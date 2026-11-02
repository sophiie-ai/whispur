import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppRelauncher")

/// Quits Whispur and opens a copy of it again once this process has gone:
/// the moved copy after "Move to Applications", or this same bundle when a
/// permission only takes effect after a restart.
@MainActor
enum AppRelauncher {
    /// Waits for this process to exit, optionally ejects a disk image, then
    /// opens `bundle`. Terminates the app.
    static func relaunch(at bundle: URL = Bundle.main.bundleURL, thenEject volume: String? = nil) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments(pid: ProcessInfo.processInfo.processIdentifier, bundle: bundle, ejecting: volume)
        do {
            try process.run()
        } catch {
            logger.error("Relaunch helper failed: \(error.localizedDescription, privacy: .public)")
            NSWorkspace.shared.open(bundle)
        }
        NSApp.terminate(nil)
    }

    /// The `/bin/sh` arguments for the helper. Paths travel as positional
    /// parameters, never spliced into the script.
    nonisolated static func arguments(pid: Int32, bundle: URL, ejecting volume: String?) -> [String] {
        var script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; "
        if volume != nil { script += "/usr/bin/hdiutil detach -quiet \"$2\"; " }
        script += "/usr/bin/open \"$1\""
        return ["-c", script, "whispur-relaunch", bundle.path, volume ?? ""]
    }
}
