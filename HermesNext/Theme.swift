import SwiftUI

/// Rose light, fixed: the same palette as the Android app. The screens stay light in dark mode.
enum Rose {
    static let panel = Color(hex: 0xFFF9FC)
    static let soft = Color(hex: 0xFAEDF3)
    static let bubble = Color(hex: 0xF9E1ED)
    static let rose = Color(hex: 0xE8A1C0)
    static let petal = Color(hex: 0xF3BED4)
    static let deep = Color(hex: 0xB04F7D)
    static let chipText = Color(hex: 0x8E3F66)
    static let text = Color(hex: 0x643C50)
    /// Bold text and headings: a step darker than `text`.
    static let strong = Color(hex: 0x4A2638)
    static let muted = Color(hex: 0x866173)
    static let border = Color(hex: 0xEED6E2)
    static let field = Color(hex: 0xFFFCFD)
    static let online = Color(hex: 0x4F9A72)
}

/// The code pane's own colours: a deep plum editor that sits in the rose screen.
enum Editor {
    static let back = Color(hex: 0x2E1F2A)
    static let bar = Color(hex: 0x3B2835)
    static let edge = Color(hex: 0x4A3443)
    static let text = Color(hex: 0xF6E7EE)
    static let dim = Color(hex: 0xC9A9BA)
    static let gutter = Color(hex: 0x7D6071)
    static let comment = Color(hex: 0x9C8191)
    static let string = Color(hex: 0xF7C59F)
    static let number = Color(hex: 0xB9E3C6)
    static let keyword = Color(hex: 0xF59CC4)
    static let dots = [Color(hex: 0xF28FAD), Color(hex: 0xF7D08A), Color(hex: 0x9FD8B4)]
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

extension Link {
    var color: Color {
        switch self {
        case .online: Rose.online
        case .connecting: Rose.rose
        case .offline: Rose.muted
        case .signedOut, .unsupported: Rose.deep
        case .idle: Rose.border
        }
    }
}

/// A bot's picture in a ringed circle; the Hermes icon stands in for a bot without one.
struct BotAvatar: View {
    let image: UIImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image("HermesIcon").resizable().scaledToFill() }
        }
        .frame(width: size - 5, height: size - 5)
        .background(Rose.soft)
        .clipShape(Circle())
        .padding(2.5)
        .overlay(Circle().stroke(Rose.petal, lineWidth: 1.5))
    }
}

/// The small square status dot; it blinks while something is going on.
struct StatusDot: View {
    let color: Color
    var blinking = false
    @State private var dim = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 6, height: 6)
            .opacity(blinking && dim ? 0.25 : 1)
            .animation(blinking ? .easeInOut(duration: 0.52).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = blinking }
            .onChange(of: blinking) { _, now in dim = now }
    }
}

/// A round icon button. `filled` gives it a soft ground; `primary` makes it the screen's main action.
struct RoundIcon: View {
    let system: String
    let label: String
    var filled = false
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.app(size: primary ? 18 : 16, weight: .semibold))
                .foregroundStyle(primary ? Color.white : Rose.muted)
                .frame(width: 40, height: 40)
                .background(primary ? Rose.deep : filled ? Rose.soft : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct PillButton: View {
    let label: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label).font(.app(size: 14.5, weight: filled ? .bold : .regular)).foregroundStyle(filled ? Color.white : Rose.text)
                .padding(.horizontal, 16).frame(minHeight: 44)
                .background(filled ? Rose.deep : Rose.field)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(filled ? Color.clear : Rose.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The search field every list uses.
struct SearchField: View {
    @Binding var query: String
    let hint: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.app(size: 14)).foregroundStyle(Rose.muted)
            TextField("", text: $query, prompt: Text(hint).foregroundStyle(Rose.muted))
                .font(.app(size: 15)).foregroundStyle(Rose.text).tint(Rose.deep)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Rose.muted) }.buttonStyle(.plain).accessibilityLabel("지우기")
            }
        }
        .padding(.horizontal, 14).frame(minHeight: 46)
        .background(Rose.field).clipShape(Capsule()).overlay(Capsule().stroke(Rose.border, lineWidth: 1))
    }
}

/// A section's name over its rows, with an optional count beside it.
struct SectionTitle: View {
    let title: String
    var count: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.app(size: 12.5, weight: .bold)).foregroundStyle(Rose.chipText)
            if let count { Text(count).font(.app(size: 10.5, design: .monospaced)).foregroundStyle(Rose.muted) }
            Spacer()
        }
    }
}

struct EmptyState: View {
    let text: String

    var body: some View {
        VStack(spacing: 14) {
            Image("HermesIcon").resizable().frame(width: 44, height: 44).clipShape(Circle()).opacity(0.7)
            Text(text).font(.app(size: 14)).foregroundStyle(Rose.muted)
        }
        .frame(maxWidth: .infinity).padding(.top, 56)
    }
}

/// A line that reports the last action and clears itself.
struct NoticeBar: View {
    @Environment(Store.self) private var store

    var body: some View {
        if let notice = store.notice {
            Text(notice).font(.app(size: 13.5)).foregroundStyle(Rose.chipText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Rose.soft).clipShape(RoundedRectangle(cornerRadius: 14))
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(2.5))
                    if store.notice == notice { store.notice = nil }
                }
        }
    }
}

/// A card for one row of a menu list.
extension View {
    func roseCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Rose.field).clipShape(RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Rose.border, lineWidth: 1))
    }
}
