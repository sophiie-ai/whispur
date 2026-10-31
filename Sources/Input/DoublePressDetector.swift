import Foundation

/// Pure, clock-injected state machine behind double-press bindings such as
/// "Fn twice". `HotkeyManager` feeds it press/release/interrupt edges for the
/// binding's modifier and maps the returned action to hotkey events; keeping
/// the timing logic here lets it be unit-tested without a CGEventTap.
///
/// Rules:
/// - A clean tap is a press then release of the modifier with no other key
///   or modifier involved, released before `maxTapDuration` (the hold arm
///   threshold). A tap that outlives it was a hold, not a tap.
/// - A second press whose gap from the previous clean tap's release is under
///   `window` returns `.start` immediately, on press. Its release is ignored
///   and the caller suppresses hold for that press, so keeping the second
///   press down never also starts a push-to-talk recording.
/// - While a toggle session is active, a single press returns `.stop` on
///   press. A press that lands within `window` of the starting release is
///   swallowed instead, so an accidental triple tap does not start and then
///   immediately stop the session.
/// - Any other key or modifier (`interrupt()`) resets tracking.
struct DoublePressDetector: Sendable {
    enum Action: Equatable, Sendable {
        /// Nothing to emit (first tap, or a tap that may become one).
        case none
        /// Second clean tap: start the toggle session.
        case start
        /// Single press during an active session: stop it.
        case stop
        /// Press consumed without an action (triple-tap guard).
        case swallow
    }

    private enum Phase: Equatable, Sendable {
        case idle
        /// Modifier down, may become the first clean tap.
        case firstDown(at: TimeInterval)
        /// First clean tap released; waiting for a second press.
        case firstUp(at: TimeInterval)
        /// Press already acted on (start, stop or swallow); release is ignored.
        case consumedDown
        /// Modifier down but chorded with something else; cannot be a tap.
        case taintedDown
    }

    var window: TimeInterval
    var maxTapDuration: TimeInterval

    private var phase: Phase = .idle
    private var awaitingStartRelease = false
    private var startReleasedAt: TimeInterval?

    init(window: TimeInterval, maxTapDuration: TimeInterval) {
        self.window = window
        self.maxTapDuration = maxTapDuration
    }

    /// The binding's modifier went down at `time`.
    mutating func press(at time: TimeInterval, sessionActive: Bool) -> Action {
        if sessionActive {
            if let startReleasedAt, time - startReleasedAt < window {
                phase = .consumedDown
                return .swallow
            }
            startReleasedAt = nil
            phase = .consumedDown
            return .stop
        }

        if case .firstUp(let releasedAt) = phase, time >= releasedAt, time - releasedAt < window {
            phase = .consumedDown
            awaitingStartRelease = true
            return .start
        }

        phase = .firstDown(at: time)
        return .none
    }

    /// The binding's modifier went up at `time`.
    mutating func release(at time: TimeInterval) {
        switch phase {
        case .firstDown(let pressedAt):
            phase = time - pressedAt < maxTapDuration ? .firstUp(at: time) : .idle
        case .consumedDown, .taintedDown, .idle, .firstUp:
            phase = .idle
        }
        if awaitingStartRelease {
            awaitingStartRelease = false
            startReleasedAt = time
        }
    }

    /// Another key or modifier was involved. Chords never count as taps.
    mutating func interrupt() {
        switch phase {
        case .firstDown, .consumedDown, .taintedDown:
            phase = .taintedDown
        case .idle, .firstUp:
            phase = .idle
        }
        // A deliberate keystroke after starting means the next press is a
        // real stop, not the tail of a triple tap.
        if !awaitingStartRelease {
            startReleasedAt = nil
        }
    }

    mutating func reset() {
        phase = .idle
        awaitingStartRelease = false
        startReleasedAt = nil
    }
}
