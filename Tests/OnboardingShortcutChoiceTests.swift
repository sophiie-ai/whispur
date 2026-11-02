import XCTest
@testable import Whispur

final class OnboardingShortcutChoiceTests: XCTestCase {
    func testEachChoiceMapsToExistingSettings() {
        XCTAssertEqual(OnboardingShortcutChoice.holdFn.style, .separate)
        XCTAssertEqual(OnboardingShortcutChoice.holdFn.binding, .fnKey)
        XCTAssertEqual(OnboardingShortcutChoice.tapOrHoldFn.style, .tapOrHold)
        XCTAssertEqual(OnboardingShortcutChoice.tapOrHoldFn.binding, .fnKey)
        XCTAssertEqual(OnboardingShortcutChoice.holdRightOption.style, .separate)
        XCTAssertEqual(OnboardingShortcutChoice.holdRightOption.binding, .rightOption)
        // Every key on offer is one Settings offers too.
        for choice in OnboardingShortcutChoice.allCases {
            XCTAssertTrue(ShortcutBinding.holdPresets.contains(choice.binding), choice.rawValue)
        }
    }

    func testEachChoiceIsRecognisedFromTheSettingsItWrites() {
        for choice in OnboardingShortcutChoice.allCases {
            let matched = OnboardingShortcutChoice.matching(
                style: choice.style,
                hold: choice.style == .separate ? choice.binding : .f5,
                tapOrHold: choice.style == .tapOrHold ? choice.binding : .f5
            )
            XCTAssertEqual(matched, choice)
        }
    }

    func testTheNewInstallDefaultIsHoldFn() {
        XCTAssertEqual(
            OnboardingShortcutChoice.matching(style: DictationShortcutStyle.newInstallDefault, hold: .fnKey, tapOrHold: .fnKey),
            .holdFn
        )
    }

    func testCustomSettingsMatchNoCard() {
        XCTAssertNil(OnboardingShortcutChoice.matching(style: .separate, hold: .controlSpace, tapOrHold: .fnKey))
        XCTAssertNil(OnboardingShortcutChoice.matching(style: .separate, hold: nil, tapOrHold: .fnKey))
        XCTAssertNil(OnboardingShortcutChoice.matching(style: .tapOrHold, hold: .fnKey, tapOrHold: .rightOption))
    }

    func testOnlyFnChoicesShowTheGlobeKeyNote() {
        XCTAssertTrue(OnboardingShortcutChoice.holdFn.usesFn)
        XCTAssertTrue(OnboardingShortcutChoice.tapOrHoldFn.usesFn)
        XCTAssertFalse(OnboardingShortcutChoice.holdRightOption.usesFn)
    }
}
