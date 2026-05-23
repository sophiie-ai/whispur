import AppKit
import Combine
import SwiftUI

/// Presents a floating overlay that mirrors the pipeline state.
@MainActor
final class OverlayPanelManager {
    private var panel: NSPanel?
    private var phaseCancellable: AnyCancellable?
    private var stopHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var styleProvider: (() -> OverlayStyle)?
    private var currentStyle: OverlayStyle = .standard

    private static let standardSize = CGSize(width: 430, height: 96)
    private static let compactSize = CGSize(width: 88, height: 38)

    func bind(
        to pipeline: DictationPipeline,
        styleProvider: @escaping () -> OverlayStyle,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        stopHandler = onStop
        cancelHandler = onCancel
        self.styleProvider = styleProvider

        phaseCancellable = pipeline.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }

                // Compact mode skips the success confirmation: the moment
                // dictation completes, the pill disappears so the user is
                // not left looking at an empty black shell while the
                // pipeline settles back to .idle.
                let style = self.styleProvider?() ?? .standard

                switch phase {
                case .idle:
                    self.hide()
                case .done where style == .compact:
                    self.hide()
                case .requestingMicrophonePermission,
                        .starting,
                        .recording,
                        .normalizingAudio,
                        .transcribing,
                        .cleaningTranscript,
                        .pasting,
                        .done,
                        .error:
                    self.show(pipeline: pipeline)
                }
            }
    }

    /// Force the panel to refresh with the latest style. Useful when the
    /// user flips the setting while an overlay is on screen.
    func refreshStyle(pipeline: DictationPipeline) {
        guard panel != nil else { return }
        show(pipeline: pipeline)
    }

    private func show(pipeline: DictationPipeline) {
        let style = styleProvider?() ?? .standard
        currentStyle = style

        if panel == nil {
            createPanel(pipeline: pipeline, style: style)
        } else {
            resizePanel(for: style)
        }

        positionPanel(for: style)
        panel?.contentView = NSHostingView(rootView: rootView(pipeline: pipeline, style: style))
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func rootView(pipeline: DictationPipeline, style: OverlayStyle) -> some View {
        let size = Self.size(for: style)
        return RecordingOverlay(
            pipeline: pipeline,
            style: style,
            onStop: { [weak self] in self?.stopHandler?() },
            onCancel: { [weak self] in self?.cancelHandler?() }
        )
        .frame(width: size.width, height: style == .compact ? size.height : nil)
    }

    private func createPanel(pipeline: DictationPipeline, style: OverlayStyle) {
        let size = Self.size(for: style)
        let hostingView = NSHostingView(rootView: rootView(pipeline: pipeline, style: style))

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
        panel.ignoresMouseEvents = style == .compact
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView

        self.panel = panel
    }

    private func resizePanel(for style: OverlayStyle) {
        guard let panel else { return }
        let size = Self.size(for: style)
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: false)
        panel.ignoresMouseEvents = style == .compact
    }

    private func positionPanel(for style: OverlayStyle) {
        guard let panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = visibleFrame.midX - (panelSize.width / 2)
        let y: CGFloat
        switch style {
        case .standard:
            y = visibleFrame.maxY - panelSize.height - 18
        case .compact:
            y = visibleFrame.minY + 24
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func size(for style: OverlayStyle) -> CGSize {
        switch style {
        case .standard: return standardSize
        case .compact: return compactSize
        }
    }
}
