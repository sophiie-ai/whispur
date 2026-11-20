import XCTest
@testable import Whispur

/// Broken mic audio is never pasted, and the overlay warns while recording.
@MainActor
final class MicHealthPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("mic-health")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func brokenMetrics(_ issue: MicHealthIssue = .dropouts) -> RecordingMetrics {
        var metrics = DiagnosticsTestSupport.speechMetrics(seconds: 1)
        metrics.micHealth = MicHealthReport(issue: issue, flaggedAfterSeconds: 0.5, measuredRateRatio: 1, dropoutCount: 12)
        return metrics
    }

    /// The incident: broken audio must not be transcribed into nonsense
    /// and pasted. It fails, keeps its recording, and can be retried.
    func testBrokenMicAudioFailsWithItsRecordingKeptAndNothingPasted() async throws {
        var sttCalls = 0
        var delivered: [String] = []
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(
            scratch: scratch,
            stt: { sttCalls += 1; return "garbled words" },
            llm: ScriptedLLM(.success("EMPTY"))
        )
        pipeline.deliverInsteadOfPasting = { delivered.append($0); return true }
        let id = UUID()
        let url = try DiagnosticsTestSupport.makeToneFile(in: scratch)
        await pipeline.processRecordingForTesting(at: url, metrics: brokenMetrics(), dictationID: id)

        XCTAssertEqual(sttCalls, 0, "nothing is sent")
        XCTAssertEqual(delivered, [], "nothing is pasted")
        XCTAssertEqual(pipeline.phase, .error(DictationPipeline.brokenMicAudioMessage))

        let record = try XCTUnwrap(history.diagnostics.item(id))
        XCTAssertEqual(record.outcome, .failed)
        XCTAssertEqual(record.stage, .recording)
        XCTAssertEqual(record.anomalies, [.failed, .micAudioCorrupted])
        XCTAssertEqual(record.audio?.midStreamDropouts, 12)

        let item = try XCTUnwrap(history.item(id))
        XCTAssertTrue(item.isFailed, "listed in Activity with Retry")
        XCTAssertNotNil(history.keptAudioURL(for: item), "the recording is kept for the retry")
    }

    func testHealthyAudioStillPastes() async throws {
        var delivered: [String] = []
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(
            scratch: scratch,
            stt: { "send the report to bob by friday" },
            llm: ScriptedLLM(.success("Send the report to Bob by Friday."))
        )
        pipeline.deliverInsteadOfPasting = { delivered.append($0); return true }
        var metrics = DiagnosticsTestSupport.speechMetrics(seconds: 1)
        metrics.inputIsBluetooth = true
        let id = UUID()
        await pipeline.processRecordingForTesting(at: try DiagnosticsTestSupport.makeToneFile(in: scratch), metrics: metrics, dictationID: id)
        XCTAssertEqual(delivered, ["Send the report to Bob by Friday."])
        XCTAssertNil(history.diagnostics.item(id)?.anomalies)
    }

    /// Cleanup saying "no real speech" on broken audio is believed: the raw
    /// transcript of garbled audio is not used instead.
    func testEmptyCleanupOnBrokenAudioNeverFallsBackToRaw() async {
        let (pipeline, _) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { "" }, llm: ScriptedLLM(.success("EMPTY")))
        let broken = await pipeline.decideText(forRaw: "the wed hound sister melon", styleChoice: nil, updatesPhase: false, micAudioCorrupted: true)
        XCTAssertNil(broken)
        let healthy = await pipeline.decideText(forRaw: "the wed hound sister melon", styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(healthy?.rawFallbackReason, .cleanupEmpty, "healthy audio keeps the existing fallback")
    }

    func testRetryOfBrokenAudioDoesNotCopyTheRawTranscriptWhenCleanupFindsNothing() async throws {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(
            scratch: scratch,
            stt: { "the wed hound sister melon" },
            llm: ScriptedLLM(.success("EMPTY"))
        )
        let id = UUID()
        await pipeline.processRecordingForTesting(at: try DiagnosticsTestSupport.makeToneFile(in: scratch), metrics: brokenMetrics(), dictationID: id)
        let audioURL = try XCTUnwrap(history.item(id).flatMap(history.keptAudioURL(for:)))
        do {
            _ = try await pipeline.retryTranscription(audioURL: audioURL, appBundleID: nil, dictationID: id)
            XCTFail("expected no text")
        } catch {
            XCTAssertEqual(error as? DictationPipeline.RetryError, .noSpeech)
        }
    }

    // Live warning and the switch to the built-in mic.

    private func makeRecorder() -> (AudioRecorder, () -> Int) {
        let recorder = AudioRecorder()
        let lock = NSLock()
        var starts = 0
        let dir = scratch!
        recorder.startEngineForTesting = {
            let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            lock.lock(); starts += 1; lock.unlock()
            return url
        }
        return (recorder, { lock.lock(); defer { lock.unlock() }; return starts })
    }

    private func makePipeline(recorder: AudioRecorder) -> DictationPipeline {
        let client = ProviderHTTPClient(
            session: URLSession(configuration: .ephemeral),
            requestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json"))
        )
        let pipeline = DictationPipeline(
            recorder: recorder,
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.assumeMicrophoneStatusForTesting(.authorized)
        pipeline.soundVolume = 0
        return pipeline
    }

    private func settle(_ recorder: AudioRecorder) async {
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        recorder.waitForPendingWorkForTesting()
        for _ in 0..<10 { await Task.yield() }
    }

    func testFlagWarnsOnceAndOffersTheBuiltInMic() async {
        let (recorder, _) = makeRecorder()
        let pipeline = makePipeline(recorder: recorder)
        pipeline.builtInMicrophoneUID = { "BuiltInMicrophoneDevice" }
        pipeline.startRecording(triggerMode: .toggle)
        await settle(recorder)
        XCTAssertTrue(recorder.isRecording)

        recorder.onMicHealthIssue?(.dropouts)
        await settle(recorder)
        XCTAssertEqual(pipeline.micHealthWarning, MicHealthWarning(issue: .dropouts, builtInMicrophoneUID: "BuiltInMicrophoneDevice"))

        recorder.onMicHealthIssue?(.rateMismatch)
        await settle(recorder)
        XCTAssertEqual(pipeline.micHealthWarning?.issue, .dropouts, "surfaced once")
        pipeline.cancel()
        XCTAssertNil(pipeline.micHealthWarning)
    }

    func testNoBuiltInMicMeansNoAction() async {
        let (recorder, _) = makeRecorder()
        let pipeline = makePipeline(recorder: recorder)
        pipeline.builtInMicrophoneUID = { nil }
        pipeline.startRecording(triggerMode: .toggle)
        await settle(recorder)
        recorder.onMicHealthIssue?(.rateMismatch)
        await settle(recorder)
        XCTAssertEqual(pipeline.micHealthWarning, MicHealthWarning(issue: .rateMismatch, builtInMicrophoneUID: nil))
        pipeline.cancel()
    }

    func testRestartDiscardsTheBrokenRecordingAndStartsANewOne() async {
        let (recorder, starts) = makeRecorder()
        let pipeline = makePipeline(recorder: recorder)
        pipeline.builtInMicrophoneUID = { "BuiltInMicrophoneDevice" }
        pipeline.startRecording(triggerMode: .toggle)
        await settle(recorder)
        recorder.onMicHealthIssue?(.dropouts)
        await settle(recorder)

        pipeline.restartRecording()
        XCTAssertNil(pipeline.micHealthWarning)
        XCTAssertEqual(pipeline.phase, .starting)
        await settle(recorder)
        XCTAssertEqual(starts(), 2, "a fresh recording")
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(pipeline.activeTriggerMode, .toggle, "same trigger mode, so the same shortcut stops it")

        // The old recording's late callbacks can't touch the new one.
        pipeline.cancel()
        await settle(recorder)
        XCTAssertFalse(recorder.isRecording)
    }

    /// Released right after the switch, before the new start ran: the
    /// microphone must not open after the stop.
    func testStopRightAfterRestartKeepsTheMicrophoneOff() async {
        let (recorder, _) = makeRecorder()
        let pipeline = makePipeline(recorder: recorder)
        pipeline.startRecording(triggerMode: .hold)
        await settle(recorder)
        pipeline.restartRecording()
        pipeline.cancel()
        await settle(recorder)
        XCTAssertFalse(recorder.isRecording)
    }
}
