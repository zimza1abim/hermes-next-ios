import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// The call screen's numbers and decisions, with no UIKit. The iOS views read these; the tests pin them
// to the Android source of truth (AuraParams table, springs, caption model, level smoothing).

public func formatClock(_ ms: Double) -> String {
    let total = Int((ms / 1000).rounded(.down))
    let clamped = max(total, 0)
    return String(format: "%02d:%02d", clamped / 60, clamped % 60)
}

public func statusLine(_ state: VoiceState) -> String {
    switch state.phase {
    case .idle: return "준비됨"
    case .connecting: return "연결하는 중…"
    case .listening: return state.muted ? "음소거됨" : "듣고 있어요"
    case .modelSpeaking: return "말하는 중"
    case .delegating(_, let request, _): return "Hermes가 확인 중 · " + String(request.prefix(18))
    case .reconnecting: return "다시 연결하는 중"
    case .ended: return "통화 종료"
    }
}

/// Top-bar status. Delegating's request lives on the chip, not here.
public func callStatus(_ state: VoiceState) -> String {
    switch state.phase {
    case .delegating: return "Hermes가 확인 중"
    case .listening:
        if state.muted { return "음소거됨" }
        if state.awaitingReply { return "생각하는 중" }
        return "듣고 있어요"
    case .connecting: return "연결하는 중"
    default: return statusLine(state)
    }
}

public func toolLabel(_ request: String) -> String {
    let folded = request.lowercased()
    if ["캘린더", "일정", "스케줄", "calendar"].contains(where: { folded.contains($0) }) { return "캘린더 확인 중" }
    if ["메일", "이메일", "mail"].contains(where: { folded.contains($0) }) { return "메일 확인 중" }
    if ["날씨", "weather"].contains(where: { folded.contains($0) }) { return "날씨 보는 중" }
    if ["검색", "찾아", "search"].contains(where: { folded.contains($0) }) { return "찾아보는 중" }
    if ["파일", "문서", "노트"].contains(where: { folded.contains($0) }) { return "문서 여는 중" }
    return "Hermes가 확인 중"
}

public func toolMeta(_ request: String) -> String? {
    let trimmed = request.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(18))
}

// MARK: - Levels

/// RMS → 0...1. Below −50 dBFS is 0, above −10 dBFS is 1.
public func normalizeLevel(_ rms: Float) -> Float {
    if rms <= 1e-5 { return 0 }
    let db = 20 * Float(log10(Double(rms)))
    return min(max((db + 50) / 40, 0), 1)
}

/// One-pole smoother. Rises with τ = 80 ms, falls with τ = 250 ms.
public struct LevelSmoother: Sendable {
    public var value: Float = 0
    public var upMs: Float
    public var downMs: Float

    public init(upMs: Float = 80, downMs: Float = 250) {
        self.upMs = upMs
        self.downMs = downMs
    }

    public mutating func step(target: Float, dtMs: Float) -> Float {
        let tau = target > value ? upMs : downMs
        let a = 1 - Float(exp(Double(-dtMs / tau)))
        value += (target - value) * a
        return value
    }

    public mutating func reset() { value = 0 }
}

public enum PCM {
    /// Little-endian signed 16-bit RMS, scaled so a full-scale square wave is 1.
    public static func rms(_ pcm: Data, from: Int = 0, to: Int? = nil) -> Float {
        let end = min(to ?? pcm.count, pcm.count)
        guard from < end else { return 0 }
        var sum = 0.0
        var count = 0
        var i = from
        pcm.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while i + 1 < end {
                let sample = Int16(bitPattern: UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
                sum += Double(sample) * Double(sample)
                count += 1
                i += 2
            }
        }
        guard count > 0 else { return 0 }
        return Float(min(1, max(0, (sum / Double(count)).squareRoot() / Double(Int16.max))))
    }
}

/// 20 ms playback windows. The call screen reads "what the speaker is saying now" from here.
public final class PlaybackMeter: @unchecked Sendable {
    public static let windowBytes = 960
    private let slots = 4096
    private var envEnd: [Int64]
    private var envVal: [Float]
    private var head = 0
    private var count = 0
    private let lock = NSLock()
    public private(set) var enqueued: Int64 = 0

    public init() {
        envEnd = Array(repeating: 0, count: slots)
        envVal = Array(repeating: 0, count: slots)
    }

    public func append(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        var from = 0
        while from < pcm.count {
            let to = min(pcm.count, from + Self.windowBytes)
            enqueued += Int64(to - from) / 2
            envEnd[head] = enqueued
            envVal[head] = PCM.rms(pcm, from: from, to: to)
            head = (head + 1) % slots
            count = min(count + 1, slots)
            from = to
        }
    }

    /// Barge-in: the queued audio is gone, so the envelope starts over.
    public func flush() {
        lock.lock(); defer { lock.unlock() }
        enqueued = 0
        count = 0
        head = 0
    }

    public func level(playedFrames played: Int64) -> Float {
        lock.lock(); defer { lock.unlock() }
        if count == 0 || played >= enqueued { return 0 }
        let start = (head - count + slots) % slots
        for k in 0..<count {
            let i = (start + k) % slots
            if envEnd[i] > played { return envVal[i] }
        }
        return 0
    }
}

// MARK: - Aura mood

public struct AuraParams: Equatable, Sendable {
    public var height: Float
    public var swell: Float
    public var flowSpeed: Float
    public var flowDir: Float
    public var edgeRipple: Float
    public var sweep: Float
    public var flash: Float
    public var brightness: Float
    public var saturation: Float

    public init(height: Float, swell: Float, flowSpeed: Float, flowDir: Float, edgeRipple: Float, sweep: Float, flash: Float, brightness: Float, saturation: Float) {
        self.height = height
        self.swell = swell
        self.flowSpeed = flowSpeed
        self.flowDir = flowDir
        self.edgeRipple = edgeRipple
        self.sweep = sweep
        self.flash = flash
        self.brightness = brightness
        self.saturation = saturation
    }
}

public enum AuraMood: String, CaseIterable, Sendable {
    case idle, connecting, listening, thinking, speaking, working, interrupted, muted, reconnecting, ended
}

public enum AuraMoods {
    public static let table: [AuraMood: AuraParams] = [
        .idle: AuraParams(height: 0.05, swell: 0, flowSpeed: 0.5, flowDir: 0, edgeRipple: 0, sweep: 0, flash: 0, brightness: 0.75, saturation: 0.9),
        .connecting: AuraParams(height: 0.22, swell: 0, flowSpeed: 0.5, flowDir: 0, edgeRipple: 0, sweep: 0, flash: 0, brightness: 0.75, saturation: 0.9),
        .listening: AuraParams(height: 0.38, swell: 0.05, flowSpeed: 0.6, flowDir: 0, edgeRipple: 1, sweep: 0, flash: 0, brightness: 0.80, saturation: 1),
        .thinking: AuraParams(height: 0.42, swell: 0.1, flowSpeed: 1.2, flowDir: 1, edgeRipple: 0, sweep: 0.5, flash: 0, brightness: 0.85, saturation: 1),
        .speaking: AuraParams(height: 0.50, swell: 0.9, flowSpeed: 1.0, flowDir: 0, edgeRipple: 0.2, sweep: 0, flash: 0, brightness: 1.10, saturation: 1),
        .working: AuraParams(height: 0.44, swell: 0.2, flowSpeed: 1.6, flowDir: 1, edgeRipple: 0, sweep: 1, flash: 0, brightness: 0.90, saturation: 1),
        .interrupted: AuraParams(height: 0.28, swell: 0, flowSpeed: 0.25, flowDir: 0, edgeRipple: 0.15, sweep: 0, flash: 0, brightness: 0.80, saturation: 1),
        .muted: AuraParams(height: 0.32, swell: 0, flowSpeed: 0, flowDir: 0, edgeRipple: 0, sweep: 0, flash: 0, brightness: 0.42, saturation: 0.45),
        .reconnecting: AuraParams(height: 0.26, swell: 0, flowSpeed: 0.3, flowDir: 0, edgeRipple: 0, sweep: 0, flash: 0, brightness: 0.50, saturation: 0.30),
        .ended: AuraParams(height: 0, swell: 0, flowSpeed: 0.3, flowDir: 0, edgeRipple: 0, sweep: 0, flash: 0, brightness: 0, saturation: 0.6),
    ]

    public static let interruptHoldMs: Double = 2_500

    /// Interrupted (and still listening, not muted) wins over speaking; delegating wins over muted.
    public static func moodOf(_ state: VoiceState, interruptedRecently: Bool) -> AuraMood {
        switch state.phase {
        case .idle: return .idle
        case .connecting: return .connecting
        case .reconnecting: return .reconnecting
        case .ended: return .ended
        case .listening where interruptedRecently && !state.muted: return .interrupted
        case .delegating: return .working
        case .modelSpeaking: return .speaking
        default:
            if state.queuedChunks > 0 { return .speaking }
            if state.muted { return .muted }
            if state.awaitingReply { return .thinking }
            return .listening
        }
    }
}

public struct UnitBezier: Equatable, Sendable {
    public var x1: Float
    public var y1: Float
    public var x2: Float
    public var y2: Float

    public static let linear = UnitBezier(x1: 0, y1: 0, x2: 1, y2: 1)
    /// Android `FastOutLinearInEasing`.
    public static let fastOutLinearIn = UnitBezier(x1: 0.4, y1: 0, x2: 1, y2: 1)
    /// The connect-rise curve, cubic (0.33, 1, 0.68, 1).
    public static let connectRise = UnitBezier(x1: 0.33, y1: 1, x2: 0.68, y2: 1)

    public init(x1: Float, y1: Float, x2: Float, y2: Float) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    public func value(_ x: Float) -> Float {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let dx = sample(t, x1, x2) - x
            let dt = derivative(t, x1, x2)
            if abs(dt) < 1e-5 { break }
            t = min(max(t - dx / dt, 0), 1)
        }
        return sample(t, y1, y2)
    }

    private func sample(_ t: Float, _ a: Float, _ b: Float) -> Float {
        let c = 3 * a
        let d = 3 * (b - a) - c
        let e = 1 - c - d
        return ((e * t + d) * t + c) * t
    }

    private func derivative(_ t: Float, _ a: Float, _ b: Float) -> Float {
        let c = 3 * a
        let d = 3 * (b - a) - c
        let e = 1 - c - d
        return (3 * e * t + 2 * d) * t + c
    }
}

/// Critically damped spring (damping ratio 1). One step over `dt` is the closed form, so it does not
/// drift with the frame rate. Stiffness 200 reaches ~95% in 330 ms; stiffness 1500 reaches ~90% in 100 ms.
public struct CriticallyDampedSpring: Equatable, Sendable {
    public var value: Float
    public var velocity: Float
    public var target: Float
    public var stiffness: Float

    public init(value: Float, velocity: Float = 0, target: Float, stiffness: Float) {
        self.value = value
        self.velocity = velocity
        self.target = target
        self.stiffness = stiffness
    }

    public mutating func step(dt: Float) {
        guard dt > 0, stiffness > 0 else { return }
        let w = Float(Double(stiffness).squareRoot())
        let x0 = value - target
        let v0 = velocity
        let e = Float(exp(Double(-w * dt)))
        let b = v0 + w * x0
        value = target + (x0 + b * dt) * e
        velocity = (v0 - w * b * dt) * e
    }
}

public enum AuraMotion: Equatable, Sendable {
    case spring(stiffness: Float)
    case tween(duration: Float, from: Float, elapsed: Float, easing: UnitBezier)
}

struct AuraChannel {
    var value: Float
    var velocity: Float = 0
    var target: Float
    var motion: AuraMotion

    mutating func retarget(_ target: Float, motion: AuraMotion) {
        self.target = target
        switch motion {
        case .spring(let stiffness):
            self.motion = .spring(stiffness: stiffness)
        case .tween(let duration, _, _, let easing):
            self.motion = .tween(duration: duration, from: value, elapsed: 0, easing: easing)
        }
    }

    mutating func snap(_ value: Float) {
        self.value = value
        self.target = value
        velocity = 0
    }

    mutating func step(dt: Float) {
        switch motion {
        case .spring(let stiffness):
            var spring = CriticallyDampedSpring(value: value, velocity: velocity, target: target, stiffness: stiffness)
            spring.step(dt: dt)
            value = spring.value
            velocity = spring.velocity
        case .tween(let duration, let from, let elapsed, let easing):
            let next = elapsed + dt
            let t = duration <= 0 ? 1 : min(max(next / duration, 0), 1)
            value = from + (target - from) * easing.value(t)
            velocity = 0
            motion = .tween(duration: duration, from: from, elapsed: next, easing: easing)
        }
    }
}

/// The nine aura values. `go` is called when the mood changes; `step` runs once per frame.
public final class AuraAnimator {
    public static let defaultStiffness: Float = 200
    public static let snapStiffness: Float = 1_500
    public static let connectSeconds: Float = 2
    public static let endSeconds: Float = 0.6
    public static let flashSeconds: Float = 0.9

    public private(set) var height: Float
    public private(set) var swell: Float
    public private(set) var flowSpeed: Float
    public private(set) var flowDir: Float
    public private(set) var edgeRipple: Float
    public private(set) var sweep: Float
    public private(set) var flash: Float
    public private(set) var brightness: Float
    public private(set) var saturation: Float

    private var channels: [String: AuraChannel] = [:]
    private var applied: String?

    public init(mood: AuraMood = .idle) {
        let p = AuraMoods.table[mood]!
        height = p.height
        swell = p.swell
        flowSpeed = p.flowSpeed
        flowDir = p.flowDir
        edgeRipple = p.edgeRipple
        sweep = p.sweep
        flash = 0
        brightness = p.brightness
        saturation = p.saturation
        for (name, value) in [
            ("height", p.height), ("swell", p.swell), ("flowSpeed", p.flowSpeed), ("flowDir", p.flowDir),
            ("edgeRipple", p.edgeRipple), ("sweep", p.sweep), ("flash", Float(0)),
            ("brightness", p.brightness), ("saturation", p.saturation),
        ] {
            channels[name] = AuraChannel(value: value, target: value, motion: .spring(stiffness: Self.defaultStiffness))
        }
    }

    public func go(mood: AuraMood, calm: Bool) {
        let key = "\(mood.rawValue)-\(calm)"
        guard key != applied else { return }
        applied = key
        let target = AuraMoods.table[mood]!
        let spec = Self.spec(mood)
        let speed: Float = calm ? 0 : target.flowSpeed
        let ripple: Float = calm ? 0 : target.edgeRipple
        let sweepT: Float = calm ? 0 : target.sweep
        let swellT: Float = calm ? 0 : target.swell
        if mood == .connecting && !calm {
            update("height") { channel in
                channel.snap(0.05)
                channel.retarget(target.height, motion: .tween(duration: Self.connectSeconds, from: 0.05, elapsed: 0, easing: .connectRise))
            }
        } else {
            update("height") { $0.retarget(target.height, motion: spec) }
        }
        retarget("swell", swellT, spec)
        retarget("flowSpeed", speed, spec)
        retarget("flowDir", target.flowDir, spec)
        retarget("edgeRipple", ripple, spec)
        retarget("sweep", sweepT, spec)
        retarget("brightness", target.brightness, spec)
        retarget("saturation", target.saturation, spec)
        publish()
    }

    /// Interrupt flash: snaps to 1 (0.35 when motion is reduced) and falls to 0 over 900 ms.
    public func flashNow(calm: Bool) {
        let start: Float = calm ? 0.35 : 1
        update("flash") { channel in
            channel.value = start
            channel.velocity = 0
            channel.retarget(0, motion: .tween(duration: Self.flashSeconds, from: start, elapsed: 0, easing: .linear))
        }
        publish()
    }

    public func step(dt: Float) {
        for key in channels.keys {
            update(key) { $0.step(dt: dt) }
        }
        publish()
    }

    private func retarget(_ name: String, _ target: Float, _ motion: AuraMotion) {
        update(name) { $0.retarget(target, motion: motion) }
    }

    private func update(_ name: String, _ body: (inout AuraChannel) -> Void) {
        guard var channel = channels[name] else { return }
        body(&channel)
        channels[name] = channel
    }

    private func publish() {
        height = channels["height"]?.value ?? height
        swell = channels["swell"]?.value ?? swell
        flowSpeed = channels["flowSpeed"]?.value ?? flowSpeed
        flowDir = channels["flowDir"]?.value ?? flowDir
        edgeRipple = channels["edgeRipple"]?.value ?? edgeRipple
        sweep = channels["sweep"]?.value ?? sweep
        flash = channels["flash"]?.value ?? flash
        brightness = channels["brightness"]?.value ?? brightness
        saturation = channels["saturation"]?.value ?? saturation
    }

    private static func spec(_ mood: AuraMood) -> AuraMotion {
        switch mood {
        case .interrupted: return .spring(stiffness: snapStiffness)
        case .ended: return .tween(duration: endSeconds, from: 0, elapsed: 0, easing: .fastOutLinearIn)
        default: return .spring(stiffness: defaultStiffness)
        }
    }
}

public struct AuraUniformValues: Equatable, Sendable {
    public var time: Float = 0
    public var flow: Float = 0
    public var height: Float = 0.05
    public var swell: Float = 0
    public var ripple: Float = 0
    public var sweep: Float = 0
    public var flash: Float = 0
    public var dir: Float = 0
    public var brightness: Float = 0.75
    public var saturation: Float = 1
    public var detail: Float = 4

    public init() {}
}

/// One display-link tick: smooth the levels, integrate the flow clock, fold in the animator.
/// Returns whether this tick should draw (low-power devices skip every other frame).
public final class CallFrameEngine {
    public private(set) var uniforms = AuraUniformValues()
    public private(set) var revealedChars = 0
    public private(set) var mic: Float = 0
    public private(set) var playback: Float = 0
    private var micS = LevelSmoother()
    private var playS = LevelSmoother()
    private var time: Float = 0
    private var flow: Float = 0
    private var odd = false

    public init() {}

    @discardableResult
    public func step(
        dtMs: Float,
        micRMS: Float,
        playbackRMS: Float,
        revealed: Int,
        animator: AuraAnimator,
        calm: Bool,
        detail: Float,
        skipEveryOther: Bool,
        heightMap: (Float) -> Float = { $0 }
    ) -> Bool {
        let dt = min(max(dtMs, 0), 100)
        animator.step(dt: dt / 1000)
        mic = micS.step(target: normalizeLevel(micRMS), dtMs: dt)
        playback = playS.step(target: normalizeLevel(playbackRMS), dtMs: dt)
        let seconds = dt / 1000
        time = (time + seconds).truncatingRemainder(dividingBy: 3600)
        flow = (flow + seconds * animator.flowSpeed).truncatingRemainder(dividingBy: 3600)
        var u = uniforms
        u.time = time
        u.flow = flow
        u.height = heightMap(animator.height)
        u.swell = animator.swell * playback
        u.ripple = animator.edgeRipple * (0.35 + 0.65 * mic)
        u.sweep = animator.sweep
        u.flash = animator.flash
        u.dir = animator.flowDir
        u.brightness = animator.brightness + (calm ? 0.25 * playback : 0)
        u.saturation = animator.saturation
        u.detail = detail
        uniforms = u
        if revealed != revealedChars { revealedChars = revealed }
        odd.toggle()
        if skipEveryOther && odd { return false }
        return true
    }
}

// MARK: - Colour

public struct RGB: Equatable, Sendable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(r: Float, g: Float, b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }

    public init(hex: UInt32) {
        r = Float((hex >> 16) & 0xFF) / 255
        g = Float((hex >> 8) & 0xFF) / 255
        b = Float(hex & 0xFF) / 255
    }

    public static func blend(_ a: RGB, _ b: RGB, _ t: Float) -> RGB {
        RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }
}

public struct AuraPalette: Equatable, Sendable {
    public var a: RGB
    public var b: RGB
    public var c: RGB
    public var d: RGB

    public static let nova = AuraPalette(
        a: RGB(hex: 0xB04F7D),
        b: RGB(hex: 0xE8A1C0),
        c: RGB(hex: 0xF3BED4),
        d: RGB(hex: 0x977CBD)
    )

    /// Other bots: four colours from one accent. b/c mix toward white; d is the hue shifted −65°.
    public static func fromAccent(_ accent: RGB) -> AuraPalette {
        if accent == RGB(hex: 0xB04F7D) { return nova }
        let white = RGB(r: 1, g: 1, b: 1)
        let hsl = rgbToHSL(accent)
        let secondary = hslToRGB((
            h: (hsl.h - 65 + 360).truncatingRemainder(dividingBy: 360),
            s: min(max(hsl.s * 0.87, 0), 1),
            l: min(max(hsl.l + 0.11, 0), 1)
        ))
        return AuraPalette(
            a: accent,
            b: RGB.blend(accent, white, 0.45),
            c: RGB.blend(accent, white, 0.68),
            d: secondary
        )
    }
}

func rgbToHSL(_ c: RGB) -> (h: Float, s: Float, l: Float) {
    let maxC = max(c.r, max(c.g, c.b))
    let minC = min(c.r, min(c.g, c.b))
    let l = (maxC + minC) / 2
    let delta = maxC - minC
    if delta == 0 { return (0, 0, l) }
    var h: Float
    if maxC == c.r {
        h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6)
    } else if maxC == c.g {
        h = (c.b - c.r) / delta + 2
    } else {
        h = (c.r - c.g) / delta + 4
    }
    h *= 60
    if h < 0 { h += 360 }
    let s = delta / (1 - abs(2 * l - 1))
    return (h, s, l)
}

func hslToRGB(_ hsl: (h: Float, s: Float, l: Float)) -> RGB {
    let c = (1 - abs(2 * hsl.l - 1)) * hsl.s
    let hp = hsl.h / 60
    let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
    let m = hsl.l - c / 2
    let (r, g, b): (Float, Float, Float)
    switch hp {
    case 0..<1: (r, g, b) = (c, x, 0)
    case 1..<2: (r, g, b) = (x, c, 0)
    case 2..<3: (r, g, b) = (0, c, x)
    case 3..<4: (r, g, b) = (0, x, c)
    case 4..<5: (r, g, b) = (x, 0, c)
    default: (r, g, b) = (c, 0, x)
    }
    return RGB(r: r + m, g: g + m, b: b + m)
}

/// One saturated colour from a bot picture. Washed-out pixels do not get a vote.
public enum AccentColor {
    public static let fallback = RGB(hex: 0xB04F7D)

    public static func fromRGBA(_ bytes: [UInt8], width: Int, height: Int) -> RGB {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return fallback }
        var red = 0.0, green = 0.0, blue = 0.0, weight = 0.0
        for i in 0..<(width * height) {
            let o = i * 4
            let r = Float(bytes[o]) / 255
            let g = Float(bytes[o + 1]) / 255
            let b = Float(bytes[o + 2]) / 255
            let maxC = max(r, max(g, b))
            let minC = min(r, min(g, b))
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let w = Double(saturation * saturation * (0.25 + maxC))
            red += Double(r) * w
            green += Double(g) * w
            blue += Double(b) * w
            weight += w
        }
        guard weight >= 1 else { return fallback }
        var color = RGB(
            r: Float(min(max(red / weight, 0), 1)),
            g: Float(min(max(green / weight, 0), 1)),
            b: Float(min(max(blue / weight, 0), 1))
        )
        let luminance = 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b
        if luminance < 0.28 {
            let by = 0.28 - luminance
            color = RGB(r: min(color.r + by, 1), g: min(color.g + by, 1), b: min(color.b + by, 1))
        }
        return color
    }
}

// MARK: - Captions

public enum CaptionRole: String, Sendable {
    case past, user, userLive, bot, botLive, botCut, notice, chip, hint
}

public struct CaptionItem: Equatable, Sendable {
    public var key: String
    public var role: CaptionRole
    public var text: String
    public var cutFrom: Int
    public var chipMeta: String?

    public init(key: String, role: CaptionRole, text: String, cutFrom: Int = -1, chipMeta: String? = nil) {
        self.key = key
        self.role = role
        self.text = text
        self.cutFrom = cutFrom
        self.chipMeta = chipMeta
    }
}

public enum CaptionModel: Equatable, Sendable {
    case centered(title: String, subtitle: String, hint: String)
    case lines([CaptionItem])
}

public func captionModel(
    state: VoiceState,
    botName: String,
    interrupt: InterruptMark?,
    interruptedRecently: Bool,
    liveBotText: String,
    clock: String
) -> CaptionModel {
    let lastBot = state.transcript.last { $0.speaker == .bot }?.text
    let lastMe = state.transcript.last { $0.speaker == .me }?.text
    let me = state.myPartial.trimmingCharacters(in: .whitespacesAndNewlines)
    let bot = (state.botPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? liveBotText : state.botPartial)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = state.transcript.count
    func past(_ text: String?) -> CaptionItem? {
        text.map { CaptionItem(key: "t-past-\(base)", role: .past, text: $0) }
    }

    switch state.phase {
    case .connecting, .idle:
        return .centered(title: "\(botName)에게", subtitle: "연결하는 중…", hint: "잠깐이면 돼요")
    case .reconnecting:
        return .centered(title: "잠깐 끊겼어요", subtitle: "다시 연결하는 중…", hint: "통화는 그대로 이어져요")
    case .ended:
        return .centered(title: "통화 종료", subtitle: clock, hint: state.notice ?? "")
    case .listening where interruptedRecently && interrupt != nil:
        let mark = interrupt!
        return .lines([
            CaptionItem(key: "cut-\(mark.seq)", role: .botCut, text: mark.text.trimmingCharacters(in: .whitespacesAndNewlines), cutFrom: mark.revealedChars),
            CaptionItem(key: "me-live", role: .userLive, text: me),
            CaptionItem(key: "hint", role: .hint, text: "말을 멈추고 듣는 중"),
        ])
    case .delegating(let callId, let request, _):
        var items: [CaptionItem] = []
        if let line = me.isEmpty ? lastMe : me { items.append(CaptionItem(key: "me-\(base)", role: .user, text: line)) }
        if let line = bot.isEmpty ? lastBot : bot { items.append(CaptionItem(key: "bot-\(base)", role: .bot, text: line)) }
        items.append(CaptionItem(key: "chip-\(callId)", role: .chip, text: toolLabel(request), chipMeta: toolMeta(request)))
        return .lines(items)
    case .modelSpeaking:
        return speakingLines(me: me, lastMe: lastMe, bot: bot, base: base)
    case .listening where state.queuedChunks > 0 || (!bot.isEmpty && !state.awaitingReply && me.isEmpty):
        return speakingLines(me: me, lastMe: lastMe, bot: bot, base: base)
    default:
        if state.muted {
            return .lines([
                past(lastBot),
                CaptionItem(key: "notice-mute", role: .notice, text: "마이크가 꺼져 있어요"),
                CaptionItem(key: "hint", role: .hint, text: "음소거 버튼을 누르면 다시 들을게요"),
            ].compactMap { $0 })
        }
        let hint: String
        if state.awaitingReply { hint = "생각하는 중" }
        else if !me.isEmpty { hint = "나 · 말하는 중" }
        else { hint = "듣고 있어요" }
        return .lines([
            past(lastBot),
            CaptionItem(key: "me-live", role: .userLive, text: me),
            CaptionItem(key: "hint", role: .hint, text: hint),
        ].compactMap { $0 })
    }
}

private func speakingLines(me: String, lastMe: String?, bot: String, base: Int) -> CaptionModel {
    var items: [CaptionItem] = []
    if let line = me.isEmpty ? lastMe : me { items.append(CaptionItem(key: "me-\(base)", role: .user, text: line)) }
    items.append(CaptionItem(key: "bot-live", role: .botLive, text: bot))
    return .lines(items)
}

public struct CaptionWord: Equatable, Sendable {
    public var start: Int
    public var text: String
}

public func captionWords(_ text: String) -> [CaptionWord] {
    var out: [CaptionWord] = []
    let chars = Array(text)
    var i = 0
    while i < chars.count {
        while i < chars.count && chars[i].isWhitespace { i += 1 }
        let start = i
        while i < chars.count && !chars[i].isWhitespace { i += 1 }
        if i > start { out.append(CaptionWord(start: start, text: String(chars[start..<i]))) }
    }
    return out
}

/// A word is drawn once its first character has been heard, or when it is the part an interruption cut off.
public func captionWordVisible(start: Int, revealed: Int, cutFrom: Int) -> Bool {
    let cut = cutFrom >= 0 && start >= cutFrom
    return start < revealed || cut
}

// MARK: - Settings codec

public enum VoiceSettingsCodec {
    public static func encode(_ settings: VoiceSettings) -> String {
        var perBot: [String: Any] = [:]
        for (bot, override) in settings.perBot {
            perBot[bot] = [
                "voice": override.voice.rawValue,
                "preset": override.persona.preset.rawValue,
                "warmth": override.persona.warmth,
                "custom": override.persona.custom,
            ]
        }
        let object: [String: Any] = [
            "model": settings.model.rawValue,
            "speed": Double(settings.speed),
            "voice": settings.voice.rawValue,
            "preset": settings.persona.preset.rawValue,
            "warmth": settings.persona.warmth,
            "custom": settings.persona.custom,
            "handOff": settings.handOff,
            "subtitles": settings.subtitles,
            "speaker": settings.speakerOn,
            "perBot": perBot,
            "language": settings.language.rawValue,
            "customLanguage": settings.customLanguage,
            "assistantName": settings.assistantName,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    public static func decode(_ raw: String) -> VoiceSettings {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return VoiceSettings() }
        var settings = VoiceSettings()
        if let model = json["model"] as? String, let parsed = LiveModel(rawValue: model) { settings.model = parsed }
        if let speed = number(json["speed"]) {
            settings.speed = min(max(Float(speed), VoiceSettings.minSpeed), VoiceSettings.maxSpeed)
        }
        if let voice = json["voice"] as? String, let parsed = Voice(rawValue: voice) { settings.voice = parsed }
        settings.persona = persona(json)
        if let handOff = json["handOff"] as? Bool { settings.handOff = handOff }
        if let subtitles = json["subtitles"] as? Bool { settings.subtitles = subtitles }
        if let speaker = json["speaker"] as? Bool { settings.speakerOn = speaker }
        if let language = json["language"] as? String, let parsed = VoiceLanguage(rawValue: language) { settings.language = parsed }
        if let custom = json["customLanguage"] as? String { settings.customLanguage = custom }
        if let name = json["assistantName"] as? String { settings.assistantName = String(name.prefix(20)) }
        if let map = json["perBot"] as? [String: Any] {
            var perBot: [String: BotVoice] = [:]
            for (bot, value) in map {
                guard let entry = value as? [String: Any] else { continue }
                let voice = (entry["voice"] as? String).flatMap(Voice.init(rawValue:)) ?? .default
                perBot[bot] = BotVoice(voice: voice, persona: persona(entry))
            }
            settings.perBot = perBot
        }
        return settings
    }

    private static func persona(_ json: [String: Any]) -> Persona {
        let preset = (json["preset"] as? String).flatMap(PersonaPreset.init(rawValue:)) ?? .warm
        let warmth = Int(number(json["warmth"]) ?? 2)
        let custom = json["custom"] as? String ?? ""
        return Persona(preset: preset, warmth: warmth, custom: custom)
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let number as Double: return number
        case let number as Int: return Double(number)
        default: return nil
        }
    }
}
