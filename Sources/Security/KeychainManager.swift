import Foundation
import Security

/// Keys for values stored in the macOS Keychain.
enum KeychainKey: String, CaseIterable {
    case openaiAPIKey = "openai-api-key"
    case anthropicAPIKey = "anthropic-api-key"
    case groqAPIKey = "groq-api-key"
    case deepgramAPIKey = "deepgram-api-key"
    case elevenlabsAPIKey = "elevenlabs-api-key"
    case awsAccessKeyID = "aws-access-key-id"
    case awsSecretAccessKey = "aws-secret-access-key"
    case awsRegion = "aws-region"

    var displayName: String {
        switch self {
        case .openaiAPIKey: "OpenAI API Key"
        case .anthropicAPIKey: "Anthropic API Key"
        case .groqAPIKey: "Groq API Key"
        case .deepgramAPIKey: "Deepgram API Key"
        case .elevenlabsAPIKey: "ElevenLabs API Key"
        case .awsAccessKeyID: "AWS Access Key ID"
        case .awsSecretAccessKey: "AWS Secret Access Key"
        case .awsRegion: "AWS Region"
        }
    }
}

/// Manages secure storage of API keys in the macOS Keychain.
final class KeychainManager {
    static let shared = KeychainManager()

    private let service = "ai.sophiie.whispur"

    private init() {}

    // MARK: - CRUD

    func get(_ key: KeychainKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ key: KeychainKey, value: String) -> Bool {
        // Delete existing value first
        delete(key)

        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    @discardableResult
    func delete(_ key: KeychainKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    func has(_ key: KeychainKey) -> Bool {
        get(key) != nil
    }

    /// Check if all required keys for a provider are configured.
    func hasKeysFor(stt provider: STTProviderID) -> Bool {
        provider.keychainKeys.allSatisfy { has($0) }
    }

    func hasKeysFor(llm provider: LLMProviderID) -> Bool {
        provider.keychainKeys.allSatisfy { has($0) }
    }
}
