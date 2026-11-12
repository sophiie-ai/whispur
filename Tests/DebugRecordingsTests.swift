import XCTest
@testable import Whispur

@MainActor
final class DebugRecordingStoreTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("debug-recordings")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func wav() throws -> URL {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        try Data(repeating: 5, count: 32).write(to: url)
        return url
    }

    func testRingKeepsOnlyTheNewestRecordings() throws {
        let store = DebugRecordingStore(directory: scratch.appendingPathComponent("DebugRecordings"), capacity: 3)
        let start = Date()
        let ids = (0..<5).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            let source = try wav()
            store.keepCopy(of: source, id: id, now: start.addingTimeInterval(Double(index)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "Copied: the pipeline still owns the original")
        }
        XCTAssertEqual(store.count, 3)
        XCTAssertEqual(store.recordings.map(\.lastPathComponent), ids.suffix(3).reversed().map { "\($0.uuidString).wav" })
    }

    func testRecordingsGetTheFailedAudioProtections() throws {
        let store = DebugRecordingStore(directory: scratch.appendingPathComponent("DebugRecordings"))
        store.keepCopy(of: try wav(), id: UUID())
        let file = try XCTUnwrap(store.recordings.first)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: store.files.directory.path)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual(try store.files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }

    func testRecordingsExpireAfterADay() throws {
        let store = DebugRecordingStore(directory: scratch.appendingPathComponent("DebugRecordings"))
        let now = Date()
        store.keepCopy(of: try wav(), id: UUID(), now: now.addingTimeInterval(-25 * 3600))
        let fresh = UUID()
        store.keepCopy(of: try wav(), id: fresh, now: now)
        store.purge(now: now)
        XCTAssertEqual(store.recordings.map(\.lastPathComponent), ["\(fresh.uuidString).wav"])
        XCTAssertEqual(store.count, 1)
    }

    func testDeleteAllEmptiesTheRing() throws {
        let store = DebugRecordingStore(directory: scratch.appendingPathComponent("DebugRecordings"))
        store.keepCopy(of: try wav(), id: UUID())
        store.keepCopy(of: try wav(), id: UUID())
        store.deleteAll()
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.files.directory.path))
    }
}

@MainActor
final class DebugRecordingsPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = try DiagnosticsTestSupport.makeScratch("debug-pipeline")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func dictate(keepDebug: Bool, history: PipelineHistoryStore? = nil) async throws -> (UUID, PipelineHistoryStore) {
        let transcript = "send the report to bob on friday"
        let (pipeline, history) = DiagnosticsTestSupport.makePipeline(
            scratch: scratch,
            stt: { transcript },
            llm: ScriptedLLM(.success(transcript)),
            history: history
        )
        pipeline.keepDebugRecordings = keepDebug
        let id = UUID()
        await pipeline.processRecordingForTesting(
            at: try DiagnosticsTestSupport.makeToneFile(in: scratch),
            metrics: DiagnosticsTestSupport.speechMetrics(seconds: 1),
            dictationID: id
        )
        await DiagnosticsTestSupport.settle { history.diagnostics.item(id)?.audio?.normalizedSampleCount != nil }
        return (id, history)
    }

    func testOffByDefaultKeepsNothing() async throws {
        let (pipeline, _) = DiagnosticsTestSupport.makePipeline(scratch: scratch, stt: { "" })
        XCTAssertFalse(pipeline.keepDebugRecordings)
        let (id, history) = try await dictate(keepDebug: false)
        XCTAssertNil(history.item(id)?.anomaly, "A normal dictation")
        XCTAssertEqual(history.debugRecordings.count, 0)
    }

    func testOnKeepsNormalDictationsInTheRing() async throws {
        let (id, history) = try await dictate(keepDebug: true)
        XCTAssertNil(history.item(id)?.anomaly)
        XCTAssertEqual(history.debugRecordings.recordings.map(\.lastPathComponent), ["\(id.uuidString).wav"])
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: history.failedAudio.directory.path)) ?? []
        XCTAssertEqual(kept, [], "Only the debug ring holds it")
    }

    func testClearHistoryDeletesDebugRecordings() async throws {
        let (_, history) = try await dictate(keepDebug: true)
        XCTAssertEqual(history.debugRecordings.count, 1)
        history.clear()
        XCTAssertEqual(history.debugRecordings.count, 0)
    }
}

@MainActor
final class DebugRecordingsSettingTests: XCTestCase {
    func testTurningTheSettingOffDeletesTheRecordings() throws {
        let scratch = try DiagnosticsTestSupport.makeScratch("debug-setting")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let defaultsValue = UserDefaults.standard.object(forKey: AppState.keepDebugRecordingsKey)
        defer { UserDefaults.standard.set(defaultsValue, forKey: AppState.keepDebugRecordingsKey) }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "debug-setting-\(UUID().uuidString)"))
        let history = PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json"))
        let appState = AppState(
            historyStore: history,
            stats: DictationStats(fileURL: scratch.appendingPathComponent("stats.json")),
            providerRequestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json")),
            vocabulary: VocabularyStore(defaults: defaults),
            styles: StyleStore(defaults: defaults, hasCustomPrompt: false),
            evalCases: MyEvalCaseStore(fileURL: scratch.appendingPathComponent("cases.jsonl")),
            startsServices: false
        )

        appState.setKeepDebugRecordings(true)
        XCTAssertTrue(appState.pipeline.keepDebugRecordings)
        let wav = scratch.appendingPathComponent("a.wav")
        try Data(repeating: 1, count: 16).write(to: wav)
        history.debugRecordings.keepCopy(of: wav, id: UUID())
        XCTAssertEqual(history.debugRecordings.count, 1)

        appState.setKeepDebugRecordings(false)
        XCTAssertFalse(appState.keepDebugRecordings)
        XCTAssertFalse(appState.pipeline.keepDebugRecordings)
        XCTAssertEqual(history.debugRecordings.count, 0, "Deleted right away")
    }

    func testCopySaysTheRecordingsStayOnThisMac() {
        XCTAssertTrue(DebugRecordingsSection.subtitle.contains("on this Mac only"))
        XCTAssertTrue(DebugRecordingsSection.subtitle.contains("24 hours"))
        XCTAssertTrue(DebugRecordingsSection.subtitle.contains("deletes them right away"))
    }
}
