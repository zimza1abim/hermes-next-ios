import Foundation

/// What a call knows before it starts: the last exchanges of the open chat, as background only.
public enum CallContext {

    public static let maxChars = 1_200
    private static let header = "참고: 방금 전에 이 사람과 나눈 대화야. 맥락으로만 쓰고, 먼저 꺼내지는 마."
    private static let lineChars = 180

    public struct Line: Equatable, Sendable {
        public var mine: Bool
        public var text: String
        public init(mine: Bool, text: String) {
            self.mine = mine
            self.text = text
        }
    }

    public static func block(_ recent: [Line], titles: [String] = []) -> String {
        var lines: [String] = []
        for line in recent {
            let flattened = line.text
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if flattened.isEmpty { continue }
            let rendered = (line.mine ? "나: " : "봇: ") + String(flattened.prefix(lineChars))
            if lines.last != rendered { lines.append(rendered) }
        }

        var topics: [String] = []
        for title in titles {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !topics.contains(trimmed) { topics.append(trimmed) }
            if topics.count == 5 { break }
        }

        if lines.isEmpty && topics.isEmpty { return "" }

        // Newest first while filling: a fresh line matters more than an old one.
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            if used + line.count + 1 > maxChars { break }
            kept.append(line)
            used += line.count + 1
        }
        kept.reverse()

        var out = header
        for line in kept { out += "\n" + line }
        if !topics.isEmpty && used < maxChars - 40 {
            out += "\n지난 대화 주제: " + String(topics.joined(separator: ", ").prefix(160))
        }
        return out
    }
}
