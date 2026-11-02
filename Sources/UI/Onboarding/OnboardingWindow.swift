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
        window.isMovableByWindowBackground = true
        // Onboarding is always the midnight brand stage, whatever the system
        // appearance: the dark token values are the midnight palette.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(sophiieHex: 0x140934)
        window.isReleasedWhenClosed = false
        window.setContentSize(OnboardingWindow.size)
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

/// First-run onboarding: one thing per screen on the midnight brand stage.
/// A large symbol, one headline, one sentence and one primary action; a
/// thin progress bar on top and Back / Continue underneath.
struct OnboardingWindow: View {
    private typealias Palette = SophiieTheme.Palette

    static let size = NSSize(width: 640, height: 520)

    @ObservedObject var appState: AppState
    let dismiss: () -> Void

    @State private var step: OnboardingStep
    /// Which way the last step change went, for the slide direction.
    @State private var movingForward = true
    /// Mirrors of the permission state. The hotkey manager and the guide
    /// publish on their own, so the window listens to them directly.
    @State private var accessibilityGranted: Bool
    @State private var guidedPermission: GuidedPermission?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            topBar

            ZStack {
                screen(for: step)
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.midnight)
        .foregroundStyle(Palette.ink)
        .tint(Palette.accent)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onReceive(appState.hotkeyManager.$isAccessibilityGranted) { granted in
            let wasGranted = accessibilityGranted
            accessibilityGranted = granted
            if granted, !wasGranted { advance(afterGranting: .accessibility) }
        }
        .onReceive(appState.$microphoneAccessGranted.removeDuplicates().dropFirst()) { granted in
            if granted { advance(afterGranting: .microphone) }
        }
        .onReceive(appState.permissionGuide.$activePermission) { guidedPermission = $0 }
    }

    // MARK: - Navigation

    private func go(to target: OnboardingStep) {
        movingForward = target.rawValue > step.rawValue
        withSophiieAnimation(SophiieTheme.Motion.medium) { step = target }
    }

    /// A permission just turned on while its step shows: let the check
    /// register, then move on.
    private func advance(afterGranting permission: GuidedPermission) {
        guard let next = OnboardingFlow.stepAfterGrant(of: permission, showing: step) else { return }
        let granted = step
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.grantedBeat) {
            guard step == granted else { return }
            go(to: next)
        }
    }

    private var stepTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let insertion: Edge = movingForward ? .trailing : .leading
        let removal: Edge = movingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .offset(x: insertion == .trailing ? 40 : -40).combined(with: .opacity),
            removal: .offset(x: removal == .leading ? -40 : 40).combined(with: .opacity)
        )
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 16) {
            ProgressTrack(value: OnboardingFlow.progress(of: step))
                .frame(maxWidth: 220)
                .sophiieAnimation(SophiieTheme.Motion.medium, value: step)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")

            Spacer(minLength: 0)

            if !step.isFirst, !step.isLast {
                Button("Finish later", action: finishLater)
                    .buttonStyle(.plain)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
                    .help("Close setup. Anything you skip stays in Settings → Get Started.")
            }
        }
        .padding(.leading, 96) // clear of the traffic lights
        .padding(.trailing, 24)
        .frame(height: 52)
    }

    private var footer: some View {
        HStack {
            if !step.isFirst {
                Button("Back") {
                    guard let previous = OnboardingFlow.previous(before: step) else { return }
                    go(to: previous)
                }
                .buttonStyle(.sophiieSecondary)
                .controlSize(.large)
            }

            Spacer()

            footerAction
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    /// Continue is the primary action unless the screen has its own (a
    /// permission still to grant), in which case it steps back to a quiet
    /// "Skip for now".
    @ViewBuilder
    private var footerAction: some View {
        switch step {
        case .welcome:
            Button("Get Started") { go(to: .microphone) }
                .buttonStyle(.sophiiePrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .ready:
            Button("Start Using Whispur") {
                appState.markOnboardingCompleted()
                dismiss()
            }
            .buttonStyle(.sophiiePrimary)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        default:
            if hasOwnPrimaryAction(step) {
                Button("Skip for now", action: continueOn)
                    .buttonStyle(.sophiieSecondary)
                    .controlSize(.large)
            } else {
                Button("Continue", action: continueOn)
                    .buttonStyle(.sophiiePrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func continueOn() {
        guard let next = OnboardingFlow.next(after: step) else { return }
        go(to: next)
    }

    private func hasOwnPrimaryAction(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: return !appState.microphoneAccessGranted
        case .accessibility: return !accessibilityGranted
        default: return false
        }
    }

    private func finishLater() {
        appState.markOnboardingCompleted()
        dismiss()
    }

    private func openSettings(tab: SettingsTab) {
        appState.markOnboardingCompleted()
        NotificationCenter.default.post(name: .whispurOpenSettings, object: tab.rawValue)
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }

    // MARK: - Screens

    @ViewBuilder
    private func screen(for step: OnboardingStep) -> some View {
        switch step {
        case .welcome: welcomeScreen
        case .microphone: microphoneScreen
        case .accessibility: accessibilityScreen
        case .shortcuts: shortcutsScreen
        case .ready: readyScreen
        }
    }

    private var welcomeScreen: some View {
        OnboardingScreen(
            hero: { AppIconHero() },
            title: "Talk instead of typing",
            message: "Hold a key, say what you mean, and Whispur types it wherever your cursor is."
        ) {
            parakeetDownloadLine
        }
    }

    private var microphoneScreen: some View {
        OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.microphone.symbol, isDone: appState.microphoneAccessGranted) },
            title: appState.microphoneAccessGranted ? "Whispur can hear you" : "Let Whispur hear you",
            message: microphoneMessage
        ) {
            if appState.microphoneAccessGranted {
                GrantedLabel(text: "Microphone on")
            } else {
                Button(microphoneActionTitle, action: appState.requestMicrophoneAccess)
                    .buttonStyle(.sophiiePrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var microphoneMessage: String {
        if appState.microphoneAccessGranted { return "Your voice only leaves the mic while you hold the shortcut." }
        if guidedPermission == .microphone { return "Switch on Whispur in the Microphone list. This moves on by itself." }
        if appState.microphoneAccessRefused { return "Microphone access is off. Switch it back on in System Settings." }
        return "Whispur listens only while you hold the shortcut."
    }

    private var microphoneActionTitle: String {
        if guidedPermission == .microphone { return "Show Guide Again" }
        return appState.microphoneAccessRefused ? "Open System Settings" : "Allow Microphone"
    }

    private var accessibilityScreen: some View {
        OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.accessibility.symbol, isDone: accessibilityGranted) },
            title: accessibilityGranted ? "Whispur can type for you" : "Let Whispur type for you",
            message: accessibilityMessage
        ) {
            if accessibilityGranted {
                GrantedLabel(text: "Accessibility on")
            } else {
                Button(guidedPermission == .accessibility ? "Show Guide Again" : "Open System Settings",
                       action: appState.requestAccessibilityAccess)
                    .buttonStyle(.sophiiePrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var accessibilityMessage: String {
        if accessibilityGranted { return "Your shortcut works in every app, and text lands where you're typing." }
        if guidedPermission == .accessibility {
            return "Drag Whispur into the \(GuidedPermission.accessibility.listName) list, then switch it on. This moves on by itself."
        }
        return "Accessibility lets your shortcut work in any app and paste text where you're typing."
    }

    private var shortcutsScreen: some View {
        OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.shortcuts.symbol, isDone: false) },
            title: "Your shortcut",
            message: shortcutMessage
        ) {
            VStack(spacing: 14) {
                if let hold = appState.effectiveHoldShortcut {
                    KeycapCombo(keys: hold.keycapLabels, join: hold.isDoublePress ? .sequence : .chord)
                        .scaleEffect(1.25)
                        .padding(.vertical, 4)
                }
                Button("More options in Settings") { openSettings(tab: .dictation) }
                    .buttonStyle(.plain)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.interactive)
            }
        }
    }

    private var shortcutMessage: String {
        guard let hold = appState.effectiveHoldShortcut else {
            return "No hold shortcut is set. Start from the menu bar, or add one in Settings."
        }
        if appState.shortcutStyle == .tapOrHold {
            return "Hold \(hold.menuTitle) while you speak, or tap it to keep recording hands-free."
        }
        return "Hold \(hold.menuTitle) while you speak. Let go and the text appears."
    }

    private var readyScreen: some View {
        let missing = OnboardingFlow.firstMissingPermissionStep(
            microphone: appState.microphoneAccessGranted,
            accessibility: accessibilityGranted
        )
        let speechReady = appState.isSelectedSTTConfigured
        let allSet = missing == nil && speechReady
        return OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.ready.symbol, isDone: allSet) },
            title: allSet ? "You're all set" : "Almost there",
            message: readyMessage(missing: missing, speechReady: speechReady)
        ) {
            VStack(spacing: 12) {
                if let missing {
                    Button(missing == .microphone ? "Allow Microphone" : "Allow Accessibility") { go(to: missing) }
                        .buttonStyle(.sophiieSecondary)
                        .controlSize(.large)
                } else if !speechReady {
                    Button("Add a Speech Provider Key") { openSettings(tab: .providers) }
                        .buttonStyle(.sophiieSecondary)
                        .controlSize(.large)
                }
                parakeetDownloadLine
                Button("Open Settings") { openSettings(tab: .getStarted) }
                    .buttonStyle(.plain)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.interactive)
            }
        }
    }

    private func readyMessage(missing: OnboardingStep?, speechReady: Bool) -> String {
        if let missing {
            return "Whispur needs \(missingPermissionName(missing)) before dictation works. You can also finish this later in Settings."
        }
        if !speechReady {
            return "\(appState.selectedSTT.displayName) needs an API key. Add one in Settings, or switch to on-device speech."
        }
        if let hold = appState.effectiveHoldShortcut {
            return "Hold \(hold.menuTitle) in any app and start talking. Whispur lives in your menu bar."
        }
        return "Start dictating from the menu bar. Whispur lives up there."
    }

    private func missingPermissionName(_ step: OnboardingStep?) -> String {
        step == .microphone ? "microphone access" : "accessibility access"
    }

    /// The model download's progress while Apple fills in for Parakeet.
    @ViewBuilder
    private var parakeetDownloadLine: some View {
        if appState.isUsingSpeechFallback {
            ParakeetDownloadStatusLine(manager: appState.parakeetModel)
                .frame(maxWidth: 380)
        }
    }
}

// MARK: - Building blocks

/// The centred column every screen uses: hero, headline, one sentence,
/// then the screen's action.
private struct OnboardingScreen<Hero: View, Action: View>: View {
    let hero: Hero
    let title: String
    let message: String
    let action: Action

    init(
        @ViewBuilder hero: () -> Hero,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.hero = hero()
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)
            hero
                .padding(.bottom, 28)
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .tracking(SophiieTheme.Typography.displayTracking)
                .foregroundStyle(SophiieTheme.Palette.ink)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(SophiieTheme.Palette.inkSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .padding(.top, 10)
            action
                .padding(.top, 28)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A large symbol on a soft sky glow; turns into a check once its step is
/// done.
private struct SymbolHero: View {
    let symbol: String
    let isDone: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [SophiieTheme.Palette.sky.opacity(0.28), SophiieTheme.Palette.sky.opacity(0)],
                        center: .center,
                        startRadius: 8,
                        endRadius: 78
                    )
                )
                .frame(width: 156, height: 156)
            Circle()
                .fill(SophiieTheme.Palette.OnDark.raised)
                .overlay(Circle().strokeBorder(SophiieTheme.Palette.OnDark.hairline, lineWidth: 1))
                .frame(width: 92, height: 92)
            Image(systemName: isDone ? "checkmark" : symbol)
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(isDone ? SophiieTheme.Palette.success : SophiieTheme.Palette.sky)
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 156, height: 120)
        .sophiieAnimation(value: isDone)
        .accessibilityHidden(true)
    }
}

/// The app icon on the same glow, for the welcome screen.
private struct AppIconHero: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [SophiieTheme.Palette.sky.opacity(0.30), SophiieTheme.Palette.sky.opacity(0)],
                        center: .center,
                        startRadius: 10,
                        endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)
        }
        .frame(width: 180, height: 132)
        .accessibilityHidden(true)
    }
}

/// "✓ Microphone on" under a granted permission.
private struct GrantedLabel: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(SophiieTheme.Typography.label)
            .foregroundStyle(SophiieTheme.Palette.success)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(SophiieTheme.Palette.success.opacity(0.12), in: Capsule())
    }
}

/// The thin progress bar in the top strip.
private struct ProgressTrack: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(SophiieTheme.Palette.track)
                Capsule()
                    .fill(SophiieTheme.Palette.highlight)
                    .frame(width: max(4, proxy.size.width * value))
            }
        }
        .frame(height: 4)
    }
}
