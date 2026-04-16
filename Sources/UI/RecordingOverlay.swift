import SwiftUI

struct RecordingOverlay: View {
    @ObservedObject var pipeline: DictationPipeline
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Group {
            switch pipeline.phase {
            case .idle:
                EmptyView()
            case .requestingMicrophonePermission:
                overlayShell {
                    statusRow(
                        title: "Microphone Access",
                        detail: pipeline.statusDetail,
                        leading: AnyView(ActivityDotsView(color: .orange))
                    )
                }
            case .starting:
                overlayShell {
                    statusRow(
                        title: "Preparing",
                        detail: pipeline.statusDetail,
                        leading: AnyView(ActivityDotsView(color: .white))
                    )
                }
            case .recording:
                overlayShell {
                    recordingRow
                }
            case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
                overlayShell {
                    HStack(spacing: 12) {
                        statusRow(
                            title: pipeline.statusTitle,
                            detail: pipeline.statusDetail,
                            leading: AnyView(ActivityDotsView(color: .blue))
                        )

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel (esc)")
                    }
                }
            case .done(let text):
                overlayShell {
                    statusRow(
                        title: "Inserted",
                        detail: text,
                        leading: AnyView(
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
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
                                .foregroundStyle(.orange)
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
        return HStack(spacing: 10) {
            CompactWaveformView(samples: pipeline.audioSamples, silence: silence)
                .opacity(silence ? 0.5 : 1)
                .animation(.easeInOut(duration: 0.2), value: silence)
                .accessibilityLabel(silence
                    ? "No audio detected"
                    : (isHold ? "Listening" : "Recording"))

            Spacer(minLength: 6)

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Cancel (esc)")

            if !isHold {
                Button(action: onStop) {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("Stop")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.red.opacity(0.92)))
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: pipeline.activeTriggerMode)
    }

    private func statusRow(title: String, detail: String?, leading: AnyView) -> some View {
        HStack(spacing: 12) {
            leading
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.72))
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
                LinearGradient(
                    colors: [Color.black.opacity(0.94), Color.black.opacity(0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.22), radius: 18, y: 10)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.spring(response: 0.26, dampingFraction: 0.85), value: pipeline.phase)
    }
}

private struct CompactWaveformView: View {
    let samples: [Float]
    let silence: Bool

    // Two precomputed shadings — one for active recording, one for silence.
    // Built once at load to avoid per-frame gradient allocation.
    private static let activeShading = GraphicsContext.Shading.linearGradient(
        Gradient(colors: [.red.opacity(0.95), .orange.opacity(0.9)]),
        startPoint: CGPoint(x: 0, y: 0),
        endPoint: CGPoint(x: 0, y: 26)
    )
    private static let silenceShading = GraphicsContext.Shading.linearGradient(
        Gradient(colors: [.orange.opacity(0.75), .orange.opacity(0.55)]),
        startPoint: CGPoint(x: 0, y: 0),
        endPoint: CGPoint(x: 0, y: 26)
    )

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let count = samples.count
            guard count > 0 else { return }
            let barWidth: CGFloat = 2
            let spacing: CGFloat = 2
            let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * spacing
            var x = max(0, (size.width - totalWidth) / 2)
            let shading = silence ? Self.silenceShading : Self.activeShading
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
                context.fill(path, with: shading)
                x += barWidth + spacing
            }
        }
        .frame(width: CGFloat(samples.count) * 4 - 2, height: 26)
        .animation(.easeOut(duration: 0.08), value: samples)
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
