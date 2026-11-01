import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "History")

/// Stores the last N pipeline results for the Run Log.
@MainActor
final class PipelineHistoryStore: ObservableObject {
    @Published private(set) var items: [PipelineResult] = []

    private let maxItems: Int
    private let fileURL: URL
    /// Where failed dictations keep their recordings. Removing an entry
    /// removes its recording.
    let failedAudio: FailedAudioStore

    /// - Parameter fileURL: Where the history lives. Defaults to
    ///   `Application Support/Whispur/history.json`; tests and renders pass
    ///   a temporary file.
    init(maxItems: Int = 25, fileURL: URL? = nil, failedAudio: FailedAudioStore? = nil) {
        self.maxItems = maxItems
        self.failedAudio = failedAudio ?? FailedAudioStore(
            directory: fileURL.map { $0.deletingLastPathComponent().appendingPathComponent("FailedAudio", isDirectory: true) }
        )

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Whispur", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("history.json")
        }

        load()
    }

    func add(_ result: PipelineResult) {
        items.insert(result, at: 0)
        if items.count > maxItems {
            items.suffix(from: maxItems).forEach(deleteAudio(of:))
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    func clear() {
        items.forEach(deleteAudio(of:))
        items = []
        save()
    }

    func item(_ id: UUID) -> PipelineResult? {
        items.first { $0.id == id }
    }

    /// Whether a failed entry still has a recording to retry.
    func canRetry(_ item: PipelineResult) -> Bool {
        guard item.isFailed, let name = item.failure?.audioFileName else { return false }
        return failedAudio.exists(name)
    }

    /// Records a dictation that produced no text. Moves `wavURL` (when there
    /// is one) into the failed-audio folder.
    @discardableResult
    func recordFailure(
        id: UUID = UUID(),
        error: String,
        wavURL: URL?,
        sttProvider: STTProviderID,
        llmProvider: LLMProviderID,
        appBundleID: String?,
        style: WritingStyle?,
        at timestamp: Date = Date()
    ) -> PipelineResult {
        var audioName: String?
        if let wavURL {
            do {
                audioName = try failedAudio.keep(wavURL, id: id, now: timestamp)
            } catch {
                logger.error("Could not keep the failed recording: \(error.localizedDescription, privacy: .public)")
            }
        }
        let result = PipelineResult(
            id: id,
            rawTranscript: "",
            cleanedText: "",
            sttProvider: sttProvider,
            llmProvider: llmProvider,
            llmModel: nil,
            timestamp: timestamp,
            appBundleID: appBundleID,
            style: style,
            failure: DictationFailure(error: error, audioFileName: audioName)
        )
        add(result)
        return result
    }

    /// A retry worked: the entry takes the new text and its recording goes.
    func markRetried(_ id: UUID, rawTranscript: String, text: String, llmModel: String?, style: WritingStyle?, at date: Date = Date()) {
        update(id) { item in
            if let name = item.failure?.audioFileName { failedAudio.delete(name) }
            item.rawTranscript = rawTranscript
            item.cleanedText = text
            item.llmModel = llmModel
            item.style = style
            item.failure?.audioFileName = nil
            item.failure?.retriedAt = date
        }
    }

    /// The user swapped the cleaned paste for the raw transcript.
    func markUsedRaw(_ id: UUID, at date: Date = Date()) {
        update(id) { $0.usedRawAt = date }
    }

    /// A retry failed: keep the recording, show the new error.
    func markRetryFailed(_ id: UUID, error: String) {
        update(id) { $0.failure?.error = error }
    }

    /// Removes an entry and its kept recording.
    func delete(_ id: UUID) {
        guard let item = item(id) else { return }
        deleteAudio(of: item)
        items.removeAll { $0.id == id }
        save()
    }

    /// Purges recordings past retention and drops the references to them.
    func purgeExpiredAudio(now: Date = Date()) {
        let removed = Set(failedAudio.purge(now: now))
        guard !removed.isEmpty else { return }
        var changed = false
        for index in items.indices {
            if let name = items[index].failure?.audioFileName, removed.contains(name) {
                items[index].failure?.audioFileName = nil
                changed = true
            }
        }
        if changed { save() }
    }

    private func update(_ id: UUID, _ change: (inout PipelineResult) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    private func deleteAudio(of item: PipelineResult) {
        if let name = item.failure?.audioFileName { failedAudio.delete(name) }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            items = try JSONDecoder().decode([PipelineResult].self, from: data)
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save history: \(error.localizedDescription)")
        }
    }
}
