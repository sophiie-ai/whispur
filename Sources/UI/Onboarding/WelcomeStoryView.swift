import SwiftUI

/// The welcome screen's before-and-after, drawn from `WelcomeStoryTimeline`.
/// Plays once on its own, offers a replay, and never holds anything up:
/// Continue works the whole time. With Reduce Motion it shows the two
/// finished composers side by side and doesn't animate.
struct WelcomeStoryView: View {
    private typealias Palette = SophiieTheme.Palette
    private typealias Story = WelcomeStoryTimeline

    /// A fixed moment to draw instead of playing, for renders.
    var fixedTime: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.onboardingRendersReducedMotion) private var rendersReducedMotion
    @State private var startedAt = Date()
    @State private var finished = false

    private var reduceMotion: Bool { systemReduceMotion || rendersReducedMotion }

    var body: some View {
        Group {
            if let fixedTime {
                scene(Story.frame(at: fixedTime))
            } else if reduceMotion {
                scene(Story.finalFrame)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: finished)) { context in
                    scene(Story.frame(at: context.date.timeIntervalSince(startedAt)))
                }
                .task(id: startedAt) {
                    finished = false
                    try? await Task.sleep(for: .seconds(Story.end + 0.2))
                    finished = true
                }
            }
        }
    }

    private func scene(_ frame: Story.Frame) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                StoryCard(
                    title: "Without Whispur",
                    elapsed: frame.handElapsed,
                    isDone: frame.handDone,
                    accent: Palette.OnDark.muted
                ) {
                    HandComposer(text: frame.handText, isDone: frame.handDone)
                }
                StoryCard(
                    title: "With Whispur",
                    elapsed: frame.voiceElapsed,
                    isDone: frame.voicePhase == .done,
                    accent: Palette.sky
                ) {
                    VoiceComposer(phase: frame.voicePhase, text: frame.voiceText)
                }
            }
            // One spoken summary for the decorative scene; the replay button
            // below stays its own VoiceOver element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Typing a reply by hand takes \(Story.clock(Story.handDuration)). Saying it with Whispur takes \(Story.clock(Story.voiceDuration))."
            )
            replayButton
                .opacity(showsReplay ? 1 : 0)
                .accessibilityHidden(!showsReplay)
                .animation(.easeOut(duration: 0.25), value: finished)
        }
    }

    private var showsReplay: Bool { finished && fixedTime == nil && !reduceMotion }

    private var replayButton: some View {
        Button {
            startedAt = Date()
        } label: {
            Label("Play again", systemImage: "arrow.counterclockwise")
                .font(SophiieTheme.Typography.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.OnDark.muted)
        .disabled(!finished)
        .accessibilityLabel("Play the comparison again")
    }
}

/// One side of the comparison: a label, a running clock, the customer's
/// message and the composer.
private struct StoryCard<Composer: View>: View {
    private typealias Palette = SophiieTheme.Palette

    let title: String
    let elapsed: TimeInterval
    let isDone: Bool
    let accent: Color
    @ViewBuilder let composer: Composer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(SophiieTheme.Typography.eyebrowTracking)
                    .foregroundStyle(accent)
                Spacer()
                Label(WelcomeStoryTimeline.clock(elapsed), systemImage: isDone ? "checkmark" : "clock")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(isDone ? accent : Palette.OnDark.muted)
            }

            Text(WelcomeStoryTimeline.question)
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.OnDark.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .padding(.trailing, 34)

            Spacer(minLength: 0)

            composer
        }
        .padding(12)
        .frame(width: 270, height: 168)
        .background(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                .fill(Palette.OnDark.raised.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                .strokeBorder(Palette.OnDark.hairline, lineWidth: 1)
        )
    }
}

/// The reply field, shared by both sides.
private struct ComposerField<Content: View>: View {
    let highlighted: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(highlighted ? SophiieTheme.Palette.sky.opacity(0.7) : SophiieTheme.Palette.OnDark.hairline, lineWidth: 1)
            )
    }
}

private struct HandComposer: View {
    let text: String
    let isDone: Bool

    var body: some View {
        ComposerField(highlighted: false) {
            // The caret rides on the end of the text; it's a bar character
            // so it wraps with the words.
            (Text(text).foregroundStyle(SophiieTheme.Palette.OnDark.ink)
                + Text(isDone ? "" : "|").foregroundStyle(SophiieTheme.Palette.sky))
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VoiceComposer: View {
    let phase: WelcomeStoryTimeline.VoicePhase
    let text: String

    var body: some View {
        ComposerField(highlighted: phase == .listening) {
            switch phase {
            case .waiting:
                Text("|")
                    .font(.system(size: 12))
                    .foregroundStyle(SophiieTheme.Palette.sky)
            case .listening:
                RecordingPill()
            case let .landing(progress):
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(SophiieTheme.Palette.OnDark.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .opacity(progress)
                    .offset(y: (1 - progress) * 4)
            case .done:
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(SophiieTheme.Palette.OnDark.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A small recording pill with a live-looking waveform.
private struct RecordingPill: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 6) {
                Circle()
                    .fill(SophiieTheme.Palette.OnDark.danger)
                    .frame(width: 6, height: 6)
                HStack(spacing: 2) {
                    ForEach(0..<14, id: \.self) { bar in
                        Capsule()
                            .fill(SophiieTheme.Palette.sky)
                            .frame(width: 2.5, height: 4 + 12 * Self.level(bar: bar, time: t))
                    }
                }
                .frame(height: 16)
                Text("Listening")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SophiieTheme.Palette.OnDark.muted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private static func level(bar: Int, time: TimeInterval) -> Double {
        let a = sin(time * 9 + Double(bar) * 0.8)
        let b = sin(time * 5.3 + Double(bar) * 1.7)
        return 0.5 + 0.5 * (0.6 * a + 0.4 * b)
    }
}
