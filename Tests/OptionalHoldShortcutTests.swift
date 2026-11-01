import XCTest
@testable import Whispur

/// Hold to talk can be removed like the hands-free shortcut.
final class OptionalHoldShortcutTests: XCTestCase {

    private let fnKeyCode: UInt16 = 63
    private let commandKeyCode: UInt16 = 55

    // MARK: - Persistence

    @MainActor
    func testNewUsersGetFnAsHoldShortcut() throws {
        let suite = "whispur.tests.hold-default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppState.loadHoldShortcut(defaults: defaults), .fnKey)
        // Loading never writes the fallback back.
        XCTAssertNil(defaults.string(forKey: "holdShortcut"))
    }

    @MainActor
    func testRemovedHoldShortcutStaysRemovedAcrossLaunches() throws {
        let suite = "whispur.tests.hold-removed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("off", forKey: "holdShortcut")
        XCTAssertNil(AppState.loadHoldShortcut(defaults: defaults))

        defaults.set(ShortcutBinding.rightOption.storageValue, forKey: "holdShortcut")
        XCTAssertEqual(AppState.loadHoldShortcut(defaults: defaults), .rightOption)

        // Garbage falls back to the default rather than silently removing it.
        defaults.set("not-a-shortcut", forKey: "holdShortcut")
        XCTAssertEqual(AppState.loadHoldShortcut(defaults: defaults), .fnKey)
    }

    @MainActor
    func testBothShortcutsRemovedStayRemoved() throws {
        let suite = "whispur.tests.both-removed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("off", forKey: "holdShortcut")
        defaults.set("off", forKey: "toggleShortcut")
        let hold = AppState.loadHoldShortcut(defaults: defaults)
        XCTAssertNil(hold)
        // No hold shortcut is not a collision: "off" must not turn back into the default toggle.
        XCTAssertNil(AppState.loadToggleShortcut(holdShortcut: hold, defaults: defaults))
    }

    @MainActor
    func testToggleLoadsNormallyWithoutHoldShortcut() throws {
        let suite = "whispur.tests.toggle-no-hold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AppState.loadToggleShortcut(holdShortcut: nil, defaults: defaults), .commandFn)
        defaults.set(ShortcutBinding.fnDoublePress.storageValue, forKey: "toggleShortcut")
        XCTAssertEqual(AppState.loadToggleShortcut(holdShortcut: nil, defaults: defaults), .fnDoublePress)
    }

    // MARK: - Copy and setup state

    @MainActor
    func testShortcutSummaryCoversEveryCombination() {
        XCTAssertEqual(AppState.shortcutSummary(hold: .fnKey, toggle: .commandFn), "Fn to talk, Command + Fn to latch")
        XCTAssertEqual(AppState.shortcutSummary(hold: .fnKey, toggle: nil), "Fn to talk")
        XCTAssertEqual(AppState.shortcutSummary(hold: nil, toggle: .commandFn), "Command + Fn to latch")
        XCTAssertTrue(AppState.shortcutSummary(hold: nil, toggle: nil).hasPrefix("No shortcut set"))
    }

    func testSetupNeedsAtLeastOneShortcut() {
        var state = SettingsSetupState(
            microphoneGranted: true, accessibilityGranted: true, speechReady: true, hasDictated: true
        )
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.pendingSteps, 0)

        state.hasShortcut = false
        XCTAssertFalse(state.isComplete, "No shortcut shows Needs setup")
        XCTAssertEqual(state.pendingSteps, 1)
        XCTAssertEqual(state.landingTab, .getStarted)
    }

    // MARK: - HotkeyManager

    @MainActor
    private func makeManager(hold: ShortcutBinding?, toggle: ShortcutBinding?) -> (HotkeyManager, () -> [HotkeyManager.Event]) {
        let manager = HotkeyManager()
        // No arm delay, so a bare-modifier hold fires on press.
        manager.holdArmThreshold = 0
        manager.holdBinding = hold
        manager.toggleBinding = toggle
        var events: [HotkeyManager.Event] = []
        manager.onEvent = { events.append($0) }
        return (manager, { events })
    }

    @MainActor
    func testFnHoldFiresWhenBound() {
        // Positive control for the nil case below.
        let (manager, events) = makeManager(hold: .fnKey, toggle: nil)
        manager.handleModifierChange(keyCode: fnKeyCode)
        manager.handleModifierChange(keyCode: fnKeyCode)
        XCTAssertEqual(events().map(String.init(describing:)), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testNilHoldBindingIgnoresHoldKeys() {
        let (manager, events) = makeManager(hold: nil, toggle: nil)
        manager.handleModifierChange(keyCode: fnKeyCode)
        manager.handleKeyDown(keyCode: 49) // Fn+Space chord path
        manager.handleKeyUp(keyCode: 49)
        manager.handleModifierChange(keyCode: fnKeyCode)
        XCTAssertTrue(events().isEmpty)
    }

    @MainActor
    func testNilHoldBindingWithThresholdNeverArms() {
        let (manager, events) = makeManager(hold: nil, toggle: nil)
        manager.holdArmThreshold = 0.01
        manager.handleModifierChange(keyCode: fnKeyCode)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        manager.handleModifierChange(keyCode: fnKeyCode)
        XCTAssertTrue(events().isEmpty)
    }

    @MainActor
    func testToggleStillWorksWithoutHoldBinding() {
        let (manager, events) = makeManager(hold: nil, toggle: .commandFn)
        manager.handleModifierChange(keyCode: commandKeyCode)
        manager.handleModifierChange(keyCode: fnKeyCode)
        manager.handleModifierChange(keyCode: fnKeyCode)
        manager.handleModifierChange(keyCode: commandKeyCode)
        XCTAssertEqual(events().map(String.init(describing:)), ["toggleActivated", "toggleDeactivated"])
    }

    @MainActor
    func testRemovingHoldMidRecordingReleasesIt() {
        let (manager, events) = makeManager(hold: .fnKey, toggle: nil)
        manager.handleModifierChange(keyCode: fnKeyCode)
        manager.holdBinding = nil
        manager.handleModifierChange(keyCode: fnKeyCode)
        XCTAssertEqual(events().map(String.init(describing:)), ["holdActivated", "holdDeactivated"])
    }
}
