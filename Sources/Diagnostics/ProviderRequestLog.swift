import Foundation
import os

private let providerRequestLogPersistenceLogger = Logger(subsystem: "ai.sophiie.whispur", category: "ProviderRequestLog")

enum ProviderRequestKind: String, Codable, CaseIterable, Identifiable {
    case stt = "STT"
    case llm = "LLM"

    var id: String { rawValue }
}

struct ProviderRequestLogEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let providerID: String
    let kind: ProviderRequestKind
    let endpointURL: String
    let httpMethod: String
    let statusCode: Int?
    let durationMS: Int
    let requestSummary: String
    let responseBodyPreview: String
    let errorMessage: String?
    /// The dictation the request belonged to, when it ran inside one. Nil for
    /// key checks and for entries saved before this was recorded.
    var dictationID: UUID? = nil
}

/// Context a provider request runs in, carried as task-locals so providers
/// don't have to pass it through.
enum ProviderRequestContext {
    @TaskLocal static var dictationID: UUID?
}

extension ProviderRequestLogEntry {
    /// A script-guard note rather than an HTTP request.
    var isScriptGuard: Bool { httpMethod == ProviderHTTPClient.scriptGuardMethod }
    /// A transcription that ran on this Mac rather than an HTTP request.
    var isOnDevice: Bool { httpMethod == ProviderHTTPClient.onDeviceMethod }
}

/// The last `maxItems` provider requests, plus older requests of failed or
/// anomalous dictations (`isPinnedDictation`), up to `maxPinnedItems`.
@MainActor
final class ProviderRequestLog: ObservableObject {
    @Published private(set) var items: [ProviderRequestLogEntry] = []

    private let maxItems: Int
    private let maxPinnedItems: Int
    private let fileURL: URL
    /// Whether a dictation's requests outlive the cap. Set by the app to ask
    /// history; nothing is pinned until then.
    var isPinnedDictation: (UUID) -> Bool = { _ in false }

    /// - Parameter fileURL: Where the log lives. Defaults to
    ///   `Application Support/Whispur/provider-requests.json`; renders pass a
    ///   temporary file.
    /// - Parameter maxPinnedItems: About 10 pinned dictations' worth of
    ///   requests (a dictation makes one to a few).
    init(maxItems: Int = 25, maxPinnedItems: Int = 40, fileURL: URL? = nil) {
        self.maxItems = maxItems
        self.maxPinnedItems = maxPinnedItems

        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let directoryURL = appSupport.appendingPathComponent("Whispur", isDirectory: true)
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            self.fileURL = directoryURL.appendingPathComponent("provider-requests.json")
        }

        load()
    }

    func record(_ entry: ProviderRequestLogEntry) {
        items.insert(entry, at: 0)
        items = PinnedTrim.trim(items, maxItems: maxItems, maxPinnedItems: maxPinnedItems) { [isPinnedDictation] entry in
            entry.dictationID.map(isPinnedDictation) ?? false
        }.kept
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            items = try JSONDecoder().decode([ProviderRequestLogEntry].self, from: data)
        } catch {
            providerRequestLogPersistenceLogger.error("Failed to load provider request log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            providerRequestLogPersistenceLogger.error("Failed to save provider request log: \(error.localizedDescription, privacy: .public)")
        }
    }
}
