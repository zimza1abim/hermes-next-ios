import AVFoundation
import UIKit
import HermesVoiceCore

/// Microphone at 16 kHz and playback at 24 kHz. Voice-processing mode is the echo canceller.
/// Barge-in stops the player and drops every buffer that has not been heard yet.
///
/// The aura's display link must not touch the player. It reads `playedFrames` and `playbackLevel`,
/// which are a cache written on the main run loop only while the player is attached and the engine is running.
final class LiveAudio {
    private let engine = AVAudioEngine()
    private let transport = EnginePlayback()
    private let meter = PlaybackMeter()
    private let lock = NSLock()
    private var micLevel: Float = 0
    private var cachedPlayed: Int64 = 0
    private var cachedLevel: Float = 0
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var pending = Data()
    private var micOn = false
    private var prepared = false
    private var headOffset: Int64 = 0
    private var playGeneration = 0
    private var outstanding = 0
    private var speakerOn = true
    private var observers: [NSObjectProtocol] = []
    private var clock: Timer?

    var onChunk: ((Data) -> Void)?
    var onFocusLost: ((Bool) -> Void)?
    var onFocusRegained: (() -> Void)?

    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)

    static var microphoneGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    enum PrepareResult { case ready, denied, failed }

    func prepare(speaker: Bool) -> PrepareResult {
        if prepared { route(speaker: speaker); return .ready }
        guard Self.microphoneGranted else { return .denied }
        speakerOn = speaker
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
            try session.setActive(true)
        } catch {
            return .failed
        }
        route(speaker: speaker)
        guard let playFormat else { return .failed }
        // Voice processing before any connection and before engine.prepare. The input node
        // exists once it is touched; the player is still unattached, so nothing reads its clock.
        try? engine.inputNode.setVoiceProcessingEnabled(true)
        engine.attach(transport.player)
        engine.attach(transport.pitch)
        engine.connect(transport.player, to: transport.pitch, format: playFormat)
        engine.connect(transport.pitch, to: engine.mainMixerNode, format: playFormat)
        engine.prepare()
        do { try engine.start() } catch {
            abandonGraph()
            return .failed
        }
        guard transport.ready(prepared: true, running: engine.isRunning) else {
            abandonGraph()
            return .failed
        }
        prepared = true
        transport.setPitch(0, prepared: true, running: engine.isRunning)
        transport.play(prepared: true, running: engine.isRunning)
        startClock()
        UIDevice.current.isProximityMonitoringEnabled = true
        observe()
        return .ready
    }

    func setSpeed(_ speed: Float) {
        transport.setRate(speed, prepared: prepared, running: engine.isRunning)
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
        guard Self.microphoneGranted else { return false }
        if !prepared {
            guard prepare(speaker: speakerOn) == .ready else { return false }
        }
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
        guard nodeReady, let playFormat, pcm.count >= 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)) else { return }
        buffer.frameLength = AVAudioFrameCount(pcm.count / 2)
        pcm.withUnsafeBytes { raw in
            guard let source = raw.bindMemory(to: Int16.self).baseAddress, let dest = buffer.floatChannelData?[0] else { return }
            for index in 0..<Int(buffer.frameLength) {
                dest[index] = Float(source[index]) / Float(Int16.max)
            }
        }
        lock.lock()
        let generation = playGeneration
        outstanding += 1
        lock.unlock()
        let scheduled = transport.schedule(buffer, prepared: prepared, running: engine.isRunning) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.playGeneration == generation { self.outstanding = max(0, self.outstanding - 1) }
            self.lock.unlock()
        }
        guard scheduled else {
            lock.lock()
            if playGeneration == generation { outstanding = max(0, outstanding - 1) }
            lock.unlock()
            return
        }
        meter.append(pcm)
        if !transport.isPlaying(prepared: prepared, running: engine.isRunning) {
            transport.play(prepared: prepared, running: engine.isRunning)
        }
    }

    /// Interrupt: drop the queue and whatever the player has not rendered.
    func stopPlayback() {
        halt(restart: true)
    }

    /// What the speaker has rendered. The display link reads this; it never asks the node.
    func playedFrames() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return cachedPlayed
    }

    func enqueuedFrames() -> Int64 { meter.enqueued }

    func playbackLevel() -> Float {
        lock.lock(); defer { lock.unlock() }
        return cachedLevel
    }

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
        halt(restart: false)
        clock?.invalidate()
        clock = nil
        if nodeReady {
            transport.stopPlayback(prepared: prepared, running: engine.isRunning)
        }
        engine.stop()
        if transport.player.engine != nil { engine.detach(transport.player) }
        if transport.pitch.engine != nil { engine.detach(transport.pitch) }
        prepared = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        UIDevice.current.isProximityMonitoringEnabled = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private var nodeReady: Bool {
        transport.ready(prepared: prepared, running: engine.isRunning)
    }

    private func halt(restart: Bool) {
        lock.lock()
        playGeneration += 1
        outstanding = 0
        cachedPlayed = 0
        cachedLevel = 0
        let offset = headOffset
        lock.unlock()
        meter.flush()
        let running = engine.isRunning
        guard transport.ready(prepared: prepared, running: running) else {
            lock.lock(); headOffset = 0; lock.unlock()
            return
        }
        transport.stopPlayback(prepared: prepared, running: running)
        guard restart else {
            lock.lock(); headOffset = 0; lock.unlock()
            return
        }
        let stillRunning = engine.isRunning
        transport.play(prepared: prepared, running: stillRunning)
        let sample = transport.sampleTime(prepared: prepared, running: stillRunning) ?? offset
        lock.lock()
        headOffset = sample
        lock.unlock()
    }

    /// Writes the cache. This is the only place that reads the player's clock, and only while it has an engine.
    private func publishClock() {
        let running = engine.isRunning
        guard transport.ready(prepared: prepared, running: running) else { return }
        lock.lock()
        let offset = headOffset
        lock.unlock()
        let played = transport.playedFrames(prepared: prepared, running: running, headOffset: offset, enqueued: meter.enqueued)
        let level = meter.level(playedFrames: played)
        lock.lock()
        cachedPlayed = played
        cachedLevel = level
        lock.unlock()
    }

    private func startClock() {
        clock?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.publishClock()
        }
        clock = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func abandonGraph() {
        clock?.invalidate()
        clock = nil
        engine.stop()
        if transport.player.engine != nil { engine.detach(transport.player) }
        if transport.pitch.engine != nil { engine.detach(transport.pitch) }
        prepared = false
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
            halt(restart: false)
            stopMicrophone()
            onFocusLost?(false)
            return
        }
        let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
        guard options.contains(.shouldResume), prepared, transport.player.engine != nil else { return }
        try? engine.start()
        transport.play(prepared: prepared, running: engine.isRunning)
        onFocusRegained?()
    }
}
