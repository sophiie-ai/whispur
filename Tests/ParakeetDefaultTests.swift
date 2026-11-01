import XCTest
@testable import Whispur

/// Parakeet as the default for users without keys: the default rules, the
/// Apple fallback while the model is missing, and the background download.
/// Nothing here reads the Keychain, touches the standard defaults, or
/// downloads or loads the real model.
final class ParakeetDefaultTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "whispur-parakeet-default-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Hardware

    func testParakeetNeedsAppleSiliconAndMacOS14() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let tahoe = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        let ventura = OperatingSystemVersion(majorVersion: 13, minorVersion: 6, patchVersion: 9)
        XCTAssertTrue(ParakeetSupport.isSupported(isAppleSilicon: true, os: sonoma))
        XCTAssertTrue(ParakeetSupport.isSupported(isAppleSilicon: true, os: tahoe))
        XCTAssertFalse(ParakeetSupport.isSupported(isAppleSilicon: false, os: tahoe), "Intel Macs keep Apple")
        XCTAssertFalse(ParakeetSupport.isSupported(isAppleSilicon: true, os: ventura))
    }

    // MARK: - Keys

    func testCloudSpeechKeysAreExactlyTheCloudProvidersKeys() {
        XCTAssertEqual(
            Set(CloudSTTKeys.providers),
            [.openai, .groqWhisper, .deepgram, .elevenlabs, .mistral, .metaMuse]
        )
        XCTAssertEqual(
            Set(CloudSTTKeys.keys),
            [.openaiAPIKey, .groqAPIKey, .deepgramAPIKey, .elevenlabsAPIKey, .mistralAPIKey, .metaAPIKey]
        )
    }

    func testOnlyAStoredCloudSpeechKeyCounts() {
        XCTAssertFalse(CloudSTTKeys.hasAny { _ in nil })
        XCTAssertFalse(CloudSTTKeys.hasAny { _ in "  \n" }, "Blank values don't count")
        XCTAssertFalse(CloudSTTKeys.hasAny { $0 == .anthropicAPIKey ? "sk-ant" : nil }, "Cleanup-only keys don't count")
        XCTAssertFalse(CloudSTTKeys.hasAny { $0 == .awsBedrockAPIKey || $0 == .awsRegion ? "x" : nil })
        for key in CloudSTTKeys.keys {
            XCTAssertTrue(CloudSTTKeys.hasAny { $0 == key ? "secret" : nil }, "\(key) counts")
        }
    }

    // MARK: - Default resolution

    func testStoredChoiceTellsNeverChosenFromChoseApple() {
        XCTAssertEqual(STTDefaultResolver.storedChoice(in: defaults), .neverChosen)
        defaults.set("apple", forKey: STTDefaultResolver.selectedSTTKey)
        XCTAssertEqual(STTDefaultResolver.storedChoice(in: defaults), .chosen(.apple))
        defaults.set("deepgram", forKey: STTDefaultResolver.selectedSTTKey)
        XCTAssertEqual(STTDefaultResolver.storedChoice(in: defaults), .chosen(.deepgram))
        defaults.set("retired-provider", forKey: STTDefaultResolver.selectedSTTKey)
        XCTAssertEqual(STTDefaultResolver.storedChoice(in: defaults), .chosen(.apple), "Unknown values are a choice, shown as Apple")
    }

    /// Never chosen / chose Apple / chose a cloud provider, × keys / no keys,
    /// × supported / unsupported Mac.
    func testDefaultResolutionTruthTable() {
        let rows: [(stored: STTDefaultResolver.StoredChoice, keys: Bool, supported: Bool, expect: STTProviderID)] = [
            (.neverChosen, false, true, .parakeet),
            (.neverChosen, false, false, .apple),
            (.neverChosen, true, true, .apple),
            (.neverChosen, true, false, .apple),
            (.chosen(.apple), false, true, .apple),
            (.chosen(.apple), false, false, .apple),
            (.chosen(.apple), true, true, .apple),
            (.chosen(.apple), true, false, .apple),
            (.chosen(.openai), false, true, .openai),
            (.chosen(.openai), false, false, .openai),
            (.chosen(.openai), true, true, .openai),
            (.chosen(.openai), true, false, .openai),
            (.chosen(.parakeet), true, true, .parakeet),
        ]
        for row in rows {
            XCTAssertEqual(
                STTDefaultResolver.effectiveProvider(stored: row.stored, hasCloudSTTKey: row.keys, parakeetSupported: row.supported),
                row.expect,
                "\(row)"
            )
        }
    }

    func testAdoptionStoresParakeetOnlyForTheUsersItIsTheDefaultFor() {
        XCTAssertTrue(STTDefaultResolver.adoptParakeetIfDefault(defaults: defaults, hasCloudSTTKey: { false }, parakeetSupported: true))
        XCTAssertEqual(defaults.string(forKey: STTDefaultResolver.selectedSTTKey), "parakeet")
        XCTAssertTrue(defaults.bool(forKey: STTDefaultResolver.automaticParakeetKey))
    }

    func testAdoptionLeavesNoKeyIntelAndKeyedUsersOnApple() throws {
        for (keys, supported) in [(false, false), (true, true), (true, false)] {
            let suite = "whispur-adopt-\(UUID().uuidString)"
            let scratch = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { scratch.removePersistentDomain(forName: suite) }
            XCTAssertFalse(STTDefaultResolver.adoptParakeetIfDefault(defaults: scratch, hasCloudSTTKey: { keys }, parakeetSupported: supported))
            XCTAssertNil(scratch.object(forKey: STTDefaultResolver.selectedSTTKey), "Nothing stored: still never chosen")
            XCTAssertFalse(scratch.bool(forKey: STTDefaultResolver.automaticParakeetKey))
        }
    }

    func testAnExplicitChoiceIsNeverOverridden() {
        for choice in STTProviderID.allCases {
            defaults.set(choice.rawValue, forKey: STTDefaultResolver.selectedSTTKey)
            var askedForKeys = false
            let adopted = STTDefaultResolver.adoptParakeetIfDefault(
                defaults: defaults,
                hasCloudSTTKey: { askedForKeys = true; return false },
                parakeetSupported: true
            )
            XCTAssertFalse(adopted)
            XCTAssertFalse(askedForKeys, "A user who chose never pays for a Keychain read")
            XCTAssertEqual(defaults.string(forKey: STTDefaultResolver.selectedSTTKey), choice.rawValue)
            XCTAssertFalse(defaults.bool(forKey: STTDefaultResolver.automaticParakeetKey))
        }
    }

    func testAddingAKeyLaterDoesNotSwitchAwayFromParakeet() {
        STTDefaultResolver.adoptParakeetIfDefault(defaults: defaults, hasCloudSTTKey: { false }, parakeetSupported: true)
        // Next launch: the user has since saved an OpenAI key.
        STTDefaultResolver.adoptParakeetIfDefault(defaults: defaults, hasCloudSTTKey: { true }, parakeetSupported: true)
        let stored = STTDefaultResolver.storedChoice(in: defaults)
        XCTAssertEqual(stored, .chosen(.parakeet))
        XCTAssertEqual(STTDefaultResolver.effectiveProvider(stored: stored, hasCloudSTTKey: true, parakeetSupported: true), .parakeet)
    }

    // MARK: - Routing

    func testParakeetWithoutItsModelFallsBackToApple() {
        XCTAssertEqual(
            STTRoute.resolve(selected: .parakeet, parakeetInstalled: false),
            STTRoute(provider: .apple, fallbackFrom: .parakeet)
        )
        XCTAssertEqual(
            STTRoute.resolve(selected: .parakeet, parakeetInstalled: true),
            STTRoute(provider: .parakeet, fallbackFrom: nil)
        )
        for provider in STTProviderID.allCases where provider != .parakeet {
            for installed in [false, true] {
                XCTAssertEqual(STTRoute.resolve(selected: provider, parakeetInstalled: installed), STTRoute(provider: provider, fallbackFrom: nil))
            }
        }
    }

    @MainActor
    func testPipelineTranscribesWithAppleWhileTheModelDownloadsThenSwitches() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json"))
        let client = ProviderHTTPClient(requestLog: log)
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.selectedSTT = .parakeet
        var asked: [STTProviderID] = []
        pipeline.sttProviderOverride = { id in
            asked.append(id)
            return RouteFakeSTT(text: id == .apple ? "Apple" : "Parakeet")
        }
        let wav = scratch.appendingPathComponent("clip.wav")
        try Data(repeating: 0, count: 64).write(to: wav)

        var installed = false
        pipeline.parakeetInstalled = { installed }
        // Short transcripts skip cleanup, so no cleanup key is read.
        let whileDownloading = try await pipeline.retryTranscription(audioURL: wav, appBundleID: nil, dictationID: UUID())
        XCTAssertEqual(whileDownloading.rawTranscript, "Apple")

        installed = true
        let afterInstall = try await pipeline.retryTranscription(audioURL: wav, appBundleID: nil, dictationID: UUID())
        XCTAssertEqual(afterInstall.rawTranscript, "Parakeet")
        XCTAssertEqual(asked, [.apple, .parakeet])

        // Requests lists who did the work, newest first.
        for _ in 0 ..< 100 where log.items.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(log.items.map(\.providerID), ["parakeet", "apple"])
        XCTAssertTrue(log.items.allSatisfy(\.isOnDevice))
        XCTAssertEqual(log.items.last?.requestSummary, DictationPipeline.onDeviceSummary(for: STTRoute(provider: .apple, fallbackFrom: .parakeet)))
        XCTAssertTrue(log.items.last?.requestSummary.contains("Parakeet (on this Mac)'s model isn't downloaded yet") == true)
    }

    @MainActor
    func testOtherProvidersAddNoOnDeviceEntries() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-route-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let log = ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json"))
        let client = ProviderHTTPClient(requestLog: log)
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.selectedSTT = .apple
        pipeline.parakeetInstalled = { false }
        pipeline.sttProviderOverride = { _ in RouteFakeSTT(text: "Apple") }
        let wav = scratch.appendingPathComponent("clip.wav")
        try Data(repeating: 0, count: 64).write(to: wav)
        _ = try await pipeline.retryTranscription(audioURL: wav, appBundleID: nil, dictationID: UUID())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(log.items.isEmpty)
    }

    func testHistoryRecordsTheFallbackAndOldHistoryStillDecodes() throws {
        let result = PipelineResult(
            rawTranscript: "hi", cleanedText: "Hi.", sttProvider: .apple, llmProvider: .anthropic,
            llmModel: nil, timestamp: Date(timeIntervalSince1970: 0), sttFallbackFrom: .parakeet
        )
        let decoded = try JSONDecoder().decode(PipelineResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.sttFallbackFrom, .parakeet)
        XCTAssertEqual(decoded.sttProviderSummary, "Apple (on-device), filling in for Parakeet (on this Mac)")

        let legacy = """
            {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","rawTranscript":"hi","cleanedText":"Hi.",
             "sttProvider":"parakeet","llmProvider":"anthropic","timestamp":0}
            """
        let old = try JSONDecoder().decode(PipelineResult.self, from: Data(legacy.utf8))
        XCTAssertNil(old.sttFallbackFrom)
        XCTAssertEqual(old.sttProviderSummary, "Parakeet (on this Mac)")
    }

    // MARK: - Automatic download

    @MainActor
    private func makeAutoDownload(adopted: Bool = true) -> (ParakeetAutoDownload, FakeModel) {
        if adopted {
            STTDefaultResolver.adoptParakeetIfDefault(defaults: defaults, hasCloudSTTKey: { false }, parakeetSupported: true)
        }
        let model = FakeModel()
        return (ParakeetAutoDownload(defaults: defaults, model: model), model)
    }

    @MainActor
    func testAutoDownloadFiresOnceForTheAutomaticDefault() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        auto.launch(selected: .parakeet)
        auto.networkChanged(constrained: false)
        XCTAssertEqual(auto.startCount, 1)
        XCTAssertEqual(model.downloads, [.init(priority: .utility, automatic: true)])
    }

    @MainActor
    func testAutoDownloadWaitsForTheFirstNetworkReport() {
        let (auto, model) = makeAutoDownload()
        auto.launch(selected: .parakeet)
        XCTAssertTrue(model.downloads.isEmpty, "Network status unknown yet")
        auto.networkChanged(constrained: false)
        XCTAssertEqual(auto.startCount, 1)
    }

    @MainActor
    func testAutoDownloadNeverFiresForAnExplicitChoice() {
        // The user picked Parakeet themselves: no automatic flag.
        defaults.set("parakeet", forKey: STTDefaultResolver.selectedSTTKey)
        let (auto, model) = makeAutoDownload(adopted: false)
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        XCTAssertEqual(auto.startCount, 0)
        XCTAssertTrue(model.downloads.isEmpty)
    }

    @MainActor
    func testAutoDownloadNeverFiresWhenAnotherProviderIsSelected() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .apple)
        XCTAssertTrue(model.downloads.isEmpty)
    }

    @MainActor
    func testAutoDownloadIsDoneOnceTheModelIsHere() {
        let (auto, model) = makeAutoDownload()
        model.downloadState = .installed(bytesOnDisk: 1)
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        XCTAssertTrue(model.downloads.isEmpty)
        XCTAssertFalse(auto.isActive)
    }

    @MainActor
    func testAutoDownloadWaitsForWiFiAndResumes() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: true)
        auto.launch(selected: .parakeet)
        XCTAssertTrue(model.downloads.isEmpty)
        XCTAssertEqual(model.downloadState, .waitingForNetwork)

        auto.networkChanged(constrained: false)
        XCTAssertEqual(auto.startCount, 1)
        XCTAssertTrue(model.isDownloading)

        // Onto a hotspot mid-download: pause, then resume on Wi-Fi.
        auto.networkChanged(constrained: true)
        XCTAssertEqual(model.downloadState, .waitingForNetwork)
        auto.networkChanged(constrained: false)
        XCTAssertEqual(auto.startCount, 2)
    }

    @MainActor
    func testAMeteredNetworkLeavesTheUsersOwnDownloadAlone() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        model.downloadState = .downloading(fraction: 0.2, isPreparing: false)
        model.isAutomaticDownload = false // The user hit Download Now.
        auto.networkChanged(constrained: true)
        XCTAssertTrue(model.isDownloading)
    }

    @MainActor
    func testUserStoppingTheDownloadEndsItForGood() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        auto.userStopped()
        XCTAssertFalse(auto.isActive)

        // Next launch.
        let next = ParakeetAutoDownload(defaults: defaults, model: model)
        next.networkChanged(constrained: false)
        next.launch(selected: .parakeet)
        XCTAssertEqual(next.startCount, 0)
    }

    @MainActor
    func testAFailedDownloadIsRetriedOnceAtTheNextLaunch() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        model.downloadState = .failed("offline")
        auto.networkChanged(constrained: false)
        XCTAssertEqual(auto.startCount, 1, "No retries in the same session; Settings offers Retry")

        let next = ParakeetAutoDownload(defaults: defaults, model: model)
        next.networkChanged(constrained: false)
        next.launch(selected: .parakeet)
        XCTAssertEqual(next.startCount, 1)
    }

    @MainActor
    func testPickingAnotherProviderCancelsTheAutomaticDownload() {
        let (auto, model) = makeAutoDownload()
        auto.networkChanged(constrained: false)
        auto.launch(selected: .parakeet)
        auto.selectionChanged(to: .openai)
        XCTAssertEqual(model.automaticCancels, 1)
        XCTAssertFalse(auto.isActive)
    }

    @MainActor
    func testFinishedDownloadEndsTheAutomaticDownload() {
        let (auto, _) = makeAutoDownload()
        auto.installed()
        XCTAssertFalse(auto.isActive)
    }

    // MARK: - Model manager (no download)

    @MainActor
    func testManagerWaitsForNetworkAndOnlyCountsTheUsersCancel() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-pk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let manager = ParakeetModelManager(spec: .ultra, modelsDirectory: scratch, engine: ParakeetEngine())
        var userStops = 0
        manager.onUserStopped = { userStops += 1 }

        manager.pauseForNetwork()
        XCTAssertEqual(manager.downloadState, .waitingForNetwork)
        manager.refresh()
        XCTAssertEqual(manager.downloadState, .waitingForNetwork, "Refresh keeps the wait")

        manager.cancelAutomaticDownload()
        XCTAssertEqual(manager.downloadState, .notDownloaded)
        XCTAssertEqual(userStops, 0)

        manager.cancelDownload()
        XCTAssertEqual(userStops, 1)
    }

    // MARK: - Status and copy

    func testWaitingForWiFiStatus() {
        XCTAssertEqual(ProviderSetupStatus(localModel: .waitingForNetwork), .waitingForNetwork)
        XCTAssertEqual(ProviderSetupStatus.waitingForNetwork.title, "Waiting for Wi-Fi")
        XCTAssertTrue(NetworkConditionsMonitor.holdsBackgroundDownloads(isConstrained: true, isExpensive: false))
        XCTAssertTrue(NetworkConditionsMonitor.holdsBackgroundDownloads(isConstrained: false, isExpensive: true))
        XCTAssertFalse(NetworkConditionsMonitor.holdsBackgroundDownloads(isConstrained: false, isExpensive: false))
    }

    @MainActor
    func testAMissingModelDoesNotHoldSetupBack() {
        let credentials = ProviderCredentials(store: EmptySecretStore())
        let manager = ParakeetModelManager(
            spec: .ultra,
            modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("whispur-none-\(UUID().uuidString)"),
            engine: ParakeetEngine()
        )
        XCTAssertEqual(credentials.status(for: STTProviderID.parakeet.setupDescriptor, localModel: manager), .needsDownload)
        XCTAssertEqual(credentials.readinessStatus(for: STTProviderID.parakeet.setupDescriptor, localModel: manager), .ready)
        XCTAssertEqual(credentials.readinessStatus(for: STTProviderID.openai.setupDescriptor, localModel: manager), .needsKey)
    }

    func testDownloadLine() {
        XCTAssertEqual(
            ParakeetDownloadCopy.line(for: .downloading(fraction: 0.42, isPreparing: false)),
            "Downloading the on-device speech model \u{00B7} 42%"
        )
        XCTAssertEqual(ParakeetDownloadCopy.line(for: .downloading(fraction: 1, isPreparing: true)), "Preparing the on-device speech model")
        XCTAssertEqual(ParakeetDownloadCopy.line(for: .waitingForNetwork), "Waiting for Wi-Fi to download the on-device speech model")
        XCTAssertEqual(ParakeetDownloadCopy.line(for: .failed("x")), "Couldn't download the on-device speech model")
        XCTAssertNil(ParakeetDownloadCopy.line(for: .installed(bytesOnDisk: 1)))
    }
}

// MARK: - Fakes

private struct RouteFakeSTT: STTProvider {
    static let providerID: STTProviderID = .apple
    let text: String

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        text
    }
}

@MainActor
private final class FakeModel: ParakeetModelDownloading {
    struct Download: Equatable {
        let priority: TaskPriority?
        let automatic: Bool
    }

    var downloadState: ParakeetModelManager.DownloadState = .notDownloaded
    var isAutomaticDownload = false
    private(set) var downloads: [Download] = []
    private(set) var automaticCancels = 0

    var isInstalled: Bool {
        if case .installed = downloadState { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    func download(priority: TaskPriority?, automatic: Bool) {
        downloads.append(Download(priority: priority, automatic: automatic))
        isAutomaticDownload = automatic
        downloadState = .downloading(fraction: 0, isPreparing: false)
    }

    func pauseForNetwork() {
        guard !isInstalled else { return }
        if isDownloading, !isAutomaticDownload { return }
        isAutomaticDownload = false
        downloadState = .waitingForNetwork
    }

    func cancelAutomaticDownload() {
        automaticCancels += 1
        isAutomaticDownload = false
        downloadState = .notDownloaded
    }
}

private final class EmptySecretStore: SecretStore {
    func get(_ key: KeychainKey) -> String? { nil }
    func set(_ key: KeychainKey, value: String) -> Bool { false }
    func delete(_ key: KeychainKey) -> Bool { true }
}
