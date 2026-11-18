import Foundation

/// The voices the app offers — the ones the Android sweep measured changing the audio.
/// An unknown name still returns audio, so the list is fixed rather than free text.
public enum Voice: String, CaseIterable, Sendable {
    case achernar = "Achernar", laomedeia = "Laomedeia", despina = "Despina", autonoe = "Autonoe"
    case sadachbia = "Sadachbia", leda = "Leda", sulafat = "Sulafat", umbriel = "Umbriel"
    case callirrhoe = "Callirrhoe", kore = "Kore", zephyr = "Zephyr", vindemiatrix = "Vindemiatrix"
    case aoede = "Aoede", erinome = "Erinome", rasalgethi = "Rasalgethi", schedar = "Schedar"
    case orus = "Orus", zubenelgenubi = "Zubenelgenubi", pulcherrima = "Pulcherrima", gacrux = "Gacrux"
    case achird = "Achird", fenrir = "Fenrir", puck = "Puck", enceladus = "Enceladus"
    case charon = "Charon", algieba = "Algieba", alnilam = "Alnilam", sadaltager = "Sadaltager"
    case algenib = "Algenib"

    public static let `default`: Voice = .kore
    public static let verified: [Voice] = [.kore, .zephyr, .leda, .aoede, .charon, .puck]
}

public enum LiveModel: String, CaseIterable, Sendable {
    case gemini38 = "gemini-3.8-live"
    case gemini31Flash = "gemini-3.1-flash-live-preview"

    public static let `default`: LiveModel = .gemini38
}

/// The languages a call may speak; `.custom` carries a free BCP-47 code.
public enum VoiceLanguage: String, CaseIterable, Sendable {
    case korean, english, japanese, spanish, french, german, custom

    public var code: String {
        switch self {
        case .korean: return "ko-KR"
        case .english: return "en-US"
        case .japanese: return "ja-JP"
        case .spanish: return "es-ES"
        case .french: return "fr-FR"
        case .german: return "de-DE"
        case .custom: return ""
        }
    }

    public var label: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "영어"
        case .japanese: return "일본어"
        case .spanish: return "스페인어"
        case .french: return "프랑스어"
        case .german: return "독일어"
        case .custom: return "직접 입력"
        }
    }

    public var native: String {
        switch self {
        case .korean: return "한국어"
        case .english: return "English"
        case .japanese: return "日本語"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .custom: return ""
        }
    }

    /// `ko`, `ko-kr`, `zh-Hant-TW` → `ko-KR`, `ko-KR`, `zh-Hant-TW`; nil when it is not a code.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else { return nil }
        let parts = trimmed.split(separator: "-").map(String.init)
        if parts.count == 1 {
            let lower = parts[0].lowercased()
            if let known = allCases.first(where: { $0.code.lowercased().hasPrefix(lower + "-") }) { return known.code }
        }
        return parts.enumerated().map { index, part in
            if index == 0 { return part.lowercased() }
            if part.count == 2 { return part.uppercased() }
            return part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: "-")
    }
}

public enum PersonaPreset: String, CaseIterable, Sendable {
    case warm, calm, friend, custom
    public var label: String {
        switch self {
        case .warm: return "다정·애교"
        case .calm: return "차분한 비서"
        case .friend: return "친구처럼"
        case .custom: return "직접 쓰기"
        }
    }
}

public struct Persona: Equatable, Sendable {
    public var preset: PersonaPreset = .warm
    public var warmth: Int = 2
    public var custom: String = ""

    public init(preset: PersonaPreset = .warm, warmth: Int = 2, custom: String = "") {
        self.preset = preset
        self.warmth = min(max(warmth, 0), 3)
        self.custom = custom
    }

    public static let `default` = Persona()
}

public struct BotVoice: Equatable, Sendable {
    public var voice: Voice
    public var persona: Persona
}

/// What a call runs with.
public struct VoiceSettings: Equatable, Sendable {
    public var model: LiveModel = .default
    public var speed: Float = 1.0
    public var voice: Voice = .default
    public var persona: Persona = .default
    public var handOff: Bool = true
    public var subtitles: Bool = true
    public var speakerOn: Bool = true
    public var perBot: [String: BotVoice] = [:]
    public var language: VoiceLanguage = .korean
    public var customLanguage: String = ""
    /// 봇 프로필 이름이 없는 통화에서 자신을 부를 이름.
    public var assistantName: String = ""

    public init() {}

    public func languageCode() -> String {
        switch language {
        case .custom: return VoiceLanguage.normalize(customLanguage) ?? VoiceLanguage.korean.code
        default: return language.code
        }
    }

    public func nameFor(_ bot: String?) -> String? {
        if let bot = bot?.trimmingCharacters(in: .whitespacesAndNewlines), !bot.isEmpty { return bot }
        let name = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func voiceFor(_ bot: String?) -> Voice {
        guard let bot, let override = perBot[bot] else { return voice }
        return override.voice
    }

    public func personaFor(_ bot: String?) -> Persona {
        guard let bot, let override = perBot[bot] else { return persona }
        return override.persona
    }

    public static let speeds: [Float] = [0.7, 0.85, 1.0, 1.15, 1.3, 1.5]
}
