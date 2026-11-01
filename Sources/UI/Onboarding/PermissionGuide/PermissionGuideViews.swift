import AppKit
import SwiftUI

/// The app as System Settings lists it: icon and name. Shown in the guide as
/// the drag handle, and flown from Whispur's window to the guide.
struct PermissionGuideTile: View {
    let icon: NSImage
    let appName: String

    static let size = CGSize(width: 404, height: 48)

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)
            Text(appName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SophiieTheme.Palette.OnDark.ink)
            Spacer(minLength: 8)
            Image(systemName: "hand.draw")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SophiieTheme.Palette.OnDark.accent)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            SophiieTheme.Palette.OnDark.raised,
            in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                .strokeBorder(SophiieTheme.Palette.OnDark.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(appName). Drag into the System Settings list.")
    }
}

/// The guide's content: a midnight HUD with the instruction, the list it
/// refers to, and (for draggable permissions) the tile.
struct PermissionGuideContent: View {
    let permission: GuidedPermission
    let appName: String
    /// The drag tile slot. The panel puts an AppKit drag source here; the
    /// render test passes the plain tile.
    let tile: AnyView?
    let onClose: () -> Void

    static let width: CGFloat = 440

    static func height(for permission: GuidedPermission) -> CGFloat {
        permission.isDraggable ? 132 : 76
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(SophiieTheme.Palette.OnDark.onAccent)
                    .frame(width: 24, height: 24)
                    .background(SophiieTheme.Palette.OnDark.accent, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.instruction(appName: appName))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SophiieTheme.Palette.OnDark.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Privacy & Security › \(permission.listName)")
                        .font(.system(size: 11))
                        .foregroundStyle(SophiieTheme.Palette.OnDark.muted)
                }
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(SophiieTheme.Palette.OnDark.inkSecondary)
                        .frame(width: 20, height: 20)
                        .background(SophiieTheme.Palette.OnDark.raised, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close guide")
            }
            if let tile {
                tile.frame(width: PermissionGuideTile.size.width, height: PermissionGuideTile.size.height)
            }
        }
        .padding(18)
        .frame(width: Self.width, height: Self.height(for: permission), alignment: .topLeading)
        .background(
            SophiieTheme.Palette.OnDark.background,
            in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.overlay, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.overlay, style: .continuous)
                .strokeBorder(SophiieTheme.Palette.OnDark.hairline, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }
}

/// Hosting view that takes the first click even while Whispur is in the
/// background, so the close button works beside System Settings.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The drag source: the tile, which drags the `.app` bundle URL so it can be
/// dropped straight into the System Settings list.
final class PermissionGuideDragView: NSView, NSDraggingSource {
    let bundleURL: URL
    private var mouseDownEvent: NSEvent?
    private let host: NSHostingView<PermissionGuideTile>

    init(bundleURL: URL, icon: NSImage, appName: String) {
        self.bundleURL = bundleURL
        host = NSHostingView(rootView: PermissionGuideTile(icon: icon, appName: appName))
        super.init(frame: CGRect(origin: .zero, size: PermissionGuideTile.size))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(appName). Drag into the System Settings list.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { PermissionGuideTile.size }

    /// The whole tile is the drag handle; the hosted SwiftUI view only draws.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) >= 3 else { return }

        let item = NSDraggingItem(pasteboardWriter: bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: snapshot())
        let session = beginDraggingSession(with: [item], event: start, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    /// The tile as an image, for the drag and the flight.
    func snapshot() -> NSImage {
        layoutSubtreeIfNeeded()
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return NSImage(size: bounds.size) }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// A SwiftUI slot that holds an existing AppKit view.
struct HostedNSView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
