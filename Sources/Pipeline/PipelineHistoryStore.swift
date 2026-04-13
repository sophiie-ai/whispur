import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "History")

/// Stores the last N pipeline results for the Run Log.
@MainActor
final class PipelineHistoryStore: ObservableObject {
    @Published private(set) var items: [PipelineResult] = []

    private let maxItems: Int
    private let fileURL: URL

    init(maxItems: Int = 25) {
        self.maxItems = maxItems

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Whispur", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("history.json")

        load()
    }

    func add(_ result: PipelineResult) {
        items.insert(result, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    func clear() {
        items = []
        save()
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
