import XCTest
@testable import Whispur

/// Drives HotkeyManager with flagsChanged events that carry realistic raw
/// modifier flags (device-independent family bit + IOLLEvent.h device bit),
/// the way the CGEvent tap delivers them.
@MainActor
final class FakeKeyboard {
    enum Key: CaseIterable {
        case fn, leftCommand, rightCommand, leftShift, rightShift
        case leftOption, rightOption, leftControl, rightControl

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .leftCommand: return 55
            case .rightCommand: return 54
            case .leftShift: return 56
            case .rightShift: return 60
            case .leftOption: return 58
            case .rightOption: return 61
            case .leftControl: return 59
            case .rightControl: return 62
            }
        }

        var familyFlag: UInt64 {
            switch self {
            case .fn: return 0x0080_0000
            case .leftCommand, .rightCommand: return 0x0010_0000
            case .leftShift, .rightShift: return 0x0002_0000
            case .leftOption, .rightOption: return 0x0008_0000
            case .leftControl, .rightControl: return 0x0004_0000
            }
        }

        var deviceFlag: UInt64 {
            switch self {
            case .fn: return 0
            case .leftCommand: return 0x08
            case .rightCommand: return 0x10
            case .leftShift: return 0x02
            case .rightShift: return 0x04
            case .leftOption: return 0x20
            case .rightOption: return 0x40
            case .leftControl: return 0x01
            case .rightControl: return 0x2000
            }
        }
    }

    let manager: HotkeyManager
    private(set) var held: Set<Key> = []

    init(manager: HotkeyManager) {
        self.manager = manager
    }

    /// Raw flags for the keys physically held right now. 0x100 is the
    /// NX_NONCOALSESCEDMASK bit real events always carry.
    var flags: UInt64 {
        held.reduce(0x100) { $0 | $1.familyFlag | $1.deviceFlag }
    }

    func press(_ key: Key) {
        held.insert(key)
        manager.handleModifierChange(keyCode: key.keyCode, flags: flags)
    }

    func release(_ key: Key) {
        held.remove(key)
        manager.handleModifierChange(keyCode: key.keyCode, flags: flags)
    }

    /// The key goes up physically but the event never reaches the manager
    /// (event tap disabled by secure input, or by timeout).
    func releaseUnobserved(_ key: Key) {
        held.remove(key)
    }

    /// What the tap does after re-enabling: read the hardware state.
    func resync(downKeys: Set<UInt16> = []) {
        manager.resyncKeyState(flags: flags, keyIsDown: { downKeys.contains($0) })
    }
}

final class HotkeyModifierStateTests: XCTestCase {

    @MainActor
    private func makeKeyboard(
        hold: ShortcutBinding? = .fnKey,
        toggle: ShortcutBinding? = nil,
        threshold: TimeInterval = 0
    ) -> (FakeKeyboard, () -> [String]) {
        let manager = HotkeyManager()
        manager.holdArmThreshold = threshold
        manager.holdBinding = hold
        manager.toggleBinding = toggle
        var events: [HotkeyManager.Event] = []
        manager.onEvent = { events.append($0) }
        return (FakeKeyboard(manager: manager), { events.map(String.init(describing:)) })
    }

    // (b) press with the Fn flag set, release with it cleared.
    @MainActor
    func testFnPressAndReleaseFollowTheFlag() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // The v0.23.0 bug: toggling meant a duplicate press event (Fn flag still
    // set) read as a release. Flags make it a no-op.
    @MainActor
    func testDuplicateFnPressDoesNotReadAsRelease() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.manager.handleModifierChange(keyCode: 63, flags: keyboard.flags)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // (a) a missed Fn key-up heals on the next flagsChanged.
    @MainActor
    func testMissedFnKeyUpSelfHealsOnNextFlagsChanged() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        XCTAssertEqual(events(), ["holdActivated"])

        // Next modifier event arrives with the Fn flag cleared.
        keyboard.press(.leftShift)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])

        // And the following Fn press/release is the right way round again.
        keyboard.release(.leftShift)
        keyboard.press(.fn)
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated", "holdActivated", "holdDeactivated"])
    }

    // (a) the same heal when the next event is the Fn press itself: it must
    // read as a press, and its release must stop the hold.
    @MainActor
    func testMissedFnKeyUpThenNextFnPressIsAPress() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.press(.fn)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // An untracked modifier (Caps Lock, keyCode 57) also carries the flags.
    @MainActor
    func testUntrackedFlagsChangedStillResyncs() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.manager.handleModifierChange(keyCode: 57, flags: keyboard.flags | 0x0001_0000)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // (c) tap disabled while recording; Fn released meanwhile.
    @MainActor
    func testTapResyncReleasesHoldWhenFnIsUp() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.resync()
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    @MainActor
    func testTapResyncKeepsHoldWhenFnIsStillDown() {
        let (keyboard, events) = makeKeyboard()
        keyboard.press(.fn)
        keyboard.resync()
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // (c) with the real arm threshold: the hold is armed, Fn goes up unseen,
    // and the resync cancels the arm so the timer never starts a recording.
    @MainActor
    func testTapResyncCancelsPendingArm() {
        let (keyboard, events) = makeKeyboard(threshold: 0.05)
        keyboard.press(.fn)
        keyboard.releaseUnobserved(.fn)
        keyboard.resync()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(events(), [])
    }

    // (c) a chorded hold (Control+Space) whose Space key-up was dropped.
    @MainActor
    func testTapResyncPrunesStaleNonModifierKeys() {
        let (keyboard, events) = makeKeyboard(hold: .controlSpace)
        keyboard.press(.leftControl)
        keyboard.manager.handleKeyDown(keyCode: 49)
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.releaseUnobserved(.leftControl)
        keyboard.resync(downKeys: [])
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // (d) left and right Command are told apart by their device bits.
    @MainActor
    func testLeftAndRightCommandTrackedIndependently() {
        let (keyboard, events) = makeKeyboard(hold: nil, toggle: .commandFn)
        keyboard.press(.leftCommand)
        keyboard.press(.rightCommand)
        keyboard.release(.leftCommand)
        // Right Command still held: Command + Fn must still fire.
        keyboard.press(.fn)
        XCTAssertEqual(events(), ["toggleActivated"])
        keyboard.release(.fn)
        keyboard.release(.rightCommand)
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated"])
    }

    @MainActor
    func testPressedSetFromDeviceBits() {
        let both: UInt64 = 0x0010_0000 | 0x08 | 0x10
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: both, previous: [], changedKeyCode: 55), [54, 55])
        let rightOnly: UInt64 = 0x0010_0000 | 0x10
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: rightOnly, previous: [54, 55], changedKeyCode: 55), [54])
        let rightControl: UInt64 = 0x0004_0000 | 0x2000
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: rightControl, previous: [], changedKeyCode: 62), [62])
        // Family flag cleared wins over everything previously held.
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: 0x100, previous: [54, 55, 63], changedKeyCode: 63), [])
        // Synthetic event: family flag without device bits still reads as held.
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: 0x0010_0000, previous: [], changedKeyCode: 54), [54])
        XCTAssertEqual(HotkeyManager.pressedModifierKeyCodes(fromRawFlags: 0x0010_0000, previous: [], changedKeyCode: nil), [55])
    }

    // Fn+other-key chord during the arm window still vetoes the hold.
    @MainActor
    func testChordDuringArmWindowStillSuppressesHold() {
        let (keyboard, events) = makeKeyboard(threshold: 0.05)
        keyboard.press(.fn)
        keyboard.manager.handleKeyDown(keyCode: 51) // Fn+Delete
        keyboard.manager.handleKeyUp(keyCode: 51)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        keyboard.release(.fn)
        XCTAssertEqual(events(), [])
    }

    // Bare-Fn hold with the real threshold: activates after the delay and
    // deactivates on release.
    @MainActor
    func testFnHoldWithThresholdActivatesThenReleases() {
        let (keyboard, events) = makeKeyboard(threshold: 0.05)
        keyboard.press(.fn)
        XCTAssertEqual(events(), [])
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(events(), ["holdActivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["holdActivated", "holdDeactivated"])
    }

    // Fn double press still toggles through the flags path.
    @MainActor
    func testFnDoublePressStillStartsToggle() {
        let (keyboard, events) = makeKeyboard(hold: nil, toggle: .fnDoublePress, threshold: 0.33)
        keyboard.press(.fn)
        keyboard.release(.fn)
        keyboard.press(.fn)
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated"])
        keyboard.release(.fn)
        XCTAssertEqual(events(), ["toggleActivated", "toggleDeactivated"])
    }
}
