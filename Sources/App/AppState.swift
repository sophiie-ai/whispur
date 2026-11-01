import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Central application state used by the menu bar UI and settings window.
@MainActor
final class AppState: ObservableObject {
    @AppStorage("selectedSTT") var selectedSTT: STTProviderID = .apple
    /// The languages the user speaks: comma-separated BCP-47 codes like
    /// `en-US,es-MX`. Empty string = auto-detect.
    @AppStorage(AppState.spokenLanguagesKey) var sttLanguageSelectionStorage: String = ""
    /// Opt-in live streaming for providers that support it.
    @AppStorage("streamWhileTalking") var streamWhileTalking: Bool = false
    @AppStorage("selectedLLM") var selectedLLM: LLMProviderID = .anthropic
    /// Empty = use the official OpenAI endpoint. Set to point STT/LLM at an
    /// OpenAI-compatible gateway (Azure OpenAI, internal proxy, Ollama, etc.).
    @AppStorage("openaiSTTBaseURL") var openaiSTTBaseURL: String = ""
    @AppStorage("openaiLLMBaseURL") var openaiLLMBaseURL: String = ""
    /// CoreAudio device UID for the preferred input. Empty = follow the system default.
    @AppStorage("preferredAudioInputUID") var preferredAudioInputUID: String = ""
    @AppStorage("deepContextEnabled") var deepContextEnabled: Bool = false
    @AppStorage("preserveClipboard") var preserveClipboard: Bool = true
    @AppStorage("customSystemPrompt") var customSystemPrompt: String = ""
    @AppStorage("learnFromEdits") var learnFromEdits: Bool = false
    @AppStorage("soundEnabled") var soundEnabled: Bool = true
    @AppStorage("muteSystemAudioWhileRecording") var muteSystemAudioWhileRecording: Bool = false
    @AppStorage("overlayStyle") var overlayStyle: OverlayStyle = .standard
    /// 0...100. How much to reduce the system output volume by while
    /// recording. 100 = full mute (the original behavior); lower values
    /// just duck playback so background audio is still audible. Only
    /// consulted when `muteSystemAudioWhileRecording` is true.
    @AppStorage("systemAudioReductionPercent") var systemAudioReductionPercent: Int = 100
    @AppStorage("showSetupGuide") var showSetupGuide: Bool = true
    @AppStorage("whispur.onboarding.completed") var onboardingCompleted: Bool = false
    /// Settings master switch: while off, the dictation shortcuts do nothing.
    @AppStorage("dictationEnabled") private(set) var dictationEnabled: Bool = true

    /// nil when the user removed the hold-to-talk shortcut.
    @Published var holdShortcut: ShortcutBinding?
    @Published var toggleShortcut: ShortcutBinding?
    @Published private(set) var microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess

    let pipeline: DictationPipeline
    let recorder: AudioRecorder
    let hotkeyManager: HotkeyManager
    let historyStore: PipelineHistoryStore
    /// Retries failed dictations from Activity and Requests.
    let retrier: FailedDictationRetrier
    let stats: DictationStats
    let providerRequestLog: ProviderRequestLog
    let keychain: KeychainManager
    let registry: ProviderRegistry
    let overlayManager: OverlayPanelManager
    let sparkleUpdater: SparkleUpdater
    let learning: TranscriptLearning
    /// The user's dictionary (terms plus where each came from).
    let vocabulary: VocabularyStore
    /// Cleanup style per app.
    let styles: StyleStore
    let learningSuggestions: LearningSuggestionCenter
    private let learningToastPanel: LearningToastPanelManager

    private let shortcutSessionController = ShortcutSessionController()
    private var permissionObservers: [NSObjectProtocol] = []
    private var phaseCancellable: AnyCancellable?
    private var statsCancellable: AnyCancellable?
    private var lastCountedResultID: UUID?
    private var failedAudioPurgeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - historyStore: Saved dictations. Defaults to the on-disk store;
    ///     renders pass one backed by a temporary file.
    ///   - stats: Dictation counters, same as above.
    ///   - providerRequestLog: Provider request diagnostics, same as above.
    ///   - vocabulary: The dictionary. Renders pass one on a scratch
    ///     defaults suite.
    ///   - styles: Per-app cleanup styles, same as above.
    ///   - startsServices: Installs the shortcut listener and starts update
    ///     checks. Renders pass false so a second instance never listens to
    ///     the keyboard.
    init(
        historyStore: PipelineHistoryStore? = nil,
        stats: DictationStats? = nil,
        providerRequestLog: ProviderRequestLog? = nil,
        vocabulary: VocabularyStore? = nil,
        styles: StyleStore? = nil,
        startsServices: Bool = true
    ) {
        // Before anything reads the language setting.
        Self.migrateSpokenLanguagesIfNeeded()
        let loadedHoldShortcut = Self.loadHoldShortcut()
        let sanitizedToggleShortcut = Self.loadToggleShortcut(holdShortcut: loadedHoldShortcut)

        _holdShortcut = Published(initialValue: loadedHoldShortcut)
        _toggleShortcut = Published(initialValue: sanitizedToggleShortcut)

        let keychain = KeychainManager.shared
        let providerRequestLog = providerRequestLog ?? ProviderRequestLog()
        let httpClient = ProviderHTTPClient(requestLog: providerRequestLog)
        let registry = ProviderRegistry(keychain: keychain, httpClient: httpClient)
        let recorder = AudioRecorder()
        let historyStore = historyStore ?? PipelineHistoryStore()
        let stats = stats ?? DictationStats()
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
        let learningSuggestions = LearningSuggestionCenter()
        let learningToastPanel = LearningToastPanelManager()

        self.keychain = keychain
        self.registry = registry
        self.recorder = recorder
        self.historyStore = historyStore
        self.retrier = FailedDictationRetrier(history: historyStore) { [weak pipeline] audioURL, item in
            guard let pipeline else { throw CancellationError() }
            return try await pipeline.retryTranscription(audioURL: audioURL, appBundleID: item.appBundleID, dictationID: item.id)
        }
        self.stats = stats
        self.lastCountedResultID = historyStore.items.first?.id
        self.pipeline = pipeline
        self.sparkleUpdater = sparkleUpdater
        self.hotkeyManager = hotkeyManager
        self.overlayManager = overlayManager
        self.providerRequestLog = providerRequestLog
        self.learning = learning
        self.vocabulary = vocabulary ?? VocabularyStore()
        self.styles = styles ?? StyleStore(
            hasCustomPrompt: !(UserDefaults.standard.string(forKey: "customSystemPrompt") ?? "").isEmpty
        )
        self.learningSuggestions = learningSuggestions
        self.learningToastPanel = learningToastPanel

        hotkeyManager.holdBinding = loadedHoldShortcut
        hotkeyManager.toggleBinding = sanitizedToggleShortcut
        hotkeyManager.isEnabled = dictationEnabled
        stats.seedDictationCountIfMissing(historyStore.items.count)

        setupHotkeys()
        observePipeline()
        setupLearning()

        overlayManager.bind(
            to: pipeline,
            styleProvider: { [weak self] in self?.overlayStyle ?? .standard },
            onStop: { [weak self] in self?.stopDictation() },
            onCancel: { [weak self] in self?.cancelDictation() }
        )

        syncPipelineConfig()
        refreshPermissionSnapshot()

        // Defer everything non-critical until after the menu bar paints.
        // Installing the CGEventTap, the legacy-preferences migration, and
        // the Sparkle update check all touch the filesystem / event system
        // and would otherwise add ~30–100 ms before the icon appears.
        guard startsServices else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            Self.clearRetiredModesStorage()
            self.hotkeyManager.start()
            self.startFailedAudioPurge()
            self.startPermissionMonitoring()
            self.sparkleUpdater.checkForUpdatesInBackground()
        }
    }

    /// Drop UserDefaults keys that outlived dictation modes and per-app
    /// provider rules. A user's global `customSystemPrompt` override (if
    /// any) is preserved; per-mode customizations and per-app rules are
    /// not carried forward.
    private static func clearRetiredModesStorage() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "whispur.dictationModes.customPrompts")
        defaults.removeObject(forKey: "selectedDictationMode")
        defaults.removeObject(forKey: "whispur.appProviderRules")
        defaults.removeObject(forKey: "appRulesEnabled")
    }

    /// Where "Languages I speak" is stored.
    nonisolated static let spokenLanguagesKey = "sttSpokenLanguages"
    /// The single-language picker's key (auto or one BCP-47 code). Left in
    /// place after migrating so an older build still reads it.
    nonisolated static let singleLanguageKey = "sttLanguageSelection"
    /// The original up-to-three languages CSV, from before the single picker.
    nonisolated static let legacyLanguagesKey = "sttLanguages"

    /// One-shot, lossless move into the "Languages I speak" set: one
    /// language stays that one language, auto stays empty (auto), and an
    /// original CSV list that was never migrated keeps every entry. Never
    /// overwrites a set the user already has.
    nonisolated static func migrateSpokenLanguagesIfNeeded(defaults: UserDefaults = .standard) {
        defer { defaults.removeObject(forKey: legacyLanguagesKey) }
        guard defaults.object(forKey: spokenLanguagesKey) == nil else { return }
        let source = defaults.string(forKey: singleLanguageKey) ?? defaults.string(forKey: legacyLanguagesKey)
        guard let source else { return }
        defaults.set(STTLanguageSelection(storageValue: source).storageValue, forKey: spokenLanguagesKey)
    }

    private func setupLearning() {
        learning.isEnabled = learnFromEdits
        learning.suggestionCenter = learningSuggestions
        learning.onLearnTerm = { [weak self] fromTerm, toTerm in
            self?.learnTerm(toTerm, from: fromTerm)
        }
        learningSuggestions.onAccept = { [weak self] suggestion in
            self?.learnTerm(suggestion.to, from: suggestion.from)
        }
        learningToastPanel.bind(to: learningSuggestions)
        pipeline.onPasteCompleted = { [weak self] pasted in
            guard let self, self.learnFromEdits else { return }
            self.learning.captureAfterPaste(pastedText: pasted)
        }
    }

    /// Adds a word the user corrected to the dictionary, remembering the
    /// word Whispur had written.
    private func learnTerm(_ term: String, from original: String) {
        let trimmed = term.trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard vocabulary.add(trimmed, source: .learned(original: source)) else { return }
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
        historyStore.items.contains { !$0.isFailed }
    }

    /// Retries a failed dictation with the current settings and copies the
    /// text.
    func retryFailedDictation(_ id: UUID) {
        syncPipelineConfig()
        Task { await retrier.retry(id) }
    }

    /// Failed recordings are kept for 24 hours: purge at launch, then hourly.
    private func startFailedAudioPurge() {
        failedAudioPurgeTask?.cancel()
        failedAudioPurgeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.historyStore.purgeExpiredAudio()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    var setupProgress: Double {
        Double(setupCompletedCount) / Double(setupItemCount)
    }

    var setupCompletedCount: Int {
        [
            microphoneAccessGranted,
            hotkeyManager.isAccessibilityGranted,
            isSelectedSTTConfigured,
            hasAnyShortcut,
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

    /// At least one dictation shortcut is set. With none, dictation still
    /// starts from the menu bar.
    var hasAnyShortcut: Bool {
        holdShortcut != nil || toggleShortcut != nil
    }

    var shortcutSummary: String {
        Self.shortcutSummary(hold: holdShortcut, toggle: toggleShortcut)
    }

    static func shortcutSummary(hold: ShortcutBinding?, toggle: ShortcutBinding?) -> String {
        switch (hold, toggle) {
        case let (hold?, toggle?):
            return "\(hold.menuTitle) to talk, \(toggle.menuTitle) to latch"
        case let (hold?, nil):
            return "\(hold.menuTitle) to talk"
        case let (nil, toggle?):
            return "\(toggle.menuTitle) to latch"
        case (nil, nil):
            return "No shortcut set. Use Start in the menu bar or add one in Settings."
        }
    }

    /// "Press Fn twice to start, press Fn once to stop." for the double-press
    /// binding; "Press X to start, press X again to stop." otherwise.
    var toggleShortcutInstruction: String {
        guard let toggleShortcut else {
            return "Toggle mode is currently off. You can add one later in Settings."
        }
        return "\(toggleShortcut.toggleStartPhrase) to start, \(toggleShortcut.toggleStopPhrase) to stop."
    }

    /// Menu bar hint while a toggle recording is running.
    var toggleActiveHint: String {
        guard let toggleShortcut else {
            return "Toggle mode is active. Press Stop when you're done."
        }
        return "Toggle mode is active. \(toggleShortcut.toggleStopPhrase.capitalizedFirst) or press Stop."
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
                guard let holdShortcut else { return "Release the shortcut to transcribe." }
                return "Release \(holdShortcut.menuTitle) to transcribe."
            }
            if let toggleShortcut {
                return "\(toggleShortcut.toggleStopPhrase.capitalizedFirst) or use Stop."
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
        StartLatencyTrace.mark("startDictation")
        syncPipelineConfig()
        learning.isEnabled = learnFromEdits
        defer {
            refreshPermissionSnapshotInBackground()
            reconcileLearning()
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

    /// Check whether the user edited the previous paste and, if so, offer
    /// to learn those words. Runs after the recording has been asked to
    /// start: it reads the focused field over Accessibility, which can take
    /// a while in some apps, and must not hold back the overlay.
    private func reconcileLearning() {
        guard learnFromEdits else { return }
        Task { [weak self] in await self?.learning.reconcile() }
    }

    func stopDictation() {
        shortcutSessionController.reset()
        syncHotkeySessionState()
        pipeline.stopAndProcess()
    }

    func toggleManualDictation() {
        if pipeline.canStopRecording {
            stopDictation()
        } else if canStartDictation {
            StartLatencyTrace.begin("menu start")
            shortcutSessionController.beginManual(mode: .toggle)
            syncHotkeySessionState()
            startDictation(triggerMode: .toggle)
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

    /// Pass nil to remove the hold-to-talk shortcut.
    func setHoldShortcut(_ binding: ShortcutBinding?) {
        guard binding == nil || binding != toggleShortcut else { return }
        holdShortcut = binding
        persistShortcut(binding, forKey: "holdShortcut")
        hotkeyManager.holdBinding = binding
    }

    func setToggleShortcut(_ binding: ShortcutBinding?) {
        guard binding == nil || binding != holdShortcut else { return }
        toggleShortcut = binding
        persistShortcut(binding, forKey: "toggleShortcut")
        hotkeyManager.toggleBinding = binding
    }

    /// Turns the dictation shortcuts on or off. Turning them off mid-recording
    /// cancels the recording, since its stop shortcut no longer works.
    func setDictationEnabled(_ enabled: Bool) {
        dictationEnabled = enabled
        hotkeyManager.isEnabled = enabled
        if !enabled, pipeline.canStopRecording {
            cancelDictation()
        }
    }

    func hideSetupGuide() {
        showSetupGuide = false
    }

    func reopenSetupGuide() {
        showSetupGuide = true
    }

    /// Same as `refreshPermissionSnapshot`, with the read off the main
    /// thread: reading the microphone status costs ~10-20 ms, too much for
    /// the dictation start path.
    private func refreshPermissionSnapshotInBackground() {
        Task { [weak self] in
            let granted = await Task.detached(priority: .utility) { AudioRecorder.hasMicrophoneAccess }.value
            self?.microphoneAccessGranted = granted
        }
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
                self.syncHotkeySessionState()
            }
        }
    }

    /// Mirror the controller's toggle state into the hotkey manager so a
    /// single press of a double-press binding (Fn twice) stops the session
    /// however it was started, and never starts one after it ended.
    private func syncHotkeySessionState() {
        hotkeyManager.setToggleSessionActive(shortcutSessionController.activeMode == .toggle)
    }

    func cancelDictation() {
        guard !pipeline.canStartRecording else { return }
        shortcutSessionController.reset()
        syncHotkeySessionState()
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
                    self.syncHotkeySessionState()
                    self.hotkeyManager.cancelWatchEnabled = false
                default:
                    self.hotkeyManager.cancelWatchEnabled = true
                }

                if case .requestingMicrophonePermission = phase {
                    self.refreshPermissionSnapshot()
                }
            }

        statsCancellable = pipeline.$lastResult
            .compactMap { $0 }
            .sink { [weak self] result in
                guard let self else { return }
                guard self.lastCountedResultID != result.id else { return }
                self.lastCountedResultID = result.id
                let words = result.cleanedText.whitespaceWordCount
                self.stats.record(wordCount: words, at: result.timestamp)
            }
    }

    private func syncPipelineConfig() {
        pipeline.selectedSTT = selectedSTT
        pipeline.selectedLLM = selectedLLM
        pipeline.sttLanguageSelection = sttLanguageSelection
        pipeline.customVocabulary = vocabulary.plainTerms
        pipeline.preserveClipboard = preserveClipboard
        pipeline.soundVolume = soundEnabled ? 1.0 : 0.0
        pipeline.muteSystemAudioWhileRecording = muteSystemAudioWhileRecording
        pipeline.systemAudioReductionPercent = systemAudioReductionPercent
        pipeline.streamingEnabled = streamWhileTalking

        // `customSystemPrompt` is the single user-editable override. When
        // empty, the pipeline falls back to the built-in cleanup prompt.
        pipeline.systemPrompt = customSystemPrompt.isEmpty ? Prompts.defaultCleanup : customSystemPrompt
        // Per-app styles pick the prompt for the app the recording started
        // in; Custom uses the prompt above.
        pipeline.cleanupStyle = { [weak self] bundleID in
            guard let self else { return CleanupStyleChoice(style: .standard, systemPrompt: Prompts.defaultCleanup) }
            return self.styles.choice(for: bundleID, customPrompt: self.customSystemPrompt)
        }
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

    /// Users who never picked a hold shortcut (new installs) get Fn; a stored
    /// "off" means the user removed it and stays removed across launches.
    static func loadHoldShortcut(defaults: UserDefaults = .standard) -> ShortcutBinding? {
        loadOptionalShortcut(forKey: "holdShortcut", fallback: .fnKey, defaults: defaults)
    }

    /// Users who never picked a toggle shortcut get `ShortcutBinding.defaultToggle`
    /// (the fallback is never written back); an explicit stored choice, including
    /// "off" and Fn twice, is kept unless it collides with the hold shortcut.
    static func loadToggleShortcut(
        holdShortcut: ShortcutBinding?,
        defaults: UserDefaults = .standard
    ) -> ShortcutBinding? {
        let loaded = loadOptionalShortcut(forKey: "toggleShortcut", fallback: .defaultToggle, defaults: defaults)
        guard let loaded, loaded == holdShortcut else { return loaded }
        return .defaultToggle
    }

    private static func loadOptionalShortcut(
        forKey key: String,
        fallback: ShortcutBinding?,
        defaults: UserDefaults = .standard
    ) -> ShortcutBinding? {
        guard let storedValue = defaults.string(forKey: key) else {
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
