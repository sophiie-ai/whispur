import Foundation
import os

/// Timing marks for the start of a dictation: shortcut press, hold armed,
/// overlay on screen, audio engine running, first audio. Each mark logs its
/// offset from the press and emits a signpost for Instruments. Watch it live:
///
///     log stream --level info --predicate 'subsystem == "ai.sophiie.whispur" AND category == "StartLatency"'
enum StartLatencyTrace {
    private static let logger = Logger(subsystem: "ai.sophiie.whispur", category: "StartLatency")
    private static let signposter = OSSignposter(logger: logger)
    private static let origin = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Starts a trace at the moment the shortcut went down. Quick taps that
    /// never start a recording just leave an origin behind; the next press
    /// replaces it.
    static func begin(_ event: StaticString) {
        origin.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        signposter.emitEvent(event)
    }

    /// Logs `event` with its offset from the press. No-op without a trace.
    static func mark(_ event: StaticString) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let start = origin.withLock({ $0 }) else { return }
        signposter.emitEvent(event)
        logger.info("\(String(describing: event), privacy: .public) +\(Int(((now - start) * 1000).rounded()), privacy: .public) ms")
    }

    /// Logs the last mark of a start and closes the trace.
    static func finish(_ event: StaticString) {
        mark(event)
        origin.withLock { $0 = nil }
    }
}
