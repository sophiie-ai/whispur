import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "AppDelegate")

extension Notification.Name {
    static let whispurOpenSettings = Notification.Name("ai.sophiie.whispur.open-settings")
}

/// Handles application lifecycle events.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var didFinishLaunching = false
    private var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Whispur launched")
        // Before onboarding: a copy outside Applications offers to move
        // itself, and a moved copy relaunches and onboards from there.
        // didFinishLaunching stays false meanwhile, so a connect() during
        // the modal alert can't put onboarding up behind it.
        if ApplicationsFolderMover.offerMoveIfNeeded() { return }
        didFinishLaunching = true
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
        guard didFinishLaunching,
              let appState,
              !appState.onboardingCompleted,
              onboardingWindowController == nil else {
            return
        }

        let controller = OnboardingWindowController(appState: appState) { [weak self] in
            self?.onboardingWindowController = nil
        }
        onboardingWindowController = controller
        controller.present()
    }
}
