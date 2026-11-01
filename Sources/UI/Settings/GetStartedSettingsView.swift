import SwiftUI

/// Get started: the setup checklist and a short how-it-works.
struct GetStartedSettingsView: View {
    @ObservedObject var appState: AppState
    let setup: SettingsSetupState
    let openTab: (SettingsTab) -> Void

    /// Steps shown in the checklist; each one is counted in `pendingSteps`.
    private static let stepCount = 5

    private var completedCount: Int {
        Self.stepCount - setup.pendingSteps
    }

    var body: some View {
        SettingsPage {
            PageHeader(
                SettingsTab.getStarted.title,
                pill: setup.isComplete ? "Ready" : "Needs setup",
                pillTone: setup.isComplete ? .info : .warning,
                subtitle: SettingsTab.getStarted.summary
            )

            progressCard
            checklistSection
            howItWorksSection
        }
    }

    private var progressCard: some View {
        SettingsCard(hero: true) {
            CardContent {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(completedCount) of \(Self.stepCount) complete")
                            .font(.system(size: 17, weight: .semibold))
                            .tracking(SophiieTheme.Typography.titleTracking)
                            .foregroundStyle(SophiieTheme.Palette.ink)
                        Spacer()
                    }
                    Text(setup.isComplete
                        ? "Whispur is ready to dictate across your Mac."
                        : "A few items still need attention before daily use feels seamless.")
                        .font(.system(size: 12))
                        .foregroundStyle(SophiieTheme.Palette.muted)
                    SetupProgressBar(fraction: Double(completedCount) / Double(Self.stepCount))
                        .accessibilityElement()
                        .accessibilityLabel("Setup progress")
                        .accessibilityValue("\(completedCount) of \(Self.stepCount) complete")
                }
            }
        }
    }

    private var checklistSection: some View {
        SettingsSection("Checklist") {
            SettingsCard {
                step(
                    "Grant microphone access",
                    detail: "Whispur needs live audio input before it can capture speech.",
                    isComplete: setup.microphoneGranted,
                    action: setup.microphoneGranted ? nil : ("Allow", { appState.requestMicrophoneAccess() })
                )
                CardDivider()
                step(
                    "Enable accessibility access",
                    detail: "Lets Whispur trigger shortcuts globally and paste text back into the active app.",
                    isComplete: setup.accessibilityGranted,
                    action: setup.accessibilityGranted ? nil : ("Open", { appState.requestAccessibilityAccess() })
                )
                CardDivider()
                step(
                    "Choose a speech provider",
                    detail: setup.speechReady
                        ? "\(appState.selectedSTT.displayName) is ready."
                        : "The current speech provider still needs credentials.",
                    isComplete: setup.speechReady,
                    action: ("Providers", { openTab(.providers) })
                )
                CardDivider()
                step(
                    "Review your shortcuts",
                    detail: appState.shortcutSummary,
                    isComplete: setup.hasShortcut,
                    action: ("Shortcuts", { openTab(.dictation) })
                )
                CardDivider()
                step(
                    "Run a first dictation",
                    detail: setup.hasDictated
                        ? "Recent activity is available on the Activity page."
                        : "Try one dictation to confirm your end-to-end flow.",
                    isComplete: setup.hasDictated,
                    action: setup.hasDictated ? ("Activity", { openTab(.activity) }) : nil
                )
            }
        }
    }

    private func step(_ title: String, detail: String, isComplete: Bool, action: (String, () -> Void)?) -> some View {
        SettingsRow(
            icon: isComplete ? "checkmark.circle.fill" : "circle.dashed",
            title: title,
            subtitle: detail,
            iconTint: isComplete ? SophiieTheme.Palette.success : SophiieTheme.Palette.warning
        ) {
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.small)
            }
        }
        .accessibilityValue(isComplete ? "Done" : "Not done")
    }

    private var howItWorksSection: some View {
        SettingsSection("How it works") {
            SettingsCard {
                CardContent {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hold your shortcut to speak, or use the hands-free shortcut when you want to stay in dictation mode. After you stop, Whispur transcribes, cleans up the wording, and pastes the final text back into the frontmost app.")
                            .font(.system(size: 13))
                            .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 10) {
                            Button("Open Dictionary") { openTab(.dictionary) }
                                .buttonStyle(.sophiiePrimary)
                            if appState.showSetupGuide {
                                Button("Hide Setup Guide") { appState.hideSetupGuide() }
                                    .buttonStyle(.sophiieSecondary)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Thin token-coloured progress bar (track + highlight fill).
private struct SetupProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SophiieTheme.Palette.track)
                Capsule()
                    .fill(SophiieTheme.Palette.highlight)
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
