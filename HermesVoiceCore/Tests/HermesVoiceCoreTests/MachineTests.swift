import XCTest
@testable import HermesVoiceCore

final class MachineTests: XCTestCase {

    private var state = LiveMachine.start(settings: VoiceSettings(), botName: "nova")
    private var effects: [VoiceEffect] = []
    private var clock: Double = 1_000

    private func feed(_ input: VoiceInput, now: Double? = nil) {
        let transition = LiveMachine.reduce(state, input, now: now ?? clock)
        state = transition.state
        effects = transition.effects
    }

    private func connected() {
        feed(.connect(state.settings, botName: "nova"))
        feed(.server(.setupComplete))
        XCTAssertEqual(state.phase, .listening)
    }

    func testConnectOpensSocketAndSetupStartsListening() {
        feed(.connect(VoiceSettings(), botName: "nova"))
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertEqual(effects, [.openSocket(nil)])

        feed(.server(.setupComplete))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects, [.startMicrophone])
    }

    func testInterruptionClearsTheQueueAtOnce() {
        connected()
        feed(.server(.audio(Data([1, 2, 3]), sampleRate: 24_000)))
        feed(.server(.audio(Data([4, 5, 6]), sampleRate: 24_000)))
        XCTAssertEqual(state.queuedChunks, 2)
        XCTAssertEqual(state.phase, .modelSpeaking)

        feed(.server(.interrupted))
        XCTAssertEqual(state.queuedChunks, 0)
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects, [.stopPlayback])
    }

    func testToolCallDelegatesAndInterruptionKeepsTheAnswer() {
        connected()
        feed(.server(.toolCall([ToolInvocation(id: "c1", name: "ask_hermes", request: "내 서버 디스크")])))
        guard case .delegating(let callId, let request, _) = state.phase else { return XCTFail("not delegating") }
        XCTAssertEqual(callId, "c1")
        XCTAssertEqual(request, "내 서버 디스크")
        XCTAssertEqual(effects.first, .askHermes(callId: "c1", request: "내 서버 디스크", submissionId: "voice-c1"))

        // 끼어들어도 대기 중인 답은 유지된다.
        feed(.server(.interrupted))
        guard case .delegating = state.phase else { return XCTFail("lost the delegation on interruption") }

        feed(.hermesDone(callId: "c1", speech: "132GB 남았어", isError: false))
        XCTAssertNil(state.pendingCall)
        XCTAssertEqual(state.phase, .listening)
        guard case .answerModel(let id, let payload, let isError) = effects.first else { return XCTFail("no answer") }
        XCTAssertEqual(id, "c1")
        XCTAssertFalse(isError)
        XCTAssertTrue(payload.contains("132GB"))
    }

    func testNinetySecondsIsTheLineBetweenWaitingAndFailing() {
        connected()
        feed(.server(.toolCall([ToolInvocation(id: "c1", name: "ask_hermes", request: "일정")])), now: 1_000)
        feed(.tick, now: 1_000 + 89_000)
        // 89초까지는 아직 기다린다: 경계는 90초.
        XCTAssertNotNil(state.pendingCall)

        feed(.tick, now: 1_000 + 91_000)
        XCTAssertNil(state.pendingCall)
        guard case .answerModel(_, let payload, let isError) = effects.first else { return XCTFail("no failure answer") }
        XCTAssertTrue(isError)
        XCTAssertTrue(payload.contains("90초"))
    }

    func testALateAnswerForACallWeNoLongerWaitOnIsIgnored() {
        connected()
        feed(.server(.toolCall([ToolInvocation(id: "c1", name: "ask_hermes", request: "일정")])), now: 1_000)
        feed(.tick, now: 1_000 + 91_000)
        let afterTimeout = state

        feed(.hermesDone(callId: "c1", speech: "늦은 답", isError: false))
        XCTAssertEqual(state, afterTimeout)
    }

    func testTurnIsCommittedMeBeforeBot() {
        connected()
        feed(.server(.inputTranscript("피곤했어")))
        feed(.server(.outputTranscript("고생했어")))
        feed(.server(.turnComplete))
        XCTAssertEqual(state.transcript, [
            VoiceLine(speaker: .me, text: "피곤했어"),
            VoiceLine(speaker: .bot, text: "고생했어"),
        ])
    }

    func testSpeechEndIsTheThinkingStateUntilTheBotAnswers() {
        connected()
        feed(.server(.voiceActivity("ACTIVITY_END")))
        XCTAssertTrue(state.awaitingReply)

        feed(.server(.audio(Data([1]), sampleRate: 24_000)))
        XCTAssertFalse(state.awaitingReply)
    }

    func testRetryFromAnEndedCallStartsFreshWithoutTheOldHandle() {
        connected()
        feed(.server(.resumeHandle("h-1", resumable: true)))
        feed(.hangUp)
        guard case .ended = state.phase else { return XCTFail("not ended") }

        feed(.retry)
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertNil(state.handle)
        XCTAssertEqual(effects, [.openSocket(nil)])
        XCTAssertTrue(state.transcript.isEmpty)
    }

    func testMessagesAfterTheCallEndedChangeNothing() {
        connected()
        feed(.hangUp)
        let ended = state
        feed(.server(.audio(Data([1]), sampleRate: 24_000)))
        feed(.hermesDone(callId: "c1", speech: "x", isError: false))
        feed(.socketClosed)
        XCTAssertEqual(state, ended)
    }

    func testHangUpTearsDownOnceAndNamesEveryResource() {
        connected()
        feed(.hangUp)
        XCTAssertEqual(effects, [.stopMicrophone, .stopPlayback, .closeSocket, .cleanup(.user)])
        XCTAssertTrue(state.cleanedUp)

        feed(.hangUp)
        XCTAssertEqual(effects, [])
    }

    func testMuteStopsSendingWithoutEndingTheCall() {
        connected()
        feed(.toggleMute)
        XCTAssertTrue(state.muted)
        XCTAssertEqual(effects, [.stopMicrophone])
        feed(.toggleMute)
        XCTAssertFalse(state.muted)
        XCTAssertEqual(effects, [.startMicrophone])
    }

    func testHandOffDisabledAnswersTheModelInstead() {
        var settings = VoiceSettings()
        settings.handOff = false
        state = LiveMachine.start(settings: settings, botName: nil)
        connected()
        feed(.server(.toolCall([ToolInvocation(id: "c1", name: "ask_hermes", request: "일정")])))
        XCTAssertNotNil(state.pendingCall == nil ? true : nil)
        guard case .answerModel(_, let payload, let isError) = effects.first else { return XCTFail("no refusal") }
        XCTAssertTrue(isError)
        XCTAssertTrue(payload.contains("꺼져 있어서"))
    }

    func testReconnectAttemptsAreBounded() {
        connected()
        for attempt in 1...3 {
            feed(.socketClosed)
            guard case .reconnecting = state.phase else { return XCTFail("attempt \(attempt) did not reconnect") }
            feed(.reconnectNow)
        }
        feed(.socketClosed)
        guard case .ended(let reason) = state.phase else { return XCTFail("did not give up") }
        XCTAssertEqual(reason, .network)
    }
}
