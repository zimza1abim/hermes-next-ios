import Foundation
import Security

/// The Gemini key, in the Keychain. The settings screen only ever shows the last four characters.
enum GeminiKey {
    private static let service = "dev.hermes.next.voice"
    private static let account = "gemini_api_key"

    static func load() -> String? {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { clear(); return }
        let data = Data(trimmed.utf8)
        let status = SecItemCopyMatching(base() as CFDictionary, nil)
        if status == errSecSuccess {
            SecItemUpdate(base() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else {
            var query = base()
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func clear() {
        SecItemDelete(base() as CFDictionary)
    }

    static func masked() -> String? {
        guard let key = load() else { return nil }
        return key.count <= 4 ? "••••" : "••••" + key.suffix(4)
    }

    private static func base() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

enum VoiceSettingsStore {
    private static let key = "voice_settings"

    static func load() -> VoiceSettings {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return VoiceSettings() }
        return VoiceSettingsCodec.decode(raw)
    }

    static func save(_ settings: VoiceSettings) {
        UserDefaults.standard.set(VoiceSettingsCodec.encode(settings), forKey: key)
    }
}
