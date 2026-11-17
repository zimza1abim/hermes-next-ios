import Foundation

/// The Markdown an answer needs: headings, lists, quotes, tables, rules and code fences as blocks; bold,
/// inline code and links inside a line.
enum Markdown {
    struct Item: Hashable {
        var depth: Int
        /// The number of an ordered item ("3."), or nil for a bullet.
        var marker: String?
        var text: String
    }

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case items([Item])
        case quote(String)
        case fence(language: String, code: String)
        /// The first row is the header.
        case table([[String]])
        case rule
    }

    private static let heading = try! NSRegularExpression(pattern: "^#{1,6}\\s+")
    private static let bullet = try! NSRegularExpression(pattern: "^(\\s*)[-*]\\s+")
    private static let ordered = try! NSRegularExpression(pattern: "^(\\s*)(\\d{1,3})[.)]\\s+")
    private static let quote = try! NSRegularExpression(pattern: "^\\s*>\\s?")
    private static let rule = try! NSRegularExpression(pattern: "^\\s*([-*_])(\\s*\\1){2,}\\s*$")
    private static let tableRule = try! NSRegularExpression(pattern: "^\\s*\\|?\\s*:?-+:?\\s*(\\|\\s*:?-+:?\\s*)*\\|?\\s*$")
    private static let marks = try! NSRegularExpression(pattern: "\\*\\*|`|^#{1,6}\\s+|^\\s*>\\s?|^\\s*[-*]\\s+", options: .anchorsMatchLines)
    private static let spaces = try! NSRegularExpression(pattern: "\\s+")

    private static func match(_ regex: NSRegularExpression, _ line: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
    }

    private static func group(_ result: NSTextCheckingResult, _ index: Int, _ line: String) -> String {
        Range(result.range(at: index), in: line).map { String(line[$0]) } ?? ""
    }

    private static func after(_ result: NSTextCheckingResult, _ line: String) -> String {
        Range(result.range, in: line).map { String(line[$0.upperBound...]) } ?? line
    }

    /// `text` on one line with its Markdown marks removed, for a list preview.
    static func plain(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let bare = marks.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return spaces.stringByReplacingMatches(in: bare, range: NSRange(bare.startIndex..., in: bare), withTemplate: " ").trimmingCharacters(in: .whitespaces)
    }

    /// `text` as blocks, line by line. An unfinished code fence (an answer still streaming) is a fence already.
    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var paragraph: [String] = []
        func flush() {
            let joined = paragraph.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.paragraph(joined)) }
            paragraph = []
        }
        func trimmedStart(_ line: String) -> Substring { line.drop { $0 == " " || $0 == "\t" } }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = trimmedStart(line)
            if trimmed.hasPrefix("```") {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, !trimmedStart(lines[i]).hasPrefix("```") {
                    body.append(lines[i])
                    i += 1
                }
                out.append(.fence(language: String(trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).prefix(24)), code: body.joined(separator: "\n")))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if match(heading, line) != nil {
                flush()
                out.append(.heading(level: trimmed.prefix { $0 == "#" }.count, text: trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if match(rule, line) != nil {
                flush()
                out.append(.rule)
            } else if match(quote, line) != nil {
                flush()
                var quoted: [String] = []
                while i < lines.count, let found = match(quote, lines[i]) {
                    quoted.append(after(found, lines[i]))
                    i += 1
                }
                i -= 1
                out.append(.quote(quoted.joined(separator: "\n")))
            } else if trimmed.hasPrefix("|"), i + 1 < lines.count, match(tableRule, lines[i + 1]) != nil {
                flush()
                var rows = [cells(line)]
                i += 2
                while i < lines.count, trimmedStart(lines[i]).hasPrefix("|") {
                    rows.append(cells(lines[i]))
                    i += 1
                }
                i -= 1
                out.append(.table(rows))
            } else if match(bullet, line) != nil || match(ordered, line) != nil {
                flush()
                var items: [Item] = []
                while i < lines.count {
                    let current = lines[i]
                    if let found = match(bullet, current) {
                        items.append(Item(depth: group(found, 1, current).count / 2, marker: nil, text: after(found, current)))
                    } else if let found = match(ordered, current) {
                        items.append(Item(depth: group(found, 1, current).count / 2, marker: group(found, 2, current) + ".", text: after(found, current)))
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty, current.hasPrefix("  "), !items.isEmpty {
                        // An indented line continues the item above it.
                        items[items.count - 1].text += "\n" + current.trimmingCharacters(in: .whitespaces)
                    } else {
                        break
                    }
                    i += 1
                }
                i -= 1
                out.append(.items(items))
            } else {
                paragraph.append(line)
            }
            i += 1
        }
        flush()
        return out
    }

    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        return row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// One block's text with its inline Markdown, line breaks kept.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static let keywords: Set<String> = [
        "fun", "val", "var", "class", "object", "interface", "return", "if", "else", "when", "for", "while", "do", "in", "is", "as", "null", "true", "false",
        "def", "import", "from", "pass", "None", "True", "False", "elif", "try", "except", "finally", "with", "lambda", "yield", "async", "await", "raise",
        "function", "const", "let", "new", "this", "typeof", "export", "default", "extends", "implements", "static", "public", "private", "protected",
        "void", "int", "string", "bool", "boolean", "float", "double", "struct", "enum", "type", "switch", "case", "break", "continue", "throw", "catch",
        "package", "func", "go", "defer", "use", "pub", "fn", "impl", "mut", "match", "self", "then", "fi", "done", "echo", "select", "where", "guard", "nil",
    ]
    private static let token = try! NSRegularExpression(
        pattern: "(#.*$|//.*$|--\\s.*$)|(\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'|`[^`]*`)|\\b(\\d+(?:\\.\\d+)?)\\b|\\b([A-Za-z_][A-Za-z0-9_]*)\\b",
        options: .anchorsMatchLines)

    enum Tint { case comment, string, number, keyword }

    /// The ranges of `code` an editor would tint. Language-blind on purpose.
    static func tints(_ code: String) -> [(Range<String.Index>, Tint)] {
        token.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap { found in
            guard let range = Range(found.range, in: code) else { return nil }
            if found.range(at: 1).location != NSNotFound { return (range, .comment) }
            if found.range(at: 2).location != NSNotFound { return (range, .string) }
            if found.range(at: 3).location != NSNotFound { return (range, .number) }
            return keywords.contains(String(code[range])) ? (range, .keyword) : nil
        }
    }
}
