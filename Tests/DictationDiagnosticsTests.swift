import AVFoundation
import XCTest
@testable import Whispur

// MARK: - Support shared by the diagnostics, anomaly and debug-recording tests

enum DiagnosticsTestSupport {
    static func makeScratch(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real audio file (a quiet tone), so normalization runs for real.
    static func makeToneFile(in dir: URL, seconds: Double = 1) throws -> URL {
        let url = dir.appendingPathComponent("\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) {
            samples[i] = 0.1 * sin(Float(i) * 2 * .pi * 440 / 16_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    /// Recorder metrics that pass the speech gate: `seconds` of 0.1 s
    /// buffers at 16 kHz, the first three quiet (room noise), the rest loud.
    static func speechMetrics(seconds: Double = 1, channels: Int = 1, device: String? = "Test Mic") -> RecordingMetrics {
        let count = max(Int(seconds * 10), 5)
        let buffers = Array(repeating: BufferMetric(frameCount: 1_600, rms: 0.002, peak: 0.01), count: 3)
            + Array(repeating: BufferMetric(frameCount: 1_600, rms: 0.08, peak: 0.5), count: count - 3)
        return RecordingMetrics(
            sampleRate: 16_000,
            totalFrames: Int64(count * 1_600),
            buffers: buffers,
            channelCount: channels,
            inputDeviceName: device
        )
    }

    static let silentMetrics = RecordingMetrics(
        sampleRate: 16_000,
        totalFrames: 16_000,
        buffers: Array(repeating: BufferMetric(frameCount: 1_600, rms: 0.001, peak: 0.002), count: 10)
    )

    @MainActor
    static func makePipeline(
        scratch: URL,
        stt: @escaping () async throws -> String,
        llm: (any LLMProvider)? = nil,
        history: PipelineHistoryStore? = nil,
        requestLog: ProviderRequestLog? = nil
    ) -> (DictationPipeline, PipelineHistoryStore) {
        let log = requestLog ?? ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json"))
        let client = ProviderHTTPClient(session: URLSession(configuration: .ephemeral), requestLog: log)
        let history = history ?? PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: history,
            httpClient: client
        )
        pipeline.selectedSTT = .apple
        pipeline.parakeetInstalled = { false }
        pipeline.soundVolume = 0
        pipeline.smartSpacingEnabled = false
        pipeline.sttProviderOverride = { _ in ClosureSTT(run: stt) }
        pipeline.llmProviderOverride = { _ in llm }
        pipeline.cleanupStyle = { _ in CleanupStyleChoice(style: .standard, systemPrompt: "prompt") }
        // Never paste into whatever app is in front while tests run.
        pipeline.deliverInsteadOfPasting = { _ in true }
        return (pipeline, history)
    }

    /// Waits for the late normalized-audio step after a dictation.
    @MainActor
    static func settle(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

struct ClosureSTT: STTProvider {
    static let providerID: STTProviderID = .apple
    let run: () async throws -> String

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        try await run()
    }
}

final class ScriptedLLM: LLMProvider, @unchecked Sendable {
    static let providerID: LLMProviderID = .cerebras
    static let model = "scripted-cleanup"
    let result: Result<String, Error>

    init(_ result: Result<String, Error>) {
        self.result = result
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: try result.get(), model: Self.model, promptTokens: nil, completionTokens: nil)
    }
}

// MARK: - Measurements

final class DictationDiagnosticsMeasurementTests: XCTestCase {
    func testEditDivergenceIgnoresCaseAndPunctuation() {
        XCTAssertEqual(DictationDiagnostics.editDivergence(raw: "hello there how are you", cleaned: "Hello there, how are you?"), 0)
        XCTAssertEqual(DictationDiagnostics.editDivergence(raw: "", cleaned: ""), 0)
    }

    func testEditDivergenceCountsWordEdits() {
        // One substitution and one deletion over five words.
        XCTAssertEqual(
            DictationDiagnostics.editDivergence(raw: "um send it to bob", cleaned: "Send it to Rob."),
            2.0 / 5.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(DictationDiagnostics.editDivergence(raw: "one two three", cleaned: "alpha beta gamma"), 1)
        XCTAssertEqual(DictationDiagnostics.editDivergence(raw: "one two three", cleaned: ""), 1)
    }

    func testAudioSignalsFromRecorderMetrics() {
        let metrics = DiagnosticsTestSupport.speechMetrics(seconds: 2, channels: 2)
        let audio = DictationDiagnostics.Audio(metrics: metrics, usedEarlyCapture: true)
        XCTAssertEqual(audio.recordingSeconds, 2, accuracy: 0.001)
        XCTAssertEqual(audio.inputChannels, 2)
        XCTAssertEqual(audio.inputSampleRate, 16_000)
        XCTAssertEqual(audio.inputDeviceName, "Test Mic")
        XCTAssertEqual(audio.peakLevel, 0.5, accuracy: 0.0001)
        XCTAssertEqual(audio.silenceRatio, 3.0 / 20.0, accuracy: 0.0001, "Only the quiet buffers are silent")
        XCTAssertGreaterThan(audio.rmsLevel, 0.07)
        XCTAssertTrue(audio.usedEarlyCapture)

        let silent = DictationDiagnostics.Audio(metrics: DiagnosticsTestSupport.silentMetrics, usedEarlyCapture: false)
        XCTAssertEqual(silent.silenceRatio, 1)
    }

    func testCharactersPerSecond() {
        XCTAssertEqual(DictationDiagnostics.charactersPerSecond(characters: 300, seconds: 20), 15)
        XCTAssertNil(DictationDiagnostics.charactersPerSecond(characters: 300, seconds: 0))
        XCTAssertNil(DictationDiagnostics.charactersPerSecond(characters: 300, seconds: nil))
    }

    func testSTTModel() {
        let defaults = UserDefaults(suiteName: "whispur-diag-\(UUID().uuidString)")!
        XCTAssertEqual(DictationDiagnostics.sttModel(for: .parakeet, defaults: defaults), ParakeetModelSpec.current.repository)
        XCTAssertEqual(DictationDiagnostics.sttModel(for: .groqWhisper, defaults: defaults), "whisper-large-v3")
        defaults.set("whisper-large-v3-turbo", forKey: "groqWhisperSTTModel")
        XCTAssertEqual(DictationDiagnostics.sttModel(for: .groqWhisper, defaults: defaults), "whisper-large-v3-turbo")
        XCTAssertNil(DictationDiagnostics.sttModel(for: .apple, defaults: defaults))
    }

    func testJSONHoldsNoTranscriptText() throws {
        let record = DictationDiagnostics(
            outcome: .success,
            stage: .paste,
            transcription: .init(
                provider: .parakeet, model: "m", fallbackFrom: nil, streamed: false, streamFellBack: false,
                latencyMS: 900, rawCharacterCount: 42, rawWordCount: 8, charactersPerSecond: 14
            ),
            cleanup: .init(
                provider: .cerebras, model: "c", latencyMS: 300, cleanedCharacterCount: 40,
                editDivergence: 0.1, rawFallbackReason: nil, cleanupOff: false, error: nil
            )
        )
        let json = record.jsonString
        XCTAssertTrue(json.contains("\"rawCharacterCount\" : 42"))
        let decoded = try JSONDecoder().decode([String: AnyDecodable].self, from: Data(json.utf8))
        let allowed: Set<String> = ["id", "timestamp", "outcome", "stage", "errorMessage", "audio", "transcription", "cleanup", "appVersion"]
        XCTAssertTrue(Set(decoded.keys).isSubset(of: allowed), "Measurements only: \(decoded.keys.sorted())")
        XCTAssertTrue(record.summary.hasPrefix("Pasted · Parakeet 900 ms · 42 chars (14.0/s) · Cerebras 300 ms · 10% changed"), record.summary)
    }
}

/// Decodes any JSON value, to list a record's keys.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}

// MARK: - Store

@MainActor
final class DictationDiagnosticsStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("diag-store")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testRecordsPersistNewestFirstAndAreBounded() {
        let url = scratch.appendingPathComponent("d.json")
        let store = DictationDiagnosticsStore(maxItems: 3, fileURL: url)
        let ids = (0..<5).map { _ in UUID() }
        for id in ids { store.record(DictationDiagnostics(id: id, outcome: .success)) }
        XCTAssertEqual(store.items.map(\.id), ids.reversed().prefix(3).map { $0 })

        let reloaded = DictationDiagnosticsStore(maxItems: 3, fileURL: url)
        XCTAssertEqual(reloaded.items, store.items)
    }

    func testRecordReplacesTheSameDictation() {
        let store = DictationDiagnosticsStore(fileURL: scratch.appendingPathComponent("d.json"))
        let id = UUID()
        store.record(DictationDiagnostics(id: id, outcome: .failed, stage: .other))
        store.record(DictationDiagnostics(id: id, outcome: .success))
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.item(id)?.outcome, .success)
    }

    func testHistoryClearAndDeleteTakeDiagnosticsWithThem() {
        let history = PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        XCTAssertEqual(
            history.diagnostics.fileURL.deletingLastPathComponent().standardizedFileURL.path,
            scratch.standardizedFileURL.path,
            "Beside the history file in tests"
        )
        let failed = history.recordFailure(error: "x", wavURL: nil, sttProvider: .apple, llmProvider: .anthropic, appBundleID: nil, style: nil)
        history.diagnostics.record(DictationDiagnostics(id: failed.id, outcome: .failed, stage: .transcription))
        history.diagnostics.record(DictationDiagnostics(outcome: .noSpeech))
        history.delete(failed.id)
        XCTAssertNil(history.diagnostics.item(failed.id))
        XCTAssertEqual(history.diagnostics.items.count, 1)
        history.clear()
        XCTAssertTrue(history.diagnostics.items.isEmpty)
    }
}

// MARK: - Pipeline: every outcome and stage keeps a record

@MainActor
final class DictationDiagnosticsPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("diag-pipeline")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func run(
        stt: @escaping () async throws -> String,
        llm: (any LLMProvider)? = nil,
        metrics: RecordingMetrics = DiagnosticsTestSupport.speechMetrics(seconds: 1),
        file: URL? = nil,
        configure: (DictationPipeline) -> Void = { _ in }
    ) async throws -> (DictationDiagnostics, PipelineHistoryStore, DictationPipeline) {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: stt, llm: llm)
        configure(pipeline)
        let id = UUID()
        let url = try file ?? DiagnosticsTestSupport.makeToneFile(in: scratch)
        await pipeline.processRecordingForTesting(at: url, metrics: metrics, usedEarlyCapture: true, dictationID: id)
        let record = try XCTUnwrap(history.diagnostics.item(id), "Every dictation keeps a record")
        return (record, history, pipeline)
    }

    func testSuccessRecordsAllThreeSignalGroups() async throws {
        let raw = "um so send the report to Bob by Friday please"
        let (record, history, _) = try await run(
            stt: { raw },
            llm: ScriptedLLM(.success("Send the report to Bob by Friday, please."))
        )
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.stage, .paste)
        XCTAssertNil(record.errorMessage)
        XCTAssertNotNil(history.item(record.id), "The history entry shares the dictation id")

        let audio = try XCTUnwrap(record.audio)
        XCTAssertEqual(audio.recordingSeconds, 1, accuracy: 0.001)
        XCTAssertEqual(audio.inputDeviceName, "Test Mic")
        XCTAssertTrue(audio.usedEarlyCapture)

        let transcription = try XCTUnwrap(record.transcription)
        XCTAssertEqual(transcription.provider, .apple)
        XCTAssertEqual(transcription.rawCharacterCount, raw.count)
        XCTAssertEqual(transcription.rawWordCount, 10)
        XCTAssertEqual(try XCTUnwrap(transcription.charactersPerSecond), Double(raw.count), accuracy: 0.01)
        XCTAssertNotNil(transcription.latencyMS)
        XCTAssertFalse(transcription.streamed)

        let cleanup = try XCTUnwrap(record.cleanup)
        XCTAssertEqual(cleanup.provider, .anthropic, "The selected cleanup provider")
        XCTAssertEqual(cleanup.model, ScriptedLLM.model)
        XCTAssertNotNil(cleanup.latencyMS)
        XCTAssertEqual(cleanup.cleanedCharacterCount, "Send the report to Bob by Friday, please.".count)
        XCTAssertNil(cleanup.rawFallbackReason)
        XCTAssertNotNil(cleanup.editDivergence)
        XCTAssertLessThan(try XCTUnwrap(cleanup.editDivergence), 0.3)

        // Normalization finishes in the background and lands later.
        await DiagnosticsTestSupport.settle { history.diagnostics.item(record.id)?.audio?.normalizedSampleCount != nil }
        let normalized = try XCTUnwrap(history.diagnostics.item(record.id)?.audio)
        XCTAssertEqual(Double(try XCTUnwrap(normalized.normalizedSampleCount)), 16_000, accuracy: 200)
        XCTAssertEqual(try XCTUnwrap(normalized.normalizedSeconds), 1, accuracy: 0.02)
    }

    func testCleanupFailureIsASuccessWithTheReasonKept() async throws {
        let (record, _, _) = try await run(
            stt: { "please send the report to bob" },
            llm: ScriptedLLM(.failure(LLMError.timeout(provider: .cerebras)))
        )
        XCTAssertEqual(record.outcome, .success)
        XCTAssertEqual(record.cleanup?.rawFallbackReason, TranscriptDecision.RawFallbackReason.cleanupUnavailable.rawValue)
        XCTAssertEqual(record.cleanup?.error, LLMError.timeout(provider: .cerebras).localizedDescription)
        XCTAssertNil(record.cleanup?.editDivergence, "Raw text was pasted: nothing to compare")
    }

    func testNoSpeechInTheRecording() async throws {
        var calls = 0
        let (record, _, _) = try await run(stt: { calls += 1; return "x" }, metrics: DiagnosticsTestSupport.silentMetrics)
        XCTAssertEqual(record.outcome, .noSpeech)
        XCTAssertEqual(record.stage, .recording)
        XCTAssertEqual(calls, 0)
        XCTAssertNotNil(record.audio)
    }

    func testNoSpeechInTheTranscript() async throws {
        let (record, _, _) = try await run(stt: { "  " })
        XCTAssertEqual(record.outcome, .noSpeech)
        XCTAssertEqual(record.stage, .transcription)
        XCTAssertEqual(record.transcription?.rawCharacterCount, 0)
    }

    func testNothingLeftAfterSpokenEdits() async throws {
        let (record, _, _) = try await run(stt: { "Send it to Alice. Scratch that." }) { $0.cleanupEnabled = false }
        XCTAssertEqual(record.outcome, .noSpeech)
        XCTAssertEqual(record.stage, .cleanup)
    }

    func testTranscriptionFailure() async throws {
        let error = STTError.apiError(provider: .apple, message: "boom", statusCode: 500)
        let (record, history, _) = try await run(stt: { throw error })
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.stage, .transcription)
        XCTAssertEqual(record.errorMessage, error.localizedDescription)
        XCTAssertEqual(record.transcription?.provider, .apple)
        XCTAssertNil(record.transcription?.rawCharacterCount)
        XCTAssertEqual(history.item(record.id)?.isFailed, true, "The failure also reaches history")
    }

    func testNormalizationFailure() async throws {
        let garbage = scratch.appendingPathComponent("garbage.caf")
        try Data(repeating: 1, count: 128).write(to: garbage)
        let (record, history, _) = try await run(stt: { "never reached" }, file: garbage)
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.stage, .normalization)
        XCTAssertNotNil(record.errorMessage)
        XCTAssertNil(record.audio?.normalizedSampleCount)
        XCTAssertEqual(history.item(record.id)?.isFailed, true)
    }

    func testCancelledDuringTranscription() async throws {
        let (record, history, _) = try await run(stt: { throw CancellationError() })
        XCTAssertEqual(record.outcome, .cancelled)
        XCTAssertEqual(record.stage, .transcription)
        XCTAssertNil(record.errorMessage)
        XCTAssertNil(history.item(record.id), "A cancel is not a failed dictation")
    }

    func testCancelWhileRecordingKeepsARecord() {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { "" })
        pipeline.setPhaseForRendering(.recording)
        pipeline.cancel()
        let record = try? XCTUnwrap(history.diagnostics.items.first)
        XCTAssertEqual(record?.outcome, .cancelled)
        XCTAssertEqual(record?.stage, .recording)
        XCTAssertEqual(history.diagnostics.items.count, 1)

        pipeline.cancel()
        XCTAssertEqual(history.diagnostics.items.count, 1, "Cancelling while idle is not a dictation")
    }

    func testErrorsBeforeProcessingKeepARecord() {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { "" })
        pipeline.presentError("Microphone access was denied.", stage: .recording)
        pipeline.presentError("Accessibility access is required.")
        XCTAssertEqual(history.diagnostics.items.map(\.outcome), [.failed, .failed])
        XCTAssertEqual(history.diagnostics.items.map(\.stage), [.other, .recording])
        XCTAssertEqual(history.diagnostics.items.last?.errorMessage, "Microphone access was denied.")
        XCTAssertEqual(pipeline.phase, .error("Accessibility access is required."))
    }

    func testEveryOutcomeAndStageIsReachable() {
        // Guards the enums the tests above cover: a new case needs a test.
        XCTAssertEqual(DictationDiagnostics.Outcome.allCases, [.success, .cancelled, .noSpeech, .failed])
        XCTAssertEqual(DictationDiagnostics.Stage.allCases, [.recording, .normalization, .transcription, .cleanup, .paste, .other])
    }
}
