import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "DebugRecordings")

/// Opt-in: keeps the last few normalized recordings for debugging, whatever
/// their outcome, while "Keep my last few recordings on this Mac for
/// debugging" is on.
///
/// A ring of `capacity` files in `Application Support/Whispur/DebugRecordings/`,
/// kept with the same protections as failed recordings (`FailedAudioStore`:
/// owner-only, excluded from backups, file protection on) and deleted after
/// 24 hours. Turning the setting off deletes them all at once.
@MainActor
final class DebugRecordingStore: ObservableObject {
    /// How many recordings the ring keeps.
    static let defaultCapacity = 5

    let files: FailedAudioStore
    let capacity: Int
    /// Recordings currently kept.
    @Published private(set) var count = 0

    /// - Parameter directory: Defaults to the app-support folder; tests pass
    ///   a temporary one.
    init(directory: URL? = nil, capacity: Int = DebugRecordingStore.defaultCapacity) {
        self.capacity = capacity
        self.files = FailedAudioStore(directory: directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Whispur", isDirectory: true)
            .appendingPathComponent("DebugRecordings", isDirectory: true))
        refreshCount()
    }

    /// Copies a dictation's normalized recording into the ring, then drops
    /// the oldest beyond `capacity`.
    func keepCopy(of wavURL: URL, id: UUID, now: Date = Date()) {
        do {
            _ = try files.keep(wavURL, id: id, now: now, copying: true)
        } catch {
            logger.error("Could not keep debug recording \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        for old in files.recordings().dropFirst(capacity) {
            files.delete(old.lastPathComponent)
        }
        refreshCount()
    }

    /// Kept recordings, newest first.
    var recordings: [URL] { files.recordings() }

    /// Deletes recordings older than 24 hours.
    func purge(now: Date = Date()) {
        files.purge(now: now)
        refreshCount()
    }

    func deleteAll() {
        let had = count
        files.deleteAll()
        refreshCount()
        if had > 0 { logger.notice("Deleted \(had, privacy: .public) debug recording(s)") }
    }

    private func refreshCount() {
        count = files.recordings().count
    }
}
