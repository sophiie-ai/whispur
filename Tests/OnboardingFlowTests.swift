import XCTest
@testable import Whispur

final class OnboardingFlowTests: XCTestCase {
    func testStepsRunInOrderAndStopAtTheEnds() {
        var seen: [OnboardingStep] = [.welcome]
        while let next = OnboardingFlow.next(after: seen.last!) { seen.append(next) }
        XCTAssertEqual(seen, OnboardingPlan.standard.steps)
        XCTAssertFalse(seen.contains(.languages))
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
        XCTAssertNil(OnboardingFlow.next(after: OnboardingStep.allCases.last!))
        XCTAssertEqual(OnboardingFlow.previous(before: .microphone), .welcome)
    }

    func testProgressGrowsToFull() {
        let values = OnboardingPlan.standard.steps.map { OnboardingFlow.progress(of: $0) }
        XCTAssertEqual(values, values.sorted())
        XCTAssertGreaterThan(values.first!, 0)
        XCTAssertEqual(values.last!, 1, accuracy: 0.0001)
    }

    func testAGrantOnlyAdvancesItsOwnStep() {
        XCTAssertEqual(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .microphone), .accessibility)
        XCTAssertEqual(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .accessibility), .tryIt)
        // A grant landing while another screen shows never moves the window.
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .accessibility))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .ready))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .microphone, showing: .welcome))
        XCTAssertNil(OnboardingFlow.stepAfterGrant(of: .accessibility, showing: .tryIt))
    }

    func testTryItFollowsAccessibilityAndComesRightBeforeReady() {
        XCTAssertEqual(OnboardingFlow.next(after: .accessibility), .tryIt)
        XCTAssertEqual(OnboardingFlow.previous(before: .tryIt), .accessibility)
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
        XCTAssertNil(TryItBlocker.shortcut.step)
        XCTAssertNil(TryItBlocker.speechProvider.step)
        // A missing shortcut is fixed in Settings now that onboarding has no Shortcuts step.
        XCTAssertEqual(TryItBlocker.shortcut.settingsTab, .dictation)
        XCTAssertEqual(TryItBlocker.speechProvider.settingsTab, .providers)
        XCTAssertNil(TryItBlocker.microphone.settingsTab)
    }

    @MainActor
    func testTryItSessionSucceedsOnlyOnRealText() {
        let session = TryItSession()
        session.receive("   ")
        XCTAssertFalse(session.succeeded)
        XCTAssertEqual(session.text, "")
        session.receive(" Hey, this is my first dictation. ")
        XCTAssertTrue(session.succeeded)
        XCTAssertEqual(session.text, "Hey, this is my first dictation.")
        session.receive("Again.")
        XCTAssertEqual(session.text, "Hey, this is my first dictation. Again.")
    }

    @MainActor
    func testTryItPhraseLeavesOutTheBrandName() {
        XCTAssertEqual(OnboardingWindow.tryItPhrase, "Hey, this is my first dictation")
        XCTAssertFalse(OnboardingWindow.tryItPhrase.localizedCaseInsensitiveContains("Whispur"))
    }

    func testStartUsingLandsOnDictationOnlyWhenAllSet() {
        XCTAssertEqual(OnboardingFlow.settingsTabAfterSetup(allSet: true), .dictation)
        XCTAssertEqual(OnboardingFlow.settingsTabAfterSetup(allSet: false), .getStarted)
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

    func testAGrantStillFinishingBlocksTryIt() {
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: true, finishing: true, hasShortcut: true, speechConfigured: true), .finishing)
        XCTAssertEqual(TryItBlocker.first(microphone: true, accessibility: true, needsRestart: true, finishing: false, hasShortcut: true, speechConfigured: true), .restart)
        XCTAssertEqual(TryItBlocker.first(microphone: false, accessibility: true, finishing: true, hasShortcut: true, speechConfigured: true), .microphone)
        XCTAssertNil(TryItBlocker.finishing.step)
        XCTAssertNil(TryItBlocker.finishing.settingsTab)
    }

    func testReadyOnlySaysAllSetOnceTheShortcutIsListeningAndHeard() {
        func readiness(mic: Bool = true, _ status: AccessibilityStatus, speech: Bool = true, heard: Bool = true) -> OnboardingReadiness {
            OnboardingReadiness.resolve(microphone: mic, accessibility: status, speechConfigured: speech, shortcutHeard: heard)
        }
        XCTAssertEqual(readiness(.on), .allSet)
        // Granted but the tap isn't in: not ready, whatever else is true.
        XCTAssertEqual(readiness(.finishing), .finishing)
        XCTAssertEqual(readiness(.needsRestart), .needsRestart)
        // A tap that has never heard a key doesn't get "You're all set".
        XCTAssertEqual(readiness(.on, heard: false), .untested)
        // Fix order: permissions, then the tap, then speech, then proof.
        XCTAssertEqual(readiness(mic: false, .off, speech: false, heard: false), .missingPermission(.microphone))
        XCTAssertEqual(readiness(.off), .missingPermission(.accessibility))
        XCTAssertEqual(readiness(.finishing, speech: false), .finishing)
        XCTAssertEqual(readiness(.on, speech: false, heard: false), .speechProvider)
    }

    func testFirstRunIgnoresShortcutStartsUntilAccessibilityIsGranted() {
        XCTAssertTrue(AppState.ignoresShortcutStart(accessibilityGranted: false, onboardingCompleted: false))
        XCTAssertFalse(AppState.ignoresShortcutStart(accessibilityGranted: true, onboardingCompleted: false))
        // After setup a start goes through, and its error says what's missing.
        XCTAssertFalse(AppState.ignoresShortcutStart(accessibilityGranted: false, onboardingCompleted: true))
        XCTAssertFalse(AppState.ignoresShortcutStart(accessibilityGranted: true, onboardingCompleted: true))
    }

    func testRestartResumesPastAccessibilityButNeverBackwards() {
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .accessibility), .tryIt)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .welcome), .tryIt)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .tryIt), .tryIt)
        XCTAssertEqual(OnboardingFlow.resumeStep(afterRestartFrom: .ready), .ready)
    }

    func testLaunchShowsOnboardingOnFirstRunResumeAndReplayOnly() {
        // First run.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: nil, replayRequested: false), .welcome)
        // Everyday launch.
        XCTAssertNil(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: nil, replayRequested: false))
        // After "Restart Whispur", whether or not setup was finished before.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: OnboardingStep.accessibility.rawValue, replayRequested: false), .accessibility)
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: OnboardingStep.tryIt.rawValue, replayRequested: false), .tryIt)
        // A resume stored on the removed Shortcuts screen lands on Try it.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: 4, replayRequested: false), .tryIt)
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: 4, replayRequested: false), .tryIt)
        // A stale or corrupt resume value falls back to the normal rule.
        XCTAssertNil(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: 99, replayRequested: false))
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: false, resumeStepRaw: -1, replayRequested: false), .welcome)
        // Replay always starts from the welcome screen.
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: nil, replayRequested: true), .welcome)
        XCTAssertEqual(OnboardingLaunch.initialStep(onboardingCompleted: true, resumeStepRaw: OnboardingStep.tryIt.rawValue, replayRequested: true), .welcome)
    }

    func testPersistedRawValuesNeverMove() {
        // `whispur.onboarding.resumeStep` stores these.
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), [0, 1, 2, 3, 5, 6])
        XCTAssertNil(OnboardingStep(rawValue: OnboardingLaunch.retiredShortcutsRawValue))
    }

    func testReplayArgument() {
        XCTAssertTrue(OnboardingLaunch.isReplayRequested(arguments: ["/Applications/Whispur.app/Contents/MacOS/Whispur", "--reset-onboarding"]))
        XCTAssertFalse(OnboardingLaunch.isReplayRequested(arguments: ["/Applications/Whispur.app/Contents/MacOS/Whispur"]))
        XCTAssertFalse(OnboardingLaunch.isReplayRequested(arguments: ["Whispur", "-NSDocumentRevisionsDebugMode", "YES"]))
    }
}
