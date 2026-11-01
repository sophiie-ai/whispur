import Foundation

/// Pure, clock-injected state machine behind the "Tap or hold" shortcut
/// style, where one key does both jobs: hold it to talk until it lifts, or
/// tap it to lock a hands-free recording that the next tap stops.
///
/// `HotkeyManager` feeds it the binding's press/release edges, chord keys,
/// and the veto timer firing, then maps the returned action to hotkey
/// events. Keeping the timing here lets it be unit-tested without a
/// CGEventTap.
///
/// Timeline of one press (bare modifier such as Fn):
///
///     press ── vetoWindow ──┬── holdThreshold ──┬──▶
///      arming: a chord key  │ recording (hold   │ recording (hold):
///      cancels silently;    │ overlay): release │ release stops,
///      release = tap, start │ = tap, lock;      │ chord keys ignored
///      locked               │ chord = cancel    │
///
/// - Recording starts when the veto window passes with the key still
///   down, so a tap doesn't lose its first word waiting to find out it was
///   a tap. A release before then also starts, already locked.
/// - Release before `holdThreshold` (measured from the press) is a tap:
///   the recording keeps going, locked. After it is a hold: release stops.
/// - A chord key inside `holdThreshold` means the key was used as a
///   modifier (Fn+Delete, Fn+arrow): before the recording started nothing
///   happens, after it the recording is discarded rather than locked open.
/// - While locked, the next clean press stops: on release, or when the veto
///   window passes with the key still down. A chord leaves it locked.
/// - A press with `sessionActive` set (a recording started from the menu)
///   takes the same stop path, so the key always stops what is running.
struct TapOrHoldDetector: Sendable {
    enum Action: Equatable, Sendable {
        /// Nothing to emit.
        case none
        /// Start a recording in hold mode (key still down).
        case startHolding
        /// Start a recording already locked (a tap released before the
        /// veto window passed).
        case startLocked
        /// The holding recording was a tap: switch it to locked.
        case lock
        /// Stop the held recording (the key was held past the threshold).
        case stopHold
        /// Stop the locked recording.
        case stopLocked
        /// Discard the recording: the key turned out to be a chord modifier.
        case cancel
    }

    enum Phase: Equatable, Sendable {
        case idle
        /// Key down, inside the veto window, nothing started yet.
        case arming(pressedAt: TimeInterval)
        /// Key down, recording in hold mode.
        case holding(pressedAt: TimeInterval)
        /// Key up, recording locked (hands-free).
        case locked
        /// Key down during a locked recording, inside the veto window.
        case stopArming
        /// Key down during a locked recording but chorded: release returns
        /// to `locked`.
        case lockedChord
        /// Key down, already acted on or chorded: release does nothing.
        case suppressed
    }

    var vetoWindow: TimeInterval
    var holdThreshold: TimeInterval

    private(set) var phase: Phase = .idle
    /// Bumped on every press so a veto timer from an earlier press is ignored.
    private(set) var generation = 0
    /// Whether a recording is running however it started. Mirrored from the
    /// session controller; a press while it is set and the detector is idle
    /// stops that recording.
    private(set) var sessionActive = false

    init(vetoWindow: TimeInterval, holdThreshold: TimeInterval) {
        self.vetoWindow = vetoWindow
        self.holdThreshold = holdThreshold
    }

    /// True while the detector is waiting for its veto timer.
    var isArming: Bool {
        switch phase {
        case .arming, .stopArming: return true
        default: return false
        }
    }

    /// The binding's key went down at `time`.
    mutating func press(at time: TimeInterval) -> Action {
        generation += 1
        return settle(pressAction(at: time))
    }

    private mutating func pressAction(at time: TimeInterval) -> Action {
        switch phase {
        case .idle where sessionActive, .locked:
            if vetoWindow <= 0 {
                phase = .suppressed
                return .stopLocked
            }
            phase = .stopArming
            return .none
        case .idle:
            if vetoWindow <= 0 {
                phase = .holding(pressedAt: time)
                return .startHolding
            }
            phase = .arming(pressedAt: time)
            return .none
        case .arming, .holding, .stopArming, .lockedChord, .suppressed:
            // Already down (duplicate edge): nothing new.
            return .none
        }
    }

    /// The veto timer scheduled for press `generation` fired at `time` with
    /// the key still down.
    mutating func vetoElapsed(generation: Int, at time: TimeInterval) -> Action {
        settle(vetoElapsedAction(generation: generation, at: time))
    }

    private mutating func vetoElapsedAction(generation: Int, at time: TimeInterval) -> Action {
        guard generation == self.generation else { return .none }
        switch phase {
        case .arming(let pressedAt):
            phase = .holding(pressedAt: pressedAt)
            return .startHolding
        case .stopArming:
            phase = .suppressed
            return .stopLocked
        default:
            return .none
        }
    }

    /// The binding's key went up at `time`.
    mutating func release(at time: TimeInterval) -> Action {
        settle(releaseAction(at: time))
    }

    private mutating func releaseAction(at time: TimeInterval) -> Action {
        switch phase {
        case .arming:
            phase = .locked
            return .startLocked
        case .holding(let pressedAt):
            if time - pressedAt < holdThreshold {
                phase = .locked
                return .lock
            }
            phase = .idle
            return .stopHold
        case .stopArming:
            phase = .idle
            return .stopLocked
        case .lockedChord:
            phase = .locked
            return .none
        case .suppressed:
            phase = .idle
            return .none
        case .idle, .locked:
            return .none
        }
    }

    /// The key went up, but the release was not observed directly (the
    /// event tap was off and a resync found it up). The release time is
    /// unknown, so never lock a recording open on it: a pending start is
    /// dropped and a running recording stops.
    mutating func releaseUnobserved() -> Action {
        settle(releaseUnobservedAction())
    }

    private mutating func releaseUnobservedAction() -> Action {
        switch phase {
        case .arming, .suppressed:
            phase = .idle
            return .none
        case .holding:
            phase = .idle
            return .stopHold
        case .stopArming:
            phase = .idle
            return .stopLocked
        case .lockedChord:
            phase = .locked
            return .none
        case .idle, .locked:
            return .none
        }
    }

    /// Another key or modifier was pressed while the binding's key is down.
    mutating func chord(at time: TimeInterval) -> Action {
        settle(chordAction(at: time))
    }

    private mutating func chordAction(at time: TimeInterval) -> Action {
        switch phase {
        case .arming:
            phase = .suppressed
            return .none
        case .holding(let pressedAt):
            guard time - pressedAt < holdThreshold else { return .none }
            phase = .suppressed
            return .cancel
        case .stopArming:
            phase = .lockedChord
            return .none
        case .idle, .locked, .lockedChord, .suppressed:
            return .none
        }
    }

    /// Mirror whether a recording session is running. When it ends from
    /// outside (Esc, the Stop button, an error, a busy pipeline refusing the
    /// start), the detector forgets it: a key still down is ignored until
    /// released, and a lock is dropped.
    mutating func setSessionActive(_ active: Bool) {
        sessionActive = active
        guard !active else { return }
        switch phase {
        case .holding, .stopArming, .lockedChord:
            phase = .suppressed
        case .locked:
            phase = .idle
        case .idle, .arming, .suppressed:
            break
        }
    }

    /// A stop or cancel ends the session here and now, so a quick next
    /// press starts afresh instead of waiting for the controller's mirror.
    private mutating func settle(_ action: Action) -> Action {
        switch action {
        case .stopHold, .stopLocked, .cancel:
            sessionActive = false
        case .none, .startHolding, .startLocked, .lock:
            break
        }
        return action
    }

    mutating func reset() {
        phase = .idle
        generation += 1
    }
}
