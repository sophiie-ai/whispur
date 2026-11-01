import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// The floating "drag to allow" guide beside System Settings' Privacy &
/// Security pane. It opens the pane for one permission, docks a small
/// midnight panel beside the System Settings window (following it across
/// moves, resizes and displays), offers Whispur as a drag tile, and closes
/// itself once the permission is granted or System Settings closes.
@MainActor
final class PermissionGuideController: ObservableObject {
    /// The permission the guide is showing, nil while closed.
    @Published private(set) var activePermission: GuidedPermission?

    /// How often the guide follows the System Settings window.
    static let tickInterval: TimeInterval = 0.1
    /// The microphone status read costs ~10-20 ms, so it is checked on every
    /// third tick only; the Accessibility check is cheap.
    static let microphoneCheckEvery = 3

    private var machine = PermissionGuideMachine()
    private let opener: SystemSettingsOpener
    private let isGranted: (GuidedPermission) -> Bool
    private var panel: NSPanel?
    private var dragView: PermissionGuideDragView?
    private var flight: PermissionGuideFlight?
    private var timer: Timer?
    private var ticks = 0
    private var onFinish: ((PermissionGuideOutcome) -> Void)?

    init(
        opener: SystemSettingsOpener? = nil,
        isGranted: @escaping (GuidedPermission) -> Bool = PermissionGuideController.liveGrant
    ) {
        self.opener = opener ?? SystemSettingsOpener()
        self.isGranted = isGranted
    }

    /// What System Settings shows now. The microphone status follows the
    /// switch live; `AXIsProcessTrusted` does too.
    nonisolated static func liveGrant(_ permission: GuidedPermission) -> Bool {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted()
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    /// Opens System Settings at `permission`'s list with the guide beside it.
    /// `onFinish` runs once, when the guide closes for any reason. An
    /// already-granted permission gets no guide: `onFinish(.granted)` runs
    /// straight away.
    func show(_ permission: GuidedPermission, onFinish: @escaping (PermissionGuideOutcome) -> Void) {
        let click = NSEvent.mouseLocation
        let fly = clickIsInAppWindow(click) && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        finish(.cancelled)

        guard !isGranted(permission) else {
            onFinish(.granted)
            return
        }

        self.onFinish = onFinish
        activePermission = permission
        ticks = 0
        machine.start(now: CACurrentMediaTime())
        opener.open(permission.settingsURL)

        // A development binary has no bundle to list, so it gets the pane
        // alone; the grant is still watched so Whispur comes back to front.
        if let bundleURL = PermissionGuideApp.bundleURL() {
            buildPanel(for: permission, bundleURL: bundleURL)
            if fly, permission.isDraggable { beginFlight(from: click) }
        }

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Closes the guide without a grant (the panel's close button).
    func cancel() {
        finish(.cancelled)
    }

    #if DEBUG
    /// A fixed "guide is open" state for renders in tests.
    func setActivePermissionForRendering(_ permission: GuidedPermission?) {
        activePermission = permission
    }
    #endif

    // MARK: - Tick

    private func tick() {
        guard let permission = activePermission else { return }
        ticks += 1
        let checkGrant = permission == .accessibility || ticks % Self.microphoneCheckEvery == 1
        let granted = checkGrant && isGranted(permission)
        let frame = SystemSettingsOpener.settingsWindowFrame()
        switch machine.tick(now: CACurrentMediaTime(), granted: granted, settingsFrame: frame) {
        case .none:
            break
        case .dock(let settings):
            dock(beside: settings)
        case .finish(let outcome):
            finish(outcome)
        }
    }

    private func dock(beside settings: CGRect) {
        guard let panel else { return }
        let screens = NSScreen.screens
        let index = SettingsWindowGeometry.screenIndex(for: settings, screenFrames: screens.map(\.frame))
        let visible = index.map { screens[$0].visibleFrame } ?? NSScreen.main?.visibleFrame ?? settings
        let origin = SettingsWindowGeometry.guideOrigin(settings: settings, guideSize: panel.frame.size, visible: visible)
        if panel.frame.origin != origin { panel.setFrameOrigin(origin) }
        if !panel.isVisible { panel.orderFrontRegardless() }
        flight?.launch()
    }

    private func finish(_ outcome: PermissionGuideOutcome) {
        guard activePermission != nil else { return }
        if case .finished = machine.phase {} else { machine.cancel() }
        timer?.invalidate()
        timer = nil
        flight?.end()
        flight = nil
        panel?.orderOut(nil)
        panel = nil
        dragView = nil
        activePermission = nil
        if outcome != .granted { opener.invalidate() }
        let callback = onFinish
        onFinish = nil
        callback?(outcome)
    }

    // MARK: - Panel

    private func buildPanel(for permission: GuidedPermission, bundleURL: URL) {
        let appName = PermissionGuideApp.displayName(for: bundleURL)
        let size = CGSize(width: PermissionGuideContent.width, height: PermissionGuideContent.height(for: permission))
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.title = "Whispur permission guide"

        let container = NSView(frame: CGRect(origin: .zero, size: size))
        let content = PermissionGuideContent(
            permission: permission,
            appName: appName,
            tile: permission.isDraggable ? AnyView(Color.clear) : nil,
            onClose: { [weak self] in self?.cancel() }
        )
        let host = FirstMouseHostingView(rootView: content)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        if permission.isDraggable {
            let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
            icon.size = CGSize(width: 32, height: 32)
            let drag = PermissionGuideDragView(bundleURL: bundleURL, icon: icon, appName: appName)
            // The content's 18 pt padding puts the tile slot at the bottom left.
            drag.frame = CGRect(x: 18, y: 18, width: PermissionGuideTile.size.width, height: PermissionGuideTile.size.height)
            container.addSubview(drag)
            dragView = drag
        }
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        self.panel = panel
    }

    // MARK: - Flight

    /// The click that asked for the guide, when it was in one of Whispur's
    /// own windows (the onboarding window, Settings, the menu bar panel).
    private func clickIsInAppWindow(_ point: CGPoint) -> Bool {
        NSApp.windows.contains { window in
            window.isVisible && window !== panel && window.frame.contains(point)
        }
    }

    private func beginFlight(from click: CGPoint) {
        guard let panel, let dragView else { return }
        let image = dragView.snapshot()
        dragView.isHidden = true
        panel.alphaValue = 0
        let flight = PermissionGuideFlight(
            image: image,
            origin: click,
            target: { [weak panel, weak dragView] in
                guard let panel, let dragView else { return click }
                let slot = panel.convertToScreen(dragView.convert(dragView.bounds, to: nil))
                return CGPoint(x: slot.midX, y: slot.midY)
            },
            onProgress: { [weak panel] t in
                panel?.alphaValue = PermissionGuideFlight.easeOutCubic(PermissionGuideFlight.clamp01((t - 0.45) / 0.55))
            },
            onEnd: { [weak panel, weak dragView, weak self] in
                dragView?.isHidden = false
                panel?.alphaValue = 1
                self?.flight = nil
            }
        )
        flight.begin()
        self.flight = flight
    }
}
