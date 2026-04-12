import Foundation
import Speech

/// Apple on-device speech recognition (SFSpeechRecognizer).
/// No API key required. Lower accuracy but fully offline.
struct AppleSTT: STTProvider {
    static let providerID: STTProviderID = .apple

    func transcribe(fileURL: URL) async throws -> String {
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

        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw STTError.apiError(
                provider: .apple,
                message: "Speech recognizer is not available for the current locale.",
                statusCode: nil
            )
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false

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
