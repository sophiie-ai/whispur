import SwiftUI

/// The Parakeet download, pinned in the onboarding top bar: percent while it
/// downloads, a check once ready, and Retry if it failed.
struct OnboardingDownloadPillView: View {
    private typealias Palette = SophiieTheme.Palette

    @ObservedObject var model: ParakeetModelManager
    let retry: () -> Void

    var body: some View {
        let pill = OnboardingDownloadPill.content(for: model.downloadState)
        HStack(spacing: 6) {
            indicator(pill)
            Text(pill.text)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(tint(pill.tone))
                .contentTransition(.numericText())
            if let action = pill.action {
                Button(action.title, action: retry)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.interactive)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 24)
        .background(Color.white.opacity(0.07), in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.OnDark.hairline, lineWidth: 1))
        .help(OnboardingDownloadPill.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(pill.text)
        .accessibilityHint("Dictation works while this downloads.")
        .sophiieAnimation(value: pill)
    }

    @ViewBuilder
    private func indicator(_ pill: OnboardingDownloadPill) -> some View {
        if let fraction = pill.fraction {
            ZStack {
                Circle().stroke(Palette.OnDark.hairline, lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Palette.sky, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
        } else if pill.tone == .progress {
            ProgressView().controlSize(.mini)
        } else {
            Image(systemName: pill.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint(pill.tone))
        }
    }

    private func tint(_ tone: OnboardingDownloadPill.Tone) -> Color {
        switch tone {
        case .progress: return Palette.OnDark.inkSecondary
        case .ready: return Palette.OnDark.success
        case .waiting: return Palette.OnDark.muted
        case .problem: return Palette.OnDark.warning
        }
    }
}
