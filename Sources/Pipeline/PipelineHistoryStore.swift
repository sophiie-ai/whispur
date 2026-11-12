import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "History")

/// Stores the last N pipeline results for the Run Log. Failed and anomalous
/// entries older than those are kept too, up to `maxPinnedItems`.
@MainActor
final class PipelineHistoryStore: ObservableObject {
    @Published private(set) var items: [PipelineResult] = []

    private let maxItems: Int
    private let maxPinnedItems: Int
    private let fileURL: URL
    /// Where failed dictations keep their recordings. Removing an entry
    /// removes its recording.
    let failedAudio: FailedAudioStore
    /// Per-dictation measurements, keyed by the same id as the entries.
    /// Clearing or deleting history clears them too.
    let diagnostics: DictationDiagnosticsStore
    private var diagnosticsCancellable: AnyCancellable?

    /// - Parameter fileURL: Where the history lives. Defaults to
    ///   `Application Support/Whispur/history.json`; tests and renders pass
    ///   a temporary file, and the failed recordings and diagnostics then
    ///   live beside it.
    init(
        maxItems: Int = 25,
        maxPinnedItems: Int = 10,
        fileURL: URL? = nil,
        failedAudio: FailedAudioStore? = nil,
        diagnostics: DictationDiagnosticsStore? = nil
    ) {
        self.maxItems = maxItems
        self.maxPinnedItems = maxPinnedItems
        self.failedAudio = failedAudio ?? FailedAudioStore(
            directory: fileURL.map { $0.deletingLastPathComponent().appendingPathComponent("FailedAudio", isDirectory: true) }
        )
        self.diagnostics = diagnostics ?? DictationDiagnosticsStore(
            fileURL: fileURL.map { $0.deletingLastPathComponent().appendingPathComponent("dictation-diagnostics.json") }
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
        // Views that show history also show its diagnostics.
        diagnosticsCancellable = self.diagnostics.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func add(_ result: PipelineResult) {
        items.insert(result, at: 0)
        let trimmed = PinnedTrim.trim(items, maxItems: maxItems, maxPinnedItems: maxPinnedItems, isPinned: \.isPinned)
        trimmed.dropped.forEach(deleteAudio(of:))
        items = trimmed.kept
        save()
    }

    /// Whether a dictation is failed or anomalous, in history or in its
    /// diagnostics. The request log keeps such dictations' requests.
    func isPinned(_ id: UUID) -> Bool {
        if item(id)?.isPinned == true { return true }
        return diagnostics.item(id)?.isPinned == true
    }

    func clear() {
        items.forEach(deleteAudio(of:))
        items = []
        diagnostics.clear()
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

    /// The kept recording of a failed or anomalous entry, while it exists.
    func keptAudioURL(for item: PipelineResult) -> URL? {
        let name = item.isFailed ? item.failure?.audioFileName : item.anomaly?.audioFileName
        guard let name, failedAudio.exists(name) else { return nil }
        return failedAudio.url(for: name)
    }

    /// Marks a dictation that produced text but looked wrong.
    func markAnomalous(_ id: UUID, reasons: [DictationAnomaly.Reason]) {
        guard !reasons.isEmpty else { return }
        update(id) { item in
            item.anomaly = DictationAnomalyMark(reasons: reasons, audioFileName: item.anomaly?.audioFileName)
        }
    }

    /// Adds an entry for a long dictation that ended with no speech, so it
    /// shows in Activity (pinned, "Looks wrong") and can keep its recording.
    @discardableResult
    func recordNoSpeech(
        id: UUID,
        audioSeconds: Double,
        sttProvider: STTProviderID,
        sttFallbackFrom: STTProviderID? = nil,
        llmProvider: LLMProviderID,
        appBundleID: String?,
        at timestamp: Date = Date()
    ) -> PipelineResult {
        var result = PipelineResult(
            id: id,
            rawTranscript: "",
            cleanedText: "",
            sttProvider: sttProvider,
            llmProvider: llmProvider,
            llmModel: nil,
            timestamp: timestamp,
            appBundleID: appBundleID,
            sttFallbackFrom: sttFallbackFrom
        )
        result.anomaly = DictationAnomalyMark(reasons: [.noSpeech], audioFileName: nil, audioSeconds: audioSeconds)
        add(result)
        return result
    }

    /// Moves an anomalous dictation's normalized recording into the
    /// failed-audio folder (same protections and 24-hour expiry). Does
    /// nothing unless the entry is marked anomalous.
    func keepAnomalyAudio(_ id: UUID, wavURL: URL, now: Date = Date()) {
        guard item(id)?.anomaly != nil else { return }
        do {
            let name = try failedAudio.keep(wavURL, id: id, now: now)
            update(id) { $0.anomaly?.audioFileName = name }
        } catch {
            logger.error("Could not keep the recording of anomalous dictation \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records a dictation that produced no text. Moves `wavURL` (when there
    /// is one) into the failed-audio folder.
    @discardableResult
    func recordFailure(
        id: UUID = UUID(),
        error: String,
        wavURL: URL?,
        sttProvider: STTProviderID,
        sttFallbackFrom: STTProviderID? = nil,
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
            failure: DictationFailure(error: error, audioFileName: audioName),
            sttFallbackFrom: sttFallbackFrom
        )
        add(result)
        return result
    }

    /// A retry worked: the entry takes the new text and its recording goes.
    func markRetried(
        _ id: UUID,
        rawTranscript: String,
        text: String,
        llmModel: String?,
        style: WritingStyle?,
        cleanupOff: Bool = false,
        at date: Date = Date()
    ) {
        update(id) { item in
            if let name = item.failure?.audioFileName { failedAudio.delete(name) }
            item.rawTranscript = rawTranscript
            item.cleanedText = text
            item.llmModel = llmModel
            item.style = style
            item.cleanupOff = cleanupOff ? true : nil
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
        diagnostics.delete(id)
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
            if let name = items[index].anomaly?.audioFileName, removed.contains(name) {
                items[index].anomaly?.audioFileName = nil
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
        if let name = item.anomaly?.audioFileName { failedAudio.delete(name) }
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
