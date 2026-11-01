import XCTest
@testable import Whispur

private func makeScratch() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-retry-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeWAV(in dir: URL, bytes: Int = 64) throws -> URL {
    let url = dir.appendingPathComponent("\(UUID().uuidString).wav")
    try Data(repeating: 7, count: bytes).write(to: url)
    return url
}

final class FailedAudioStoreTests: XCTestCase {
    private var scratch: URL!
    private var store: FailedAudioStore!

    override func setUpWithError() throws {
        scratch = try makeScratch()
        store = FailedAudioStore(directory: scratch.appendingPathComponent("FailedAudio"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    func testKeepMovesTheRecordingIntoAPrivateFolder() throws {
        let wav = try makeWAV(in: scratch)
        let id = UUID()
        let name = try store.keep(wav, id: id)
        XCTAssertEqual(name, "\(id.uuidString).wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path), "Moved, not copied")
        XCTAssertTrue(store.exists(name))

        let attributes = try FileManager.default.attributesOfItem(atPath: try XCTUnwrap(store.url(for: name)).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: store.directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let values = try store.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testPurgeDeletesOnlyRecordingsOlderThanADay() throws {
        let now = Date()
        let old = try store.keep(try makeWAV(in: scratch), id: UUID(), now: now.addingTimeInterval(-25 * 3600))
        let fresh = try store.keep(try makeWAV(in: scratch), id: UUID(), now: now.addingTimeInterval(-23 * 3600))
        XCTAssertEqual(store.purge(now: now), [old])
        XCTAssertFalse(store.exists(old))
        XCTAssertTrue(store.exists(fresh))
    }

    func testNamesCannotLeaveTheFolder() {
        XCTAssertNil(store.url(for: "../history.json"))
        XCTAssertNil(store.url(for: ".hidden"))
        XCTAssertFalse(store.exists("../x"))
    }
}

@MainActor
final class FailedDictationHistoryTests: XCTestCase {
    private var scratch: URL!
    private var history: PipelineHistoryStore!

    override func setUpWithError() throws {
        scratch = try makeScratch()
        history = PipelineHistoryStore(maxItems: 3, fileURL: scratch.appendingPathComponent("history.json"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func fail(at date: Date = Date()) throws -> PipelineResult {
        history.recordFailure(
            error: "Groq Whisper transcription timed out.",
            wavURL: try makeWAV(in: scratch),
            sttProvider: .groqWhisper,
            llmProvider: .groq,
            appBundleID: "com.apple.mail",
            style: .formal,
            at: date
        )
    }

    func testFailureKeepsAudioAndContext() throws {
        let item = try fail()
        XCTAssertTrue(item.isFailed)
        XCTAssertTrue(history.canRetry(item))
        XCTAssertEqual(item.failure?.error, "Groq Whisper transcription timed out.")
        XCTAssertEqual(item.appBundleID, "com.apple.mail")
        XCTAssertEqual(item.style, .formal)
        XCTAssertEqual(item.sttProvider, .groqWhisper)

        let reloaded = PipelineHistoryStore(maxItems: 3, fileURL: scratch.appendingPathComponent("history.json"))
        XCTAssertEqual(reloaded.items.first?.failure, item.failure, "Persisted")
    }

    func testFailureWithoutARecordingCannotBeRetried() {
        let item = history.recordFailure(error: "Could not read audio", wavURL: nil, sttProvider: .apple, llmProvider: .anthropic, appBundleID: nil, style: nil)
        XCTAssertTrue(item.isFailed)
        XCTAssertFalse(history.canRetry(item))
    }

    func testRetriedEntryTakesTheTextAndLosesItsAudio() throws {
        let item = try fail()
        let name = try XCTUnwrap(item.failure?.audioFileName)
        history.markRetried(item.id, rawTranscript: "hola que tal", text: "Hola, ¿qué tal?", llmModel: "m", style: .formal)
        let updated = try XCTUnwrap(history.item(item.id))
        XCTAssertFalse(updated.isFailed)
        XCTAssertEqual(updated.cleanedText, "Hola, ¿qué tal?")
        XCTAssertNotNil(updated.failure?.retriedAt)
        XCTAssertFalse(history.failedAudio.exists(name))
    }

    func testFailedRetryKeepsAudioAndShowsTheNewError() throws {
        let item = try fail()
        history.markRetryFailed(item.id, error: "No internet connection.")
        let updated = try XCTUnwrap(history.item(item.id))
        XCTAssertTrue(updated.isFailed)
        XCTAssertEqual(updated.failure?.error, "No internet connection.")
        XCTAssertTrue(history.canRetry(updated))
    }

    func testDeleteTrimAndClearRemoveRecordings() throws {
        let first = try fail()
        history.delete(first.id)
        XCTAssertNil(history.item(first.id))
        XCTAssertFalse(history.failedAudio.exists(try XCTUnwrap(first.failure?.audioFileName)))

        let oldest = try fail()
        for _ in 0 ..< 3 { _ = try fail() }
        XCTAssertNil(history.item(oldest.id), "Trimmed past maxItems")
        XCTAssertFalse(history.failedAudio.exists(try XCTUnwrap(oldest.failure?.audioFileName)))

        let names = history.items.compactMap(\.failure?.audioFileName)
        history.clear()
        XCTAssertTrue(names.allSatisfy { !history.failedAudio.exists($0) })
    }

    func testPurgeExpiresOldRecordingsButKeepsTheEntry() throws {
        let now = Date()
        let old = try fail(at: now.addingTimeInterval(-25 * 3600))
        let fresh = try fail(at: now)
        history.purgeExpiredAudio(now: now)
        XCTAssertNil(history.item(old.id)?.failure?.audioFileName)
        XCTAssertTrue(try XCTUnwrap(history.item(old.id)).isFailed)
        XCTAssertFalse(history.canRetry(try XCTUnwrap(history.item(old.id))))
        XCTAssertTrue(history.canRetry(try XCTUnwrap(history.item(fresh.id))))
    }

    func testOldHistoryWithoutFailuresStillLoads() throws {
        let url = scratch.appendingPathComponent("old.json")
        let json = #"[{"id":"\#(UUID().uuidString)","rawTranscript":"hi there","cleanedText":"Hi there.","sttProvider":"deepgram","llmProvider":"anthropic","timestamp":0}]"#
        try Data(json.utf8).write(to: url)
        let store = PipelineHistoryStore(fileURL: url)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertFalse(store.items[0].isFailed)
    }
}

final class FailureClassificationTests: XCTestCase {
    func testTranscriptionErrorsAreFailures() {
        XCTAssertTrue(DictationFailureClassifier.isFailure(STTError.timeout(provider: .groqWhisper), taskCancelled: false))
        XCTAssertTrue(DictationFailureClassifier.isFailure(STTError.apiError(provider: .openai, message: "x", statusCode: 500), taskCancelled: false))
        XCTAssertTrue(DictationFailureClassifier.isFailure(STTError.missingAPIKey(provider: .deepgram), taskCancelled: false))
        XCTAssertTrue(DictationFailureClassifier.isFailure(URLError(.notConnectedToInternet), taskCancelled: false))
    }

    func testCancellingIsNotAFailure() {
        XCTAssertFalse(DictationFailureClassifier.isFailure(CancellationError(), taskCancelled: false))
        XCTAssertFalse(DictationFailureClassifier.isFailure(URLError(.cancelled), taskCancelled: false))
        XCTAssertFalse(DictationFailureClassifier.isFailure(STTStreamingError.cancelled, taskCancelled: false))
        XCTAssertFalse(DictationFailureClassifier.isFailure(STTError.timeout(provider: .apple), taskCancelled: true))
    }

    func testCleanupErrorPastesTheRawTranscriptSoItIsNotAFailure() {
        // A cleanup error reaches the decision as nil cleaned text: the raw
        // transcript is pasted, never kept as a failure.
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: "send the invoice tomorrow", cleaned: nil),
            .paste("send the invoice tomorrow", rawFallbackReason: .cleanupUnavailable)
        )
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: "send the invoice tomorrow", cleaned: ""),
            .paste("send the invoice tomorrow", rawFallbackReason: .cleanupEmpty)
        )
    }
}

@MainActor
final class FailedDictationRetrierTests: XCTestCase {
    private var scratch: URL!
    private var history: PipelineHistoryStore!
    private var copied: [String] = []

    override func setUpWithError() throws {
        scratch = try makeScratch()
        history = PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        copied = []
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func failed() throws -> PipelineResult {
        history.recordFailure(error: "Timed out", wavURL: try makeWAV(in: scratch), sttProvider: .groqWhisper, llmProvider: .groq, appBundleID: "com.tinyspeck.slackmacgap", style: .casual)
    }

    private func retrier(_ process: @escaping (URL, PipelineResult) async throws -> DictationPipeline.RetryResult) -> FailedDictationRetrier {
        FailedDictationRetrier(history: history, process: process, copy: { [weak self] in self?.copied.append($0) })
    }

    func testSuccessCopiesMarksRetriedAndDeletesAudio() async throws {
        let item = try failed()
        let name = try XCTUnwrap(item.failure?.audioFileName)
        var seen: (URL, String?)?
        let retrier = retrier { url, item in
            seen = (url, item.appBundleID)
            return .init(rawTranscript: "hola que tal", text: "Hola, ¿qué tal?", llmModel: "m", style: .casual)
        }
        await retrier.retry(item.id)

        XCTAssertEqual(seen?.0.lastPathComponent, name, "Ran on the kept recording")
        XCTAssertEqual(seen?.1, "com.tinyspeck.slackmacgap", "With the original app, for its style")
        XCTAssertEqual(copied, ["Hola, ¿qué tal?"])
        XCTAssertEqual(retrier.toast, "Copied to clipboard")
        XCTAssertFalse(history.failedAudio.exists(name))
        let updated = try XCTUnwrap(history.item(item.id))
        XCTAssertFalse(updated.isFailed)
        XCTAssertEqual(updated.cleanedText, "Hola, ¿qué tal?")
        XCTAssertFalse(retrier.isRunning(item.id))
    }

    func testFailureKeepsAudioAndShowsTheError() async throws {
        let item = try failed()
        let retrier = retrier { _, _ in throw STTError.timeout(provider: .groqWhisper) }
        await retrier.retry(item.id)

        XCTAssertTrue(copied.isEmpty)
        XCTAssertNil(retrier.toast)
        let updated = try XCTUnwrap(history.item(item.id))
        XCTAssertTrue(updated.isFailed)
        XCTAssertEqual(updated.failure?.error, STTError.timeout(provider: .groqWhisper).localizedDescription)
        XCTAssertTrue(history.canRetry(updated))
        XCTAssertFalse(retrier.isRunning(item.id))
    }

    func testProgressIsShownWhileRunningAndASecondTapIsIgnored() async throws {
        let item = try failed()
        var calls = 0
        let gate = AsyncStream<Void>.makeStream()
        let retrier = retrier { _, _ in
            calls += 1
            for await _ in gate.stream { break }
            return .init(rawTranscript: "a", text: "A.", llmModel: nil, style: nil)
        }
        let first = Task { await retrier.retry(item.id) }
        while !retrier.isRunning(item.id) { await Task.yield() }
        await retrier.retry(item.id)
        XCTAssertEqual(calls, 1)
        retrier.delete(item.id)
        XCTAssertNotNil(history.item(item.id), "Delete waits for the running retry")
        gate.continuation.yield()
        await first.value
        XCTAssertFalse(retrier.isRunning(item.id))
        XCTAssertEqual(calls, 1)
    }

    func testMissingRecordingFailsWithoutRunning() async throws {
        let item = try failed()
        history.failedAudio.delete(try XCTUnwrap(item.failure?.audioFileName))
        var calls = 0
        let retrier = retrier { _, _ in calls += 1; return .init(rawTranscript: "", text: "", llmModel: nil, style: nil) }
        await retrier.retry(item.id)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(history.item(item.id)?.failure?.error, DictationPipeline.RetryError.noRecording.localizedDescription)
    }

    func testDeleteRemovesTheEntryAndRecording() throws {
        let item = try failed()
        let name = try XCTUnwrap(item.failure?.audioFileName)
        retrier { _, _ in throw CancellationError() }.delete(item.id)
        XCTAssertNil(history.item(item.id))
        XCTAssertFalse(history.failedAudio.exists(name))
    }

    func testSuccessfulEntriesAreNeverRetried() async {
        history.add(PipelineResult(rawTranscript: "a", cleanedText: "A.", sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date()))
        var calls = 0
        let retrier = retrier { _, _ in calls += 1; return .init(rawTranscript: "", text: "", llmModel: nil, style: nil) }
        await retrier.retry(history.items[0].id)
        XCTAssertEqual(calls, 0)
    }
}
