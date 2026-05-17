import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("settings.selectedTab") private var selectedTabRaw = SettingsTab.setup.rawValue

    @State private var isPresentingRecap = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statsStrip
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

            if let preview = appState.lastTranscriptPreview,
               !appState.pipeline.canStopRecording {
                lastTranscriptCard(preview)
            }

            settingsStrip

            footerButtons
        }
        .padding(16)
        .frame(width: 370)
        .sheet(isPresented: $isPresentingRecap) {
            ShareRecapView(stats: appState.stats)
        }
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

    @ViewBuilder
    private var statsStrip: some View {
        if appState.stats.totalWords > 0 {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(appState.stats.totalWords.formatted(.number))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                    Text("words")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    if appState.stats.currentStreak > 0 {
                        HStack(spacing: 4) {
                            Text("🔥")
                            Text("\(appState.stats.currentStreak)d streak")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                        .foregroundStyle(.orange)
                    }
                }

                weekSparkline

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(savedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        isPresentingRecap = true
                    } label: {
                        Label("Share recap", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(.purple)
                }
            }
            .padding(14)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var weekSparkline: some View {
        let days = appState.stats.lastSevenDays
        let maxValue = max(1, days.map(\.words).max() ?? 1)

        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                let height = max(4, CGFloat(day.words) / CGFloat(maxValue) * 22)
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(day.words > 0 ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08))
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 24)
    }

    private var savedSummary: String {
        let week = appState.stats.minutesSavedThisWeek
        if week > 0 {
            return "~\(week) min saved typing this week"
        }
        let total = appState.stats.minutesSavedAllTime
        if total > 0 {
            return "~\(total) min saved typing"
        }
        return "Dictate to start tracking your time saved."
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

    private var settingsStrip: some View {
        HStack(spacing: 10) {
            providerChip(
                icon: "waveform",
                value: appState.selectedSTT.displayName,
                configured: appState.isSelectedSTTConfigured,
                tab: .providers
            )

            providerChip(
                icon: "sparkles",
                value: appState.selectedLLM.displayName,
                configured: appState.isSelectedLLMConfigured,
                tab: .providers
            )

            Spacer(minLength: 0)

            Button {
                openSettings(tab: .general)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "command")
                    Text(appState.holdShortcut.menuTitle)
                }
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    private func providerChip(
        icon: String,
        value: String,
        configured: Bool,
        tab: SettingsTab
    ) -> some View {
        Button {
            openSettings(tab: tab)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(value)
                    .lineLimit(1)
                Image(systemName: configured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(configured ? .green : .orange)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
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

            Button {
                appState.copyLastTranscript()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var footerButtons: some View {
        HStack {
            Button("About") {
                openAbout()
            }

            Button("Settings") {
                openSettings(tab: .general)
            }
            .keyboardShortcut(",", modifiers: .command)

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

    private func openSettings(tab: SettingsTab) {
        selectedTabRaw = tab.rawValue
        WindowUtilities.dismissMenuBarPopover()
        WindowUtilities.focusOrOpenWindow(id: .settings, using: openWindow)
    }

    private func openAbout() {
        WindowUtilities.dismissMenuBarPopover()
        WindowUtilities.focusOrOpenWindow(id: .about, using: openWindow)
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
