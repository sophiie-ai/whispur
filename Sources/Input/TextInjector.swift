import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "TextInjector")

/// Pastes text into the active application while preserving the previous clipboard contents when possible.
enum TextInjector {
    static func paste(_ text: String, preserveClipboard: Bool = true) async {
        let pasteboard = NSPasteboard.general

        // Snapshot the current clipboard in parallel with the key-release
        // wait. The two are independent, and snapshotting takes ~1–5 ms, so
        // running them concurrently shaves measurable paste latency.
        async let snapshot: [NSPasteboardItem]? = preserveClipboard
            ? snapshotPasteboard(pasteboard)
            : nil
        await waitForKeyRelease()
        let savedItems = await snapshot

        guard !Task.isCancelled else {
            logger.info("Paste cancelled before clipboard write")
            return
        }

        // Write text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasteChangeCount = pasteboard.changeCount

        // Brief wait for app focus to return. 15ms is enough on modern
        // hardware; the prior 30ms was defensive padding.
        try? await Task.sleep(for: .milliseconds(15))

        // If cancelled after clipboard write but before paste, restore and bail.
        guard !Task.isCancelled else {
            logger.info("Paste cancelled before simulating Cmd+V — restoring clipboard")
            if let savedItems {
                pasteboard.clearContents()
                pasteboard.writeObjects(savedItems)
            }
            return
        }

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after 150ms (only if nothing else modified it)
        if preserveClipboard, let savedItems {
            try? await Task.sleep(for: .milliseconds(150))
            if pasteboard.changeCount == pasteChangeCount {
                pasteboard.clearContents()
                let wrote = pasteboard.writeObjects(savedItems)
                if wrote {
                    logger.debug("Clipboard restored")
                } else {
                    logger.warning("Clipboard restore failed: writeObjects returned false")
                }
            } else {
                // Something else wrote to the clipboard between paste and restore
                // (likely the user or another app). Skip restore to avoid clobbering.
                logger.info("Clipboard changed during paste — skipping restore to preserve new contents")
            }
        }
    }

    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) async -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let newItem = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    newItem.setData(data, forType: type)
                }
            }
            return newItem
        }
    }

    /// Wait up to 500ms for modifier keys to be released. Polls at 8ms so
    /// the average wait after a quick release is ~4ms (previously ~12ms).
    private static func waitForKeyRelease() async {
        let maxAttempts = 62  // 62 × 8ms ≈ 500ms
        for _ in 0..<maxAttempts {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let hasModifiers = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
            if !hasModifiers { return }
            try? await Task.sleep(for: .milliseconds(8))
        }
        logger.warning("Key release wait timed out after 500ms")
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // V key
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)

        logger.debug("Simulated Cmd+V paste")
    }
}
