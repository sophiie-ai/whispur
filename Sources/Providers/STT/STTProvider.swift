import Foundation

/// Identifies available speech-to-text providers.
enum STTProviderID: String, Codable, CaseIterable, Identifiable {
    case openai
    case deepgram
    case elevenlabs
    case bedrock
    case apple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI Whisper"
        case .deepgram: "Deepgram"
        case .elevenlabs: "ElevenLabs"
        case .bedrock: "AWS Bedrock"
        case .apple: "Apple (on-device)"
        }
    }

    var requiresAPIKey: Bool {
        self != .apple
    }

    var keychainKeys: [KeychainKey] {
        switch self {
        case .openai: [.openaiAPIKey]
        case .deepgram: [.deepgramAPIKey]
        case .elevenlabs: [.elevenlabsAPIKey]
        case .bedrock: [.awsAccessKeyID, .awsSecretAccessKey]
        case .apple: []
        }
    }
}

/// A provider that converts audio to text.
///
/// All providers receive a normalized 16kHz mono WAV file.
/// Implementations should handle their own HTTP transport and error mapping.
protocol STTProvider {
    static var providerID: STTProviderID { get }

    /// Transcribe an audio file and return the raw text.
    /// - Parameter fileURL: Path to a 16kHz mono WAV file.
    /// - Returns: The raw transcription text.
    func transcribe(fileURL: URL) async throws -> String
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
