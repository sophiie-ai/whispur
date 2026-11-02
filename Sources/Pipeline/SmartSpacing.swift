import ApplicationServices
import Foundation

/// Smart spacing at paste time: when the cursor sits right after a word (or
/// after the end of a sentence), the dictation gets one leading space, so
/// "Hello.|" plus "How are you?" pastes as "Hello. How are you?" instead of
/// "Hello.How are you?".
///
/// The character before the cursor is read through Accessibility. No space
/// is added at the start of a field, after a space, line break or opening
/// bracket or quote, before text that starts with punctuation, or next to
/// CJK, Thai and other scripts written without spaces. When the field can't
/// be read (no Accessibility access, a secure field, an app that doesn't
/// report its cursor) or the app is a terminal, nothing is added: the paste
/// is exactly what it was before.
enum SmartSpacing {
    /// What sits right before the insertion point.
    enum Before: Equatable {
        /// The cursor is at the start of the field.
        case fieldStart
        case character(Character)
        /// The field couldn't be read.
        case unknown
    }

    /// Terminals keep their own line editing; their Accessibility cursor is
    /// not where typing goes.
    static let excludedBundleIDs: Set<String> = UseRawOffer.excludedBundleIDs

    /// `text` with a leading space when `before` calls for one.
    static func adjusted(_ text: String, before: Before) -> String {
        needsLeadingSpace(before: before, text: text) ? " " + text : text
    }

    static func needsLeadingSpace(before: Before, text: String) -> Bool {
        guard case let .character(previous) = before, let first = text.first else { return false }
        guard attachesAfter(previous) else { return false }
        guard first.isLetterOrNumber || "\u{201C}\u{2018}([\"#@".contains(first) else { return false }
        return !isUnspacedScript(previous) && !isUnspacedScript(first)
    }

    /// Characters a following word is separated from by a space.
    private static func attachesAfter(_ c: Character) -> Bool {
        c.isLetterOrNumber || ".,;:!?)]}\u{201D}\u{2019}%".contains(c)
    }

    /// Scripts that don't put spaces between words (same set as Hex's
    /// replacement boundaries).
    static func isUnspacedScript(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xAC00 ... 0xD7AF, // Hangul
                 0x2E80 ... 0x2FDF, 0x3000 ... 0x303F, // CJK radicals, punctuation
                 0x3040 ... 0x30FF, 0x31F0 ... 0x31FF, // Hiragana, Katakana
                 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF, // Han
                 0xFF00 ... 0xFFEF, // Fullwidth forms
                 0x0E00 ... 0x0EFF, // Thai, Lao
                 0x0F00 ... 0x0FFF, // Tibetan
                 0x1000 ... 0x109F, // Myanmar
                 0x1780 ... 0x17FF: // Khmer
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Reading the field

    /// How long one Accessibility call may block before the field counts as
    /// unreadable.
    static let messagingTimeout: Float = 0.12

    /// Reads the character before the insertion point of the focused text
    /// field. Call off the main thread: a slow app blocks for up to
    /// `messagingTimeout` per call.
    nonisolated static func readBeforeCursor() -> Before {
        guard AXIsProcessTrusted() else { return .unknown }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return .unknown }
        let element = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        if isSecure(element) { return .unknown }

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return .unknown }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location >= 0 else { return .unknown }
        if range.location == 0 { return .fieldStart }

        // The last composed character before the cursor. Ranges are UTF-16.
        if let character = character(in: element, endingAt: range.location) {
            return .character(character)
        }
        return .unknown
    }

    private static func character(in element: AXUIElement, endingAt location: CFIndex) -> Character? {
        // A short window before the cursor, enough for any composed
        // character (emoji sequences, combining marks).
        let length = min(location, 8)
        var window = CFRange(location: location - length, length: length)
        if let rangeValue = AXValueCreate(.cfRange, &window) {
            var stringRef: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, rangeValue, &stringRef
            ) == .success, let string = stringRef as? String, let last = string.last {
                return last
            }
        }
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String
        else { return nil }
        let utf16 = value.utf16
        guard location <= utf16.count,
              let end = utf16.index(utf16.startIndex, offsetBy: location, limitedBy: utf16.endIndex),
              let endIndex = end.samePosition(in: value) ?? String.Index(end, within: value)
        else { return nil }
        return value[..<endIndex].last
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if (role as? String) == "AXSecureTextField" { return true }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        return (subrole as? String)?.lowercased().contains("secure") ?? false
    }
}
