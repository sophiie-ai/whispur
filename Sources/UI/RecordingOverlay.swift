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

                        EscapeHintChip()

                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.white.opacity(0.18)))
                        }
                        .buttonStyle(.plain)
                        .help("Cancel (discard)")
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
            ZStack {
                Circle()
                    .fill((silence ? Color.orange : Color.red).opacity(0.22))
                    .frame(width: 24, height: 24)
                    .scaleEffect(pipeline.audioLevel > 0.04 ? 1.16 : 0.94)
                    .animation(.easeInOut(duration: 0.14), value: pipeline.audioLevel)

                Circle()
                    .fill(silence ? Color.orange : Color.red)
                    .frame(width: 9, height: 9)
            }

            Text(silence
                ? "No audio"
                : (isHold ? "Listening" : "Recording"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            CompactWaveformView(samples: pipeline.audioSamples)
                .opacity(silence ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.2), value: silence)

            EscapeHintChip()

            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Cancel (discard recording)")

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

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.92), .orange.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: height(for: sample))
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.08), value: samples)
    }

    private func height(for sample: Float) -> CGFloat {
        let normalized = max(0.06, CGFloat(sample))
        return 3 + normalized * 22
    }
}

private struct EscapeHintChip: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("esc")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5)
                )
            Text("cancel")
                .font(.system(size: 10, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.6))
        .accessibilityLabel("Press Escape to cancel")
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
