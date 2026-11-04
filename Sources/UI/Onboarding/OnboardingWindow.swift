import AppKit
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void

    init(appState: AppState, initialStep: OnboardingStep = .welcome, onClose: @escaping () -> Void) {
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
        window.identifier = OnboardingWindow.windowIdentifier
        window.setContentSize(OnboardingWindow.size)
        window.center()

        super.init(window: window)

        hostingController.rootView = AnyView(
            OnboardingWindow(appState: appState, initialStep: initialStep) { [weak self] in
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
    /// Granted, still finishing, on, or waiting on a restart.
    @State private var accessibility: AccessibilityStatus
    @State private var guidedPermission: GuidedPermission?
    /// The "Try it" field and whether a real dictation has landed in it.
    @StateObject private var tryIt = TryItSession()
    /// This run's steps, fixed when the window opens.
    private let plan: OnboardingPlan
    /// Speech setup is framed around the Parakeet download (see
    /// `OnboardingSpeechSetup`); fixed when the window opens.
    private let usesParakeetDownload: Bool
    /// A fixed moment of the welcome story, for renders.
    private let storyTime: TimeInterval?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a fresh grant's check shows before the step moves on.
    static let grantedBeat: TimeInterval = 0.7

    init(
        appState: AppState,
        initialStep: OnboardingStep = .welcome,
        storyTime: TimeInterval? = nil,
        usesParakeetDownload usesDownloadOverride: Bool? = nil,
        dismiss: @escaping () -> Void
    ) {
        self.appState = appState
        self.dismiss = dismiss
        self.storyTime = storyTime
        let usesDownload = usesDownloadOverride ?? OnboardingSpeechSetup.usesParakeetDownload(
            selected: appState.selectedSTT,
            parakeetSupported: ParakeetSupport.isSupported,
            modelInstalled: appState.parakeetModel.isInstalled
        )
        usesParakeetDownload = usesDownload
        plan = OnboardingPlan(asksLanguages: OnboardingSpeechSetup.asksLanguages(
            usesParakeetDownload: usesDownload,
            languagesStored: usesDownloadOverride != nil
                || UserDefaults.standard.object(forKey: AppState.spokenLanguagesKey) != nil
        ))
        _step = State(initialValue: initialStep)
        _accessibility = State(initialValue: appState.hotkeyManager.accessibilityStatus)
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
        .onReceive(appState.hotkeyManager.accessibilityStatusPublisher) { status in
            let wasOn = accessibility == .on
            accessibility = status
            // Only a working shortcut moves on: a grant macOS hasn't honoured
            // yet stays here to finish, or to offer the restart.
            if status == .on, !wasOn { advance(afterGranting: .accessibility) }
        }
        .onReceive(appState.$microphoneAccessGranted.removeDuplicates().dropFirst()) { granted in
            if granted { advance(afterGranting: .microphone) }
        }
        .onReceive(appState.permissionGuide.$activePermission) { guidedPermission = $0 }
        .onAppear {
            routeDictationIntoTryIt(step == .tryIt)
            // The model starts downloading as soon as setup opens, so it has
            // the whole walkthrough to arrive.
            if usesParakeetDownload { appState.startParakeetDownloadForOnboarding() }
        }
        .onChange(of: step) { _, newStep in routeDictationIntoTryIt(newStep == .tryIt) }
        .onDisappear { routeDictationIntoTryIt(false) }
    }

    // MARK: - Navigation

    private func go(to target: OnboardingStep) {
        movingForward = target.rawValue > step.rawValue
        withSophiieAnimation(SophiieTheme.Motion.medium) { step = target }
    }

    /// A permission just turned on while its step shows: let the check
    /// register, then move on.
    private func advance(afterGranting permission: GuidedPermission) {
        guard let next = OnboardingFlow.stepAfterGrant(of: permission, showing: step, in: plan) else { return }
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
            ProgressTrack(value: plan.progress(of: step))
                .frame(maxWidth: 220)
                .sophiieAnimation(SophiieTheme.Motion.medium, value: step)
                .accessibilityLabel("Step \(plan.number(of: step)) of \(plan.steps.count)")

            Spacer(minLength: 0)

            if OnboardingSpeechSetup.showsDownloadPill(on: step, plan: plan, usesParakeetDownload: usesParakeetDownload) {
                OnboardingDownloadPillView(model: appState.parakeetModel) {
                    appState.parakeetModel.download()
                }
                .transition(.opacity)
            }

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
                    guard let previous = plan.previous(before: step) else { return }
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
            Button("Get Started", action: continueOn)
                .buttonStyle(.sophiiePrimary)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .ready:
            // Opens Settings, so Whispur stays open (and in the Dock)
            // instead of vanishing into the menu bar.
            Button("Start Using Whispur") {
                openSettings(tab: OnboardingFlow.settingsTabAfterSetup(allSet: readyIsAllSet))
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
        guard let next = plan.next(after: step) else { return }
        go(to: next)
    }

    private func hasOwnPrimaryAction(_ step: OnboardingStep) -> Bool {
        switch step {
        case .microphone: return !appState.microphoneAccessGranted
        case .tryIt: return !tryIt.succeeded
        case .accessibility: return accessibility != .on
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
        case .languages: languagesScreen
        case .microphone: microphoneScreen
        case .accessibility: accessibilityScreen
        case .shortcuts: shortcutsScreen
        case .tryIt: tryItScreen
        case .ready: readyScreen
        }
    }

    private var welcomeScreen: some View {
        OnboardingScreen(
            hero: { WelcomeStoryView(fixedTime: storyTime) },
            title: "Talk instead of typing",
            message: "Hold a key, say what you mean, and Whispur types it wherever your cursor is."
        ) {
            EmptyView()
        }
    }

    private var languagesScreen: some View {
        OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.languages.symbol, isDone: false) },
            title: "Which languages do you speak?",
            message: usesParakeetDownload
                ? "Whispur's on-device speech model has started downloading. Pick every language you dictate in."
                : "Pick every language you dictate in. You can change this any time in Settings."
        ) {
            OnboardingLanguagePicker(appState: appState, provider: usesParakeetDownload ? .parakeet : appState.selectedSTT)
        }
        .onAppear {
            // Preselect from the system language the first time only.
            guard UserDefaults.standard.object(forKey: AppState.spokenLanguagesKey) == nil else { return }
            appState.sttLanguageSelection = OnboardingSpeechSetup.defaultLanguages(
                systemLocaleIdentifier: Locale.current.identifier
            )
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
            hero: { SymbolHero(symbol: accessibilitySymbol, isDone: accessibility == .on) },
            title: accessibilityTitle,
            message: accessibilityMessage
        ) {
            switch accessibility {
            case .on:
                GrantedLabel(text: "Accessibility on")
            case .finishing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Turning on your shortcut\u{2026}")
                        .font(SophiieTheme.Typography.label)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(height: 32)
            case .needsRestart:
                restartButton
            case .off:
                Button(guidedPermission == .accessibility ? "Show Guide Again" : "Open System Settings",
                       action: appState.requestAccessibilityAccess)
                    .buttonStyle(.sophiiePrimary)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var accessibilitySymbol: String {
        accessibility == .needsRestart ? "arrow.clockwise" : OnboardingStep.accessibility.symbol
    }

    private var accessibilityTitle: String {
        switch accessibility {
        case .on: return "Whispur can type for you"
        case .needsRestart: return Self.restartTitle
        case .off, .finishing: return "Let Whispur type for you"
        }
    }

    private var accessibilityMessage: String {
        switch accessibility {
        case .on:
            return "Your shortcut works in every app, and text lands where you're typing."
        case .finishing:
            return "Accessibility is on. Whispur is hooking up your shortcut."
        case .needsRestart:
            return Self.restartMessage
        case .off:
            if guidedPermission == .accessibility {
                return "Drag Whispur into the \(GuidedPermission.accessibility.listName) list, then switch it on. This moves on by itself."
            }
            return "Accessibility lets your shortcut work in any app and paste text where you're typing."
        }
    }

    static let restartTitle = "Whispur needs a quick restart to finish"
    static let restartMessage = "macOS has switched Accessibility on, but Whispur only sees it after a restart. Setup picks up where you left off."

    /// Relaunches Whispur; onboarding reopens past the accessibility step.
    private var restartButton: some View {
        Button("Restart Whispur") {
            appState.restartWhispur(resumingOnboardingAt: OnboardingFlow.resumeStep(afterRestartFrom: step))
        }
        .buttonStyle(.sophiiePrimary)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }

    private var shortcutsScreen: some View {
        let selected = appState.currentShortcutChoice
        return OnboardingScreen(
            hero: { EmptyView() },
            title: "Pick your shortcut",
            message: shortcutMessage(selected)
        ) {
            VStack(spacing: 16) {
                HStack(spacing: 12) {
                    ForEach(OnboardingShortcutChoice.allCases) { choice in
                        ShortcutChoiceCard(choice: choice, isSelected: selected == choice) {
                            withSophiieAnimation { appState.applyShortcutChoice(choice) }
                        }
                    }
                }

                if selected?.usesFn == true {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Label(Self.globeKeyHint, systemImage: "globe")
                            .font(SophiieTheme.Typography.caption)
                            .foregroundStyle(Palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Open Keyboard Settings", action: appState.openKeyboardSettings)
                            .buttonStyle(.sophiieSecondary)
                            .controlSize(.small)
                    }
                    .frame(maxWidth: 540)
                    .transition(.opacity)
                }

                Button("More options in Settings") { openSettings(tab: .dictation) }
                    .buttonStyle(.plain)
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.interactive)
            }
        }
    }

    static let globeKeyHint = "So quick Fn taps don't open the Emoji panel, set \"Press \u{1F310} key to\" to Do Nothing in System Settings → Keyboard."

    private func shortcutMessage(_ selected: OnboardingShortcutChoice?) -> String {
        if selected == nil {
            return "Right now: \(appState.shortcutSummary). Pick one below to switch, or keep yours."
        }
        return "Choose the key you'll hold while you talk. You can change it any time."
    }

    // MARK: Try it

    /// While "Try it" shows, a dictation finished with this window in front
    /// goes straight into the field: no clipboard, no synthetic Cmd+V into
    /// Whispur itself. Anywhere else it pastes as usual.
    private func routeDictationIntoTryIt(_ active: Bool) {
        guard active else {
            appState.pipeline.deliverInsteadOfPasting = nil
            return
        }
        appState.pipeline.deliverInsteadOfPasting = { [weak tryIt] text in
            guard let tryIt, NSApp.isActive,
                  NSApp.keyWindow?.identifier == OnboardingWindow.windowIdentifier else { return false }
            withSophiieAnimation { tryIt.receive(text) }
            return true
        }
    }

    static let windowIdentifier = NSUserInterfaceItemIdentifier("ai.sophiie.whispur.onboarding")

    private var tryItScreen: some View {
        let blocker = TryItBlocker.first(
            microphone: appState.microphoneAccessGranted,
            accessibility: accessibility.isGranted,
            needsRestart: accessibility == .needsRestart,
            hasShortcut: appState.hasAnyShortcut,
            speechConfigured: appState.isSelectedSTTConfigured
        )
        return OnboardingScreen(
            hero: { SymbolHero(symbol: OnboardingStep.tryIt.symbol, isDone: tryIt.succeeded) },
            title: tryIt.succeeded ? "That's it" : "Try it",
            message: tryItMessage(blocker)
        ) {
            if let blocker {
                tryItBlockerAction(blocker)
            } else {
                TryItPanel(pipeline: appState.pipeline, session: tryIt, prompt: Self.tryItPhrase)
            }
        }
    }

    static let tryItPhrase = "Hi, I'm testing Whispur"

    private func tryItMessage(_ blocker: TryItBlocker?) -> String {
        switch blocker {
        case .microphone:
            return "Whispur needs microphone access before it can hear you."
        case .accessibility:
            return "Whispur needs accessibility access before your shortcut works."
        case .restart:
            return "Accessibility is on, but your shortcut only works after Whispur restarts."
        case .shortcut:
            return "There's no dictation shortcut yet. Pick one first."
        case .speechProvider:
            return "\(appState.selectedSTT.displayName) needs an API key before it can transcribe."
        case nil:
            break
        }
        if tryIt.succeeded {
            return "Whispur types wherever your cursor is, in any app."
        }
        if appState.shortcutStyle == .separate, appState.holdShortcut == nil, let toggle = appState.toggleShortcut {
            return "\(toggle.toggleStartPhrase), say \u{201C}\(Self.tryItPhrase)\u{201D}, then \(toggle.toggleStopPhrase)."
        }
        let key = appState.effectiveHoldShortcut?.menuTitle ?? "your shortcut"
        return "Hold \(key) and say \u{201C}\(Self.tryItPhrase)\u{201D}. Let go to see it land below."
    }

    @ViewBuilder
    private func tryItBlockerAction(_ blocker: TryItBlocker) -> some View {
        if blocker == .restart {
            restartButton
        } else if let fix = blocker.step {
            Button(fix == .shortcuts ? "Pick a Shortcut" : "Allow \(fix.title)") { go(to: fix) }
                .buttonStyle(.sophiiePrimary)
                .controlSize(.large)
        } else {
            Button("Open Providers") { openSettings(tab: .providers) }
                .buttonStyle(.sophiiePrimary)
                .controlSize(.large)
        }
    }

    /// Both permissions working and speech ready: the Ready screen's
    /// "You're all set".
    private var readyIsAllSet: Bool {
        OnboardingFlow.firstMissingPermissionStep(
            microphone: appState.microphoneAccessGranted,
            accessibility: accessibility.isGranted
        ) == nil && accessibility != .needsRestart && appState.isSelectedSTTConfigured
    }

    private var readyScreen: some View {
        let missing = OnboardingFlow.firstMissingPermissionStep(
            microphone: appState.microphoneAccessGranted,
            accessibility: accessibility.isGranted
        )
        let needsRestart = missing == nil && accessibility == .needsRestart
        let speechReady = appState.isSelectedSTTConfigured
        let allSet = readyIsAllSet
        return OnboardingScreen(
            hero: {
                if allSet {
                    OnboardingMenuBarPreview(caption: readyCaption)
                        .frame(height: 120)
                } else {
                    SymbolHero(symbol: needsRestart ? "arrow.clockwise" : OnboardingStep.ready.symbol, isDone: false)
                }
            },
            title: allSet ? "You're all set" : (needsRestart ? Self.restartTitle : "Almost there"),
            message: needsRestart ? Self.restartMessage : readyMessage(missing: missing, speechReady: speechReady)
        ) {
            VStack(spacing: 12) {
                if let missing {
                    Button(missing == .microphone ? "Allow Microphone" : "Allow Accessibility") { go(to: missing) }
                        .buttonStyle(.sophiieSecondary)
                        .controlSize(.large)
                } else if needsRestart {
                    restartButton
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

    /// The one line to remember, under the menu bar preview.
    private var readyCaption: String {
        appState.talkAnywhereHint
    }

    private func readyMessage(missing: OnboardingStep?, speechReady: Bool) -> String {
        if let missing {
            return "Whispur needs \(missingPermissionName(missing)) before dictation works. You can also finish this later in Settings."
        }
        if !speechReady {
            return "\(appState.selectedSTT.displayName) needs an API key. Add one in Settings, or switch to on-device speech."
        }
        return "Whispur waits up in your menu bar. Click it any time for settings and your recent dictations."
    }

    private func missingPermissionName(_ step: OnboardingStep?) -> String {
        step == .microphone ? "microphone access" : "accessibility access"
    }

    /// The model download's progress while Apple fills in for Parakeet, for
    /// anyone the top-bar pill doesn't already tell.
    @ViewBuilder
    private var parakeetDownloadLine: some View {
        if appState.isUsingSpeechFallback,
           !OnboardingSpeechSetup.showsDownloadPill(on: step, plan: plan, usesParakeetDownload: usesParakeetDownload) {
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

/// One preset on the Shortcuts screen: the key, its name and one line.
private struct ShortcutChoiceCard: View {
    private typealias Palette = SophiieTheme.Palette

    let choice: OnboardingShortcutChoice
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 12) {
                KeycapCombo(keys: choice.binding.keycapLabels)
                    .frame(height: 30)
                VStack(spacing: 4) {
                    Text(choice.title)
                        .font(SophiieTheme.Typography.label)
                        .foregroundStyle(Palette.ink)
                    Text(choice.detail)
                        .font(SophiieTheme.Typography.caption)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 12)
            .frame(width: 168, height: 132)
            .background(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                    .fill(isSelected ? Palette.surfaceSelected : (isHovering ? Palette.surfaceSubtle : Palette.OnDark.raised.opacity(0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                    .strokeBorder(isSelected ? Palette.highlight : Palette.hairline, lineWidth: isSelected ? 2 : 1)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Palette.highlight)
                        .padding(8)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .sophiieAnimation(value: isSelected)
        .sophiieAnimation(value: isHovering)
        .accessibilityLabel("\(choice.title). \(choice.detail)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The "Try it" field's state, shared with the pipeline's delivery hook.
@MainActor
final class TryItSession: ObservableObject {
    @Published var text = ""
    @Published private(set) var succeeded = false

    func receive(_ dictated: String) {
        let trimmed = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = text.isEmpty ? trimmed : text + " " + trimmed
        succeeded = true
    }
}

/// The field the user dictates into, with the pipeline's live state above
/// it and a check once text has landed.
private struct TryItPanel: View {
    private typealias Palette = SophiieTheme.Palette

    @ObservedObject var pipeline: DictationPipeline
    @ObservedObject var session: TryItSession
    let prompt: String

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 12) {
            TextField(prompt, text: $session.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .lineLimit(3, reservesSpace: true)
                .focused($focused)
                .padding(14)
                .frame(width: 440)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SophiieTheme.Radius.card, style: .continuous)
                        .strokeBorder(session.succeeded ? Palette.success : (focused ? Palette.brand : Palette.controlBorder),
                                      lineWidth: session.succeeded || focused ? 2 : 1)
                )
                .accessibilityLabel("Try it field")

            status
                .frame(height: 22)
        }
        .onAppear { focused = true }
    }

    @ViewBuilder
    private var status: some View {
        if session.succeeded, pipeline.phase == .idle || isDone {
            Label("It works", systemImage: "checkmark.circle.fill")
                .font(SophiieTheme.Typography.label)
                .foregroundStyle(Palette.success)
        } else {
            switch pipeline.phase {
            case .recording:
                Label("Listening\u{2026}", systemImage: "waveform")
                    .font(SophiieTheme.Typography.label)
                    .foregroundStyle(Palette.highlight)
            case .starting, .requestingMicrophonePermission:
                Text("Starting\u{2026}")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
            case .normalizingAudio, .transcribing, .cleaningTranscript, .pasting:
                Label("Transcribing\u{2026}", systemImage: "ellipsis")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
            case let .error(message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.warning)
                    .lineLimit(1)
                    .truncationMode(.tail)
            default:
                Text("The text lands here, not in another app.")
                    .font(SophiieTheme.Typography.caption)
                    .foregroundStyle(Palette.muted)
            }
        }
    }

    private var isDone: Bool {
        if case .done = pipeline.phase { return true }
        return false
    }
}
