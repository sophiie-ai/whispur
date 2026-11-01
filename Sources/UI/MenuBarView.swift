import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
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
                    tint: SophiieTheme.Palette.warning,
                    buttonTitle: "Grant Access",
                    action: appState.requestAccessibilityAccess
                )
            }

            if !appState.microphoneAccessGranted {
                warningCard(
                    title: "Microphone Needed",
                    detail: "Whispur can’t record until macOS microphone permission is granted.",
                    tint: SophiieTheme.Palette.warning,
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
        // Opaque brand canvas instead of the system window material, so the
        // cards sit on the same stage as Settings and onboarding. The
        // MenuBarExtra window still clips this to its native rounded shape.
        .background { SophiieTheme.Palette.surfaceWarm.ignoresSafeArea() }
        .foregroundStyle(SophiieTheme.Palette.ink)
        .tint(SophiieTheme.Palette.accent)
        .sheet(isPresented: $isPresentingRecap) {
            ShareRecapView(stats: appState.stats)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Whispur")
                    .font(SophiieTheme.Typography.title)
                    .tracking(SophiieTheme.Typography.titleTracking)

                Text(appState.pipeline.statusTitle)
                    .font(.subheadline)
                    .foregroundStyle(SophiieTheme.Palette.muted)
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
                        .font(SophiieTheme.Typography.display)
                        .tracking(SophiieTheme.Typography.displayTracking)
                    Text("words")
                        .font(.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)

                    Spacer()

                    if appState.stats.currentStreak > 0 {
                        HStack(spacing: 4) {
                            Text("🔥")
                            Text("\(appState.stats.currentStreak)d streak")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(SophiieTheme.Palette.surfaceSelected, in: Capsule())
                        .foregroundStyle(SophiieTheme.Palette.ink)
                    }
                }

                weekSparkline

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption2)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                    Text(savedSummary)
                        .font(.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)

                    Spacer()

                    Button {
                        isPresentingRecap = true
                    } label: {
                        Label("Share recap", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(SophiieTheme.Palette.interactive)
                }
            }
            .sophiieCard(padding: 14, radius: SophiieTheme.Radius.panel)
        }
    }

    private var weekSparkline: some View {
        let days = appState.stats.lastSevenDays
        let maxValue = max(1, days.map(\.words).max() ?? 1)

        let trackHeight: CGFloat = 24
        let barWidth: CGFloat = 10
        let barShape = RoundedRectangle(cornerRadius: 3, style: .continuous)

        // Every day gets a quiet full-height track; days with words fill it
        // from the bottom in proportion to the busiest day.
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                ZStack(alignment: .bottom) {
                    barShape
                        .fill(SophiieTheme.Palette.track)
                        .frame(width: barWidth, height: trackHeight)
                    if day.words > 0 {
                        barShape
                            .fill(SophiieTheme.Palette.highlight)
                            .frame(width: barWidth, height: max(6, CGFloat(day.words) / CGFloat(maxValue) * trackHeight))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: trackHeight)
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
                .foregroundStyle(SophiieTheme.Palette.muted)

            Button {
                appState.toggleManualDictation()
            } label: {
                Label(primaryActionTitle, systemImage: primaryActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.sophiiePrimary)
            .controlSize(.large)
            .disabled(!appState.pipeline.canStopRecording && !appState.canStartDictation)

            if appState.pipeline.canStopRecording {
                Text(appState.pipeline.activeTriggerMode == .toggle
                    ? appState.toggleActiveHint
                    : "Push-to-talk is active. Releasing the shortcut also stops recording.")
                    .font(.caption)
                    .foregroundStyle(SophiieTheme.Palette.muted)
            }
        }
        .sophiieCard(padding: 14, radius: SophiieTheme.Radius.panel, fill: actionCardFill)
        .sophiieAnimation(value: appState.pipeline.phase)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Setup Guide")
                        .font(.subheadline.weight(.semibold))
                    Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                        .font(.caption)
                        .foregroundStyle(SophiieTheme.Palette.muted)
                }

                Spacer()

                Button("Open") {
                    openSettings(tab: .setup)
                }
                .buttonStyle(.sophiieSecondary)
                .controlSize(.small)
            }

            ProgressView(value: appState.setupProgress)
        }
        .sophiieCard(padding: 14, radius: SophiieTheme.Radius.panel)
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
                .font(SophiieTheme.Typography.captionStrong)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SophiieTheme.Palette.surfaceSubtle, in: Capsule())
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
                    .foregroundStyle(configured ? SophiieTheme.Palette.success : SophiieTheme.Palette.warning)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(SophiieTheme.Palette.surfaceSubtle, in: Capsule())
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
                .foregroundStyle(SophiieTheme.Palette.muted)

            Button(buttonTitle, action: action)
                .buttonStyle(.sophiieSecondary)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        // Lighter tint in light mode keeps the warning title at 4.5:1.
        .background(tint.opacity(colorScheme == .dark ? 0.10 : 0.08), in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SophiieTheme.Radius.panel, style: .continuous)
                .strokeBorder(tint.opacity(0.18), lineWidth: 1)
        )
    }

    private func lastTranscriptCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Last Transcript")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(SophiieTheme.Palette.muted)
                Spacer()
                Button("History") {
                    openSettings(tab: .activity)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(SophiieTheme.Palette.interactive)
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
            .buttonStyle(.sophiieSecondary)
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sophiieCard(padding: 14, radius: SophiieTheme.Radius.panel)
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
                checkForUpdates()
            }
            .disabled(!appState.sparkleUpdater.canCheckForUpdates)

            Spacer()

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.sophiieSecondary)
        .controlSize(.small)
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

    private func checkForUpdates() {
        // Close the menu bar window first: Sparkle activates the app and shows
        // its own window, and an app-owned popover does not auto-close on that
        // activation, so it would otherwise stay on top of the update dialog.
        WindowUtilities.dismissMenuBarPopover()
        appState.sparkleUpdater.checkForUpdates()
    }

    private var primaryActionTitle: String {
        appState.pipeline.canStopRecording ? "Stop Dictation" : "Start Dictation"
    }

    private var primaryActionIcon: String {
        appState.pipeline.canStopRecording ? "stop.circle.fill" : "mic.circle.fill"
    }

    private var actionCardFill: Color {
        switch appState.pipeline.phase {
        case .recording:
            return SophiieTheme.Palette.sky.opacity(0.16)
        case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
            return SophiieTheme.Palette.surfaceSelected
        case .done:
            return SophiieTheme.Palette.success.opacity(0.10)
        case .error:
            return SophiieTheme.Palette.warning.opacity(0.10)
        default:
            return SophiieTheme.Palette.surface
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
