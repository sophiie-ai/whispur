import Foundation

/// The onboarding screens, in order. One thing per screen.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case microphone
    case accessibility
    case shortcuts
    case tryIt
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        case .shortcuts: return "Shortcuts"
        case .tryIt: return "Try it"
        case .ready: return "Ready"
        }
    }

    /// The SF Symbol shown large at the top of the screen.
    var symbol: String {
        switch self {
        case .welcome: return "waveform"
        case .microphone: return "mic.fill"
        case .accessibility: return "accessibility"
        case .shortcuts: return "command"
        case .tryIt: return "text.cursor"
        case .ready: return "flag.checkered"
        }
    }

    /// The permission the screen asks for, if any.
    var permission: GuidedPermission? {
        switch self {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        default: return nil
        }
    }

    var isFirst: Bool { self == Self.allCases.first }
    var isLast: Bool { self == Self.allCases.last }
}

/// Step sequencing, kept free of SwiftUI so it can be unit tested.
enum OnboardingFlow {
    static func next(after step: OnboardingStep) -> OnboardingStep? {
        OnboardingStep(rawValue: step.rawValue + 1)
    }

    static func previous(before step: OnboardingStep) -> OnboardingStep? {
        OnboardingStep(rawValue: step.rawValue - 1)
    }

    /// Fraction for the progress bar: the welcome screen shows a sliver,
    /// the last screen a full bar.
    static func progress(of step: OnboardingStep) -> Double {
        let count = OnboardingStep.allCases.count
        guard count > 1 else { return 1 }
        return Double(step.rawValue + 1) / Double(count)
    }

    /// Where a fresh grant moves the window: only off the step that asked
    /// for that permission, never from somewhere else.
    static func stepAfterGrant(of permission: GuidedPermission, showing step: OnboardingStep) -> OnboardingStep? {
        guard step.permission == permission else { return nil }
        return next(after: step)
    }

    /// The first step whose permission is still missing, for the "fix it"
    /// links on later screens.
    static func firstMissingPermissionStep(microphone: Bool, accessibility: Bool) -> OnboardingStep? {
        if !microphone { return .microphone }
        if !accessibility { return .accessibility }
        return nil
    }
}

/// What stops the "Try it" step from working, in the order to fix it.
enum TryItBlocker: Equatable {
    case microphone
    case accessibility
    case shortcut
    case speechProvider

    /// The onboarding step that fixes it, nil when Settings does.
    var step: OnboardingStep? {
        switch self {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .shortcut: return .shortcuts
        case .speechProvider: return nil
        }
    }

    static func first(
        microphone: Bool,
        accessibility: Bool,
        hasShortcut: Bool,
        speechConfigured: Bool
    ) -> TryItBlocker? {
        if !microphone { return .microphone }
        if !accessibility { return .accessibility }
        if !hasShortcut { return .shortcut }
        if !speechConfigured { return .speechProvider }
        return nil
    }
}
