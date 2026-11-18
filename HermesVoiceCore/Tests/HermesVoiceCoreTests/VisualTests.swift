import XCTest
@testable import HermesVoiceCore

final class VisualTests: XCTestCase {

    func testSnapSpringReachesNinetyPercentInATenth() {
        var spring = CriticallyDampedSpring(value: 0, target: 1, stiffness: AuraAnimator.snapStiffness)
        spring.step(dt: 0.1)
        XCTAssertEqual(spring.value, 0.90, accuracy: 0.02)
    }

    func testDefaultSpringIsMostlyThereByAThirdOfASecond() {
        var spring = CriticallyDampedSpring(value: 0, target: 1, stiffness: AuraAnimator.defaultStiffness)
        spring.step(dt: 0.33)
        XCTAssertGreaterThan(spring.value, 0.93)
        XCTAssertLessThan(spring.value, 0.98)
    }

    func testConnectCurveStartsAndEndsAtTheEnds() {
        XCTAssertEqual(UnitBezier.connectRise.value(0), 0, accuracy: 0.001)
        XCTAssertEqual(UnitBezier.connectRise.value(1), 1, accuracy: 0.001)
        XCTAssertEqual(UnitBezier.linear.value(0.4), 0.4, accuracy: 0.001)
    }

    func testMoodPriorityMatchesTheAndroidTable() {
        var state = VoiceState()
        state.phase = .listening
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: true), .interrupted)

        state.muted = true
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: true), .muted)

        state.muted = false
        state.phase = .delegating(callId: "c", request: "디스크", startedAt: 0)
        state.queuedChunks = 4
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: false), .working)

        state.phase = .listening
        state.queuedChunks = 2
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: false), .speaking)

        state.queuedChunks = 0
        state.awaitingReply = true
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: false), .thinking)

        state.awaitingReply = false
        XCTAssertEqual(AuraMoods.moodOf(state, interruptedRecently: false), .listening)

        XCTAssertEqual(AuraMoods.table[.speaking]?.swell, 0.9)
        XCTAssertEqual(AuraMoods.table[.muted]?.brightness, 0.42)
        XCTAssertEqual(AuraMoods.table.count, AuraMood.allCases.count)
    }

    func testLevelRisesFasterThanItFalls() {
        var smoother = LevelSmoother()
        let up = smoother.step(target: 1, dtMs: 80)
        smoother.reset()
        smoother.value = 1
        let down = smoother.step(target: 0, dtMs: 80)
        XCTAssertGreaterThan(up, 0.5)
        XCTAssertGreaterThan(down, 0.5)
        XCTAssertLessThan(1 - down, up)
    }

    func testNormalizeLevelClampsTheDecibelWindow() {
        XCTAssertEqual(normalizeLevel(0), 0)
        XCTAssertEqual(normalizeLevel(1), 1)
        // −20 dBFS sits three quarters of the way from −50 to −10.
        XCTAssertEqual(normalizeLevel(0.1), 0.75, accuracy: 0.02)
    }

    func testToolLabelsUseTheFirstMatchingKind() {
        XCTAssertEqual(toolLabel("내일 일정 알려줘"), "캘린더 확인 중")
        XCTAssertEqual(toolLabel("날씨 검색해줘"), "날씨 보는 중")
        XCTAssertEqual(toolLabel("서버 디스크"), "Hermes가 확인 중")
        XCTAssertEqual(toolMeta(String(repeating: "가", count: 20))?.count, 18)
        XCTAssertNil(toolMeta("   "))
    }

    func testCaptionModelFollowsThePhase() {
        var state = VoiceState()
        state.phase = .connecting
        guard case .centered(let title, _, _) = captionModel(state: state, botName: "Nova", interrupt: nil, interruptedRecently: false, liveBotText: "", clock: "00:00") else {
            return XCTFail("connecting should be centered")
        }
        XCTAssertEqual(title, "Nova에게")

        state.phase = .listening
        state.myPartial = "디스크"
        state.awaitingReply = true
        guard case .lines(let thinking) = captionModel(state: state, botName: "Nova", interrupt: nil, interruptedRecently: false, liveBotText: "", clock: "00:01") else {
            return XCTFail("listening")
        }
        XCTAssertTrue(thinking.contains { $0.role == .hint && $0.text == "생각하는 중" })

        state.phase = .delegating(callId: "c1", request: "내일 일정", startedAt: 0)
        guard case .lines(let working) = captionModel(state: state, botName: "Nova", interrupt: nil, interruptedRecently: false, liveBotText: "", clock: "00:02") else {
            return XCTFail("delegating")
        }
        XCTAssertEqual(working.last?.role, .chip)
        XCTAssertEqual(working.last?.text, "캘린더 확인 중")
    }

    func testAWordIsHiddenUntilItsFirstCharacterIsHeard() {
        let words = captionWords("오늘 하루")
        XCTAssertEqual(words.map(\.text), ["오늘", "하루"])
        XCTAssertFalse(captionWordVisible(start: words[0].start, revealed: 0, cutFrom: -1))
        XCTAssertTrue(captionWordVisible(start: words[0].start, revealed: 1, cutFrom: -1))
        XCTAssertFalse(captionWordVisible(start: words[1].start, revealed: 1, cutFrom: -1))
        XCTAssertTrue(captionWordVisible(start: words[1].start, revealed: 0, cutFrom: words[1].start))
    }

    func testFrameFoldsPlaybackIntoTheSwellAndSkipsEveryOtherOnLowPower() {
        let animator = AuraAnimator(mood: .speaking)
        animator.go(mood: .speaking, calm: false)
        animator.step(dt: 5)
        let engine = CallFrameEngine()
        // The first low-power tick is the skipped one, matching the Android frame loop.
        XCTAssertFalse(engine.step(dtMs: 16, micRMS: 0, playbackRMS: 1, revealed: 3, animator: animator, calm: false, detail: 4, skipEveryOther: true))
        XCTAssertTrue(engine.step(dtMs: 400, micRMS: 0, playbackRMS: 1, revealed: 3, animator: animator, calm: false, detail: 4, skipEveryOther: true))
        XCTAssertGreaterThan(engine.uniforms.swell, 0.5)
        XCTAssertEqual(engine.revealedChars, 3)
    }

    func testCalmMotionExpressesTheVoiceAsBrightness() {
        let animator = AuraAnimator()
        animator.go(mood: .speaking, calm: true)
        let engine = CallFrameEngine()
        engine.step(dtMs: 200, micRMS: 0, playbackRMS: 1, revealed: 0, animator: animator, calm: true, detail: 2, skipEveryOther: false)
        XCTAssertEqual(engine.uniforms.swell, 0, accuracy: 0.001)
        XCTAssertGreaterThan(engine.uniforms.brightness, animator.brightness)
    }

    func testPlaybackFlushDropsTheEnvelope() {
        var samples = Data(count: PlaybackMeter.windowBytes)
        samples[1] = 0x7F
        samples[0] = 0xFF
        XCTAssertGreaterThan(PCM.rms(samples), 0)
        let meter = PlaybackMeter()
        meter.append(samples)
        XCTAssertEqual(meter.enqueued, Int64(PlaybackMeter.windowBytes / 2))
        XCTAssertGreaterThan(meter.level(playedFrames: 0), 0)
        XCTAssertEqual(meter.level(playedFrames: meter.enqueued), 0)
        meter.flush()
        XCTAssertEqual(meter.enqueued, 0)
        XCTAssertEqual(meter.level(playedFrames: 0), 0)
    }

    func testSettingsRoundTripAndUnknownValuesFallBack() {
        var settings = VoiceSettings()
        settings.voice = .puck
        settings.model = .gemini31Flash
        settings.speed = 1.15
        settings.persona = Persona(preset: .calm, warmth: 3, custom: "")
        settings.perBot = ["nova": BotVoice(voice: .kore, persona: Persona(preset: .warm, warmth: 1, custom: ""))]
        settings.assistantName = "한채린"
        let decoded = VoiceSettingsCodec.decode(VoiceSettingsCodec.encode(settings))
        XCTAssertEqual(decoded, settings)
        let broken = VoiceSettingsCodec.decode("{\"voice\":\"NotAVoice\",\"warmth\":9,\"speed\":4}")
        XCTAssertEqual(broken.voice, .kore)
        XCTAssertEqual(broken.persona.warmth, 3)
        XCTAssertEqual(broken.speed, VoiceSettings.maxSpeed)
        XCTAssertEqual(VoiceSettingsCodec.decode("not json").voice, .default)
    }

    func testDefaultAccentStaysNovaAndAnotherAccentShifts() {
        XCTAssertEqual(AuraPalette.fromAccent(RGB(hex: 0xB04F7D)), .nova)
        let shifted = AuraPalette.fromAccent(RGB(hex: 0x3366CC))
        XCTAssertNotEqual(shifted.d, shifted.a)
        XCTAssertEqual(AccentColor.fromRGBA([255, 255, 255, 255], width: 1, height: 1), AccentColor.fallback)
    }

    func testSetupDeclaresAskHermesUnlessHandOffIsOff() throws {
        var on = LiveSetup()
        on.handOff = true
        let withTool = try json(LiveProtocol.setup(on))
        let payload = try XCTUnwrap(withTool["setup"] as? [String: Any])
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        let declarations = try XCTUnwrap(tools.first?["functionDeclarations"] as? [[String: Any]])
        XCTAssertEqual(declarations.first?["name"] as? String, "ask_hermes")
        XCTAssertEqual(declarations.first?["behavior"] as? String, "NON_BLOCKING")

        var off = LiveSetup()
        off.handOff = false
        let without = try json(LiveProtocol.setup(off))
        let bare = try XCTUnwrap(without["setup"] as? [String: Any])
        XCTAssertNil(bare["tools"])
    }

    private func json(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
