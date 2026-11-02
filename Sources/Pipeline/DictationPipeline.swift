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
    private static let minRecordingSeconds: Double = 0.3
    private static let minVoicedSeconds: Double = 0.3
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
        guard canStartRecording else { return }
        noteRecordingApp()

        cancelResetTask()
        activeTriggerMode = triggerMode
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
                activeTriggerMode = .hold
                phase = .idle
            } else {
                presentError("No audio was captured.")
            }
            return
        }

        systemAudioMuter.restore()

        playSound(.pop)

        resetAudioSamples()
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.processRecording(at: stopped.url, metrics: stopped.metrics, stream: stream)
        }
    }

    func cancel() {
        recordingGeneration &+= 1
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        processingTask?.cancel()
        processingTask = nil

        cancelResetTask()

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        recorder.onRecordingReady = nil
        _ = recorder.stopRecording()
        recorder.onAudioBuffer = nil
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

    func presentError(_ message: String) {
        logger.error("Pipeline error: \(message, privacy: .public)")
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
                presentError("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.")
            case .none:
                presentError("Microphone permission request timed out. Try again or grant access in System Settings > Privacy & Security > Microphone.")
            }
        case .restricted, .denied:
            presentError("Microphone access is unavailable. Enable it in System Settings > Privacy & Security > Microphone.")
        @unknown default:
            presentError("Whispur could not determine microphone permissions.")
        }
    }

    private func beginRecording() async {
        guard !recorder.isRecording else { return }

        // Move out of `.idle` before touching the recorder so stop events are
        // never dropped even if the user stops immediately.
        phase = .starting
        recordingGeneration &+= 1
        let generation = recordingGeneration

        recorder.onRecordingReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard case .starting = self.phase else { return }

                self.phase = .recording
                self.playSound(.tink)
                StartLatencyTrace.finish("listening (first audio, start sound)")
            }
        }

        startStreamingIfEnabled()

        do {
            try await recorder.startRecording()
        } catch {
            guard generation == recordingGeneration else { return }
            recorder.onAudioBuffer = nil
            streamingSession?.cancel()
            streamingSession = nil
            presentError(error.localizedDescription)
            return
        }
        StartLatencyTrace.mark("audio engine started")

        // A stop or cancel while the engine warmed up already stopped it
        // (the recorder serializes them after the start) and moved on.
        guard generation == recordingGeneration, canStopRecording else { return }

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
        else { return }

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
        recorder.onAudioBuffer = { buffer in
            session.append(converter.convert(buffer))
        }
        session.start()
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

    private func processRecording(at recordedURL: URL, metrics: RecordingMetrics, stream: STTStreamingSession?) async {
        defer {
            processingTask = nil
        }

        defer {
            recorder.cleanup()
        }

        // Skip STT entirely if the recording doesn't contain enough speech.
        // See `minRecordingSeconds` / `noiseFloorMultiplier` comments above for
        // rationale. Providers hallucinate confidently on silent audio, so
        // gating aggressively here saves both a request and a bad paste.
        if !recordingHasSpeech(metrics: metrics) {
            stream?.cancel()
            try? FileManager.default.removeItem(at: recordedURL)
            dismissForNoSpeech()
            return
        }

        // The recording is always normalized, even while a stream is
        // finishing: it is the fallback if streaming fails, and the copy kept
        // for a retry if the dictation fails. Removed at the end unless a
        // failure moved it into the failed-audio folder.
        phase = stream == nil ? .normalizingAudio : .transcribing
        let normalization = Task.detached(priority: .userInitiated) {
            try AudioNormalization.normalize(recordedURL)
        }
        defer {
            Task.detached {
                if let wavURL = try? await normalization.value {
                    try? FileManager.default.removeItem(at: wavURL)
                }
            }
        }
        let dictationID = UUID()
        lastRoute = nil

        do {

            // Warm the LLM connection in parallel with STT. By the time the
            // transcript lands, the TLS handshake to the cleanup endpoint is
            // already done, which saves ~200–500 ms on cold paths.
            if cleanupEnabled,
               let client = httpClient,
               let llmProvider = makeLLMProvider(),
               let origin = llmProvider.endpointOrigin {
                client.warmConnection(to: origin)
            }

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
                    try await batchTranscript(wavURL: try await normalization.value, initial: rejected)
                },
                batch: { [self] in
                    try await batchTranscript(wavURL: try await normalization.value, initial: nil)
                }
                )
            }
            guard let normalizedRawTranscript = TranscriptDecision.normalizedRawTranscript(rawTranscript) else {
                dismissForNoSpeech()
                return
            }

            guard let decided = await decideText(
                forRaw: normalizedRawTranscript,
                styleChoice: cleanupChoice(),
                appBundleID: recordingAppBundleID,
                updatesPhase: true
            ) else {
                dismissForNoSpeech()
                return
            }
            let finalTranscript = decided.text

            guard !Task.isCancelled else { throw CancellationError() }

            phase = .pasting
            let pasteText = await smartSpaced(finalTranscript)
            await TextInjector.paste(pasteText, preserveClipboard: preserveClipboard)

            guard !Task.isCancelled else { throw CancellationError() }

            onPasteCompleted?(finalTranscript)

            let result = PipelineResult(
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
            onDictationPasted?(result)

            phase = .done(finalTranscript)
            scheduleResetToIdle(after: .milliseconds(1200))

            logger.info("Pipeline finished successfully")
        } catch is CancellationError {
            logger.info("Pipeline processing cancelled")
            phase = .idle
        } catch {
            // URLSession throws URLError.cancelled when its Task is cancelled
            // mid-request; treat it as a clean cancel rather than surfacing
            // a misleading "cancelled" error banner.
            if !DictationFailureClassifier.isFailure(error, taskCancelled: Task.isCancelled) {
                logger.info("Pipeline processing cancelled")
                phase = .idle
            } else {
                // Keep the recording so the user can retry from Activity.
                historyStore.recordFailure(
                    id: dictationID,
                    error: error.localizedDescription,
                    wavURL: try? await normalization.value,
                    sttProvider: lastRoute?.provider ?? selectedSTT,
                    sttFallbackFrom: lastRoute?.fallbackFrom,
                    llmProvider: selectedLLM,
                    appBundleID: recordingAppBundleID,
                    style: cleanupChoice()?.style
                )
                presentError(error.localizedDescription)
            }
        }
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
                cleanupOff: false
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
    ) async -> (text: String?, llmModel: String?, style: WritingStyle?) {
        // Skip LLM cleanup for very short transcripts: an LLM tends to
        // answer "thanks" instead of cleaning it. They are pasted raw.
        guard cleanupEnabled,
              TranscriptDecision.shouldRunCleanup(for: raw),
              let llmProvider = makeLLMProvider()
        else { return (nil, nil, nil) }
        if updatesPhase { phase = .cleaningTranscript }

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
            return (text, response.model, styleChoice?.style)
        } catch {
            logger.warning("LLM cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
            return (nil, nil, nil)
        }
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
    private func recordingHasSpeech(metrics: RecordingMetrics) -> Bool {
        guard metrics.totalDurationSeconds >= Self.minRecordingSeconds else {
            logger.info("Skipping STT: recording too short (\(metrics.totalDurationSeconds)s)")
            return false
        }

        let series = metrics.buffers.dropFirst()
        guard !series.isEmpty, metrics.sampleRate > 0 else {
            logger.info("Skipping STT: no buffer metrics available")
            return false
        }

        let noiseFloor = series.map(\.rms).min() ?? 0
        let threshold = max(noiseFloor * Self.noiseFloorMultiplier, Self.absoluteFloorRMS)

        let voicedFrames = series.reduce(Int64(0)) { acc, buffer in
            buffer.rms > threshold ? acc + Int64(buffer.frameCount) : acc
        }
        let voicedSeconds = Double(voicedFrames) / metrics.sampleRate

        if voicedSeconds < Self.minVoicedSeconds {
            logger.info(
                "Skipping STT: voiced=\(voicedSeconds)s threshold=\(threshold) noiseFloor=\(noiseFloor)"
            )
            return false
        }
        return true
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

    var isCleanupOff: Bool { cleanupOff == true }

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
