import Cocoa
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "HotkeyManager")
private let trackedModifierKeyCodes: Set<UInt16> = [
    54, 55,       // Right Cmd, Left Cmd
    56, 60,       // Left Shift, Right Shift
    58, 61,       // Left Option, Right Option
    59, 62,       // Left Control, Right Control
    63,           // Fn / Globe key
]

/// Global hotkey detection using CGEventTap with NSEvent monitor fallback.
@MainActor
final class HotkeyManager {

    enum Event: Sendable {
        case holdActivated
        case holdDeactivated
        case toggleActivated
        case toggleDeactivated
        case cancelRequested
    }

    nonisolated(unsafe) var onEvent: ((Event) -> Void)?
    /// The hold-to-talk shortcut. nil when the user removed it: no key
    /// starts a hold recording, and the hands-free shortcut still works.
    nonisolated(unsafe) var holdBinding: ShortcutBinding? = .fnKey
    nonisolated(unsafe) var toggleBinding: ShortcutBinding? = nil {
        didSet {
            stateLock.withLock { state in
                state.doublePress.reset()
                state.doublePressDown = false
            }
        }
    }
    nonisolated(unsafe) var cancelWatchEnabled = false

    /// What happens on the keyboard while the "Use raw" toast is up.
    enum UseRawKey: Sendable {
        /// ⌥⌘Z: swap the paste for the raw transcript.
        case useRaw
        /// Any other key: the user kept typing, so the offer ends.
        case otherKey
    }

    /// ⌥⌘Z (Z is virtual key 6). Only ours while the toast is up.
    nonisolated static let useRawKeyCode: UInt16 = 6
    /// Armed while the "Use raw" toast is up. ⌥⌘Z is then consumed.
    nonisolated(unsafe) var useRawWatchEnabled = false
    nonisolated(unsafe) var onUseRawKey: ((UseRawKey) -> Void)?

    /// The Settings master switch. While false, no shortcut starts or stops
    /// dictation (Esc-to-cancel still works). Turning it off drops any
    /// in-flight hold or toggle state so nothing fires when it comes back.
    nonisolated(unsafe) var isEnabled = true {
        didSet {
            guard oldValue != isEnabled, !isEnabled else { return }
            holdArmTimer?.cancel()
            holdArmTimer = nil
            stateLock.withLock { state in
                state.holdActive = false
                state.holdArming = false
                state.holdSuppressed = false
                state.toggleActive = false
                state.doublePress.reset()
                state.doublePressDown = false
            }
        }
    }

    /// Delay before a bare-modifier hold binding (e.g. Fn alone) activates.
    /// Short taps within this window are ignored so macOS can handle its own
    /// Fn behaviors (emoji picker, dictation) without racing our overlay.
    /// Chorded bindings with an explicit keyCode activate immediately.
    ///
    /// The window also has to cover reaching for the second key of an Fn
    /// chord (Fn+arrow, Fn+Delete): a chord key pressed inside it cancels
    /// the arm. 0.18 s caught those chords and was raised to 0.33 s for
    /// that reason. It is the only wait before the overlay shows; nothing
    /// else on the start path waits on the recorder.
    nonisolated(unsafe) var holdArmThreshold: TimeInterval = 0.33

    /// Maximum gap between the release of the first clean tap and the second
    /// press for a double-press toggle binding (e.g. "Fn twice") to fire.
    nonisolated(unsafe) var doublePressWindow: TimeInterval = 0.4

    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var eventCount = 0
    @Published private(set) var lastEventDescription = ""

    // Tracked key state — protected by `stateLock` so concurrent reads from the
    // CGEvent tap callback and NSEvent monitors can't tear the sets.
    private struct SharedState {
        var pressedModifierKeyCodes: Set<UInt16> = []
        var pressedKeyCodes: Set<UInt16> = []
        var holdActive = false
        var holdArming = false
        // Set when a chord key was pressed during a bare-modifier arm window,
        // signalling the modifier is being used as a chord (e.g. Fn+Delete).
        // Blocks re-arming until the modifier is fully released.
        var holdSuppressed = false
        var toggleActive = false
        // Double-press toggle bindings (e.g. Fn twice). `doublePressDown`
        // tracks the binding's modifier edge; `toggleSessionActive` says
        // whether a single press should stop a running toggle session. The
        // manager sets it when it emits start/stop, and AppState re-syncs it
        // from ShortcutSessionController after every event so Stop button,
        // Esc and manual starts are reflected too.
        var doublePress = DoublePressDetector(window: 0.4, maxTapDuration: 0.33)
        var doublePressDown = false
        var toggleSessionActive = false
    }
    private let stateLock = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var holdArmTimer: DispatchWorkItem?
    private var localFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    /// Dedicated ESC watcher that runs in parallel with the CGEvent tap.
    /// Some focused-input contexts (secure input, certain IMEs, other taps
    /// ahead of ours) can swallow keyDown events before our tap sees them.
    /// Global monitors can't *consume* events, but they reliably *observe*,
    /// so they let us still fire cancel even when the tap path misses.
    private var globalEscMonitor: Any?
    private var accessibilityTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        checkAccessibilityAndInstall()
        scheduleAccessibilityPollIfNeeded()
        installGlobalEscMonitor()
    }

    /// Poll for Accessibility permission changes only until it's granted and
    /// the CGEvent tap is installed. Once monitoring is up, the timer stops —
    /// nothing else flips the grant state at runtime in a way that matters here.
    private func scheduleAccessibilityPollIfNeeded() {
        guard accessibilityTimer == nil else { return }
        guard eventTap == nil else { return }

        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkAccessibilityAndInstall()
                if self.eventTap != nil {
                    self.accessibilityTimer?.invalidate()
                    self.accessibilityTimer = nil
                }
            }
        }
    }

    func stop() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        teardownEventTap()
        teardownLocalMonitors()
        teardownGlobalEscMonitor()
        holdArmTimer?.cancel()
        holdArmTimer = nil
        stateLock.withLock { state in
            state.pressedModifierKeyCodes.removeAll()
            state.pressedKeyCodes.removeAll()
            state.holdActive = false
            state.holdArming = false
            state.holdSuppressed = false
            state.toggleActive = false
            state.doublePress.reset()
            state.doublePressDown = false
            state.toggleSessionActive = false
        }
        isMonitoring = false
    }

    /// Tell the manager whether a toggle session is running, so a single
    /// press of a double-press binding stops it instead of starting a tap.
    nonisolated func setToggleSessionActive(_ active: Bool) {
        stateLock.withLock { state in
            state.toggleSessionActive = active
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // Re-arm the poll so we notice the grant quickly once the user responds.
        scheduleAccessibilityPollIfNeeded()
    }

    // MARK: - Setup

    private func checkAccessibilityAndInstall() {
        let trusted = AXIsProcessTrusted()
        isAccessibilityGranted = trusted

        if trusted && eventTap == nil {
            installEventTap()
            teardownLocalMonitors()
        } else if !trusted && eventTap == nil && localFlagsMonitor == nil {
            installLocalMonitors()
        }
    }

    // MARK: - CGEventTap (primary)

    private func installEventTap() {
        let eventMask: CGEventMask = (
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)
        )

        let unmanagedSelf = Unmanaged.passUnretained(self)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                return manager.handleEventTap(type: type, event: event)
            },
            userInfo: unmanagedSelf.toOpaque()
        ) else {
            logger.error("CGEvent.tapCreate failed — Accessibility granted but tap creation failed")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        self.isMonitoring = true

        logger.info("CGEventTap installed — monitoring for \(self.holdBinding?.displayName ?? "no hold shortcut")")
    }

    private func teardownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - NSEvent Monitors (fallback when CGEventTap unavailable)

    private func installLocalMonitors() {
        // Global monitors detect events from ALL apps (but can't consume them)
        // This is what we need for a menu bar app that's never focused
        localFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            _ = self?.handleFlagsChanged(event)
        }
        localKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            _ = self?.handleKeyDown(event)
        }
        localKeyUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyUp) { [weak self] event in
            self?.handleKeyUp(event)
        }
        isMonitoring = true
        logger.info("Global NSEvent monitors installed (fallback — no Accessibility)")
    }

    private func teardownLocalMonitors() {
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m); localKeyDownMonitor = nil }
        if let m = localKeyUpMonitor { NSEvent.removeMonitor(m); localKeyUpMonitor = nil }
    }

    // MARK: - Global ESC watcher (parallel to CGEvent tap)

    private func installGlobalEscMonitor() {
        guard globalEscMonitor == nil else { return }
        globalEscMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            guard let self, self.cancelWatchEnabled else { return }
            logger.info("ESC observed by global monitor — firing cancel")
            self.onEvent?(.cancelRequested)
        }
    }

    private func teardownGlobalEscMonitor() {
        if let m = globalEscMonitor {
            NSEvent.removeMonitor(m)
            globalEscMonitor = nil
        }
    }

    // MARK: - CGEventTap Handler

    private nonisolated func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if macOS disabled it
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            // While the tap was off (secure input such as a password dialog,
            // or a slow callback) key-up events may have been dropped. Resync
            // from the real hardware state so a released hold key stops the
            // recording now instead of on its next press.
            logger.info("Event tap re-enabled after \(type == .tapDisabledByTimeout ? "timeout" : "user input") — resyncing key state")
            resyncKeyState(
                flags: CGEventSource.flagsState(.combinedSessionState).rawValue,
                keyIsDown: { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) }
            )
            return Unmanaged.passUnretained(event)

        case .flagsChanged, .keyDown, .keyUp:
            guard let nsEvent = NSEvent(cgEvent: event) else {
                return Unmanaged.passUnretained(event)
            }

            let shouldConsume: Bool
            switch type {
            case .flagsChanged:
                shouldConsume = handleFlagsChanged(nsEvent)
            case .keyDown:
                shouldConsume = handleKeyDown(nsEvent)
            case .keyUp:
                handleKeyUp(nsEvent)
                shouldConsume = false
            default:
                shouldConsume = false
            }

            return shouldConsume ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: - Event Handlers (shared between tap and local monitors)

    /// Handle modifier key changes. Returns true if the event should be consumed.
    @discardableResult
    private nonisolated func handleFlagsChanged(_ event: NSEvent) -> Bool {
        // Prefer the CGEvent's raw flags: they carry the device-dependent
        // left/right bits. NSEvent's raw value keeps them too, as a fallback.
        let flags = event.cgEvent?.flags.rawValue ?? UInt64(event.modifierFlags.rawValue)
        logger.info("flagsChanged: keyCode=\(event.keyCode) flags=\(flags)")
        return handleModifierChange(keyCode: event.keyCode, flags: flags)
    }

    /// A modifier key went down or up. `flags` is the event's raw modifier
    /// state (CGEventFlags / NSEvent.ModifierFlags raw value). The pressed
    /// set is recomputed from it on every event rather than toggled, so a
    /// dropped key-up heals on the next flagsChanged instead of inverting
    /// that key's state for good. Internal so tests can drive it directly.
    @discardableResult
    nonisolated func handleModifierChange(keyCode: UInt16, flags: UInt64) -> Bool {
        let isKnown = trackedModifierKeyCodes.contains(keyCode)

        DispatchQueue.main.async {
            self.eventCount += 1
            self.lastEventDescription = "flags keyCode=\(keyCode)"
        }

        let (changed, isPressed) = stateLock.withLock { state -> (Bool, Bool) in
            let next = Self.pressedModifierKeyCodes(
                fromRawFlags: flags,
                previous: state.pressedModifierKeyCodes,
                changedKeyCode: keyCode
            )
            let changed = next != state.pressedModifierKeyCodes
            state.pressedModifierKeyCodes = next
            return (changed, next.contains(keyCode))
        }

        // An untracked key (e.g. Caps Lock) still resyncs the set above, but
        // only drives the bindings when that resync actually changed something.
        guard isKnown || changed else { return false }
        if isKnown {
            logger.info("Modifier \(isPressed ? "pressed" : "released"): keyCode=\(keyCode)")
        } else {
            logger.info("Modifier state resynced from flags on keyCode=\(keyCode)")
        }

        // Any modifier other than the double-press binding's own resets
        // double-press tracking (Fn+Cmd is a chord, not a tap).
        let otherModifier = toggleBinding.map { binding in
            binding.isDoublePress && !Self.keyCodes(for: binding.modifiers).contains(keyCode)
        } ?? false
        evaluateBindings(interruptDoublePress: otherModifier)
        return false
    }

    /// Rebuild key state from the real hardware state after a window in
    /// which events may have been dropped (event tap disabled by timeout or
    /// secure input), then re-evaluate the bindings so a hold whose key is no
    /// longer down is released. `keyIsDown` prunes stale non-modifier keys.
    nonisolated func resyncKeyState(flags: UInt64, keyIsDown: (UInt16) -> Bool) {
        let changed = stateLock.withLock { state -> Bool in
            let modifiers = Self.pressedModifierKeyCodes(
                fromRawFlags: flags,
                previous: state.pressedModifierKeyCodes,
                changedKeyCode: nil
            )
            let keys = state.pressedKeyCodes.filter(keyIsDown)
            let changed = modifiers != state.pressedModifierKeyCodes || keys != state.pressedKeyCodes
            state.pressedModifierKeyCodes = modifiers
            state.pressedKeyCodes = keys
            return changed
        }
        if changed {
            logger.info("Key state resync corrected stale state")
        }
        evaluateBindings()
    }

    private nonisolated func handleKeyDown(_ event: NSEvent) -> Bool {
        handleKeyDown(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    /// Whether a key-down is the "Use raw" shortcut: exactly ⌥⌘Z.
    nonisolated static func isUseRawShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == useRawKeyCode
            && modifiers.intersection([.command, .option, .shift, .control]) == [.command, .option]
    }

    @discardableResult
    nonisolated func handleKeyDown(keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.insert(keyCode)
        }
        if useRawWatchEnabled {
            if Self.isUseRawShortcut(keyCode: keyCode, modifiers: modifiers) {
                onUseRawKey?(.useRaw)
                return true
            }
            onUseRawKey?(.otherKey)
        }
        // Escape while recording → cancel (consume the event so the focused app doesn't see it).
        if keyCode == 53 {
            logger.info("ESC keyDown via tap — cancelWatchEnabled=\(self.cancelWatchEnabled)")
            if cancelWatchEnabled {
                onEvent?(.cancelRequested)
                return true
            }
        }
        // Bare-modifier hold (e.g. Fn alone): if another key is pressed while
        // the modifier is held, treat it as a chord (e.g. Fn+Delete) and veto
        // both the pending arm and any re-arm until the modifier is released.
        if let holdBinding, holdBinding.keyCode == nil {
            let cancelledArm = stateLock.withLock { state -> Bool in
                guard Self.bindingIsActive(holdBinding, state: state) else { return false }
                let wasArming = state.holdArming
                state.holdArming = false
                state.holdSuppressed = true
                return wasArming
            }
            if cancelledArm {
                holdArmTimer?.cancel()
                holdArmTimer = nil
                logger.info("Hold arm cancelled — chord key pressed (keyCode=\(keyCode))")
            }
        }
        // Any regular key (Fn+Delete, typing between taps) resets double-press tracking.
        evaluateBindings(interruptDoublePress: true)
        return false
    }

    private nonisolated func handleKeyUp(_ event: NSEvent) {
        handleKeyUp(keyCode: event.keyCode)
    }

    nonisolated func handleKeyUp(keyCode: UInt16) {
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.remove(keyCode)
        }
        evaluateBindings()
    }

    // MARK: - Binding Evaluation

    /// Check all bindings against current key state and fire events.
    private nonisolated func evaluateBindings(interruptDoublePress: Bool = false) {
        guard isEnabled else { return }
        let holdBinding = self.holdBinding
        let useThreshold = holdBinding.map { $0.keyCode == nil } == true && holdArmThreshold > 0
        let toggleBinding = self.toggleBinding
        let now = ProcessInfo.processInfo.systemUptime

        enum HoldAction { case none, arm, cancelArm }

        let (transitions, holdAction) = stateLock.withLock { state -> ([Event], HoldAction) in
            var events: [Event] = []
            var action: HoldAction = .none

            // Double-press toggle binding: edge-driven, evaluated before hold
            // so a press it acts on can veto the hold arm in the same pass.
            if let toggleBinding, toggleBinding.isDoublePress {
                state.doublePress.window = doublePressWindow
                state.doublePress.maxTapDuration = holdArmThreshold
                if interruptDoublePress {
                    state.doublePress.interrupt()
                }

                let modifiers = Self.currentModifiers(state: state)
                let isDown = modifiers.isSuperset(of: toggleBinding.modifiers)
                if isDown && !state.doublePressDown {
                    state.doublePressDown = true
                    if modifiers != toggleBinding.modifiers {
                        // Pressed while another modifier is held: a chord, never a tap.
                        state.doublePress.interrupt()
                    } else {
                        let pressAction = state.doublePress.press(at: now, sessionActive: state.toggleSessionActive)
                        switch pressAction {
                        case .none:
                            break
                        case .start:
                            // Start on the second press itself (snappy) and
                            // emit the release edge right away so the
                            // controller arms its stop. The physical release
                            // is ignored, and hold is suppressed for this
                            // press so keeping it down never also starts a
                            // push-to-talk recording.
                            state.toggleSessionActive = true
                            events.append(.toggleActivated)
                            events.append(.toggleDeactivated)
                        case .stop:
                            // One press stops, on press (not after the hold
                            // threshold). Hold is suppressed for this press so
                            // it cannot start a new recording after the stop.
                            state.toggleSessionActive = false
                            events.append(.toggleActivated)
                        case .swallow:
                            break
                        }
                        if pressAction != .none {
                            state.holdSuppressed = true
                            if state.holdArming {
                                state.holdArming = false
                                action = .cancelArm
                            }
                        }
                    }
                } else if !isDown && state.doublePressDown {
                    state.doublePressDown = false
                    state.doublePress.release(at: now)
                }
            }

            let holdNowMatches = holdBinding.map { Self.bindingIsActive($0, state: state) } ?? false
            let toggleNowActive = toggleBinding.map { binding in
                !binding.isDoublePress && Self.bindingIsActive(binding, state: state)
            } ?? false

            if useThreshold {
                if holdNowMatches {
                    if !state.holdActive && !state.holdArming && !state.holdSuppressed {
                        state.holdArming = true
                        action = .arm
                    }
                } else {
                    if state.holdArming {
                        state.holdArming = false
                        action = .cancelArm
                    }
                    if state.holdActive {
                        state.holdActive = false
                        events.append(.holdDeactivated)
                    }
                    // Modifier fully released — clear suppression so the next
                    // clean press can arm again.
                    state.holdSuppressed = false
                }
            } else {
                if holdNowMatches && !state.holdActive {
                    state.holdActive = true
                    events.append(.holdActivated)
                } else if !holdNowMatches && state.holdActive {
                    state.holdActive = false
                    events.append(.holdDeactivated)
                }
            }

            if toggleNowActive && !state.toggleActive {
                state.toggleActive = true
                events.append(.toggleActivated)
            }
            if !toggleNowActive && state.toggleActive {
                state.toggleActive = false
                events.append(.toggleDeactivated)
            }

            return (events, action)
        }

        switch holdAction {
        case .arm:
            StartLatencyTrace.begin("hold key down")
            scheduleHoldArmTimer()
        case .cancelArm:
            holdArmTimer?.cancel()
            holdArmTimer = nil
        case .none:
            break
        }

        for event in transitions {
            switch event {
            case .holdActivated:
                // Chorded holds activate on press, with no arm threshold.
                StartLatencyTrace.begin("hold shortcut down")
                logger.info("Hold activated")
            case .holdDeactivated: logger.info("Hold deactivated")
            case .toggleActivated:
                StartLatencyTrace.begin("toggle shortcut down")
                logger.info("Toggle activated")
            default: break
            }
            onEvent?(event)
        }
    }

    /// Schedule a deferred activation for bare-modifier holds so brief taps
    /// don't trigger recording (and don't conflict with macOS Fn behaviors).
    private nonisolated func scheduleHoldArmTimer() {
        holdArmTimer?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holdArmTimer = nil

            let shouldFire = self.stateLock.withLock { state -> Bool in
                guard self.isEnabled, state.holdArming else { return false }
                state.holdArming = false
                // Re-check that the binding is still held when the timer fires.
                guard let holdBinding = self.holdBinding,
                      Self.bindingIsActive(holdBinding, state: state) else {
                    return false
                }
                state.holdActive = true
                // A tap that became a hold can never be part of a double press.
                state.doublePress.interrupt()
                return true
            }

            if shouldFire {
                StartLatencyTrace.mark("hold armed")
                logger.info("Hold activated (after threshold)")
                self.onEvent?(.holdActivated)
            }
        }

        holdArmTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdArmThreshold, execute: work)
    }

    /// Check if a binding matches the supplied pressed-key snapshot. Pure;
    /// expected to be called from inside `stateLock.withLock`.
    private nonisolated static func bindingIsActive(_ binding: ShortcutBinding, state: SharedState) -> Bool {
        let activeModifiers = currentModifiers(state: state)
        guard activeModifiers.isSuperset(of: binding.modifiers) else {
            return false
        }

        if binding.keyCode == nil {
            return true
        }

        if let keyCode = binding.keyCode {
            return state.pressedKeyCodes.contains(keyCode)
        }

        return false
    }

    /// One modifier family: its device-independent flag plus, per physical
    /// key, the device-dependent bit (IOKit/IOLLEvent.h NX_DEVICE*KEYMASK).
    private struct ModifierFamily {
        let flag: UInt64
        let keys: [(mask: UInt64, keyCode: UInt16)]
    }

    private nonisolated static let modifierFamilies: [ModifierFamily] = [
        // NX_SECONDARYFNMASK; Fn has no left/right device bits.
        ModifierFamily(flag: 0x0080_0000, keys: [(0, 63)]),
        // NX_COMMANDMASK — NX_DEVICELCMDKEYMASK / NX_DEVICERCMDKEYMASK
        ModifierFamily(flag: 0x0010_0000, keys: [(0x08, 55), (0x10, 54)]),
        // NX_SHIFTMASK — NX_DEVICELSHIFTKEYMASK / NX_DEVICERSHIFTKEYMASK
        ModifierFamily(flag: 0x0002_0000, keys: [(0x02, 56), (0x04, 60)]),
        // NX_ALTERNATEMASK — NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK
        ModifierFamily(flag: 0x0008_0000, keys: [(0x20, 58), (0x40, 61)]),
        // NX_CONTROLMASK — NX_DEVICELCTLKEYMASK / NX_DEVICERCTLKEYMASK
        ModifierFamily(flag: 0x0004_0000, keys: [(0x01, 59), (0x2000, 62)]),
    ]

    /// The set of held modifier key codes implied by raw event flags. Pure.
    ///
    /// The device-independent flag says whether a family is held at all and
    /// is authoritative; the device bits say which side. Synthetic events
    /// (remappers, automation) can set the family flag without device bits —
    /// then the previously known side is kept, else the changed key, else
    /// the left key, so the family still reads as held.
    nonisolated static func pressedModifierKeyCodes(
        fromRawFlags flags: UInt64,
        previous: Set<UInt16>,
        changedKeyCode: UInt16?
    ) -> Set<UInt16> {
        var pressed: Set<UInt16> = []
        for family in modifierFamilies where flags & family.flag != 0 {
            let codes = family.keys.map(\.keyCode)
            if family.keys.count == 1 {
                pressed.insert(codes[0])
                continue
            }
            let bySide = family.keys.filter { flags & $0.mask != 0 }.map(\.keyCode)
            if !bySide.isEmpty {
                pressed.formUnion(bySide)
            } else if !previous.isDisjoint(with: codes) {
                pressed.formUnion(previous.intersection(codes))
            } else if let changedKeyCode, codes.contains(changedKeyCode) {
                pressed.insert(changedKeyCode)
            } else {
                pressed.insert(codes[0])
            }
        }
        return pressed
    }

    /// Physical key codes that produce the given modifiers.
    private nonisolated static func keyCodes(for modifiers: ShortcutModifiers) -> Set<UInt16> {
        var codes: Set<UInt16> = []
        if modifiers.contains(.function) { codes.insert(63) }
        if modifiers.contains(.command) { codes.formUnion([54, 55]) }
        if modifiers.contains(.shift) { codes.formUnion([56, 60]) }
        if modifiers.contains(.option) { codes.formUnion([58, 61]) }
        if modifiers.contains(.control) { codes.formUnion([59, 62]) }
        return codes
    }

    private nonisolated static func currentModifiers(state: SharedState) -> ShortcutModifiers {
        var mods = ShortcutModifiers()
        let codes = state.pressedModifierKeyCodes
        if codes.contains(63) { mods.insert(.function) }
        if codes.contains(55) || codes.contains(54) { mods.insert(.command) }
        if codes.contains(56) || codes.contains(60) { mods.insert(.shift) }
        if codes.contains(58) || codes.contains(61) { mods.insert(.option) }
        if codes.contains(59) || codes.contains(62) { mods.insert(.control) }
        return mods
    }
}
