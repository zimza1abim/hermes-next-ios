import AVFoundation
import UIKit
import HermesVoiceCore

/// Microphone at 16 kHz and playback at 24 kHz. Voice-processing mode is the echo canceller.
/// Barge-in stops the player and drops every buffer that has not been heard yet.
final class LiveAudio {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let meter = PlaybackMeter()
    private let lock = NSLock()
    private var micLevel: Float = 0
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending = Data()
    private var micOn = false
    private var prepared = false
    private var headOffset: AVAudioFramePosition = 0
    private var playGeneration = 0
    private var outstanding = 0
    private var speakerOn = true
    private var observers: [NSObjectProtocol] = []

    var onChunk: ((Data) -> Void)?
    var onFocusLost: ((Bool) -> Void)?
    var onFocusRegained: (() -> Void)?

    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)

    func prepare(speaker: Bool) -> Bool {
        if prepared { route(speaker: speaker); return true }
        speakerOn = speaker
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true)
        } catch {
            return false
        }
        route(speaker: speaker)
        guard let playFormat else { return false }
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: playFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: playFormat)
        pitch.pitch = 0
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        engine.prepare()
        do { try engine.start() } catch { return false }
        player.play()
        prepared = true
        UIDevice.current.isProximityMonitoringEnabled = true
        observe()
        return true
    }

    func setSpeed(_ speed: Float) {
        pitch.rate = min(max(speed, 0.5), 2)
    }

    func route(speaker: Bool) {
        speakerOn = speaker
        let session = AVAudioSession.sharedInstance()
        let bluetooth = session.currentRoute.outputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE
        }
        let near = UIDevice.current.proximityState
        try? session.overrideOutputAudioPort((speaker && !bluetooth && !near) ? .speaker : .none)
    }

    func startMicrophone() -> Bool {
        if micOn { return true }
        guard prepared || prepare(speaker: speakerOn) else { return false }
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: hardware, to: target) else { return false }
        self.converter = converter
        self.targetFormat = target
        lock.lock()
        pending.removeAll()
        lock.unlock()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        if !engine.isRunning { try? engine.start() }
        micOn = true
        return true
    }

    func stopMicrophone() {
        guard micOn else { return }
        micOn = false
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        pending.removeAll()
        micLevel = 0
        lock.unlock()
    }

    func play(_ pcm: Data) {
        guard prepared, let playFormat, pcm.count >= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress, let dest = buffer.floatChannelData?[0] else { return }
            for index in 0..<Int(buffer.frameLength) {
                dest[index] = Float(source[index]) / Float(Int16.max)
            }
        }
        meter.append(pcm)
        lock.lock()
        let generation = playGeneration
        outstanding += 1
        lock.unlock()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.playGeneration == generation { self.outstanding = max(0, self.outstanding - 1) }
            self.lock.unlock()
        }
        if !player.isPlaying { player.play() }
    }

    /// Interrupt: drop the queue and whatever the player has not rendered.
    func stopPlayback() {
        lock.lock()
        playGeneration += 1
        outstanding = 0
        lock.unlock()
        player.stop()
        meter.flush()
        if engine.isRunning { player.play() }
        if let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) {
            headOffset = playerTime.sampleTime
        } else {
            headOffset = 0
        }
    }

    func playedFrames() -> Int64 {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime) else { return 0 }
        let played = playerTime.sampleTime - headOffset
        return min(max(played, 0), meter.enqueued)
    }

    func enqueuedFrames() -> Int64 { meter.enqueued }

    func playbackLevel() -> Float { meter.level(playedFrames: playedFrames()) }

    func amplitude() -> Float {
        lock.lock(); defer { lock.unlock() }
        return micLevel
    }

    func playbackIdle() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return outstanding == 0
    }

    func release() {
        stopMicrophone()
        stopPlayback()
        player.stop()
        engine.stop()
        if prepared {
            engine.detach(player)
            engine.detach(pitch)
        }
        prepared = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        UIDevice.current.isProximityMonitoringEnabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let targetFormat else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
        var error: NSError?
        var fed = false
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let channel = output.int16ChannelData else { return }
        let bytes = Data(bytes: channel[0], count: Int(output.frameLength) * 2)
        var chunks: [Data] = []
        lock.lock()
        pending.append(bytes)
        micLevel = PCM.rms(bytes)
        while pending.count >= 640 {
            chunks.append(Data(pending.prefix(640)))
            pending.removeFirst(640)
        }
        lock.unlock()
        guard let onChunk else { return }
        for chunk in chunks { onChunk(chunk) }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            self?.interrupted(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.route(speaker: self.speakerOn)
        })
        observers.append(center.addObserver(forName: UIDevice.proximityStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.route(speaker: self.speakerOn)
        })
    }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .began {
            stopPlayback()
            stopMicrophone()
            onFocusLost?(false)
            return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        guard options.contains(.shouldResume) else { return }
        try? engine.start()
        player.play()
        onFocusRegained?()
    }
}
