import AppKit
import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Pipeline")

@MainActor
final class DictationPipeline: ObservableObject {
    static let waveformSampleCount = 28

    @Published private(set) var phase: PipelinePhase = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioSamples: [Float] = Array(repeating: 0, count: DictationPipeline.waveformSampleCount)
    @Published private(set) var lastResult: PipelineResult?
    @Published private(set) var activeTriggerMode: RecordingTriggerMode = .hold
    /// True when we haven't heard audible input for ~1.3s while recording.
    /// Use this to prompt the user to check their mic/input device.
    @Published private(set) var isHearingSilence: Bool = false
    /// Words heard so far while streaming, for the overlay. Empty when not
    /// streaming.
    @Published private(set) var liveTranscript: String = ""

    private var silentSampleCount: Int = 0
    private static let silenceLevelThreshold: Float = 0.05
    private static let silenceTickThreshold: Int = 60  // ~1.3s at ~47Hz

    // Voice-activity gate thresholds (applied to raw per-buffer RMS captured
    // by AudioRecorder). STT providers — Whisper especially — hallucinate
    // confident-sounding text on silent audio ("Thanks for watching!"), so
    // we skip STT entirely when a recording doesn't contain enough speech.
    //
    // The gate combines three signals so a single loud click or steady hum
    // doesn't get mistaken for speech:
    //   1. Total duration must exceed `minRecordingSeconds`.
    //   2. An adaptive threshold is derived from the quietest observed
    //      buffer (noise floor) so quiet rooms and noisy cafés are handled
    //      differently. `absoluteFloorRMS` prevents a dead channel from
    //      passing via 0 × multiplier == 0.
    //   3. The cumulative time spent above that threshold must exceed
    //      `minVoicedSeconds`; a single spike can beat the threshold once
    //      but not for long enough to be speech.
    //
    // Voiced time is counted in whole tap buffers (~85-100 ms each), so
    // 0.3 s needed three or four loud buffers and dropped short one-word
    // dictations ("yes", "no", "okay"). Two buffers is still more than a
    // click or a bump, which fills one.
    nonisolated static let minRecordingSeconds: Double = 0.3
    nonisolated static let minVoicedSeconds: Double = 0.15
    private static let noiseFloorMultiplier: Float = 3.0
    private static let absoluteFloorRMS: Float = 0.005

    private let recorder: AudioRecorder
    private let registry: ProviderRegistry
    private let historyStore: PipelineHistoryStore
    private let httpClient: ProviderHTTPClient?

    var selectedSTT: STTProviderID = .apple
    /// Whether Parakeet's model is on disk. While it isn't, a Parakeet
    /// selection transcribes with Apple on-device (`STTRoute`). Injectable
    /// for tests.
    var parakeetInstalled: () -> Bool = { ParakeetModelLocation.isInstalled(.current) }
    /// The provider that transcribed the current (or latest) recording in a
    /// batch request. Nil while nothing has been sent, and for a streamed
    /// transcript, which always comes from `selectedSTT`.
    private(set) var lastRoute: STTRoute?
    /// Replaces the registry's speech providers. Tests only.
    var sttProviderOverride: ((STTProviderID) -> (any STTProvider)?)?
    var selectedLLM: LLMProviderID = .anthropic
    /// The "Clean up with AI" switch. While off, no cleanup request is made:
    /// the transcript is pasted with only the spoken edit commands and text
    /// fixes applied.
    var cleanupEnabled: Bool = true
    /// Fillers, spoken quotes and spoken symbols, fixed in code on every
    /// dictation (`TextFixes`). The quote style follows the app.
    var textFixOptions = TextFixOptions()
    /// Adds a leading space when the cursor sits right after a word
    /// (`SmartSpacing`).
    var smartSpacingEnabled = true
    /// Reads what sits before the cursor in the focused field. Injectable
    /// for tests.
    var readBeforeCursor: () async -> SmartSpacing.Before = {
        await Task.detached(priority: .userInitiated) { SmartSpacing.readBeforeCursor() }.value
    }
    /// The dictation whose paste got a leading space from smart spacing, so
    /// "Use raw" can paste the raw transcript the same way.
    private(set) var smartSpacedDictationID: UUID?
    /// Replaces the registry's cleanup providers. Tests only.
    var llmProviderOverride: ((LLMProviderID) -> (any LLMProvider)?)?
    var sttLanguageSelection: STTLanguageSelection = .auto
    var customVocabulary: [String] = []
    /// The dictionary's "heard as" spellings: clear-cut ones replaced in
    /// code with the text fixes, ambiguous ones sent to cleanup as hints.
    var aliasPlan: VocabularyAliasPlan = .empty
    var systemPrompt: String = Prompts.defaultCleanup
    /// Picks the cleanup style for the app the recording started in. When
    /// nil, cleanup uses `systemPrompt` as is.
    var cleanupStyle: ((_ bundleID: String?) -> CleanupStyleChoice)?
    /// Reads the frontmost app's bundle id (injectable for tests).
    var frontmostBundleID: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    /// The app that was frontmost when the current recording started.
    private(set) var recordingAppBundleID: String?
    var preserveClipboard: Bool = true
    var soundVolume: Float = 1.0
    /// When true, duck the system default output device while recording.
    /// The reduction amount comes from `systemAudioReductionPercent`.
    var muteSystemAudioWhileRecording: Bool = false
    /// 0...100. 0 = no ducking, 100 = full mute. Only consulted when
    /// `muteSystemAudioWhileRecording` is true.
    var systemAudioReductionPercent: Int = 100
    /// Opt-in: stream audio to providers that support it while the user
    /// talks. The recording is still written and is the fallback.
    var streamingEnabled: Bool = false

    /// How long to wait after release for a streamed transcript before
    /// falling back to a batch request with the same recording.
    static let streamFinishTimeout: Duration = .seconds(5)

    private var streamingSession: STTStreamingSession? {
        didSet { if streamingSession == nil { liveTranscript = "" } }
    }

    /// Whether this recording streams, so the overlay can make room for
    /// live words before the first ones arrive.
    var streamsLiveTranscript: Bool {
        streamingEnabled && selectedSTT.supportsStreaming
    }

    private let systemAudioMuter = SystemAudioMuter()

    /// Fires with the final pasted text right after `TextInjector.paste`
    /// returns. Used by the learning module to snapshot the focused field
    /// before the user starts editing.
    var onPasteCompleted: ((String) -> Void)?
    /// Fires once a pasted dictation is saved to history ("Use raw").
    var onDictationPasted: ((PipelineResult) -> Void)?
    /// Takes the final text instead of the simulated paste when it returns
    /// true. Onboarding's "Try it" step sets this while its own window is in
    /// front, so the text lands in its field directly rather than through
    /// the clipboard and a synthetic Cmd+V into Whispur itself.
    var deliverInsteadOfPasting: (@MainActor (String) -> Bool)?

    private var audioLevelCancellable: AnyCancellable?
    /// Bumped by every start, stop and cancel, so a recorder start that
    /// finishes after the user already let go can tell it is stale.
    private var recordingGeneration = 0
    /// Last microphone permission read; lets a start show the overlay
    /// before the permission is read again. Seeded at init.
    private var lastKnownMicrophoneStatus: AVAuthorizationStatus?
    private var microphoneRequestTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    /// The last cleanup warm-up, so `warmCleanupConnection` can skip one the
    /// connection doesn't need yet.
    private var lastCleanupWarmup: (origin: URL, at: Date)?
    static let cleanupWarmupReuseWindow: TimeInterval = 30

    /// A recorder started at shortcut key-down, before the press is known
    /// to be a hold (see `beginEarlyCapture`). Nil once a start adopts it or
    /// it is discarded. The phase stays where it was while it runs: no
    /// overlay, no sound.
    private struct EarlyCaptureState {
        let generation: Int
        var engineStarted = false
        var heardAudio = false
    }
    private var earlyCapture: EarlyCaptureState?
    /// The current recording was adopted from an early capture, for
    /// diagnostics.
    private var recordingUsedEarlyCapture = false
    private var earlyCaptureWatchdog: Task<Void, Never>?
    /// The longest an early capture runs without a start adopting it. The
    /// shortcut decides within its 0.33 s arm window; this only makes sure a
    /// lost resolution can't leave the microphone on.
    static let earlyCaptureTimeout: Duration = .seconds(2)

    init(
        recorder: AudioRecorder,
        registry: ProviderRegistry,
        historyStore: PipelineHistoryStore,
        httpClient: ProviderHTTPClient? = nil
    ) {
        self.recorder = recorder
        self.registry = registry
        self.historyStore = historyStore
        self.httpClient = httpClient

        Task { [weak self] in
            let status = await Self.readMicrophoneStatus()
            if self?.lastKnownMicrophoneStatus == nil {
                self?.lastKnownMicrophoneStatus = status
            }
        }
    }

    var canStartRecording: Bool {
        switch phase {
        case .idle, .done, .error:
            return true
        default:
            return false
        }
    }

    var canStopRecording: Bool {
        switch phase {
        case .starting, .recording:
            return true
        default:
            return false
        }
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return "Ready to Dictate"
        case .requestingMicrophonePermission:
            return "Waiting for Microphone Access"
        case .starting:
            return "Starting Recorder"
        case .recording:
            return activeTriggerMode == .hold ? "Listening" : "Recording"
        case .normalizingAudio:
            return "Normalizing Audio"
        case .transcribing:
            return "Transcribing"
        case .cleaningTranscript:
            return "Cleaning Transcript"
        case .pasting:
            return "Pasting Text"
        case .done:
            return "Finished"
        case .error:
            return "Error"
        }
    }

    var statusDetail: String? {
        switch phase {
        case .idle:
            return "Use the menu bar to start and stop dictation."
        case .requestingMicrophonePermission:
            return "Approve microphone access to begin recording."
        case .starting:
            return activeTriggerMode == .hold
                ? "Preparing a hold-to-talk recording."
                : "Preparing a toggle recording."
        case .recording:
            return activeTriggerMode == .hold
                ? "Speak now, then release your shortcut to stop."
                : "Speak now, then use your toggle shortcut or press Stop."
        case .normalizingAudio:
            return "Converting the captured audio to 16 kHz mono WAV."
        case .transcribing:
            let provider = lastRoute?.provider ?? selectedSTT
            return provider.runsOnDevice
                ? "Transcribing on this Mac with \(provider.displayName)."
                : "Sending the recording to \(provider.displayName)."
        case .cleaningTranscript:
            return "Polishing the raw transcript before paste."
        case .pasting:
            return "Injecting the transcript into the active app."
        case .done(let text):
            return text
        case .error(let message):
            return message
        }
    }

    func startRecording(triggerMode: RecordingTriggerMode = .hold) {
        guard canStartRecording else {
            discardEarlyCapture()
            return
        }
        noteRecordingApp()
        warmCleanupConnection()

        cancelResetTask()
        activeTriggerMode = triggerMode
        if let early = earlyCapture, early.generation == recordingGeneration {
            adoptEarlyCapture(early)
            return
        }
        if lastKnownMicrophoneStatus == .authorized {
            // Show the overlay now, in this turn; the recorder warms up in
            // the background and flips it to `.recording` on first audio.
            // The status is confirmed below, before the recorder starts.
            phase = .starting
            StartLatencyTrace.mark("overlay requested (.starting)")
        } else {
            if case .done = phase { phase = .idle }
            if case .error = phase { phase = .idle }
        }

        microphoneRequestTask?.cancel()
        microphoneRequestTask = Task { [weak self] in
            let status = await Self.readMicrophoneStatus()
            guard let self, !Task.isCancelled else { return }
            self.lastKnownMicrophoneStatus = status
            await self.requestMicrophoneAccessAndBeginRecording(status: status)
        }
    }

    /// Starts the recorder quietly at shortcut key-down, while the shortcut
    /// waits to tell a hold from a tap or a chord, so the words said during
    /// that wait are captured. `startRecording` adopts it, keeping the audio
    /// from key-down; `discardEarlyCapture` throws it away.
    ///
    /// Only with microphone access already granted: a permission prompt is
    /// the normal start's job. A failure stays quiet; the normal start then
    /// tries again and reports it.
    func beginEarlyCapture() {
        guard earlyCapture == nil, canStartRecording,
              lastKnownMicrophoneStatus == .authorized,
              microphoneRequestTask == nil
        else { return }

        recordingGeneration &+= 1
        let generation = recordingGeneration
        earlyCapture = EarlyCaptureState(generation: generation)
        recorder.onAudioBuffer = nil
        recorder.onRecordingReady = { [weak self] in
            Task { @MainActor in self?.recorderHeardFirstAudio(generation: generation) }
        }
        earlyCaptureWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.earlyCaptureTimeout)
            guard !Task.isCancelled, let self, self.earlyCapture?.generation == generation else { return }
            logger.notice("Early capture timed out without a start")
            self.discardEarlyCapture()
        }
        StartLatencyTrace.mark("early capture requested")

        // The start runs in a later turn; a discard can come first. The
        // ticket, taken now, makes the recorder refuse a start whose capture
        // was already discarded, instead of opening the microphone after the
        // discard's stop found nothing to stop.
        let ticket = recorder.startTicket()
        Task { [weak self] in
            await self?.startRecorder(generation: generation, holdingAudio: true, ticket: ticket)
        }
        // The permission can be revoked while Whispur runs. Recheck it beside
        // the start instead of before it; if it is gone, the normal start
        // takes over and shows the right message.
        let assumedStatus = microphoneStatusForTesting
        Task { [weak self] in
            let status: AVAuthorizationStatus
            if let assumedStatus { status = assumedStatus } else { status = await Self.readMicrophoneStatus() }
            guard let self else { return }
            self.lastKnownMicrophoneStatus = status
            if status != .authorized, self.earlyCapture?.generation == generation {
                self.discardEarlyCapture()
            }
        }
    }

    /// Test seam: the microphone permission `beginEarlyCapture` sees, both
    /// up front and in its recheck, instead of the system's.
    private var microphoneStatusForTesting: AVAuthorizationStatus?
    func assumeMicrophoneStatusForTesting(_ status: AVAuthorizationStatus) {
        microphoneStatusForTesting = status
        lastKnownMicrophoneStatus = status
    }

    /// Stops and deletes an early capture no start adopted (the press was a
    /// tap or a chord). Silent: no overlay, sound, history entry or file.
    func discardEarlyCapture() {
        guard let early = endEarlyCapture() else { return }
        guard early.generation == recordingGeneration else { return }
        recordingGeneration &+= 1
        recorder.onRecordingReady = nil
        recorder.onAudioBuffer = nil
        recorder.discardRecording()
        logger.info("Early capture discarded")
    }

    @discardableResult
    private func endEarlyCapture() -> EarlyCaptureState? {
        let early = earlyCapture
        earlyCapture = nil
        earlyCaptureWatchdog?.cancel()
        earlyCaptureWatchdog = nil
        return early
    }

    /// The shortcut became a recording: show it and keep the audio the
    /// early capture has from key-down. Whatever the recorder has not done
    /// yet, `startRecorder` finishes when it gets there.
    private func adoptEarlyCapture(_ early: EarlyCaptureState) {
        endEarlyCapture()
        recordingUsedEarlyCapture = true
        phase = .starting
        StartLatencyTrace.mark("overlay requested (.starting, early capture)")
        startStreamingIfEnabled()
        if early.heardAudio {
            recorderHeardFirstAudio(generation: early.generation)
        }
        if early.engineStarted {
            finishStartingSession()
        }
    }

    /// Remembers the frontmost app as recording starts, so cleanup uses that
    /// app's style even if the user switches apps while Whispur works.
    func noteRecordingApp() {
        recordingAppBundleID = frontmostBundleID()
    }

    /// The style and system prompt for the app the recording started in.
    func cleanupChoice() -> CleanupStyleChoice? {
        cleanupStyle?(recordingAppBundleID)
    }

    func updateTriggerMode(_ triggerMode: RecordingTriggerMode) {
        activeTriggerMode = triggerMode
    }

    func stopAndProcess() {
        guard canStopRecording else { return }

        let wasStarting = phase == .starting
        recordingGeneration &+= 1
        cancelResetTask()
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        audioLevel = 0

        recorder.onRecordingReady = nil

        let stopped = recorder.stopRecording()
        recorder.onAudioBuffer = nil
        let stream = streamingSession
        streamingSession = nil

        guard let stopped else {
            stream?.cancel()
            systemAudioMuter.restore()
            resetAudioSamples()
            if wasStarting {
                // Released before the recorder was even asked to start:
                // nothing was said, so just put the overlay away.
                recordDiagnostics(DictationDiagnostics(outcome: .cancelled, stage: .recording))
                activeTriggerMode = .hold
                phase = .idle
            } else {
                presentError("No audio was captured.", stage: .recording)
            }
            return
        }

        systemAudioMuter.restore()

        playSound(.pop)

        resetAudioSamples()
        processingTask?.cancel()
        let usedEarlyCapture = recordingUsedEarlyCapture
        processingTask = Task { [weak self] in
            await self?.processRecording(
                at: stopped.url,
                metrics: stopped.metrics,
                stream: stream,
                usedEarlyCapture: usedEarlyCapture
            )
        }
    }

    func cancel() {
        // A recording in progress (not one already processing, which records
        // its own cancel) gets a diagnostics record.
        let wasRecording = phase == .starting || phase == .recording
        recordingGeneration &+= 1
        endEarlyCapture()
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        processingTask?.cancel()
        processingTask = nil

        cancelResetTask()

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        recorder.onRecordingReady = nil
        let stopped = recorder.stopRecording()
        recorder.onAudioBuffer = nil
        if wasRecording {
            recordDiagnostics(DictationDiagnostics(
                outcome: .cancelled,
                stage: .recording,
                audio: stopped.map { DictationDiagnostics.Audio(metrics: $0.metrics, usedEarlyCapture: recordingUsedEarlyCapture) }
            ))
        }
        streamingSession?.cancel()
        streamingSession = nil
        recorder.cleanup()
        systemAudioMuter.restore()

        audioLevel = 0
        resetAudioSamples()
        activeTriggerMode = .hold
        phase = .idle
    }

    /// Safety net for the app lifecycle: invoked when the app is about to
    /// terminate so the user isn't left with a ducked output if they quit
    /// while a recording is in flight.
    func restoreSystemAudioIfNeeded() {
        systemAudioMuter.restore()
    }

    /// Shows an error that ended a dictation before its recording was
    /// processed (permissions, setup, the recorder), and keeps a diagnostics
    /// record of it.
    func presentError(_ message: String, stage: DictationDiagnostics.Stage = .other) {
        let diagnostics = DictationDiagnostics(outcome: .failed, stage: stage, errorMessage: message)
        recordDiagnostics(diagnostics)
        showError(message, dictationID: diagnostics.id)
    }

    /// Puts the overlay in its error state. Callers keep the diagnostics
    /// record themselves.
    private func showError(_ message: String, dictationID: UUID) {
        logger.error("Pipeline error in dictation \(dictationID.uuidString, privacy: .public): \(message, privacy: .public)")
        phase = .error(message)
        scheduleResetToIdle()
    }

    /// Reading the microphone permission costs ~10-20 ms, so it happens off
    /// the main thread and never holds back the overlay.
    private nonisolated static func readMicrophoneStatus() async -> AVAuthorizationStatus {
        await Task.detached(priority: .userInitiated) {
            AVCaptureDevice.authorizationStatus(for: .audio)
        }.value
    }

    private func requestMicrophoneAccessAndBeginRecording(status: AVAuthorizationStatus) async {
        defer {
            microphoneRequestTask = nil
        }

        switch status {
        case .authorized:
            guard !Task.isCancelled else { return }
            await beginRecording()
        case .notDetermined:
            phase = .requestingMicrophonePermission
            // The system permission dialog can linger indefinitely if the user
            // ignores it. Cap the wait so the pipeline can recover instead of
            // hanging forever in `.requestingMicrophonePermission`.
            let granted = await withTaskGroup(of: Bool?.self, returning: Bool?.self) { group in
                group.addTask { await AudioRecorder.requestMicrophoneAccess() }
                group.addTask {
                    try? await Task.sleep(for: .seconds(30))
                    return nil
                }
                defer { group.cancelAll() }
                return await group.next() ?? nil
            }
            guard !Task.isCancelled else { return }

            switch granted {
            case .some(true):
                await beginRecording()
            case .some(false):
                presentError("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.", stage: .recording)
            case .none:
                presentError("Microphone permission request timed out. Try again or grant access in System Settings > Privacy & Security > Microphone.", stage: .recording)
            }
        case .restricted, .denied:
            presentError("Microphone access is unavailable. Enable it in System Settings > Privacy & Security > Microphone.", stage: .recording)
        @unknown default:
            presentError("Whispur could not determine microphone permissions.", stage: .recording)
        }
    }

    private func beginRecording() async {
        // Move out of `.idle` before touching the recorder so stop events are
        // never dropped even if the user stops immediately. A discarded
        // early capture may still be stopping; the recorder serializes this
        // start after it.
        phase = .starting
        recordingGeneration &+= 1
        let generation = recordingGeneration
        recordingUsedEarlyCapture = false

        recorder.onRecordingReady = { [weak self] in
            Task { @MainActor in self?.recorderHeardFirstAudio(generation: generation) }
        }

        startStreamingIfEnabled()
        await startRecorder(generation: generation, holdingAudio: false)
    }

    /// Starts the engine for `generation` and, once it runs, finishes the
    /// session if a start owns it by then. An early capture nobody adopted
    /// yet only notes that the engine runs.
    private func startRecorder(generation: Int, holdingAudio: Bool, ticket: Int? = nil) async {
        do {
            try await recorder.startRecording(holdingAudioUntilHandler: holdingAudio, ticket: ticket)
        } catch {
            guard generation == recordingGeneration else { return }
            if earlyCapture?.generation == generation {
                logger.notice("Early capture failed to start: \(error.localizedDescription, privacy: .public)")
                discardEarlyCapture()
                return
            }
            recorder.onAudioBuffer = nil
            streamingSession?.cancel()
            streamingSession = nil
            presentError(error.localizedDescription, stage: .recording)
            return
        }
        StartLatencyTrace.mark("audio engine started")

        // A stop or cancel while the engine warmed up already stopped it
        // (the recorder serializes them after the start) and moved on.
        guard generation == recordingGeneration else { return }
        if earlyCapture?.generation == generation {
            earlyCapture?.engineStarted = true
            return
        }
        guard canStopRecording else { return }
        finishStartingSession()
    }

    /// The first non-silent audio: the overlay goes live and the start
    /// sound plays. An early capture only remembers it for its adoption.
    private func recorderHeardFirstAudio(generation: Int) {
        guard generation == recordingGeneration else { return }
        if earlyCapture?.generation == generation {
            earlyCapture?.heardAudio = true
            return
        }
        guard case .starting = phase else { return }

        phase = .recording
        playSound(.tink)
        StartLatencyTrace.finish("listening (first audio, start sound)")
    }

    /// The engine runs and a start owns it: duck system audio and feed the
    /// waveform.
    private func finishStartingSession() {
        if muteSystemAudioWhileRecording {
            systemAudioMuter.mute(reductionPercent: systemAudioReductionPercent)
        }

        resetAudioSamples()
        audioLevelCancellable = recorder.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.pushAudioSample(level)
            }

        logger.info("Recording session started")
    }

    /// Opens a live session for the selected provider when streaming is on
    /// and the provider supports it. Audio flows from the recorder's tap.
    private func startStreamingIfEnabled() {
        streamingSession?.cancel()
        streamingSession = nil
        recorder.onAudioBuffer = nil

        guard streamingEnabled,
              selectedSTT.supportsStreaming,
              let provider = registry.makeStreamingProvider(for: selectedSTT)
        else {
            recorder.dropHeldAudio()
            return
        }

        let session = provider.makeStreamingSession(language: sttLanguageSelection, vocabulary: customVocabulary)
        let converter = LivePCMConverter(targetSampleRate: provider.streamingSampleRate)
        // Arrives on the socket's receive task; the audio path never waits
        // on the overlay.
        session.onPartial = { [weak self, weak session] text in
            Task { @MainActor [weak self] in
                guard let self, let session, self.streamingSession === session else { return }
                self.liveTranscript = text
            }
        }
        // Set after an early capture, this first replays the audio it held
        // from key-down, so the stream hears the first word too.
        session.start()
        recorder.onAudioBuffer = { buffer in
            session.append(converter.convert(buffer))
        }
        streamingSession = session
        logger.info("Streaming to \(self.selectedSTT.rawValue, privacy: .public)")
    }

    /// Lists a finished stream in the Requests tab and the log.
    private func report(_ outcome: StreamingFallback.Outcome, for stream: STTStreamingSession) {
        if let error = outcome.error {
            logger.warning("Streaming failed, using batch transcription: \(error.localizedDescription, privacy: .public)")
        } else {
            logger.info("Streamed transcript arrived \(outcome.elapsedMS, privacy: .public) ms after release")
        }
        httpClient?.recordStream(
            providerID: stream.providerID.rawValue,
            endpointURL: stream.endpointDescription,
            durationMS: outcome.elapsedMS,
            responsePreview: outcome.text ?? "",
            errorMessage: outcome.error.map { $0.localizedDescription + " Fell back to batch transcription." }
        )
    }

    private func processRecording(
        at recordedURL: URL,
        metrics: RecordingMetrics,
        stream: STTStreamingSession?,
        usedEarlyCapture: Bool = false,
        dictationID: UUID = UUID()
    ) async {
        defer {
            processingTask = nil
        }

        defer {
            recorder.cleanup()
        }

        // Every way out of here keeps a diagnostics record. It starts as
        // "ended without an outcome" and each path below says how it ended.
        var diagnostics = DictationDiagnostics.unfinished(
            id: dictationID,
            audio: DictationDiagnostics.Audio(metrics: metrics, usedEarlyCapture: usedEarlyCapture)
        )
        diagnostics.stage = .recording
        defer { recordDiagnostics(diagnostics) }

        // Skip STT entirely if the recording doesn't contain enough speech.
        // See `minRecordingSeconds` / `noiseFloorMultiplier` comments above for
        // rationale. Providers hallucinate confidently on silent audio, so
        // gating aggressively here saves both a request and a bad paste.
        if !Self.recordingHasSpeech(metrics: metrics) {
            stream?.cancel()
            try? FileManager.default.removeItem(at: recordedURL)
            diagnostics.outcome = .noSpeech
            diagnostics.errorMessage = nil
            dismissForNoSpeech()
            return
        }

        // The recording is always normalized, even while a stream is
        // finishing: it is the fallback if streaming fails, and the copy kept
        // for a retry if the dictation fails. Removed at the end unless a
        // failure moved it into the failed-audio folder.
        phase = stream == nil ? .normalizingAudio : .transcribing
        diagnostics.stage = stream == nil ? .normalization : .transcription
        let normalization = Task.detached(priority: .userInitiated) {
            try AudioNormalization.normalizeMeasured(recordedURL)
        }
        defer {
            // Holds the stores, not the pipeline: this outlives the dictation.
            Task { [historyStore] in
                let normalized = try? await normalization.value
                Self.finishNormalizedAudio(normalized, dictationID: dictationID, history: historyStore)
            }
        }
        lastRoute = nil
        let transcriptionStarted = ContinuousClock.now

        do {

            // The connection was warmed when recording started. A long
            // recording can outlive an idle connection, so warm again here
            // if that warm-up is stale (see `warmCleanupConnection`).
            warmCleanupConnection()

            let rawTranscript = try await ProviderRequestContext.$dictationID.withValue(dictationID) {
                try await StreamingFallback.transcript(
                stream: stream,
                timeout: Self.streamFinishTimeout,
                report: { [weak self] outcome in
                    guard let self, let stream else { return }
                    self.report(outcome, for: stream)
                },
                accept: { [sttLanguageSelection] text in
                    guard let check = ScriptGuard.check(text, for: sttLanguageSelection), check.fails else { return nil }
                    let scripts = check.unexpectedScripts.map(\.rawValue).sorted().joined(separator: ", ")
                    return "The streamed transcript used \(scripts) letters, which none of your languages use."
                },
                retryRejected: { [self] rejected in
                    try await batchTranscript(wavURL: try await normalization.value.url, initial: rejected)
                },
                batch: { [self] in
                    try await batchTranscript(wavURL: try await normalization.value.url, initial: nil)
                }
                )
            }
            diagnostics.transcription = transcriptionDiagnostics(
                stream: stream,
                since: transcriptionStarted,
                rawTranscript: rawTranscript,
                recordingSeconds: metrics.totalDurationSeconds
            )
            diagnostics.stage = .transcription
            guard let normalizedRawTranscript = TranscriptDecision.normalizedRawTranscript(rawTranscript) else {
                diagnostics.outcome = .noSpeech
                diagnostics.errorMessage = nil
                dismissForNoSpeech()
                return
            }

            diagnostics.stage = .cleanup
            let styleChoice = cleanupChoice()
            let decided = await ProviderRequestContext.$dictationID.withValue(dictationID) {
                await decideText(
                    forRaw: normalizedRawTranscript,
                    styleChoice: styleChoice,
                    appBundleID: recordingAppBundleID,
                    updatesPhase: true
                )
            }
            guard let decided else {
                diagnostics.outcome = .noSpeech
                diagnostics.errorMessage = nil
                dismissForNoSpeech()
                return
            }
            let finalTranscript = decided.text
            diagnostics.cleanup = cleanupDiagnostics(decided)

            guard !Task.isCancelled else { throw CancellationError() }

            phase = .pasting
            diagnostics.stage = .paste
            let delivered = deliverInsteadOfPasting?(finalTranscript) == true
            let pasteText = delivered ? finalTranscript : await smartSpaced(finalTranscript)
            if !delivered {
                await TextInjector.paste(pasteText, preserveClipboard: preserveClipboard)
            }

            guard !Task.isCancelled else { throw CancellationError() }

            // Learning and "Use raw" act on another app's field; a dictation
            // delivered into Whispur's own window skips both.
            if !delivered { onPasteCompleted?(finalTranscript) }

            let result = PipelineResult(
                id: dictationID,
                rawTranscript: normalizedRawTranscript,
                cleanedText: finalTranscript,
                sttProvider: lastRoute?.provider ?? selectedSTT,
                llmProvider: selectedLLM,
                llmModel: decided.llmModel,
                timestamp: Date(),
                appBundleID: recordingAppBundleID,
                style: decided.style,
                sttFallbackFrom: lastRoute?.fallbackFrom,
                cleanupOff: decided.cleanupOff
            )

            smartSpacedDictationID = pasteText == finalTranscript ? nil : result.id
            lastResult = result
            historyStore.add(result)
            if !delivered { onDictationPasted?(result) }

            diagnostics.outcome = .success
            diagnostics.errorMessage = nil
            phase = .done(finalTranscript)
            scheduleResetToIdle(after: .milliseconds(1200))
        } catch is CancellationError {
            diagnostics.outcome = .cancelled
            diagnostics.errorMessage = nil
            // A batch request starts only once normalization is done.
            if diagnostics.stage == .normalization, lastRoute != nil { diagnostics.stage = .transcription }
            phase = .idle
        } catch {
            // URLSession throws URLError.cancelled when its Task is cancelled
            // mid-request; treat it as a clean cancel rather than surfacing
            // a misleading "cancelled" error banner.
            if !DictationFailureClassifier.isFailure(error, taskCancelled: Task.isCancelled) {
                diagnostics.outcome = .cancelled
                diagnostics.errorMessage = nil
                if diagnostics.stage == .normalization, lastRoute != nil { diagnostics.stage = .transcription }
                phase = .idle
            } else {
                let normalized = try? await normalization.value
                diagnostics.outcome = .failed
                diagnostics.errorMessage = error.localizedDescription
                // A batch transcription waits for normalization; when that
                // failed, the error is normalization's.
                if normalized == nil, diagnostics.stage == .normalization || diagnostics.stage == .transcription {
                    diagnostics.stage = .normalization
                } else if diagnostics.stage == .normalization {
                    diagnostics.stage = .transcription
                }
                if diagnostics.transcription == nil, diagnostics.stage == .transcription {
                    diagnostics.transcription = transcriptionDiagnostics(
                        stream: stream,
                        since: transcriptionStarted,
                        rawTranscript: nil,
                        recordingSeconds: metrics.totalDurationSeconds
                    )
                }
                // Keep the recording so the user can retry from Activity.
                historyStore.recordFailure(
                    id: dictationID,
                    error: error.localizedDescription,
                    wavURL: normalized?.url,
                    sttProvider: lastRoute?.provider ?? selectedSTT,
                    sttFallbackFrom: lastRoute?.fallbackFrom,
                    llmProvider: selectedLLM,
                    appBundleID: recordingAppBundleID,
                    style: cleanupChoice()?.style
                )
                showError(error.localizedDescription, dictationID: dictationID)
            }
        }
    }

    /// Transcription signals for diagnostics. `rawTranscript` is nil when
    /// transcription failed.
    private func transcriptionDiagnostics(
        stream: STTStreamingSession?,
        since started: ContinuousClock.Instant,
        rawTranscript: String?,
        recordingSeconds: Double
    ) -> DictationDiagnostics.Transcription {
        let provider = lastRoute?.provider ?? selectedSTT
        let raw = rawTranscript?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictationDiagnostics.Transcription(
            provider: provider,
            model: DictationDiagnostics.sttModel(for: provider),
            fallbackFrom: lastRoute?.fallbackFrom,
            streamed: stream != nil,
            streamFellBack: stream != nil && lastRoute != nil,
            latencyMS: Int(started.duration(to: .now) / .milliseconds(1)),
            rawCharacterCount: raw?.count,
            rawWordCount: raw.map(DictationDiagnostics.wordCount),
            charactersPerSecond: raw.flatMap {
                DictationDiagnostics.charactersPerSecond(characters: $0.count, seconds: recordingSeconds)
            }
        )
    }

    /// Cleanup signals for diagnostics.
    private func cleanupDiagnostics(_ decided: DecidedText) -> DictationDiagnostics.Cleanup {
        DictationDiagnostics.Cleanup(
            provider: decided.cleanupOff ? nil : selectedLLM,
            model: decided.llmModel,
            latencyMS: decided.cleanupLatencyMS,
            cleanedCharacterCount: decided.text.count,
            editDivergence: decided.editDivergence,
            rawFallbackReason: decided.rawFallbackReason?.rawValue,
            cleanupOff: decided.cleanupOff,
            error: decided.cleanupError
        )
    }

    /// Saves a dictation's diagnostics, marks its history entry when it
    /// looks wrong (`DictationAnomaly`), and logs a one-line summary at a
    /// level macOS keeps.
    private func recordDiagnostics(_ diagnostics: DictationDiagnostics) {
        var diagnostics = diagnostics
        let reasons = DictationAnomaly.reasons(for: diagnostics)
        diagnostics.anomalies = reasons.isEmpty ? nil : reasons
        historyStore.diagnostics.record(diagnostics)
        if diagnostics.outcome == .success {
            historyStore.markAnomalous(diagnostics.id, reasons: reasons)
        }
        let id = diagnostics.id.uuidString
        switch diagnostics.outcome {
        case .failed:
            logger.error("Dictation \(id, privacy: .public): \(diagnostics.summary, privacy: .public). \(diagnostics.errorMessage ?? "", privacy: .public)")
        case .success, .cancelled, .noSpeech:
            logger.notice("Dictation \(id, privacy: .public): \(diagnostics.summary, privacy: .public)")
        }
        if diagnostics.outcome == .success, !reasons.isEmpty {
            let labels = reasons.map(\.rawValue).joined(separator: ", ")
            logger.notice("Dictation \(id, privacy: .public) looks anomalous (\(labels, privacy: .public)); keeping its recording for 24 hours")
        }
    }

    /// Runs once a dictation is over and its normalization has finished:
    /// notes the normalized length in diagnostics, keeps the WAV when the
    /// dictation looked anomalous, and otherwise deletes it (a failure has
    /// already moved it into the failed-audio folder).
    private static func finishNormalizedAudio(_ normalized: NormalizedAudio?, dictationID: UUID, history: PipelineHistoryStore) {
        guard let normalized else { return }
        history.diagnostics.update(dictationID) { record in
            record.audio?.normalizedSeconds = normalized.durationSeconds
            record.audio?.normalizedSampleCount = normalized.sampleCount
        }
        if FileManager.default.fileExists(atPath: normalized.url.path) {
            history.keepAnomalyAudio(dictationID, wavURL: normalized.url)
        }
        try? FileManager.default.removeItem(at: normalized.url)
    }

    /// The text a dictation pastes, from its normalized raw transcript.
    struct DecidedText: Equatable {
        let text: String
        /// The cleanup model, when cleanup ran and returned text.
        let llmModel: String?
        /// The style cleanup used, when it ran and returned text.
        let style: WritingStyle?
        /// Why the raw transcript was pasted instead of a cleanup. Nil when
        /// the cleanup was pasted, and when cleanup is switched off.
        let rawFallbackReason: TranscriptDecision.RawFallbackReason?
        /// Cleanup is switched off: the text is the transcript with only the
        /// spoken edit commands and text fixes applied, and no model saw it.
        let cleanupOff: Bool
        /// How long the cleanup request took, when one ran.
        var cleanupLatencyMS: Int? = nil
        /// The cleanup request's error, when it failed.
        var cleanupError: String? = nil
        /// Share of words cleanup changed (`DictationDiagnostics.editDivergence`),
        /// when its text is what gets pasted.
        var editDivergence: Double? = nil
    }

    /// Applies the spoken edit commands and the text fixes, then cleanup
    /// (unless it is switched off), then picks what to paste. Nil when there
    /// is nothing worth pasting.
    ///
    /// The text fixes run before cleanup, so the model reads "#release"
    /// rather than "hashtag release", and the raw-transcript fallback gets
    /// them too.
    func decideText(
        forRaw normalizedRaw: String,
        styleChoice: CleanupStyleChoice?,
        appBundleID: String? = nil,
        updatesPhase: Bool
    ) async -> DecidedText? {
        let spoken = TextFixes.apply(VoiceCommands.apply(to: normalizedRaw), options: textFixOptions(for: appBundleID))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanupEnabled else {
            guard case let .paste(text, _) = TranscriptDecision.finalOutcome(raw: spoken, cleaned: nil) else { return nil }
            return DecidedText(text: text, llmModel: nil, style: nil, rawFallbackReason: nil, cleanupOff: true)
        }
        let cleanup = await clean(spoken, styleChoice: styleChoice, updatesPhase: updatesPhase)
        switch TranscriptDecision.finalOutcome(raw: spoken, cleaned: cleanup.text) {
        case .dismiss:
            return nil
        case let .paste(text, rawFallbackReason):
            if let rawFallbackReason, cleanup.text != nil {
                logger.warning("Pasting raw transcript: \(rawFallbackReason.rawValue, privacy: .public)")
            }
            return DecidedText(
                text: text,
                llmModel: cleanup.llmModel,
                style: cleanup.style,
                rawFallbackReason: rawFallbackReason,
                cleanupOff: false,
                cleanupLatencyMS: cleanup.latencyMS,
                cleanupError: cleanup.error,
                editDivergence: rawFallbackReason == nil
                    ? DictationDiagnostics.editDivergence(raw: spoken, cleaned: text)
                    : nil
            )
        }
    }

    /// The text fixes for a dictation into `appBundleID`: straight quotes in
    /// code apps, curly quotes everywhere else.
    func textFixOptions(for appBundleID: String?) -> TextFixOptions {
        var options = textFixOptions
        options.spokenLanguages = sttLanguageSelection.codes
        options.vocabulary = aliasPlan.replacements
        options.quoteStyle = appBundleID.flatMap(AppGroup.group(for:)) == .code ? .straight : .curly
        return options
    }

    /// `text` with a leading space when smart spacing is on and the cursor in
    /// the frontmost app sits right after a word.
    private func smartSpaced(_ text: String) async -> String {
        guard smartSpacingEnabled else { return text }
        if let bundleID = frontmostBundleID(), SmartSpacing.excludedBundleIDs.contains(bundleID) { return text }
        return SmartSpacing.adjusted(text, before: await readBeforeCursor())
    }

    /// Opens the TCP/TLS connection to the cleanup endpoint before the
    /// cleanup request needs it. Called when recording starts, so the
    /// handshake (~200–500 ms cold) runs while the user is still talking
    /// instead of racing the request after a fast on-device transcript.
    ///
    /// Called again when processing starts, but it only fires if the last
    /// warm-up to this origin is older than `cleanupWarmupReuseWindow`.
    /// Neither URLSession nor the providers' front doors promise how long
    /// an idle connection survives, and load balancers commonly close idle
    /// ones after a minute (AWS ALB's default is 60 s), so a recording longer
    /// than the window may have lost the connection warmed at its start. The
    /// same window keeps rapid start/cancel presses from sending a burst of
    /// warm-up requests.
    func warmCleanupConnection() {
        guard cleanupEnabled,
              let client = httpClient,
              let origin = makeLLMProvider()?.endpointOrigin
        else { return }
        let now = Date()
        if let last = lastCleanupWarmup,
           last.origin == origin,
           now.timeIntervalSince(last.at) < Self.cleanupWarmupReuseWindow {
            return
        }
        lastCleanupWarmup = (origin, now)
        client.warmConnection(to: origin)
    }

    private func makeLLMProvider() -> (any LLMProvider)? {
        llmProviderOverride?(selectedLLM) ?? registry.makeLLMProvider(for: selectedLLM)
    }

    /// LLM cleanup of a raw transcript. A failure or skipped cleanup comes
    /// back as nil text, which `TranscriptDecision.finalOutcome` turns into a
    /// raw-transcript paste: never a failed dictation.
    private func clean(
        _ raw: String,
        styleChoice: CleanupStyleChoice?,
        updatesPhase: Bool
    ) async -> CleanupAttempt {
        // Skip LLM cleanup for very short transcripts: an LLM tends to
        // answer "thanks" instead of cleaning it. They are pasted raw.
        guard cleanupEnabled,
              TranscriptDecision.shouldRunCleanup(for: raw),
              let llmProvider = makeLLMProvider()
        else { return CleanupAttempt() }
        if updatesPhase { phase = .cleaningTranscript }

        let started = ContinuousClock.now
        func elapsedMS() -> Int { Int(started.duration(to: .now) / .milliseconds(1)) }
        do {
            let response = try await llmProvider.complete(
                request: LLMRequest(
                    systemPrompt: styleChoice?.systemPrompt ?? systemPrompt,
                    userMessage: CleanupMessage.userMessage(
                        transcript: raw,
                        vocabulary: customVocabulary,
                        heardAs: aliasPlan.heardAs
                    ),
                    maxTokens: LLMRequest.cleanupMaxTokens(
                        forTranscriptCharacters: raw.count
                    )
                )
            )
            let text = VoiceCommands.restoreLineBreaks(in: response.text, from: raw)
            return CleanupAttempt(text: text, llmModel: response.model, style: styleChoice?.style, latencyMS: elapsedMS())
        } catch {
            let dictation = ProviderRequestContext.dictationID?.uuidString ?? "none"
            logger.warning("LLM cleanup failed in dictation \(dictation, privacy: .public), using raw transcript: \(error.localizedDescription, privacy: .public)")
            return CleanupAttempt(latencyMS: elapsedMS(), error: error.localizedDescription)
        }
    }

    /// What one cleanup attempt returned. `text` is nil when cleanup didn't
    /// run or failed.
    private struct CleanupAttempt {
        var text: String?
        var llmModel: String?
        var style: WritingStyle?
        var latencyMS: Int?
        var error: String?
    }

    /// A retried dictation's text.
    struct RetryResult: Equatable {
        let rawTranscript: String
        let text: String
        let llmModel: String?
        let style: WritingStyle?
        /// Cleanup was switched off for the retry.
        var cleanupOff: Bool = false
    }

    enum RetryError: LocalizedError, Equatable {
        case noRecording
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .noRecording: "The recording for this dictation is no longer available."
            case .noSpeech: "No speech was found in the recording."
            }
        }
    }

    /// Re-runs transcription and cleanup on a failed dictation's kept
    /// recording, with the current providers and languages and the style of
    /// the app it was dictated in. Never touches the overlay or pastes.
    func retryTranscription(audioURL: URL, appBundleID: String?, dictationID: UUID) async throws -> RetryResult {
        let raw = try await ProviderRequestContext.$dictationID.withValue(dictationID) {
            try await batchTranscript(wavURL: audioURL, initial: nil, updatesPhase: false)
        }
        guard let normalizedRaw = TranscriptDecision.normalizedRawTranscript(raw) else {
            throw RetryError.noSpeech
        }
        let styleChoice = cleanupStyle?(appBundleID)
        let decided = await ProviderRequestContext.$dictationID.withValue(dictationID) {
            await decideText(forRaw: normalizedRaw, styleChoice: styleChoice, appBundleID: appBundleID, updatesPhase: false)
        }
        guard let decided else { throw RetryError.noSpeech }
        let cleaned = decided.rawFallbackReason == nil
        return RetryResult(
            rawTranscript: normalizedRaw,
            text: decided.text,
            llmModel: cleaned ? decided.llmModel : nil,
            style: cleaned ? decided.style : nil,
            cleanupOff: decided.cleanupOff
        )
    }

    /// Transcribes the normalized recording with the selected provider,
    /// with the script guard behind it for users who speak several
    /// languages. `initial` is a streamed transcript the guard already
    /// rejected.
    private func batchTranscript(wavURL: URL, initial: String?, updatesPhase: Bool = true) async throws -> String {
        let route = STTRoute.resolve(selected: selectedSTT, parakeetInstalled: parakeetInstalled())
        // A retry from Activity runs beside the live dictation; only the
        // live one owns `lastRoute`.
        if updatesPhase {
            lastRoute = route
            phase = .transcribing
        }
        guard let sttProvider = sttProviderOverride?(route.provider) ?? registry.makeSTTProvider(for: route.provider) else {
            throw STTError.missingAPIKey(provider: route.provider)
        }
        let started = ContinuousClock.now
        do {
            let text = try await transcribe(with: sttProvider, route: route, wavURL: wavURL, initial: initial)
            reportOnDevice(route, since: started, text: text, error: nil)
            return text
        } catch {
            if !(error is CancellationError) { reportOnDevice(route, since: started, text: nil, error: error) }
            throw error
        }
    }

    /// Lists a Parakeet selection's transcription in the Requests tab, so it
    /// shows whether Parakeet or the Apple fallback did the work. Other
    /// on-device transcriptions make no request and aren't listed.
    private func reportOnDevice(_ route: STTRoute, since started: ContinuousClock.Instant, text: String?, error: Error?) {
        guard route.provider == .parakeet || route.fallbackFrom != nil else { return }
        let elapsed = started.duration(to: .now)
        httpClient?.recordOnDevice(
            providerID: route.provider.rawValue,
            summary: Self.onDeviceSummary(for: route),
            durationMS: Int(elapsed / .milliseconds(1)),
            responsePreview: text ?? "",
            errorMessage: error?.localizedDescription
        )
    }

    static func onDeviceSummary(for route: STTRoute) -> String {
        if let from = route.fallbackFrom {
            return "Transcribed on this Mac with \(route.provider.displayName) because \(from.displayName)'s model isn't downloaded yet."
        }
        return "Transcribed on this Mac with \(route.provider.displayName)."
    }

    private func transcribe(with sttProvider: any STTProvider, route: STTRoute, wavURL: URL, initial: String?) async throws -> String {
        try await MultiLanguageTranscription.transcribe(
            provider: sttProvider,
            providerID: route.provider,
            fileURL: wavURL,
            language: sttLanguageSelection,
            vocabulary: customVocabulary,
            initial: initial,
            onGuard: { [httpClient] report in
                httpClient?.recordScriptGuard(
                    providerID: report.provider.rawValue,
                    summary: MultiLanguageTranscription.logSummary(report),
                    keptText: report.chosenText
                )
            }
        )
    }

    /// Decide whether a finished recording is worth sending to STT.
    ///
    /// Three gates, all must pass: total duration, per-buffer adaptive
    /// threshold, cumulative voiced time. The noise floor is the minimum RMS
    /// observed across the recording (excluding the very first buffer, which
    /// can be a zero-fill during engine warm-up). In a silent room this is
    /// near zero; in a café it's the ambient hum, so the threshold adapts.
    nonisolated static func recordingHasSpeech(metrics: RecordingMetrics) -> Bool {
        guard metrics.totalDurationSeconds >= Self.minRecordingSeconds else {
            logger.notice("Skipping STT: recording too short (\(metrics.totalDurationSeconds, privacy: .public)s)")
            return false
        }

        let series = metrics.buffers.dropFirst()
        guard !series.isEmpty, metrics.sampleRate > 0 else {
            logger.notice("Skipping STT: no buffer metrics available")
            return false
        }

        let threshold = Float(speechThreshold(metrics: metrics))
        let voicedFrames = series.reduce(Int64(0)) { acc, buffer in
            buffer.rms > threshold ? acc + Int64(buffer.frameCount) : acc
        }
        let voicedSeconds = Double(voicedFrames) / metrics.sampleRate

        if voicedSeconds < Self.minVoicedSeconds {
            logger.notice(
                "Skipping STT: voiced=\(voicedSeconds, privacy: .public)s threshold=\(threshold, privacy: .public)"
            )
            return false
        }
        return true
    }

    /// The per-buffer RMS a buffer must beat to count as voiced: three times
    /// the recording's noise floor (its quietest buffer after the first),
    /// and never below `absoluteFloorRMS`.
    nonisolated static func speechThreshold(metrics: RecordingMetrics) -> Double {
        let noiseFloor = metrics.buffers.dropFirst().map(\.rms).min() ?? 0
        return Double(max(noiseFloor * Self.noiseFloorMultiplier, Self.absoluteFloorRMS))
    }

    /// Close the overlay immediately and play a soft chime when the
    /// recording had no speech. Distinct from the tink→pop start/stop cues
    /// so the user knows the trigger registered but nothing was pasted.
    private func dismissForNoSpeech() {
        playSound(.bottle)
        cancelResetTask()
        activeTriggerMode = .hold
        phase = .idle
    }

    private func playSound(_ sound: NSSound?) {
        guard soundVolume > 0 else { return }
        sound?.stop()
        sound?.volume = soundVolume
        sound?.play()
    }

    private func scheduleResetToIdle(after duration: Duration = .seconds(3)) {
        cancelResetTask()
        resetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            await MainActor.run {
                guard let self else { return }

                switch self.phase {
                case .done, .error:
                    self.activeTriggerMode = .hold
                    self.phase = .idle
                default:
                    break
                }
            }
        }
    }

    private func cancelResetTask() {
        resetTask?.cancel()
        resetTask = nil
    }

    #if DEBUG
    /// Puts the pipeline in a phase with a fixed waveform, without touching
    /// the recorder. Only for overlay renders in tests.
    func setPhaseForRendering(_ phase: PipelinePhase, samples: [Float]? = nil, liveTranscript: String? = nil) {
        self.phase = phase
        if let samples { audioSamples = samples }
        if let liveTranscript { self.liveTranscript = liveTranscript }
    }

    /// Sets the last dictation shown in the menu bar. Only for renders in
    /// tests.
    func setLastResultForRendering(_ result: PipelineResult?) {
        lastResult = result
    }

    /// Runs a finished recording through the pipeline as `stopAndProcess`
    /// would, without a microphone. Tests only.
    func processRecordingForTesting(
        at url: URL,
        metrics: RecordingMetrics,
        usedEarlyCapture: Bool = false,
        dictationID: UUID = UUID()
    ) async {
        await processRecording(at: url, metrics: metrics, stream: nil, usedEarlyCapture: usedEarlyCapture, dictationID: dictationID)
    }
    #endif

    private func resetAudioSamples() {
        audioSamples = Array(repeating: 0, count: Self.waveformSampleCount)
        silentSampleCount = 0
        isHearingSilence = false
    }

    /// Append one sample to the rolling waveform buffer, dropping the oldest.
    /// Log-scales the input so quiet speech still moves the bars.
    private func pushAudioSample(_ level: Float) {
        let clamped = max(0, min(1, level))
        // log10(1 + 9x) maps [0,1] → [0,1] with a gentle low-end boost.
        let shaped = log10(1 + 9 * clamped)
        var samples = audioSamples
        samples.removeFirst()
        samples.append(shaped)
        audioSamples = samples

        if case .recording = phase {
            if clamped < Self.silenceLevelThreshold {
                silentSampleCount += 1
                if silentSampleCount >= Self.silenceTickThreshold && !isHearingSilence {
                    isHearingSilence = true
                }
            } else {
                silentSampleCount = 0
                if isHearingSilence {
                    isHearingSilence = false
                }
            }
        }
    }
}

enum PipelinePhase: Equatable {
    case idle
    case requestingMicrophonePermission
    case starting
    case recording
    case normalizingAudio
    case transcribing
    case cleaningTranscript
    case pasting
    case done(String)
    case error(String)
}

struct PipelineResult: Identifiable, Codable {
    let id: UUID
    var rawTranscript: String
    var cleanedText: String
    let sttProvider: STTProviderID
    let llmProvider: LLMProviderID
    var llmModel: String?
    let timestamp: Date
    /// The app that was frontmost when recording started. Nil for results
    /// saved before styles existed.
    let appBundleID: String?
    /// The cleanup style used, or nil when cleanup didn't run.
    var style: WritingStyle?
    /// Set when the dictation failed. Nil for every successful dictation and
    /// for results saved before failures were kept.
    var failure: DictationFailure?
    /// When the user swapped the cleaned paste for the raw transcript.
    var usedRawAt: Date?
    /// The selected provider when another one transcribed in its place
    /// (Parakeet while its model downloads, with `sttProvider` Apple). Nil
    /// when the selected provider ran, and for results saved before this.
    var sttFallbackFrom: STTProviderID?
    /// True when cleanup was switched off for this dictation: the pasted
    /// text is the transcript with only spoken edits and text fixes. Nil
    /// for cleaned dictations and results saved before the switch existed.
    var cleanupOff: Bool?
    /// Set when a dictation that produced text looked wrong
    /// (`DictationAnomaly`). Failed dictations carry `failure` instead.
    var anomaly: DictationAnomalyMark?

    var isCleanupOff: Bool { cleanupOff == true }

    /// Failed or anomalous: kept past history's cap (see `PinnedTrim`).
    var isPinned: Bool { failure != nil || anomaly != nil }

    init(
        id: UUID = UUID(),
        rawTranscript: String,
        cleanedText: String,
        sttProvider: STTProviderID,
        llmProvider: LLMProviderID,
        llmModel: String?,
        timestamp: Date,
        appBundleID: String? = nil,
        style: WritingStyle? = nil,
        failure: DictationFailure? = nil,
        sttFallbackFrom: STTProviderID? = nil,
        cleanupOff: Bool = false
    ) {
        self.id = id
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.sttProvider = sttProvider
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.timestamp = timestamp
        self.appBundleID = appBundleID
        self.style = style
        self.failure = failure
        self.sttFallbackFrom = sttFallbackFrom
        self.cleanupOff = cleanupOff ? true : nil
    }

    /// The provider that transcribed, and the one it filled in for.
    var sttProviderSummary: String {
        guard let from = sttFallbackFrom else { return sttProvider.displayName }
        return "\(sttProvider.displayName), filling in for \(from.displayName)"
    }

    /// Failed and not yet retried successfully.
    var isFailed: Bool {
        guard let failure else { return false }
        return failure.retriedAt == nil
    }
}

/// Why a dictation produced no text, and where its recording is kept.
struct DictationFailure: Codable, Equatable {
    /// The error shown to the user (the latest one, after a failed retry).
    var error: String
    /// File name in `FailedAudioStore`, or nil when no recording was kept
    /// (normalization failed) or it has been deleted or expired.
    var audioFileName: String?
    /// When a retry succeeded. The entry then carries the retried text.
    var retriedAt: Date?
}
