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
}

@MainActor
final class ProviderRequestLog: ObservableObject {
    @Published private(set) var items: [ProviderRequestLogEntry] = []

    private let maxItems: Int
    private let fileURL: URL

    init(maxItems: Int = 100) {
        self.maxItems = maxItems

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directoryURL = appSupport.appendingPathComponent("Whispur", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        self.fileURL = directoryURL.appendingPathComponent("provider-requests.json")

        load()
    }

    func record(_ entry: ProviderRequestLogEntry) {
        items.insert(entry, at: 0)
        if items.count > maxItems {
            items = Array(items.prefix(maxItems))
        }
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
