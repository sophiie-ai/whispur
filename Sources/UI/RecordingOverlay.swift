import SwiftUI

/// Visual treatment of the recording overlay panel. `standard` keeps the
/// top-centered status overlay with controls; `compact` is a minimal
/// bottom-centered pill with waveform-only feedback.
enum OverlayStyle: String, CaseIterable, Identifiable {
    case standard
    case compact

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .compact: return "Compact"
        }
    }
}

struct RecordingOverlay: View {
    private typealias OnDark = SophiieTheme.Palette.OnDark

    @ObservedObject var pipeline: DictationPipeline
    var style: OverlayStyle = .standard
    let onStop: () -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch style {
        case .standard:
            standardBody
        case .compact:
            CompactRecordingOverlay(pipeline: pipeline)
                .padding(6)
        }
    }

    private var standardBody: some View {
        Group {
            switch pipeline.phase {
            case .idle:
                EmptyView()
            case .requestingMicrophonePermission:
                overlayShell {
                    statusRow(
                        title: "Microphone Access",
                        detail: pipeline.statusDetail,
                        leading: AnyView(ActivityDotsView(color: OnDark.warning))
                    )
                }
            case .starting:
                overlayShell {
                    statusRow(
                        title: "Preparing",
                        detail: pipeline.statusDetail,
                        leading: AnyView(ActivityDotsView(color: OnDark.ink))
                    )
                }
            case .recording:
                overlayShell {
                    VStack(alignment: .leading, spacing: 10) {
                        recordingRow
                        if pipeline.streamsLiveTranscript, !pipeline.liveTranscript.isEmpty {
                            LiveTranscriptText(
                                text: pipeline.liveTranscript,
                                budget: LiveTranscriptTail.standardBudget,
                                lineLimit: 2,
                                font: .system(size: 12.5),
                                color: OnDark.inkSecondary
                            )
                            .transition(.opacity)
                        }
                    }
                    .sophiieAnimation(value: pipeline.liveTranscript.isEmpty)
                }
            case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
                overlayShell {
                    HStack(spacing: 12) {
                        statusRow(
                            title: pipeline.statusTitle,
                            detail: pipeline.statusDetail,
                            leading: AnyView(ActivityDotsView(color: OnDark.accent))
                        )

                        cancelButton
                    }
                }
            case .done(let text):
                overlayShell {
                    statusRow(
                        title: "Inserted",
                        detail: text,
                        leading: AnyView(
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(OnDark.success)
                                .font(.title3)
                        )
                    )
                }
            case .error(let message):
                overlayShell {
                    statusRow(
                        title: "Couldn’t Finish",
                        detail: message,
                        leading: AnyView(
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(OnDark.warning)
                                .font(.title3)
                        )
                    )
                }
            }
        }
        .padding(10)
    }

    private var recordingRow: some View {
        let silence = pipeline.isHearingSilence
        let isHold = pipeline.activeTriggerMode == .hold
        let indicator = silence ? OnDark.warning : OnDark.accent
        let isSpeaking = pipeline.audioLevel > 0.04
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(indicator.opacity(0.22))
                    .frame(width: 24, height: 24)
                    .scaleEffect(reduceMotion ? 1 : (isSpeaking ? 1.16 : 0.94))
                    .sophiieAnimation(0.14, value: isSpeaking)

                Circle()
                    .fill(indicator)
                    .frame(width: 9, height: 9)
            }

            Text(silence
                ? "No audio"
                : (isHold ? "Listening" : "Recording"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(OnDark.ink)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            CompactWaveformView(samples: pipeline.audioSamples, silence: silence)
                .opacity(silence ? 0.45 : 1)
                .sophiieAnimation(value: silence)

            cancelButton

            if !isHold {
                Button(action: onStop) {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.sophiiePrimaryOnDark)
                .controlSize(.small)
                .transition(.opacity)
            }
        }
        .sophiieAnimation(value: pipeline.activeTriggerMode)
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(OnDark.ink)
                .frame(width: 22, height: 22)
                .background(Circle().fill(OnDark.raised))
        }
        .buttonStyle(.plain)
        .help("Cancel (esc)")
        .accessibilityLabel("Cancel")
    }

    private func statusRow(title: String, detail: String?, leading: AnyView) -> some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(OnDark.ink)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(OnDark.inkSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)
        }
    }

    private func overlayShell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                OnDark.background.opacity(0.97),
                in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.overlay, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.overlay, style: .continuous)
                    .strokeBorder(OnDark.hairline, lineWidth: 1)
            )
            .shadow(color: SophiieTheme.Shadow.tint.opacity(0.28), radius: 18, y: 10)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
            .sophiieAnimation(SophiieTheme.Motion.medium, value: pipeline.phase)
    }
}

/// The end of the live transcript, cut at a word so the newest words
/// always show. Pure, for tests.
enum LiveTranscriptTail {
    /// About two lines of the standard overlay.
    static let standardBudget = 110
    /// One line beside the compact pill's waveform.
    static let compactBudget = 30

    static func tail(_ text: String, budget: Int) -> (text: String, truncated: Bool) {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        let joined = words.joined(separator: " ")
        guard joined.count > budget, budget > 0 else { return (joined, false) }
        var kept: [Substring] = []
        var length = 0
        for word in words.reversed() {
            let added = kept.isEmpty ? word.count : word.count + 1
            if length + added > budget { break }
            kept.append(word)
            length += added
        }
        // A single word longer than the budget: keep its end.
        if kept.isEmpty, let last = words.last {
            return (String(last.suffix(budget)), true)
        }
        return (kept.reversed().joined(separator: " "), true)
    }
}

/// Live words, newest at the end. When older words were cut, the start of
/// the first line fades out so the cut reads as "and before that".
struct LiveTranscriptText: View {
    let text: String
    let budget: Int
    let lineLimit: Int
    let font: Font
    let color: Color

    var body: some View {
        let tail = LiveTranscriptTail.tail(text, budget: budget)
        Text(tail.text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(lineLimit)
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .mask(alignment: .topLeading) {
                if tail.truncated {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.black.opacity(0.1), .black],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 64)
                            Color.black
                        }
                        .frame(height: 18)
                        Color.black
                    }
                } else {
                    Color.black
                }
            }
            .accessibilityLabel("Live transcript")
            .accessibilityValue(text)
    }
}

private struct CompactWaveformView: View {
    let samples: [Float]
    var silence: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // One shading reused across all capsules: the prior ForEach built a new
    // LinearGradient per bar per frame (~1.3k gradients/sec during
    // recording). Canvas draws ~30x faster and keeps CPU cool.
    // Sky at the edges fading to white at the centre line.
    private static let fillShading = GraphicsContext.Shading.linearGradient(
        Gradient(colors: [
            SophiieTheme.Palette.sky,
            .white.opacity(0.95),
            SophiieTheme.Palette.sky
        ]),
        startPoint: CGPoint(x: 0, y: 0),
        endPoint: CGPoint(x: 0, y: 26)
    )
    private static let silenceShading = GraphicsContext.Shading.color(SophiieTheme.Palette.OnDark.warning)

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let count = samples.count
            guard count > 0 else { return }
            let barWidth: CGFloat = 2
            let spacing: CGFloat = 2
            let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
            var x = max(0, (size.width - totalWidth) / 2)
            for sample in samples {
                let normalized = max(0.06, CGFloat(sample))
                let h = 3 + normalized * 22
                let rect = CGRect(
                    x: x,
                    y: (size.height - h) / 2,
                    width: barWidth,
                    height: h
                )
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: silence ? Self.silenceShading : Self.fillShading)
                x += barWidth + spacing
            }
        }
        .frame(width: CGFloat(samples.count) * 4 - 2, height: 26)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: samples)
    }
}

struct CompactRecordingOverlay: View {
    private typealias OnDark = SophiieTheme.Palette.OnDark

    @ObservedObject var pipeline: DictationPipeline
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Widest the pill gets with live words beside the waveform. It hugs
    /// shorter text.
    static let liveWidth: CGFloat = 268
    private static let liveTextMaxWidth: CGFloat = liveWidth - 56 - 8 - 20

    private var showsLiveWords: Bool {
        pipeline.phase == .recording && pipeline.streamsLiveTranscript && !pipeline.liveTranscript.isEmpty
    }

    var body: some View {
        content
            .frame(width: showsLiveWords ? nil : 76, height: 26)
            .fixedSize(horizontal: showsLiveWords, vertical: false)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(OnDark.background.opacity(0.95))
            )
            // Inset the hairline so its antialiased outer edge stays on the
            // fill. Flush with the edge, it reads as a light bar at each end
            // of the pill on dark desktops.
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .inset(by: 0.5)
                    .strokeBorder(OnDark.hairline, lineWidth: 1)
            )
            .shadow(color: SophiieTheme.Shadow.tint.opacity(0.32), radius: 10, y: 4)
            .opacity(pulse ? 0.75 : 1.0)
            .animation(
                reduceMotion ? nil : .timingCurve(0.2, 0, 0, 1, duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = isProcessing && !reduceMotion }
            .onChange(of: isProcessing) { _, newValue in
                pulse = newValue && !reduceMotion
            }
            .transition(.opacity)
            .sophiieAnimation(value: pipeline.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch pipeline.phase {
        case .recording:
            HStack(spacing: 8) {
                MiniWaveformView(samples: pipeline.audioSamples, silence: pipeline.isHearingSilence)
                    .frame(width: 56, height: 16)
                if showsLiveWords {
                    LiveTranscriptText(
                        text: pipeline.liveTranscript,
                        budget: LiveTranscriptTail.compactBudget,
                        lineLimit: 1,
                        font: .system(size: 11.5, weight: .medium),
                        color: OnDark.ink
                    )
                    .frame(maxWidth: Self.liveTextMaxWidth, alignment: .leading)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, showsLiveWords ? 10 : 0)
        case .requestingMicrophonePermission, .starting,
                .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            CompactDotsView(color: pipeline.phase == .requestingMicrophonePermission ? OnDark.warning : OnDark.accent)
                .frame(maxWidth: .infinity)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnDark.warning)
                .frame(maxWidth: .infinity)
        case .idle, .done:
            EmptyView()
        }
    }

    private var isProcessing: Bool {
        switch pipeline.phase {
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting,
                .starting, .requestingMicrophonePermission:
            return true
        default:
            return false
        }
    }
}

private struct MiniWaveformView: View {
    let samples: [Float]
    let silence: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            guard !samples.isEmpty else { return }
            // Downsample to a chunky bar set so the pill reads as a
            // recognizable waveform glyph rather than a noisy strip.
            let targetBars = 10
            let step = max(1, samples.count / targetBars)
            let tail = stride(from: 0, to: samples.count, by: step).map { samples[$0] }
            let count = tail.count
            let barWidth: CGFloat = 2.5
            let spacing: CGFloat = 2
            let totalWidth = CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * spacing
            var x = max(0, (size.width - totalWidth) / 2)
            let baseColor: Color = silence ? SophiieTheme.Palette.OnDark.warning : SophiieTheme.Palette.OnDark.accent
            let shading = GraphicsContext.Shading.color(baseColor.opacity(silence ? 0.6 : 1))
            for sample in tail {
                let normalized = max(0.08, CGFloat(sample))
                let h = 2 + normalized * (size.height - 2)
                let rect = CGRect(
                    x: x,
                    y: (size.height - h) / 2,
                    width: barWidth,
                    height: h
                )
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: shading)
                x += barWidth + spacing
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: samples)
    }
}

private struct CompactDotsView: View {
    let color: Color
    @State private var activeIndex = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(activeIndex == index ? 0.95 : 0.3))
                    .frame(width: 4, height: 4)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}

private struct ActivityDotsView: View {
    let color: Color

    @State private var activeIndex = 0
    private let timer = Timer.publish(every: 0.45, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(color.opacity(activeIndex == index ? 0.95 : 0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .onReceive(timer) { _ in
            activeIndex = (activeIndex + 1) % 3
        }
    }
}
