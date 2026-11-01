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

enum OnboardingStep: Int, CaseIterable, Identifiable {
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

    @State private var step: OnboardingStep
    /// Mirrors of the permission state. The hotkey manager and the guide
    /// publish on their own, so the window listens to them directly.
    @State private var accessibilityGranted: Bool
    @State private var guidedPermission: GuidedPermission?

    /// How long a fresh grant's check shows before the step moves on.
    static let grantedBeat: TimeInterval = 0.7

    init(appState: AppState, initialStep: OnboardingStep = .welcome, dismiss: @escaping () -> Void) {
        self.appState = appState
        self.dismiss = dismiss
        _step = State(initialValue: initialStep)
        _accessibilityGranted = State(initialValue: appState.hotkeyManager.isAccessibilityGranted)
        _guidedPermission = State(initialValue: appState.permissionGuide.activePermission)
    }

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
        .background(SophiieTheme.Palette.surfaceWarm)
        .foregroundStyle(SophiieTheme.Palette.ink)
        .tint(SophiieTheme.Palette.accent)
        .onReceive(appState.hotkeyManager.$isAccessibilityGranted) { granted in
            let wasGranted = accessibilityGranted
            accessibilityGranted = granted
            if granted, !wasGranted { advance(after: .accessibility) }
        }
        .onReceive(appState.$microphoneAccessGranted.removeDuplicates().dropFirst()) { granted in
            if granted { advance(after: .microphone) }
        }
        .onReceive(appState.permissionGuide.$activePermission) { guidedPermission = $0 }
    }

    /// A permission just turned on while its step shows: let the check
    /// register, then move on.
    private func advance(after granted: OnboardingStep) {
        guard step == granted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grantedBeat) {
            guard step == granted, let next = OnboardingStep(rawValue: granted.rawValue + 1) else { return }
            withSophiieAnimation { step = next }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Whispur")
                    .font(.title2.weight(.semibold))
                    .tracking(SophiieTheme.Typography.titleTracking)
                    .foregroundStyle(SophiieTheme.Palette.ink)
                Text(step.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(SophiieTheme.Palette.muted)
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
                        .background(stepFill(for: currentStep), in: Circle())
                        .foregroundStyle(stepForeground(for: currentStep))

                    Text(currentStep.title)
                        .font(.caption.weight(step == currentStep ? .semibold : .regular))
                        .foregroundStyle(step == currentStep ? SophiieTheme.Palette.ink : SophiieTheme.Palette.muted)
                }
                .frame(maxWidth: .infinity)
                .sophiieAnimation(value: step)
            }
        }
    }

    private func stepFill(for candidate: OnboardingStep) -> Color {
        if candidate == step { return SophiieTheme.Palette.brand }
        if candidate.rawValue < step.rawValue { return SophiieTheme.Palette.surfaceSelected }
        return SophiieTheme.Palette.surfaceSubtle
    }

    private func stepForeground(for candidate: OnboardingStep) -> Color {
        if candidate == step { return SophiieTheme.Palette.onBrand }
        if candidate.rawValue < step.rawValue { return SophiieTheme.Palette.ink }
        return SophiieTheme.Palette.muted
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
                .foregroundStyle(SophiieTheme.Palette.muted)

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
                detail: microphoneDetail,
                isComplete: appState.microphoneAccessGranted,
                actionTitle: microphoneActionTitle,
                action: appState.microphoneAccessGranted ? appState.openMicrophoneSettings : appState.requestMicrophoneAccess
            )

            Text(appState.microphoneAccessRefused && !appState.microphoneAccessGranted
                ? "Whispur opens System Settings with a guide beside it. Once the switch is on, this step moves on by itself."
                : "macOS asks once. If you said no earlier, Whispur takes you to the switch in System Settings.")
                .font(.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
        }
    }

    private var microphoneDetail: String {
        if appState.microphoneAccessGranted { return "Whispur can capture speech from your active input device." }
        if guidedPermission == .microphone { return "Waiting for you in System Settings. Switch on Whispur in the Microphone list." }
        if appState.microphoneAccessRefused { return "Microphone access was turned off. Switch it back on in System Settings." }
        return "Allow microphone access so Whispur can record your voice."
    }

    private var microphoneActionTitle: String {
        if appState.microphoneAccessGranted { return "Open Settings" }
        if guidedPermission == .microphone { return "Show Guide Again" }
        return appState.microphoneAccessRefused ? "Open Settings" : "Allow"
    }

    private var accessibilityStep: some View {
        VStack(spacing: 10) {
            SetupChecklistRow(
                title: "Enable accessibility access",
                detail: accessibilityDetail,
                isComplete: accessibilityGranted,
                actionTitle: accessibilityGranted ? "Open Settings" : (guidedPermission == .accessibility ? "Show Guide Again" : "Grant Access"),
                action: accessibilityGranted ? appState.openAccessibilitySettings : appState.requestAccessibilityAccess
            )

            Text("Whispur opens System Settings with a guide beside it. Drag Whispur into the list and switch it on; this step moves on by itself.")
                .font(.caption)
                .foregroundStyle(SophiieTheme.Palette.muted)
        }
    }

    private var accessibilityDetail: String {
        if accessibilityGranted { return "Global shortcuts and paste-back are available." }
        if guidedPermission == .accessibility {
            return "Waiting for you in System Settings. Drag Whispur into the \(GuidedPermission.accessibility.listName) list, then switch it on."
        }
        return "Whispur needs accessibility access for global shortcuts and text insertion."
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                if appState.shortcutStyle == .tapOrHold {
                    ShortcutSummaryBadge(title: "Tap or hold: \(appState.tapOrHoldShortcut.menuTitle)")
                } else {
                    ShortcutSummaryBadge(title: "Hold: \(appState.holdShortcut?.menuTitle ?? "Off")")
                    ShortcutSummaryBadge(title: "Toggle: \(appState.toggleShortcut?.menuTitle ?? "Off")")
                }
            }

            SetupChecklistRow(
                title: "Push to talk",
                detail: appState.effectiveHoldShortcut.map {
                    "Hold \($0.menuTitle) while speaking. Releasing the shortcut begins transcription immediately."
                } ?? "Hold to talk is off. You can add a shortcut later in Settings.",
                isComplete: true,
                actionTitle: nil,
                action: nil
            )

            SetupChecklistRow(
                title: "Latched recording",
                detail: appState.toggleShortcut == nil && appState.shortcutStyle == .separate
                    ? "Toggle mode is currently off. You can add one later in Settings."
                    : appState.toggleShortcutInstruction,
                isComplete: true,
                actionTitle: "Open Settings",
                action: { openSettings(tab: .dictation) }
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
                action: appState.hasRequiredPermissions ? nil : { openSettings(tab: .getStarted) }
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
                .foregroundStyle(SophiieTheme.Palette.muted)
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
            .buttonStyle(.sophiieSecondary)
            .disabled(step == .welcome)

            Spacer()

            if step != .ready {
                Button(step == .welcome ? "Begin Setup" : "Continue") {
                    guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
                    step = next
                }
                .buttonStyle(.sophiiePrimary)
            } else {
                Button("Open Settings") {
                    openSettings(tab: .getStarted)
                }
                .buttonStyle(.sophiieSecondary)

                Button("Start Using Whispur") {
                    appState.markOnboardingCompleted()
                    dismiss()
                }
                .buttonStyle(.sophiiePrimary)
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
