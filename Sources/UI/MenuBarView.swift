import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            actionCard

            if appState.showSetupGuide && (!appState.isReadyForDailyUse || !appState.hasCompletedFirstDictation) {
                setupCard
            }

            if !appState.hotkeyManager.isAccessibilityGranted {
                warningCard(
                    title: "Accessibility Needed",
                    detail: "Global shortcuts and paste-back won’t work until accessibility access is enabled.",
                    tint: .orange,
                    buttonTitle: "Grant Access",
                    action: appState.requestAccessibilityAccess
                )
            }

            if !appState.microphoneAccessGranted {
                warningCard(
                    title: "Microphone Needed",
                    detail: "Whispur can’t record until macOS microphone permission is granted.",
                    tint: .yellow,
                    buttonTitle: "Allow Microphone",
                    action: appState.requestMicrophoneAccess
                )
            }

            providersCard
            shortcutsCard

            if let preview = appState.lastTranscriptPreview,
               !appState.pipeline.canStopRecording {
                lastTranscriptCard(preview)
            }

            footerButtons
        }
        .padding(16)
        .frame(width: 370)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Whispur")
                    .font(.title3.weight(.semibold))

                Text(appState.pipeline.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PreferenceBadge(title: statusBadgeTitle, tone: statusBadgeTone)
        }
    }

    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(appState.recordingSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                appState.toggleManualDictation()
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.pipeline.canStopRecording && !appState.canStartDictation)

            if appState.pipeline.canStopRecording {
                Text(appState.pipeline.activeTriggerMode == .toggle
                    ? "Toggle mode is active. Use the shortcut again or press Stop."
                    : "Push-to-talk is active. Releasing the shortcut also stops recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(backgroundTone.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Guide")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Open") {
                    openSettings(tab: .setup)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            ProgressView(value: appState.setupProgress)
                .tint(.orange)
        }
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var providersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Providers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    openSettings(tab: .providers)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            providerRow(
                title: "Speech",
                value: appState.selectedSTT.displayName,
                configured: appState.isSelectedSTTConfigured
            )

            providerRow(
                title: "Cleanup",
                value: appState.selectedLLM.displayName,
                configured: appState.isSelectedLLMConfigured,
                fallbackText: "Raw transcripts still paste when cleanup credentials are missing."
            )
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var shortcutsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Shortcuts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit") {
                    openSettings(tab: .general)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            HStack(spacing: 10) {
                ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func warningCard(
        title: String,
        detail: String,
        tint: Color,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(buttonTitle, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func lastTranscriptCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("History") {
                    openSettings(tab: .activity)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            Text(preview)
                .font(.caption)
                .lineLimit(5)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Button("Paste Again") {
                    appState.pasteLastTranscript()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Copy") {
                    appState.copyLastTranscript()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footerButtons: some View {
        HStack {
            Button("Settings") {
                openSettings(tab: .general)
            }

            Button("Check for Updates…") {
                appState.sparkleUpdater.checkForUpdates()
            }
            .disabled(!appState.sparkleUpdater.canCheckForUpdates)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .font(.caption)
    }

    private func providerRow(
        title: String,
        value: String,
        configured: Bool,
        fallbackText: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(configured ? .green : .orange)
                    .font(.caption)
            }

            Text(value)
                .font(.subheadline)

            if !configured, let fallbackText {
                Text(fallbackText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func openSettings(tab: SettingsTab) {
        selectedTabRaw = tab.rawValue
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var primaryActionTitle: String {
        appState.pipeline.canStopRecording ? "Stop Dictation" : "Start Dictation"
    }

    private var primaryActionIcon: String {
        appState.pipeline.canStopRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var backgroundTone: Color {
        switch appState.pipeline.phase {
        case .recording:
            return .red
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return .blue
        case .done:
            return .green
        case .error:
            return .orange
        default:
            return .secondary
        }
    }

    private var statusBadgeTitle: String {
        switch appState.pipeline.phase {
        case .idle:
            return appState.isReadyForDailyUse ? "Ready" : "Setup"
        case .requestingMicrophonePermission, .starting:
            return "Starting"
        case .recording:
            return appState.pipeline.activeTriggerMode == .hold ? "Listening" : "Latched"
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return "Working"
        case .done:
            return "Done"
        case .error:
            return "Issue"
        }
    }

    private var statusBadgeTone: PreferenceBadge.Tone {
        switch appState.pipeline.phase {
        case .idle:
            return appState.isReadyForDailyUse ? .good : .warning
        case .requestingMicrophonePermission, .starting:
            return .warning
        case .recording:
            return .critical
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return .neutral
        case .done:
            return .good
        case .error:
            return .critical
        }
    }
}
