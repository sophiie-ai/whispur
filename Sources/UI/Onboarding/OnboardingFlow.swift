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

    /// Where onboarding picks up after "Restart Whispur": past the
    /// accessibility step it restarted for, or the later step it was on.
    static func resumeStep(afterRestartFrom step: OnboardingStep) -> OnboardingStep {
        let pastAccessibility = next(after: .accessibility) ?? .accessibility
        return step.rawValue > pastAccessibility.rawValue ? step : pastAccessibility
    }
}

/// Whether onboarding opens at launch, and on which step. Pure, so the
/// first-run, resume-after-restart and replay cases are unit tested.
enum OnboardingLaunch {
    /// The step to resume on after a restart Whispur asked for. Read and
    /// cleared at the next launch.
    static let resumeStepDefaultsKey = "whispur.onboarding.resumeStep"
    /// `open -a Whispur --args --reset-onboarding` runs setup again from the
    /// welcome screen; settings and permissions stay as they are.
    static let replayArgument = "--reset-onboarding"

    static func isReplayRequested(arguments: [String]) -> Bool {
        arguments.contains(replayArgument)
    }

    static func initialStep(onboardingCompleted: Bool, resumeStepRaw: Int?, replayRequested: Bool) -> OnboardingStep? {
        if replayRequested { return .welcome }
        if let resumeStepRaw, let step = OnboardingStep(rawValue: resumeStepRaw) { return step }
        return onboardingCompleted ? nil : .welcome
    }
}

/// What stops the "Try it" step from working, in the order to fix it.
enum TryItBlocker: Equatable {
    case microphone
    case accessibility
    /// Accessibility is granted but only takes effect after a restart.
    case restart
    case shortcut
    case speechProvider

    /// The onboarding step that fixes it, nil when Settings does.
    var step: OnboardingStep? {
        switch self {
        case .microphone: return .microphone
        case .accessibility: return .accessibility
        case .shortcut: return .shortcuts
        case .restart, .speechProvider: return nil
        }
    }

    static func first(
        microphone: Bool,
        accessibility: Bool,
        needsRestart: Bool = false,
        hasShortcut: Bool,
        speechConfigured: Bool
    ) -> TryItBlocker? {
        if !microphone { return .microphone }
        if !accessibility { return .accessibility }
        if needsRestart { return .restart }
        if !hasShortcut { return .shortcut }
        if !speechConfigured { return .speechProvider }
        return nil
    }
}
