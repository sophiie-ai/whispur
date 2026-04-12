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
        didFinishLaunching = true
        logger.info("Whispur launched")
        presentOnboardingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("Whispur terminating")
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
