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

    @Published private(set) var isAccessibilityGranted = false
    @Published private(set) var isMonitoring = false
    @Published private(set) var eventCount = 0
    @Published private(set) var lastEventDescription = ""

    // Tracked key state
    private nonisolated(unsafe) var pressedModifierKeyCodes: Set<UInt16> = []
    private nonisolated(unsafe) var pressedKeyCodes: Set<UInt16> = []
    private nonisolated(unsafe) var holdActive = false
    private nonisolated(unsafe) var toggleActive = false

    private nonisolated(unsafe) var eventTap: CFMachPort?
    private nonisolated(unsafe) var runLoopSource: CFRunLoopSource?
    private var localFlagsMonitor: Any?
    private var localKeyDownMonitor: Any?
    private var localKeyUpMonitor: Any?
    private var accessibilityTimer: Timer?

    // MARK: - Lifecycle

    func start() {
        checkAccessibilityAndInstall()

        // Poll for accessibility changes every 2 seconds
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibilityAndInstall()
            }
        }
    }

    func stop() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        teardownEventTap()
        teardownLocalMonitors()
        pressedModifierKeyCodes.removeAll()
        pressedKeyCodes.removeAll()
        holdActive = false
        toggleActive = false
        isMonitoring = false
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
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
        if pressedModifierKeyCodes.contains(keyCode) {
            pressedModifierKeyCodes.remove(keyCode)
            logger.info("Modifier released: keyCode=\(keyCode)")
        } else {
            pressedModifierKeyCodes.insert(keyCode)
            logger.info("Modifier pressed: keyCode=\(keyCode)")
        }

        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyDown(_ event: NSEvent) -> Bool {
        pressedKeyCodes.insert(event.keyCode)
        // Escape while recording → cancel (consume the event so the focused app doesn't see it).
        if event.keyCode == 53, cancelWatchEnabled {
            onEvent?(.cancelRequested)
            return true
        }
        evaluateBindings()
        return false
    }

    private nonisolated func handleKeyUp(_ event: NSEvent) {
        pressedKeyCodes.remove(event.keyCode)
        evaluateBindings()
    }

    // MARK: - Binding Evaluation

    /// Check all bindings against current key state and fire events.
    private nonisolated func evaluateBindings() {
        let holdNowActive = bindingIsActive(holdBinding)
        let toggleNowActive = toggleBinding.map { bindingIsActive($0) } ?? false

        // Hold binding transitions
        if holdNowActive && !holdActive {
            holdActive = true
            logger.info("Hold activated (Fn pressed)")
            onEvent?(.holdActivated)
        } else if !holdNowActive && holdActive {
            holdActive = false
            logger.info("Hold deactivated (Fn released)")
            onEvent?(.holdDeactivated)
        }

        // Toggle binding transitions
        if toggleNowActive && !toggleActive {
            toggleActive = true
            onEvent?(.toggleActivated)
        }
        if !toggleNowActive && toggleActive {
            toggleActive = false
            onEvent?(.toggleDeactivated)
        }
    }

    /// Check if a binding matches the current pressed key state.
    private nonisolated func bindingIsActive(_ binding: ShortcutBinding) -> Bool {
        // Check if all required modifiers are pressed
        let activeModifiers = currentModifiers()
        guard activeModifiers.isSuperset(of: binding.modifiers) else {
            return false
        }

        // For modifier-only bindings (like Fn), just checking modifiers is enough
        if binding.keyCode == nil {
            return true
        }

        // For key + modifier bindings, also check the key
        if let keyCode = binding.keyCode {
            return pressedKeyCodes.contains(keyCode)
        }

        return false
    }

    /// Convert pressed modifier keyCodes to ShortcutModifiers.
    private nonisolated func currentModifiers() -> ShortcutModifiers {
        var mods = ShortcutModifiers()
        if pressedModifierKeyCodes.contains(63) { mods.insert(.function) }
        if pressedModifierKeyCodes.contains(55) || pressedModifierKeyCodes.contains(54) { mods.insert(.command) }
        if pressedModifierKeyCodes.contains(56) || pressedModifierKeyCodes.contains(60) { mods.insert(.shift) }
        if pressedModifierKeyCodes.contains(58) || pressedModifierKeyCodes.contains(61) { mods.insert(.option) }
        if pressedModifierKeyCodes.contains(59) || pressedModifierKeyCodes.contains(62) { mods.insert(.control) }
        return mods
    }
}
