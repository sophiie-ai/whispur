import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Central application state used by the menu bar UI and settings window.
@MainActor
final class AppState: ObservableObject {
    @AppStorage("selectedSTT") var selectedSTT: STTProviderID = .apple
    /// Empty string = auto-detect; otherwise a BCP-47 code like `en-US`.
    @AppStorage("sttLanguageSelection") var sttLanguageSelectionStorage: String = ""
    @AppStorage("selectedLLM") var selectedLLM: LLMProviderID = .anthropic
    @AppStorage("deepContextEnabled") var deepContextEnabled: Bool = false
    @AppStorage("preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("customSystemPrompt") var customSystemPrompt: String = ""
    @AppStorage("customVocabulary") var customVocabulary: String = ""
    @AppStorage("learnFromEdits") var learnFromEdits: Bool = false
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("showSetupGuide") var showSetupGuide: Bool = true
    @AppStorage("whispur.onboarding.completed") var onboardingCompleted: Bool = false

    @Published var holdShortcut: ShortcutBinding
    @Published var toggleShortcut: ShortcutBinding?
    @Published private(set) var microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess

    let pipeline: DictationPipeline
    let recorder: AudioRecorder
    let hotkeyManager: HotkeyManager
    let historyStore: PipelineHistoryStore
    let providerRequestLog: ProviderRequestLog
    let keychain: KeychainManager
    let registry: ProviderRegistry
    let overlayManager: OverlayPanelManager
    let sparkleUpdater: SparkleUpdater
    let learning: TranscriptLearning

    private let shortcutSessionController = ShortcutSessionController()
    private var permissionObservers: [NSObjectProtocol] = []
    private var phaseCancellable: AnyCancellable?

    init() {
        let loadedHoldShortcut = Self.loadShortcut(forKey: "holdShortcut", fallback: .fnKey)
        let loadedToggleShortcut = Self.loadOptionalShortcut(forKey: "toggleShortcut", fallback: .commandFn)
        let sanitizedToggleShortcut = loadedToggleShortcut == loadedHoldShortcut
            ? ShortcutBinding.commandFn
            : loadedToggleShortcut

        _holdShortcut = Published(initialValue: loadedHoldShortcut)
        _toggleShortcut = Published(initialValue: sanitizedToggleShortcut)

        let keychain = KeychainManager.shared
        let providerRequestLog = ProviderRequestLog()
        let httpClient = ProviderHTTPClient(requestLog: providerRequestLog)
        let registry = ProviderRegistry(keychain: keychain, httpClient: httpClient)
        let recorder = AudioRecorder()
        let historyStore = PipelineHistoryStore()
        let pipeline = DictationPipeline(
            recorder: recorder,
            registry: registry,
            historyStore: historyStore,
            httpClient: httpClient
        )
        let sparkleUpdater = SparkleUpdater()
        let hotkeyManager = HotkeyManager()
        let overlayManager = OverlayPanelManager()
        let learning = TranscriptLearning()

        self.keychain = keychain
        self.registry = registry
        self.recorder = recorder
        self.historyStore = historyStore
        self.pipeline = pipeline
        self.sparkleUpdater = sparkleUpdater
        self.hotkeyManager = hotkeyManager
        self.overlayManager = overlayManager
        self.providerRequestLog = providerRequestLog
        self.learning = learning

        hotkeyManager.holdBinding = loadedHoldShortcut
        hotkeyManager.toggleBinding = sanitizedToggleShortcut

        setupHotkeys()
        observePipeline()
        setupLearning()

        overlayManager.bind(
            to: pipeline,
            onStop: { [weak self] in self?.stopDictation() },
            onCancel: { [weak self] in self?.cancelDictation() }
        )

        syncPipelineConfig()
        refreshPermissionSnapshot()

        // Defer everything non-critical until after the menu bar paints.
        // Installing the CGEventTap, the legacy-preferences migration, and
        // the Sparkle update check all touch the filesystem / event system
        // and would otherwise add ~30–100 ms before the icon appears.
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.migrateLegacyLanguagesPreferenceIfNeeded()
            self.hotkeyManager.start()
            self.startPermissionMonitoring()
            self.sparkleUpdater.checkForUpdatesInBackground()
        }
    }

    /// One-shot migration of the prior multi-language CSV setting
    /// (`sttLanguages`) into the new single-selection storage key
    /// (`sttLanguageSelection`). Keeps the first entry as the user's single
    /// preferred language; empty list becomes auto-detect.
    private static func migrateLegacyLanguagesPreferenceIfNeeded() {
        let defaults = UserDefaults.standard
        let legacyKey = "sttLanguages"
        let newKey = "sttLanguageSelection"
        guard let legacy = defaults.string(forKey: legacyKey) else { return }
        // Only migrate if the new key hasn't been set yet — don't overwrite a
        // user who already made a choice in the new UI.
        if defaults.object(forKey: newKey) == nil {
            let firstCode = legacy
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? ""
            defaults.set(firstCode, forKey: newKey)
        }
        defaults.removeObject(forKey: legacyKey)
    }

    private func setupLearning() {
        learning.isEnabled = learnFromEdits
        learning.onLearnTerm = { [weak self] _, toTerm in
            guard let self else { return }
            self.appendToVocabulary(toTerm)
        }
        pipeline.onPasteCompleted = { [weak self] pasted in
            guard let self, self.learnFromEdits else { return }
            self.learning.captureAfterPaste(pastedText: pasted)
        }
    }

    private func appendToVocabulary(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = VocabularyParser.parse(customVocabulary)
        guard !existing.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { return }
        let prefix = customVocabulary.isEmpty || customVocabulary.hasSuffix("\n")
            ? customVocabulary
            : customVocabulary + "\n"
        customVocabulary = prefix + trimmed
        syncPipelineConfig()
    }

    var isSelectedSTTConfigured: Bool {
        !selectedSTT.requiresAPIKey || keychain.hasKeysFor(stt: selectedSTT)
    }

    var isSelectedLLMConfigured: Bool {
        keychain.hasKeysFor(llm: selectedLLM)
    }

    var canStartDictation: Bool {
        pipeline.canStartRecording && isSelectedSTTConfigured && hotkeyManager.isAccessibilityGranted
    }

    var hasRequiredPermissions: Bool {
        microphoneAccessGranted && hotkeyManager.isAccessibilityGranted
    }

    var isReadyForDailyUse: Bool {
        hasRequiredPermissions && isSelectedSTTConfigured
    }

    var hasCompletedFirstDictation: Bool {
        !historyStore.items.isEmpty
    }

    var setupProgress: Double {
        Double(setupCompletedCount) / Double(setupItemCount)
    }

    var setupCompletedCount: Int {
        [
            microphoneAccessGranted,
            hotkeyManager.isAccessibilityGranted,
            isSelectedSTTConfigured,
            true,
            hasCompletedFirstDictation
        ]
        .filter { $0 }
        .count
    }

    var setupItemCount: Int { 5 }

    var lastTranscriptPreview: String? {
        let text = pipeline.lastResult?.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var lastRawTranscriptPreview: String? {
        let text = pipeline.lastResult?.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    var hasToggleShortcut: Bool {
        toggleShortcut != nil
    }

    var shortcutSummary: String {
        if let toggleShortcut {
            return "\(holdShortcut.menuTitle) to talk, \(toggleShortcut.menuTitle) to latch"
        }
        return "\(holdShortcut.menuTitle) to talk"
    }

    var recordingSummary: String {
        switch pipeline.phase {
        case .idle:
            if !isReadyForDailyUse {
                return "Finish setup to start dictating."
            }
            return shortcutSummary
        case .requestingMicrophonePermission:
            return "Allow microphone access to begin recording."
        case .starting:
            return "Preparing your microphone."
        case .recording:
            if pipeline.activeTriggerMode == .hold {
                return "Release \(holdShortcut.menuTitle) to transcribe."
            }
            if let toggleShortcut {
                return "Press \(toggleShortcut.menuTitle) again or use Stop."
            }
            return "Use Stop when you're done."
        case .normalizingAudio:
            return "Cleaning up the captured audio."
        case .transcribing:
            return "Turning speech into text."
        case .cleaningTranscript:
            return "Polishing the transcript for paste."
        case .pasting:
            return "Inserting text into the active app."
        case .done:
            return "Ready for the next dictation."
        case .error:
            return "Review setup or try again."
        }
    }

    func startDictation(triggerMode: RecordingTriggerMode = .hold) {
        syncPipelineConfig()
        refreshPermissionSnapshot()

        // Before the new recording begins, check whether the user edited
        // the previous paste — if so, offer to learn those words.
        learning.isEnabled = learnFromEdits
        if learnFromEdits {
            Task { [weak self] in await self?.learning.reconcile() }
        }

        guard hotkeyManager.isAccessibilityGranted else {
            pipeline.presentError("Accessibility access is required before Whispur can paste dictated text.")
            return
        }

        guard isSelectedSTTConfigured else {
            pipeline.presentError("\(selectedSTT.displayName) is not configured. Add its API key or switch to Apple STT.")
            return
        }

        pipeline.startRecording(triggerMode: triggerMode)
    }

    func stopDictation() {
        shortcutSessionController.reset()
        pipeline.stopAndProcess()
    }

    func toggleManualDictation() {
        if pipeline.canStopRecording {
            stopDictation()
        } else if canStartDictation {
            shortcutSessionController.beginManual(mode: .toggle)
            startDictation(triggerMode: .toggle)
        }
    }

    func pasteLastTranscript() {
        guard let transcript = lastTranscriptPreview else { return }

        Task {
            await TextInjector.paste(transcript, preserveClipboard: preserveClipboard)
        }
    }

    func copyLastTranscript() {
        guard let transcript = lastTranscriptPreview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    func requestMicrophoneAccess() {
        guard !microphoneAccessGranted else { return }

        Task {
            _ = await AudioRecorder.requestMicrophoneAccess()
            await MainActor.run {
                self.refreshPermissionSnapshot()
            }
        }
    }

    func requestAccessibilityAccess() {
        hotkeyManager.requestAccessibility()
        refreshPermissionSnapshot()
    }

    func openMicrophoneSettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func markOnboardingCompleted() {
        onboardingCompleted = true
    }

    func setHoldShortcut(_ binding: ShortcutBinding) {
        guard binding != toggleShortcut else { return }
        holdShortcut = binding
        persistShortcut(binding, forKey: "holdShortcut")
        hotkeyManager.holdBinding = binding
    }

    func setToggleShortcut(_ binding: ShortcutBinding?) {
        guard binding != holdShortcut else { return }
        toggleShortcut = binding
        persistShortcut(binding, forKey: "toggleShortcut")
        hotkeyManager.toggleBinding = binding
    }

    func hideSetupGuide() {
        showSetupGuide = false
    }

    func reopenSetupGuide() {
        showSetupGuide = true
    }

    func refreshPermissionSnapshot() {
        microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess
    }

    private func setupHotkeys() {
        hotkeyManager.onEvent = { [weak self] event in
            guard let self else { return }

            Task { @MainActor in
                if case .cancelRequested = event {
                    self.cancelDictation()
                    return
                }

                let isBusy = !self.pipeline.canStartRecording && !self.pipeline.canStopRecording

                switch self.shortcutSessionController.handle(event: event, isBusy: isBusy) {
                case .start(let mode):
                    self.startDictation(triggerMode: mode)
                case .stop:
                    self.stopDictation()
                case .switchedToToggle:
                    self.shortcutSessionController.switchToToggleMode()
                    self.pipeline.updateTriggerMode(.toggle)
                case .none:
                    break
                }
            }
        }
    }

    func cancelDictation() {
        guard !pipeline.canStartRecording else { return }
        shortcutSessionController.reset()
        pipeline.cancel()
    }

    private func observePipeline() {
        // Use `sink` directly (no `receive(on:)`) so the cancel-watch flag
        // flips in the same turn as the phase change. The CGEvent tap reads
        // this flag from its own thread and can fire before any delayed
        // main-thread hop would complete, dropping ESC-to-cancel.
        phaseCancellable = pipeline.$phase
            .sink { [weak self] phase in
                guard let self else { return }

                switch phase {
                case .idle, .done, .error:
                    self.shortcutSessionController.reset()
                    self.hotkeyManager.cancelWatchEnabled = false
                default:
                    self.hotkeyManager.cancelWatchEnabled = true
                }

                if case .requestingMicrophonePermission = phase {
                    self.refreshPermissionSnapshot()
                }
            }
    }

    private func syncPipelineConfig() {
        pipeline.selectedSTT = selectedSTT
        pipeline.selectedLLM = selectedLLM
        pipeline.sttLanguageSelection = sttLanguageSelection
        pipeline.customVocabulary = VocabularyParser.parse(customVocabulary)
        pipeline.preserveClipboard = preserveClipboard
        pipeline.soundVolume = soundEnabled ? 1.0 : 0.0
        pipeline.systemPrompt = customSystemPrompt.isEmpty ? Prompts.defaultCleanup : customSystemPrompt
    }

    var sttLanguageSelection: STTLanguageSelection {
        get { STTLanguageSelection(storageValue: sttLanguageSelectionStorage) }
        set {
            sttLanguageSelectionStorage = newValue.storageValue
            syncPipelineConfig()
        }
    }

    private func startPermissionMonitoring() {
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
        permissionObservers.removeAll()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let appCenter = NotificationCenter.default

        let activationObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionSnapshot()
            }
        }

        let becomeActiveObserver = appCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissionSnapshot()
            }
        }

        permissionObservers = [activationObserver, becomeActiveObserver]
    }

    deinit {
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func openSystemSettingsPane(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func loadShortcut(forKey key: String, fallback: ShortcutBinding) -> ShortcutBinding {
        guard let storedValue = UserDefaults.standard.string(forKey: key),
              let binding = ShortcutBinding(storageValue: storedValue) else {
            return fallback
        }
        return binding
    }

    private static func loadOptionalShortcut(forKey key: String, fallback: ShortcutBinding?) -> ShortcutBinding? {
        guard let storedValue = UserDefaults.standard.string(forKey: key) else {
            return fallback
        }

        guard storedValue != "off" else {
            return nil
        }

        return ShortcutBinding(storageValue: storedValue) ?? fallback
    }

    private func persistShortcut(_ binding: ShortcutBinding?, forKey key: String) {
        UserDefaults.standard.set(binding?.storageValue ?? "off", forKey: key)
    }
}
