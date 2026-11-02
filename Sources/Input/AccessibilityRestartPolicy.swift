import Foundation

/// Where Accessibility stands for the running process, as far as the
/// shortcut cares. Granting it in System Settings is not always enough:
/// macOS sometimes reports the grant (`AXIsProcessTrusted()` is true) while
/// still refusing this process an event tap until it relaunches, typically
/// when the grant follows an earlier denial or an older Whispur entry.
enum AccessibilityStatus: Equatable {
    /// Not granted.
    case off
    /// Granted, the event tap isn't in yet, and Whispur is still retrying.
    case finishing
    /// Granted and the event tap is listening.
    case on
    /// Granted, but the event tap kept failing: only a relaunch fixes it.
    case needsRestart

    static func resolve(trusted: Bool, tapInstalled: Bool, needsRestart: Bool) -> AccessibilityStatus {
        guard trusted else { return .off }
        if tapInstalled { return .on }
        return needsRestart ? .needsRestart : .finishing
    }

    /// macOS reports the grant, whether or not the tap took.
    var isGranted: Bool { self != .off }
}

/// When a granted-but-tapless process should stop retrying and ask for a
/// restart. Pure, so the timing is unit tested.
enum AccessibilityRestartPolicy {
    /// Gap between fast retries after a failed tap install.
    static let retryInterval: TimeInterval = 1
    /// How long failures must persist before a restart is suggested.
    static let retryWindow: TimeInterval = 3
    /// Failed installs needed (with the window) before a restart is suggested.
    static let minimumFailures = 3

    static func needsRestart(
        trusted: Bool,
        tapInstalled: Bool,
        failedAttempts: Int,
        firstFailure: Date?,
        now: Date
    ) -> Bool {
        guard trusted, !tapInstalled, failedAttempts >= minimumFailures, let firstFailure else { return false }
        return now.timeIntervalSince(firstFailure) >= retryWindow
    }

    /// Keep retrying quickly until a restart is suggested; the slow poll
    /// keeps going after that in case the tap comes good on its own.
    static func shouldRetrySoon(trusted: Bool, tapInstalled: Bool, needsRestart: Bool) -> Bool {
        trusted && !tapInstalled && !needsRestart
    }
}
