import AppKit
import SwiftUI

enum WhispurWindowID: String {
    case settings
    case about
}

enum WindowUtilities {
    /// Dismisses the SwiftUI `MenuBarExtra` popover window, if it's currently open.
    static func dismissMenuBarPopover() {
        for window in NSApp.windows where isMenuBarExtraWindow(window) {
            window.orderOut(nil)
        }
    }

    /// Brings an existing window (identified by `id`) to the front, or opens it if
    /// not yet instantiated. Avoids stacking duplicate windows and ensures the app
    /// is activated so the window actually comes to focus.
    static func focusOrOpenWindow(id: WhispurWindowID, using openWindow: OpenWindowAction) {
        NSApp.activate(ignoringOtherApps: true)

        if let existing = findWindow(id: id) {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        openWindow(id: id.rawValue)

        DispatchQueue.main.async {
            if let window = findWindow(id: id) {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    private static func findWindow(id: WhispurWindowID) -> NSWindow? {
        NSApp.windows.first { window in
            guard window.identifier?.rawValue.contains(id.rawValue) == true else {
                return false
            }
            return !isMenuBarExtraWindow(window)
        }
    }

    private static func isMenuBarExtraWindow(_ window: NSWindow) -> Bool {
        let className = String(describing: type(of: window))
        return className.contains("MenuBarExtra") || className.contains("StatusBar")
    }
}
