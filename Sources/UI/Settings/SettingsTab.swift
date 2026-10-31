import Foundation

enum SettingsTab: String, CaseIterable, Identifiable {
    case setup = "Setup"
    case general = "General"
    case providers = "Providers"
    case prompts = "Prompts"
    case activity = "Activity"
    case requests = "Requests"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .setup:
            return "sparkles"
        case .general:
            return "slider.horizontal.3"
        case .providers:
            return "key.fill"
        case .prompts:
            return "text.bubble.fill"
        case .activity:
            return "clock.arrow.circlepath"
        case .requests:
            return "network"
        }
    }

    var subtitle: String {
        switch self {
        case .setup:
            return "Get ready to dictate"
        case .general:
            return "Shortcuts, permissions, and behavior"
        case .providers:
            return "Speech and cleanup services"
        case .prompts:
            return "Cleanup instructions and vocabulary"
        case .activity:
            return "Recent transcripts and pipeline output"
        case .requests:
            return "Provider API calls, errors, and timings"
        }
    }

    /// One line under the tab title in the detail pane.
    var summary: String {
        switch self {
        case .setup:
            return "The few steps that get Whispur ready to dictate anywhere on your Mac."
        case .general:
            return "Recording shortcuts, permissions, and how Whispur behaves while you dictate."
        case .providers:
            return "Choose who transcribes and who cleans up, and keep their keys in your Keychain."
        case .prompts:
            return "Tune the cleanup instructions and teach Whispur the words you use."
        case .activity:
            return "Recent dictations with the raw and cleaned transcript side by side."
        case .requests:
            return "Every provider request with its status, timing, and error message."
        }
    }
}
