import AppKit
import QuartzCore

/// Flies a copy of the tile from the click in Whispur's window to its slot in
/// the guide, so the eye follows it to System Settings. The tile lifts out
/// first and hovers until System Settings shows its window; if it never
/// does, the flight gives up.
@MainActor
final class PermissionGuideFlight {
    static let padding: CGFloat = 40
    static let lift: CFTimeInterval = 0.18
    static let duration: CFTimeInterval = 0.62
    /// System Settings that has not opened by then gets no flight.
    static let patience: CFTimeInterval = 4

    private let panel: NSPanel
    private let layer = CALayer()
    private let origin: CGPoint
    private let target: () -> CGPoint
    private let onProgress: (CGFloat) -> Void
    private let onEnd: () -> Void
    private var timer: Timer?
    private let shownAt = CACurrentMediaTime()
    private var startedAt: CFTimeInterval?

    /// - Parameters:
    ///   - origin: where the click was, in screen coordinates.
    ///   - target: the tile's slot centre in the guide, in screen coordinates.
    ///   - onProgress: the flight's 0...1 progress once it is under way, to
    ///     fade the guide in as the tile arrives.
    init(image: NSImage, origin: CGPoint, target: @escaping () -> CGPoint, onProgress: @escaping (CGFloat) -> Void, onEnd: @escaping () -> Void) {
        self.origin = origin
        self.target = target
        self.onProgress = onProgress
        self.onEnd = onEnd

        let tileSize = image.size
        let size = CGSize(width: tileSize.width + 2 * Self.padding, height: tileSize.height + 2 * Self.padding)
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let host = NSView(frame: CGRect(origin: .zero, size: size))
        host.layer = CALayer()
        host.wantsLayer = true
        host.layerUsesCoreImageFilters = true
        layer.bounds = CGRect(origin: .zero, size: tileSize)
        layer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        layer.contents = image
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.shadowColor = NSColor(sophiieHex: 0x140934).cgColor
        layer.shadowOpacity = 0.3
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: -6)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.name = "blur"
            blur.setValue(0, forKey: kCIInputRadiusKey)
            layer.filters = [blur]
        }
        host.layer?.addSublayer(layer)
        panel.contentView = host
    }

    func begin() {
        place(center: origin, scale: 0.7, blur: 4, opacity: 0)
        panel.orderFrontRegardless()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// System Settings is up and the guide is docked: fly.
    func launch() {
        if startedAt == nil { startedAt = CACurrentMediaTime() }
    }

    var isLaunched: Bool { startedAt != nil }

    func end() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
        onEnd()
    }

    private func step() {
        let now = CACurrentMediaTime()
        guard let startedAt else {
            // Lifted out of the row, waiting for System Settings to open.
            if now - shownAt > Self.patience {
                end()
                return
            }
            let t = Self.easeOutCubic(Self.clamp01((now - shownAt) / Self.lift))
            place(center: CGPoint(x: origin.x, y: origin.y + 12 * t), scale: 0.7 + 0.1 * t, blur: 4 * (1 - t), opacity: t)
            return
        }
        let t = Self.clamp01((now - startedAt) / Self.duration)
        let e = Self.easeInOutCubic(t)
        let start = CGPoint(x: origin.x, y: origin.y + 12)
        let point = Self.arcPoint(from: start, to: target(), progress: e)
        place(center: point, scale: 0.8 + 0.2 * e, blur: 6 * sin(.pi * e), opacity: 1)
        onProgress(t)
        if t >= 1 { end() }
    }

    private func place(center: CGPoint, scale: CGFloat, blur: CGFloat, opacity: CGFloat) {
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(scale, scale, 1)
        layer.opacity = Float(opacity)
        layer.setValue(blur, forKeyPath: "filters.blur.inputRadius")
        CATransaction.commit()
    }

    // MARK: - Curves

    nonisolated static func clamp01(_ value: CGFloat) -> CGFloat { min(max(value, 0), 1) }

    nonisolated static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    nonisolated static func easeOutCubic(_ t: CGFloat) -> CGFloat { 1 - pow(1 - t, 3) }

    /// A point on the quadratic arc from `start` to `end`, bowing upwards by
    /// a quarter of the distance (at most 160 pt).
    nonisolated static func arcPoint(from start: CGPoint, to end: CGPoint, progress e: CGFloat) -> CGPoint {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let control = CGPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + min(160, distance * 0.25))
        let u = 1 - e
        return CGPoint(
            x: u * u * start.x + 2 * u * e * control.x + e * e * end.x,
            y: u * u * start.y + 2 * u * e * control.y + e * e * end.y
        )
    }
}
