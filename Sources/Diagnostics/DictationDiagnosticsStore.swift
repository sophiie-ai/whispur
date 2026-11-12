import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Diagnostics")

/// Keeps the diagnostics of the most recent dictations, newest first, in
/// `Application Support/Whispur/dictation-diagnostics.json`.
///
/// Records hold measurements only (see `DictationDiagnostics`), so they are
/// kept for every outcome, including the cancelled and no-speech dictations
/// history never lists.
@MainActor
final class DictationDiagnosticsStore: ObservableObject {
    @Published private(set) var items: [DictationDiagnostics] = []

    private let maxItems: Int
    let fileURL: URL

    /// - Parameter fileURL: Defaults to the app-support folder; tests pass a
    ///   temporary file.
    init(maxItems: Int = 50, fileURL: URL? = nil) {
        self.maxItems = maxItems
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Whispur", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dictation-diagnostics.json")
        }
        load()
    }

    /// Adds a record, or replaces the one with the same id, at the top.
    func record(_ diagnostics: DictationDiagnostics) {
        items.removeAll { $0.id == diagnostics.id }
        items.insert(diagnostics, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
        save()
    }

    func item(_ id: UUID) -> DictationDiagnostics? {
        items.first { $0.id == id }
    }

    /// Changes a record in place. Does nothing when there is none.
    func update(_ id: UUID, _ change: (inout DictationDiagnostics) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        save()
    }

    func delete(_ id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
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
            items = try JSONDecoder().decode([DictationDiagnostics].self, from: Data(contentsOf: fileURL))
        } catch {
            logger.error("Failed to load dictation diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(items).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Failed to save dictation diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }
}
