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

    private var silentSampleCount: Int = 0
    private var peakAudioLevel: Float = 0
    private static let silenceLevelThreshold: Float = 0.05
    private static let silenceTickThreshold: Int = 60  // ~1.3s at ~47Hz
    /// A recording whose peak level never crosses this is treated as silent.
    /// STT providers (Whisper especially) hallucinate confident-sounding text
    /// on silent audio ("Thanks for watching!"), so we skip processing entirely.
    /// Keep this well below `silenceLevelThreshold` (0.05) so quiet speech
    /// still passes; this only catches sessions where the mic captured nothing.
    private static let voiceActivityPeakThreshold: Float = 0.02

    private let recorder: AudioRecorder
    private let registry: ProviderRegistry
    private let historyStore: PipelineHistoryStore
    private let httpClient: ProviderHTTPClient?

    var selectedSTT: STTProviderID = .apple
    var selectedLLM: LLMProviderID = .anthropic
    var sttLanguageSelection: STTLanguageSelection = .auto
    var customVocabulary: [String] = []
    var systemPrompt: String = Prompts.defaultCleanup
    var preserveClipboard: Bool = true
    var soundVolume: Float = 1.0

    /// Fires with the final pasted text right after `TextInjector.paste`
    /// returns. Used by the learning module to snapshot the focused field
    /// before the user starts editing.
    var onPasteCompleted: ((String) -> Void)?

    private var audioLevelCancellable: AnyCancellable?
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
                : "Speak now, then use your shortcut again or press Stop."
        case .normalizingAudio:
            return "Converting the captured audio to 16 kHz mono WAV."
        case .transcribing:
            return "Sending the recording to \(selectedSTT.displayName)."
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

        cancelResetTask()
        if case .done = phase { phase = .idle }
        if case .error = phase { phase = .idle }
        activeTriggerMode = triggerMode

        microphoneRequestTask?.cancel()
        microphoneRequestTask = Task { [weak self] in
            await self?.requestMicrophoneAccessAndBeginRecording()
        }
    }

    func updateTriggerMode(_ triggerMode: RecordingTriggerMode) {
        activeTriggerMode = triggerMode
    }

    func stopAndProcess() {
        guard canStopRecording else { return }

        cancelResetTask()
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil
        audioLevel = 0

        recorder.onRecordingReady = nil

        guard let recordedURL = recorder.stopRecording() else {
            resetAudioSamples()
            presentError("No audio was captured.")
            return
        }

        playSound(.pop)

        let capturedPeak = peakAudioLevel
        resetAudioSamples()
        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.processRecording(at: recordedURL, peakLevel: capturedPeak)
        }
    }

    func cancel() {
        microphoneRequestTask?.cancel()
        microphoneRequestTask = nil

        processingTask?.cancel()
        processingTask = nil

        cancelResetTask()

        audioLevelCancellable?.cancel()
        audioLevelCancellable = nil

        recorder.onRecordingReady = nil
        _ = recorder.stopRecording()
        recorder.cleanup()

        audioLevel = 0
        resetAudioSamples()
        activeTriggerMode = .hold
        phase = .idle
    }

    func presentError(_ message: String) {
        logger.error("Pipeline error: \(message, privacy: .public)")
        phase = .error(message)
        scheduleResetToIdle()
    }

    private func requestMicrophoneAccessAndBeginRecording() async {
        defer {
            microphoneRequestTask = nil
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            beginRecording()
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
                beginRecording()
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

    private func beginRecording() {
        guard !recorder.isRecording else { return }

        // Move out of `.idle` before touching the recorder so stop events are
        // never dropped even if the user stops immediately.
        phase = .starting

        recorder.onRecordingReady = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard case .starting = self.phase else { return }

                self.phase = .recording
                self.playSound(.tink)
            }
        }

        do {
            try recorder.startRecording()
        } catch {
            presentError(error.localizedDescription)
            return
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

    private func processRecording(at recordedURL: URL, peakLevel: Float) async {
        defer {
            processingTask = nil
        }

        defer {
            recorder.cleanup()
        }

        // Skip STT entirely if the whole recording was below the voice-activity floor.
        // Providers confidently hallucinate on silent audio (Whisper's famous
        // "Thanks for watching!"); don't paste anything if the user didn't speak.
        if peakLevel < Self.voiceActivityPeakThreshold {
            logger.info("Skipping STT: peak level \(peakLevel) below voice-activity threshold")
            try? FileManager.default.removeItem(at: recordedURL)
            dismissForNoSpeech()
            return
        }

        do {
            phase = .normalizingAudio
            let wavURL = try await Task.detached(priority: .userInitiated) {
                try AudioNormalization.normalize(recordedURL)
            }.value
            defer {
                try? FileManager.default.removeItem(at: wavURL)
            }

            phase = .transcribing
            guard let sttProvider = registry.makeSTTProvider(for: selectedSTT) else {
                throw STTError.missingAPIKey(provider: selectedSTT)
            }

            // Warm the LLM connection in parallel with STT. By the time the
            // transcript lands, the TLS handshake to the cleanup endpoint is
            // already done, which saves ~200–500 ms on cold paths.
            if let client = httpClient,
               let llmProvider = registry.makeLLMProvider(for: selectedLLM),
               let origin = llmProvider.endpointOrigin {
                client.warmConnection(to: origin)
            }

            let rawTranscript = try await sttProvider.transcribe(
                fileURL: wavURL,
                language: sttLanguageSelection,
                vocabulary: customVocabulary
            )
            guard let normalizedRawTranscript = normalizedTranscriptText(from: rawTranscript) else {
                dismissForNoSpeech()
                return
            }

            var cleanedTranscript = normalizedRawTranscript
            var llmModel: String?

            // Skip LLM cleanup for too-short transcripts — they're almost always noise
            // and an LLM will hallucinate conversational replies instead of cleaning text.
            let wordCount = normalizedRawTranscript.split { $0.isWhitespace }.count
            let looksLikeSpeech = normalizedRawTranscript.count >= 8 && wordCount >= 2

            if looksLikeSpeech, let llmProvider = registry.makeLLMProvider(for: selectedLLM) {
                phase = .cleaningTranscript

                do {
                    let response = try await llmProvider.complete(
                        request: LLMRequest(
                            systemPrompt: buildSystemPrompt(vocabulary: customVocabulary),
                            userMessage: normalizedRawTranscript
                        )
                    )

                    if let normalizedCleanedTranscript = normalizedTranscriptText(from: response.text) {
                        cleanedTranscript = normalizedCleanedTranscript
                    } else {
                        cleanedTranscript = ""
                    }

                    llmModel = response.model
                } catch {
                    logger.warning("LLM cleanup failed, using raw transcript: \(error.localizedDescription, privacy: .public)")
                }
            }

            guard let finalTranscript = normalizedTranscriptText(from: cleanedTranscript) else {
                dismissForNoSpeech()
                return
            }

            guard !Task.isCancelled else { throw CancellationError() }

            phase = .pasting
            await TextInjector.paste(finalTranscript, preserveClipboard: preserveClipboard)

            guard !Task.isCancelled else { throw CancellationError() }

            onPasteCompleted?(finalTranscript)

            let result = PipelineResult(
                rawTranscript: normalizedRawTranscript,
                cleanedText: finalTranscript,
                sttProvider: selectedSTT,
                llmProvider: selectedLLM,
                llmModel: llmModel,
                timestamp: Date()
            )

            lastResult = result
            historyStore.add(result)

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
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                logger.info("Pipeline processing cancelled")
                phase = .idle
            } else {
                presentError(error.localizedDescription)
            }
        }
    }

    private func buildSystemPrompt(vocabulary: [String]) -> String {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return systemPrompt }
        let joined = terms.joined(separator: ", ")
        return systemPrompt + """


        Preserve these proper nouns / terms exactly as spelled when they appear \
        (do not paraphrase, translate, or correct them): \(joined).
        """
    }

    private func normalizedTranscriptText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.uppercased() != "EMPTY" else { return nil }
        if isKnownSilenceHallucination(trimmed) { return nil }
        return trimmed
    }

    /// Whisper (and other STT providers trained on subtitled video) confidently
    /// emit a small set of canned phrases when given silence or near-silence —
    /// "Thanks for watching!", "[Music]", "Subtitles by the Amara.org community".
    /// If the *entire* transcript matches one of these, treat it as silence.
    /// Matching is whole-transcript only so real speech that happens to contain
    /// "thank you" mid-sentence still passes through.
    private static let knownSilenceHallucinations: Set<String> = [
        "thank you for watching",
        "thanks for watching",
        "thank you for watching!",
        "thanks for watching!",
        "thank you",
        "thank you so much",
        "thank you so much for watching",
        "thanks",
        "you",
        "bye",
        "goodbye",
        "please subscribe",
        "like and subscribe",
        "don't forget to subscribe",
        "thanks for listening",
        "thank you for listening",
        "subtitles by the amara.org community",
        "music",
        "applause",
        "silence",
    ]

    private func isKnownSilenceHallucination(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        let stripped = String(lowered.unicodeScalars.filter { allowed.contains($0) })
        let collapsed = stripped
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        return Self.knownSilenceHallucinations.contains(collapsed)
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

    private func resetAudioSamples() {
        audioSamples = Array(repeating: 0, count: Self.waveformSampleCount)
        silentSampleCount = 0
        peakAudioLevel = 0
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
            if clamped > peakAudioLevel {
                peakAudioLevel = clamped
            }
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
    let rawTranscript: String
    let cleanedText: String
    let sttProvider: STTProviderID
    let llmProvider: LLMProviderID
    let llmModel: String?
    let timestamp: Date

    init(
        rawTranscript: String,
        cleanedText: String,
        sttProvider: STTProviderID,
        llmProvider: LLMProviderID,
        llmModel: String?,
        timestamp: Date
    ) {
        self.id = UUID()
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.sttProvider = sttProvider
        self.llmProvider = llmProvider
        self.llmModel = llmModel
        self.timestamp = timestamp
    }
}
