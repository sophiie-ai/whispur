import SwiftUI

/// General settings: shortcuts, permissions, and behavior.
struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                shortcutsCard
                permissionsCard
                behaviorCard
                appearanceCard
                aboutCard
            }
            .padding(24)
        }
    }

    private var shortcutsCard: some View {
        PreferenceCard(
            "Recording Shortcuts",
            detail: "Use a hold shortcut for push-to-talk and an optional second shortcut for start/stop recording.",
            icon: "keyboard"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                DetailRow("Hold to talk", detail: "Press and hold to record. Releasing ends capture immediately.") {
                    Picker("Hold to talk", selection: holdShortcutBinding) {
                        ForEach(ShortcutBinding.holdPresets, id: \.self) { binding in
                            Text(binding.menuTitle).tag(binding)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
                }

                DetailRow("Toggle recording", detail: "Start once, then stop with the same shortcut or the overlay button.") {
                    Picker("Toggle recording", selection: toggleShortcutBinding) {
                        Text("Off").tag(Optional<ShortcutBinding>.none)
                        ForEach(ShortcutBinding.togglePresets, id: \.self) { binding in
                            Text(binding.menuTitle).tag(Optional(binding))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }

                Divider()

                HStack(spacing: 10) {
                    ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                    ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
                }

                Text(appState.recordingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var permissionsCard: some View {
        PreferenceCard(
            "Permissions",
            detail: "Whispur can monitor setup changes while this window stays open.",
            icon: "lock.shield"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                DetailRow("Accessibility", detail: "Required for global shortcuts and pasting dictated text.") {
                    HStack(spacing: 8) {
                        PreferenceBadge(
                            title: appState.hotkeyManager.isAccessibilityGranted ? "Granted" : "Missing",
                            tone: appState.hotkeyManager.isAccessibilityGranted ? .good : .warning
                        )

                        if appState.hotkeyManager.isAccessibilityGranted {
                            Button("Open Settings") {
                                appState.openAccessibilitySettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button("Grant Access") {
                                appState.requestAccessibilityAccess()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                DetailRow("Microphone", detail: "Needed to capture speech from the selected input device.") {
                    HStack(spacing: 8) {
                        PreferenceBadge(
                            title: appState.microphoneAccessGranted ? "Granted" : "Missing",
                            tone: appState.microphoneAccessGranted ? .good : .warning
                        )

                        if appState.microphoneAccessGranted {
                            Button("Open Settings") {
                                appState.openMicrophoneSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button("Allow") {
                                appState.requestMicrophoneAccess()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }

                DetailRow("Input device", detail: "Pick which microphone Whispur records from. \"System default\" follows the macOS Sound setting.") {
                    AudioInputDevicePicker(appState: appState)
                }

                Divider()

                DetailRow("Shortcut monitoring", detail: "Whispur keeps the global shortcut listener active in the background.") {
                    PreferenceBadge(
                        title: appState.hotkeyManager.isMonitoring ? "Active" : "Inactive",
                        tone: appState.hotkeyManager.isMonitoring ? .good : .critical
                    )
                }
            }
        }
    }

    private var behaviorCard: some View {
        PreferenceCard(
            "Behavior",
            detail: "Tune how Whispur handles output and feedback.",
            icon: "slider.horizontal.3"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Preserve clipboard contents after paste", isOn: $appState.preserveClipboard)
                Toggle("Play start and stop sounds", isOn: $appState.soundEnabled)
                Toggle("Quiet system audio while recording", isOn: $appState.muteSystemAudioWhileRecording)

                if appState.muteSystemAudioWhileRecording {
                    HStack(spacing: 12) {
                        Slider(
                            value: systemAudioReductionBinding,
                            in: 0...100,
                            step: 5
                        )
                        .controlSize(.small)

                        Text(systemAudioReductionLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 80, alignment: .trailing)
                    }
                }

                Text("Reduces the Mac's output volume the moment recording starts and restores it when dictation ends. Background audio keeps playing — it just won't bleed into the mic. 100% silences output entirely; lower values just duck it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Deep context", isOn: $appState.deepContextEnabled)

                Text("Deep context is reserved for future capture-aware cleanup. The setting stays here so the interaction model is already in place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appearanceCard: some View {
        PreferenceCard(
            "Appearance",
            detail: "Choose how the recording indicator looks while you dictate.",
            icon: "rectangle.on.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Recording indicator", selection: $appState.overlayStyle) {
                    ForEach(OverlayStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.overlayStyle == .compact
                    ? "A small pill at the bottom of the screen shows only a waveform while recording. No stop or cancel buttons — use your shortcut or Esc."
                    : "The full overlay at the top of the screen shows status, waveform, and stop/cancel controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var aboutCard: some View {
        PreferenceCard(
            "About",
            detail: "Whispur keeps the brand and workflow lightweight: speak, clean up, paste, move on.",
            icon: "sparkles.rectangle.stack"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                DetailRow("Version") {
                    Text(AppVersion.description)
                        .foregroundStyle(.secondary)
                }

                if !appState.showSetupGuide {
                    Button("Show Setup Guide Again") {
                        appState.reopenSetupGuide()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var holdShortcutBinding: Binding<ShortcutBinding> {
        Binding(
            get: { appState.holdShortcut },
            set: { appState.setHoldShortcut($0) }
        )
    }

    private var toggleShortcutBinding: Binding<ShortcutBinding?> {
        Binding(
            get: { appState.toggleShortcut },
            set: { appState.setToggleShortcut($0) }
        )
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
}

private struct AudioInputDevicePicker: View {
    @ObservedObject var appState: AppState
    @State private var devices: [AudioDevice] = []

    private static let systemDefaultTag = ""

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Picker("Input device", selection: $appState.preferredAudioInputUID) {
                Text("System default").tag(Self.systemDefaultTag)
                if !devices.isEmpty {
                    Divider()
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 240)

            if !appState.preferredAudioInputUID.isEmpty,
               !devices.contains(where: { $0.uid == appState.preferredAudioInputUID }) {
                Text("Saved device is not connected — recording will use the system default.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { devices = AudioDevice.availableInputDevices() }
    }
}
