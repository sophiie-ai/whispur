import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Central application state used by the menu bar UI and settings window.
@MainActor
final class AppState: ObservableObject {
    /// Apple when nothing is stored. A user who never picked a provider and
    /// has no cloud speech key gets Parakeet stored at launch instead
    /// (`STTDefaultResolver`).
    @AppStorage(STTDefaultResolver.selectedSTTKey) var selectedSTT: STTProviderID = .apple {
        didSet {
            guard selectedSTT != oldValue else { return }
            prepareLocalModel(for: selectedSTT)
        }
    }
    /// The languages the user speaks: comma-separated BCP-47 codes like
    /// `en-US,es-MX`. Empty string = auto-detect.
    @AppStorage(AppState.spokenLanguagesKey) var sttLanguageSelectionStorage: String = ""
    /// Opt-in live streaming for providers that support it.
    @AppStorage("streamWhileTalking") var streamWhileTalking: Bool = false
    @AppStorage("selectedLLM") var selectedLLM: LLMProviderID = .anthropic
    /// "Clean up with AI". Off: paste exactly what the speech engine heard
    /// (spoken edit commands and text fixes still apply) and make no cleanup
    /// request.
    @AppStorage(AppState.cleanupEnabledKey) var cleanupEnabled: Bool = true {
        didSet { syncPipelineConfig() }
    }
    /// Text fixes made in code on every dictation, cleanup on or off
    /// (`TextFixes`, `SmartSpacing`). All on by default.
    @AppStorage(AppState.removeFillersKey) var removeFillers: Bool = true
    @AppStorage(AppState.spokenSymbolsKey) var spokenSymbols: Bool = true
    @AppStorage(AppState.spokenQuotesKey) var spokenQuotes: Bool = true
    @AppStorage(AppState.smartSpacingKey) var smartSpacing: Bool = true
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
    /// After a cleaned paste, offer the raw transcript for a few seconds.
    @AppStorage("useRawToastEnabled") var useRawToastEnabled: Bool = true
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
    /// Separate hold and hands-free shortcuts, or one tap-or-hold key.
    @Published private(set) var shortcutStyle: DictationShortcutStyle
    /// The key used when `shortcutStyle` is `.tapOrHold`.
    @Published private(set) var tapOrHoldShortcut: ShortcutBinding
    @Published private(set) var microphoneAccessGranted = AudioRecorder.hasMicrophoneAccess
    /// The user refused the microphone (or a profile restricts it): macOS
    /// won't ask again, so the switch is in System Settings.
    @Published private(set) var microphoneAccessRefused = false

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
    /// The "drag to allow" guide beside System Settings.
    let permissionGuide = PermissionGuideController()
    private let learningToastPanel: LearningToastPanelManager
    /// Dictations the user marked as wrong, as local eval cases.
    let evalCases: MyEvalCaseStore
    /// The "Use raw" offer after a cleaned paste.
    let useRaw = UseRawController()
    private let useRawToastPanel = UseRawToastPanelManager()
    private var appActivationObserver: NSObjectProtocol?

    private let shortcutSessionController = ShortcutSessionController()
    private var permissionObservers: [NSObjectProtocol] = []
    private var phaseCancellable: AnyCancellable?
    private var statsCancellable: AnyCancellable?
    private var lastCountedResultID: UUID?
    private var failedAudioPurgeTask: Task<Void, Never>?
    /// The on-device Parakeet model: download, warm-up, memory.
    let parakeetModel: ParakeetModelManager
    /// Downloads the model in the background for users Parakeet became the
    /// default for.
    let parakeetAutoDownload: ParakeetAutoDownload
    private var parakeetCancellable: AnyCancellable?
    private var networkConditions: NetworkConditionsMonitor?
    private let startsServices: Bool

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
        evalCases: MyEvalCaseStore? = nil,
        startsServices: Bool = true
    ) {
        // Before anything reads the language setting.
        Self.migrateSpokenLanguagesIfNeeded()
        // Before anything reads the speech provider. Renders and tests
        // never read the Keychain or change the stored provider.
        if startsServices { Self.adoptDefaultSpeechProvider() }
        let loadedHoldShortcut = Self.loadHoldShortcut()
        let sanitizedToggleShortcut = Self.loadToggleShortcut(holdShortcut: loadedHoldShortcut)

        _holdShortcut = Published(initialValue: loadedHoldShortcut)
        _toggleShortcut = Published(initialValue: sanitizedToggleShortcut)
        let loadedStyle = Self.loadShortcutStyle()
        let loadedTapOrHold = Self.loadTapOrHoldShortcut()
        _shortcutStyle = Published(initialValue: loadedStyle)
        _tapOrHoldShortcut = Published(initialValue: loadedTapOrHold)

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
        self.evalCases = evalCases ?? MyEvalCaseStore()
        self.parakeetModel = .shared
        self.parakeetAutoDownload = ParakeetAutoDownload(model: ParakeetModelManager.shared)
        self.startsServices = startsServices

        Self.applyBindings(
            to: hotkeyManager,
            style: loadedStyle,
            hold: loadedHoldShortcut,
            toggle: sanitizedToggleShortcut,
            tapOrHold: loadedTapOrHold
        )
        hotkeyManager.isEnabled = dictationEnabled
        stats.seedDictationCountIfMissing(historyStore.items.count)

        setupHotkeys()
        observePipeline()
        setupLearning()
        setupUseRaw()
        observeParakeetModel()

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
            // Low priority: the menu bar and shortcuts come first.
            if self.selectedSTT == .parakeet { self.parakeetModel.warm() }
            self.startParakeetAutoDownload()
        }
    }

    /// Stores Parakeet for a user who never picked a speech provider, has no
    /// cloud speech key, and has a Mac that runs it.
    private static func adoptDefaultSpeechProvider() {
        let keychain = KeychainManager.shared
        STTDefaultResolver.adoptParakeetIfDefault(
            defaults: .standard,
            hasCloudSTTKey: { CloudSTTKeys.hasAny { keychain.get($0) } },
            parakeetSupported: ParakeetSupport.isSupported
        )
    }

    /// Starts the background model download when Parakeet was picked
    /// automatically and its model isn't here yet. Watches the network only
    /// while that download is pending.
    private func startParakeetAutoDownload() {
        guard parakeetAutoDownload.isActive, selectedSTT == .parakeet else { return }
        parakeetAutoDownload.launch(selected: selectedSTT)
        guard parakeetAutoDownload.isActive else { return }
        networkConditions = NetworkConditionsMonitor { [weak self] constrained in
            self?.parakeetAutoDownload.networkChanged(constrained: constrained)
        }
    }

    /// Dictation transcribes with Apple on-device because Parakeet is
    /// selected and its model isn't downloaded yet.
    var isUsingSpeechFallback: Bool {
        selectedSTT == .parakeet && !parakeetModel.isInstalled
    }

    /// "Parakeet (on this Mac) ready", or what fills in for it.
    var speechReadyTitle: String {
        isUsingSpeechFallback
            ? "\(STTProviderID.apple.displayName) until Parakeet is ready"
            : "\(selectedSTT.displayName) ready"
    }

    /// Republishes model changes (download finished, deleted) so readiness
    /// in the menu bar and onboarding follows them, and warms a model that
    /// just finished downloading for the selected provider.
    private func observeParakeetModel() {
        parakeetCancellable = parakeetModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        parakeetModel.onInstalled = { [weak self] in
            guard let self else { return }
            self.parakeetAutoDownload.installed()
            guard self.selectedSTT == .parakeet else { return }
            self.parakeetModel.warm()
        }
        parakeetModel.onUserStopped = { [weak self] in
            self?.parakeetAutoDownload.userStopped()
        }
    }

    /// Picking Parakeet starts its download, or loads it when it's already
    /// here. Picking anything else frees its memory.
    private func prepareLocalModel(for provider: STTProviderID) {
        // Renders and tests never download or load a model.
        guard startsServices else { return }
        parakeetAutoDownload.selectionChanged(to: provider)
        if provider == .parakeet {
            if parakeetModel.isInstalled {
                parakeetModel.warm()
            } else {
                parakeetModel.download()
            }
        } else {
            parakeetModel.unload()
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
    nonisolated static let cleanupEnabledKey = "cleanupEnabled"
    nonisolated static let removeFillersKey = "textFixes.removeFillers"
    nonisolated static let spokenSymbolsKey = "textFixes.spokenSymbols"
    nonisolated static let spokenQuotesKey = "textFixes.spokenQuotes"
    nonisolated static let smartSpacingKey = "textFixes.smartSpacing"
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

    private func setupUseRaw() {
        useRawToastPanel.bind(to: useRaw, styleProvider: { [weak self] in self?.overlayStyle ?? .standard })
        useRaw.setShortcutWatch = { [weak hotkeyManager] armed in
            hotkeyManager?.useRawWatchEnabled = armed
        }
        hotkeyManager.onUseRawKey = { [weak self] key in
            Task { @MainActor in
                switch key {
                case .useRaw: self?.useRaw.trigger()
                case .otherKey: self?.useRaw.keyTyped()
                }
            }
        }
        useRaw.replace = { [weak self] offer in
            // The undo also removes the leading space smart spacing added.
            let leadingSpace = self?.pipeline.smartSpacedDictationID == offer.dictationID ? " " : ""
            let outcome = await PasteReplacer.replaceLastPaste(
                pasted: offer.pastedText,
                with: leadingSpace + offer.rawTranscript,
                preserveClipboard: self?.preserveClipboard ?? true
            )
            return outcome == .replaced
        }
        useRaw.onUsedRaw = { [weak self] offer in
            guard let self else { return }
            self.historyStore.markUsedRaw(offer.dictationID)
            // The field now holds the raw text; learning should compare
            // later edits against that, not against the cleaned paste.
            if self.learnFromEdits {
                self.learning.captureAfterPaste(pastedText: offer.rawTranscript)
            }
        }
        pipeline.onDictationPasted = { [weak self] result in
            guard let self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            self.useRaw.offer(
                for: result,
                processID: app?.processIdentifier,
                bundleID: app?.bundleIdentifier,
                enabled: self.useRawToastEnabled
            )
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let offer = self.useRaw.visibleOffer, offer.processID != pid else { return }
                self.useRaw.dismiss(.appChanged)
            }
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
        // Without its model, Parakeet falls back to Apple on-device.
        if selectedSTT == .parakeet { return true }
        return !selectedSTT.requiresAPIKey || keychain.hasKeysFor(stt: selectedSTT)
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
        shortcutStyle == .tapOrHold || holdShortcut != nil || toggleShortcut != nil
    }

    var shortcutSummary: String {
        if shortcutStyle == .tapOrHold {
            return Self.tapOrHoldSummary(tapOrHoldShortcut)
        }
        return Self.shortcutSummary(hold: holdShortcut, toggle: toggleShortcut)
    }

    static func tapOrHoldSummary(_ binding: ShortcutBinding) -> String {
        "Hold \(binding.menuTitle) to talk, tap to latch"
    }

    /// The key that talks while held, whichever style is in use.
    var effectiveHoldShortcut: ShortcutBinding? {
        shortcutStyle == .tapOrHold ? tapOrHoldShortcut : holdShortcut
    }

    /// The shortcut shown on the menu bar's shortcut chip.
    var primaryShortcutTitle: String {
        if shortcutStyle == .tapOrHold { return tapOrHoldShortcut.menuTitle }
        return holdShortcut?.menuTitle ?? toggleShortcut?.menuTitle ?? "No shortcut"
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
        if shortcutStyle == .tapOrHold {
            return "Tap \(tapOrHoldShortcut.menuTitle) to start, tap it again to stop."
        }
        guard let toggleShortcut else {
            return "Toggle mode is currently off. You can add one later in Settings."
        }
        return "\(toggleShortcut.toggleStartPhrase) to start, \(toggleShortcut.toggleStopPhrase) to stop."
    }

    /// Menu bar hint while a toggle recording is running.
    var toggleActiveHint: String {
        if shortcutStyle == .tapOrHold {
            return "Toggle mode is active. Tap \(tapOrHoldShortcut.menuTitle) or press Stop."
        }
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
                if shortcutStyle == .tapOrHold {
                    return "Release \(tapOrHoldShortcut.menuTitle) to transcribe."
                }
                guard let holdShortcut else { return "Release the shortcut to transcribe." }
                return "Release \(holdShortcut.menuTitle) to transcribe."
            }
            if shortcutStyle == .tapOrHold {
                return "Tap \(tapOrHoldShortcut.menuTitle) or use Stop."
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
        useRaw.dismiss(.newDictation)
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
            pipeline.presentError(unconfiguredSTTMessage())
            return
        }

        pipeline.startRecording(triggerMode: triggerMode)
    }

    private func unconfiguredSTTMessage() -> String {
        "\(selectedSTT.displayName) is not configured. Add its API key or switch to Apple STT."
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

    /// Asks for the microphone. macOS asks only once, so a refused
    /// microphone opens System Settings with the guide instead.
    func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshPermissionSnapshot()
        case .notDetermined:
            Task {
                _ = await AudioRecorder.requestMicrophoneAccess()
                await MainActor.run {
                    self.refreshPermissionSnapshot()
                }
            }
        default:
            showPermissionGuide(.microphone)
        }
    }

    /// Registers Whispur with Accessibility (macOS shows its prompt once per
    /// launch) and opens System Settings with the drag guide beside it.
    func requestAccessibilityAccess() {
        guard !AXIsProcessTrusted() else {
            hotkeyManager.recheckAccessibility()
            return
        }
        if !Self.didPromptAccessibility {
            Self.didPromptAccessibility = true
            hotkeyManager.requestAccessibility()
        }
        refreshPermissionSnapshot()
        showPermissionGuide(.accessibility)
    }

    /// Opens the Microphone list: plainly when granted, with the guide
    /// when not.
    func openMicrophoneSettings() {
        if microphoneAccessGranted {
            openSystemSettingsPane(GuidedPermission.microphone.settingsURL)
        } else {
            showPermissionGuide(.microphone)
        }
    }

    /// Opens the Accessibility list: plainly when granted, with the guide
    /// when not.
    func openAccessibilitySettings() {
        if AXIsProcessTrusted() {
            openSystemSettingsPane(GuidedPermission.accessibility.settingsURL)
        } else {
            showPermissionGuide(.accessibility)
        }
    }

    private static var didPromptAccessibility = false

    /// Shows the guide for `permission`. Once it is granted, Whispur picks
    /// the grant up straight away and comes back to the front, where
    /// onboarding moves on by itself.
    func showPermissionGuide(_ permission: GuidedPermission) {
        permissionGuide.show(permission) { [weak self] outcome in
            guard let self else { return }
            self.hotkeyManager.recheckAccessibility()
            self.refreshPermissionSnapshot()
            if outcome == .granted {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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

    /// Switch between separate shortcuts and one tap-or-hold key. The
    /// separate shortcuts are kept as they were, so switching back restores
    /// them. A recording in flight is cancelled: its stop key may change.
    func setShortcutStyle(_ style: DictationShortcutStyle) {
        guard style != shortcutStyle else { return }
        shortcutStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.shortcutStyleKey)
        if pipeline.canStopRecording {
            cancelDictation()
        }
        applyHotkeyBindings()
    }

    func setTapOrHoldShortcut(_ binding: ShortcutBinding) {
        tapOrHoldShortcut = binding
        UserDefaults.standard.set(binding.storageValue, forKey: Self.tapOrHoldShortcutKey)
        applyHotkeyBindings()
    }

    private func applyHotkeyBindings() {
        Self.applyBindings(
            to: hotkeyManager,
            style: shortcutStyle,
            hold: holdShortcut,
            toggle: toggleShortcut,
            tapOrHold: tapOrHoldShortcut
        )
    }

    /// Tap or hold replaces both separate shortcuts, so only one set is live.
    static func applyBindings(
        to manager: HotkeyManager,
        style: DictationShortcutStyle,
        hold: ShortcutBinding?,
        toggle: ShortcutBinding?,
        tapOrHold: ShortcutBinding
    ) {
        switch style {
        case .separate:
            manager.tapOrHoldBinding = nil
            manager.holdBinding = hold
            manager.toggleBinding = toggle
        case .tapOrHold:
            manager.holdBinding = nil
            manager.toggleBinding = nil
            manager.tapOrHoldBinding = tapOrHold
        }
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
            let status = await Task.detached(priority: .utility) { AVCaptureDevice.authorizationStatus(for: .audio) }.value
            self?.applyMicrophoneStatus(status)
        }
    }

    func refreshPermissionSnapshot() {
        applyMicrophoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func applyMicrophoneStatus(_ status: AVAuthorizationStatus) {
        microphoneAccessGranted = status == .authorized
        microphoneAccessRefused = status == .denied || status == .restricted
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
        hotkeyManager.setShortcutSessionActive(shortcutSessionController.activeMode != nil)
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
        pipeline.cleanupEnabled = cleanupEnabled
        pipeline.sttLanguageSelection = sttLanguageSelection
        pipeline.customVocabulary = vocabulary.plainTerms
        pipeline.aliasPlan = VocabularyAliasPlan.build(
            entries: vocabulary.aliasEntries,
            terms: vocabulary.plainTerms,
            isCommonWord: CommonWords.isCommon
        )
        pipeline.textFixOptions = TextFixOptions(
            removeFillers: removeFillers,
            spokenSymbols: spokenSymbols,
            spokenQuotes: spokenQuotes
        )
        pipeline.smartSpacingEnabled = smartSpacing
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
                self?.hotkeyManager.recheckAccessibility()
                self?.refreshPermissionSnapshot()
            }
        }

        permissionObservers = [activationObserver, becomeActiveObserver]
    }

    deinit {
        permissionObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func openSystemSettingsPane(_ url: URL) {
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

    static let shortcutStyleKey = "shortcutStyle"
    static let tapOrHoldShortcutKey = "tapOrHoldShortcut"

    /// A stored style wins. Without one, anyone who has used Whispur before
    /// (a stored shortcut, or onboarding done) keeps separate shortcuts, the
    /// only style that existed; only a fresh install gets the new default.
    static func loadShortcutStyle(
        defaults: UserDefaults = .standard,
        newInstallDefault: DictationShortcutStyle = DictationShortcutStyle.newInstallDefault
    ) -> DictationShortcutStyle {
        if let stored = defaults.string(forKey: shortcutStyleKey),
           let style = DictationShortcutStyle(rawValue: stored) {
            return style
        }
        let isExistingUser = defaults.object(forKey: "holdShortcut") != nil
            || defaults.object(forKey: "toggleShortcut") != nil
            || defaults.bool(forKey: "whispur.onboarding.completed")
        return isExistingUser ? .separate : newInstallDefault
    }

    /// Fn unless the user picked another key. Double-press bindings can't
    /// be held, so they fall back to Fn too.
    static func loadTapOrHoldShortcut(defaults: UserDefaults = .standard) -> ShortcutBinding {
        guard let stored = defaults.string(forKey: tapOrHoldShortcutKey),
              let binding = ShortcutBinding(storageValue: stored),
              !binding.isDoublePress else {
            return .fnKey
        }
        return binding
    }

    private func persistShortcut(_ binding: ShortcutBinding?, forKey key: String) {
        UserDefaults.standard.set(binding?.storageValue ?? "off", forKey: key)
    }
}
