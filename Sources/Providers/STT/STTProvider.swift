import Foundation

/// Identifies available speech-to-text providers.
enum STTProviderID: String, Codable, CaseIterable, Identifiable {
    case openai
    case groqWhisper
    case deepgram
    case elevenlabs
    case mistral
    case metaMuse
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .groqWhisper: "Groq Whisper"
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .mistral: "Mistral Voxtral"
        case .metaMuse: "Meta Muse"
        case .apple: "Apple (on-device)"
        }
    }

    var requiresAPIKey: Bool {
        self != .apple
    }

    var keychainKeys: [KeychainKey] {
        switch self {
        case .openai: [.openaiAPIKey]
        case .groqWhisper: [.groqAPIKey]
        case .deepgram: [.deepgramAPIKey]
        case .elevenlabs: [.elevenlabsAPIKey]
        case .mistral: [.mistralAPIKey]
        case .metaMuse: [.metaAPIKey]
        case .apple: []
        }
    }

    /// Models offered in the Settings picker, default first. Empty when the
    /// provider has a single model.
    var modelOptions: [STTModelOption] {
        switch self {
        case .openai:
            [
                STTModelOption(id: "gpt-transcribe", label: "GPT Transcribe"),
                STTModelOption(id: "whisper-1", label: "Whisper (retiring Feb 2027)"),
            ]
        case .groqWhisper:
            [
                STTModelOption(id: "whisper-large-v3", label: "Whisper Large v3"),
                STTModelOption(id: "whisper-large-v3-turbo", label: "Whisper Large v3 Turbo"),
            ]
        case .mistral:
            [
                STTModelOption(id: "voxtral-mini-transcribe-3", label: "Voxtral Mini Transcribe 3"),
                STTModelOption(id: "voxtral-small-transcribe-3", label: "Voxtral Small Transcribe 3"),
            ]
        case .deepgram, .elevenlabs, .metaMuse, .apple:
            []
        }
    }

    /// Model used when the user hasn't picked one.
    ///
    /// Like the cleanup models, only an explicit choice is ever persisted
    /// (`modelStorageKey`), so changing the default here moves every user
    /// who never picked a model onto the new one.
    var defaultModel: String? {
        modelOptions.first?.id
    }

    /// UserDefaults key for the user's model choice. OpenAI keeps the key
    /// its custom-model field always used.
    var modelStorageKey: String? {
        switch self {
        case .openai: "openaiSTTModel"
        case .groqWhisper: "groqWhisperSTTModel"
        case .mistral: "mistralSTTModel"
        case .deepgram, .elevenlabs, .metaMuse, .apple: nil
        }
    }
}

/// One entry in a speech provider's model picker.
struct STTModelOption: Equatable, Identifiable {
    let id: String
    let label: String
}

/// A provider that converts audio to text.
///
/// All providers receive a normalized 16kHz mono WAV file.
/// Implementations should handle their own HTTP transport and error mapping.
protocol STTProvider {
    static var providerID: STTProviderID { get }

    /// Transcribe an audio file and return the raw text.
    /// - Parameters:
    ///   - fileURL: Path to a 16kHz mono WAV file.
    ///   - language: The user's language selection. Each provider maps this
    ///     through `STTLanguageResolver` into its native parameter shape —
    ///     e.g. `.auto` becomes `language=multi` for Deepgram nova-3 but is
    ///     omitted entirely for Whisper.
    ///   - vocabulary: Custom terms to bias the recognizer toward (names,
    ///     acronyms, product words). Providers wire this into their own
    ///     biasing feature — prompt text for Whisper, `keyterm` for
    ///     Deepgram nova-3, `biased_keywords` for ElevenLabs Scribe,
    ///     `context_bias` for Mistral, `keywords` for Meta Muse,
    ///     `contextualStrings` for Apple. Empty means no biasing.
    /// - Returns: The raw transcription text.
    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String

    /// Like `transcribe`, plus the provider's confidence when its API
    /// returns one. Used by the script guard to pick between re-runs.
    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript
}

extension STTProvider {
    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript {
        ScoredTranscript(text: try await transcribe(fileURL: fileURL, language: language, vocabulary: vocabulary), confidence: nil)
    }
}

/// A transcript and how sure the provider was of it.
struct ScoredTranscript: Equatable {
    let text: String
    /// Mean log probability per token (Whisper's `avg_logprob`, averaged
    /// over segments by duration): closer to 0 is more confident. Nil when
    /// the provider doesn't report one.
    let confidence: Double?
}

// MARK: - Errors

enum STTError: LocalizedError {
    case noAudioFile
    case invalidAudioFormat
    case apiError(provider: STTProviderID, message: String, statusCode: Int?)
    case timeout(provider: STTProviderID)
    case missingAPIKey(provider: STTProviderID)

    var errorDescription: String? {
        switch self {
        case .noAudioFile:
            "No audio file found to transcribe."
        case .invalidAudioFormat:
            "Audio file is not in the expected format."
        case let .apiError(provider, message, code):
            "\(provider.displayName) error\(code.map { " (\($0))" } ?? ""): \(message)"
        case let .timeout(provider):
            "\(provider.displayName) transcription timed out."
        case let .missingAPIKey(provider):
            "\(provider.displayName) API key is not configured."
        }
    }
}
