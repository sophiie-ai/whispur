import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "FailedAudio")

/// Keeps the recording of a FAILED dictation so it can be retried, and
/// nothing else: successful dictations never land here.
///
/// Files live in `Application Support/Whispur/FailedAudio/` (owner-only,
/// excluded from Time Machine and iCloud backups, file protection on) and
/// are deleted after a successful retry, on the row's Delete, or once they
/// are older than `retention`.
final class FailedAudioStore: @unchecked Sendable {
    /// How long a failed recording is kept.
    static let retention: TimeInterval = 24 * 60 * 60

    let directory: URL
    private let fileManager = FileManager.default

    /// - Parameter directory: Defaults to the app-support folder; tests pass
    ///   a temporary one.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport
                .appendingPathComponent("Whispur", isDirectory: true)
                .appendingPathComponent("FailedAudio", isDirectory: true)
        }
    }

    /// Moves `wavURL` into the store as `<id>.wav` and returns the file name
    /// to record in history.
    func keep(_ wavURL: URL, id: UUID, now: Date = Date()) throws -> String {
        try prepareDirectory()
        let name = "\(id.uuidString).wav"
        let destination = directory.appendingPathComponent(name)
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: wavURL, to: destination)
        } catch {
            try fileManager.copyItem(at: wavURL, to: destination)
            try? fileManager.removeItem(at: wavURL)
        }
        try fileManager.setAttributes([
            .posixPermissions: 0o600,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            .modificationDate: now,
        ], ofItemAtPath: destination.path)
        return name
    }

    func url(for name: String) -> URL? {
        // Names come from history; never follow one out of the folder.
        guard !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return directory.appendingPathComponent(name)
    }

    func exists(_ name: String) -> Bool {
        guard let url = url(for: name) else { return false }
        return fileManager.fileExists(atPath: url.path)
    }

    func delete(_ name: String) {
        guard let url = url(for: name) else { return }
        try? fileManager.removeItem(at: url)
    }

    /// Deletes recordings older than `retention`. Returns the deleted names.
    @discardableResult
    func purge(now: Date = Date(), retention: TimeInterval = FailedAudioStore.retention) -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [String] = []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) >= retention else { continue }
            if (try? fileManager.removeItem(at: file)) != nil {
                removed.append(file.lastPathComponent)
            }
        }
        if !removed.isEmpty {
            logger.info("Purged \(removed.count, privacy: .public) failed recording(s) older than 24 hours")
        }
        return removed
    }

    private func prepareDirectory() throws {
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
