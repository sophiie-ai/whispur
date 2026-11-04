import XCTest
@testable import Whispur

final class NextStepsTests: XCTestCase {
    private let baseline = NextSteps.Baseline(dictationCount: 3, offersCleanupKey: false)

    private func signals(
        dictations: Int = 3, terms: Int = 0, styles: StyleSettings = .initial,
        cleanupEnabled: Bool = true, cleanupKeyReady: Bool = false
    ) -> NextSteps.Signals {
        NextSteps.Signals(
            dictationCount: dictations, termCount: terms, styles: styles,
            cleanupEnabled: cleanupEnabled, cleanupKeyReady: cleanupKeyReady
        )
    }

    func testHiddenWithoutABaselineOrOnceDismissed() {
        XCTAssertEqual(NextSteps.display(baseline: nil, dismissed: false, signals: signals()), .hidden)
        XCTAssertEqual(NextSteps.display(baseline: baseline, dismissed: true, signals: signals()), .hidden)
    }

    func testOnlyDictationsAfterOnboardingCount() {
        // The onboarding Try it is inside the baseline, so it doesn't tick.
        XCTAssertEqual(
            NextSteps.display(baseline: baseline, dismissed: false, signals: signals()),
            .steps([.dictate, .dictionary, .style], done: [])
        )
        XCTAssertEqual(
            NextSteps.display(baseline: baseline, dismissed: false, signals: signals(dictations: 4, terms: 1)),
            .steps([.dictate, .dictionary, .style], done: [.dictate, .dictionary])
        )
    }

    func testStylesNeedCleanupAndTheKeyIsOfferedOnlyWhenMissing() {
        let offers = NextSteps.Baseline(dictationCount: 3, offersCleanupKey: true)
        XCTAssertEqual(
            NextSteps.display(baseline: offers, dismissed: false, signals: signals(cleanupEnabled: false)),
            .steps([.dictate, .dictionary, .cleanupKey], done: [])
        )
    }

    func testOnlyAChangedStyleCounts() {
        XCTAssertFalse(NextSteps.hasPickedStyle(.initial))
        XCTAssertFalse(NextSteps.hasPickedStyle(.customEverywhere))
        var picked = StyleSettings.initial
        picked.fallback = .formal
        XCTAssertTrue(NextSteps.hasPickedStyle(picked))
    }

    func testAllSetIgnoresTheOptionalKey() {
        let offers = NextSteps.Baseline(dictationCount: 0, offersCleanupKey: true)
        var picked = StyleSettings.initial
        picked.fallback = .formal
        XCTAssertEqual(
            NextSteps.display(baseline: offers, dismissed: false, signals: signals(dictations: 1, terms: 2, styles: picked)),
            .allSet
        )
    }
}
