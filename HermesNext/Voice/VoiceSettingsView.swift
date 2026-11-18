import SwiftUI
import HermesVoiceCore

/// Voice, persona, language and the Gemini key. The key is the only value that goes in the Keychain.
struct VoiceSettingsView: View {
    @Environment(Store.self) private var store
    @State private var settings = VoiceSettingsStore.load()
    @State private var key = ""
    @State private var masked = GeminiKey.masked()
    @State private var notice: String?

    private var botKey: String? { store.profile?.lowercased() }
    private var botTitle: String { store.openBot?.title ?? "이 봇" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                keySection
                section("모델") { modelRow }
                section("목소리") { voiceList(binding: voiceBinding) }
                section("속도") { speedRow }
                section("성격") { personaBlock(persona: personaBinding) }
                section("언어") { languageRow }
                section("나") { assistantRow }
                section(botTitle) { perBotRow }
                section("통화") { toggles }
                soulNote
                previewButton
                if let notice {
                    Text(notice).font(.app(size: 13.5)).foregroundStyle(Rose.chipText)
                }
            }
            .padding(16)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Rose.panel.ignoresSafeArea())
        .navigationTitle("음성 대화")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, next in VoiceSettingsStore.save(next) }
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gemini 키").font(.app(size: 12.5, weight: .bold)).foregroundStyle(Rose.chipText)
            if let masked {
                Text("저장됨 \(masked)").font(.app(size: 14)).foregroundStyle(Rose.text)
            }
            SecureField("API 키", text: $key)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.app(size: 16))
                .padding(.horizontal, 14)
                .frame(minHeight: 48)
                .background(Rose.field)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Rose.border, lineWidth: 1))
            Text("무료 등급은 대화 내용이 Google의 제품 개선에 쓰일 수 있어요.")
                .font(.app(size: 13)).foregroundStyle(Rose.muted)
            HStack(spacing: 8) {
                PillButton(label: "저장", filled: true) {
                    GeminiKey.save(key)
                    key = ""
                    masked = GeminiKey.masked()
                }
                if masked != nil {
                    PillButton(label: "지우기") {
                        GeminiKey.clear()
                        masked = nil
                    }
                }
            }
        }
        .roseCard()
    }

    private var modelRow: some View {
        let selection: Binding<LiveModel> = $settings.model
        return Picker("모델", selection: selection) {
            ForEach(LiveModel.allCases, id: \.self) { model in
                Text(model.label).tag(model)
            }
        }
        .pickerStyle(.segmented)
    }

    private func voiceList(binding: Binding<Voice>) -> some View {
        VStack(spacing: 0) {
            ForEach(Voice.allCases, id: \.self) { voice in
                Button {
                    binding.wrappedValue = voice
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(voice.label).font(.app(size: 16)).foregroundStyle(Rose.text)
                                if Voice.verified.contains(voice) {
                                    Text("확인").font(.app(size: 11, weight: .medium)).foregroundStyle(Rose.chipText)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(Rose.soft).clipShape(Capsule())
                                }
                            }
                            Text("\(voice.rawValue) · \(voice.range)").font(.app(size: 12)).foregroundStyle(Rose.muted)
                        }
                        Spacer()
                        if binding.wrappedValue == voice {
                            Image(systemName: "checkmark").foregroundStyle(Rose.deep)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: "%.2f×", settings.speed)).font(.app(size: 15, design: .monospaced)).foregroundStyle(Rose.text)
            Slider(value: $settings.speed, in: VoiceSettings.minSpeed...VoiceSettings.maxSpeed, step: 0.05)
                .tint(Rose.deep)
        }
    }

    private func personaBlock(persona: Binding<Persona>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            let selection: Binding<PersonaPreset> = persona.preset
            Picker("성격", selection: selection) {
                ForEach(PersonaPreset.allCases, id: \.self) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            HStack {
                Text("말투 \(persona.wrappedValue.warmth)/3").font(.app(size: 14)).foregroundStyle(Rose.muted)
                Slider(value: warmth(persona), in: 0...3, step: 1).tint(Rose.deep)
            }
            if persona.wrappedValue.preset == .custom {
                TextField("직접 정한 말투", text: persona.custom, axis: .vertical)
                    .lineLimit(2...4)
                    .font(.app(size: 15))
                    .padding(12)
                    .background(Rose.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var languageRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            let selection: Binding<VoiceLanguage> = $settings.language
            Picker("언어", selection: selection) {
                ForEach(VoiceLanguage.allCases, id: \.self) { language in
                    Text(language.label).tag(language)
                }
            }
            if settings.language == .custom {
                TextField("BCP-47, 예: ko-KR", text: $settings.customLanguage)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.app(size: 15))
                    .padding(12)
                    .background(Rose.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private var assistantRow: some View {
        TextField("봇 이름이 없을 때 부를 이름", text: $settings.assistantName)
            .font(.app(size: 16))
            .padding(12)
            .background(Rose.panel)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var perBotRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let botKey {
                Toggle("\(botTitle)만 다르게", isOn: perBotOn(botKey))
                    .font(.app(size: 16)).tint(Rose.deep)
                if settings.perBot[botKey] != nil {
                    voiceList(binding: perBotVoice(botKey))
                    personaBlock(persona: perBotPersona(botKey))
                }
            } else {
                Text("열린 봇이 없어요. 전체 설정이 쓰여요.").font(.app(size: 14)).foregroundStyle(Rose.muted)
            }
        }
    }

    private var toggles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("질문을 Hermes에게 넘기기", isOn: $settings.handOff).font(.app(size: 16)).tint(Rose.deep)
            Toggle("자막", isOn: $settings.subtitles).font(.app(size: 16)).tint(Rose.deep)
            Toggle("스피커로 시작", isOn: $settings.speakerOn).font(.app(size: 16)).tint(Rose.deep)
        }
    }

    private var soulNote: some View {
        Text("이 봇의 SOUL.md는 서버 설정에서 바뀌어요. 통화가 시작될 때 그 내용을 읽어 와요.")
            .font(.app(size: 13)).foregroundStyle(Rose.muted)
            .padding(.horizontal, 4)
    }

    private var previewButton: some View {
        PillButton(label: "목소리 들어보기", filled: true) {
            let active = VoiceCenter.shared.mode != .hidden
            if active {
                notice = "통화 중에는 미리듣기를 할 수 없어요."
                return
            }
            if GeminiKey.load() == nil {
                notice = "Gemini 키를 먼저 저장해 주세요."
                return
            }
            VoiceCenter.shared.open(store: store, context: "", preview: true)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.app(size: 12.5, weight: .bold)).foregroundStyle(Rose.chipText)
            content()
        }
        .roseCard()
    }

    private var voiceBinding: Binding<Voice> {
        Binding(get: { settings.voice }, set: { settings.voice = $0 })
    }

    private var personaBinding: Binding<Persona> {
        Binding(get: { settings.persona }, set: { settings.persona = $0 })
    }

    private func warmth(_ persona: Binding<Persona>) -> Binding<Double> {
        Binding(get: { Double(persona.wrappedValue.warmth) }, set: { persona.wrappedValue.warmth = Int($0) })
    }

    private func perBotOn(_ key: String) -> Binding<Bool> {
        Binding(get: { settings.perBot[key] != nil }, set: { on in
            if on {
                settings.perBot[key] = BotVoice(voice: settings.voice, persona: settings.persona)
            } else {
                settings.perBot.removeValue(forKey: key)
            }
        })
    }

    private func perBotVoice(_ key: String) -> Binding<Voice> {
        Binding(get: { settings.perBot[key]?.voice ?? settings.voice }, set: { voice in
            var bot = settings.perBot[key] ?? BotVoice(voice: voice, persona: settings.persona)
            bot.voice = voice
            settings.perBot[key] = bot
        })
    }

    private func perBotPersona(_ key: String) -> Binding<Persona> {
        Binding(get: { settings.perBot[key]?.persona ?? settings.persona }, set: { persona in
            var bot = settings.perBot[key] ?? BotVoice(voice: settings.voice, persona: persona)
            bot.persona = persona
            settings.perBot[key] = bot
        })
    }
}

struct GeminiKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("음성 대화에는 Gemini API 키가 필요해요.").font(.app(size: 16)).foregroundStyle(Rose.text)
                SecureField("API 키", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.app(size: 16))
                    .padding(.horizontal, 14)
                    .frame(minHeight: 48)
                    .background(Rose.field)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Text("무료 등급은 대화 내용이 Google의 제품 개선에 쓰일 수 있어요.")
                    .font(.app(size: 13)).foregroundStyle(Rose.muted)
                PillButton(label: "저장하고 시작", filled: true) {
                    GeminiKey.save(key)
                    dismiss()
                }
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            .padding(20)
            .background(Rose.panel.ignoresSafeArea())
            .navigationTitle("Gemini 키")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
        .preferredColorScheme(.light)
        .tint(Rose.deep)
    }
}
