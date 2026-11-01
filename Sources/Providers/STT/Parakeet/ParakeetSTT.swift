import FluidAudio
import Foundation

/// NVIDIA Parakeet, run on this Mac's Neural Engine through FluidAudio.
/// No key, no upload: the recording never leaves the Mac.
///
/// Vocabulary is not passed to the recognizer. FluidAudio's biasing for the
/// 0.6B models needs a second, English-only CTC model and a second pass over
/// the audio; Dictionary terms still reach the cleanup step.
struct ParakeetSTT: STTProvider {
    static let providerID: STTProviderID = .parakeet

    static let notDownloadedMessage =
        "Parakeet's model isn't on this Mac yet. Download it in Settings > Providers, then retry this dictation from Activity."

    var spec: ParakeetModelSpec = .current
    var engine: ParakeetEngine = .shared
    var modelsDirectory: URL = ParakeetModelLocation.modelsDirectory

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        try await transcribeScored(fileURL: fileURL, language: language, vocabulary: vocabulary).text
    }

    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript {
        guard ParakeetModelLocation.isInstalled(spec, in: modelsDirectory) else {
            throw STTError.modelNotReady(provider: .parakeet, detail: Self.notDownloadedMessage)
        }
        let result: ASRResult
        do {
            result = try await engine.transcribe(
                fileURL: fileURL,
                spec: spec,
                language: ParakeetLanguages.hint(for: language),
                modelsDirectory: modelsDirectory
            )
        } catch let error as STTError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw STTError.apiError(provider: .parakeet, message: error.localizedDescription, statusCode: nil)
        }
        return ScoredTranscript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: Self.logConfidence(result.confidence)
        )
    }

    /// FluidAudio reports a mean token probability in 0...1. The script
    /// guard compares confidences as log probabilities (closer to 0 is
    /// better), so convert; the order is unchanged.
    static func logConfidence(_ probability: Float) -> Double? {
        guard probability.isFinite, probability > 0 else { return nil }
        return log(Double(min(probability, 1)))
    }
}
