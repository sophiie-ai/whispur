import Foundation

enum ShortcutSessionAction: Equatable {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
}

/// Coordinates hold and toggle shortcut events so mode transitions feel predictable.
///
/// Toggle stop needs the shortcut to be released after the start
/// (`toggleDeactivated` arms the stop) and pressed again (`toggleActivated`
/// stops). Double-press bindings (Fn twice) fit the same contract:
/// HotkeyManager emits `toggleActivated` then `toggleDeactivated` on the
/// second tap, and a lone `toggleActivated` on the single stop press.
final class ShortcutSessionController {
    private(set) var activeMode: RecordingTriggerMode?
    private(set) var toggleStopArmed = false

    func handle(event: HotkeyManager.Event, isBusy: Bool) -> ShortcutSessionAction? {
        if activeMode == nil {
            guard !isBusy else { return nil }

            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                return .start(.toggle)
            case .holdActivated:
                activeMode = .hold
                toggleStopArmed = false
                return .start(.hold)
            case .holdDeactivated, .toggleDeactivated, .cancelRequested:
                return nil
            }
        }

        switch activeMode {
        case .hold:
            switch event {
            case .toggleActivated:
                activeMode = .toggle
                toggleStopArmed = false
                return .switchedToToggle
            case .holdDeactivated:
                reset()
                return .stop
            case .holdActivated, .toggleDeactivated, .cancelRequested:
                return nil
            }

        case .toggle:
            switch event {
            case .toggleDeactivated:
                toggleStopArmed = true
                return nil
            case .toggleActivated:
                guard toggleStopArmed else { return nil }
                reset()
                return .stop
            case .holdActivated, .holdDeactivated, .cancelRequested:
                return nil
            }

        case .none:
            return nil
        }
    }

    /// A manual start (menu button) holds no shortcut key down, so a toggle
    /// session is armed immediately: the next toggle shortcut press stops it.
    func beginManual(mode: RecordingTriggerMode) {
        activeMode = mode
        toggleStopArmed = mode == .toggle
    }

    func switchToToggleMode() {
        activeMode = .toggle
        toggleStopArmed = false
    }

    func reset() {
        activeMode = nil
        toggleStopArmed = false
    }
}
