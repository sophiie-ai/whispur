import AppKit
import AVFoundation
import Combine
import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "Pipeline")

@MainActor
final class DictationPipeline: ObservableObject {
    @Published private(set) var phase: PipelinePhase = .idle
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastResult: PipelineResult?
    @Published private(set) var activeTriggerMode: RecordingTriggerMode = .hold

    private let recorder: AudioRecorder
    private let registry: ProviderRegistry
    private let historyStore: PipelineHistoryStore

    var selectedSTT: STTProviderID = .apple
    var selectedLLM: LLMProviderID = .anthropic
    var systemPrompt: String = Prompts.defaultCleanup
    var preserveClipboard: Bool = true
    var soundVolume: Float = 1.0

    private var audioLevelCancellable: AnyCancellable?
    private var microphoneRequestTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?

    init(
        recorder: AudioRecorder,
        registry: ProviderRegistry,
        historyStore: PipelineHistoryStore
    ) {
        self.recorder = recorder
        self.registry = registry
        self.historyStore = historyStore
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
            presentError("No audio was captured.")
            return
        }

        playSound(.pop)

        processingTask?.cancel()
        processingTask = Task { [weak self] in
            await self?.processRecording(at: recordedURL)
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
            let granted = await AudioRecorder.requestMicrophoneAccess()
            guard !Task.isCancelled else { return }

            if granted {
                beginRecording()
            } else {
                presentError("Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone.")
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

        audioLevelCancellable = recorder.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.audioLevel = level
            }

        logger.info("Recording session started")
    }

    private func processRecording(at recordedURL: URL) async {
        defer {
            processingTask = nil
        }

        defer {
            recorder.cleanup()
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

            let rawTranscript = try await sttProvider.transcribe(fileURL: wavURL)
            guard let normalizedRawTranscript = normalizedTranscriptText(from: rawTranscript) else {
                phase = .done("No speech detected.")
                scheduleResetToIdle(after: .seconds(1))
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
                            systemPrompt: systemPrompt,
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
                phase = .done("No speech detected.")
                scheduleResetToIdle(after: .seconds(1))
                return
            }

            phase = .pasting
            await TextInjector.paste(finalTranscript, preserveClipboard: preserveClipboard)

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
            presentError(error.localizedDescription)
        }
    }

    private func normalizedTranscriptText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.uppercased() != "EMPTY" else { return nil }
        return trimmed
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
