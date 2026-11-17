import SwiftUI

/// An answer block by block: headings, lists, quotes, tables and code each drawn in their own way.
struct MarkdownView: View {
    let text: String

    /// Parsed answers by text, so a finished answer is not parsed again each time it is drawn.
    @MainActor private static var parsed: [String: [Markdown.Block]] = [:]

    private var blocks: [Markdown.Block] {
        if let known = MarkdownView.parsed[text] { return known }
        let blocks = Markdown.parse(text)
        if MarkdownView.parsed.count > 200 { MarkdownView.parsed.removeAll() }
        MarkdownView.parsed[text] = blocks
        return blocks
    }

    var body: some View {
        let blocks = blocks
        VStack(alignment: .leading, spacing: 13) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): body(text)
                case .heading(let level, let text): heading(level, text)
                case .items(let items): list(items)
                case .quote(let text): quote(text)
                case .fence(let language, let code): CodeBlock(language: language, code: code)
                case .table(let rows): table(rows)
                case .rule: Rectangle().fill(Rose.border).frame(height: 1).padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Inline Markdown in the body style: bold a step darker, inline code on a soft ground, links underlined.
    private func styled(_ text: String) -> AttributedString {
        var out = Markdown.inline(text)
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else {
                if run.link != nil {
                    out[run.range].foregroundColor = Rose.deep
                    out[run.range].underlineStyle = .single
                }
                continue
            }
            if intent.contains(.stronglyEmphasized) { out[run.range].foregroundColor = Rose.strong }
            if intent.contains(.code) {
                out[run.range].foregroundColor = Rose.chipText
                out[run.range].backgroundColor = Rose.soft
                out[run.range].font = .system(size: 14.5, design: .monospaced)
            }
        }
        return out
    }

    private func body(_ text: String) -> some View {
        Text(styled(text)).font(.app(size: 16)).lineSpacing(6).foregroundStyle(Rose.text).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heading(_ level: Int, _ text: String) -> some View {
        let size: CGFloat = level == 1 ? 21.5 : level == 2 ? 19 : 17
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 9) {
                // A petal marks a section; the two top levels also get a rule under them.
                RoundedRectangle(cornerRadius: 2).fill(Rose.rose).frame(width: 4, height: level <= 2 ? 20 : 16)
                Text(styled(text)).font(.app(size: size, weight: .bold)).foregroundStyle(Rose.strong)
            }
            if level <= 2 { Rectangle().fill(Rose.border).frame(height: 1) }
        }
        .padding(.top, level <= 2 ? 6 : 2)
    }

    private func list(_ items: [Markdown.Item]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                // The marker sits in its own column, so a wrapped line lines up with the text above it.
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    if let marker = item.marker {
                        Text(marker).font(.app(size: 16, weight: .semibold)).foregroundStyle(Rose.deep).frame(minWidth: 24, alignment: .leading)
                    } else {
                        Circle().fill(item.depth == 0 ? Rose.deep : Rose.rose).frame(width: 6, height: 6).frame(width: 18, alignment: .leading)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 5 }
                    }
                    Text(styled(item.text)).font(.app(size: 16)).lineSpacing(6).foregroundStyle(Rose.text)
                }
                .padding(.leading, CGFloat(min(item.depth, 4) * 16))
            }
        }
    }

    private func quote(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Rose.rose).frame(width: 4)
            Text(styled(text)).font(.app(size: 15)).lineSpacing(5).foregroundStyle(Rose.text).padding(.horizontal, 13).padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(Rose.soft).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// A table that scrolls sideways when it is wider than the screen.
    private func table(_ rows: [[String]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        return ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(styled(column < cells.count ? cells[column] : "")).font(.app(size: 14, weight: index == 0 ? .bold : .regular))
                                .foregroundStyle(index == 0 ? Rose.strong : Rose.text)
                                .frame(maxWidth: 240, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                    .background(index == 0 ? Rose.soft : index % 2 == 0 ? Rose.field : Color.clear)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Rose.border, lineWidth: 1))
    }
}

/// Code as an editor pane: a title bar with the language and a copy button, line numbers, tinted tokens.
private struct CodeBlock: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        let lines = code.components(separatedBy: "\n").count
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { Circle().fill(Editor.dots[$0]).frame(width: 9, height: 9) }
                Text(language.isEmpty ? "code" : language).font(.app(size: 11.5, design: .monospaced)).foregroundStyle(Editor.dim).padding(.leading, 6)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                } label: {
                    Label(copied ? "복사됨" : "복사", systemImage: copied ? "checkmark" : "doc.on.doc").font(.app(size: 11.5)).foregroundStyle(Editor.dim)
                        .padding(.horizontal, 10).frame(minHeight: 38)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 14).padding(.trailing, 6).background(Editor.bar)
            HStack(alignment: .top, spacing: 10) {
                if lines > 1 {
                    Text((1...lines).map(String.init).joined(separator: "\n")).font(.app(size: 13.5, design: .monospaced)).lineSpacing(4)
                        .foregroundStyle(Editor.gutter).multilineTextAlignment(.trailing).padding(.leading, 12)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(tinted).font(.app(size: 13.5, design: .monospaced)).lineSpacing(4).foregroundStyle(Editor.text)
                        .fixedSize(horizontal: true, vertical: true).padding(.leading, lines > 1 ? 0 : 14).padding(.trailing, 14)
                }
            }
            .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Editor.back).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Editor.edge, lineWidth: 1))
    }

    private var tinted: AttributedString {
        var out = AttributedString(code)
        for (range, tint) in Markdown.tints(code) {
            guard let lower = AttributedString.Index(range.lowerBound, within: out), let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            switch tint {
            case .comment: out[lower..<upper].foregroundColor = Editor.comment
            case .string: out[lower..<upper].foregroundColor = Editor.string
            case .number: out[lower..<upper].foregroundColor = Editor.number
            case .keyword: out[lower..<upper].foregroundColor = Editor.keyword
            }
        }
        return out
    }
}
