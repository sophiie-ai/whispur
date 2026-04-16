import AppKit
import ApplicationServices
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Learning")

/// Captures what Whispur just pasted and, on the next dictation, re-reads
/// the focused text field to see whether the user corrected any words.
/// Word-level substitutions are proposed (via a confirmation alert) as
/// additions to the custom vocabulary so STT biases toward them next time.
@MainActor
final class TranscriptLearning {
    struct Snapshot {
        let element: AXUIElement
        let pastedText: String
        let fullValue: String
        let bundleID: String?
        let capturedAt: Date
    }

    private var pending: Snapshot?

    /// Called when the user confirms a substitution. Expected to append the
    /// term to the custom vocabulary (deduping is the caller's job).
    var onLearnTerm: ((_ from: String, _ to: String) -> Void)?

    /// True iff the feature is enabled. Callers read this before capturing.
    var isEnabled: Bool = false

    /// When non-nil, learning suggestions are enqueued on this center and
    /// rendered as a non-modal toast instead of a blocking NSAlert. Set by
    /// AppState during wiring.
    weak var suggestionCenter: LearningSuggestionCenter?

    // MARK: - Capture (right after paste)

    func captureAfterPaste(pastedText: String) {
        guard isEnabled else { return }
        guard !pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        guard let element = Self.copyFocusedTextElement() else {
            logger.debug("Learning capture skipped: no focused text element")
            return
        }

        // Refuse password fields — we never want to read their contents.
        if Self.isSecureField(element) {
            logger.debug("Learning capture skipped: secure text field")
            return
        }

        let fullValue = Self.copyValue(element) ?? ""
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        pending = Snapshot(
            element: element,
            pastedText: pastedText,
            fullValue: fullValue,
            bundleID: bundleID,
            capturedAt: Date()
        )
        logger.info("Learning snapshot captured (\(pastedText.count) chars, bundle=\(bundleID ?? "-"))")
    }

    // MARK: - Reconcile (next dictation start)

    /// Compare the pasted text against the current element value. If the
    /// user made clean word-level substitutions, show a confirmation alert
    /// for each (up to 3) and invoke `onLearnTerm` for any they accept.
    func reconcile() async {
        guard isEnabled else { return }
        guard let snapshot = pending else { return }
        pending = nil

        // Stale after 5 minutes — reading long-abandoned fields is creepy.
        if Date().timeIntervalSince(snapshot.capturedAt) > 300 {
            logger.debug("Learning reconcile skipped: snapshot stale")
            return
        }

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard bundleID == snapshot.bundleID else {
            logger.debug("Learning reconcile skipped: app changed")
            return
        }

        guard let currentValue = Self.copyValue(snapshot.element) else {
            logger.debug("Learning reconcile skipped: element no longer readable")
            return
        }

        // If the field text doesn't contain recognizable remnants of what we
        // pasted, the user probably replaced the whole thing — not a targeted
        // edit. Bail rather than guess.
        guard Self.pastedStillPresent(pasted: snapshot.pastedText, in: currentValue) else {
            logger.debug("Learning reconcile skipped: pasted text no longer recognizable in field")
            return
        }

        let substitutions = Self.wordSubstitutions(
            pasted: snapshot.pastedText,
            fullValueBefore: snapshot.fullValue,
            fullValueAfter: currentValue
        )
        guard !substitutions.isEmpty else { return }

        // Cap at 3 — more than that usually means the user rewrote the
        // sentence for style, not corrected STT.
        let capped = substitutions.prefix(3)

        // Prefer the non-blocking toast when a suggestion center is wired
        // up. The old NSAlert path remains as a fallback so background
        // learning keeps working in tests or unwired instantiations.
        if let center = suggestionCenter {
            let suggestions = capped.map {
                VocabularySuggestion(from: $0.from, to: $0.to)
            }
            center.present(suggestions)
        } else {
            for sub in capped {
                if await promptToLearn(from: sub.from, to: sub.to) {
                    onLearnTerm?(sub.from, sub.to)
                }
            }
        }
    }

    // MARK: - Prompt

    private func promptToLearn(from: String, to: String) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.messageText = "Learn this correction?"
            alert.informativeText = "You changed \"\(from)\" → \"\(to)\". Add \"\(to)\" to the custom vocabulary so STT prefers it next time?"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Add to vocabulary")
            alert.addButton(withTitle: "Not this one")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    // MARK: - AX helpers

    private static func copyFocusedTextElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    private static func copyValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }

    private static func isSecureField(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        if let roleStr = role as? String, roleStr == "AXSecureTextField" {
            return true
        }
        var subrole: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        if let subroleStr = subrole as? String, subroleStr.lowercased().contains("secure") {
            return true
        }
        return false
    }

    // MARK: - Diff

    /// Returns true iff at least 60% of the pasted text's non-trivial words
    /// still appear (in order) in the current field value. Lets us skip
    /// "user wiped the field and typed something completely new" cases.
    static func pastedStillPresent(pasted: String, in current: String) -> Bool {
        let pastedWords = tokenize(pasted).map { $0.lowercased() }.filter { $0.count > 1 }
        guard !pastedWords.isEmpty else { return false }
        let currentWords = Set(tokenize(current).map { $0.lowercased() })
        let hits = pastedWords.filter { currentWords.contains($0) }.count
        return Double(hits) / Double(pastedWords.count) >= 0.6
    }

    /// Word-level substitutions the user made to the pasted text.
    /// Compares the pasted tokens against the tokens in `fullValueAfter`
    /// anchored to where the pasted text sits — falls back to diffing the
    /// full values if we can't localize the paste.
    static func wordSubstitutions(
        pasted: String,
        fullValueBefore: String,
        fullValueAfter: String
    ) -> [(from: String, to: String)] {
        // Try to localize by finding the pasted text's bounds in the
        // before-snapshot, then compare against the same slice in the
        // after-snapshot. If the slice boundaries shifted, diff ranges.
        let pastedTokens = tokenize(pasted)
        guard !pastedTokens.isEmpty else { return [] }

        // Heuristic: diff pastedTokens against every window of the same
        // approximate size in the after-value, pick the window with the
        // most overlap, then emit paired substitutions from that window's
        // diff. Simple and works for typical edits.
        let afterTokens = tokenize(fullValueAfter)
        guard !afterTokens.isEmpty else { return [] }

        let bestWindow = findBestWindow(
            needle: pastedTokens.map { $0.lowercased() },
            haystack: afterTokens.map { $0.lowercased() }
        )
        let editedTokens: [String]
        if let bestWindow {
            editedTokens = Array(afterTokens[bestWindow])
        } else {
            editedTokens = afterTokens
        }

        return pairedSubstitutions(original: pastedTokens, edited: editedTokens)
    }

    private static func findBestWindow(needle: [String], haystack: [String]) -> Range<Int>? {
        guard !needle.isEmpty, !haystack.isEmpty else { return nil }
        // Allow the window to grow/shrink by up to 40% vs the needle length,
        // covering typical word-level edits.
        let baseLen = needle.count
        let minLen = max(1, Int(Double(baseLen) * 0.6))
        let maxLen = min(haystack.count, Int(Double(baseLen) * 1.4) + 1)
        let needleSet = Set(needle)

        var best: Range<Int>?
        var bestScore = 0
        for len in stride(from: maxLen, through: minLen, by: -1) {
            if len > haystack.count { continue }
            for start in 0...(haystack.count - len) {
                let window = haystack[start ..< (start + len)]
                let score = window.filter { needleSet.contains($0) }.count
                if score > bestScore {
                    bestScore = score
                    best = start ..< (start + len)
                }
            }
        }
        // Require at least half the needle words to match somewhere in the
        // window; otherwise we're not looking at an edit of the paste.
        return bestScore >= max(1, baseLen / 2) ? best : nil
    }

    /// Emit `(removed, inserted)` pairs where a remove and an insert land
    /// at the same offset in Foundation's `CollectionDifference`.
    private static func pairedSubstitutions(original: [String], edited: [String]) -> [(from: String, to: String)] {
        let originalKeys = original.map { normalizedKey($0) }
        let editedKeys = edited.map { normalizedKey($0) }
        let diff = editedKeys.difference(from: originalKeys)

        var removes: [Int: Int] = [:] // offset → index into `original`
        var inserts: [Int: Int] = [:] // offset → index into `edited`
        for change in diff {
            switch change {
            case let .remove(offset, _, _):
                removes[offset] = offset
            case let .insert(offset, _, _):
                inserts[offset] = offset
            }
        }

        var pairs: [(String, String)] = []
        for offset in removes.keys.sorted() {
            guard let origIdx = removes[offset], origIdx < original.count else { continue }
            guard let edIdx = inserts[offset], edIdx < edited.count else { continue }
            let from = original[origIdx]
            let to = edited[edIdx]
            let fromKey = normalizedKey(from)
            let toKey = normalizedKey(to)
            if fromKey == toKey || toKey.isEmpty { continue }
            pairs.append((from, to))
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { String($0) }
    }

    private static func normalizedKey(_ word: String) -> String {
        word
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
    }
}
