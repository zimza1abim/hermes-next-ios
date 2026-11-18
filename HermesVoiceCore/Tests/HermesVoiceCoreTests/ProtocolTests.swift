import XCTest
@testable import HermesVoiceCore

final class ProtocolTests: XCTestCase {

    func testSetupCarriesVoiceLanguageAndSensitivity() throws {
        var setup = LiveSetup()
        setup.voice = .leda
        setup.languageCode = "ja-JP"
        setup.instructions = "너는 테스트예요."

        let object = try json(LiveProtocol.setup(setup))
        let payload = try XCTUnwrap(object["setup"] as? [String: Any])
        XCTAssertEqual(payload["model"] as? String, "models/gemini-3.8-live")

        let generation = try XCTUnwrap(payload["generationConfig"] as? [String: Any])
        let speech = try XCTUnwrap(generation["speechConfig"] as? [String: Any])
        XCTAssertEqual(speech["languageCode"] as? String, "ja-JP")
        let voice = try XCTUnwrap((speech["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"] as? [String: Any])
        XCTAssertEqual(voice["voiceName"] as? String, "Leda")

        let realtime = try XCTUnwrap(payload["realtimeInputConfig"] as? [String: Any])
        let activity = try XCTUnwrap(realtime["automaticActivityDetection"] as? [String: Any])
        XCTAssertEqual(activity["silenceDurationMs"] as? Int, 500)
        XCTAssertEqual(activity["endOfSpeechSensitivity"] as? String, "END_SENSITIVITY_HIGH")
    }

    func testAudioFrameUsesTheRateTheServerNames() throws {
        let pcm = Data([1, 2, 3, 4])
        let frame = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(pcm.base64EncodedString())"}}]}}}"#
        let events = LiveProtocol.parse(frame)
        guard case .audio(let data, let rate)? = events.first else { return XCTFail("no audio: \(events)") }
        XCTAssertEqual(data, pcm)
        XCTAssertEqual(rate, 24_000)
    }

    func testMalformedFramesYieldNothingAndNeverThrow() {
        for raw in ["", "not json", "[]", "{}", #"{"serverContent":{}}"#, "{\"setupComplete\":"] {
            XCTAssertTrue(LiveProtocol.parse(raw).isEmpty, "expected empty for \(raw)")
        }
    }

    func testToolCallCarriesIdNameAndRequest() {
        let frame = #"{"toolCall":{"functionCalls":[{"id":"c1","name":"ask_hermes","args":{"request":"내 서버 디스크"}}]}}"#
        guard case .toolCall(let calls)? = LiveProtocol.parse(frame).first else { return XCTFail("no tool call") }
        XCTAssertEqual(calls.first?.id, "c1")
        XCTAssertEqual(calls.first?.name, "ask_hermes")
        XCTAssertEqual(calls.first?.request, "내 서버 디스크")
    }

    func testResumeHandleIsRead() {
        let frame = #"{"sessionResumptionUpdate":{"newHandle":"h-1","resumable":true}}"#
        guard case .resumeHandle(let handle, let resumable)? = LiveProtocol.parse(frame).first else {
            return XCTFail("no handle")
        }
        XCTAssertEqual(handle, "h-1")
        XCTAssertTrue(resumable)
    }

    func testTurnCompleteInterruptedAndVoiceActivity() {
        XCTAssertEqual(LiveProtocol.parse(#"{"serverContent":{"turnComplete":true}}"#), [.turnComplete])
        XCTAssertEqual(LiveProtocol.parse(#"{"serverContent":{"interrupted":true}}"#), [.interrupted])
        XCTAssertEqual(LiveProtocol.parse(#"{"voiceActivity":{"type":"ACTIVITY_END"}}"#), [.voiceActivity("ACTIVITY_END")])
    }

    func testGoAwayAcceptsSecondsOrString() {
        XCTAssertEqual(LiveProtocol.parse(#"{"goAway":{"timeLeft":"18s"}}"#), [.goAway(seconds: 18)])
        XCTAssertEqual(LiveProtocol.parse(#"{"goAway":{"timeLeft":12}}"#), [.goAway(seconds: 12)])
    }

    func testAudioAndTranscriptContaining429AreNotQuota() {
        let audio = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"QQ429quotaQQ"}}]}}}"#
        XCTAssertFalse(Quota.frame(audio))
        let transcript = #"{"serverContent":{"outputTranscription":{"text":"code 429 quota check"}}}"#
        XCTAssertFalse(Quota.frame(transcript))
        XCTAssertEqual(LiveProtocol.parse(transcript), [.outputTranscript("code 429 quota check")])
        let messageOnly = #"{"error":{"code":400,"message":"see quota 429 in the text","status":"INVALID_ARGUMENT"}}"#
        XCTAssertFalse(Quota.frame(messageOnly))
    }

    func testQuotaIsTheErrorObjectOrTheClose() {
        XCTAssertTrue(Quota.frame(#"{"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}"#))
        XCTAssertTrue(Quota.frame(#"{"error":{"status":"RESOURCE_EXHAUSTED"}}"#))
        XCTAssertTrue(Quota.close(code: 1011, reason: "RESOURCE_EXHAUSTED"))
        XCTAssertTrue(Quota.close(code: 1008, reason: "RESOURCE_EXHAUSTED"))
        XCTAssertTrue(Quota.close(code: 429, reason: ""))
        XCTAssertTrue(Quota.close(code: 1011, reason: "quota exceeded"))
        XCTAssertFalse(Quota.close(code: 1006, reason: "the log says 429"))
        XCTAssertFalse(Quota.close(code: 1000, reason: "closed 429"))
        XCTAssertFalse(Quota.staleHandle(code: 1006, reason: "mention 1008 in a sentence"))
        XCTAssertTrue(Quota.staleHandle(code: 1008, reason: "session not found"))
        XCTAssertFalse(Quota.staleHandle(code: 1008, reason: "RESOURCE_EXHAUSTED"))
    }

    func testResampleLeaves24kHzAndExpands16kHz() {
        let pcm = Data(repeating: 0, count: 32)
        XCTAssertEqual(PCM.resample(pcm, from: 24_000, to: 24_000), pcm)
        XCTAssertEqual(PCM.resample(pcm, from: 16_000, to: 24_000).count, 48)
    }

    private func json(_ text: String) throws -> [String: Any] {
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
