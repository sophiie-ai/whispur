import AppKit
import Combine
import SwiftUI

/// The small "Cleaned up · Use raw ⌥⌘Z" toast shown after a cleaned paste.
/// A non-activating panel, so clicking it never takes focus from the app the
/// text went into.
@MainActor
final class UseRawToastPanelManager {
    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var styleProvider: () -> OverlayStyle = { .standard }

    static let contentSize = CGSize(width: 268, height: 34)
    /// Room for the toast's shadow inside the panel (see OverlayPanelManager).
    static let shadowMargin: CGFloat = 20

    func bind(to controller: UseRawController, styleProvider: @escaping () -> OverlayStyle) {
        self.styleProvider = styleProvider
        cancellable = controller.$visibleOffer
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak controller] offer in
                guard let self, let controller else { return }
                if offer == nil {
                    self.panel?.orderOut(nil)
                } else {
                    self.show(controller: controller)
                }
            }
    }

    #if DEBUG
    var panelForTesting: NSPanel? { panel }
    #endif

    private func show(controller: UseRawController) {
        if panel == nil {
            let size = CGSize(
                width: Self.contentSize.width + 2 * Self.shadowMargin,
                height: Self.contentSize.height + 2 * Self.shadowMargin
            )
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.becomesKeyOnlyIfNeeded = true
            panel.contentView = NSHostingView(rootView: UseRawToast(onUseRaw: { [weak controller] in controller?.trigger() })
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                .padding(Self.shadowMargin))
            self.panel = panel
        }
        position()
        panel?.orderFrontRegardless()
    }

    /// Next to where the recording overlay sits: under the standard overlay
    /// at the top of the screen, or in place of the compact pill at the
    /// bottom (the pill is already gone by the time the toast shows).
    private func position() {
        guard let panel, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y: CGFloat
        switch styleProvider() {
        case .standard:
            y = visible.maxY - 18 - 96 - Self.contentSize.height - Self.shadowMargin
        case .compact:
            y = visible.minY + 24 - Self.shadowMargin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct UseRawToast: View {
    private typealias OnDark = SophiieTheme.Palette.OnDark

    let onUseRaw: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(OnDark.accent)
                .accessibilityHidden(true)
            Text("Cleaned up")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnDark.inkSecondary)
            Text("·")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OnDark.muted)
                .accessibilityHidden(true)
            Button(action: onUseRaw) {
                HStack(spacing: 7) {
                    Text("Use raw")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(OnDark.accent)
                    Text("⌥⌘Z")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(OnDark.inkSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(OnDark.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Replace the pasted text with exactly what you said")
            .accessibilityLabel("Use raw transcript")
            .accessibilityHint("Replaces the cleaned text with what you said. Shortcut: Option Command Z")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OnDark.background.opacity(0.97), in: Capsule())
        .overlay(Capsule().inset(by: 0.5).strokeBorder(OnDark.hairline, lineWidth: 1))
        .shadow(color: SophiieTheme.Shadow.tint.opacity(0.28), radius: 9, y: 4)
    }
}
