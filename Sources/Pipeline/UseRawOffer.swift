import AppKit
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "UseRaw")

/// The "Use raw" offer shown after Whispur pastes cleaned text that differs
/// from what the user said. Pure state, driven by a clock the caller passes
/// in, so the rules and the timing are unit-testable.
///
/// The offer is live for `duration` after the paste. While it is live, the
/// shortcut (or a click on the toast) swaps the pasted text for the raw
/// transcript, but only in the app the text was pasted into, and only while
/// nothing else was typed there: the swap undoes the paste, and an undo
/// after more typing would undo the typing instead.
struct UseRawOffer: Equatable {
    struct Offer: Equatable {
        let dictationID: UUID
        let rawTranscript: String
        let pastedText: String
        /// The app the text went into.
        let processID: pid_t
        let bundleID: String?
        let expiresAt: Date
    }

    enum DismissReason: Equatable {
        case expired
        case typed
        case appChanged
        case newDictation
        case disabled
        case used
    }

    enum TriggerResult: Equatable {
        /// Swap the paste for the raw transcript.
        case replace(Offer)
        /// No live offer: the shortcut is not ours right now.
        case ignored
        /// There was an offer but the shortcut came from another app; the
        /// offer is dropped and nothing is replaced.
        case wrongApp
    }

    static let duration: TimeInterval = 4

    /// Apps where undo does not reliably remove a paste (terminals keep
    /// their own line editing and ignore or repurpose Cmd+Z). The offer is
    /// never shown there.
    static let excludedBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.mitchellh.ghostty",
        "org.alacritty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
    ]

    private(set) var current: Offer?
    private(set) var lastDismissReason: DismissReason?

    /// Whether a paste is worth offering the raw transcript for: cleanup
    /// changed the words (not just capitalisation, punctuation or spacing)
    /// and the target app can undo a paste.
    static func shouldOffer(raw: String, pasted: String, bundleID: String?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        let rawWords = words(raw)
        let pastedWords = words(pasted)
        guard !rawWords.isEmpty, !pastedWords.isEmpty, rawWords != pastedWords else { return false }
        if let bundleID, excludedBundleIDs.contains(bundleID) { return false }
        return true
    }

    /// The word sequence of a text: lowercased, punctuation (including
    /// curly quotes and dashes) removed, split on whitespace.
    static func words(_ text: String) -> [String] {
        let stripped = String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        ))
        return stripped.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Starts an offer for a paste. Returns false (and leaves any previous
    /// offer dismissed) when the paste doesn't qualify.
    @discardableResult
    mutating func offer(
        dictationID: UUID,
        raw: String,
        pasted: String,
        processID: pid_t,
        bundleID: String?,
        enabled: Bool,
        now: Date
    ) -> Bool {
        current = nil
        guard Self.shouldOffer(raw: raw, pasted: pasted, bundleID: bundleID, enabled: enabled) else { return false }
        current = Offer(
            dictationID: dictationID,
            rawTranscript: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            pastedText: pasted,
            processID: processID,
            bundleID: bundleID,
            expiresAt: now.addingTimeInterval(Self.duration)
        )
        lastDismissReason = nil
        return true
    }

    /// The live offer at `now`, or nil once it has expired.
    func liveOffer(at now: Date) -> Offer? {
        guard let current, now < current.expiresAt else { return nil }
        return current
    }

    /// The shortcut or a click on the toast. `frontmostProcessID` is the app
    /// in front at that moment.
    mutating func trigger(frontmostProcessID: pid_t?, now: Date) -> TriggerResult {
        guard let offer = liveOffer(at: now) else {
            if current != nil { dismiss(.expired) }
            return .ignored
        }
        guard frontmostProcessID == offer.processID else {
            dismiss(.appChanged)
            return .wrongApp
        }
        dismiss(.used)
        return .replace(offer)
    }

    /// A key other than the shortcut went down while the offer was live.
    mutating func keyTyped() {
        guard current != nil else { return }
        dismiss(.typed)
    }

    mutating func dismiss(_ reason: DismissReason) {
        guard current != nil else { return }
        current = nil
        lastDismissReason = reason
    }
}

/// Runs the "Use raw" offer in the app: the 4 s timer, the toast, the
/// shortcut watch, and the swap itself.
@MainActor
final class UseRawController: ObservableObject {
    /// The offer the toast shows; nil hides it.
    @Published private(set) var visibleOffer: UseRawOffer.Offer?

    private(set) var state = UseRawOffer()
    private var expiryTask: Task<Void, Never>?

    /// Arms or disarms the global shortcut watch.
    var setShortcutWatch: (Bool) -> Void = { _ in }
    /// The process in front right now.
    var frontmostProcessID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    /// Swaps the pasted text for the raw transcript in the focused app.
    /// Returns whether the swap happened.
    var replace: (_ offer: UseRawOffer.Offer) async -> Bool = { _ in false }
    /// Called after a successful swap (history, learning).
    var onUsedRaw: (_ offer: UseRawOffer.Offer) -> Void = { _ in }
    var now: () -> Date = Date.init
    /// How long the toast stays up. Tests shorten it.
    var duration: Duration = .seconds(UseRawOffer.duration)

    private var replacing = false

    func offer(for result: PipelineResult, processID: pid_t?, bundleID: String?, enabled: Bool) {
        expiryTask?.cancel()
        guard let processID,
              state.offer(
                  dictationID: result.id,
                  raw: result.rawTranscript,
                  pasted: result.cleanedText,
                  processID: processID,
                  bundleID: bundleID,
                  enabled: enabled,
                  now: now()
              )
        else {
            publish()
            return
        }
        publish()
        expiryTask = Task { [weak self, duration] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.dismiss(.expired)
        }
    }

    /// The shortcut, or a click on the toast.
    func trigger() {
        guard !replacing else { return }
        let result = state.trigger(frontmostProcessID: frontmostProcessID(), now: now())
        publish()
        guard case let .replace(offer) = result else {
            if result == .wrongApp { logger.info("Use raw ignored: another app is in front") }
            return
        }
        replacing = true
        Task { [weak self] in
            guard let self else { return }
            let swapped = await self.replace(offer)
            self.replacing = false
            if swapped {
                self.onUsedRaw(offer)
            } else {
                logger.warning("Use raw: the pasted text could not be swapped")
            }
        }
    }

    func keyTyped() {
        state.keyTyped()
        publish()
    }

    func dismiss(_ reason: UseRawOffer.DismissReason) {
        state.dismiss(reason)
        if state.current == nil {
            expiryTask?.cancel()
            expiryTask = nil
        }
        publish()
    }

    #if DEBUG
    /// Shows the toast with a fixed offer, for renders.
    func setOfferForRendering(_ offer: UseRawOffer.Offer?) {
        visibleOffer = offer
    }
    #endif

    private func publish() {
        let live = state.current
        if visibleOffer != live { visibleOffer = live }
        setShortcutWatch(live != nil)
    }
}
