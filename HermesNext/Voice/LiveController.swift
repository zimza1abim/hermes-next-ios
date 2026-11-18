import AVFoundation
import Foundation
import HermesVoiceCore

/// One live call. The state machine decides; this is the only place that touches the socket, the audio and Hermes.
@MainActor
@Observable
final class LiveController {
    private let store: Store
    let audio = LiveAudio()
    private let sender = SocketSend()
    private var socket: LiveSocket?
    private(set) var captions = CaptionTimeline()

    private(set) var state = VoiceState()
    private(set) var interrupt: InterruptMark?
    private(set) var revealedChars = 0
    private(set) var booting = false
    private(set) var startedAt: Date?
    var palette = AuraPalette.nova

    private var interruptSeq = 0
    private var cleanedUp = false
    private var greeted = false
    private var echoed = 0
    private let seed = Int.random(in: 0...10_000)
    private var pendingContext = ""
    private var pendingSoul = ""
    private var previewing = false
    private var botKey: String?
    private var displayName: String?
    private var ticker: Task<Void, Never>?
    private var drainer: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init(store: Store) {
        self.store = store
        audio.onChunk = { [sender] pcm in
            sender.send(LiveProtocol.audioChunk(pcm))
        }
        audio.onFocusLost = { [weak self] permanent in
            Task { @MainActor in self?.audioFocusLost(permanent: permanent) }
        }
        audio.onFocusRegained = { [weak self] in
            Task { @MainActor in self?.audioFocusRegained() }
        }
    }

    func liveBotText() -> String { captions.currentText() }

    /// Levels for one aura frame. Cached audio only: the display link must not touch the player.
    func signalSnapshot() -> (mic: Float, playback: Float, revealed: Int) {
        let mic = state.muted ? 0 : audio.amplitude()
        return (mic, audio.playbackLevel(), captions.revealedChars(playedFrames: audio.playedFrames()))
    }

    func start(context: String, preview: Bool = false) {
        pendingContext = context
        previewing = preview
        if !cleanedUp && !isTerminal(state.phase) && !isIdle(state.phase) {
            dispatch(.hangUp)
        }
        // A finished call ignores further input, so a new call starts from a blank machine.
        state = VoiceState()
        captions = CaptionTimeline()
        interrupt = nil
        revealedChars = 0
        greeted = false
        echoed = 0
        guard GeminiKey.load() != nil else {
            dispatch(.fatal(.keyMissing, notice: "Gemini 키가 없어요."))
            return
        }
        botKey = store.profile?.lowercased()
        displayName = store.openBot?.title
        cleanedUp = false
        greeted = false
        echoed = 0
        startedAt = Date()
        booting = true
        store.voiceCallActive = true
        Task {
            pendingSoul = await store.soulText()
            let allowed = await Self.microphoneAllowed()
            booting = false
            guard allowed else {
                dispatch(.fatal(.error, notice: "마이크 권한을 허용해야 통화할 수 있어요. 설정에서 허용해 주세요."))
                return
            }
            let settings = VoiceSettingsStore.load()
            dispatch(.connect(settings, botName: displayName))
        }
    }

    func hangUp() { dispatch(.hangUp) }
    func toggleMute() { dispatch(.toggleMute) }
    func toggleSpeaker() {
        dispatch(.toggleSpeaker)
        audio.route(speaker: state.speakerOn)
    }
    func toggleSubtitles() { dispatch(.toggleSubtitles) }
    func retry() {
        if case .ended = state.phase {
            cleanedUp = false
            startedAt = Date()
            greeted = false
        }
        dispatch(.retry)
    }
    func approvalShown(_ approval: VoiceApproval) { dispatch(.approvalRequested(approval)) }
    func approvalResolved() { dispatch(.approvalResolved) }

    func close() {
        if !cleanedUp { dispatch(.hangUp) }
    }

    private func audioFocusLost(permanent: Bool) {
        audio.stopPlayback()
        audio.stopMicrophone()
        if permanent {
            dispatch(.fatal(.error, notice: "다른 앱이 오디오를 가져갔어요. 통화를 끝냈어요."))
        }
    }

    private func audioFocusRegained() {
        if state.phase == .listening || state.phase == .modelSpeaking {
            _ = audio.startMicrophone()
        }
    }

    private func dispatch(_ input: VoiceInput) {
        let transition = LiveMachine.reduce(state, input, now: Date().timeIntervalSince1970 * 1000)
        state = transition.state
        echo(transition.state)
        refreshSend()
        apply(transition.effects)
    }

    private func echo(_ state: VoiceState) {
        guard state.transcript.count > echoed else { return }
        for line in state.transcript.dropFirst(echoed) {
            store.appendVoiceLine(me: line.speaker == .me, text: line.text)
        }
        echoed = state.transcript.count
    }

    private func refreshSend() {
        let phase = state.phase
        let sending = !state.muted && (phase == .listening || phase == .modelSpeaking || isDelegating(phase))
        sender.update(socket: socket, enabled: sending)
    }

    private func apply(_ effects: [VoiceEffect]) {
        for effect in effects {
            switch effect {
            case .openSocket(let handle):
                openSocket(handle)
            case .closeSocket:
                socket?.close()
                socket = nil
                refreshSend()
            case .startMicrophone:
                if !audio.startMicrophone() {
                    dispatch(.fatal(.error, notice: "마이크를 열지 못했어요. 다른 앱이 쓰고 있는지 확인해 주세요."))
                }
            case .stopMicrophone:
                audio.stopMicrophone()
            case .play(let pcm):
                audio.play(pcm)
                scheduleDrain()
            case .stopPlayback:
                audio.stopPlayback()
            case .askHermes(let callId, let request, let submissionId):
                askHermes(callId: callId, request: request, submissionId: submissionId)
            case .answerModel(_, let payload, _):
                socket?.send(payload)
            case .scheduleReconnect(_, let delayMs):
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(delayMs))
                    guard !Task.isCancelled else { return }
                    self?.dispatch(.reconnectNow)
                }
            case .announceApproval:
                socket?.send(LiveProtocol.textTurn("승인 요청이 떴어요. 화면에 카드를 띄웠으니 \"화면에서 허용해 줄래?\"라고 짧게 말해 줘."))
            case .cleanup(_):
                cleanup()
            }
        }
        scheduleTicker()
    }

    private func openSocket(_ handle: String?) {
        let settings = state.settings
        var config = LiveSetup()
        config.model = settings.model
        config.speed = settings.speed
        config.voice = settings.voiceFor(botKey)
        config.handOff = previewing ? false : settings.handOff
        config.resumeHandle = previewing ? nil : handle
        config.sessionResumption = !previewing
        config.languageCode = settings.languageCode()
        var instructions = PersonaBuilder.instructions(
            botName: settings.nameFor(displayName),
            role: nil,
            persona: settings.personaFor(botKey),
            handOff: config.handOff,
            language: settings.language,
            soulNote: pendingSoul
        )
        if !pendingContext.isEmpty { instructions += "\n\n" + pendingContext }
        config.instructions = instructions
        guard let key = GeminiKey.load() else {
            dispatch(.fatal(.keyMissing, notice: "Gemini 키가 없어요."))
            return
        }
        switch audio.prepare(speaker: state.speakerOn) {
        case .ready:
            break
        case .denied:
            dispatch(.fatal(.error, notice: "마이크 권한을 허용해야 통화할 수 있어요. 설정에서 허용해 주세요."))
            return
        case .failed:
            dispatch(.fatal(.error, notice: "오디오를 열지 못했어요."))
            return
        }
        audio.setSpeed(settings.speed)
        audio.route(speaker: state.speakerOn)
        let socket = LiveSocket()
        socket.onText = { [weak self] text in
            Task { @MainActor in self?.handle(text) }
        }
        socket.onClosed = { [weak self] reason in
            Task { @MainActor in self?.socketClosed(reason) }
        }
        self.socket = socket
        refreshSend()
        let setup = LiveProtocol.setup(config)
        socket.onOpened = { [weak socket] in
            socket?.send(setup)
        }
        socket.connect(LiveProtocol.endpoint(key: key))
    }

    private func handle(_ raw: String) {
        if cleanedUp { return }
        let lowered = raw.lowercased()
        if lowered.contains("resource_exhausted") || raw.contains("429") || lowered.contains("quota") {
            dispatch(.fatal(.quota, notice: "오늘 무료 한도를 다 썼어요."))
            return
        }
        for event in LiveProtocol.parse(raw) {
            switch event {
            case .interrupted:
                let snap = captions.snapshot(playedFrames: audio.playedFrames())
                interruptSeq += 1
                interrupt = InterruptMark(seq: interruptSeq, text: snap.text, revealedChars: snap.revealedChars, atMs: Date().timeIntervalSince1970 * 1000)
                captions.endTurn()
            case .audio(let pcm, let rate):
                captions.onAudio(frames: pcm.count / 2, sampleRate: rate, enqueuedBefore: audio.enqueuedFrames())
            case .outputTranscript(let text):
                captions.onTranscript(text, enqueuedNow: audio.enqueuedFrames())
            case .turnComplete:
                captions.endTurn()
            case .setupComplete:
                if !greeted {
                    greeted = true
                    if previewing {
                        socket?.send(LiveProtocol.textTurn("이 문장을 그대로, 자연스럽게 읽어 줘: 안녕, 나야. 오늘 하루도 정말 고생 많았어. 잠깐 쉬어 가자."))
                    } else {
                        let hour = Calendar.current.component(.hour, from: Date())
                        socket?.send(LiveProtocol.textTurn(LiveMachine.greeting(hour: hour, hasHistory: !pendingContext.isEmpty, seed: seed)))
                    }
                }
            default:
                break
            }
            dispatch(.server(event))
        }
    }

    private func socketClosed(_ reason: String?) {
        if cleanedUp { return }
        let message = reason ?? ""
        let stale = message.localizedCaseInsensitiveContains("session not found") || message.contains("1008")
        if stale, state.handle != nil { dispatch(.handleRejected) }
        let quota = message.contains("429") || message.localizedCaseInsensitiveContains("quota") || message.contains("RESOURCE_EXHAUSTED")
        if quota {
            dispatch(.fatal(.quota, notice: "오늘 무료 한도를 다 썼어요."))
        } else {
            dispatch(.socketClosed)
        }
    }

    private func askHermes(callId: String, request: String, submissionId: String) {
        Task {
            let turn = await store.askVoice(question: request, submissionId: submissionId)
            if turn.text == nil {
                dispatch(.hermesFailed(callId: callId, failure: .error(turn.error)))
            } else {
                dispatch(.hermesDone(callId: callId, speech: HermesHandOff.polish(turn.text), isError: false))
            }
        }
    }

    private func scheduleTicker() {
        let phase = state.phase
        let active = phase == .connecting || phase == .listening || phase == .modelSpeaking || isDelegating(phase)
        if !active || cleanedUp {
            ticker?.cancel()
            ticker = nil
            return
        }
        if ticker != nil { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.dispatch(.tick)
            }
        }
    }

    private func scheduleDrain() {
        if drainer != nil { return }
        drainer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, !Task.isCancelled else { return }
                if self.audio.playbackIdle() {
                    self.drainer = nil
                    self.dispatch(.audioDrained)
                    return
                }
            }
        }
    }

    private func cleanup() {
        if cleanedUp { return }
        cleanedUp = true
        leaveCallRecord()
        ticker?.cancel()
        drainer?.cancel()
        reconnectTask?.cancel()
        ticker = nil
        drainer = nil
        reconnectTask = nil
        audio.release()
        socket?.close()
        socket = nil
        sender.update(socket: nil, enabled: false)
        store.voiceCallActive = false
    }

    private func leaveCallRecord() {
        var lines = state.transcript
        let mine = state.myPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { lines.append(VoiceLine(speaker: .me, text: mine)) }
        let bot = state.botPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bot.isEmpty { lines.append(VoiceLine(speaker: .bot, text: bot)) }
        guard !lines.isEmpty else { return }
        let elapsed = startedAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0
        let clock = formatClock(elapsed)
        let name = displayName?.isEmpty == false ? displayName! : "Hermes"
        let spoken = lines.suffix(60).map { line in
            (line.speaker == .me ? "나: " : "\(name): ") + line.text
        }
        store.recordVoiceCall(HermesHandOff.callRecord(clock: clock, bot: displayName, lines: Array(spoken)))
    }

    private static func microphoneAllowed() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    private func isTerminal(_ phase: VoicePhase) -> Bool {
        if case .ended = phase { return true }
        return false
    }

    private func isIdle(_ phase: VoicePhase) -> Bool {
        if case .idle = phase { return true }
        return false
    }

    private func isDelegating(_ phase: VoicePhase) -> Bool {
        if case .delegating = phase { return true }
        return false
    }
}
