import XCTest
@testable import Whispur

final class ShortcutDoublePressTests: XCTestCase {

    // MARK: - ShortcutBinding

    func testDoublePressStorageRoundTrip() {
        let binding = ShortcutBinding.fnDoublePress
        XCTAssertEqual(binding.storageValue, "16:x:2")
        XCTAssertEqual(ShortcutBinding(storageValue: "16:x:2"), binding)
        XCTAssertTrue(ShortcutBinding(storageValue: binding.storageValue)?.isDoublePress ?? false)
    }

    func testDoublePressIsDistinctFromFnHold() {
        XCTAssertNotEqual(ShortcutBinding.fnDoublePress, .fnKey)
        XCTAssertNotEqual(ShortcutBinding.fnDoublePress.storageValue, ShortcutBinding.fnKey.storageValue)
        XCTAssertEqual(ShortcutBinding.fnDoublePress.menuTitle, "Fn twice")
    }

    func testPreviouslyStoredValuesStillDecode() {
        // Values written by earlier versions (two-part format).
        XCTAssertEqual(ShortcutBinding(storageValue: "16:x"), .fnKey)
        XCTAssertEqual(ShortcutBinding(storageValue: "17:x"), .commandFn)
        XCTAssertEqual(ShortcutBinding(storageValue: "2:49"), .controlSpace)
        XCTAssertEqual(ShortcutBinding(storageValue: "16:x")?.isDoublePress, false)
    }

    func testMalformedDoublePressStorageIsRejected() {
        XCTAssertNil(ShortcutBinding(storageValue: "16:x:3"))
        XCTAssertNil(ShortcutBinding(storageValue: "16:49:2"))
        XCTAssertNil(ShortcutBinding(storageValue: "16:x:"))
        XCTAssertNil(ShortcutBinding(storageValue: "1:"))
    }

    func testDoublePressCodableIsBackwardCompatible() throws {
        let legacyJSON = #"{"modifiers":16}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(ShortcutBinding.self, from: legacyJSON)
        XCTAssertEqual(legacy, .fnKey)

        let encoded = try JSONEncoder().encode(ShortcutBinding.fnDoublePress)
        XCTAssertEqual(try JSONDecoder().decode(ShortcutBinding.self, from: encoded), .fnDoublePress)
    }

    // MARK: - Toggle default persistence

    @MainActor
    func testDefaultToggleIsCommandFnWhenNothingStored() throws {
        let suite = "whispur.tests.toggle-default.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ShortcutBinding.defaultToggle, .commandFn)
        XCTAssertEqual(AppState.loadToggleShortcut(holdShortcut: .fnKey, defaults: defaults), .commandFn)
        // Loading never writes the fallback back.
        XCTAssertNil(defaults.string(forKey: "toggleShortcut"))
    }

    @MainActor
    func testStoredToggleChoicesStillLoad() throws {
        let suite = "whispur.tests.toggle-stored.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(ShortcutBinding.fnDoublePress.storageValue, forKey: "toggleShortcut")
        XCTAssertEqual(AppState.loadToggleShortcut(holdShortcut: .fnKey, defaults: defaults), .fnDoublePress)

        defaults.set("off", forKey: "toggleShortcut")
        XCTAssertNil(AppState.loadToggleShortcut(holdShortcut: .fnKey, defaults: defaults))

        // A stored toggle that collides with the hold shortcut falls back to the default.
        defaults.set(ShortcutBinding.rightOption.storageValue, forKey: "toggleShortcut")
        XCTAssertEqual(AppState.loadToggleShortcut(holdShortcut: .rightOption, defaults: defaults), .commandFn)
    }

    func testDoublePressPresets() {
        XCTAssertEqual(ShortcutBinding.togglePresets.first, .commandFn)
        XCTAssertEqual(ShortcutBinding.togglePresets.dropFirst().first, .fnDoublePress)
        XCTAssertFalse(ShortcutBinding.holdPresets.contains(.fnDoublePress))
        XCTAssertFalse(ShortcutBinding.holdPresets.contains { $0.isDoublePress })
    }

    func testToggleCopyReadsCorrectly() {
        XCTAssertEqual(ShortcutBinding.fnDoublePress.toggleStartPhrase, "Press Fn twice")
        XCTAssertEqual(ShortcutBinding.fnDoublePress.toggleStopPhrase, "press Fn once")
        XCTAssertEqual(ShortcutBinding.commandFn.toggleStartPhrase, "Press Command + Fn")
        XCTAssertEqual(ShortcutBinding.commandFn.toggleStopPhrase, "press Command + Fn again")
        XCTAssertEqual("press Fn once".capitalizedFirst, "Press Fn once")
    }

    // MARK: - ShortcutSessionController

    func testControllerStartsOnDoublePressAndStopsOnSinglePress() {
        let controller = ShortcutSessionController()

        // Second tap: HotkeyManager emits activated + deactivated together.
        XCTAssertEqual(controller.handle(event: .toggleActivated, isBusy: false), .start(.toggle))
        XCTAssertNil(controller.handle(event: .toggleDeactivated, isBusy: false))
        XCTAssertTrue(controller.toggleStopArmed)

        // Single stop press.
        XCTAssertEqual(controller.handle(event: .toggleActivated, isBusy: false), .stop)
        XCTAssertNil(controller.activeMode)

        // The stop press's physical release is not reported; a stray
        // deactivation after stop must not start anything.
        XCTAssertNil(controller.handle(event: .toggleDeactivated, isBusy: false))
        XCTAssertNil(controller.activeMode)
    }

    func testControllerIgnoresHoldWhileToggleRunning() {
        let controller = ShortcutSessionController()
        _ = controller.handle(event: .toggleActivated, isBusy: false)
        _ = controller.handle(event: .toggleDeactivated, isBusy: false)
        XCTAssertNil(controller.handle(event: .holdActivated, isBusy: false))
        XCTAssertNil(controller.handle(event: .holdDeactivated, isBusy: false))
        XCTAssertEqual(controller.activeMode, .toggle)
    }

    func testManualToggleStartStopsOnFirstShortcutPress() {
        let controller = ShortcutSessionController()
        controller.beginManual(mode: .toggle)
        XCTAssertTrue(controller.toggleStopArmed)
        XCTAssertEqual(controller.handle(event: .toggleActivated, isBusy: false), .stop)
    }

    // MARK: - DoublePressDetector

    private func makeDetector() -> DoublePressDetector {
        DoublePressDetector(window: 0.4, maxTapDuration: 0.33)
    }

    func testDoubleTapFiresOnceOnSecondPress() {
        var d = makeDetector()
        XCTAssertEqual(d.press(at: 0.0, sessionActive: false), .none)
        d.release(at: 0.1)
        XCTAssertEqual(d.press(at: 0.3, sessionActive: false), .start)
        d.release(at: 0.4)
    }

    func testSlowTapsDoNotFire() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.1)
        XCTAssertEqual(d.press(at: 0.55, sessionActive: false), .none)
        d.release(at: 0.6)
        // ...but the slow second tap can itself be the first of a new pair.
        XCTAssertEqual(d.press(at: 0.8, sessionActive: false), .start)
    }

    func testTapThenHoldDoesNotFire() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.5) // held past the hold threshold: a hold, not a tap
        XCTAssertEqual(d.press(at: 0.6, sessionActive: false), .none)
    }

    func testHoldInterruptResetsTracking() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.interrupt() // hold armed and fired
        d.release(at: 0.2)
        XCTAssertEqual(d.press(at: 0.3, sessionActive: false), .none)
    }

    func testChordDuringTapResets() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.interrupt() // Fn+Delete
        d.release(at: 0.1)
        XCTAssertEqual(d.press(at: 0.2, sessionActive: false), .none)
    }

    func testKeyBetweenTapsResets() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.1)
        d.interrupt() // typed a key between the taps
        XCTAssertEqual(d.press(at: 0.2, sessionActive: false), .none)
    }

    func testTripleTapDoesNotDoubleFire() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.08)
        XCTAssertEqual(d.press(at: 0.16, sessionActive: false), .start)
        d.release(at: 0.24)
        // Third tap: session is now active, but it lands inside the window.
        XCTAssertEqual(d.press(at: 0.32, sessionActive: true), .swallow)
        d.release(at: 0.4)
        // Without a session (e.g. start was ignored while busy), a third tap
        // must not count as a second tap of a fresh pair either.
        var d2 = makeDetector()
        _ = d2.press(at: 0.0, sessionActive: false)
        d2.release(at: 0.08)
        XCTAssertEqual(d2.press(at: 0.16, sessionActive: false), .start)
        d2.release(at: 0.24)
        XCTAssertEqual(d2.press(at: 0.32, sessionActive: false), .none)
    }

    func testSinglePressStopsActiveSession() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.1)
        XCTAssertEqual(d.press(at: 0.2, sessionActive: false), .start)
        d.release(at: 0.3)
        XCTAssertEqual(d.press(at: 3.0, sessionActive: true), .stop)
        d.release(at: 3.1)
        // The stop press does not count as the first tap of a new pair.
        XCTAssertEqual(d.press(at: 3.2, sessionActive: false), .none)
    }

    func testSinglePressStopsManualSession() {
        var d = makeDetector()
        XCTAssertEqual(d.press(at: 5.0, sessionActive: true), .stop)
    }

    func testKeystrokeAfterStartLiftsTripleTapGuard() {
        var d = makeDetector()
        _ = d.press(at: 0.0, sessionActive: false)
        d.release(at: 0.1)
        _ = d.press(at: 0.2, sessionActive: false)
        d.release(at: 0.25)
        d.interrupt() // Esc or another deliberate key
        XCTAssertEqual(d.press(at: 0.4, sessionActive: true), .stop)
    }
}
