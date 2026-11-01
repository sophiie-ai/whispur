import Foundation
import SwiftUI

// MARK: - Secret storage

/// The subset of Keychain behaviour the provider setup UI needs. The app
/// uses `KeychainManager`; tests and renders use an in-memory store so they
/// never touch the user's real Keychain items.
protocol SecretStore: AnyObject {
    func get(_ key: KeychainKey) -> String?
    @discardableResult func set(_ key: KeychainKey, value: String) -> Bool
    @discardableResult func delete(_ key: KeychainKey) -> Bool
}

extension KeychainManager: SecretStore {}

extension KeychainKey {
    /// Secrets are masked once saved. The AWS region is plain configuration
    /// that happens to live next to the Bedrock key.
    var isSecret: Bool {
        self != .awsRegion
    }

    /// Short label shown above the field inside a provider panel.
    var fieldLabel: String {
        self == .awsRegion ? "AWS Region" : "API Key"
    }

    var placeholder: String {
        switch self {
        case .openaiAPIKey: "Paste your OpenAI key (sk-...)"
        case .anthropicAPIKey: "Paste your Anthropic key (sk-ant-...)"
        case .groqAPIKey: "Paste your Groq key (gsk_...)"
        case .deepgramAPIKey: "Paste your Deepgram key"
        case .elevenlabsAPIKey: "Paste your ElevenLabs key"
        case .mistralAPIKey: "Paste your Mistral key"
        case .awsBedrockAPIKey: "Paste your Bedrock API key"
        case .awsRegion: "us-east-1"
        }
    }
}

// MARK: - Masking

enum KeyMasking {
    static let dots = "••••••••"

    /// Masks a stored secret down to its last four characters, for example
    /// `••••••••abcd`. Short values show dots only so most of the secret is
    /// never on screen.
    static func masked(_ secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return dots }
        return dots + String(trimmed.suffix(4))
    }
}

// MARK: - Commit rules

/// When a typed key is written to the Keychain. Keys save on Return, on
/// focus loss, and shortly after a paste. Ordinary typing never saves on its
/// own, so a half-typed key is not stored mid-word.
enum KeyEntryCommitPolicy {
    /// Delay after a paste before saving, so a paste followed by a quick
    /// correction saves once.
    static let pasteDebounce: Duration = .milliseconds(400)

    /// The value to store for a draft, or `nil` when there is nothing new to
    /// save (empty, whitespace, or identical to the stored value).
    static func committableValue(draft: String, stored: String?) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let stored, stored == trimmed { return nil }
        return trimmed
    }

    /// A single edit that adds several characters at once is a paste (or
    /// autofill), not typing.
    static func isLikelyPaste(previous: String, current: String) -> Bool {
        current.count - previous.count >= 8
    }
}

// MARK: - Status

enum ProviderSetupStatus: Equatable {
    case ready
    case needsKey
    case needsRegion

    var title: String {
        switch self {
        case .ready: "Ready"
        case .needsKey: "Needs key"
        case .needsRegion: "Needs region"
        }
    }

    var tone: PreferenceBadge.Tone {
        self == .ready ? .good : .warning
    }

    var isReady: Bool { self == .ready }

    /// A provider with no required keys (Apple) is always ready.
    static func derive(requiredKeys: [KeychainKey], has: (KeychainKey) -> Bool) -> ProviderSetupStatus {
        if requiredKeys.contains(where: { $0.isSecret && !has($0) }) {
            return .needsKey
        }
        if requiredKeys.contains(where: { !$0.isSecret && !has($0) }) {
            return .needsRegion
        }
        return .ready
    }
}

/// The live status line under the Settings header.
struct SettingsReadiness: Equatable {
    enum Tone: Equatable {
        case ready
        case incomplete
    }

    let tone: Tone
    let headline: String
    let detail: String

    static func derive(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        speechProviderName: String,
        speechStatus: ProviderSetupStatus,
        cleanupProviderName: String,
        cleanupStatus: ProviderSetupStatus
    ) -> SettingsReadiness {
        var missing: [String] = []
        if !microphoneGranted { missing.append("microphone access") }
        if !accessibilityGranted { missing.append("accessibility access") }
        switch speechStatus {
        case .ready: break
        case .needsKey: missing.append("\(speechProviderName) key")
        case .needsRegion: missing.append("\(speechProviderName) region")
        }

        if !missing.isEmpty {
            return SettingsReadiness(
                tone: .incomplete,
                headline: "Setup incomplete",
                detail: "Needs " + listPhrase(missing) + "."
            )
        }

        if !cleanupStatus.isReady {
            return SettingsReadiness(
                tone: .ready,
                headline: "Ready",
                detail: "Cleanup is off until \(cleanupProviderName) has a key."
            )
        }

        return SettingsReadiness(
            tone: .ready,
            headline: "Ready",
            detail: "\(speechProviderName) with \(cleanupProviderName) cleanup."
        )
    }

    static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

// MARK: - Credentials

/// Observable wrapper around the Keychain for the Settings window. It caches
/// presence and masks (never full secrets) so views don't hit the Keychain
/// on every render, and it notifies `onChange` so app-wide readiness updates
/// the moment a key is saved or removed.
@MainActor
final class ProviderCredentials: ObservableObject {
    @Published private(set) var revision = 0

    private let store: SecretStore
    private var cache: [KeychainKey: String?] = [:]
    var onChange: (() -> Void)?

    init(store: SecretStore) {
        self.store = store
    }

    func reload() {
        cache.removeAll()
        revision += 1
    }

    func has(_ key: KeychainKey) -> Bool {
        storedValue(key) != nil
    }

    func status(for keys: [KeychainKey]) -> ProviderSetupStatus {
        ProviderSetupStatus.derive(requiredKeys: keys, has: has)
    }

    /// The masked form of a stored secret, or the plain value for
    /// non-secret configuration like the AWS region.
    func displayValue(_ key: KeychainKey) -> String? {
        guard let value = storedValue(key) else { return nil }
        return key.isSecret ? KeyMasking.masked(value) : value
    }

    /// Full stored value. Used only to send a key check; never displayed.
    func secret(_ key: KeychainKey) -> String? {
        storedValue(key)
    }

    /// Saves a draft if it differs from what is stored. Returns `true` when
    /// a new value was written.
    @discardableResult
    func save(_ key: KeychainKey, draft: String) -> Bool {
        guard let value = KeyEntryCommitPolicy.committableValue(draft: draft, stored: storedValue(key)) else {
            return false
        }
        guard store.set(key, value: value) else { return false }
        cache[key] = .some(value)
        changed()
        return true
    }

    func remove(_ key: KeychainKey) {
        store.delete(key)
        cache[key] = .some(nil)
        changed()
    }

    private func storedValue(_ key: KeychainKey) -> String? {
        if let cached = cache[key] { return cached }
        let raw = store.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (raw?.isEmpty ?? true) ? nil : raw
        cache[key] = .some(value)
        return value
    }

    private func changed() {
        revision += 1
        onChange?()
    }
}

// MARK: - Provider descriptors

/// One way to describe a speech or cleanup provider to the setup UI, so both
/// sections share a single key setup component.
struct ProviderDescriptor: Identifiable, Equatable {
    struct OverrideField: Equatable, Identifiable {
        enum Kind: Equatable {
            case baseURL
            case model
        }

        let kind: Kind
        let storageKey: String
        let label: String
        let defaultValue: String

        var id: String { storageKey }
    }

    /// `stt.openai`, `llm.anthropic`, and so on. Unique across sections.
    let id: String
    let name: String
    let keys: [KeychainKey]
    let note: String
    let keyCheck: ProviderKeyCheck?
    let overrides: [OverrideField]
    var modelPicker: ModelPicker? = nil

    /// A menu of known models. Picking the default clears the stored value,
    /// so a later default change still reaches the user.
    struct ModelPicker: Equatable {
        let storageKey: String
        let options: [STTModelOption]

        var defaultModel: String { options.first?.id ?? "" }
    }
}

extension STTProviderID {
    var setupDescriptor: ProviderDescriptor {
        ProviderDescriptor(
            id: "stt.\(rawValue)",
            name: displayName,
            keys: keychainKeys,
            note: setupNote,
            keyCheck: ProviderKeyCheck.forSpeech(self),
            overrides: self == .openai
                ? [
                    .init(kind: .baseURL, storageKey: "openaiSTTBaseURL", label: "Custom Base URL", defaultValue: ProviderKeyCheck.openAIDefaultBaseURL),
                    .init(kind: .model, storageKey: "openaiSTTModel", label: "Custom Model", defaultValue: OpenAISTT.defaultModel),
                ]
                : [],
            modelPicker: modelStorageKey.map { ProviderDescriptor.ModelPicker(storageKey: $0, options: modelOptions) }
        )
    }

    private var setupNote: String {
        switch self {
        case .apple: "Runs on-device. No key needed."
        case .openai: "GPT Transcribe through the OpenAI API, or any compatible gateway. Whisper shuts down in February 2027."
        case .groqWhisper: "Fast hosted Whisper. Groq bills each recording as at least 10 seconds. Shares its key with Groq cleanup."
        case .deepgram: "Nova-3 transcription with multilingual auto-detect."
        case .elevenlabs: "Scribe transcription with keyword biasing."
        case .mistral: "Voxtral transcription with custom vocabulary."
        }
    }
}

extension LLMProviderID {
    var setupDescriptor: ProviderDescriptor {
        var overrides: [ProviderDescriptor.OverrideField] = []
        if self == .openai {
            overrides.append(.init(kind: .baseURL, storageKey: "openaiLLMBaseURL", label: "Custom Base URL", defaultValue: ProviderKeyCheck.openAIDefaultBaseURL))
        }
        overrides.append(.init(kind: .model, storageKey: customModelStorageKey, label: "Custom Model", defaultValue: defaultModel))
        return ProviderDescriptor(
            id: "llm.\(rawValue)",
            name: displayName,
            keys: keychainKeys,
            note: setupNote,
            keyCheck: ProviderKeyCheck.forCleanup(self),
            overrides: overrides
        )
    }

    private var setupNote: String {
        switch self {
        case .openai: "Chat completions through the OpenAI API, or any compatible gateway."
        case .anthropic: "Claude cleans up punctuation, filler, and phrasing."
        case .groq: "Low-latency hosted gpt-oss. Shares its key with Groq Whisper."
        case .bedrock: "Claude on AWS Bedrock with a Bedrock API key and region."
        }
    }
}
