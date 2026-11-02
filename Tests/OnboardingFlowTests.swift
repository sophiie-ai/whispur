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
    }

    func testFirstMissingPermissionStep() {
        XCTAssertNil(OnboardingFlow.firstMissingPermissionStep(microphone: true, accessibility: true))
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: false, accessibility: true), .microphone)
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: true, accessibility: false), .accessibility)
        XCTAssertEqual(OnboardingFlow.firstMissingPermissionStep(microphone: false, accessibility: false), .microphone)
    }
}
