import Foundation

enum ShortcutSessionAction {
    case start(RecordingTriggerMode)
    case stop
    case switchedToToggle
}

/// Coordinates hold and toggle shortcut events so mode transitions feel predictable.
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
            case .holdDeactivated, .toggleDeactivated:
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
            case .holdActivated, .toggleDeactivated:
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
            case .holdActivated, .holdDeactivated:
                return nil
            }

        case .none:
            return nil
        }
    }

    func beginManual(mode: RecordingTriggerMode) {
        activeMode = mode
        toggleStopArmed = false
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
