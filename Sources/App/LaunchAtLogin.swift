import AppKit
import Foundation
import ServiceManagement
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "LaunchAtLogin")

/// The slice of `SMAppService` that "Open at login" uses, so tests can
/// supply a fake instead of touching the real login items.
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

/// "Open at login". The setting lives in macOS (System Settings → General →
/// Login Items), not in Whispur's defaults, so the toggle always reads the
/// system's answer and a change made there shows up here.
///
/// New installs start with it on: the first launch from the Applications
/// folder registers the login item once. After that Whispur never turns it
/// back on by itself, so switching it off (here or in System Settings) sticks.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    /// Set once the on-by-default registration has been attempted.
    static let defaultAppliedKey = "launchAtLogin.defaultApplied"

    @Published private(set) var status: SMAppService.Status

    private let service: LoginItemService
    private let defaults: UserDefaults
    private var activeObserver: NSObjectProtocol?

    init(service: LoginItemService = SMAppService.mainApp, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.status = service.status
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
    }

    /// On, or on and waiting for the user to allow it in System Settings.
    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    func refresh() {
        let current = service.status
        if current != status { status = current }
    }

    /// A choice made with the switch, from any copy of the app, also
    /// settles the default: a later first launch from Applications must not
    /// undo it.
    func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: Self.defaultAppliedKey)
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            logger.error("Open at login \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this launch should turn "Open at login" on. Pure, so the
    /// allow and block sides are unit tested.
    ///
    /// Only a copy in the Applications folder registers: a login item points
    /// at the running bundle, and a DMG, Downloads or translocated copy would
    /// leave it pointing somewhere that goes away.
    nonisolated static func shouldApplyDefault(
        alreadyApplied: Bool,
        location: AppInstallLocation,
        status: SMAppService.Status
    ) -> Bool {
        guard !alreadyApplied, location == .applicationsFolder else { return false }
        return status == .notRegistered
    }

    /// Runs the on-by-default registration at most once per Mac account.
    /// A launch outside Applications leaves it for a later launch.
    func applyDefaultIfNeeded(location: AppInstallLocation) {
        guard location == .applicationsFolder, !defaults.bool(forKey: Self.defaultAppliedKey) else { return }
        // Marked before registering: a failed attempt is not retried, and
        // a user who already has it on (or off by approval) is left alone.
        defaults.set(true, forKey: Self.defaultAppliedKey)
        if Self.shouldApplyDefault(alreadyApplied: false, location: location, status: service.status) {
            logger.info("Turning on Open at login for the first launch from Applications")
            setEnabled(true)
        }
    }
}
