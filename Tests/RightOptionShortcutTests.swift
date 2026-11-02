import XCTest
@testable import Whispur

/// Right Option is a modifier key: macOS reports it with flagsChanged, never
/// keyDown, so a binding on its key code has to read the held-modifier set.
final class RightOptionShortcutTests: XCTestCase {
    @MainActor
    private func makeKeyboard(
        hold: ShortcutBinding? = nil,
        toggle: ShortcutBinding? = nil
    ) -> (FakeKeyboard, () -> [String]) {
        let manager = HotkeyManager()
        manager.holdArmThreshold = 0
        manager.holdBinding = hold
        manager.toggleBinding = toggle
        var events: [HotkeyManager.Event] = []
        manager.onEvent = { events.append($0) }
        return (FakeKeyboard(manager: manager), { events.map(String.init(describing:)) })
    }

    @MainActor
    func testRightOptionHoldStartsAndStops() {
        let (keyboard, events) = makeKeyboard(hold: .rightOption)
        keyboard.press(.rightOption)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.rightOption)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testLeftOptionDoesNotTriggerRightOption() {
        let (keyboard, events) = makeKeyboard(hold: .rightOption)
        keyboard.press(.leftOption)
        keyboard.release(.leftOption)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testRightOptionHeldOnTopOfLeftOptionStillActivates() {
        let (keyboard, events) = makeKeyboard(hold: .rightOption)
        keyboard.press(.leftOption)
        keyboard.press(.rightOption)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.rightOption)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testRightOptionToggleLatches() {
        let (keyboard, events) = makeKeyboard(hold: .fnKey, toggle: .rightOption)
        keyboard.press(.rightOption)
        keyboard.release(.rightOption)
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated"])
    }
}
