import XCTest
@testable import Whispur

final class WritingStylesTests: XCTestCase {
    // MARK: - Prompts

    func testDefaultStyleIsTheUnchangedDefaultPrompt() {
        XCTAssertEqual(Prompts.cleanupPrompt(for: .standard, customPrompt: ""), Prompts.defaultCleanup)
        XCTAssertEqual(Prompts.cleanupPrompt(for: .standard, customPrompt: "ignored"), Prompts.defaultCleanup)
        XCTAssertNil(WritingStyle.standard.promptSection)
    }

    func testCustomStyleUsesTheCustomPromptOrFallsBack() {
        XCTAssertEqual(Prompts.cleanupPrompt(for: .custom, customPrompt: "Shout everything."), "Shout everything.")
        XCTAssertEqual(Prompts.cleanupPrompt(for: .custom, customPrompt: "  \n"), Prompts.defaultCleanup)
    }

    /// A preset adds one tone section and changes nothing else: the shared
    /// rules before it and the output contract and examples after it are the
    /// default prompt's own text.
    func testPresetsOnlyAddAToneSection() throws {
        let marker = try XCTUnwrap(Prompts.defaultCleanup.range(of: Prompts.styleInsertionMarker))
        let rules = String(Prompts.defaultCleanup[..<marker.lowerBound])
        let contract = String(Prompts.defaultCleanup[marker.lowerBound...])

        for style in [WritingStyle.casual, .formal, .verbatim, .codeAware] {
            let prompt = Prompts.cleanupPrompt(for: style, customPrompt: "")
            let section = try XCTUnwrap(style.promptSection)
            XCTAssertTrue(prompt.hasPrefix(rules), "\(style) keeps the shared rules")
            XCTAssertTrue(prompt.hasSuffix(contract), "\(style) keeps the output contract and examples")
            let inserted = String(prompt.dropFirst(rules.count).dropLast(contract.count))
            XCTAssertTrue(inserted.hasPrefix("Style: \(style.title)."), "\(style)")
            XCTAssertTrue(inserted.contains(section), "\(style)")
            XCTAssertTrue(inserted.hasSuffix("\n\n"), "\(style) leaves a blank line before the contract")
            XCTAssertNotEqual(prompt, Prompts.defaultCleanup)
        }
    }

    func testStyleSectionsStayShort() throws {
        for style in [WritingStyle.casual, .formal, .verbatim, .codeAware] {
            let section = try XCTUnwrap(style.promptSection)
            XCTAssertLessThanOrEqual(section.split(separator: "\n").count, 2, "\(style)")
            XCTAssertLessThanOrEqual(section.split { $0.isWhitespace }.count, 50, "\(style)")
        }
    }

    func testStyleStringsHaveNoEmDashes() {
        for style in WritingStyle.allCases {
            for string in [style.title, style.sample, style.promptSection ?? ""] {
                XCTAssertFalse(string.contains("\u{2014}"), "Em dash in \(style)")
            }
        }
    }

    // MARK: - Resolution

    func testGroupsAreDisjointAndCoverTheirApps() {
        var seen = Set<String>()
        for group in AppGroup.allCases {
            XCTAssertTrue(seen.isDisjoint(with: group.bundleIDs), "\(group) shares a bundle id")
            seen.formUnion(group.bundleIDs)
        }
        XCTAssertEqual(AppGroup.group(for: "com.tinyspeck.slackmacgap"), .chat)
        XCTAssertEqual(AppGroup.group(for: "com.apple.mail"), .email)
        XCTAssertEqual(AppGroup.group(for: "md.obsidian"), .docs)
        XCTAssertEqual(AppGroup.group(for: "com.mitchellh.ghostty"), .code)
        XCTAssertNil(AppGroup.group(for: "com.apple.Safari"))
    }

    func testOverrideBeatsGroupBeatsDefault() {
        var settings = StyleSettings.initial
        settings.fallback = .formal
        settings.groups[.chat] = .verbatim
        settings.overrides = [AppStyleOverride(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", style: .codeAware)]

        XCTAssertEqual(settings.resolve(bundleID: "com.tinyspeck.slackmacgap").style, .codeAware)
        XCTAssertEqual(settings.resolve(bundleID: "com.tinyspeck.slackmacgap").reason, .override)
        XCTAssertEqual(settings.resolve(bundleID: "com.apple.MobileSMS").style, .verbatim)
        XCTAssertEqual(settings.resolve(bundleID: "com.apple.MobileSMS").reason, .group(.chat))
        XCTAssertEqual(settings.resolve(bundleID: "com.apple.Safari").style, .formal)
        XCTAssertEqual(settings.resolve(bundleID: "com.apple.Safari").reason, .fallback)
        XCTAssertEqual(settings.resolve(bundleID: nil).style, .formal)
    }

    func testInitialSettingsPutEveryGroupOnDefault() {
        let initial = StyleSettings.initial
        XCTAssertEqual(initial.fallback, .standard, "Apps outside every group behave exactly as today")
        for group in AppGroup.allCases {
            XCTAssertEqual(group.defaultStyle, .standard, "\(group) starts on Default")
            XCTAssertEqual(initial.style(for: group), .standard, "\(group) starts on Default")
        }
    }

    @MainActor
    func testUpgradeWithoutACustomPromptChangesNothing() throws {
        let suite = "ai.sophiie.whispur.tests.styles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = StyleStore(defaults: defaults, hasCustomPrompt: false)
        XCTAssertEqual(store.settings, .initial)
        for bundleID in ["com.tinyspeck.slackmacgap", "com.apple.mail", "md.obsidian", "com.mitchellh.ghostty", "com.apple.Safari"] {
            let choice = store.choice(for: bundleID, customPrompt: "")
            XCTAssertEqual(choice.style, .standard, bundleID)
            XCTAssertEqual(choice.systemPrompt, Prompts.defaultCleanup, bundleID)
        }
    }

    // MARK: - Store

    @MainActor
    func testStorePersistsAndKeepsAnExistingCustomPromptEverywhere() throws {
        let suite = "ai.sophiie.whispur.tests.styles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let customUser = StyleStore(defaults: defaults, hasCustomPrompt: true)
        XCTAssertEqual(customUser.settings, .customEverywhere)
        XCTAssertEqual(customUser.choice(for: "com.apple.mail", customPrompt: "Mine").systemPrompt, "Mine")

        customUser.setStyle(.formal, for: .email)
        customUser.setOverride(bundleID: "com.apple.Safari", name: "Safari", style: .casual)
        customUser.setOverride(bundleID: "com.apple.Safari", name: "Safari", style: .verbatim)
        XCTAssertEqual(customUser.settings.overrides.count, 1, "One override per app")

        let reloaded = StyleStore(defaults: defaults, hasCustomPrompt: false)
        XCTAssertEqual(reloaded.settings, customUser.settings, "Stored choices win over first-run defaults")

        reloaded.removeOverride(bundleID: "com.apple.Safari")
        XCTAssertTrue(reloaded.settings.overrides.isEmpty)
        reloaded.reset()
        XCTAssertEqual(reloaded.settings, .initial)
    }

    @MainActor
    func testCustomChoiceWithoutAPromptFallsBackToDefault() throws {
        let suite = "ai.sophiie.whispur.tests.styles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = StyleStore(defaults: defaults, hasCustomPrompt: false)
        store.setFallback(.custom)
        let choice = store.choice(for: "com.apple.Safari", customPrompt: "")
        XCTAssertEqual(choice.style, .standard)
        XCTAssertEqual(choice.systemPrompt, Prompts.defaultCleanup)

        store.setStyle(.casual, for: .chat)
        let slack = store.choice(for: "com.tinyspeck.slackmacgap", customPrompt: "")
        XCTAssertEqual(slack.style, .casual, "A group the user opted into keeps its style")
        XCTAssertEqual(slack.systemPrompt, Prompts.cleanupPrompt(for: .casual, customPrompt: ""))
    }

    // MARK: - Bundle id capture

    @MainActor
    func testPipelineCapturesTheAppAtRecordingStartAndResolvesItsStyle() {
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: ProviderHTTPClient(requestLog: ProviderRequestLog(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("requests-\(UUID().uuidString).json")))),
            historyStore: PipelineHistoryStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json"))
        )
        XCTAssertNil(pipeline.cleanupChoice(), "No resolver: cleanup keeps systemPrompt")

        var frontmost: String? = "com.tinyspeck.slackmacgap"
        pipeline.frontmostBundleID = { frontmost }
        var asked: [String?] = []
        pipeline.cleanupStyle = { bundleID in
            asked.append(bundleID)
            return CleanupStyleChoice(style: .casual, systemPrompt: "casual prompt")
        }

        pipeline.noteRecordingApp()
        frontmost = "com.apple.mail" // The user switches apps while Whispur works.

        XCTAssertEqual(pipeline.recordingAppBundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(pipeline.cleanupChoice(), CleanupStyleChoice(style: .casual, systemPrompt: "casual prompt"))
        XCTAssertEqual(asked, ["com.tinyspeck.slackmacgap"])
    }

    func testHistoryWithoutStyleFieldsStillDecodes() throws {
        let legacy = """
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","rawTranscript":"hi","cleanedText":"Hi.",
              "sttProvider":"apple","llmProvider":"anthropic","timestamp":0}]
            """
        let items = try JSONDecoder().decode([PipelineResult].self, from: Data(legacy.utf8))
        XCTAssertNil(items.first?.appBundleID)
        XCTAssertNil(items.first?.style)
    }
}
