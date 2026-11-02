import FluidAudio
import XCTest
@testable import Whispur

final class ParakeetTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-parakeet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Provider identity

    func testParakeetNeedsNoKeyAndRunsOnDevice() {
        let parakeet = STTProviderID.parakeet
        XCTAssertFalse(parakeet.requiresAPIKey)
        XCTAssertTrue(parakeet.runsOnDevice)
        XCTAssertTrue(parakeet.keychainKeys.isEmpty)
        XCTAssertNil(ProviderKeyCheck.forSpeech(parakeet))
        XCTAssertNil(parakeet.setupDescriptor.modelPicker)
        XCTAssertFalse(parakeet.supportsStreaming)
        XCTAssertEqual(parakeet.displayName, "Parakeet (on this Mac)")
        XCTAssertTrue(parakeet.setupDescriptor.hasLocalModel)
        XCTAssertFalse(STTProviderID.apple.setupDescriptor.hasLocalModel)
    }

    @MainActor
    func testRegistryMakesParakeetWithoutKeys() {
        let registry = ProviderRegistry(keychain: .shared, httpClient: ProviderHTTPClient(requestLog: ProviderRequestLog()))
        XCTAssertTrue(registry.makeSTTProvider(for: .parakeet) is ParakeetSTT)
    }

    // MARK: - Model location

    /// FluidAudio writes the download to `<parent>/<its folder name>` and
    /// its loader reads from there; a different name here would download
    /// fine and then never load.
    func testFolderMatchesFluidAudioCacheLayout() {
        let spec = ParakeetModelSpec.ultra
        XCTAssertEqual(spec.folderName, "parakeet-ultra")
        XCTAssertEqual(spec.folderName, AsrModels.defaultCacheDirectory(for: .ultra).lastPathComponent)
        XCTAssertEqual(
            ParakeetModelLocation.directory(for: spec, in: scratch).path,
            scratch.appendingPathComponent("parakeet-ultra").path
        )
    }

    func testInstalledNeedsEveryBundleAndTheVocabulary() throws {
        let spec = ParakeetModelSpec.ultra
        XCTAssertFalse(ParakeetModelLocation.isInstalled(spec, in: scratch))

        let directory = ParakeetModelLocation.directory(for: spec, in: scratch)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bundle in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
        }
        XCTAssertFalse(ParakeetModelLocation.isInstalled(spec, in: scratch), "The vocabulary is missing")

        try Data("{}".utf8).write(to: directory.appendingPathComponent("parakeet_v3_vocab.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("parakeet_vocab.json"))
        XCTAssertTrue(ParakeetModelLocation.isInstalled(spec, in: scratch))
    }

    // MARK: - Missing model

    func testMissingModelThrowsAClearErrorThatKeepsTheDictation() async throws {
        let wav = scratch.appendingPathComponent("clip.wav")
        try Data(count: 44).write(to: wav)
        let provider = ParakeetSTT(modelsDirectory: scratch)
        do {
            _ = try await provider.transcribe(fileURL: wav, language: .auto, vocabulary: [])
            XCTFail("Expected an error")
        } catch let error as STTError {
            guard case let .modelNotReady(provider, _) = error else { return XCTFail("Unexpected \(error)") }
            XCTAssertEqual(provider, .parakeet)
            XCTAssertEqual(error.errorDescription, ParakeetSTT.notDownloadedMessage)
            XCTAssertTrue(error.errorDescription?.contains("Download it in Settings > Providers") ?? false)
            // A failure (not a cancel): the recording is kept for retry.
            XCTAssertTrue(DictationFailureClassifier.isFailure(error, taskCancelled: false))
        }
    }

    // MARK: - Languages

    func testScriptHint() {
        XCTAssertNil(ParakeetLanguages.hint(for: .auto))
        XCTAssertEqual(ParakeetLanguages.hint(for: .single(code: "es-MX")), .spanish)
        // One language keeps the language itself (French gets FluidAudio's
        // English-leak filter).
        XCTAssertEqual(ParakeetLanguages.hint(for: .single(code: "fr-FR")), .french)
        // Several languages on one alphabet get a stand-in for it, never
        // French, whose filter would corrupt the other languages.
        XCTAssertEqual(ParakeetLanguages.hint(for: STTLanguageSelection(codes: ["en-US", "es-MX"])), .english)
        XCTAssertEqual(ParakeetLanguages.hint(for: STTLanguageSelection(codes: ["fr-FR", "de-DE"])), .english)
        XCTAssertEqual(ParakeetLanguages.hint(for: STTLanguageSelection(codes: ["ru-RU", "uk-UA"])), .russian)
        // Mixed alphabets or a language FluidAudio doesn't know: no hint.
        XCTAssertNil(ParakeetLanguages.hint(for: STTLanguageSelection(codes: ["en-US", "ru-RU"])))
        XCTAssertNil(ParakeetLanguages.hint(for: STTLanguageSelection(codes: ["en-US", "ja-JP"])))
        XCTAssertNil(ParakeetLanguages.hint(for: .single(code: "ja-JP")))
    }

    func testUnsupportedLanguages() {
        XCTAssertEqual(ParakeetLanguages.unsupported(in: STTLanguageSelection(codes: ["en-US", "es-ES"])), [])
        XCTAssertEqual(ParakeetLanguages.unsupported(in: STTLanguageSelection(codes: ["en-US", "ja-JP", "zh-CN"])), ["ja", "zh"])
    }

    // MARK: - Confidence

    func testConfidenceBecomesALogProbability() {
        XCTAssertEqual(ParakeetSTT.logConfidence(1), 0)
        XCTAssertEqual(ParakeetSTT.logConfidence(0.5) ?? 0, log(0.5), accuracy: 1e-9)
        XCTAssertNil(ParakeetSTT.logConfidence(0))
        XCTAssertNil(ParakeetSTT.logConfidence(.nan))
        // Order is kept, so the script guard still picks the surest re-run.
        XCTAssertGreaterThan(ParakeetSTT.logConfidence(0.9)!, ParakeetSTT.logConfidence(0.6)!)
    }

    // MARK: - Status

    func testModelStateDrivesSetupStatus() {
        XCTAssertEqual(ProviderSetupStatus(localModel: .notDownloaded), .needsDownload)
        XCTAssertEqual(ProviderSetupStatus(localModel: .failed("x")), .needsDownload)
        XCTAssertEqual(ProviderSetupStatus(localModel: .downloading(fraction: 0.4, isPreparing: false)), .downloading)
        XCTAssertEqual(ProviderSetupStatus(localModel: .installed(bytesOnDisk: 1)), .ready)

        let readiness = SettingsReadiness.derive(
            microphoneGranted: true, accessibilityGranted: true,
            speechProviderName: "Parakeet", speechStatus: .needsDownload,
            cleanupEnabled: true,
            cleanupProviderName: "Y", cleanupStatus: .ready
        )
        XCTAssertEqual(readiness.tone, .incomplete)
        XCTAssertEqual(readiness.detail, "Needs Parakeet model.")
    }

    func testDownloadProgressOnlyMovesForward() {
        let tracker = DownloadProgressTracker()
        XCTAssertEqual(tracker.record(.init(fractionCompleted: 0, phase: .listing)).fraction, 0)
        XCTAssertEqual(tracker.record(.init(fractionCompleted: 0.25, phase: .downloading(completedFiles: 3, totalFiles: 20))).fraction, 0.5)
        // A later bundle load restarts FluidAudio's own fraction.
        XCTAssertEqual(tracker.record(.init(fractionCompleted: 0.1, phase: .downloading(completedFiles: 0, totalFiles: 0))).fraction, 0.5)
        let preparing = tracker.record(.init(fractionCompleted: 0.6, phase: .compiling(modelName: "Encoder.mlmodelc")))
        XCTAssertEqual(preparing.fraction, 1)
        XCTAssertTrue(preparing.isPreparing)
    }

    @MainActor
    func testManagerSeesAndDeletesAModel() async throws {
        let spec = ParakeetModelSpec.ultra
        let manager = ParakeetModelManager(spec: spec, modelsDirectory: scratch, engine: ParakeetEngine())
        XCTAssertEqual(manager.downloadState, .notDownloaded)
        XCTAssertFalse(manager.isInstalled)

        let directory = ParakeetModelLocation.directory(for: spec, in: scratch)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for bundle in ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(bundle), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4096).write(to: directory.appendingPathComponent("parakeet_v3_vocab.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("parakeet_vocab.json"))
        manager.refresh()
        XCTAssertTrue(manager.isInstalled)
        guard case let .installed(bytes) = manager.downloadState else { return XCTFail("Not installed") }
        XCTAssertGreaterThan(bytes, 0)

        await manager.delete()
        XCTAssertEqual(manager.downloadState, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Real model (opt-in)

    /// Runs the downloaded model end to end through `ParakeetSTT`. Skipped
    /// unless `WHISPUR_PARAKEET_MODEL_TEST` is set (pass
    /// `TEST_RUNNER_WHISPUR_PARAKEET_MODEL_TEST=1` to xcodebuild) and the
    /// model is in ~/Library/Application Support/Whispur/Models.
    func testTranscribesWithTheDownloadedModel() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["WHISPUR_PARAKEET_MODEL_TEST"] != nil, "Set WHISPUR_PARAKEET_MODEL_TEST to run")
        try XCTSkipUnless(ParakeetModelLocation.isInstalled(.current), "Download the Parakeet model first")

        let cases: [(voice: String, text: String, language: STTLanguageSelection, expect: String)] = [
            ("Samantha", "Please send the signed contract before Friday.", STTLanguageSelection(codes: ["en-US", "es-MX"]), "contract"),
            ("Paulina", "La reunión con el cliente se movió al jueves por la mañana.", STTLanguageSelection(codes: ["en-US", "es-MX"]), "reunión"),
        ]
        let engine = ParakeetEngine()
        let provider = ParakeetSTT(engine: engine)
        for (index, item) in cases.enumerated() {
            let wav = try synthesize(item.text, voice: item.voice, name: "case\(index)")
            let scored = try await provider.transcribeScored(fileURL: wav, language: item.language, vocabulary: [])
            XCTAssertTrue(scored.text.lowercased().contains(item.expect), scored.text)
            XCTAssertNotNil(scored.confidence)
        }
        let isLoaded = await engine.isLoaded
        XCTAssertTrue(isLoaded, "The model stays loaded between dictations")
        await engine.unload()
    }

    private func synthesize(_ text: String, voice: String, name: String) throws -> URL {
        let aiff = scratch.appendingPathComponent("\(name).aiff")
        let wav = scratch.appendingPathComponent("\(name).wav")
        try run("/usr/bin/say", ["-v", voice, "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        return wav
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(tool) failed")
    }
}
