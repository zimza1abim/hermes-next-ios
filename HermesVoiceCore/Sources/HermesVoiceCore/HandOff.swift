import Foundation

/// One question handed to Hermes on behalf of the live call.
public struct HandOff: Equatable, Sendable {
    public var callId: String
    public var request: String
    public var submissionId: String
    public var surface: String = HermesHandOff.surface
}

public enum HandOffFailure: Equatable, Sendable {
    case timeout
    case error(String?)
    case unreachable
}

public struct VoiceTurn: Equatable, Sendable {
    public var text: String?
    public var error: String?

    public init(text: String?, error: String?) {
        self.text = text
        self.error = error
    }
}

/// Turns a live conversation's question into a Hermes turn, and a Hermes answer into something worth
/// reading out loud. Speech is not a transcript: markdown, tables, URLs and code read as noise.
public enum HermesHandOff {

    public static let surface = "voice-live"
    public static let timeoutMs: Double = 90_000

    /// The shortest answer worth speaking; below this the model is told to say it has nothing.
    public static let minChars = 2
    public static let maxChars = 3_000
    public static let softMaxChars = 2_000

    public static func polish(_ raw: String?) -> String {
        guard var text = raw else { return "" }

        // Fenced code: keep the fact, drop the listing.
        text = replace(text, pattern: "```[\\s\\S]*?```", with: "코드는 화면에 띄웠어요")
        text = replace(text, pattern: "`([^`]*)`", with: "$1")

        // Tables keep their words and lose their pipes: a row read aloud as "디스크 132GB" is useful,
        // a row read as pipes is noise, and dropping the row loses the number entirely.
        let lines = text.components(separatedBy: "\n").compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.range(of: "^[-: ]*\\|[-: |]*$", options: .regularExpression) != nil { return nil }
            guard trimmed.hasPrefix("|") else { return line }
            let cells = trimmed.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return cells.isEmpty ? nil : cells.joined(separator: " ")
        }
        text = lines.joined(separator: "\n")

        // Links keep their words, lose the address.
        text = replace(text, pattern: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1")
        text = replace(text, pattern: "https?://\\S+", with: "")

        // Markdown emphasis and headings.
        text = replace(text, pattern: "(?m)^#{1,6}\\s*", with: "")
        text = replace(text, pattern: "\\*\\*([^*]+)\\*\\*", with: "$1")
        text = replace(text, pattern: "__([^_]+)__", with: "$1")
        text = replace(text, pattern: "(?m)^\\s*[-*+]\\s+", with: "")
        text = replace(text, pattern: "(?m)^\\s*\\d+\\.\\s+", with: "")

        // Whitespace back to speech.
        text = replace(text, pattern: "[ \\t]+", with: " ")
        text = replace(text, pattern: "\\n{3,}", with: "\n\n")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > maxChars { text = String(text.prefix(maxChars)) + "…" }
        return text
    }

    /// What the bot says when Hermes produced nothing usable. The truth, never a consolation prize.
    public static func failureSpeech(_ failure: HandOffFailure) -> String {
        switch failure {
        case .timeout:
            return "확인하는 데 90초가 넘어서 못 받았어. 지금 다시 해볼까?"
        case .unreachable:
            return "지금 Hermes랑 연결이 안 돼서 확인하지 못했어."
        case .error(let message):
            let detail = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "확인하지 못했어. 잠깐 뒤에 다시 해볼까?" : "확인하지 못했어. \(detail)"
        }
    }

    /// What a finished call leaves in a session. The first line is something a person said, never a
    /// label: a session is titled from its content.
    public static func callRecord(clock: String, bot: String?, lines: [String]) -> String {
        let spoken = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return "" }
        let mark = (bot?.isEmpty ?? true) ? "음성 통화 \(clock)" : "음성 통화 \(clock) · \(bot!)"
        return spoken.joined(separator: "\n") + "\n\n[\(mark)] 이 통화를 두 문장으로 요약해 줘."
    }

    /// Hermes's answer, carried as the tool's result.
    public static func toolResult(callId: String, text: String, isError: Bool = false) -> String {
        var response: [String: Any] = ["result": text]
        if isError { response["error"] = text }
        let payload: [String: Any] = ["toolResponse": ["functionResponses": [[
            "id": callId, "name": "ask_hermes", "response": response,
        ]]]]
        return json(payload)
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
