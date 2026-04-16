import AppKit
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "TextInjector")

/// Pastes text into the active application while preserving the previous clipboard contents when possible.
enum TextInjector {
    static func paste(_ text: String, preserveClipboard: Bool = true) async {
        // Wait for modifier keys to be released (Fn, etc.)
        await waitForKeyRelease()

        guard !Task.isCancelled else {
            logger.info("Paste cancelled before clipboard write")
            return
        }

        let pasteboard = NSPasteboard.general

        // Snapshot current clipboard
        var savedItems: [NSPasteboardItem]?
        if preserveClipboard {
            savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                return newItem
            }
        }

        // Write text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let pasteChangeCount = pasteboard.changeCount

        // Wait 30ms for app focus to return
        try? await Task.sleep(for: .milliseconds(30))

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

    /// Wait up to 600ms for all modifier keys to be released.
    private static func waitForKeyRelease() async {
        let maxAttempts = 24  // 24 × 25ms = 600ms
        for _ in 0..<maxAttempts {
            let flags = CGEventSource.flagsState(.hidSystemState)
            let hasModifiers = flags.contains(.maskSecondaryFn)
                || flags.contains(.maskCommand)
                || flags.contains(.maskAlternate)
                || flags.contains(.maskControl)
            if !hasModifiers { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        logger.warning("Key release wait timed out after 600ms")
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
