import XCTest
@testable import HermesVoiceCore

final class TextTests: XCTestCase {

    // MARK: persona

    func testAssemblyOrderIsFixed() {
        var settings = VoiceSettings()
        settings.language = .korean
        let text = PersonaBuilder.instructionsFor(botName: "한채린", role: nil, settings: settings, soulNote: "반말로 다정하게")

        let name = try! XCTUnwrap(text.range(of: "너는 한채린"))
        let preset = try! XCTUnwrap(text.range(of: "따뜻하고 다정한"))
        let strength = try! XCTUnwrap(text.range(of: "말투 강도 2/3"))
        let rules = try! XCTUnwrap(text.range(of: "연인 역할"))
        let handOff = try! XCTUnwrap(text.range(of: "ask_hermes"))
        let soul = try! XCTUnwrap(text.range(of: "이 사람에 대해 늘 기억할 것"))
        let language = try! XCTUnwrap(text.range(of: "기본 대답 언어"))

        XCTAssertTrue(name.lowerBound < preset.lowerBound)
        XCTAssertTrue(preset.lowerBound < strength.lowerBound)
        XCTAssertTrue(strength.lowerBound < rules.lowerBound)
        XCTAssertTrue(rules.lowerBound < handOff.lowerBound)
        XCTAssertTrue(handOff.lowerBound < soul.lowerBound)
        XCTAssertTrue(soul.lowerBound < language.lowerBound)
        XCTAssertTrue(text.hasSuffix(PersonaBuilder.languageRule(.korean)))
    }

    func testLanguageRuleIsAPolicyNotALock() {
        let rule = PersonaBuilder.languageRule(.korean)
        XCTAssertTrue(rule.contains("다른 언어로 말해 달라고 하면"))
        XCTAssertTrue(rule.contains("두 언어를 섞어 말해도"))
        XCTAssertTrue(rule.contains("가르치거나 번역할 때"))
        XCTAssertFalse(rule.contains("한국어로만"))
        XCTAssertFalse(rule.contains("Never answer in another language"))
    }

    func testCallWithoutProfileKnowsItsName() {
        var settings = VoiceSettings()
        settings.assistantName = "한채린"
        XCTAssertEqual(settings.nameFor(nil), "한채린")
        XCTAssertEqual(settings.nameFor("nova"), "nova")

        let text = PersonaBuilder.instructionsFor(botName: settings.nameFor(nil), role: nil, settings: settings)
        XCTAssertTrue(text.hasPrefix("너는 한채린"))
    }

    func testLanguageCodesAreNormalisedAndBadOnesFallBack() {
        XCTAssertEqual(VoiceLanguage.normalize("ko"), "ko-KR")
        XCTAssertEqual(VoiceLanguage.normalize("ZH-hant-tw"), "zh-Hant-TW")
        XCTAssertNil(VoiceLanguage.normalize("한국어"))

        var settings = VoiceSettings()
        settings.language = .custom
        settings.customLanguage = "!!"
        XCTAssertEqual(settings.languageCode(), "ko-KR")
        settings.customLanguage = "pt-br"
        XCTAssertEqual(settings.languageCode(), "pt-BR")
    }

    // MARK: hand-off

    func testSpeechStripsMarkdownTablesLinksAndCode() {
        let raw = """
        ## 결과
        | 항목 | 값 |
        | --- | --- |
        | 디스크 | 132GB |

        **서버** 상태는 [여기](https://example.com)에서 봐.

        ```bash
        df -h
        ```
        """
        let spoken = HermesHandOff.polish(raw)
        XCTAssertFalse(spoken.contains("|"))
        XCTAssertFalse(spoken.contains("https://"))
        XCTAssertFalse(spoken.contains("```"))
        XCTAssertTrue(spoken.contains("코드는 화면에 띄웠어요"))
        XCTAssertTrue(spoken.contains("132GB"))
    }

    func testFailureSpeechTellsTheTruth() {
        XCTAssertTrue(HermesHandOff.failureSpeech(.timeout).contains("90초"))
        XCTAssertTrue(HermesHandOff.failureSpeech(.unreachable).contains("연결이 안 돼"))
        XCTAssertTrue(HermesHandOff.failureSpeech(.error("boom")).contains("boom"))
    }

    func testCallRecordStartsWithSpeechNotALabel() {
        let record = HermesHandOff.callRecord(
            clock: "02:11", bot: "Nova",
            lines: ["나: 서버 디스크 얼마나 남았어?", "Nova: 132GB 남았어."]
        )
        XCTAssertEqual(record.components(separatedBy: "\n").first, "나: 서버 디스크 얼마나 남았어?")
        XCTAssertTrue(record.hasSuffix("[음성 통화 02:11 · Nova] 이 통화를 두 문장으로 요약해 줘."))
        XCTAssertEqual(HermesHandOff.callRecord(clock: "00:04", bot: "Nova", lines: ["   "]), "")
    }

    // MARK: context

    func testContextKeepsTheNewestAndStaysInsideItsBudget() {
        let long = String(repeating: "가", count: 170)
        let recent = (1...30).map { CallContext.Line(mine: true, text: "\($0) \(long)") }
        let block = CallContext.block(recent)
        XCTAssertLessThanOrEqual(block.count, CallContext.maxChars + 200)
        XCTAssertTrue(block.contains("나: 30 "))
        XCTAssertFalse(block.contains("나: 1 "))
        XCTAssertTrue(block.hasPrefix("참고:"))
    }

    func testContextCollapsesDuplicatesAndHandlesEmpty() {
        XCTAssertEqual(CallContext.block([]), "")
        XCTAssertEqual(CallContext.block([CallContext.Line(mine: true, text: "  ")]), "")
        let block = CallContext.block([
            CallContext.Line(mine: true, text: "뭐 해?"),
            CallContext.Line(mine: true, text: "뭐 해?"),
        ])
        XCTAssertEqual(block.components(separatedBy: "나: 뭐 해?").count - 1, 1)
    }

    // MARK: captions

    func testCaptionsNeverRunAheadOfTheAudio() {
        let timeline = CaptionTimeline()
        let text = "오늘 하루도 정말 고생 많았어 푹 쉬자"
        timeline.onTranscript(text, enqueuedNow: 0)
        timeline.onAudio(frames: 72_000, sampleRate: 24_000, enqueuedBefore: 0)

        var last = -1
        for played in stride(from: 0, through: 72_000, by: 2_400) {
            let revealed = timeline.revealedChars(playedFrames: Int64(played))
            let heardMs = Double(played) / 24
            XCTAssertGreaterThanOrEqual(revealed, last)
            for index in 0..<revealed {
                XCTAssertLessThan(timeline.estimatedStartMs(index), heardMs)
            }
            if revealed < text.count {
                XCTAssertGreaterThanOrEqual(timeline.estimatedStartMs(revealed), heardMs)
            }
            last = revealed
        }
        XCTAssertGreaterThan(timeline.revealedChars(playedFrames: 72_000), 0)
        XCTAssertEqual(CaptionTimeline().revealedChars(playedFrames: 0), 0)
    }

    func testNewTurnUsesItsOwnAudioClock() {
        let timeline = CaptionTimeline()
        timeline.onAudio(frames: 24_000, sampleRate: 24_000, enqueuedBefore: 0)
        timeline.onTranscript("첫 번째", enqueuedNow: 24_000)
        timeline.endTurn()

        timeline.onAudio(frames: 24_000, sampleRate: 24_000, enqueuedBefore: 72_000)
        timeline.onTranscript("두 번째", enqueuedNow: 96_000)
        XCTAssertEqual(timeline.currentText(), "두 번째")
        XCTAssertEqual(timeline.revealedChars(playedFrames: 72_000), 0)
    }

    // MARK: greeting

    func testGreetingKnowsTheTimeAndAsksNothingUnanswerable() {
        XCTAssertTrue(LiveMachine.greeting(hour: 8, hasHistory: false, seed: 0).contains("아침"))
        XCTAssertTrue(LiveMachine.greeting(hour: 12, hasHistory: false, seed: 0).contains("점심때"))
        XCTAssertTrue(LiveMachine.greeting(hour: 20, hasHistory: false, seed: 0).contains("저녁"))

        let noHistory = LiveMachine.greeting(hour: 12, hasHistory: false, seed: 1)
        XCTAssertTrue(noHistory.contains("인사만 하고"))
        XCTAssertTrue(noHistory.contains("답이 없을 수 있는 질문"))
        XCTAssertFalse(noHistory.contains("요즘 푹 빠져 있는지"))
    }
}
