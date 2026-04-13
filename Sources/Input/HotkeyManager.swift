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
    nonisolated(unsafe) var holdBinding: ShortcutBinding = .fnKey
    nonisolated(unsafe) var toggleBinding: ShortcutBinding? = nil
    nonisolated(unsafe) var cancelWatchEnabled = false

    /// Delay before a bare-modifier hold binding (e.g. Fn alone) activates.
    /// Short taps within this window are ignored so macOS can handle its own
    /// Fn behaviors (emoji picker, dictation) without racing our overlay.
    /// Chorded bindings with an explicit keyCode activate immediately.
    nonisolated(unsafe) var holdArmThreshold: TimeInterval = 0.18

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
        var toggleActive = false
    }
    private let stateLock = OSAllocatedUnfairLock<SharedState>(initialState: SharedState())

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private nonisolated(unsafe) var holdArmTimer: DispatchWorkItem?
    private var localFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var accessibilityTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        checkAccessibilityAndInstall()
        scheduleAccessibilityPollIfNeeded()
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
        holdArmTimer?.cancel()
        holdArmTimer = nil
        stateLock.withLock { state in
            state.pressedModifierKeyCodes.removeAll()
            state.pressedKeyCodes.removeAll()
            state.holdActive = false
            state.holdArming = false
            state.toggleActive = false
        }
        isMonitoring = false
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

        logger.info("CGEventTap installed — monitoring for \(self.holdBinding.displayName)")
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

    // MARK: - CGEventTap Handler

    private nonisolated func handleEventTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable the tap if macOS disabled it
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
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
        let keyCode = event.keyCode

        // Log every flagsChanged for debugging
        let isKnown = trackedModifierKeyCodes.contains(keyCode)
        logger.info("flagsChanged: keyCode=\(keyCode) known=\(isKnown) mods=\(event.modifierFlags.rawValue)")

        DispatchQueue.main.async {
            self.eventCount += 1
            self.lastEventDescription = "flags keyCode=\(keyCode)"
        }

        guard isKnown else { return false }

        // Toggle presence: if already pressed → now released, if not pressed → now pressed
        let wasReleased = stateLock.withLock { state -> Bool in
            if state.pressedModifierKeyCodes.contains(keyCode) {
                state.pressedModifierKeyCodes.remove(keyCode)
                return true
            } else {
                state.pressedModifierKeyCodes.insert(keyCode)
                return false
            }
        }
        logger.info("Modifier \(wasReleased ? "released" : "pressed"): keyCode=\(keyCode)")

        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.insert(keyCode)
        }
        // Escape while recording → cancel (consume the event so the focused app doesn't see it).
        if keyCode == 53, cancelWatchEnabled {
            onEvent?(.cancelRequested)
            return true
        }
        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyUp(_ event: NSEvent) {
        let keyCode = event.keyCode
        stateLock.withLock { state in
            _ = state.pressedKeyCodes.remove(keyCode)
        }
        evaluateBindings()
    }

    // MARK: - Binding Evaluation

    /// Check all bindings against current key state and fire events.
    private nonisolated func evaluateBindings() {
        let useThreshold = holdBinding.keyCode == nil && holdArmThreshold > 0

        enum HoldAction { case none, arm, cancelArm }

        let (transitions, holdAction) = stateLock.withLock { state -> ([Event], HoldAction) in
            let holdNowMatches = Self.bindingIsActive(holdBinding, state: state)
            let toggleNowActive = toggleBinding.map { Self.bindingIsActive($0, state: state) } ?? false

            var events: [Event] = []
            var action: HoldAction = .none

            if useThreshold {
                if holdNowMatches {
                    if !state.holdActive && !state.holdArming {
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
            scheduleHoldArmTimer()
        case .cancelArm:
            holdArmTimer?.cancel()
            holdArmTimer = nil
        case .none:
            break
        }

        for event in transitions {
            switch event {
            case .holdActivated: logger.info("Hold activated")
            case .holdDeactivated: logger.info("Hold deactivated")
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
                guard state.holdArming else { return false }
                state.holdArming = false
                // Re-check that the binding is still held when the timer fires.
                guard Self.bindingIsActive(self.holdBinding, state: state) else {
                    return false
                }
                state.holdActive = true
                return true
            }

            if shouldFire {
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
