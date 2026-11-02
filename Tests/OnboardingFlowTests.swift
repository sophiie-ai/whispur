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
}
