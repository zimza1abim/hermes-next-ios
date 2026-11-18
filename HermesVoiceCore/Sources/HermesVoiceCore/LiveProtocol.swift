import Foundation

public struct ToolInvocation: Equatable, Sendable {
    public var id: String
    public var name: String
    public var request: String
}

public enum LiveEvent: Equatable, Sendable {
    case setupComplete
    case audio(Data, sampleRate: Int)
    case inputTranscript(String)
    case outputTranscript(String)
    case toolCall([ToolInvocation])
    case interrupted
    case turnComplete
    case goAway(seconds: Int?)
    case resumeHandle(String, resumable: Bool)
    case voiceActivity(String)
}

public struct LiveSetup: Sendable {
    public var model: LiveModel = .default
    public var voice: Voice = .default
    public var speed: Float = 1.0
    public var instructions: String = ""
    public var resumeHandle: String?
    public var languageCode: String = "ko-KR"
    public var handOff = true
    /// When true the tool is declared `NON_BLOCKING`, so the model can keep talking while Hermes works.
    public var asyncTools = true
    public var sessionResumption = true
    public var contextWindowCompression = true
    public var targetTokens = 12_800
    public var startSensitivity = "START_SENSITIVITY_HIGH"
    public var endSensitivity = "END_SENSITIVITY_HIGH"
    public var prefixPaddingMs = 40
    public var silenceDurationMs = 500

    public init() {}
}

public enum LiveProtocol {

    public static let inputSampleRate = 16_000
    public static let outputSampleRate = 24_000
    public static let askHermes = "ask_hermes"

    public static func endpoint(key: String, version: String = "v1beta") -> String {
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.\(version).GenerativeService.BidiGenerateContent?key=\(key)"
    }

    public static func setup(_ config: LiveSetup) -> String {
        var generation: [String: Any] = [
            "responseModalities": ["AUDIO"],
            "speechConfig": [
                "languageCode": config.languageCode,
                "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": config.voice.rawValue]],
            ],
        ]
        if config.speed != 1.0, var speech = generation["speechConfig"] as? [String: Any] {
            speech["speed"] = Double(config.speed)
            generation["speechConfig"] = speech
        }

        var payload: [String: Any] = [
            "model": "models/\(config.model.rawValue)",
            "generationConfig": generation,
            "inputAudioTranscription": [:],
            "outputAudioTranscription": [:],
            "systemInstruction": ["parts": [["text": config.instructions]]],
        ]
        if config.sessionResumption {
            var resumption: [String: Any] = [:]
            if let handle = config.resumeHandle, !handle.isEmpty { resumption["handle"] = handle }
            payload["sessionResumption"] = resumption
        }
        if config.contextWindowCompression {
            payload["contextWindowCompression"] = ["slidingWindow": ["targetTokens": config.targetTokens]]
        }
        payload["realtimeInputConfig"] = [
            "automaticActivityDetection": [
                "startOfSpeechSensitivity": config.startSensitivity,
                "endOfSpeechSensitivity": config.endSensitivity,
                "prefixPaddingMs": config.prefixPaddingMs,
                "silenceDurationMs": config.silenceDurationMs,
            ],
        ]
        if config.handOff {
            var declaration: [String: Any] = [
                "name": askHermes,
                "description": "내 데이터·파일·서버·일정·검색·기억이 필요한 질문을 Hermes에게 한국어로 그대로 넘긴다.",
                "parameters": [
                    "type": "OBJECT",
                    "properties": [
                        "request": [
                            "type": "STRING",
                            "description": "사용자가 물어본 내용을 한국어 그대로. 요약하거나 바꾸지 않는다.",
                        ],
                    ],
                    "required": ["request"],
                ],
            ]
            if config.asyncTools { declaration["behavior"] = "NON_BLOCKING" }
            payload["tools"] = [["functionDeclarations": [declaration]]]
        }
        return json(["setup": payload])
    }

    /// Reads one server frame. Anything unusable (keepalives, unknown shapes, invalid JSON) yields nothing:
    /// a malformed frame must never end a call.
    public static func parse(_ raw: String) -> [LiveEvent] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var out: [LiveEvent] = []

        if object["setupComplete"] != nil { out.append(.setupComplete) }

        if let content = object["serverContent"] as? [String: Any] {
            if let parts = (content["modelTurn"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for part in parts {
                    guard let inline = part["inlineData"] as? [String: Any],
                          let base64 = inline["data"] as? String, !base64.isEmpty,
                          let pcm = Data(base64Encoded: base64), !pcm.isEmpty else { continue }
                    let mime = inline["mimeType"] as? String ?? ""
                    let rate = rate(fromMime: mime) ?? outputSampleRate
                    out.append(.audio(pcm, sampleRate: rate))
                }
            }
            if let text = (content["inputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                out.append(.inputTranscript(text))
            }
            if let text = (content["outputTranscription"] as? [String: Any])?["text"] as? String, !text.isEmpty {
                out.append(.outputTranscript(text))
            }
            if content["interrupted"] as? Bool == true { out.append(.interrupted) }
            if content["turnComplete"] as? Bool == true { out.append(.turnComplete) }
        }

        if let calls = (object["toolCall"] as? [String: Any])?["functionCalls"] as? [[String: Any]] {
            let invocations: [ToolInvocation] = calls.compactMap { call in
                guard let name = call["name"] as? String, !name.isEmpty,
                      let id = call["id"] as? String, !id.isEmpty else { return nil }
                let request = (call["args"] as? [String: Any])?["request"] as? String ?? ""
                return ToolInvocation(id: id, name: name, request: request)
            }
            if !invocations.isEmpty { out.append(.toolCall(invocations)) }
        }

        if let goAway = object["goAway"] as? [String: Any] {
            out.append(.goAway(seconds: seconds(goAway["timeLeft"])))
        }

        if let activity = object["voiceActivity"] as? [String: Any],
           let type = activity["type"] as? String, !type.isEmpty {
            out.append(.voiceActivity(type))
        }

        if let update = object["sessionResumptionUpdate"] as? [String: Any],
           let handle = update["newHandle"] as? String, !handle.isEmpty {
            out.append(.resumeHandle(handle, resumable: update["resumable"] as? Bool ?? false))
        }

        return out
    }

    public static func textTurn(_ text: String) -> String {
        json(["clientContent": ["turns": [["role": "user", "parts": [["text": text]]]], "turnComplete": true]])
    }

    public static func audioChunk(_ pcm: Data) -> String {
        json(["realtimeInput": ["audio": [
            "mimeType": "audio/pcm;rate=\(inputSampleRate)",
            "data": pcm.base64EncodedString(),
        ]]])
    }

    public static func toolResult(callId: String, text: String, isError: Bool = false) -> String {
        HermesHandOff.toolResult(callId: callId, text: text, isError: isError)
    }

    static func rate(fromMime mime: String) -> Int? {
        guard let range = mime.range(of: "rate=(\\d+)", options: .regularExpression) else { return nil }
        return Int(mime[range].replacingOccurrences(of: "rate=", with: ""))
    }

    private static func seconds(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(Double(text.replacingOccurrences(of: "s", with: "")) ?? 0)
        default: return nil
        }
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Quota is a structured signal. A "429" or "quota" inside audio or a transcript is not one.
public enum Quota {
    /// True when the JSON has an `error` object whose `status` is RESOURCE_EXHAUSTED or whose `code` is 429.
    public static func frame(_ raw: String) -> Bool {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return false }
        if let status = error["status"] as? String,
           status.caseInsensitiveCompare("RESOURCE_EXHAUSTED") == .orderedSame {
            return true
        }
        if let code = error["code"] as? NSNumber, code.intValue == 429 { return true }
        if let code = error["code"] as? String,
           code == "429" || code.caseInsensitiveCompare("RESOURCE_EXHAUSTED") == .orderedSame {
            return true
        }
        return false
    }

    /// Websocket close. 1011/1008 plus RESOURCE_EXHAUSTED, a close code of 429, or a quota token
    /// in the close reason. The digits 429 inside a longer reason are not a match.
    public static func close(code: Int, reason: String) -> Bool {
        if code == 429 { return true }
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.range(of: "RESOURCE_EXHAUSTED", options: .caseInsensitive) != nil { return true }
        let serverClose = code == 1011 || code == 1008 || code == 0
        return serverClose && text.range(of: "quota", options: .caseInsensitive) != nil
    }

    /// A rejected resume handle. A quota close is not this, and a "1008" inside a sentence is not a code.
    public static func staleHandle(code: Int, reason: String) -> Bool {
        if close(code: code, reason: reason) { return false }
        if reason.localizedCaseInsensitiveContains("session not found") { return true }
        return code == 1008
    }
}
