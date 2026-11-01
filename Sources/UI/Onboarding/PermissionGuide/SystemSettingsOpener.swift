import AppKit
import CoreGraphics

/// Opens System Settings at a Privacy & Security list, and reads where its
/// window is.
///
/// A System Settings that isn't running yet drops the pane in the URL while
/// it restores the pane it showed last, so after a cold launch the URL is
/// sent again once its window is up and has settled. Every request bumps a
/// generation counter so an older request's retries stand down.
@MainActor
final class SystemSettingsOpener {
    nonisolated static let bundleID = "com.apple.systempreferences"
    /// Re-send delays after a cold launch's first window appears.
    static let coldLaunchResends: [TimeInterval] = [0.35, 1.2]

    private let isRunning: () -> Bool
    private let hasWindow: () -> Bool
    private let openURL: (URL) -> Void
    private(set) var generation = 0

    init(
        isRunning: @escaping () -> Bool = SystemSettingsOpener.settingsIsRunning,
        hasWindow: @escaping () -> Bool = SystemSettingsOpener.settingsHasWindow,
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.isRunning = isRunning
        self.hasWindow = hasWindow
        self.openURL = openURL
    }

    /// Opens `url`, retrying after a cold launch.
    func open(_ url: URL) {
        let cold = !isRunning()
        generation += 1
        let request = generation
        openURL(url)
        guard cold else { return }

        var polls = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                polls += 1
                if request != self.generation || polls > 100 {
                    timer.invalidate()
                    return
                }
                guard self.hasWindow() else { return }
                timer.invalidate()
                for delay in Self.coldLaunchResends {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.resend(url, request: request)
                    }
                }
            }
        }
    }

    /// Re-sends `url` only while `request` is still the latest one.
    func resend(_ url: URL, request: Int) {
        guard request == generation else { return }
        openURL(url)
    }

    /// Makes pending cold-launch retries stand down.
    func invalidate() {
        generation += 1
    }

    // MARK: - System Settings state

    nonisolated static func settingsIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    nonisolated static func settingsHasWindow() -> Bool {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier else {
            return false
        }
        return onScreenWindows().contains { window in
            (window[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid
                && (window[kCGWindowLayer as String] as? Int) == 0
        }
    }

    nonisolated static func onScreenWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    /// The System Settings window in AppKit screen coordinates, or nil when
    /// it has no window on screen.
    static func settingsWindowFrame() -> CGRect? {
        guard let quartz = SettingsWindowGeometry.settingsWindowFrame(in: onScreenWindows()) else { return nil }
        // The primary screen (index 0) anchors both coordinate systems.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? quartz.maxY
        return SettingsWindowGeometry.appKitFrame(fromQuartz: quartz, primaryScreenHeight: primaryHeight)
    }
}
