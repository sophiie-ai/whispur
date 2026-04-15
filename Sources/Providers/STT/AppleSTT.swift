import Foundation
import Speech

/// Apple on-device speech recognition (SFSpeechRecognizer).
/// No API key required. Lower accuracy but fully offline.
struct AppleSTT: STTProvider {
    static let providerID: STTProviderID = .apple

    func transcribe(fileURL: URL, languages: [String], vocabulary: [String]) async throws -> String {
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let granted = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
            guard granted else {
                throw STTError.apiError(
                    provider: .apple,
                    message: "Speech recognition not authorized. Enable it in System Settings > Privacy & Security.",
                    statusCode: nil
                )
            }
        }

        // SFSpeechRecognizer is locked to a single locale per instance. Use
        // the user's primary language when set; fall back to system default.
        let recognizer: SFSpeechRecognizer? = {
            if let primary = languages.first {
                return SFSpeechRecognizer(locale: Locale(identifier: primary))
            }
            return SFSpeechRecognizer()
        }()

        guard let recognizer, recognizer.isAvailable else {
            throw STTError.apiError(
                provider: .apple,
                message: "Speech recognizer is not available for the selected language.",
                statusCode: nil
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

        let contextualStrings = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(throwing: STTError.apiError(
                        provider: .apple, message: error.localizedDescription, statusCode: nil
                    ))
                } else if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }
}
