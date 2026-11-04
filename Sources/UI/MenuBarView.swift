import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsView.selectedTabKey) private var selectedTabRaw = ""

    @State private var isPresentingRecap = false

    private typealias Palette = SophiieTheme.Palette
    private typealias OnDark = SophiieTheme.Palette.OnDark

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 12) {
                statsStrip
                actionCard

                if appState.showSetupGuide && (!appState.isReadyForDailyUse || !appState.hasCompletedFirstDictation) {
                    setupCard
                }

                permissionsCard

                if let preview = appState.lastTranscriptPreview,
                   !appState.pipeline.canStopRecording {
                    lastTranscriptCard(preview)
                }

                settingsStrip
            }
            .padding(16)

            footerButtons
        }
        .frame(width: 370)
        // Opaque brand canvas instead of the system window material, so the
        // cards sit on the same stage as Settings and onboarding. The
        // MenuBarExtra window still clips this to its native rounded shape.
        .background { Palette.surfaceWarm.ignoresSafeArea() }
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .sheet(isPresented: $isPresentingRecap) {
            ShareRecapView(stats: appState.stats)
        }
    }

    // MARK: - Header

    /// Midnight band with the app icon and status, like the head of the
    /// Settings sidebar.
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("Whispur")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(OnDark.ink)
                Text(appState.pipeline.statusTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnDark.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OnDark.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(OnDark.hairline)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Status dot and word on a raised pill, like the sidebar status card.
    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(statusBadgeTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(OnDark.ink)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(OnDark.raised, in: Capsule())
        .overlay(Capsule().strokeBorder(OnDark.hairline, lineWidth: 1))
        .fixedSize()
        .sophiieAnimation(value: statusBadgeTitle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(statusBadgeTitle)")
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsStrip: some View {
        if appState.stats.totalWords > 0 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(appState.stats.totalWords.formatted(.number))
                        .font(SophiieTheme.Typography.display)
                        .tracking(SophiieTheme.Typography.displayTracking)
                    Text("words")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)

                    Spacer()

                    if appState.stats.currentStreak > 0 {
                        streakPill
                    }
                }

                weekSparkline

                CardDivider(leadingInset: 0)

                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(savedSummary)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    TextAction(title: "Share", systemImage: "square.and.arrow.up") {
                        isPresentingRecap = true
                    }
                    .help("Share a recap of your week")
                    .accessibilityLabel("Share recap")
                }
            }
            .sophiieCard(padding: SettingsMetrics.cardPadding, radius: SophiieTheme.Radius.panel)
        }
    }

    /// Same pill shape as the page title pills in Settings.
    private var streakPill: some View {
        HStack(spacing: 4) {
            Text("🔥")
                .accessibilityHidden(true)
            Text("\(appState.stats.currentStreak)d streak")
                .foregroundStyle(Palette.interactive)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Palette.surfaceSelected, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var weekSparkline: some View {
        let days = appState.stats.lastSevenDays
        let maxValue = max(1, days.map(\.words).max() ?? 1)

        let trackHeight: CGFloat = 28
        let barWidth: CGFloat = 12
        let barShape = RoundedRectangle(cornerRadius: 4, style: .continuous)

        // Every day gets a quiet full-height track; days with words fill it
        // from the bottom in proportion to the busiest day.
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(days) { day in
                VStack(spacing: 5) {
                    ZStack(alignment: .bottom) {
                        barShape
                            .fill(Palette.track)
                            .frame(width: barWidth, height: trackHeight)
                        if day.words > 0 {
                            barShape
                                .fill(Palette.highlight)
                                .frame(width: barWidth, height: max(6, CGFloat(day.words) / CGFloat(maxValue) * trackHeight))
                        }
                    }
                    Text(day.label)
                        .font(.system(size: 10, weight: day.id == days.last?.id ? .semibold : .regular))
                        .foregroundStyle(day.id == days.last?.id ? Palette.ink : Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.label): \(day.words) words")
            }
        }
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

    // MARK: - Dictation

    /// The hero card, like the Dictation switch card at the top of Settings.
    private var actionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text(appState.recordingSummary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let shortcut = primaryShortcut {
                    Button {
                        openSettings(tab: .dictation)
                    } label: {
                        KeycapCombo(keys: shortcut.keycapLabels, join: shortcut.isDoublePress ? .sequence : .chord)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Change shortcut")
                    .accessibilityLabel("Shortcut: \(appState.primaryShortcutTitle)")
                    .accessibilityHint("Opens Dictation settings")
                }
            }

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
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sophiieCard(padding: SettingsMetrics.cardPadding, radius: SophiieTheme.Radius.panel, fill: actionCardFill)
        .sophiieAnimation(value: appState.pipeline.phase)
    }

    /// The shortcut the action card shows as keycaps.
    private var primaryShortcut: ShortcutBinding? {
        if appState.shortcutStyle == .tapOrHold { return appState.tapOrHoldShortcut }
        return appState.holdShortcut ?? appState.toggleShortcut
    }

    // MARK: - Setup and permissions

    private var setupCard: some View {
        SettingsCard {
            HStack(alignment: .top, spacing: SettingsMetrics.iconGap) {
                IconTile(systemName: SettingsTab.getStarted.icon)

                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setup Guide")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                    }

                    setupProgressBar

                    HStack(spacing: 6) {
                        Button("Run Setup") {
                            WindowUtilities.dismissMenuBarPopover()
                            NotificationCenter.default.post(name: .whispurRunSetupAgain, object: nil)
                        }
                        .help("Opens the welcome window from the start. Your settings stay as they are.")

                        Button("Open") {
                            openSettings(tab: .getStarted)
                        }
                    }
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, SettingsMetrics.rowPadding + 2)
        }
    }

    /// Setup progress drawn with the same track and highlight as the week
    /// chart.
    private var setupProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.highlight)
                    .frame(width: max(6, proxy.size.width * appState.setupProgress))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Setup progress")
        .accessibilityValue("\(appState.setupCompletedCount) of \(appState.setupItemCount) complete")
    }

    @ViewBuilder
    private var permissionsCard: some View {
        let needsAccessibility = !appState.hotkeyManager.isAccessibilityGranted
        let needsMicrophone = !appState.microphoneAccessGranted
        if needsAccessibility || needsMicrophone {
            SettingsCard {
                if needsAccessibility {
                    permissionRow(
                        title: "Accessibility Needed",
                        detail: "Global shortcuts and paste-back won’t work until accessibility access is enabled.",
                        buttonTitle: "Grant Access",
                        action: appState.requestAccessibilityAccess
                    )
                }
                if needsAccessibility && needsMicrophone {
                    CardDivider()
                }
                if needsMicrophone {
                    permissionRow(
                        title: "Microphone Needed",
                        detail: "Whispur can’t record until macOS microphone permission is granted.",
                        buttonTitle: "Allow Microphone",
                        action: appState.requestMicrophoneAccess
                    )
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: SettingsMetrics.iconGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.warning)
                .frame(width: SettingsMetrics.iconTile, height: SettingsMetrics.iconTile)
                .background(
                    Palette.warning.opacity(colorScheme == .dark ? 0.14 : 0.10),
                    in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(buttonTitle, action: action)
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SettingsMetrics.rowPadding + 2)
    }

    // MARK: - Last transcript

    private func lastTranscriptCard(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last Transcript")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                TextAction(title: "History", systemImage: SettingsTab.activity.icon) {
                    openSettings(tab: .activity)
                }
            }
            .padding(.horizontal, 4)

            SettingsCard {
                CardContent {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(preview)
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.inkSecondary)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)

                        Button {
                            appState.copyLastTranscript()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.sophiieSecondary)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Providers

    /// Speech and cleanup as Settings rows: icon tile, name, status, chevron.
    private var settingsStrip: some View {
        SettingsCard {
            Button {
                openSettings(tab: .providers)
            } label: {
                SettingsRow(icon: "waveform", title: "Speech") {
                    providerValue(
                        appState.selectedSTT.displayName,
                        state: appState.isSelectedSTTConfigured ? .configured : .needsSetup,
                        chevron: "chevron.right"
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Speech: \(appState.selectedSTT.displayName)")
            .accessibilityHint("Opens Providers")

            CardDivider()

            cleanupChip
        }
    }

    private enum ChipState {
        case configured
        case needsSetup
        case off
    }

    /// The cleanup row opens a small menu: the "Clean up with AI" switch
    /// and a link to the Providers page.
    private var cleanupChip: some View {
        Menu {
            Toggle(ProvidersSettingsView.cleanupSwitchTitle, isOn: $appState.cleanupEnabled)
            Divider()
            Button("Cleanup Settings\u{2026}") { openSettings(tab: .providers) }
        } label: {
            SettingsRow(icon: "sparkles", title: "Cleanup") {
                providerValue(
                    appState.cleanupEnabled ? appState.selectedLLM.displayName : "Off",
                    state: !appState.cleanupEnabled ? .off : (appState.isSelectedLLMConfigured ? .configured : .needsSetup),
                    chevron: "chevron.up.chevron.down"
                )
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(appState.cleanupEnabled ? "Cleanup: \(appState.selectedLLM.displayName)" : "Cleanup off")
    }

    private func providerValue(_ value: String, state: ChipState, chevron: String) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .configured:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
            case .needsSetup:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Palette.warning)
            case .off:
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(Palette.muted)
            }
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(state == .off ? Palette.muted : Palette.inkSecondary)
                .lineLimit(1)
            Image(systemName: chevron)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .accessibilityHidden(true)
        }
        .font(.system(size: 12))
        .fixedSize()
    }

    // MARK: - Footer

    /// Quiet text actions on a hairline-topped strip, so the window chrome
    /// actions don't compete with the cards.
    private var footerButtons: some View {
        HStack(spacing: 2) {
            Button("About") {
                openAbout()
            }

            Button("Settings") {
                openSettings(tab: nil)
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
        .buttonStyle(MenuBarFooterButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Palette.surfaceStage)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Palette.border)
                .frame(height: 1)
                .accessibilityHidden(true)
        }
    }

    /// Opens Settings on `tab`, or on its landing page when nil.
    private func openSettings(tab: SettingsTab?) {
        selectedTabRaw = tab?.rawValue ?? ""
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
            return SophiieTheme.Palette.surfaceSelected
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
    private var statusDotColor: Color {
        switch statusBadgeTone {
        case .good: return OnDark.success
        case .warning: return OnDark.warning
        case .critical: return OnDark.danger
        case .neutral: return OnDark.accent
        }
    }
}

/// Footer action in the menu bar panel: muted text that lifts to ink on a
/// subtle fill when hovered.
private struct MenuBarFooterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarFooterButton(configuration: configuration)
    }
}

private struct MenuBarFooterButton: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SophiieTheme.Radius.small, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(isHovering || configuration.isPressed ? SophiieTheme.Palette.ink : SophiieTheme.Palette.inkSecondary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(shape.fill(isHovering || configuration.isPressed ? SophiieTheme.Palette.surfaceSubtle : Color.clear))
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { isHovering = isEnabled && $0 }
            .animation(SophiieTheme.Motion.standard(reduceMotion: reduceMotion), value: isHovering)
    }
}
