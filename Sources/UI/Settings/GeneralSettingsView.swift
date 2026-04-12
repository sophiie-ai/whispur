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
                Toggle("Deep context", isOn: $appState.deepContextEnabled)

                Text("Deep context is reserved for future capture-aware cleanup. The setting stays here so the interaction model is already in place.")
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
                    Text("v0.1.0")
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
}
