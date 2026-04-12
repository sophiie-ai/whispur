import SwiftUI

struct SetupSettingsView: View {
    @ObservedObject var appState: AppState
    let openTab: (SettingsTab) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heroCard
                checklistCard
                quickStartCard
            }
            .padding(24)
        }
    }

    private var heroCard: some View {
        PreferenceCard(
            "Whispur Setup",
            detail: "Finish the core steps once, then dictation stays out of your way.",
            icon: "sparkles"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                            .font(.title2.weight(.semibold))
                        Text(appState.isReadyForDailyUse ? "Whispur is ready to dictate across your Mac." : "A few items still need attention before daily use feels seamless.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    PreferenceBadge(
                        title: appState.isReadyForDailyUse ? "Ready" : "Needs setup",
                        tone: appState.isReadyForDailyUse ? .good : .warning
                    )
                }

                ProgressView(value: appState.setupProgress)
                    .tint(.orange)

                HStack(spacing: 10) {
                    ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                    ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
                }
            }
        }
    }

    private var checklistCard: some View {
        PreferenceCard(
            "Checklist",
            detail: "These are the steps that matter for a smooth first-run experience.",
            icon: "checklist"
        ) {
            VStack(spacing: 10) {
                SetupChecklistRow(
                    title: "Grant microphone access",
                    detail: "Whispur needs live audio input before it can capture speech.",
                    isComplete: appState.microphoneAccessGranted,
                    actionTitle: appState.microphoneAccessGranted ? nil : "Allow",
                    action: appState.microphoneAccessGranted ? nil : { appState.requestMicrophoneAccess() }
                )

                SetupChecklistRow(
                    title: "Enable accessibility access",
                    detail: "This lets Whispur trigger shortcuts globally and paste text back into the active app.",
                    isComplete: appState.hotkeyManager.isAccessibilityGranted,
                    actionTitle: appState.hotkeyManager.isAccessibilityGranted ? nil : "Open",
                    action: appState.hotkeyManager.isAccessibilityGranted ? nil : { appState.requestAccessibilityAccess() }
                )

                SetupChecklistRow(
                    title: "Choose a speech provider",
                    detail: appState.isSelectedSTTConfigured
                        ? "\(appState.selectedSTT.displayName) is ready."
                        : "The current speech provider still needs credentials.",
                    isComplete: appState.isSelectedSTTConfigured,
                    actionTitle: "Providers",
                    action: { openTab(.providers) }
                )

                SetupChecklistRow(
                    title: "Review your shortcuts",
                    detail: appState.shortcutSummary,
                    isComplete: true,
                    actionTitle: "Shortcuts",
                    action: { openTab(.general) }
                )

                SetupChecklistRow(
                    title: "Run a first dictation",
                    detail: appState.hasCompletedFirstDictation
                        ? "Recent activity is available in the Activity tab."
                        : "Try one dictation to confirm your end-to-end flow.",
                    isComplete: appState.hasCompletedFirstDictation,
                    actionTitle: appState.hasCompletedFirstDictation ? "Activity" : nil,
                    action: appState.hasCompletedFirstDictation ? { openTab(.activity) } : nil
                )
            }
        }
    }

    private var quickStartCard: some View {
        PreferenceCard(
            "How It Works",
            detail: "Whispur keeps capture, cleanup, and paste in a single pass.",
            icon: "waveform.and.mic"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Hold your shortcut to speak, or use the toggle shortcut when you want to stay in dictation mode. After you stop, Whispur transcribes, cleans up the wording, and pastes the final text back into the frontmost app.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button("Review Prompts") {
                        openTab(.prompts)
                    }

                    Button("Hide Setup Guide") {
                        appState.hideSetupGuide()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}
