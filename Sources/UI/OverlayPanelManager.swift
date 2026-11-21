import AppKit
import Combine
import SwiftUI

/// Presents a floating overlay that mirrors the pipeline state.
@MainActor
final class OverlayPanelManager {
    private var panel: NSPanel?
    private var phaseCancellable: AnyCancellable?
    private var warningCancellable: AnyCancellable?
    private var stopHandler: (() -> Void)?
    private var cancelHandler: (() -> Void)?
    private var switchMicHandler: (() -> Void)?
    private var styleProvider: (() -> OverlayStyle)?
    private var currentStyle: OverlayStyle = .standard
    /// Style the hosting view was built for; nil when it needs a rebuild.
    private var hostedStyle: OverlayStyle?
    /// Whether the hosted layout has room for live words.
    private var hostedLive = false
    /// Whether the hosted layout has room for the mic warning.
    private var hostedWarning = false

    /// The overlay itself, including its own padding.
    private static let standardContentSize = CGSize(width: 430, height: 96)
    private static let compactContentSize = CGSize(width: 88, height: 38)
    /// With streaming, the standard overlay grows down by up to two lines
    /// of live words and the compact pill grows sideways.
    private static let standardLiveContentSize = CGSize(width: 430, height: 140)
    private static let compactLiveContentSize = CGSize(width: CompactRecordingOverlay.liveWidth + 12, height: 38)
    /// The standard overlay grows down by one row for the mic warning.
    private static let warningRowHeight: CGFloat = 32

    /// Transparent room around the overlay so its SwiftUI shadow fades out
    /// inside the panel. Without it the window edge cuts the shadow off and
    /// a faint box shows around the pill. Each margin covers its style's
    /// shadow: blur radius plus y offset (RecordingOverlay).
    private static let standardShadowMargin: CGFloat = 30
    private static let compactShadowMargin: CGFloat = 18

    func bind(
        to pipeline: DictationPipeline,
        styleProvider: @escaping () -> OverlayStyle,
        onStop: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSwitchToBuiltInMic: @escaping () -> Void = {}
    ) {
        stopHandler = onStop
        cancelHandler = onCancel
        switchMicHandler = onSwitchToBuiltInMic
        self.styleProvider = styleProvider

        // Build the panel and its SwiftUI view ahead of time, hidden, so the
        // first dictation doesn't pay for it on the way to the screen. One
        // turn later, so it stays off the launch path.
        DispatchQueue.main.async { [weak self, weak pipeline] in
            guard let self, let pipeline, self.panel == nil else { return }
            let style = styleProvider()
            self.currentStyle = style
            self.createPanel(pipeline: pipeline, style: style, live: pipeline.streamsLiveTranscript, warning: false)
        }

        // The mic warning adds a row to a visible overlay: make room.
        warningCancellable = pipeline.$micHealthWarning
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak pipeline] _ in
                guard let self, let pipeline, self.panel?.isVisible == true else { return }
                self.show(pipeline: pipeline)
            }

        // DispatchQueue.main, not RunLoop.main: it runs in every run loop
        // mode, so the overlay also appears while a menu is tracking. The
        // hop lets `pipeline.phase` settle (@Published emits in willSet)
        // before the view reads it.
        phaseCancellable = pipeline.$phase
            .receive(on: DispatchQueue.main)
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
        guard panel?.isVisible == true else { return }
        show(pipeline: pipeline)
    }

    private func show(pipeline: DictationPipeline) {
        let style = styleProvider?() ?? .standard
        let live = pipeline.streamsLiveTranscript
        let warning = style == .standard && pipeline.micHealthWarning != nil
        currentStyle = style

        if panel == nil {
            createPanel(pipeline: pipeline, style: style, live: live, warning: warning)
        }
        guard let panel else { return }
        let wasVisible = panel.isVisible

        // Keep one hosting view for a whole dictation; SwiftUI follows the
        // phase on its own. Rebuild only for a new style or a fresh
        // appearance, so a hidden panel never flashes its last frame.
        if hostedStyle != style || hostedLive != live || hostedWarning != warning || !wasVisible {
            resizePanel(for: style, live: live, warning: warning)
            panel.contentView = NSHostingView(rootView: rootView(pipeline: pipeline, style: style, live: live, warning: warning))
            hostedStyle = style
            hostedLive = live
            hostedWarning = warning
        }

        positionPanel(for: style, live: live, warning: warning)
        panel.orderFrontRegardless()
        if !wasVisible {
            StartLatencyTrace.mark("overlay ordered front")
        }
    }

    #if DEBUG
    /// The overlay panel, for render tests.
    var panelForTesting: NSPanel? { panel }
    #endif

    private func hide() {
        panel?.orderOut(nil)
    }

    private func rootView(pipeline: DictationPipeline, style: OverlayStyle, live: Bool, warning: Bool) -> some View {
        let size = Self.contentSize(for: style, live: live, warning: warning)
        // Live words and the mic warning grow the standard overlay
        // downward, so it is pinned to the top of its slot instead of
        // centred in it.
        let height: CGFloat? = style == .compact || live || warning ? size.height : nil
        return RecordingOverlay(
            pipeline: pipeline,
            style: style,
            onStop: { [weak self] in self?.stopHandler?() },
            onCancel: { [weak self] in self?.cancelHandler?() },
            onSwitchToBuiltInMic: { [weak self] in self?.switchMicHandler?() }
        )
        .frame(width: size.width, height: height, alignment: style == .standard ? .top : .center)
        .padding(Self.shadowMargin(for: style))
    }

    private func createPanel(pipeline: DictationPipeline, style: OverlayStyle, live: Bool, warning: Bool) {
        let size = Self.size(for: style, live: live, warning: warning)
        let hostingView = NSHostingView(rootView: rootView(pipeline: pipeline, style: style, live: live, warning: warning))

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
        hostedStyle = style
        hostedLive = live
        hostedWarning = warning
    }

    private func resizePanel(for style: OverlayStyle, live: Bool, warning: Bool) {
        guard let panel else { return }
        let size = Self.size(for: style, live: live, warning: warning)
        var frame = panel.frame
        frame.size = size
        panel.setFrame(frame, display: false)
        panel.ignoresMouseEvents = style == .compact
    }

    private func positionPanel(for style: OverlayStyle, live: Bool, warning: Bool) {
        guard let panel, let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        // Place the overlay itself where it always was; the shadow margin
        // hangs outside that spot.
        let margin = Self.shadowMargin(for: style)
        let contentHeight = Self.contentSize(for: style, live: live, warning: warning).height
        let x = visibleFrame.midX - (panelSize.width / 2)
        let y: CGFloat
        switch style {
        case .standard:
            y = visibleFrame.maxY - contentHeight - 18 - margin
        case .compact:
            y = visibleFrame.minY + 24 - margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private static func contentSize(for style: OverlayStyle, live: Bool, warning: Bool = false) -> CGSize {
        switch style {
        case .standard:
            var size = live ? standardLiveContentSize : standardContentSize
            if warning { size.height += warningRowHeight }
            return size
        case .compact: return live ? compactLiveContentSize : compactContentSize
        }
    }

    private static func shadowMargin(for style: OverlayStyle) -> CGFloat {
        switch style {
        case .standard: return standardShadowMargin
        case .compact: return compactShadowMargin
        }
    }

    /// The panel: the overlay plus its shadow margin on every side.
    private static func size(for style: OverlayStyle, live: Bool, warning: Bool) -> CGSize {
        let content = contentSize(for: style, live: live, warning: warning)
        let margin = shadowMargin(for: style)
        return CGSize(width: content.width + 2 * margin, height: content.height + 2 * margin)
    }
}
