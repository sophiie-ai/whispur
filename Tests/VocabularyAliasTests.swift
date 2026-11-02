import XCTest
@testable import Whispur

/// "Heard as" spellings: which ones are replaced in code, how, and what
/// cleanup sees for the rest.
final class VocabularyAliasReplacerTests: XCTestCase {
    private func replace(_ text: String, _ rules: [(String, String)]) -> String {
        VocabularyAliasReplacer.apply(rules.map { VocabularyReplacement(phrase: $0.0, term: $0.1) }, to: text)
    }

    func testReplacesWholePhrasesIgnoringCaseAndKeepsPunctuation() {
        let rules = [("open code", "OpenCode"), ("wispur", "Whispur"), ("über", "Über")]
        XCTAssertEqual(replace("OPEN CODE, open code. Wispur's menu; über!", rules), "OpenCode, OpenCode. Whispur's menu; Über!")
        XCTAssertEqual(replace("reopen code, open codes, wispurs, übercool", rules), "reopen code, open codes, wispurs, übercool")
    }

    func testPhrasesNextToUnspacedScriptsStillMatch() {
        let rules = [("issue", "Issue"), ("open code", "OpenCode")]
        XCTAssertEqual(replace("这个issue很重要", rules), "这个Issue很重要")
        XCTAssertEqual(replace("用open code写", rules), "用OpenCode写")
        XCTAssertEqual(replace("ใช้issueบ่อย", rules), "ใช้Issueบ่อย")
        XCTAssertEqual(replace("issue_id issue2 reissues", rules), "issue_id issue2 reissues")
    }

    func testLongestMatchWinsAndReplacementsDoNotRecurse() {
        let rules = [("open", "closed"), ("open code", "OpenCode"), ("code then open", "combined"), ("closed", "shut")]
        XCTAssertEqual(replace("open code then open", rules), "closed combined")
        XCTAssertEqual(replace("alpha", [("alpha", "beta release"), ("beta", "gamma")]), "beta release")
    }

    func testARejectedMatchInsideAWordDoesNotHideAnOverlappingPhrase() {
        XCTAssertEqual(replace("Hi I I think so.", [("I I", "I")]), "Hi I think so.")
        XCTAssertEqual(replace("Breathe the the air.", [("the the", "the")]), "Breathe the air.")
    }

    func testAddressesPathsHandlesAndHyphenatedWordsAreLeftAlone() {
        let rules = [("sophie", "Sophiie")]
        for text in ["sophie@acme.io", "mail.sophie.dev", "acme.io/sophie", "@sophie", "#sophie", "Sophie-Anne", "sophie_bot"] {
            XCTAssertEqual(replace(text, rules), text)
        }
        XCTAssertEqual(replace("Ask Sophie. Then Sophie's team.", rules), "Ask Sophiie. Then Sophiie's team.")
    }
}

final class VocabularyAliasPlanTests: XCTestCase {
    /// A fixed word list, so the plan rules are tested without the Mac's
    /// spelling dictionaries.
    private static let common: Set<String> = ["whisper", "app", "sophie", "hanks", "open", "code", "cube", "cuddle", "planet", "scale"]
    private let isCommon: (String) -> Bool = { VocabularyAliasPlanTests.common.contains($0.lowercased()) }

    func testOnlyClearCutAliasesAreReplacedInCode() {
        let plan = VocabularyAliasPlan.build(
            entries: [
                VocabularyAliasEntry(term: "Whispur", aliases: ["Whisper", "Wispur", "Whisper app"]),
                VocabularyAliasEntry(term: "OpenCode", aliases: ["open code"]),
                VocabularyAliasEntry(term: "kubectl", aliases: ["cube cuddle", "kube control"]),
                VocabularyAliasEntry(term: "Sophiie", aliases: ["Sophie"]),
            ],
            terms: ["Whispur", "OpenCode", "kubectl", "Sophiie"],
            isCommonWord: isCommon
        )
        XCTAssertEqual(plan.replacements, [
            VocabularyReplacement(phrase: "Wispur", term: "Whispur"),
            VocabularyReplacement(phrase: "open code", term: "OpenCode"),
            VocabularyReplacement(phrase: "kube control", term: "kubectl"),
        ], "Not a word / the term split up / a phrase with a word that isn't ordinary")
        XCTAssertEqual(plan.heardAs, [
            "Whispur": ["Whisper", "Whisper app"],
            "kubectl": ["cube cuddle"],
            "Sophiie": ["Sophie"],
        ], "Ordinary words and names go to cleanup as hints")
    }

    func testAlwaysReplaceMakesEveryAliasClearCut() {
        let plan = VocabularyAliasPlan.build(
            entries: [VocabularyAliasEntry(term: "Sophiie", aliases: ["Sophie"], alwaysReplace: true)],
            terms: ["Sophiie"],
            isCommonWord: isCommon
        )
        XCTAssertEqual(plan.replacements, [VocabularyReplacement(phrase: "Sophie", term: "Sophiie")])
        XCTAssertTrue(plan.heardAs.isEmpty)
    }

    func testAliasesThatAreListedTermsOrClaimedTwiceAreDropped() {
        let plan = VocabularyAliasPlan.build(
            entries: [
                VocabularyAliasEntry(term: "Clyde", aliases: ["Claude", "Klyde", "  "], alwaysReplace: true),
                VocabularyAliasEntry(term: "Klide", aliases: ["klyde"], alwaysReplace: true),
            ],
            terms: ["Claude", "Clyde", "Klide"],
            isCommonWord: isCommon
        )
        XCTAssertTrue(plan.replacements.isEmpty, "\(plan.replacements)")
        XCTAssertTrue(plan.heardAs.isEmpty)
    }

    func testTheMacDictionaryKnowsOrdinaryWordsAndNames() {
        let checks: [(String, Bool)] = [("whisper", true), ("Sophie", true), ("hanks", true), ("Wispur", false), ("Hanx", false)]
        for (word, expected) in checks {
            XCTAssertEqual(CommonWords.isCommon(word), expected, word)
        }
    }

    /// The guard set: aliases meant as written must never be replaced in
    /// code unless the user asked for "Always replace".
    func testGuardSentencesAreNeverRewrittenInCode() {
        let plan = VocabularyAliasPlan.build(
            entries: [
                VocabularyAliasEntry(term: "Whispur", aliases: ["Whisper", "Wispur"]),
                VocabularyAliasEntry(term: "Sophiie", aliases: ["Sophie"]),
                VocabularyAliasEntry(term: "Hanx", aliases: ["Hanks"]),
            ],
            terms: [],
            isCommonWord: CommonWords.isCommon
        )
        var options = TextFixOptions()
        options.vocabulary = plan.replacements
        for text in [
            "I use Whisper from OpenAI for transcription.",
            "Please whisper it so the baby doesn't wake up.",
            "Sophie from accounting called about the invoice.",
            "Tom Hanks was great in that movie.",
            "Send it to sophie@acme.io.",
            "Hablé con Sofía y con Sophie ayer.",
        ] {
            XCTAssertEqual(TextFixes.apply(text, options: options), text)
        }
        XCTAssertEqual(TextFixes.apply("I pushed the fix to wispur.", options: options), "I pushed the fix to Whispur.")
    }
}

@MainActor
final class VocabularyAliasStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ai.sophiie.whispur.tests.aliases.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testAliasesPersistAndThePlainListStaysTermsOnly() {
        let store = VocabularyStore(defaults: defaults)
        store.add("Sophiie")
        let id = store.terms[0].id
        XCTAssertTrue(store.addAlias(" Sophie ", to: id))
        XCTAssertFalse(store.addAlias("sophie", to: id), "Duplicate, any case")
        XCTAssertFalse(store.addAlias("SOPHIIE", to: id), "The term itself")
        XCTAssertFalse(store.addAlias("  ", to: id))
        XCTAssertTrue(store.addAlias("Sofie", to: id))
        store.setAlwaysReplace(true, for: id)

        let reloaded = VocabularyStore(defaults: defaults)
        XCTAssertEqual(reloaded.terms[0].aliases, ["Sophie", "Sofie"])
        XCTAssertTrue(reloaded.terms[0].alwaysReplace)
        XCTAssertEqual(defaults.string(forKey: VocabularyStore.legacyKey), "Sophiie", "Older builds see the terms only")
        XCTAssertEqual(reloaded.aliasEntries, [VocabularyAliasEntry(term: "Sophiie", aliases: ["Sophie", "Sofie"], alwaysReplace: true)])

        reloaded.removeAlias("Sophie", from: id)
        reloaded.removeAlias("Sofie", from: id)
        XCTAssertEqual(reloaded.terms[0].aliases, [])
        XCTAssertFalse(reloaded.terms[0].alwaysReplace, "No aliases left: nothing to always replace")
    }

    func testTermsSavedBeforeAliasesStillLoad() throws {
        let saved = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"Whispur","source":{"manual":{}},"addedAt":800000000}]"#
        defaults.set(Data(saved.utf8), forKey: VocabularyStore.termsKey)
        let store = VocabularyStore(defaults: defaults)
        XCTAssertEqual(store.plainTerms, ["Whispur"])
        XCTAssertEqual(store.terms[0].aliases, [])
        XCTAssertFalse(store.terms[0].alwaysReplace)
    }

    func testAddAliasToTermCreatesOrMerges() {
        let store = VocabularyStore(defaults: defaults)
        XCTAssertTrue(store.addAlias("open code", toTerm: "OpenCode"))
        XCTAssertEqual(store.terms[0].text, "OpenCode")
        XCTAssertEqual(store.terms[0].source, .manual)
        XCTAssertTrue(store.addAlias("open cold", toTerm: "opencode"), "Merges into the existing term, any case")
        XCTAssertEqual(store.terms.count, 1)
        XCTAssertEqual(store.terms[0].aliases, ["open code", "open cold"])
        XCTAssertFalse(store.addAlias("same", toTerm: "Same"), "An alias that is the new term itself")
        XCTAssertEqual(store.terms.count, 1)
    }

    func testSearchFindsTermsByTheirAliases() {
        let store = VocabularyStore(defaults: defaults)
        store.addAlias("cube cuddle", toTerm: "kubectl")
        store.add("Whispur")
        XCTAssertEqual(VocabularyStore.filter(store.terms, query: "cuddle", filter: .all).map(\.text), ["kubectl"])
    }
}

/// The plan inside the pipeline.
@MainActor
final class VocabularyAliasPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-aliases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makePipeline(llm: AliasLLM) -> DictationPipeline {
        let client = ProviderHTTPClient(requestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json")))
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.llmProviderOverride = { _ in llm }
        pipeline.customVocabulary = ["Whispur", "OpenCode"]
        pipeline.aliasPlan = VocabularyAliasPlan(
            replacements: [VocabularyReplacement(phrase: "open code", term: "OpenCode")],
            heardAs: ["Whispur": ["Whisper"]]
        )
        return pipeline
    }

    func testCleanupOffReplacesOnlyClearCutAliases() async {
        let pipeline = makePipeline(llm: AliasLLM())
        pipeline.cleanupEnabled = false
        let decided = await pipeline.decideText(forRaw: "Open code and Whisper both work.", styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(decided?.text, "OpenCode and Whisper both work.")
    }

    func testCleanupOnSeesTheReplacementAndTheHints() async {
        let llm = AliasLLM()
        let pipeline = makePipeline(llm: llm)
        _ = await pipeline.decideText(forRaw: "Open code and Whisper both work.", styleChoice: nil, updatesPhase: false)
        let message = llm.lastUserMessage ?? ""
        XCTAssertTrue(message.contains("Whispur (heard as: Whisper)\nOpenCode\n</vocabulary>\n\(CleanupMessage.heardAsNote)"), message)
        XCTAssertTrue(message.contains("OpenCode and Whisper both work."), message)
    }
}

private final class AliasLLM: LLMProvider, @unchecked Sendable {
    static let providerID: LLMProviderID = .anthropic
    private(set) var lastUserMessage: String?

    func complete(request: LLMRequest) async throws -> LLMResponse {
        lastUserMessage = request.userMessage
        return LLMResponse(text: "OpenCode and Whisper both work.", model: "fake", promptTokens: nil, completionTokens: nil)
    }
}

/// The "Add to vocabulary…" prefill.
final class HeardAsSuggestionTests: XCTestCase {
    func testFirstMisspelledWordIsSuggested() {
        XCTAssertEqual(
            HeardAsSuggestion.from(raw: "um can you push the wispur build tonight", cleaned: "Can you push the Whispur build tonight?"),
            HeardAsSuggestion(term: "Whispur", heardAs: "wispur")
        )
        XCTAssertEqual(
            HeardAsSuggestion.from(raw: "run cube cuddle get pods", cleaned: "Run kubectl get pods."),
            HeardAsSuggestion(term: "kubectl", heardAs: "cube cuddle")
        )
    }

    func testCaseNumbersAndRemovedFillersAreNotVocabulary() {
        XCTAssertNil(HeardAsSuggestion.from(raw: "um ship it by five", cleaned: "Ship it by 5."))
        XCTAssertNil(HeardAsSuggestion.from(raw: "sounds good", cleaned: "Sounds good."))
        XCTAssertNil(HeardAsSuggestion.from(raw: "", cleaned: "x"))
    }
}
