import Foundation

/// Tracks the microphone capture a bare-modifier shortcut starts at key-down,
/// before it is known whether the press is a hold.
///
/// A bare modifier such as Fn has to wait before it can call a press a hold:
/// a quick tap belongs to macOS (emoji picker, dictation) and Fn+Delete or
/// Fn+arrow is a chord. Waiting for that before turning on the microphone
/// loses the first word, so `HotkeyManager` starts capturing when the wait
/// begins and resolves it when the wait ends: kept if the press became a
/// recording, discarded otherwise.
///
/// The tracker makes sure each begin gets exactly one resolution and that a
/// second press can't begin a capture while one is still open. Pure, so the
/// rules can be tested without an event tap.
struct EarlyCapture: Sendable, Equatable {
    enum Signal: Sendable, Equatable {
        /// Start capturing quietly: no overlay, no sound.
        case begin
        /// Stop and throw the capture away: no overlay, no sound, no file.
        case discard
    }

    private(set) var isOpen = false

    /// The wait before a hold started. Returns `.begin` unless a capture is
    /// already open.
    mutating func waitStarted() -> Signal? {
        guard !isOpen else { return nil }
        isOpen = true
        return .begin
    }

    /// The wait ended. `startedRecording` is true when the press became a
    /// recording, which takes over the capture, so nothing is signalled;
    /// otherwise the capture is discarded. No-op when nothing is open.
    mutating func waitEnded(startedRecording: Bool) -> Signal? {
        guard isOpen else { return nil }
        isOpen = false
        return startedRecording ? nil : .discard
    }
}
