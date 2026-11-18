import SwiftUI
import UIKit
import HermesVoiceCore

enum CallHaptics {
    static func connected() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func working() { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
    static func interrupt() { UISelectionFeedbackGenerator().selectionChanged() }
    static func hangUp() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.error)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { generator.notificationOccurred(.error) }
    }
    static func toggle() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func longPress() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

/// Words wrap onto the next line. A caption is a row of words, not one string, so each word can arrive on its own.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + lineSpacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + lineSpacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 18
            var y: CGFloat = step
            while y < min(size.height, CallTokens.dotGridHeight) {
                var x: CGFloat = step
                while x < size.width {
                    let rect = CGRect(x: x, y: y, width: 1.5, height: 1.5)
                    context.fill(Path(ellipseIn: rect), with: .color(CallTokens.dot))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

struct CallTopBar: View {
    let name: String
    let status: String
    let statusColor: Color
    let started: Date?
    let image: UIImage?
    let onName: () -> Void

    var body: some View {
        HStack(spacing: CallTokens.nameGap) {
            BotAvatar(image: image, size: CallTokens.avatarDot)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.app(size: CallTypeScale.current.name, weight: .medium))
                    .foregroundStyle(CallTokens.textStrong)
                    .lineLimit(1)
                HStack(spacing: CallTokens.statusGap) {
                    Circle().fill(statusColor).frame(width: CallTokens.statusDot, height: CallTokens.statusDot)
                    Text(status)
                        .font(.app(size: CallTypeScale.current.status))
                        .foregroundStyle(CallTokens.textMuted)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45) {
                CallHaptics.longPress()
                onName()
            }
            Spacer(minLength: 8)
            if let started {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    Text(formatClock(context.date.timeIntervalSince(started) * 1000))
                        .font(.app(size: CallTypeScale.current.timer, design: .monospaced))
                        .foregroundStyle(CallTokens.textStrong)
                        .padding(.horizontal, CallTokens.timerPadH)
                        .padding(.vertical, CallTokens.timerPadV)
                        .background(CallTokens.glass)
                        .clipShape(RoundedRectangle(cornerRadius: CallTokens.timerRadius))
                }
            }
        }
        .padding(.horizontal, CallTokens.screenHPadding)
        .frame(height: CallTokens.topBarHeight)
        .padding(.top, CallTokens.topBarTop)
    }
}

struct KineticCaptions: View {
    let model: CaptionModel
    let revealed: Int
    let subtitles: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CallTokens.captionLineGap) {
            switch model {
            case .centered(let title, let subtitle, let hint):
                Text(title).font(.app(size: CallTypeScale.current.connectTitle, weight: .medium)).foregroundStyle(CallTokens.textStrong)
                Text(subtitle).font(.app(size: CallTypeScale.current.captionSecondary)).foregroundStyle(CallTokens.textMuted)
                Text(hint).font(.app(size: CallTypeScale.current.hint)).foregroundStyle(CallTokens.captionHint).padding(.top, CallTokens.hintTopGap)
            case .lines(let items):
                ForEach(items, id: \.key) { item in
                    caption(item)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, CallTokens.captionHPadding)
    }

    @ViewBuilder private func caption(_ item: CaptionItem) -> some View {
        switch item.role {
        case .chip:
            WorkingChip(title: item.text, meta: item.chipMeta)
                .padding(.top, CallTokens.chipTopGap)
        case .hint, .notice:
            Text(item.text)
                .font(.app(size: CallTypeScale.current.hint))
                .foregroundStyle(item.role == .notice ? CallTokens.error : CallTokens.captionHint)
                .padding(.top, CallTokens.hintTopGap)
        default:
            if subtitles {
                KineticLine(text: item.text, revealed: revealed, cutFrom: item.cutFrom, role: item.role)
            }
        }
    }
}

struct KineticLine: View {
    let text: String
    let revealed: Int
    let cutFrom: Int
    let role: CaptionRole

    var body: some View {
        let words = captionWords(text)
        let scale = CallTypeScale.current
        FlowLayout(spacing: 6, lineSpacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                let shown = captionWordVisible(start: word.start, revealed: role == .botLive || role == .botCut ? revealed : .max, cutFrom: cutFrom)
                Text(word.text)
                    .font(.app(size: size(scale), weight: role == .bot || role == .botLive ? .medium : .regular))
                    .tracking(scale.captionTracking)
                    .foregroundStyle(color.opacity(shown ? 1 : (role == .botCut ? CallTokens.captionCut : 0.2)))
                    .blur(radius: shown || role != .botLive ? 0 : CallTokens.wordBlur)
                    .offset(y: shown || role != .botLive ? 0 : CallTokens.wordRise)
                    .animation(.easeOut(duration: CallTokens.wordReveal), value: shown)
            }
            if role == .botLive {
                Caret().frame(width: 2, height: size(scale) * 0.85)
            }
        }
    }

    private func size(_ scale: CallTypeScale) -> CGFloat {
        switch role {
        case .past: scale.past
        case .user, .userLive: scale.user
        case .hint, .notice: scale.hint
        case .bot: scale.captionSecondary
        default: scale.caption
        }
    }

    private var color: Color {
        switch role {
        case .past: CallTokens.captionPast
        case .user: CallTokens.captionUser
        case .userLive: CallTokens.captionUserLive
        case .botCut: CallTokens.captionNowTint
        case .botLive: CallTokens.textStrong
        default: CallTokens.textStrong
        }
    }
}

struct Caret: View {
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(CallTokens.caret)
            .opacity(on ? 1 : 0.15)
            .onAppear { withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true } }
    }
}

struct WorkingChip: View {
    let title: String
    let meta: String?
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: CallTokens.chipGap) {
            Spinner()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.app(size: CallTypeScale.current.chip, weight: .medium)).foregroundStyle(CallTokens.textStrong).lineLimit(1)
                if let meta, !meta.isEmpty {
                    Text(meta).font(.app(size: CallTypeScale.current.chipMeta)).foregroundStyle(CallTokens.textMuted).lineLimit(1)
                }
            }
        }
        .padding(.leading, CallTokens.chipPadStart)
        .padding(.trailing, CallTokens.chipPadEnd)
        .padding(.vertical, CallTokens.chipPadV)
        .background(CallTokens.glass.opacity(shimmer ? 1 : 0.65))
        .clipShape(RoundedRectangle(cornerRadius: CallTokens.chipRadius))
        .overlay(RoundedRectangle(cornerRadius: CallTokens.chipRadius).stroke(CallTokens.glassBorder, lineWidth: 1))
        .onAppear { withAnimation(.easeInOut(duration: CallTokens.chipShimmer).repeatForever(autoreverses: true)) { shimmer = true } }
    }
}

struct Spinner: View {
    @State private var on = false

    var body: some View {
        Circle().trim(from: 0.2, to: 0.85)
            .stroke(CallTokens.accentLight, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: CallTokens.chipSpinner, height: CallTokens.chipSpinner)
            .rotationEffect(.degrees(on ? 360 : 0))
            .onAppear { withAnimation(.linear(duration: CallTokens.spinner).repeatForever(autoreverses: false)) { on = true } }
    }
}

struct CallPill: View {
    let muted: Bool
    let onMic: () -> Void
    let onSpeaker: () -> Void
    let onKeyboard: () -> Void
    let onSubtitles: () -> Void
    let onHangUp: () -> Void

    var body: some View {
        HStack(spacing: CallTokens.pillGap) {
            HoldButton(system: muted ? "mic.slash.fill" : "mic.fill", label: muted ? "음소거 해제" : "음소거", onTap: onMic, onLong: onSpeaker)
            HoldButton(system: "keyboard", label: "글자로", onTap: onKeyboard, onLong: onSubtitles)
            HoldButton(
                system: "phone.down.fill",
                label: "통화 종료",
                tint: .white,
                background: CallTokens.hangUp,
                width: CallTokens.hangUpWidth,
                height: CallTokens.hangUpHeight,
                radius: CallTokens.hangUpRadius,
                onTap: onHangUp,
                onLong: nil
            )
        }
        .padding(.horizontal, CallTokens.pillPadH)
        .frame(height: CallTokens.pillHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: CallTokens.pillRadius))
        .overlay(RoundedRectangle(cornerRadius: CallTokens.pillRadius).stroke(CallTokens.glassBorder, lineWidth: 1))
        .padding(.horizontal, CallTokens.screenHPadding)
        .padding(.bottom, CallTokens.pillBottom)
    }
}

struct HoldButton: View {
    let system: String
    let label: String
    var tint: Color = .white
    var background: Color = CallTokens.glass
    var width: CGFloat = CallTokens.pillButton
    var height: CGFloat = CallTokens.pillButton
    var radius: CGFloat = CallTokens.pillButton / 2
    let onTap: () -> Void
    let onLong: (() -> Void)?
    @State private var down = false
    @State private var suppress = false

    var body: some View {
        Image(systemName: system)
            .font(.system(size: CallTokens.pillIcon, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: width, height: height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .scaleEffect(down ? 0.92 : 1)
            .animation(.spring(response: 0.21, dampingFraction: 0.42), value: down)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45, maximumDistance: 24, pressing: { pressing in
                down = pressing
            }, perform: {
                guard onLong != nil else { return }
                suppress = true
                CallHaptics.longPress()
                onLong?()
            })
            .onTapGesture {
                if suppress { suppress = false; return }
                CallHaptics.toggle()
                onTap()
            }
            .accessibilityLabel(label)
    }
}

struct CallBar: View {
    let name: String
    let status: String
    let started: Date?
    let image: UIImage?
    let animator: AuraAnimator
    let calm: Bool
    let lowPower: Bool
    let palette: AuraPalette
    let signals: () -> (mic: Float, playback: Float, revealed: Int)
    let onOpen: () -> Void
    let onHangUp: () -> Void

    var body: some View {
        ZStack {
            AuraLayer(
                animator: animator,
                calm: calm,
                detail: lowPower ? 2 : 4,
                halfRate: lowPower,
                mini: true,
                palette: palette,
                heightMap: { 0.18 + 0.24 * $0 },
                signals: signals
            )
            .clipShape(RoundedRectangle(cornerRadius: CallTokens.barRadius))
            HStack(spacing: CallTokens.barGap) {
                BotAvatar(image: image, size: CallTokens.barAvatar)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.app(size: CallTypeScale.current.barName, weight: .medium)).foregroundStyle(CallTokens.textStrong).lineLimit(1)
                    Text(status).font(.app(size: CallTypeScale.current.barStatus)).foregroundStyle(CallTokens.textMuted).lineLimit(1)
                }
                Spacer()
                if let started {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(formatClock(context.date.timeIntervalSince(started) * 1000))
                            .font(.app(size: CallTypeScale.current.barTimer, design: .monospaced))
                            .foregroundStyle(CallTokens.textStrong)
                    }
                }
                Button {
                    CallHaptics.hangUp()
                    onHangUp()
                } label: {
                    Image(systemName: "phone.down.fill").font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
                        .frame(width: CallTokens.barEnd, height: CallTokens.barEnd)
                        .background(CallTokens.hangUp).clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("통화 종료")
            }
            .padding(.leading, CallTokens.barPadStart)
            .padding(.trailing, CallTokens.barPadEnd)
        }
        .frame(height: CallTokens.barHeight)
        .padding(.horizontal, CallTokens.barHPadding)
        .padding(.top, CallTokens.barTop)
        .contentShape(RoundedRectangle(cornerRadius: CallTokens.barRadius))
        .onTapGesture(perform: onOpen)
    }
}
