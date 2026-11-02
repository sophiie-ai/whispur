import XCTest
@testable import Whispur

final class SettingsPagesTests: XCTestCase {
    // MARK: - Tabs

    func testStoredTabDecodesNewAndLegacyValues() {
        for tab in SettingsTab.allCases {
            XCTAssertEqual(SettingsTab(storedValue: tab.rawValue), tab)
        }
        XCTAssertEqual(SettingsTab(storedValue: "Setup"), .getStarted)
        XCTAssertEqual(SettingsTab(storedValue: "General"), .preferences)
        XCTAssertEqual(SettingsTab(storedValue: "Prompts"), .dictionary)
        XCTAssertEqual(SettingsTab(storedValue: "Providers"), .providers)
        XCTAssertEqual(SettingsTab(storedValue: "Activity"), .activity)
        XCTAssertEqual(SettingsTab(storedValue: "Requests"), .requests)
        XCTAssertNil(SettingsTab(storedValue: ""))
        XCTAssertNil(SettingsTab(storedValue: "Nope"))
    }

    func testSidebarGroupsCoverEveryVisibleTabOnce() {
        let grouped = SettingsTab.Group.allCases.flatMap(SettingsTab.tabs(in:))
        XCTAssertEqual(grouped, SettingsTab.visible)
        XCTAssertEqual(SettingsTab.tabs(in: .setup), [.getStarted, .providers, .preferences])
        XCTAssertEqual(SettingsTab.tabs(in: .diagnostics), [.activity, .requests])
    }

    func testLandingIsDictationOnlyOnceSetupIsComplete() {
        var state = SettingsSetupState(microphoneGranted: true, accessibilityGranted: true, speechReady: true, hasDictated: false)
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(state.landingTab, .dictation)
        XCTAssertEqual(state.pendingSteps, 1, "The first dictation is still a step")

        state.accessibilityGranted = false
        XCTAssertFalse(state.isComplete)
        XCTAssertEqual(state.landingTab, .getStarted)
        XCTAssertEqual(state.pendingSteps, 2)

        let done = SettingsSetupState(microphoneGranted: true, accessibilityGranted: true, speechReady: true, hasDictated: true)
        XCTAssertEqual(done.pendingSteps, 0)
    }

    // MARK: - Sidebar status

    private func readiness(mic: Bool = true, speech: ProviderSetupStatus = .ready) -> SettingsReadiness {
        SettingsReadiness.derive(
            microphoneGranted: mic, accessibilityGranted: true,
            speechProviderName: "Deepgram", speechStatus: speech,
            cleanupEnabled: true,
            cleanupProviderName: "Anthropic Claude", cleanupStatus: .ready
        )
    }

    func testSidebarStatusReady() {
        let status = SidebarStatus.derive(
            dictationEnabled: true, readiness: readiness(),
            speechProviderName: "Deepgram", cleanupEnabled: true, cleanupProviderName: "Anthropic Claude", cleanupReady: true
        )
        XCTAssertEqual(status.tone, .ready)
        XCTAssertEqual(status.headline, "Ready to dictate")
        XCTAssertEqual(status.detail, "Deepgram \u{00B7} Anthropic Claude cleanup")
        XCTAssertNil(status.target)

        let noCleanup = SidebarStatus.derive(
            dictationEnabled: true, readiness: readiness(),
            speechProviderName: "Deepgram", cleanupEnabled: true, cleanupProviderName: "Anthropic Claude", cleanupReady: false
        )
        XCTAssertEqual(noCleanup.detail, "Deepgram \u{00B7} Cleanup off")
    }

    func testSidebarStatusPointsAtTheFix() {
        let incomplete = SidebarStatus.derive(
            dictationEnabled: true, readiness: readiness(mic: false),
            speechProviderName: "Deepgram", cleanupEnabled: true, cleanupProviderName: "Anthropic Claude", cleanupReady: true
        )
        XCTAssertEqual(incomplete.tone, .attention)
        XCTAssertEqual(incomplete.target, .getStarted)
        XCTAssertEqual(incomplete.detail, "Needs microphone access.")

        let off = SidebarStatus.derive(
            dictationEnabled: false, readiness: readiness(),
            speechProviderName: "Deepgram", cleanupEnabled: true, cleanupProviderName: "Anthropic Claude", cleanupReady: true
        )
        XCTAssertEqual(off.tone, .off)
        XCTAssertEqual(off.target, .dictation)
    }

    // MARK: - Shortcuts

    func testKeycapLabels() {
        XCTAssertEqual(ShortcutBinding.fnKey.keycapLabels, ["fn"])
        XCTAssertEqual(ShortcutBinding.commandFn.keycapLabels, ["\u{2318}", "fn"])
        XCTAssertEqual(ShortcutBinding.fnDoublePress.keycapLabels, ["fn", "fn"])
        XCTAssertEqual(ShortcutBinding.rightOption.keycapLabels, ["Right \u{2325}"])
        XCTAssertEqual(ShortcutBinding.controlSpace.keycapLabels, ["\u{2303}", "Space"])
        XCTAssertEqual(ShortcutBinding.commandShiftSpace.keycapLabels, ["\u{21E7}", "\u{2318}", "Space"])
        XCTAssertEqual(ShortcutBinding.f5.keycapLabels, ["F5"])
    }

    // MARK: - Dictation page

    func testCountLabels() {
        XCTAssertEqual(DictationSettingsView.dictationCountLabel(1), "1 dictation")
        XCTAssertEqual(DictationSettingsView.dictationCountLabel(0), "0 dictations")
        XCTAssertEqual(DictationSettingsView.termCountLabel(1), "1 term")
        XCTAssertEqual(DictationSettingsView.termCountLabel(3), "3 terms")
    }

    func testStylesSummary() {
        var settings = StyleSettings.initial
        XCTAssertEqual(DictationSettingsView.stylesSummary(settings), "4 groups")
        settings.overrides = [AppStyleOverride(bundleID: "a", name: "A", style: .formal)]
        XCTAssertEqual(DictationSettingsView.stylesSummary(settings), "4 groups, 1 app")
    }

    func testPreviewTextIsOneLineAndFallsBackToRaw() {
        let multiline = PipelineResult(
            rawTranscript: "raw", cleanedText: "First line\n\n  second line ",
            sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date()
        )
        XCTAssertEqual(DictationSettingsView.previewText(multiline), "First line second line")

        let uncleaned = PipelineResult(
            rawTranscript: "just raw", cleanedText: "  ",
            sttProvider: .apple, llmProvider: .anthropic, llmModel: nil, timestamp: Date()
        )
        XCTAssertEqual(DictationSettingsView.previewText(uncleaned), "just raw")
    }

    // MARK: - Stats

    @MainActor
    func testDictationCountIsSeededOnceThenCounts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stats-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        // A stats file from before the count existed.
        try Data(#"{"totalWords":40,"dailyWords":{}}"#.utf8).write(to: url)

        let stats = DictationStats(fileURL: url)
        XCTAssertEqual(stats.totalDictations, 0)
        stats.seedDictationCountIfMissing(7)
        XCTAssertEqual(stats.totalDictations, 7)
        stats.seedDictationCountIfMissing(25)
        XCTAssertEqual(stats.totalDictations, 7, "Seeding is one-shot")

        stats.record(wordCount: 3)
        XCTAssertEqual(stats.totalDictations, 8)
        stats.record(wordCount: 0)
        XCTAssertEqual(stats.totalDictations, 8, "Empty dictations are not counted")

        let reloaded = DictationStats(fileURL: url)
        XCTAssertEqual(reloaded.totalDictations, 8)
        reloaded.seedDictationCountIfMissing(99)
        XCTAssertEqual(reloaded.totalDictations, 8)
    }
}
