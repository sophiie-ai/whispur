import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppDelegate")

extension Notification.Name {
    static let whispurOpenSettings = Notification.Name("ai.sophiie.whispur.open-settings")
    /// Opens onboarding again from the welcome screen (Settings → Get
    /// Started, the menu bar). Settings and permissions stay as they are.
    static let whispurRunSetupAgain = Notification.Name("ai.sophiie.whispur.run-setup-again")
}

/// Handles application lifecycle events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var didFinishLaunching = false
    private var onboardingWindowController: OnboardingWindowController?
    /// `--reset-onboarding` on the command line: show setup once this launch.
    private var replayRequested = false
    private var runSetupObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Whispur launched")
        // Before onboarding: a copy outside Applications offers to move
        // itself, and a moved copy relaunches and onboards from there.
        // didFinishLaunching stays false meanwhile, so a connect() during
        // the modal alert can't put onboarding up behind it.
        if ApplicationsFolderMover.offerMoveIfNeeded() { return }
        didFinishLaunching = true
        LaunchAtLogin.shared.applyDefaultIfNeeded(location: ApplicationsFolderMover.currentLocation())
        replayRequested = OnboardingLaunch.isReplayRequested(arguments: ProcessInfo.processInfo.arguments)
        runSetupObserver = NotificationCenter.default.addObserver(
            forName: .whispurRunSetupAgain,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.runSetupAgain() }
        }
        presentOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Whispur terminating")
        // If the user quits while a recording is in flight, the pipeline's
        // stop/cancel paths never run — restore here so the system output
        // isn't left ducked after the app is gone.
        appState?.pipeline.restoreSystemAudioIfNeeded()
    }

    func connect(appState: AppState) {
        guard self.appState !== appState else { return }
        self.appState = appState
        presentOnboardingIfNeeded()
    }

    private func presentOnboardingIfNeeded() {
        guard didFinishLaunching, let appState, onboardingWindowController == nil else { return }

        let defaults = UserDefaults.standard
        let resumeStep = defaults.object(forKey: OnboardingLaunch.resumeStepDefaultsKey) as? Int
        guard let step = OnboardingLaunch.initialStep(
            onboardingCompleted: appState.onboardingCompleted,
            resumeStepRaw: resumeStep,
            replayRequested: replayRequested
        ) else { return }

        // A resume or replay applies to this launch only.
        defaults.removeObject(forKey: OnboardingLaunch.resumeStepDefaultsKey)
        replayRequested = false
        presentOnboarding(at: step, appState: appState)
    }

    /// "Run Setup Again": the welcome screen, or the open window to the front.
    private func runSetupAgain() {
        guard didFinishLaunching, let appState else { return }
        if let onboardingWindowController {
            onboardingWindowController.present()
            return
        }
        presentOnboarding(at: .welcome, appState: appState)
    }

    private func presentOnboarding(at step: OnboardingStep, appState: AppState) {
        let controller = OnboardingWindowController(appState: appState, initialStep: step) { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.present()
    }
}
