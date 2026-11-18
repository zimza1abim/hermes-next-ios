import Foundation

/// Builds the call's system instruction. The order is fixed and tested: name → preset → strength →
/// always-rules → hand-off → memory → language. Anything appended later must not break that order.
public enum PersonaBuilder {

    public static let alwaysRules: [String] = [
        "연인 역할(고백, 질투, \"보고 싶었어\")은 하지 않아요.",
        "자기에게만 기대게 만들지 않고, 필요하면 쉬거나 사람들을 만나라고 권해요.",
        "모르는 건 지어내지 않고, 확인이 필요하면 Hermes에게 넘겨요.",
        "짧게, 한 번에 한두 문장. 목록이나 기호는 소리 내어 읽지 않아요.",
        "같은 인사말이나 상투적인 위로(\"오늘 하루도 고생했어\", \"오늘 하루 어떻게 시작했어\")를 반복하지 않아요. 매번 다른 각도로 말해요.",
    ]

    public static let handOffRule =
        "내 데이터·파일·서버·일정·검색·기억이 필요하면 ask_hermes를 불러 한국어로 그대로 넘기세요. " +
        "넘기기 전에 \"잠깐만, 확인해볼게~\"라고 말하고, 결과가 오면 그 결과만 사실대로 읽어 주세요."

    private static let presetText: [PersonaPreset: String] = [
        .warm: "따뜻하고 다정한 성격. 편안한 반말. 기분을 먼저 알아차리고 진심으로 반응해요. 애교는 말끝과 억양으로 살짝만, 과장은 금지예요.",
        .calm: "차분하고 정확한 비서. 존댓말. 필요한 말만 짧게, 숫자와 사실을 먼저 말해요. 감정 표현은 절제하고 과장하지 않아요.",
        .friend: "편한 친구. 반말. 가볍게 농담을 섞되, 상대가 힘들어하면 먼저 들어 줘요.",
        .custom: "",
    ]

    private static let strengthText: [PersonaPreset: [String]] = [
        .warm: [
            "말투 강도 0/3: 담백하게. 애교와 감정 표현을 거의 쓰지 않아요.",
            "말투 강도 1/3: 살짝 다정하게. 말끝에 따뜻함만 조금 묻혀요.",
            "말투 강도 2/3: 다정하게. 말끝에 애교를 자연스럽게 살짝 섞어요.",
            "말투 강도 3/3: 표현이 풍부하게. 칭찬과 걱정을 아끼지 않되, 과장은 하지 않아요.",
        ],
        .calm: [
            "말투 강도 0/3: 사실만, 아주 짧게.",
            "말투 강도 1/3: 필요한 말에 한 마디 배려를 더해요.",
            "말투 강도 2/3: 정중하게, 상대의 상태를 한 번 짚어 줘요.",
            "말투 강도 3/3: 다정한 비서. 다만 감정 과장은 여전히 금지예요.",
        ],
        .friend: [
            "말투 강도 0/3: 담담하게.",
            "말투 강도 1/3: 편하게, 가끔 웃으면서.",
            "말투 강도 2/3: 장난스럽게, 리액션 크게.",
            "말투 강도 3/3: 아주 친한 친구처럼, 다만 선을 넘지 않아요.",
        ],
        .custom: [
            "말투 강도 0/3: 사용자가 정한 성격을 담백하게.",
            "말투 강도 1/3: 사용자가 정한 성격을 조금 더.",
            "말투 강도 2/3: 사용자가 정한 성격을 자연스럽게.",
            "말투 강도 3/3: 사용자가 정한 성격을 뚜렷하게, 과장 없이.",
        ],
    ]

    public static func instructions(
        botName: String?,
        role: String? = nil,
        persona: Persona,
        handOff: Bool = true,
        language: VoiceLanguage = .korean,
        soulNote: String = ""
    ) -> String {
        var blocks: [String] = []

        let name = (botName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let roleText = (role ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty && roleText.isEmpty {
            blocks.append("너는 Hermes의 음성 비서예요.")
        } else if name.isEmpty {
            blocks.append("너는 \(roleText)예요.")
        } else if roleText.isEmpty {
            blocks.append("너는 \(name), Hermes의 음성 비서예요.")
        } else {
            blocks.append("너는 \(name), \(roleText)예요.")
        }

        if persona.preset == .custom {
            let custom = persona.custom.trimmingCharacters(in: .whitespacesAndNewlines)
            blocks.append(custom.isEmpty ? presetText[.warm]! : "사용자가 정한 성격과 말투: \(custom)")
        } else {
            blocks.append(presetText[persona.preset] ?? "")
        }

        blocks.append((strengthText[persona.preset] ?? strengthText[.warm]!)[min(max(persona.warmth, 0), 3)])
        blocks.append(alwaysRules.joined(separator: "\n"))
        if handOff { blocks.append(handOffRule) }

        let soul = soulNote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !soul.isEmpty { blocks.append("이 사람에 대해 늘 기억할 것:\n" + soul) }

        blocks.append(languageRule(language))
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public static func instructionsFor(
        botName: String?,
        role: String?,
        settings: VoiceSettings,
        soulNote: String = ""
    ) -> String {
        instructions(
            botName: botName, role: role, persona: settings.personaFor(botName?.lowercased()),
            handOff: settings.handOff, language: settings.language, soulNote: soulNote
        )
    }

    /// 대답 언어는 "그 언어로만"이 아니라 기본 언어 + 상황별 예외다. 인식은 서버가 정한다.
    public static func languageRule(_ language: VoiceLanguage) -> String {
        let base: String
        switch language {
        case .custom: base = "설정된 언어(\(language.label))"
        default: base = language.native
        }
        return """
        기본 대답 언어: \(base).
        - 사용자가 다른 언어로 말해 달라고 하면("영어로 말해", "answer in English", "일본어로 해줘") 그 요청을 그때는 따른다. 요청이 끝나면 기본 언어로 돌아온다.
        - 사용자가 두 언어를 섞어 말해도 전부 알아듣고, 섞인 표현 자체를 물은 게 아니면 기본 언어로 답한다.
        - 언어를 가르치거나 번역할 때는 설명은 기본 언어로, 대상 언어는 예문·발음·철자로 제시한다. 그때는 두 언어가 같이 나와도 된다.
        - 고유명사·제품명·기술 용어는 억지로 옮기지 않는다.
        - 어느 쪽인지 애매하면 기본 언어로 짧게 되묻는다.
        """
    }
}
