import XCTest
@testable import Whispur

// MARK: - Classification

final class DictationAnomalyClassificationTests: XCTestCase {
    /// A normal dictation: 20 s of audio, 15 characters per second, light
    /// cleanup, the selected provider ran.
    private func record(
        outcome: DictationDiagnostics.Outcome = .success,
        seconds: Double = 20,
        cps: Double? = 15,
        words: Int = 50,
        divergence: Double? = 0.1,
        fallbackFrom: STTProviderID? = nil,
        streamFellBack: Bool = false
    ) -> DictationDiagnostics {
        DictationDiagnostics(
            outcome: outcome,
            stage: .paste,
            audio: .init(
                recordingSeconds: seconds, inputDeviceName: nil, inputSampleRate: 48_000, inputChannels: 1,
                normalizedSeconds: nil, normalizedSampleCount: nil, peakLevel: 0.5, rmsLevel: 0.1,
                silenceRatio: 0.2, usedEarlyCapture: false
            ),
            transcription: .init(
                provider: .parakeet, model: nil, fallbackFrom: fallbackFrom, streamed: streamFellBack,
                streamFellBack: streamFellBack, latencyMS: 500, rawCharacterCount: cps.map { Int($0 * seconds) },
                rawWordCount: words, charactersPerSecond: cps
            ),
            cleanup: .init(
                provider: .cerebras, model: "m", latencyMS: 300, cleanedCharacterCount: 100,
                editDivergence: divergence, rawFallbackReason: divergence == nil ? "cleanup unavailable or failed" : nil,
                cleanupOff: false, error: nil
            )
        )
    }

    // Block side.

    func testFailureIsAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .failed, stage: .transcription)), [.failed])
    }

    func testLongAudioWithLittleTextIsAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(seconds: 300, cps: 1.2)), [.lowCharacterRate])
        XCTAssertEqual(DictationAnomaly.reasons(for: record(seconds: 10, cps: 2.9)), [.lowCharacterRate], "At the 10 s floor")
    }

    func testCleanupThatRewroteMostWordsIsAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(divergence: 0.8)), [.cleanupDiverged])
    }

    func testSTTFallbacksAreAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(fallbackFrom: .parakeet)), [.sttFellBack])
        XCTAssertEqual(DictationAnomaly.reasons(for: record(streamFellBack: true)), [.sttFellBack])
    }

    func testReasonsCombine() {
        XCTAssertEqual(
            DictationAnomaly.reasons(for: record(seconds: 60, cps: 1, divergence: 0.9, fallbackFrom: .parakeet)),
            [.lowCharacterRate, .cleanupDiverged, .sttFellBack]
        )
    }

    // Allow side: normal dictations are not flagged.

    func testNormalDictationIsNotAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record()), [])
    }

    func testShortAudioIsNeverJudgedOnRate() {
        // "Yes" after a pause: 9 s, 0.3 characters per second.
        XCTAssertEqual(DictationAnomaly.reasons(for: record(seconds: 9.9, cps: 0.3, words: 1)), [])
    }

    func testRateAtTheFloorIsNormal() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(seconds: 120, cps: 3)), [])
    }

    func testShortTranscriptsAreNeverJudgedOnDivergence() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(words: 7, divergence: 1)), [])
    }

    func testDivergenceAtTheThresholdIsNormal() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(divergence: 0.5)), [])
    }

    func testRawFallbackAndCleanupOffAreNotDivergence() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(divergence: nil)), [])
        var off = record(divergence: nil)
        off.cleanup?.cleanupOff = true
        XCTAssertEqual(DictationAnomaly.reasons(for: off), [])
    }

    func testCancelledIsNeverAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(outcome: .cancelled, seconds: 300, cps: 0, fallbackFrom: .parakeet)), [])
    }

    func testLongNoSpeechIsAnomalous() {
        XCTAssertEqual(DictationAnomaly.reasons(for: record(outcome: .noSpeech, seconds: 300, cps: 0)), [.noSpeech])
        XCTAssertEqual(DictationAnomaly.reasons(for: record(outcome: .noSpeech, seconds: 10, cps: nil)), [.noSpeech], "At the 10 s floor")
    }

    func testShortNoSpeechIsNotAnomalous() {
        // Accidental taps and short silences.
        XCTAssertEqual(DictationAnomaly.reasons(for: record(outcome: .noSpeech, seconds: 0.4, cps: nil)), [])
        XCTAssertEqual(DictationAnomaly.reasons(for: record(outcome: .noSpeech, seconds: 9.9, cps: 0)), [])
        XCTAssertEqual(DictationAnomaly.reasons(for: DictationDiagnostics(outcome: .noSpeech, stage: .recording)), [], "No audio measured")
    }

    func testNoSpeechReasonNamesTheAudioLength() {
        let mark = DictationAnomalyMark(reasons: [.noSpeech], audioFileName: nil, audioSeconds: 312.4)
        XCTAssertEqual(mark.summary, "No speech in 312 s of audio")
    }
}

// MARK: - Pipeline keeps anomalous audio

@MainActor
final class DictationAnomalyPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("anomaly-pipeline")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func dictate(
        transcript: String,
        seconds: Double = 1,
        configure: (DictationPipeline) -> Void = { _ in }
    ) async throws -> (UUID, PipelineHistoryStore) {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(
            scratch: scratch,
            stt: { transcript },
            llm: ScriptedLLM(.success(transcript))
        )
        configure(pipeline)
        let id = UUID()
        await pipeline.processRecordingForTesting(
            at: try DiagnosticsTestSupport.makeToneFile(in: scratch),
            metrics: DiagnosticsTestSupport.speechMetrics(seconds: seconds),
            dictationID: id
        )
        await DiagnosticsTestSupport.settle { history.diagnostics.item(id)?.audio?.normalizedSampleCount != nil }
        return (id, history)
    }

    func testFallbackDictationKeepsItsRecordingUnderTheFailedAudioRules() async throws {
        let (id, history) = try await dictate(transcript: "send the report to bob on friday") {
            $0.selectedSTT = .parakeet // Not installed: Apple fills in.
        }
        let item = try XCTUnwrap(history.item(id))
        XCTAssertFalse(item.isFailed)
        XCTAssertEqual(item.anomaly?.reasons, [.sttFellBack])
        XCTAssertEqual(history.diagnostics.item(id)?.anomalies, [.sttFellBack])

        let url = try XCTUnwrap(history.keptAudioURL(for: item), "Recording kept")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, history.failedAudio.directory.standardizedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try history.failedAudio.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)

        history.purgeExpiredAudio(now: Date().addingTimeInterval(FailedAudioStore.retention + 60))
        let purged = try XCTUnwrap(history.item(id))
        XCTAssertNil(purged.anomaly?.audioFileName, "Deleted after 24 hours")
        XCTAssertNotNil(purged.anomaly, "Still marked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLowCharacterRateIsFlagged() async throws {
        let (id, history) = try await dictate(transcript: "okay then", seconds: 30)
        XCTAssertEqual(history.item(id)?.anomaly?.reasons, [.lowCharacterRate])
        XCTAssertNotNil(history.keptAudioURL(for: try XCTUnwrap(history.item(id))))
    }

    func testNormalDictationKeepsNoRecording() async throws {
        let (id, history) = try await dictate(transcript: "send the report to bob on friday")
        let item = try XCTUnwrap(history.item(id))
        XCTAssertNil(item.anomaly)
        XCTAssertNil(history.diagnostics.item(id)?.anomalies)
        XCTAssertNil(history.keptAudioURL(for: item))
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: history.failedAudio.directory.path)) ?? []
        XCTAssertEqual(kept, [], "No recording lands in the folder")
    }

    private static func silence(seconds: Double) -> RecordingMetrics {
        let count = max(Int(seconds * 10), 1)
        return RecordingMetrics(
            sampleRate: 16_000,
            totalFrames: Int64(count * 1_600),
            buffers: Array(repeating: BufferMetric(frameCount: 1_600, rms: 0.001, peak: 0.002), count: count)
        )
    }

    private func dictateNoSpeech(metrics: RecordingMetrics, transcript: String = "") async throws -> (UUID, PipelineHistoryStore) {
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { transcript })
        let id = UUID()
        await pipeline.processRecordingForTesting(
            at: try DiagnosticsTestSupport.makeToneFile(in: scratch),
            metrics: metrics,
            dictationID: id
        )
        await DiagnosticsTestSupport.settle {
            history.item(id).map { history.keptAudioURL(for: $0) != nil } ?? false
        }
        return (id, history)
    }

    func testLongSilentRecordingGetsAPinnedEntryWithItsAudio() async throws {
        let (id, history) = try await dictateNoSpeech(metrics: Self.silence(seconds: 12))
        XCTAssertEqual(history.diagnostics.item(id)?.outcome, .noSpeech)
        XCTAssertEqual(history.diagnostics.item(id)?.anomalies, [.noSpeech])
        let item = try XCTUnwrap(history.item(id), "Listed in Activity")
        XCTAssertTrue(item.isNoSpeech)
        XCTAssertTrue(item.isPinned)
        XCTAssertFalse(item.producedText, "Not a first dictation, not counted as text")
        XCTAssertEqual(item.anomaly?.summary, "No speech in 12 s of audio")
        let url = try XCTUnwrap(history.keptAudioURL(for: item), "Recording kept")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, history.failedAudio.directory.standardizedFileURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        history.purgeExpiredAudio(now: Date().addingTimeInterval(FailedAudioStore.retention + 60))
        XCTAssertNil(history.item(id)?.anomaly?.audioFileName, "Deleted after 24 hours")
    }

    func testLongRecordingWithAnEmptyTranscriptIsFlagged() async throws {
        let (id, history) = try await dictateNoSpeech(metrics: DiagnosticsTestSupport.speechMetrics(seconds: 15), transcript: " ")
        XCTAssertEqual(history.diagnostics.item(id)?.stage, .transcription)
        let item = try XCTUnwrap(history.item(id))
        XCTAssertEqual(item.anomaly?.summary, "No speech in 15 s of audio")
        XCTAssertNotNil(history.keptAudioURL(for: item))
    }

    func testShortTapsWithNoSpeechAreNotFlagged() async throws {
        // An accidental tap: under a second of silence.
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { "" })
        let tap = UUID()
        await pipeline.processRecordingForTesting(
            at: try DiagnosticsTestSupport.makeToneFile(in: scratch),
            metrics: Self.silence(seconds: 0.5),
            dictationID: tap
        )
        // A short recording whose transcript came back empty.
        let empty = UUID()
        await pipeline.processRecordingForTesting(
            at: try DiagnosticsTestSupport.makeToneFile(in: scratch),
            metrics: DiagnosticsTestSupport.speechMetrics(seconds: 3),
            dictationID: empty
        )
        await DiagnosticsTestSupport.settle { history.diagnostics.item(empty)?.audio?.normalizedSampleCount != nil }

        for id in [tap, empty] {
            XCTAssertEqual(history.diagnostics.item(id)?.outcome, .noSpeech)
            XCTAssertNil(history.diagnostics.item(id)?.anomalies)
            XCTAssertFalse(history.isPinned(id))
        }
        XCTAssertTrue(history.items.isEmpty, "Nothing listed in Activity")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: history.failedAudio.directory.path)) ?? []
        XCTAssertEqual(kept, [], "No recording kept")
    }

    func testAnomalousEntryCanBeTranscribedAgainWithoutLosingIt() async throws {
        let (id, history) = try await dictate(transcript: "send the report to bob on friday") { $0.selectedSTT = .parakeet }
        var copied: [String] = []
        let retrier = FailedDictationRetrier(
            history: history,
            process: { _, _ in DictationPipeline.RetryResult(rawTranscript: "raw", text: "Again.", llmModel: nil, style: nil) },
            copy: { copied.append($0) }
        )
        let before = try XCTUnwrap(history.item(id))
        await retrier.retry(id)
        XCTAssertEqual(copied, ["Again."])
        let after = try XCTUnwrap(history.item(id))
        XCTAssertEqual(after.cleanedText, before.cleanedText, "The pasted text stays")
        XCTAssertNotNil(history.keptAudioURL(for: after), "The recording stays")
    }
}

// MARK: - Pinning survives the caps

@MainActor
final class DictationPinningTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("pinning")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func normal(_ text: String = "hi") -> PipelineResult {
        PipelineResult(rawTranscript: text, cleanedText: text, sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date())
    }

    private func wav() throws -> URL {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        try Data(repeating: 3, count: 32).write(to: url)
        return url
    }

    func testFailedAndAnomalousEntriesSurviveTheCap() throws {
        let history = PipelineHistoryStore(maxItems: 3, maxPinnedItems: 2, fileURL: scratch.appendingPathComponent("history.json"))
        let failed = history.recordFailure(error: "x", wavURL: try wav(), sttProvider: .apple, llmProvider: .anthropic, appBundleID: nil, style: nil)
        let odd = normal("odd")
        history.add(odd)
        history.markAnomalous(odd.id, reasons: [.cleanupDiverged])
        history.keepAnomalyAudio(odd.id, wavURL: try wav())
        let firstNormal = normal()
        history.add(firstNormal)
        for _ in 0..<5 { history.add(normal()) }

        XCTAssertEqual(history.items.count, 5, "3 recent + 2 pinned")
        XCTAssertNotNil(history.item(failed.id))
        XCTAssertNotNil(history.item(odd.id))
        XCTAssertNil(history.item(firstNormal.id), "Normal entries still roll off")
        XCTAssertTrue(history.canRetry(try XCTUnwrap(history.item(failed.id))))
        XCTAssertNotNil(history.keptAudioURL(for: try XCTUnwrap(history.item(odd.id))))

        let reloaded = PipelineHistoryStore(maxItems: 3, maxPinnedItems: 2, fileURL: scratch.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.item(odd.id)?.anomaly?.reasons, [.cleanupDiverged], "Persisted")
    }

    func testPinnedEntriesHaveTheirOwnBound() throws {
        let history = PipelineHistoryStore(maxItems: 2, maxPinnedItems: 2, fileURL: scratch.appendingPathComponent("history.json"))
        var failures: [PipelineResult] = []
        for _ in 0..<4 {
            failures.append(history.recordFailure(error: "x", wavURL: try wav(), sttProvider: .apple, llmProvider: .anthropic, appBundleID: nil, style: nil))
        }
        for _ in 0..<2 { history.add(normal()) }
        XCTAssertEqual(history.items.count, 4)
        let pinnedIDs: [UUID] = history.items.filter { $0.isPinned }.map { $0.id }
        XCTAssertEqual(pinnedIDs, [failures[3].id, failures[2].id], "The newest pinned stay")
        let oldest = failures[0].failure?.audioFileName
        XCTAssertFalse(history.failedAudio.exists(try XCTUnwrap(oldest)), "A dropped entry's recording goes too")
    }

    func testDiagnosticsKeepFailedAndAnomalousRecordsPastTheCap() {
        let store = DictationDiagnosticsStore(maxItems: 2, maxPinnedItems: 1, fileURL: scratch.appendingPathComponent("d.json"))
        var anomalous = DictationDiagnostics(outcome: .success)
        anomalous.anomalies = [.sttFellBack]
        let failed = DictationDiagnostics(outcome: .failed, stage: .transcription)
        store.record(anomalous)
        store.record(failed)
        for _ in 0..<3 { store.record(DictationDiagnostics(outcome: .success)) }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertNotNil(store.item(failed.id))
        XCTAssertNil(store.item(anomalous.id), "Past the pinned bound")
    }

    func testRequestsOfPinnedDictationsSurviveTheCap() {
        let log = ProviderRequestLog(maxItems: 3, maxPinnedItems: 2, fileURL: scratch.appendingPathComponent("requests.json"))
        let pinnedDictation = UUID()
        log.isPinnedDictation = { $0 == pinnedDictation }
        func entry(_ dictation: UUID?) -> ProviderRequestLogEntry {
            ProviderRequestLogEntry(
                id: UUID(), timestamp: Date(), providerID: "groq", kind: .stt, endpointURL: "https://x", httpMethod: "POST",
                statusCode: 500, durationMS: 10, requestSummary: "", responseBodyPreview: "", errorMessage: "boom",
                dictationID: dictation
            )
        }
        let pinned = [entry(pinnedDictation), entry(pinnedDictation), entry(pinnedDictation)]
        let unpinned = entry(UUID())
        pinned.forEach(log.record)
        log.record(unpinned)
        for _ in 0..<3 { log.record(entry(nil)) }

        let ids = Set(log.items.map(\.id))
        XCTAssertEqual(log.items.count, 5, "3 recent + 2 pinned")
        XCTAssertTrue(ids.contains(pinned[2].id))
        XCTAssertTrue(ids.contains(pinned[1].id))
        XCTAssertFalse(ids.contains(pinned[0].id), "Past the pinned bound")
        XCTAssertFalse(ids.contains(unpinned.id), "Normal requests still roll off")
    }

    func testHistoryAnswersWhetherADictationIsPinned() {
        let history = PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        let ok = normal()
        history.add(ok)
        XCTAssertFalse(history.isPinned(ok.id))
        history.markAnomalous(ok.id, reasons: [.lowCharacterRate])
        XCTAssertTrue(history.isPinned(ok.id))

        let preProcessing = DictationDiagnostics(outcome: .failed, stage: .recording)
        history.diagnostics.record(preProcessing)
        XCTAssertTrue(history.isPinned(preProcessing.id), "Failures without a history entry count too")
        XCTAssertFalse(history.isPinned(UUID()))
    }
}
