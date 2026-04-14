import AppKit
import Foundation

@MainActor
final class DockIconController {
    static let shared = DockIconController()

    private struct TrackedWindow {
        weak var window: NSWindow?
        var observer: NSObjectProtocol
    }

    private var tracked: [ObjectIdentifier: TrackedWindow] = [:]

    private init() {}

    func register(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        if tracked[id] == nil {
            let observer = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                guard let closed = notification.object as? NSWindow else { return }
                let closedID = ObjectIdentifier(closed)
                Task { @MainActor [weak self] in
                    self?.handleClose(id: closedID)
                }
            }
            tracked[id] = TrackedWindow(window: window, observer: observer)
        }
        updateActivationPolicy()
    }

    private func handleClose(id: ObjectIdentifier) {
        if let entry = tracked.removeValue(forKey: id) {
            NotificationCenter.default.removeObserver(entry.observer)
        }
        updateActivationPolicy()
    }

    private func updateActivationPolicy() {
        var anyVisible = false
        var staleKeys: [ObjectIdentifier] = []
        for (key, entry) in tracked {
            guard let window = entry.window else {
                staleKeys.append(key)
                continue
            }
            if window.isVisible {
                anyVisible = true
            }
        }
        for key in staleKeys {
            if let entry = tracked.removeValue(forKey: key) {
                NotificationCenter.default.removeObserver(entry.observer)
            }
        }

        let current = NSApp.activationPolicy()
        if anyVisible {
            if current != .regular {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else if current != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
