import SwiftUI
import XCTest
@testable import Whispur

/// The "Clean up with AI" switch: with it off no cleanup request is made,
/// spoken edit commands still apply, history says "Cleanup off", and no
/// "Use raw" is offered.
@MainActor
final class CleanupToggleTests: XCTestCase {
    private var scratch: URL!

    /// "Scratch that" drops the first sentence; "New paragraph" adds a blank line.
    private static let spokenRaw = "Send the invoice to Alice. Scratch that. Send it to Bob instead. New paragraph. Thanks for the help."

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-cleanup-toggle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makePipeline(transcript: String, llm: CountingLLM) -> DictationPipeline {
        let client = ProviderHTTPClient(requestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json")))
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.selectedSTT = .apple
        pipeline.parakeetInstalled = { false }
        pipeline.sttProviderOverride = { _ in FixedSTT(text: transcript) }
        pipeline.llmProviderOverride = { _ in llm }
        pipeline.cleanupStyle = { _ in CleanupStyleChoice(style: .formal, systemPrompt: "formal prompt") }
        return pipeline
    }

    private func makeWAV() throws -> URL {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: url)
        return url
    }

    // MARK: - Pipeline

    func testCleanupOffMakesNoLLMRequestAndStillAppliesSpokenEdits() async throws {
        let llm = CountingLLM(reply: "Should never be pasted.")
        let pipeline = makePipeline(transcript: "  \(Self.spokenRaw)  ", llm: llm)
        pipeline.cleanupEnabled = false

        let result = try await pipeline.retryTranscription(audioURL: try makeWAV(), appBundleID: "com.apple.mail", dictationID: UUID())

        XCTAssertEqual(llm.calls, 0, "No cleanup request while the switch is off")
        let expected = VoiceCommands.apply(to: Self.spokenRaw)
        XCTAssertEqual(result.text, expected)
        XCTAssertFalse(result.text.contains("Alice"), "Scratch that applied")
        XCTAssertTrue(result.text.contains("\n\n"), "New paragraph applied")
        XCTAssertEqual(result.text, result.text.trimmingCharacters(in: .whitespacesAndNewlines), "Trimmed")
        XCTAssertEqual(result.rawTranscript, Self.spokenRaw)
        XCTAssertTrue(result.cleanupOff)
        XCTAssertNil(result.llmModel)
        XCTAssertNil(result.style, "No style: no model read the text")
    }

    func testCleanupOffDecisionIsMarkedAndNeverAFallback() async {
        let llm = CountingLLM(reply: "x")
        let pipeline = makePipeline(transcript: "", llm: llm)
        pipeline.cleanupEnabled = false

        let decided = await pipeline.decideText(forRaw: Self.spokenRaw, styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(decided?.cleanupOff, true)
        XCTAssertNil(decided?.rawFallbackReason, "Switched off is not a cleanup failure")
        XCTAssertEqual(llm.calls, 0)

        let scratchedOut = await pipeline.decideText(forRaw: "Send it to Alice. Scratch that.", styleChoice: nil, updatesPhase: false)
        XCTAssertNil(scratchedOut, "Nothing left after scratch that: dismissed, as with cleanup on")
    }

    func testCleanupOnStillCallsTheProvider() async throws {
        let llm = CountingLLM(reply: "Send it to Bob instead.\n\nThanks for the help!")
        let pipeline = makePipeline(transcript: Self.spokenRaw, llm: llm)
        XCTAssertTrue(pipeline.cleanupEnabled, "On by default")

        let result = try await pipeline.retryTranscription(audioURL: try makeWAV(), appBundleID: nil, dictationID: UUID())

        XCTAssertEqual(llm.calls, 1)
        XCTAssertEqual(llm.lastUserMessage?.contains("Alice"), false, "The model sees the transcript after spoken edits")
        XCTAssertEqual(result.text, "Send it to Bob instead.\n\nThanks for the help!")
        XCTAssertEqual(result.llmModel, CountingLLM.model)
        XCTAssertEqual(result.style, .formal)
        XCTAssertFalse(result.cleanupOff)
    }

    func testFailedDictationRetryWorksWithCleanupOff() async throws {
        let llm = CountingLLM(reply: "x")
        let pipeline = makePipeline(transcript: Self.spokenRaw, llm: llm)
        pipeline.cleanupEnabled = false
        let history = PipelineHistoryStore(fileURL: scratch.appendingPathComponent("retry-history.json"))
        let failed = history.recordFailure(
            error: "Groq Whisper transcription timed out.",
            wavURL: try makeWAV(),
            sttProvider: .groqWhisper, llmProvider: .anthropic, appBundleID: nil, style: .formal
        )
        var copied: [String] = []
        let retrier = FailedDictationRetrier(
            history: history,
            process: { url, item in try await pipeline.retryTranscription(audioURL: url, appBundleID: item.appBundleID, dictationID: item.id) },
            copy: { copied.append($0) }
        )

        await retrier.retry(failed.id)

        let item = try XCTUnwrap(history.item(failed.id))
        XCTAssertFalse(item.isFailed)
        XCTAssertTrue(item.isCleanupOff)
        XCTAssertNil(item.style)
        XCTAssertEqual(copied, [VoiceCommands.apply(to: Self.spokenRaw)])
        XCTAssertEqual(llm.calls, 0)
    }

    // MARK: - History

    func testHistoryRecordsCleanupOffAndOldHistoryStillDecodes() throws {
        let off = PipelineResult(
            rawTranscript: "hi there", cleanedText: "hi there", sttProvider: .apple, llmProvider: .anthropic,
            llmModel: nil, timestamp: Date(timeIntervalSince1970: 0), cleanupOff: true
        )
        let decoded = try JSONDecoder().decode(PipelineResult.self, from: JSONEncoder().encode(off))
        XCTAssertTrue(decoded.isCleanupOff)

        let cleaned = PipelineResult(
            rawTranscript: "hi there", cleanedText: "Hi there.", sttProvider: .apple, llmProvider: .anthropic,
            llmModel: "m", timestamp: Date(timeIntervalSince1970: 0)
        )
        let cleanedJSON = try XCTUnwrap(String(data: JSONEncoder().encode(cleaned), encoding: .utf8))
        XCTAssertFalse(cleanedJSON.contains("cleanupOff"), "Cleaned dictations store nothing new")

        let legacy = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","rawTranscript":"hi","cleanedText":"Hi.",
              "sttProvider":"apple","llmProvider":"anthropic","timestamp":0}]
            """
        let items = try JSONDecoder().decode([PipelineResult].self, from: Data(legacy.utf8))
        XCTAssertEqual(items.first?.isCleanupOff, false)
    }

    func testRetriedEntryKeepsCleanupOffAcrossReload() throws {
        let url = scratch.appendingPathComponent("marked.json")
        let history = PipelineHistoryStore(fileURL: url)
        let item = history.recordFailure(error: "e", wavURL: nil, sttProvider: .apple, llmProvider: .anthropic, appBundleID: nil, style: nil)
        history.markRetried(item.id, rawTranscript: "hola", text: "hola", llmModel: nil, style: nil, cleanupOff: true)
        XCTAssertEqual(PipelineHistoryStore(fileURL: url).item(item.id)?.isCleanupOff, true)

        history.markRetried(item.id, rawTranscript: "hola", text: "Hola.", llmModel: "m", style: .standard)
        XCTAssertEqual(PipelineHistoryStore(fileURL: url).item(item.id)?.isCleanupOff, false, "A cleaned retry clears it")
    }

    // MARK: - Use raw

    func testNoUseRawOfferWhenCleanupWasOff() {
        let controller = UseRawController()
        var watch: [Bool] = []
        controller.setShortcutWatch = { watch.append($0) }
        // Spoken edits changed the words, but nothing to undo: the user asked for them.
        let off = PipelineResult(
            rawTranscript: Self.spokenRaw, cleanedText: VoiceCommands.apply(to: Self.spokenRaw),
            sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date(), cleanupOff: true
        )
        controller.offer(for: off, processID: 7, bundleID: nil, enabled: true)
        XCTAssertNil(controller.visibleOffer)
        XCTAssertEqual(watch.last, false)

        let cleaned = PipelineResult(
            rawTranscript: "um send it to bob", cleanedText: "Send the file to Bob.",
            sttProvider: .apple, llmProvider: .anthropic, llmModel: "m", timestamp: Date()
        )
        controller.offer(for: cleaned, processID: 7, bundleID: nil, enabled: true)
        XCTAssertNotNil(controller.visibleOffer, "Cleaned pastes still get the offer")
        controller.dismiss(.used)
    }

    // MARK: - Status

    private func readiness(cleanupEnabled: Bool, cleanupStatus: ProviderSetupStatus) -> SettingsReadiness {
        SettingsReadiness.derive(
            microphoneGranted: true, accessibilityGranted: true,
            speechProviderName: "Parakeet", speechStatus: .ready,
            cleanupEnabled: cleanupEnabled,
            cleanupProviderName: "Anthropic Claude", cleanupStatus: cleanupStatus
        )
    }

    func testStatusWithCleanupSwitchedOffAndNoKeys() {
        let off = readiness(cleanupEnabled: false, cleanupStatus: .needsKey)
        XCTAssertEqual(off.tone, .ready, "No cleanup key never blocks setup")
        XCTAssertEqual(off.detail, "Parakeet, cleanup switched off.")
        XCTAssertEqual(readiness(cleanupEnabled: false, cleanupStatus: .ready).detail, "Parakeet, cleanup switched off.")
        XCTAssertEqual(readiness(cleanupEnabled: true, cleanupStatus: .ready).detail, "Parakeet with Anthropic Claude cleanup.")

        let sidebar = SidebarStatus.derive(
            dictationEnabled: true, readiness: off,
            speechProviderName: "Parakeet", cleanupEnabled: false,
            cleanupProviderName: "Anthropic Claude", cleanupReady: true
        )
        XCTAssertEqual(sidebar.tone, .ready)
        XCTAssertEqual(sidebar.headline, "Ready to dictate")
        XCTAssertEqual(sidebar.detail, "Parakeet \u{00B7} Cleanup off", "Off even with a key saved")
        XCTAssertNil(sidebar.target)

        // Get started never counts cleanup: the same setup is complete.
        let setup = SettingsSetupState(microphoneGranted: true, accessibilityGranted: true, speechReady: true, hasDictated: false)
        XCTAssertTrue(setup.isComplete)
        XCTAssertEqual(setup.pendingSteps, 1, "Only the first dictation is left")

        XCTAssertEqual(DictationSettingsView.pillTitle(isReady: true, cleanupEnabled: false), "Ready \u{00B7} Cleanup off")
        XCTAssertEqual(DictationSettingsView.pillTitle(isReady: true, cleanupEnabled: true), "Ready")
        XCTAssertEqual(DictationSettingsView.pillTitle(isReady: false, cleanupEnabled: false), "Needs setup")
    }

    func testNewCopyHasNoEmDashes() {
        let strings = [
            readiness(cleanupEnabled: false, cleanupStatus: .needsKey).detail,
            ProvidersSettingsView.cleanupSwitchTitle,
            ProvidersSettingsView.cleanupSwitchSubtitle,
            StylesSettingsView.cleanupOffTitle,
            StylesSettingsView.cleanupOffDetail,
        ]
        for string in strings {
            XCTAssertFalse(string.contains("\u{2014}"), "Em dash in: \(string)")
        }
    }

    // MARK: - Persistence

    func testSwitchPersistsAndDefaultsOn() throws {
        let key = AppState.cleanupEnabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let suite = "ai.sophiie.whispur.tests.cleanup-toggle"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaults.standard.removeObject(forKey: key)
        let first = makeAppState(defaults: defaults)
        XCTAssertTrue(first.cleanupEnabled, "Existing users keep cleanup")
        XCTAssertTrue(first.pipeline.cleanupEnabled)

        first.cleanupEnabled = false
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Bool, false)
        XCTAssertFalse(first.pipeline.cleanupEnabled, "The pipeline follows the switch straight away")

        let relaunched = makeAppState(defaults: defaults)
        XCTAssertFalse(relaunched.cleanupEnabled)
        XCTAssertFalse(relaunched.pipeline.cleanupEnabled)
    }

    private func makeAppState(defaults: UserDefaults) -> AppState {
        AppState(
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("state-history-\(UUID().uuidString).json")),
            stats: DictationStats(fileURL: scratch.appendingPathComponent("stats-\(UUID().uuidString).json")),
            providerRequestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("log-\(UUID().uuidString).json")),
            vocabulary: VocabularyStore(defaults: defaults),
            styles: StyleStore(defaults: defaults, hasCustomPrompt: false),
            evalCases: MyEvalCaseStore(fileURL: scratch.appendingPathComponent("cases-\(UUID().uuidString).jsonl")),
            startsServices: false
        )
    }
}

/// Renders the cleanup switch on and off. Skipped unless
/// `WHISPUR_RENDER_SETTINGS` is set; output goes to `WHISPUR_RENDER_DIR`,
/// default /tmp/whispur-cleanup-toggle.
@MainActor
final class CleanupToggleRenderTests: XCTestCase {
    func testRenderCleanupSwitch() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["WHISPUR_RENDER_SETTINGS"] != nil, "Set WHISPUR_RENDER_SETTINGS to render Settings")
        let dir = URL(fileURLWithPath: env["WHISPUR_RENDER_DIR"] ?? "/tmp/whispur-cleanup-toggle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let suite = "ai.sophiie.whispur.render.cleanup-toggle"
        let vocabularyDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { vocabularyDefaults.removePersistentDomain(forName: suite) }
        let pageDefaults = try XCTUnwrap(UserDefaults(suiteName: suite + ".pages"))
        defer { pageDefaults.removePersistentDomain(forName: suite + ".pages") }

        let key = AppState.cleanupEnabledKey
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let appState = try SettingsRenderTests.makeAppState(in: scratch, vocabularyDefaults: vocabularyDefaults)
        // Speech keys only, no cleanup key: with the switch off nothing may
        // ask for one. The speech provider is whatever is stored (not
        // changed here, since it lives in the standard defaults).
        let secrets = InMemorySecretStore()
        for key in STTProviderID.allCases.flatMap(\.keychainKeys) {
            secrets.values[key] = "sk-render-0000000000abcd"
        }
        let ready = SettingsView.PermissionsOverride(microphone: true, accessibility: true)

        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for enabled in [true, false] {
                appState.cleanupEnabled = enabled
                let state = enabled ? "on" : "off"
                for (tab, size) in [(SettingsTab.providers, CGSize(width: 1000, height: 1900)), (.styles, CGSize(width: 1000, height: 900)), (.dictation, CGSize(width: 1000, height: 760))] {
                    pageDefaults.set(tab.rawValue, forKey: SettingsView.selectedTabKey)
                    let view = SettingsView(appState: appState, secretStore: secrets, permissionsOverride: ready, defaults: pageDefaults)
                    try SettingsRenderTests.renderPNG(view, scheme: scheme, size: size, to: dir.appendingPathComponent("\(tab.rawValue)-cleanup-\(state)-\(suffix).png"))
                }
                try SettingsRenderTests.renderPNG(
                    MenuBarView(appState: appState),
                    scheme: scheme,
                    size: CGSize(width: 370, height: 520),
                    to: dir.appendingPathComponent("menubar-cleanup-\(state)-\(suffix).png")
                )
            }
        }
    }
}

private struct FixedSTT: STTProvider {
    static let providerID: STTProviderID = .apple
    let text: String

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        text
    }
}

/// A cleanup provider that counts its requests.
private final class CountingLLM: LLMProvider, @unchecked Sendable {
    static let providerID: LLMProviderID = .anthropic
    static let model = "fake-cleanup-model"

    private let reply: String
    private(set) var calls = 0
    private(set) var lastUserMessage: String?

    init(reply: String) {
        self.reply = reply
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        calls += 1
        lastUserMessage = request.userMessage
        return LLMResponse(text: reply, model: Self.model, promptTokens: nil, completionTokens: nil)
    }
}
