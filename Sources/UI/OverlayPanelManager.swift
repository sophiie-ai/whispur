import AppKit
import Combine
import SwiftUI

/// Presents a floating overlay that mirrors the pipeline state.
@MainActor
final class OverlayPanelManager {
    private var panel: NSPanel?
    private var phaseCancellable: AnyCancellable?
    private var stopHandler: (() -> Void)?

    func bind(to pipeline: DictationPipeline, onStop: @escaping () -> Void) {
        stopHandler = onStop

        phaseCancellable = pipeline.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let self else { return }

                switch phase {
                case .idle:
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

    private func show(pipeline: DictationPipeline) {
        if panel == nil {
            createPanel(pipeline: pipeline)
        }

        positionPanel()
        panel?.contentView = NSHostingView(
            rootView: RecordingOverlay(
                pipeline: pipeline,
                onStop: { [weak self] in self?.stopHandler?() }
            )
            .frame(width: 430)
        )
        panel?.orderFrontRegardless()
    }

    private func hide() {
        panel?.orderOut(nil)
    }

    private func createPanel(pipeline: DictationPipeline) {
        let hostingView = NSHostingView(
            rootView: RecordingOverlay(
                pipeline: pipeline,
                onStop: { [weak self] in self?.stopHandler?() }
            )
            .frame(width: 430)
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 96),
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
        panel.isMovableByWindowBackground = false
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }

        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let x = visibleFrame.midX - (panelSize.width / 2)
        let y = visibleFrame.maxY - panelSize.height - 18
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
