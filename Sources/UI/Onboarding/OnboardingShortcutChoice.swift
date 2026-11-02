import AppKit

/// The shortcut presets the onboarding Shortcuts screen offers. Each one is
/// a combination of existing Dictation settings (style plus key), written
/// through the same AppState setters the Settings page uses.
enum OnboardingShortcutChoice: String, CaseIterable, Identifiable {
    /// Separate shortcuts, Fn held to talk (the new-install default).
    case holdFn
    /// One key: hold Fn to talk, tap it to go hands-free.
    case tapOrHoldFn
    /// Separate shortcuts, Right Option held to talk.
    case holdRightOption

    var id: String { rawValue }

    var title: String {
        switch self {
        case .holdFn: return "Hold Fn"
        case .tapOrHoldFn: return "Tap or hold Fn"
        case .holdRightOption: return "Hold Right Option"
        }
    }

    var detail: String {
        switch self {
        case .holdFn: return "Hold to talk, let go to paste."
        case .tapOrHoldFn: return "Hold to talk, or tap to go hands-free."
        case .holdRightOption: return "For keyboards without a Globe key."
        }
    }

    /// The key the card shows.
    var binding: ShortcutBinding {
        switch self {
        case .holdFn, .tapOrHoldFn: return .fnKey
        case .holdRightOption: return .rightOption
        }
    }

    var style: DictationShortcutStyle {
        switch self {
        case .holdFn, .holdRightOption: return .separate
        case .tapOrHoldFn: return .tapOrHold
        }
    }

    /// Fn choices need the Globe key set to Do Nothing, or quick taps open
    /// the Emoji panel too.
    var usesFn: Bool { binding.modifiers.contains(.function) }

    /// The choice the current settings amount to, or nil for a custom
    /// combination made in Settings.
    static func matching(
        style: DictationShortcutStyle,
        hold: ShortcutBinding?,
        tapOrHold: ShortcutBinding
    ) -> OnboardingShortcutChoice? {
        switch style {
        case .tapOrHold:
            return tapOrHold == .fnKey ? .tapOrHoldFn : nil
        case .separate:
            switch hold {
            case ShortcutBinding.fnKey?: return .holdFn
            case ShortcutBinding.rightOption?: return .holdRightOption
            default: return nil
            }
        }
    }
}

extension AppState {
    /// Applies an onboarding preset through the Settings setters. The
    /// hands-free shortcut of the separate style is left as it is.
    func applyShortcutChoice(_ choice: OnboardingShortcutChoice) {
        switch choice.style {
        case .tapOrHold:
            setTapOrHoldShortcut(choice.binding)
        case .separate:
            // A toggle shortcut on the same key would make the hold setter
            // refuse; the toggle default moves out of the way first.
            if toggleShortcut == choice.binding {
                setToggleShortcut(.defaultToggle == choice.binding ? nil : .defaultToggle)
            }
            setHoldShortcut(choice.binding)
        }
        setShortcutStyle(choice.style)
    }

    var currentShortcutChoice: OnboardingShortcutChoice? {
        OnboardingShortcutChoice.matching(style: shortcutStyle, hold: holdShortcut, tapOrHold: tapOrHoldShortcut)
    }

    /// System Settings → Keyboard, where "Press 🌐 key to" lives.
    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
