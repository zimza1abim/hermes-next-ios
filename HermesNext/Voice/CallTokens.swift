import SwiftUI

/// The call screen's colours and sizes. Android `CallTokens`: the mock's CSS pixels are points here.
enum CallTokens {
    static let base = Color(hex: 0x0B0B10)
    static let baseDeep = Color(hex: 0x07070B)
    static let dot = Color.white.opacity(0).blend(Color(hex: 0xF3BED4), 0.10)
    static let dotGridHeight: CGFloat = 300

    static let textStrong = Color.white.opacity(0.92)
    static let textMuted = Color.white.opacity(0.60)
    static let textFaint = Color.white.opacity(0.40)
    static let captionPast = Color.white.opacity(0.28)
    static let captionUser = Color.white.opacity(0.46)
    static let captionUserLive = Color.white.opacity(0.62)
    static let captionHint = Color.white.opacity(0.52)
    static let captionCut: Double = 0.16
    static let captionNowStart: Double = 0.5
    static let captionNowTint = Color(hex: 0xF3BED4)
    static let caret = Color(hex: 0xE8A1C0)

    static let accent = Color(hex: 0xB04F7D)
    static let accentLight = Color(hex: 0xE8A1C0)
    static let accentHighlight = Color(hex: 0xF3BED4)
    static let secondary = Color(hex: 0x977CBD)
    static let avatarCore = Color(hex: 0xD77FA6)

    static let topBarTop: CGFloat = 10
    static let topBarHeight: CGFloat = 40
    static let screenHPadding: CGFloat = 22
    static let avatarDot: CGFloat = 22
    static let avatarRing: CGFloat = 1.5
    static let nameGap: CGFloat = 10
    static let statusDot: CGFloat = 6
    static let statusGap: CGFloat = 6
    static let timerPadH: CGFloat = 11
    static let timerPadV: CGFloat = 5
    static let timerRadius: CGFloat = 16

    static let captionTop: CGFloat = 68
    static let captionHeight: CGFloat = 270
    static let captionHPadding: CGFloat = 28
    static let captionLineGap: CGFloat = 14
    static let chipTopGap: CGFloat = 18
    static let hintTopGap: CGFloat = 16
    static let wordRise: CGFloat = 4
    static let wordBlur: CGFloat = 1.6
    static let cutBlur: CGFloat = 1

    static let chipRadius: CGFloat = 16
    static let chipPadStart: CGFloat = 12
    static let chipPadEnd: CGFloat = 16
    static let chipPadV: CGFloat = 9
    static let chipGap: CGFloat = 10
    static let chipSpinner: CGFloat = 16

    static let pillBottom: CGFloat = 20
    static let pillHeight: CGFloat = 72
    static let pillRadius: CGFloat = 36
    static let pillPadH: CGFloat = 10
    static let pillGap: CGFloat = 8
    static let pillButton: CGFloat = 56
    static let pillIcon: CGFloat = 26
    static let hangUpWidth: CGFloat = 76
    static let hangUpHeight: CGFloat = 56
    static let hangUpRadius: CGFloat = 28
    static let hangUp = Color(hex: 0xFF3B30)

    static let barTop: CGFloat = 10
    static let barHPadding: CGFloat = 16
    static let barHeight: CGFloat = 56
    static let barRadius: CGFloat = 28
    static let barPadStart: CGFloat = 12
    static let barPadEnd: CGFloat = 7
    static let barGap: CGFloat = 10
    static let barAvatar: CGFloat = 24
    static let barEnd: CGFloat = 38

    static let glass = Color.white.opacity(0.08)
    static let glassBorder = Color.white.opacity(0.10)
    static let error = Color(hex: 0xFF6B6B)
    static let reconnecting = Color(hex: 0x8E8E93)
    static let online = Color(hex: 0x4F9A72)

    static let wordReveal: Double = 0.28
    static let wordTint: Double = 0.42
    static let wordTintDelay: Double = 0.12
    static let cut: Double = 0.18
    static let chipShimmer: Double = 1.6
    static let spinner: Double = 0.9
    static let interruptHold: Double = 2.5
}

struct CallTypeScale {
    var caption: CGFloat
    var captionSecondary: CGFloat
    var past: CGFloat
    var user: CGFloat
    var hint: CGFloat
    var name: CGFloat
    var status: CGFloat
    var timer: CGFloat
    var chip: CGFloat
    var chipMeta: CGFloat
    var connectTitle: CGFloat
    var barName: CGFloat
    var barStatus: CGFloat
    var barTimer: CGFloat
    var captionTracking: CGFloat

    static let picked = CallTypeScale(
        caption: 37, captionSecondary: 30, past: 25, user: 19, hint: 17,
        name: 23, status: 16, timer: 17, chip: 19, chipMeta: 14, connectTitle: 33,
        barName: 18, barStatus: 14, barTimer: 17, captionTracking: -0.6
    )
    static let system = CallTypeScale(
        caption: 32, captionSecondary: 26, past: 21, user: 16, hint: 15,
        name: 20, status: 14, timer: 15, chip: 16, chipMeta: 12, connectTitle: 28,
        barName: 16, barStatus: 12, barTimer: 15, captionTracking: -0.6
    )

    @MainActor static var current: CallTypeScale { Fonts.shared.family == nil ? .system : .picked }
}

extension Color {
    /// `other` mixed over `self` by `amount` (0 keeps self, 1 is other).
    func blend(_ other: Color, _ amount: Double) -> Color {
        // The dot grid only needs the petal at 10% white-space; opacity is enough and stays in SwiftUI.
        other.opacity(amount)
    }
}
