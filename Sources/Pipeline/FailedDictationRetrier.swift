import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Retry")

/// Retries failed dictations from Activity (or Requests): transcription and
/// cleanup run again on the kept recording, and the text goes to the
/// clipboard rather than being pasted, since the app it was meant for is
/// probably no longer in front.
///
/// An anomalous dictation (`DictationAnomaly`) can be transcribed again the
/// same way; its entry keeps the text that was pasted.
@MainActor
final class FailedDictationRetrier: ObservableObject {
    /// Entries with a retry in flight.
    @Published private(set) var running: Set<UUID> = []
    /// A short confirmation for the Settings window, cleared after a moment.
    @Published private(set) var toast: String?

    private let history: PipelineHistoryStore
    /// Runs the pipeline on a recording. Injected so tests use fakes.
    private let process: (_ audioURL: URL, _ item: PipelineResult) async throws -> DictationPipeline.RetryResult
    private let copy: (String) -> Void
    private var toastTask: Task<Void, Never>?

    static let toastDuration: Duration = .seconds(2.5)

    init(
        history: PipelineHistoryStore,
        process: @escaping (_ audioURL: URL, _ item: PipelineResult) async throws -> DictationPipeline.RetryResult,
        copy: @escaping (String) -> Void = FailedDictationRetrier.copyToClipboard
    ) {
        self.history = history
        self.process = process
        self.copy = copy
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func isRunning(_ id: UUID) -> Bool {
        running.contains(id)
    }

    /// Retries one failed entry. On success the entry takes the new text,
    /// its recording is deleted and the text is copied. On failure the
    /// recording stays and the entry shows the new error.
    ///
    /// For an anomalous entry the new text is only copied: the entry and
    /// its recording stay as they are.
    func retry(_ id: UUID) async {
        guard !running.contains(id),
              let item = history.item(id),
              item.isFailed || item.anomaly != nil
        else { return }
        guard let audioURL = history.keptAudioURL(for: item) else {
            if item.isFailed {
                history.markRetryFailed(id, error: DictationPipeline.RetryError.noRecording.localizedDescription)
            }
            return
        }

        running.insert(id)
        defer { running.remove(id) }
        do {
            let result = try await process(audioURL, item)
            if item.isFailed {
                history.markRetried(
                    id,
                    rawTranscript: result.rawTranscript,
                    text: result.text,
                    llmModel: result.llmModel,
                    style: result.style,
                    cleanupOff: result.cleanupOff
                )
            }
            copy(result.text)
            showToast("Copied to clipboard")
            logger.notice("Transcribed dictation \(id.uuidString, privacy: .public) again")
        } catch {
            if error is CancellationError { return }
            if item.isFailed {
                history.markRetryFailed(id, error: error.localizedDescription)
            } else {
                showToast("Couldn't transcribe it again: \(error.localizedDescription)")
            }
            logger.error("Retry of dictation \(id.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a failed entry and its recording.
    func delete(_ id: UUID) {
        guard !running.contains(id) else { return }
        history.delete(id)
    }

    #if DEBUG
    /// Fixed states for Settings renders in tests.
    func setStateForRendering(running: Set<UUID>, toast: String?) {
        self.running = running
        self.toast = toast
    }
    #endif

    private func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: Self.toastDuration)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
