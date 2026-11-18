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

    public init(voice: Voice, persona: Persona) {
        self.voice = voice
        self.persona = persona
    }
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
    public static let minSpeed: Float = 0.7
    public static let maxSpeed: Float = 1.5
}

extension Voice {
    /// Median F0 from the Android sweep, high to low. The settings screen shows a band, not the hertz.
    public var pitchHz: Int {
        switch self {
        case .achernar: return 274
        case .laomedeia: return 233
        case .despina: return 220
        case .autonoe: return 208
        case .sadachbia: return 205
        case .leda: return 204
        case .sulafat: return 203
        case .umbriel: return 202
        case .callirrhoe: return 200
        case .kore: return 199
        case .zephyr: return 199
        case .vindemiatrix: return 195
        case .aoede: return 187
        case .erinome: return 185
        case .rasalgethi: return 179
        case .schedar: return 166
        case .orus: return 155
        case .zubenelgenubi: return 145
        case .pulcherrima: return 139
        case .gacrux: return 133
        case .achird: return 131
        case .fenrir: return 128
        case .puck: return 120
        case .enceladus: return 119
        case .charon: return 116
        case .algieba: return 116
        case .alnilam: return 108
        case .sadaltager: return 97
        case .algenib: return 75
        }
    }

    public var label: String {
        switch self {
        case .achernar: return "아케르나르"
        case .laomedeia: return "라오메데이아"
        case .despina: return "데스피나"
        case .autonoe: return "아우토노에"
        case .sadachbia: return "사다크비아"
        case .leda: return "레다"
        case .sulafat: return "술라파트"
        case .umbriel: return "움브리엘"
        case .callirrhoe: return "칼리로에"
        case .kore: return "코레"
        case .zephyr: return "제피르"
        case .vindemiatrix: return "빈데미아트릭스"
        case .aoede: return "아오이데"
        case .erinome: return "에리노메"
        case .rasalgethi: return "라살게티"
        case .schedar: return "셰다르"
        case .orus: return "오루스"
        case .zubenelgenubi: return "주베넬게누비"
        case .pulcherrima: return "풀케리마"
        case .gacrux: return "가크룩스"
        case .achird: return "아치르드"
        case .fenrir: return "펜리르"
        case .puck: return "퍽"
        case .enceladus: return "엔켈라두스"
        case .charon: return "카론"
        case .algieba: return "알기에바"
        case .alnilam: return "알닐람"
        case .sadaltager: return "사달타거"
        case .algenib: return "알게니브"
        }
    }

    public var range: String {
        if pitchHz >= 185 { return "높은 편" }
        if pitchHz >= 140 { return "중간" }
        return "낮은 편"
    }
}

extension LiveModel {
    public var label: String {
        switch self {
        case .gemini38: return "3.8 Live"
        case .gemini31Flash: return "3.1 Flash Live"
        }
    }
}
