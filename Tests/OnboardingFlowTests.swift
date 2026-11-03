import XCTest
@testable import Whispur

final class OnboardingFlowTests: XCTestCase {
    func testStepsRunInOrderAndStopAtTheEnds() {
        var seen: [OnboardingStep] = [.welcome]
        while let next = OnboardingFlow.next(after: seen.last!) { seen.append(next) }
        XCTAssertEqual(seen, OnboardingStep.allCases)
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
        XCTAssertNil(OnboardingFlow.next(after: OnboardingStep.allCases.last!))
        XCTAssertEqual(OnboardingFlow.previous(before: .microphone), .welcome)
    }

    func testProgressGrowsToFull() {
        let values = OnboardingStep.allCases.map(OnboardingFlow.progress(of:))
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(values.first!, 0)
        XCTAssertEqual(values.last!, 1, accuracy: 0.0001)
    }

    func testAGrantOnlyAdvancesItsOwnStep() {
        XCTAssertEqual(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .microphone), .accessibility)
        XCTAssertEqual(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .accessibility), .shortcuts)
        // A grant landing while another screen shows never moves the window.
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .accessibility))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .ready))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .welcome))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .tryIt))
    }

    func testTryItComesRightBeforeReady() {
        XCTAssertEqual(OnboardingFlow.next(after: .shortcuts), .tryIt)
        XCTAssertEqual(OnboardingFlow.next(after: .tryIt), .ready)
        XCTAssertEqual(OnboardingFlow.previous(before: .ready), .tryIt)
    }

    func testTryItBlockersComeInFixOrderAndPointBackToTheirStep() {
        XCTAssertNil(TryItBlocker.first(microphone: true, accessibility: true, hasShortcut: true, speechConfigured: true))
        XCTAssertEqual(TryItBlocker.first(microphone: false, accessibility: false, hasShortcut: false, speechConfigured: false), .microphone)
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: false, hasShortcut: false, speechConfigured: false), .accessibility)
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: true, hasShortcut: false, speechConfigured: false), .shortcut)
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: true, hasShortcut: true, speechConfigured: false), .speechProvider)
        XCTAssertEqual(TryItBlocker.microphone.step, .microphone)
        XCTAssertEqual(TryItBlocker.accessibility.step, .accessibility)
        XCTAssertEqual(TryItBlocker.shortcut.step, .shortcuts)
        XCTAssertNil(TryItBlocker.speechProvider.step)
    }

    @MainActor
    func testTryItSessionSucceedsOnlyOnRealText() {
        let session = TryItSession()
        session.receive("   ")
        XCTAssertFalse(session.succeeded)
        XCTAssertEqual(session.text, "")
        session.receive(" Hi, I'm testing Whispur. ")
        XCTAssertTrue(session.succeeded)
        XCTAssertEqual(session.text, "Hi, I'm testing Whispur.")
        session.receive("Again.")
        XCTAssertEqual(session.text, "Hi, I'm testing Whispur. Again.")
    }

    func testFirstMissingPermissionStep() {
        XCTAssertNil(OnboardingFlow.firstMissingPermissionStep(microphone: true, accessibility: true))
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: false, accessibility: true), .microphone)
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: true, accessibility: false), .accessibility)
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: false, accessibility: false), .microphone)
    }

    func testARestartBlockerComesAfterTheGrantAndBeforeTheShortcut() {
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: true, needsRestart: true, hasShortcut: false, speechConfigured: false), .restart)
        // A missing grant still comes first; the restart only matters once granted.
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: false, needsRestart: true, hasShortcut: true, speechConfigured: true), .accessibility)
        XCTAssertNil(TryItBlocker.first(microphone: true, accessibility: true, needsRestart: false, hasShortcut: true, speechConfigured: true))
        XCTAssertNil(TryItBlocker.restart.step)
    }

    func testRestartResumesPastAccessibilityButNeverBackwards() {
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .accessibility), .shortcuts)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .welcome), .shortcuts)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .shortcuts), .shortcuts)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .tryIt), .tryIt)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .ready), .ready)
    }

    func testLaunchShowsOnboardingOnFirstRunResumeAndReplayOnly() {
        // First run.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: nil, replayRequested: false), .welcome)
        // Everyday launch.
        XCTAssertNil(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: nil, replayRequested: false))
        // After "Restart Whispur", whether or not setup was finished before.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: OnboardingStep.shortcuts.rawValue, replayRequested: false), .shortcuts)
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: OnboardingStep.tryIt.rawValue, replayRequested: false), .tryIt)
        // A stale or corrupt resume value falls back to the normal rule.
        XCTAssertNil(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: 99, replayRequested: false))
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: -1, replayRequested: false), .welcome)
        // Replay always starts from the welcome screen.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: nil, replayRequested: true), .welcome)
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: OnboardingStep.tryIt.rawValue, replayRequested: true), .welcome)
    }

    func testReplayArgument() {
        XCTAssertTrue(OnboardingLaunch.isReplayRequested(arguments: ["/Applications/Whispur.app/Contents/MacOS/Whispur", "--reset-onboarding"]))
        XCTAssertFalse(OnboardingLaunch.isReplayRequested(arguments: ["/Applications/Whispur.app/Contents/MacOS/Whispur"]))
        XCTAssertFalse(OnboardingLaunch.isReplayRequested(arguments: ["Whispur", "-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
