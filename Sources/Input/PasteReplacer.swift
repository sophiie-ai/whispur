import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "PasteReplacer")

/// Swaps text Whispur just pasted for other text ("Use raw").
///
/// The swap is Cmd+Z, then a normal paste. Undo was chosen over selecting
/// the pasted range with Shift+Left × length because:
/// - a paste is one undo step in Cocoa text views, WebKit/Chromium fields and
///   Electron apps, and undoing it restores the field exactly, including any
///   selection the paste replaced;
/// - Shift+Left counts characters the way the app does, which breaks when
///   the app rewrote the paste (smart quotes, auto-indent, "- " turned into a
///   list bullet, emoji and CRLF clusters) and can then select and destroy
///   text the user wrote; it is also one key event per character.
///
/// Undo's failure mode is an app where Cmd+Z doesn't remove the paste
/// (terminals). Those are excluded from the offer (`UseRawOffer`), and when
/// the focused field can be read over Accessibility the swap checks that the
/// undo actually changed it before pasting, so a no-op undo never leaves the
/// text pasted twice.
enum PasteReplacer {
    enum Outcome: Equatable {
        case replaced
        /// The focused field doesn't hold the pasted text any more.
        case pastedTextNotFound
        /// Cmd+Z left the field unchanged.
        case undoHadNoEffect
        case secureField
    }

    /// The decision after reading the field before and after the undo.
    /// `nil` reads mean the app doesn't expose its text; the swap then
    /// trusts the undo.
    static func decide(pasted: String, before: String?, after: String?) -> Outcome {
        if let before, !normalized(before).contains(normalized(pasted)) {
            return .pastedTextNotFound
        }
        if let before, let after, before == after {
            return .undoHadNoEffect
        }
        return .replaced
    }

    @MainActor
    static func replaceLastPaste(pasted: String, with replacement: String, preserveClipboard: Bool) async -> Outcome {
        await waitForModifierRelease()

        let element = focusedElement()
        if let element, isSecure(element) { return .secureField }
        let before = await read(element)
        if case .pastedTextNotFound = decide(pasted: pasted, before: before, after: nil) {
            logger.info("Use raw skipped: the focused field no longer holds the pasted text")
            return .pastedTextNotFound
        }

        postKey(0x06, flags: .maskCommand) // Cmd+Z
        try? await Task.sleep(for: .milliseconds(90))
        let after = await read(element)
        let outcome = decide(pasted: pasted, before: before, after: after)
        guard outcome == .replaced else {
            logger.info("Use raw skipped: undo did not change the field")
            return outcome
        }

        await TextInjector.paste(replacement, preserveClipboard: preserveClipboard)
        return .replaced
    }

    // MARK: - Helpers

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The shortcut is ⌥⌘Z: a synthetic Cmd+Z sent while Option is still
    /// held would arrive as ⌥⌘Z in the app.
    private static func waitForModifierRelease() async {
        for _ in 0..<62 {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if !flags.contains(.maskCommand), !flags.contains(.maskAlternate),
               !flags.contains(.maskShift), !flags.contains(.maskControl) {
                return
            }
            try? await Task.sleep(for: .milliseconds(8))
        }
    }

    private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cgSessionEventTap)
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &role)
        return (role as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Reads the field's text off the main thread: Accessibility calls into
    /// another app can stall.
    private static func read(_ element: AXUIElement?) async -> String? {
        guard let element else { return nil }
        let text = await Task.detached(priority: .userInitiated) { () -> String? in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
            return value as? String
        }.value
        // Some apps answer with an empty value for fields they don't expose.
        return text?.isEmpty == true ? nil : text
    }
}
