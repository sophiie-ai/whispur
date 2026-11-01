import SwiftUI

/// Preferences: permissions, sound and output, the recording indicator, and
/// the app version. Shortcuts live on the Dictation page and the custom
/// cleanup prompt on the Styles page.
struct PreferencesSettingsView: View {
    @ObservedObject var appState: AppState
    let setup: SettingsSetupState

    var body: some View {
        SettingsPage {
            PageHeader(SettingsTab.preferences.title, subtitle: SettingsTab.preferences.summary)
            permissionsSection
            outputSection
            indicatorSection
            aboutSection
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        SettingsSection("Permissions", footer: "Whispur notices permission changes while this window is open.") {
            SettingsCard {
                SettingsRow(icon: "accessibility", title: "Accessibility", subtitle: "Required for global shortcuts and pasting dictated text.") {
                    permissionControls(
                        granted: setup.accessibilityGranted,
                        grant: ("Grant Access", appState.requestAccessibilityAccess),
                        open: appState.openAccessibilitySettings
                    )
                }
                CardDivider()
                SettingsRow(icon: "mic", title: "Microphone", subtitle: "Needed to capture speech from the selected input device.") {
                    permissionControls(
                        granted: setup.microphoneGranted,
                        grant: ("Allow", appState.requestMicrophoneAccess),
                        open: appState.openMicrophoneSettings
                    )
                }
                CardDivider()
                AudioInputDeviceRow(appState: appState)
                CardDivider()
                SettingsRow(icon: "keyboard", title: "Shortcut monitoring", subtitle: "Whispur keeps the global shortcut listener active in the background.") {
                    PreferenceBadge(
                        title: appState.hotkeyManager.isMonitoring ? "Active" : "Inactive",
                        tone: appState.hotkeyManager.isMonitoring ? .good : .critical
                    )
                }
            }
        }
    }

    private func permissionControls(granted: Bool, grant: (String, () -> Void), open: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            PreferenceBadge(title: granted ? "Granted" : "Missing", tone: granted ? .good : .warning)
            if granted {
                Button("Open Settings", action: open)
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.small)
            } else {
                Button(grant.0, action: grant.1)
                    .buttonStyle(.sophiiePrimary)
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Sound and output

    private var outputSection: some View {
        SettingsSection("Sound and output") {
            SettingsCard {
                SettingsRow(icon: "doc.on.clipboard", title: "Preserve clipboard", subtitle: "Put back what was on the clipboard after pasting.") {
                    SettingsSwitch(label: "Preserve clipboard contents after paste", isOn: $appState.preserveClipboard)
                }
                CardDivider()
                SettingsRow(icon: "speaker.wave.2", title: "Start and stop sounds", subtitle: "Play a short sound when recording starts and ends.") {
                    SettingsSwitch(label: "Play start and stop sounds", isOn: $appState.soundEnabled)
                }
                CardDivider()
                SettingsRow(
                    icon: "speaker.slash",
                    title: "Quiet system audio while recording",
                    subtitle: "Lowers the Mac's output while you talk and restores it when dictation ends, so background audio doesn't bleed into the mic."
                ) {
                    SettingsSwitch(label: "Quiet system audio while recording", isOn: $appState.muteSystemAudioWhileRecording)
                }
                if appState.muteSystemAudioWhileRecording {
                    HStack(spacing: 12) {
                        Slider(value: systemAudioReductionBinding, in: 0...100, step: 5)
                            .controlSize(.small)
                            .accessibilityLabel("System audio reduction")
                            .accessibilityValue(systemAudioReductionLabel)
                        Text(systemAudioReductionLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(SophiieTheme.Palette.muted)
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    .padding(.leading, SettingsMetrics.textInset)
                    .padding(.bottom, 12)
                }
                CardDivider()
                SettingsRow(
                    icon: "brain",
                    title: "Deep context",
                    subtitle: "Reserved for future capture-aware cleanup. It has no effect yet."
                ) {
                    SettingsSwitch(label: "Deep context", isOn: $appState.deepContextEnabled)
                }
            }
        }
    }

    private var systemAudioReductionBinding: Binding<Double> {
        Binding(
            get: { Double(appState.systemAudioReductionPercent) },
            set: { appState.systemAudioReductionPercent = Int($0.rounded()) }
        )
    }

    private var systemAudioReductionLabel: String {
        let percent = appState.systemAudioReductionPercent
        if percent >= 100 { return "Full mute" }
        if percent == 0 { return "No change" }
        return "-\(percent)%"
    }

    // MARK: - Recording indicator

    private var indicatorSection: some View {
        SettingsSection("Recording indicator") {
            SettingsCard {
                SettingsRow(
                    icon: "rectangle.on.rectangle",
                    title: "Style",
                    subtitle: appState.overlayStyle == .compact
                        ? "A small pill at the bottom of the screen shows only a waveform. Stop with your shortcut or Esc."
                        : "The full overlay at the top of the screen shows status, waveform, and stop and cancel buttons."
                ) {
                    Picker("Recording indicator", selection: $appState.overlayStyle) {
                        ForEach(OverlayStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        SettingsSection("About") {
            SettingsCard {
                SettingsRow(icon: "info.circle", title: "Version", subtitle: AppVersion.description) {
                    if !appState.showSetupGuide {
                        Button("Show Setup Guide Again") { appState.reopenSetupGuide() }
                            .buttonStyle(.sophiieSecondary)
                            .controlSize(.small)
                    }
                }
            }
        }
    }
}

/// Read-only view of the built-in cleanup prompt, collapsed by default.
struct DefaultPromptDisclosure: View {
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withSophiieAnimation { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    Text("Show the default cleanup prompt")
                        .font(.system(size: 12.5, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                Text(Prompts.defaultCleanup)
                    .font(SophiieTheme.Typography.mono)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SophiieTheme.Palette.surfaceSubtle, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.control, style: .continuous))
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 12)
    }
}

private struct AudioInputDeviceRow: View {
    @ObservedObject var appState: AppState
    @State private var devices: [AudioDevice] = []
    @Environment(\.listInputDevices) private var listInputDevices

    private static let systemDefaultTag = ""

    var body: some View {
        SettingsRow(icon: "waveform.circle", title: "Input device", subtitle: subtitle) {
            RowPicker("Input device", selection: $appState.preferredAudioInputUID, maxWidth: 200) {
                Text("System default").tag(Self.systemDefaultTag)
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
        }
        .onAppear { devices = listInputDevices() }
    }

    private var subtitle: String {
        if !appState.preferredAudioInputUID.isEmpty,
           !devices.contains(where: { $0.uid == appState.preferredAudioInputUID }) {
            return "The saved device is not connected, so recording uses the system default."
        }
        return "\"System default\" follows the macOS Sound setting."
    }
}

private struct ListInputDevicesKey: EnvironmentKey {
    static let defaultValue: @Sendable () -> [AudioDevice] = { AudioDevice.availableInputDevices() }
}

extension EnvironmentValues {
    /// Lists the input devices the Preferences page offers. Renders swap in a
    /// fixed list so the output does not depend on the machine's hardware.
    var listInputDevices: @Sendable () -> [AudioDevice] {
        get { self[ListInputDevicesKey.self] }
        set { self[ListInputDevicesKey.self] = newValue }
    }
}
