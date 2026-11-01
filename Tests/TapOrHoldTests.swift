import XCTest
@testable import Whispur

/// "Tap or hold": one key that talks while held and locks hands-free when
/// tapped.
final class TapOrHoldTests: XCTestCase {

    // MARK: - TapOrHoldDetector (pure, injected clock)

    private func makeDetector(veto: TimeInterval = 0.15, threshold: TimeInterval = 0.3) -> TapOrHoldDetector {
        TapOrHoldDetector(vetoWindow: veto, holdThreshold: threshold)
    }

    /// Press at `time` and let the veto timer for that press fire.
    private func pressPastVeto(_ d: inout TapOrHoldDetector, at time: TimeInterval) -> [TapOrHoldDetector.Action] {
        let pressed = d.press(at: time)
        let elapsed = d.vetoElapsed(generation: d.generation, at: time + d.vetoWindow)
        return [pressed, elapsed]
    }

    func testTapAfterVetoLocksThenNextTapStops() {
        var d = makeDetector()
        XCTAssertEqual(pressPastVeto(&d, at: 0), [.none, .startHolding])
        XCTAssertEqual(d.release(at: 0.2), .lock)
        XCTAssertEqual(d.phase, .locked)
        d.setSessionActive(true)

        // Next tap: down, up inside the veto window, stops on release.
        XCTAssertEqual(d.press(at: 2.0), .none)
        XCTAssertEqual(d.release(at: 2.08), .stopLocked)
        XCTAssertEqual(d.phase, .idle)
        XCTAssertFalse(d.sessionActive)
    }

    func testQuickTapInsideVetoStartsLocked() {
        var d = makeDetector()
        XCTAssertEqual(d.press(at: 0), .none)
        XCTAssertEqual(d.release(at: 0.08), .startLocked)
        XCTAssertEqual(d.phase, .locked)
        // The stale veto timer from that press does nothing.
        XCTAssertEqual(d.vetoElapsed(generation: d.generation, at: 0.15), .none)
    }

    func testHoldPastThresholdStopsOnRelease() {
        var d = makeDetector()
        XCTAssertEqual(pressPastVeto(&d, at: 0), [.none, .startHolding])
        XCTAssertEqual(d.release(at: 2.5), .stopHold)
        XCTAssertEqual(d.phase, .idle)
    }

    func testThresholdBoundaryIsAHold() {
        var d = makeDetector()
        _ = pressPastVeto(&d, at: 10)
        XCTAssertEqual(d.release(at: 10.3), .stopHold, "exactly the threshold counts as a hold")

        var tap = makeDetector()
        _ = pressPastVeto(&tap, at: 10)
        XCTAssertEqual(tap.release(at: 10.299), .lock)
    }

    func testChordInsideVetoDoesNothing() {
        var d = makeDetector()
        XCTAssertEqual(d.press(at: 0), .none)
        XCTAssertEqual(d.chord(at: 0.06), .none)
        XCTAssertEqual(d.vetoElapsed(generation: d.generation, at: 0.15), .none, "no recording starts")
        XCTAssertEqual(d.release(at: 0.4), .none)
        XCTAssertEqual(d.phase, .idle)
    }

    func testChordAfterStartButInsideThresholdCancels() {
        var d = makeDetector()
        _ = pressPastVeto(&d, at: 0)
        XCTAssertEqual(d.chord(at: 0.2), .cancel)
        XCTAssertEqual(d.release(at: 0.25), .none, "never locks after a chord")
        XCTAssertEqual(d.phase, .idle)
    }

    func testChordDuringLongHoldIsIgnored() {
        var d = makeDetector()
        _ = pressPastVeto(&d, at: 0)
        XCTAssertEqual(d.chord(at: 1.0), .none)
        XCTAssertEqual(d.release(at: 2.0), .stopHold)
    }

    func testTapThenHoldStopsTheLockedRecording() {
        var d = makeDetector()
        _ = d.press(at: 0)
        XCTAssertEqual(d.release(at: 0.1), .startLocked)
        d.setSessionActive(true)
        // Holding the key while locked stops once the veto window passes.
        XCTAssertEqual(d.press(at: 3.0), .none)
        XCTAssertEqual(d.vetoElapsed(generation: d.generation, at: 3.15), .stopLocked)
        XCTAssertEqual(d.release(at: 5.0), .none, "release after the stop does nothing")
        XCTAssertEqual(d.phase, .idle)
        // And the next press is a fresh start.
        XCTAssertEqual(pressPastVeto(&d, at: 6.0), [.none, .startHolding])
    }

    func testChordWhileLockedKeepsTheLock() {
        var d = makeDetector()
        _ = d.press(at: 0)
        _ = d.release(at: 0.1)
        d.setSessionActive(true)
        XCTAssertEqual(d.press(at: 1.0), .none)
        XCTAssertEqual(d.chord(at: 1.05), .none)
        XCTAssertEqual(d.vetoElapsed(generation: d.generation, at: 1.15), .none)
        XCTAssertEqual(d.release(at: 1.3), .none)
        XCTAssertEqual(d.phase, .locked)
    }

    func testEscCancelWhileLockedForgetsTheLock() {
        var d = makeDetector()
        _ = d.press(at: 0)
        _ = d.release(at: 0.1)
        d.setSessionActive(true)
        // Esc: the controller resets and mirrors "no session".
        d.setSessionActive(false)
        XCTAssertEqual(d.phase, .idle)
        // The next press starts a new recording rather than "stopping".
        XCTAssertEqual(pressPastVeto(&d, at: 2.0), [.none, .startHolding])
    }

    func testEscCancelWhileHoldingIgnoresTheRelease() {
        var d = makeDetector()
        _ = pressPastVeto(&d, at: 0)
        d.setSessionActive(true)
        d.setSessionActive(false)
        XCTAssertEqual(d.release(at: 0.2), .none, "a tap-length release must not lock a cancelled recording")
        XCTAssertEqual(d.phase, .idle)
    }

    func testPressDuringManualSessionStops() {
        var d = makeDetector()
        d.setSessionActive(true) // started from the menu bar
        XCTAssertEqual(d.press(at: 0), .none)
        XCTAssertEqual(d.release(at: 0.1), .stopLocked)
    }

    func testUnobservedReleaseNeverLocks() {
        var arming = makeDetector()
        _ = arming.press(at: 0)
        XCTAssertEqual(arming.releaseUnobserved(), .none)
        XCTAssertEqual(arming.phase, .idle)

        var holding = makeDetector()
        _ = pressPastVeto(&holding, at: 0)
        XCTAssertEqual(holding.releaseUnobserved(), .stopHold)

        var stopping = makeDetector()
        _ = stopping.press(at: 0)
        _ = stopping.release(at: 0.1)
        _ = stopping.press(at: 1.0)
        XCTAssertEqual(stopping.releaseUnobserved(), .stopLocked)

        var locked = makeDetector()
        _ = locked.press(at: 0)
        _ = locked.release(at: 0.1)
        XCTAssertEqual(locked.releaseUnobserved(), .none)
        XCTAssertEqual(locked.phase, .locked)
    }

    func testStaleVetoTimerIsIgnored() {
        var d = makeDetector()
        _ = d.press(at: 0)
        let first = d.generation
        _ = d.release(at: 0.05) // locked
        _ = d.press(at: 0.1)    // stop press
        XCTAssertEqual(d.vetoElapsed(generation: first, at: 0.15), .none)
        XCTAssertEqual(d.phase, .stopArming)
    }

    func testZeroVetoStartsOnPress() {
        var d = makeDetector(veto: 0)
        XCTAssertEqual(d.press(at: 0), .startHolding)
        XCTAssertEqual(d.release(at: 0.1), .lock)
        XCTAssertEqual(d.press(at: 1), .stopLocked)
        XCTAssertEqual(d.release(at: 1.1), .none)
    }

    // MARK: - HotkeyManager integration

    @MainActor
    private func makeKeyboard(
        binding: ShortcutBinding = .fnKey,
        veto: TimeInterval = 0.05,
        threshold: TimeInterval = 0.3
    ) -> (FakeKeyboard, () -> [String]) {
        let manager = HotkeyManager()
        manager.holdBinding = nil
        manager.toggleBinding = nil
        manager.tapOrHoldVetoWindow = veto
        manager.tapOrHoldThreshold = threshold
        manager.tapOrHoldBinding = binding
        var events: [HotkeyManager.Event] = []
        manager.onEvent = { events.append($0) }
        return (FakeKeyboard(manager: manager), { events.map(String.init(describing:)) })
    }

    @MainActor
    private func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    func testManagerHoldStartsAfterVetoAndStopsOnRelease() {
        let (keyboard, events) = makeKeyboard(threshold: 0.1)
        keyboard.press(.fn)
        XCTAssertEqual(events(), [], "nothing inside the veto window")
        wait(0.2)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testManagerTapLocksAndNextTapStops() {
        let (keyboard, events) = makeKeyboard(veto: 0.05, threshold: 10)
        keyboard.press(.fn)
        wait(0.1)
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "toggleActivated", "toggleDeactivated"])
        keyboard.manager.setShortcutSessionActive(true)

        keyboard.press(.fn)
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "toggleActivated", "toggleDeactivated", "toggleActivated"])
        wait(0.1)
        XCTAssertEqual(events().count, 4, "the stop press's veto timer was cancelled")
    }

    @MainActor
    func testManagerFnChordInsideVetoDoesNothing() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.fn)
        keyboard.manager.handleKeyDown(keyCode: 123) // Fn+Left arrow
        keyboard.manager.handleKeyUp(keyCode: 123)
        wait(0.15)
        keyboard.release(.fn)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testManagerFnPlusCommandIsAChord() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.leftCommand)
        keyboard.press(.fn)
        wait(0.15)
        keyboard.release(.fn)
        keyboard.release(.leftCommand)
        XCTAssertEqual(events(), [])

        keyboard.press(.fn)
        keyboard.press(.leftCommand)
        wait(0.15)
        keyboard.release(.leftCommand)
        keyboard.release(.fn)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testManagerChordAfterStartCancels() {
        let (keyboard, events) = makeKeyboard(veto: 0.02, threshold: 10)
        keyboard.press(.fn)
        wait(0.08)
        keyboard.manager.handleKeyDown(keyCode: 51) // Fn+Delete, a bit late
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "cancelRequested"])
    }

    @MainActor
    func testManagerEscCancelsAndReleaseIsIgnored() {
        let (keyboard, events) = makeKeyboard(veto: 0.02, threshold: 10)
        keyboard.manager.cancelWatchEnabled = true
        keyboard.press(.fn)
        wait(0.08)
        keyboard.manager.setShortcutSessionActive(true)
        keyboard.manager.handleKeyDown(keyCode: 53) // Esc
        // AppState cancels and mirrors "no session".
        keyboard.manager.setShortcutSessionActive(false)
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "cancelRequested"])
    }

    // Tap disabled, resync in each state.

    @MainActor
    func testResyncWhileArmingDropsThePendingStart() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.resync()
        wait(0.15)
        XCTAssertEqual(events(), [])
    }

    @MainActor
    func testResyncWhileHoldingStopsInsteadOfLocking() {
        let (keyboard, events) = makeKeyboard(veto: 0.02, threshold: 10)
        keyboard.press(.fn)
        wait(0.08)
        keyboard.releaseUnobserved(.fn)
        keyboard.resync()
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testResyncWhileLockedKeepsTheLock() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.fn)
        keyboard.release(.fn)
        keyboard.manager.setShortcutSessionActive(true)
        keyboard.resync()
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated"])
        // Still locked: the next tap stops.
        keyboard.press(.fn)
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated", "toggleActivated"])
    }

    @MainActor
    func testResyncWhileStopPressIsDownStops() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.fn)
        keyboard.release(.fn)
        keyboard.manager.setShortcutSessionActive(true)
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.resync()
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated", "toggleActivated"])
    }

    @MainActor
    func testResyncWithKeyStillDownChangesNothing() {
        let (keyboard, events) = makeKeyboard(veto: 0.02, threshold: 10)
        keyboard.press(.fn)
        wait(0.08)
        keyboard.resync()
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "toggleActivated", "toggleDeactivated"])
    }

    @MainActor
    func testChordedBindingStartsOnPressWithoutVeto() {
        let (keyboard, events) = makeKeyboard(binding: .controlSpace, veto: 0.5, threshold: 10)
        keyboard.press(.leftControl)
        keyboard.manager.handleKeyDown(keyCode: 49)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.manager.handleKeyUp(keyCode: 49)
        XCTAssertEqual(events(), ["holdActivated", "toggleActivated", "toggleDeactivated"])
        keyboard.release(.leftControl)
    }

    @MainActor
    func testDisablingDropsTheLock() {
        let (keyboard, events) = makeKeyboard(veto: 0.05)
        keyboard.press(.fn)
        keyboard.release(.fn)
        keyboard.manager.isEnabled = false
        keyboard.manager.isEnabled = true
        keyboard.press(.fn)
        wait(0.15)
        // A fresh start, not a stop of the forgotten lock.
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated", "holdActivated"])
        keyboard.release(.fn)
    }

    // MARK: - End to end with ShortcutSessionController

    @MainActor
    func testControllerSeesHoldThenLockThenStop() {
        let (keyboard, _) = makeKeyboard(veto: 0.02, threshold: 10)
        let controller = ShortcutSessionController()
        var actions: [ShortcutSessionAction] = []
        keyboard.manager.onEvent = { event in
            if let action = controller.handle(event: event, isBusy: false) {
                actions.append(action)
                if action == .switchedToToggle { controller.switchToToggleMode() }
            }
            keyboard.manager.setShortcutSessionActive(controller.activeMode != nil)
        }
        keyboard.press(.fn)
        wait(0.08)
        XCTAssertEqual(controller.activeMode, .hold, "overlay shows holding")
        keyboard.release(.fn)
        XCTAssertEqual(controller.activeMode, .toggle, "overlay shows locked")
        keyboard.press(.fn)
        keyboard.release(.fn)
        XCTAssertEqual(actions, [.start(.hold), .switchedToToggle, .stop])
        XCTAssertNil(controller.activeMode)
    }

    // MARK: - Persistence and migration

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "whispur.tests.tap-or-hold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    func testExistingUsersKeepSeparateShortcuts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        // Even if the new-install default becomes Tap or hold.
        defaults.set(true, forKey: "whispur.onboarding.completed")
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults, newInstallDefault: .tapOrHold), .separate)

        defaults.removeObject(forKey: "whispur.onboarding.completed")
        defaults.set(ShortcutBinding.fnKey.storageValue, forKey: "holdShortcut")
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults, newInstallDefault: .tapOrHold), .separate)

        defaults.removeObject(forKey: "holdShortcut")
        defaults.set("off", forKey: "toggleShortcut")
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults, newInstallDefault: .tapOrHold), .separate)
    }

    @MainActor
    func testFreshInstallGetsTheNewInstallDefault() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults), DictationShortcutStyle.newInstallDefault)
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults, newInstallDefault: .tapOrHold), .tapOrHold)
        XCTAssertNil(defaults.string(forKey: AppState.shortcutStyleKey), "loading never writes")
    }

    @MainActor
    func testStoredStylePersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        defaults.set(true, forKey: "whispur.onboarding.completed")
        defaults.set(DictationShortcutStyle.tapOrHold.rawValue, forKey: AppState.shortcutStyleKey)
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults), .tapOrHold)

        defaults.set("garbage", forKey: AppState.shortcutStyleKey)
        XCTAssertEqual(AppState.loadShortcutStyle(defaults: defaults), .separate)
    }

    @MainActor
    func testTapOrHoldShortcutPersistence() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        XCTAssertEqual(AppState.loadTapOrHoldShortcut(defaults: defaults), .fnKey)
        defaults.set(ShortcutBinding.rightOption.storageValue, forKey: AppState.tapOrHoldShortcutKey)
        XCTAssertEqual(AppState.loadTapOrHoldShortcut(defaults: defaults), .rightOption)
        defaults.set(ShortcutBinding.fnDoublePress.storageValue, forKey: AppState.tapOrHoldShortcutKey)
        XCTAssertEqual(AppState.loadTapOrHoldShortcut(defaults: defaults), .fnKey, "a double press can't be held")
        defaults.set("nonsense", forKey: AppState.tapOrHoldShortcutKey)
        XCTAssertEqual(AppState.loadTapOrHoldShortcut(defaults: defaults), .fnKey)
    }

    @MainActor
    func testApplyBindingsLeavesOnlyOneStyleLive() {
        let manager = HotkeyManager()
        AppState.applyBindings(to: manager, style: .tapOrHold, hold: .fnKey, toggle: .commandFn, tapOrHold: .fnKey)
        XCTAssertNil(manager.holdBinding)
        XCTAssertNil(manager.toggleBinding)
        XCTAssertEqual(manager.tapOrHoldBinding, .fnKey)

        AppState.applyBindings(to: manager, style: .separate, hold: .fnKey, toggle: .commandFn, tapOrHold: .fnKey)
        XCTAssertEqual(manager.holdBinding, .fnKey)
        XCTAssertEqual(manager.toggleBinding, .commandFn)
        XCTAssertNil(manager.tapOrHoldBinding)
    }

    // MARK: - Copy

    @MainActor
    func testSettingsCopyAndFnHint() {
        XCTAssertEqual(DictationShortcutStyle.tapOrHold.displayName, "Tap or hold")
        XCTAssertEqual(DictationShortcutStyle.separate.displayName, "Separate shortcuts")
        XCTAssertTrue(DictationSettingsView.styleSubtitle(.tapOrHold).contains("tap to lock, hold to talk"))
        XCTAssertTrue(DictationSettingsView.needsFnTapHint(.fnKey))
        XCTAssertFalse(DictationSettingsView.needsFnTapHint(.rightOption))
        XCTAssertFalse(DictationSettingsView.needsFnTapHint(.controlSpace))
        XCTAssertEqual(AppState.tapOrHoldSummary(.fnKey), "Hold Fn to talk, tap to latch")
    }
}
