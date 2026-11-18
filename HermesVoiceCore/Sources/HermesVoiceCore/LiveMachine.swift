import Foundation

public enum Speaker: Equatable, Sendable { case me, bot }

public struct VoiceLine: Equatable, Sendable {
    public var speaker: Speaker
    public var text: String
    public init(speaker: Speaker, text: String) {
        self.speaker = speaker
        self.text = text
    }
}

public enum VoiceEndReason: String, Equatable, Sendable {
    case user, error, quota, keyMissing, network
}

public enum VoicePhase: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case modelSpeaking
    case delegating(callId: String, request: String, startedAt: Double)
    case reconnecting(handle: String?)
    case ended(VoiceEndReason)
}

public struct VoiceApproval: Equatable, Sendable {
    public var id: String
    public var tool: String
    public var prompt: String
    public init(id: String, tool: String, prompt: String) {
        self.id = id
        self.tool = tool
        self.prompt = prompt
    }
}

public struct PendingCall: Equatable, Sendable {
    public var id: String
    public var request: String
    public var submissionId: String
    public var startedAt: Double
}

public struct VoiceState: Equatable, Sendable {
    public var phase: VoicePhase = .idle
    public var settings = VoiceSettings()
    public var botName: String?
    public var handle: String?
    public var muted = false
    public var speakerOn = true
    public var subtitlesOn = true
    public var transcript: [VoiceLine] = []
    public var botPartial = ""
    public var myPartial = ""
    public var queuedChunks = 0
    public var pendingCall: PendingCall?
    public var approval: VoiceApproval?
    public var reconnectAttempts = 0
    public var endReason: VoiceEndReason?
    public var notice: String?
    public var cleanedUp = false
    public var awaitingReply = false

    public init() {}
}

public enum VoiceInput: Equatable, Sendable {
    case connect(VoiceSettings, botName: String?)
    case socketOpened
    case socketClosed
    case server(LiveEvent)
    case hermesDone(callId: String, speech: String, isError: Bool)
    case hermesFailed(callId: String, failure: HandOffFailure)
    case hangUp
    case toggleMute
    case toggleSpeaker
    case toggleSubtitles
    case approvalRequested(VoiceApproval)
    case approvalResolved
    case tick
    case audioDrained
    case handleRejected
    case reconnectNow
    case retry
    case fatal(VoiceEndReason, notice: String?)
}

public enum VoiceEffect: Equatable, Sendable {
    case openSocket(String?)
    case closeSocket
    case startMicrophone
    case stopMicrophone
    case play(Data)
    case stopPlayback
    case askHermes(callId: String, request: String, submissionId: String)
    case answerModel(callId: String, payload: String, isError: Bool)
    case scheduleReconnect(attempt: Int, delayMs: Int)
    case announceApproval
    case cleanup(VoiceEndReason)
}

public struct Transition: Equatable, Sendable {
    public var state: VoiceState
    public var effects: [VoiceEffect]
    public init(_ state: VoiceState, _ effects: [VoiceEffect]) {
        self.state = state
        self.effects = effects
    }
}

/// The call, as a pure function. Sound, sockets and Hermes sit outside; every branch is reachable in a
/// test, which is the only way "a late message after hang-up" or "the 90 s clock" can be proven.
public enum LiveMachine {

    public static let maxReconnects = 3
    public static let reconnectBaseMs = 500

    public static func start(settings: VoiceSettings, botName: String?) -> VoiceState {
        var state = VoiceState()
        state.settings = settings
        state.botName = botName
        state.subtitlesOn = settings.subtitles
        state.speakerOn = settings.speakerOn
        return state
    }

    /// 첫 마디. 고정 질문 목록 대신 지금 시각과 대화 유무만 알려 준다.
    public static func greeting(hour: Int, hasHistory: Bool, seed: Int) -> String {
        let part: String
        switch hour {
        case 5...10: part = "아침"
        case 11...13: part = "점심때"
        case 14...17: part = "오후"
        case 18...21: part = "저녁"
        default: part = "늦은 시간"
        }
        let variety = seed % 2 == 0 ? "짧은 인사" : "아주 짧게 인사"
        var text = "통화가 연결됐어. 지금은 \(part). 인사는 한 문장, \(variety)."
        text += " \"오늘 하루도 고생했어\", \"오늘 하루 어떻게 시작했어\", \"오늘 어땠어\" 같은 상투어는 쓰지 마."
        text += hasHistory
            ? " 최근에 나눈 대화가 있으면 그중 하나를 가볍게 이어 가도 되지만, 억지로 꺼내지는 마."
            : " 이어 갈 대화가 없으면 인사만 하고 사용자가 말을 걸 때까지 기다려도 돼."
        text += " 질문은 하나만, 답이 없을 수 있는 질문(\"뭐 했어?\", \"요즘 빠진 게 뭐야?\")은 하지 마."
        text += " 묻기 애매하면 그냥 인사만 해."
        return text
    }

    public static func reduce(_ state: VoiceState, _ input: VoiceInput, now: Double) -> Transition {
        // 다시 시도는 끝난 통화도 받는다: 종료 화면의 버튼이 아무 일도 안 하던 원인이었다.
        if case .retry = input {
            guard case .ended = state.phase else { return Transition(state, []) }
            var next = VoiceState()
            next.phase = .connecting
            next.settings = state.settings
            next.botName = state.botName
            next.handle = nil
            next.subtitlesOn = state.subtitlesOn
            next.speakerOn = state.speakerOn
            return Transition(next, [.openSocket(nil)])
        }

        // 끝난 통화는 아무것도 받지 않는다: 늦은 프레임이 소켓을 되살리지 못하게.
        if state.cleanedUp { return Transition(state, []) }

        switch input {
        case .connect(let settings, let bot):
            var next = VoiceState()
            next.phase = .connecting
            next.settings = settings
            next.botName = bot
            next.handle = state.handle
            next.subtitlesOn = settings.subtitles
            next.speakerOn = settings.speakerOn
            return Transition(next, [.openSocket(state.handle)])

        case .socketOpened:
            return Transition(state, [])

        case .server(let event):
            return server(state, event, now: now)

        case .socketClosed:
            return onSocketClosed(state)

        case .hermesDone(let callId, let speech, let isError):
            return answer(state, callId, speech: speech, isError: isError)

        case .hermesFailed(let callId, let failure):
            return answer(state, callId, speech: HermesHandOff.failureSpeech(failure), isError: true)

        case .hangUp:
            return end(state, .user, nil)

        case .fatal(let reason, let notice):
            return end(state, reason, notice)

        case .toggleMute:
            var next = state
            next.muted.toggle()
            var effects: [VoiceEffect] = []
            if state.phase == .listening || state.phase == .modelSpeaking {
                effects.append(next.muted ? .stopMicrophone : .startMicrophone)
            }
            return Transition(next, effects)

        case .toggleSpeaker:
            var next = state
            next.speakerOn.toggle()
            return Transition(next, [])

        case .toggleSubtitles:
            var next = state
            next.subtitlesOn.toggle()
            return Transition(next, [])

        case .approvalRequested(let approval):
            var next = state
            next.approval = approval
            return Transition(next, [.announceApproval])

        case .approvalResolved:
            var next = state
            next.approval = nil
            return Transition(next, [])

        case .tick:
            return tick(state, now: now)

        case .audioDrained:
            var next = state
            next.queuedChunks = 0
            if case .modelSpeaking = state.phase { next.phase = .listening }
            return Transition(next, [])

        case .handleRejected:
            var next = state
            next.handle = nil
            if case .reconnecting = state.phase { next.phase = .reconnecting(handle: nil) }
            return Transition(next, [])

        case .reconnectNow:
            guard case .reconnecting = state.phase else { return Transition(state, []) }
            var next = state
            next.phase = .connecting
            return Transition(next, [.openSocket(state.handle)])

        case .retry:
            return Transition(state, [])
        }
    }

    private static func server(_ state: VoiceState, _ event: LiveEvent, now: Double) -> Transition {
        switch event {
        case .setupComplete:
            var next = state
            next.phase = .listening
            next.reconnectAttempts = 0
            return Transition(next, [.startMicrophone])

        case .audio(let pcm, _):
            var next = state
            if case .listening = state.phase { next.phase = .modelSpeaking }
            next.queuedChunks += 1
            next.awaitingReply = false
            return Transition(next, [.play(pcm)])

        case .outputTranscript(let text):
            var next = state
            if case .listening = state.phase { next.phase = .modelSpeaking }
            next.botPartial += text
            next.awaitingReply = false
            return Transition(next, [])

        case .inputTranscript(let text):
            var next = state
            next.myPartial += text
            return Transition(next, [])

        case .turnComplete:
            var next = commit(state)
            next.phase = state.pendingCall != nil ? state.phase : .listening
            next.awaitingReply = false
            return Transition(next, [])

        case .interrupted:
            var next = commitBot(state)
            // 끼어들기로 Hermes 질문을 버리지 않는다: 답은 그대로 오고, 여기서 버리면 같은 걸 두 번 묻는다.
            next.phase = state.pendingCall != nil ? state.phase : .listening
            next.queuedChunks = 0
            next.awaitingReply = false
            return Transition(next, [.stopPlayback])

        case .toolCall(let calls):
            return onToolCall(state, calls, now: now)

        case .goAway:
            var next = state
            next.phase = .reconnecting(handle: state.handle)
            next.queuedChunks = 0
            return Transition(next, [
                .stopMicrophone, .stopPlayback, .closeSocket,
                .scheduleReconnect(attempt: 1, delayMs: reconnectBaseMs),
            ])

        case .voiceActivity(let type):
            var next = state
            // 말 끝 + 듣는 중 + 음소거 아님 = 봇의 첫 응답을 기다린다("생각 중").
            next.awaitingReply = type.hasSuffix("END") && state.phase == .listening && !state.muted
            return Transition(next, [])

        case .resumeHandle(let handle, let resumable):
            var next = state
            if resumable { next.handle = handle }
            return Transition(next, [])
        }
    }

    private static func onToolCall(_ state: VoiceState, _ calls: [ToolInvocation], now: Double) -> Transition {
        guard state.settings.handOff else {
            let refusals: [VoiceEffect] = calls.map { call in
                .answerModel(
                    callId: call.id,
                    payload: LiveProtocol.toolResult(callId: call.id, text: "지금은 Hermes 연결이 꺼져 있어서 확인할 수 없어요.", isError: true),
                    isError: true
                )
            }
            return Transition(state, refusals)
        }
        guard let first = calls.first else { return Transition(state, []) }
        let request = first.request.isEmpty ? state.botPartial.trimmingCharacters(in: .whitespaces) : first.request
        let pending = PendingCall(
            id: first.id,
            request: request,
            submissionId: "voice-\(first.id)",
            startedAt: now
        )
        var effects: [VoiceEffect] = [.askHermes(callId: pending.id, request: request, submissionId: pending.submissionId)]
        for extra in calls.dropFirst() {
            effects.append(.answerModel(
                callId: extra.id,
                payload: LiveProtocol.toolResult(callId: extra.id, text: "이미 다른 확인을 하고 있어요.", isError: true),
                isError: true
            ))
        }
        var next = state
        next.phase = .delegating(callId: pending.id, request: request, startedAt: now)
        next.pendingCall = pending
        next.awaitingReply = false
        return Transition(next, effects)
    }

    private static func answer(_ state: VoiceState, _ callId: String, speech: String, isError: Bool) -> Transition {
        guard let pending = state.pendingCall, pending.id == callId else { return Transition(state, []) }
        let payload = isError
            ? HermesHandOff.toolResult(callId: callId, text: speech, isError: true)
            : HermesHandOff.toolResult(callId: callId, text: speech)
        var next = state
        next.pendingCall = nil
        if case .delegating = state.phase { next.phase = .listening }
        return Transition(next, [.answerModel(callId: callId, payload: payload, isError: isError)])
    }

    private static func tick(_ state: VoiceState, now: Double) -> Transition {
        guard case .delegating(let callId, _, let startedAt) = state.phase else { return Transition(state, []) }
        guard now - startedAt >= HermesHandOff.timeoutMs else { return Transition(state, []) }
        // 90초를 넘기면 사실대로 말한다: 성공한 척하지 않는다.
        return answer(state, callId, speech: HermesHandOff.failureSpeech(.timeout), isError: true)
    }

    private static func onSocketClosed(_ state: VoiceState) -> Transition {
        let attempts = state.reconnectAttempts + 1
        guard attempts <= maxReconnects else {
            return end(state, .network, "연결이 끊겼어요.")
        }
        var next = state
        next.phase = .reconnecting(handle: state.handle)
        next.reconnectAttempts = attempts
        let delay = reconnectBaseMs * (1 << (attempts - 1))
        return Transition(next, [.stopMicrophone, .stopPlayback, .scheduleReconnect(attempt: attempts, delayMs: delay)])
    }

    private static func end(_ state: VoiceState, _ reason: VoiceEndReason, _ notice: String?) -> Transition {
        guard !state.cleanedUp else { return Transition(state, []) }
        var next = state
        next.phase = .ended(reason)
        next.endReason = reason
        next.notice = notice
        next.cleanedUp = true
        next.awaitingReply = false
        return Transition(next, [
            .stopMicrophone, .stopPlayback, .closeSocket, .cleanup(reason),
        ])
    }

    /// 내가 먼저 말했으니 ME를 먼저 기록한다. 예전 iOS/Android 초기 구현은 BOT → ME로 뒤집혀 남았다.
    private static func commit(_ state: VoiceState) -> VoiceState {
        var next = state
        let mine = state.myPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty {
            next.transcript.append(VoiceLine(speaker: .me, text: mine))
            next.myPartial = ""
        }
        return commitBot(next)
    }

    private static func commitBot(_ state: VoiceState) -> VoiceState {
        var next = state
        let bot = state.botPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bot.isEmpty {
            next.transcript.append(VoiceLine(speaker: .bot, text: bot))
            next.botPartial = ""
        }
        return next
    }
}
