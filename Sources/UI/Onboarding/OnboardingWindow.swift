import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(appState: AppState, onClose: @escaping () -> Void) {
        self.onClose = onClose

        let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Welcome to Whispur"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()

        super.init(window: window)

        hostingController.rootView = AnyView(
            OnboardingWindow(appState: appState) { [weak self] in
                self?.close()
            }
        )
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        showWindow(nil)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case microphone
    case accessibility
    case shortcuts
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .shortcuts:
            return "Shortcuts"
        case .ready:
            return "Ready"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "A fast first-run pass before dictation disappears into the background."
        case .microphone:
            return "Whispur needs live audio input before it can capture speech."
        case .accessibility:
            return "Global shortcuts and paste-back depend on accessibility access."
        case .shortcuts:
            return "Review the default controls before you start dictating."
        case .ready:
            return "You can always revisit setup later from Settings."
        }
    }

    var icon: String {
        switch self {
        case .welcome:
            return "sparkles"
        case .microphone:
            return "mic"
        case .accessibility:
            return "lock.shield"
        case .shortcuts:
            return "keyboard"
        case .ready:
            return "checkmark.circle"
        }
    }
}

struct OnboardingWindow: View {
    @ObservedObject var appState: AppState
    let dismiss: () -> Void

    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    stepIndicator
                    contentCard
                    summaryCard
                }
                .padding(24)
            }

            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Whispur")
                    .font(.title2.weight(.semibold))
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            PreferenceBadge(
                title: "Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)",
                tone: .neutral
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var stepIndicator: some View {
        HStack(spacing: 10) {
            ForEach(OnboardingStep.allCases) { currentStep in
                VStack(spacing: 8) {
                    Image(systemName: currentStep.icon)
                        .font(.headline)
                        .frame(width: 34, height: 34)
                        .background(step == currentStep ? Color.orange.opacity(0.16) : Color.primary.opacity(0.05), in: Circle())
                        .foregroundStyle(step.rawValue >= currentStep.rawValue ? Color.orange : Color.secondary)

                    Text(currentStep.title)
                        .font(.caption.weight(step == currentStep ? .semibold : .regular))
                        .foregroundStyle(step == currentStep ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var contentCard: some View {
        PreferenceCard(step.title, detail: step.subtitle, icon: step.icon) {
            Group {
                switch step {
                case .welcome:
                    welcomeStep
                case .microphone:
                    microphoneStep
                case .accessibility:
                    accessibilityStep
                case .shortcuts:
                    shortcutsStep
                case .ready:
                    readyStep
                }
            }
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Whispur keeps capture, cleanup, and paste in one pass. This short setup makes sure the menu bar app is ready before your first dictation.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                PreferenceBadge(
                    title: appState.isSelectedSTTConfigured ? "\(appState.selectedSTT.displayName) ready" : "\(appState.selectedSTT.displayName) needs setup",
                    tone: appState.isSelectedSTTConfigured ? .good : .warning
                )
                PreferenceBadge(
                    title: appState.showSetupGuide ? "Guide available" : "Guide hidden",
                    tone: .neutral
                )
            }
        }
    }

    private var microphoneStep: some View {
        VStack(spacing: 10) {
            SetupChecklistRow(
                title: "Grant microphone access",
                detail: appState.microphoneAccessGranted
                    ? "Whispur can capture speech from your active input device."
                    : "Allow microphone access so Whispur can record your voice.",
                isComplete: appState.microphoneAccessGranted,
                actionTitle: appState.microphoneAccessGranted ? "Open Settings" : "Allow",
                action: appState.microphoneAccessGranted ? appState.openMicrophoneSettings : appState.requestMicrophoneAccess
            )

            Text("If the system prompt was dismissed earlier, use Open Settings and enable Whispur manually in Privacy & Security > Microphone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityStep: some View {
        VStack(spacing: 10) {
            SetupChecklistRow(
                title: "Enable accessibility access",
                detail: appState.hotkeyManager.isAccessibilityGranted
                    ? "Global shortcuts and paste-back are available."
                    : "Whispur needs accessibility access for global shortcuts and text insertion.",
                isComplete: appState.hotkeyManager.isAccessibilityGranted,
                actionTitle: appState.hotkeyManager.isAccessibilityGranted ? "Open Settings" : "Grant Access",
                action: appState.hotkeyManager.isAccessibilityGranted ? appState.openAccessibilitySettings : appState.requestAccessibilityAccess
            )

            Text("macOS may keep System Settings in front while you approve access. Return here after the toggle is enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut.menuTitle)")
                ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
            }

            SetupChecklistRow(
                title: "Push to talk",
                detail: "Hold \(appState.holdShortcut.menuTitle) while speaking. Releasing the shortcut begins transcription immediately.",
                isComplete: true,
                actionTitle: nil,
                action: nil
            )

            SetupChecklistRow(
                title: "Latched recording",
                detail: appState.toggleShortcut == nil
                    ? "Toggle mode is currently off. You can add one later in Settings."
                    : "Press \(appState.toggleShortcut?.menuTitle ?? "") once to start and again to stop.",
                isComplete: true,
                actionTitle: "Open Settings",
                action: { openSettings(tab: .general) }
            )
        }
    }

    private var readyStep: some View {
        VStack(spacing: 10) {
            SetupChecklistRow(
                title: "Permissions",
                detail: appState.hasRequiredPermissions
                    ? "Microphone and accessibility access are both in place."
                    : "You can finish setup later, but Whispur won’t be seamless until both permissions are granted.",
                isComplete: appState.hasRequiredPermissions,
                actionTitle: appState.hasRequiredPermissions ? nil : "Open Setup Guide",
                action: appState.hasRequiredPermissions ? nil : { openSettings(tab: .setup) }
            )

            SetupChecklistRow(
                title: "Speech provider",
                detail: appState.isSelectedSTTConfigured
                    ? "\(appState.selectedSTT.displayName) is ready for dictation."
                    : "The selected speech provider still needs credentials in Settings.",
                isComplete: appState.isSelectedSTTConfigured,
                actionTitle: appState.isSelectedSTTConfigured ? nil : "Providers",
                action: appState.isSelectedSTTConfigured ? nil : { openSettings(tab: .providers) }
            )

            Text("Finish here and start dictating from the menu bar. Setup, providers, and prompt tuning all stay available in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var summaryCard: some View {
        PreferenceCard(
            "Current Status",
            detail: "The same setup state shown here also appears in the Settings setup guide.",
            icon: "checklist"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: appState.setupProgress)
                    .tint(.orange)

                HStack(spacing: 10) {
                    PreferenceBadge(
                        title: "\(appState.setupCompletedCount) of \(appState.setupItemCount) complete",
                        tone: appState.isReadyForDailyUse ? .good : .warning
                    )
                    PreferenceBadge(
                        title: appState.recordingSummary,
                        tone: .neutral
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Back") {
                guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
                step = previous
            }
            .disabled(step == .welcome)

            Spacer()

            if step != .ready {
                Button(step == .welcome ? "Begin Setup" : "Continue") {
                    guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
                    step = next
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Open Settings") {
                    openSettings(tab: .setup)
                }
                .buttonStyle(.bordered)

                Button("Start Using Whispur") {
                    appState.markOnboardingCompleted()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private func openSettings(tab: SettingsTab) {
        appState.markOnboardingCompleted()
        NotificationCenter.default.post(name: .whispurOpenSettings, object: tab.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}
