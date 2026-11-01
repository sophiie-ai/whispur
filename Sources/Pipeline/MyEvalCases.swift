import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "MyEvalCases")

/// A dictation the user marked as wrong, as one cleanup eval case. Same
/// fields as `Evals/cleanup/cases.jsonl`, with `split` "mine", so
/// `scripts/eval-cleanup.py` can score the user's own cases.
struct MyEvalCase: Equatable {
    /// What the user can tag a case with in the sheet.
    enum Tag: String, CaseIterable, Identifiable {
        case correction, list, email, names, other

        var id: String { rawValue }

        var title: String {
            switch self {
            case .correction: "Correction"
            case .list: "List"
            case .email: "Email"
            case .names: "Names"
            case .other: "Other"
            }
        }

        /// The tag written to the file, matching the eval set's own tags
        /// where it has one.
        var evalTag: String {
            switch self {
            case .correction: "corrections"
            case .list: "lists"
            case .email: "email"
            case .names: "names"
            case .other: "other"
            }
        }
    }

    static let split = "mine"

    let id: String
    /// The raw transcript.
    let input: String
    /// What the cleanup should have produced.
    let expected: String
    let vocabulary: [String]
    let tags: [Tag]

    /// `mine-<date>-<time>-<first 8 of the dictation id>`. The dictation
    /// part lets Activity show which entries were already marked.
    static func makeID(dictationID: UUID, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "mine-\(formatter.string(from: date))-\(dictationKey(dictationID))"
    }

    static func dictationKey(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    /// The dictation key inside an id written by `makeID`.
    static func dictationKey(fromCaseID id: String) -> String? {
        guard id.hasPrefix("mine-"), let key = id.split(separator: "-").last, key.count == 8 else { return nil }
        return String(key)
    }

    /// One JSONL line (no newline), fields in the eval file's order.
    func jsonLine() throws -> String {
        var fields: [(String, String)] = [
            ("id", try Self.json(id)),
            ("split", try Self.json(Self.split)),
            ("input", try Self.json(input)),
        ]
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !terms.isEmpty { fields.append(("vocabulary", try Self.jsonArray(terms))) }
        fields.append(("expected", try Self.json(expected)))
        fields.append(("tags", try Self.jsonArray(tags.map(\.evalTag))))
        fields.append(("critical", "false"))
        return "{" + fields.map { "\"\($0.0)\": \($0.1)" }.joined(separator: ", ") + "}"
    }

    /// `["a", "b"]`, spaced like the eval file.
    private static func jsonArray(_ values: [String]) throws -> String {
        "[" + (try values.map(json)).joined(separator: ", ") + "]"
    }

    private static func json(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(value)
        let text = String(decoding: data, as: UTF8.self)
        // JSON allows these raw, but Python's str.splitlines() (which the
        // eval runner reads the file with) breaks lines on them.
        return text
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{85}", with: "\\u0085")
    }
}

/// Appends marked cases to `MyEvalCases.jsonl` on this Mac. The file is
/// never uploaded anywhere.
@MainActor
final class MyEvalCaseStore: ObservableObject {
    /// Dictation keys (see `MyEvalCase.dictationKey`) already in the file.
    @Published private(set) var markedKeys: Set<String> = []
    @Published private(set) var lastError: String?

    let fileURL: URL

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Whispur", isDirectory: true)
            .appendingPathComponent("MyEvalCases.jsonl")
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL
        loadMarkedKeys()
    }

    var count: Int { markedKeys.count }

    func isMarked(_ id: UUID) -> Bool {
        markedKeys.contains(MyEvalCase.dictationKey(id))
    }

    /// Appends one case. Returns false (and sets `lastError`) on failure.
    @discardableResult
    func append(_ evalCase: MyEvalCase) -> Bool {
        do {
            try Self.append(line: evalCase.jsonLine(), to: fileURL)
            if let key = MyEvalCase.dictationKey(fromCaseID: evalCase.id) { markedKeys.insert(key) }
            lastError = nil
            logger.info("Saved an eval case")
            return true
        } catch {
            lastError = error.localizedDescription
            logger.error("Could not save the eval case: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Shows the file in Finder, or its folder when nothing is saved yet.
    func reveal() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            let folder = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    /// Appends `line` plus a newline, starting a new line first if the file
    /// doesn't end with one. Creates the file private to the user.
    nonisolated static func append(line: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var data = Data()
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if handle.readData(ofLength: 1) != Data("\n".utf8) { data.append(contentsOf: Array("\n".utf8)) }
            try handle.seekToEnd()
        }
        data.append(contentsOf: Array(line.utf8))
        data.append(contentsOf: Array("\n".utf8))
        try handle.write(contentsOf: data)
    }

    private func loadMarkedKeys() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        var keys = Set<String>()
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = object["id"] as? String,
                  let key = MyEvalCase.dictationKey(fromCaseID: id)
            else { continue }
            keys.insert(key)
        }
        markedKeys = keys
    }
}
