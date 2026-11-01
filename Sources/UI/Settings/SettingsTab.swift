import Foundation

/// Pages of the Settings window, in sidebar order.
enum SettingsTab: String, CaseIterable, Identifiable {
    case dictation
    case dictionary
    case styles
    case getStarted
    case providers
    case preferences
    case activity
    case requests

    var id: String { rawValue }

    /// Sidebar groups. `main` has no label.
    enum Group: CaseIterable {
        case main
        case setup
        case diagnostics

        var title: String? {
            switch self {
            case .main: return nil
            case .setup: return "Setup"
            case .diagnostics: return "Diagnostics"
            }
        }
    }

    /// Pages that appear in the sidebar.
    static let visible: [SettingsTab] = allCases

    static func tabs(in group: Group) -> [SettingsTab] {
        visible.filter { $0.group == group }
    }

    var group: Group {
        switch self {
        case .dictation, .dictionary, .styles: return .main
        case .getStarted, .providers, .preferences: return .setup
        case .activity, .requests: return .diagnostics
        }
    }

    var title: String {
        switch self {
        case .dictation: return "Dictation"
        case .dictionary: return "Dictionary"
        case .styles: return "Styles"
        case .getStarted: return "Get started"
        case .providers: return "Providers"
        case .preferences: return "Preferences"
        case .activity: return "Activity"
        case .requests: return "Requests"
        }
    }

    var icon: String {
        switch self {
        case .dictation: return "waveform"
        case .dictionary: return "book.closed"
        case .styles: return "textformat"
        case .getStarted: return "sparkles"
        case .providers: return "key"
        case .preferences: return "slider.horizontal.3"
        case .activity: return "clock.arrow.circlepath"
        case .requests: return "network"
        }
    }

    /// One line under the page title.
    var summary: String {
        switch self {
        case .dictation:
            return "Your shortcuts, recent dictations, and personalization."
        case .dictionary:
            return "Words Whispur should always spell your way."
        case .styles:
            return "How Whispur cleans up your words, per app."
        case .getStarted:
            return "The few steps that get Whispur ready to dictate anywhere on your Mac."
        case .providers:
            return "Choose who transcribes and who cleans up, and keep their keys in your Keychain."
        case .preferences:
            return "Permissions, sounds, and how Whispur behaves while you dictate."
        case .activity:
            return "Recent dictations with the raw and cleaned transcript side by side."
        case .requests:
            return "Every provider request with its status, timing, and error message."
        }
    }

    /// The page the window opens on when nothing asked for a specific one:
    /// Dictation once setup is complete, otherwise Get started.
    static func landing(setupComplete: Bool) -> SettingsTab {
        setupComplete ? .dictation : .getStarted
    }

    /// Decodes a stored selection, including the tab names used before the
    /// redesign ("Setup", "General", "Prompts", …). Unknown or empty values
    /// return nil so the caller falls back to the landing page.
    init?(storedValue: String) {
        if let tab = SettingsTab(rawValue: storedValue) {
            self = tab
            return
        }
        switch storedValue {
        case "Setup": self = .getStarted
        case "General": self = .preferences
        // The old Prompts tab held the vocabulary; the dictionary is its home now.
        case "Prompts": self = .dictionary
        case "Providers": self = .providers
        case "Activity": self = .activity
        case "Requests": self = .requests
        default: return nil
        }
    }
}

/// The setup state the Settings window shows: the readiness pill, the Get
/// started badge, and the landing page.
struct SettingsSetupState: Equatable {
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var speechReady: Bool
    var hasDictated: Bool
    /// At least one of the two dictation shortcuts is set.
    var hasShortcut: Bool = true

    /// Ready for daily use: both permissions, a working speech provider, and
    /// a shortcut to start dictating with.
    var isComplete: Bool {
        microphoneGranted && accessibilityGranted && speechReady && hasShortcut
    }

    /// Get started steps still open (the first dictation counts as a step).
    var pendingSteps: Int {
        [microphoneGranted, accessibilityGranted, speechReady, hasShortcut, hasDictated].filter { !$0 }.count
    }

    var landingTab: SettingsTab {
        SettingsTab.landing(setupComplete: isComplete)
    }
}
