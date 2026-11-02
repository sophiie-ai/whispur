import XCTest
@testable import Whispur

/// The no-AI text fixes: filler words, spoken quotes, spoken symbols, and
/// smart spacing at paste time.
final class TextFixesTests: XCTestCase {
    private func assertUnchanged(_ texts: [String], by fix: (String) -> String, file: StaticString = #filePath, line: UInt = #line) {
        for text in texts {
            XCTAssertEqual(fix(text), text, "Should stay as said: \(text)", file: file, line: line)
        }
    }

    // MARK: - Filler words

    func testFillersLeaveWithTheirCommasAndSpaces() {
        XCTAssertEqual(FillerWords.remove(from: "So, um, we should go."), "So, we should go.")
        XCTAssertEqual(FillerWords.remove(from: "I think uh we should go."), "I think we should go.")
        XCTAssertEqual(FillerWords.remove(from: "I think, um."), "I think.")
        XCTAssertEqual(FillerWords.remove(from: "Well umm... maybe"), "Well maybe")
        XCTAssertEqual(FillerWords.remove(from: "It was, er, erm, fine"), "It was, fine")
        XCTAssertEqual(FillerWords.remove(from: "Done, uh"), "Done")
        XCTAssertEqual(FillerWords.remove(from: "(um, aside)"), "(aside)")
        XCTAssertEqual(FillerWords.remove(from: "Let me, hmm, check"), "Let me, check")
        XCTAssertEqual(FillerWords.remove(from: "ummm I guess uhhh not"), "I guess not")
    }

    func testCapitalisedFillerHandsItsCapitalToTheNextWord() {
        XCTAssertEqual(FillerWords.remove(from: "Um, so I think"), "So I think")
        XCTAssertEqual(FillerWords.remove(from: "Hello. Uh, we left. Ah. Then"), "Hello. We left. Then")
        XCTAssertEqual(FillerWords.remove(from: "Uh, um, okay"), "Okay")
        XCTAssertEqual(FillerWords.remove(from: "Hmm. Let me think."), "Let me think.")
    }

    func testFillerOnlyDictationBecomesEmpty() {
        XCTAssertEqual(FillerWords.remove(from: "Um."), "")
        XCTAssertEqual(FillerWords.remove(from: "uh, um"), "")
    }

    func testLineBreaksAreKept() {
        XCTAssertEqual(FillerWords.remove(from: "First line.\nUm, second"), "First line.\nSecond")
        XCTAssertEqual(FillerWords.remove(from: "one um\ntwo"), "one\ntwo")
    }

    func testRealWordsAndQuotedFillersStay() {
        assertUnchanged([
            "The umbrella is ahead of the error.",
            "Uhura said uh-huh.",
            "Take him to the ER.",
            "UM is a university.",
            "drum, Ahab, ermine, hum, hm",
            "um2 and uh_oh are identifiers",
            // Words that are fillers only sometimes.
            "I like it, so we should go, you know.",
            // Quoted or named as a word.
            "Rename the \"um\" label to \u{201C}uh\u{201D}.",
            "The word um is a filler.",
            "Plain text, nothing to do.",
            "",
        ], by: { FillerWords.remove(from: $0) })
    }

    func testSpanishAndCJKAreLeftAlone() {
        assertUnchanged([
            // "este" is also a demonstrative, "eh" also a tag question.
            "Este proyecto está bien, ¿eh?",
            "Ahí está, ahora mismo, umbral.",
            // Unspaced scripts: a Latin run inside is a word, not a filler.
            "这个um很重要",
            "えーとahまだ",
        ], by: { FillerWords.remove(from: $0) })
        XCTAssertEqual(FillerWords.remove(from: "Bueno, eh, um, vamos"), "Bueno, eh, vamos")
    }

    // MARK: - Spoken quotes

    func testQuotePairsBecomeQuotationMarks() {
        XCTAssertEqual(SpokenQuotes.apply(to: "He said open quote hi close quote.", style: .curly), "He said \u{201C}hi\u{201D}.")
        XCTAssertEqual(
            SpokenQuotes.apply(to: "He said, quote, I'll be there, end quote, and left.", style: .curly),
            "He said, \u{201C}I'll be there\u{201D}, and left."
        )
        XCTAssertEqual(SpokenQuotes.apply(to: "quote yes unquote then", style: .curly), "\u{201C}yes\u{201D} then")
        XCTAssertEqual(SpokenQuotes.apply(to: "Begin quote ship it end of quote", style: .curly), "\u{201C}ship it\u{201D}")
        XCTAssertEqual(
            SpokenQuotes.apply(to: "set the title to open quote Hello world close quote", style: .straight),
            "set the title to \"Hello world\""
        )
    }

    func testQuoteWordsWithoutAPairStay() {
        assertUnchanged([
            // Trades: a quote is a price.
            "Send me the quote for the kitchen.",
            "Can you quote the bathroom job?",
            "The open quote for the deck is still pending.",
            // Idiom, nothing between.
            "It's quote unquote fine.",
            // A closer after an article is a noun.
            "Quote the job, the end quote was too high.",
            // An opener with its closer on another line.
            "open quote first\nsecond close quote",
            "quotes, quoted, unquoted",
            "",
        ], by: { SpokenQuotes.apply(to: $0, style: .curly) })
    }

    // MARK: - Spoken symbols

    func testSymbolsJoinTheirWords() {
        XCTAssertEqual(SpokenSymbols.apply(to: "hashtag release"), "#release")
        XCTAssertEqual(SpokenSymbols.apply(to: "Tag it hashtag release please."), "Tag it #release please.")
        XCTAssertEqual(SpokenSymbols.apply(to: "use hash tag launch"), "use #launch")
        XCTAssertEqual(SpokenSymbols.apply(to: "my underscore variable"), "my_variable")
        XCTAssertEqual(SpokenSymbols.apply(to: "my underscore big underscore variable"), "my_big_variable")
        XCTAssertEqual(SpokenSymbols.apply(to: "rename user id to user underscore id"), "rename user id to user_id")
        XCTAssertEqual(SpokenSymbols.apply(to: "git push dash dash force"), "git push --force")
        XCTAssertEqual(SpokenSymbols.apply(to: "run it with double dash verbose"), "run it with --verbose")
        XCTAssertEqual(SpokenSymbols.apply(to: "ping at sign maya"), "ping @maya")
        XCTAssertEqual(SpokenSymbols.apply(to: "Hashtag Launch day"), "#Launch day")
    }

    func testSymbolNamesUsedAsWordsStay() {
        assertUnchanged([
            // The rule: a symbol joins only a content word after spaces,
            // never after an article, demonstrative or quantifier.
            "The hashtag is trending.",
            "Our hashtag game is weak.",
            "Your hashtag release went out.",
            "Add an underscore between the words.",
            "The underscore key is broken.",
            "underscore the point",
            "Type one at sign and a dash dash.",
            "hashtag and mention",
            // Punctuation between: a sentence boundary, not a join.
            "Use the hashtag. Release is Friday.",
            "Hashtag, release.",
            // Whole words only.
            "hashtags, underscored, dashes",
            // Left out on purpose: comma, slash, hyphen.
            "put a comma here and use slash commands with a hyphen",
            "",
        ], by: SpokenSymbols.apply)
    }

    // MARK: - All together

    func testFixesComposeInOrder() {
        let options = TextFixOptions()
        XCTAssertEqual(TextFixes.apply("Um, tag it hashtag uh release.", options: options), "Tag it #release.")
        XCTAssertEqual(
            TextFixes.apply("uh he said quote dash dash force is fine end quote", options: options),
            "he said \u{201C}--force is fine\u{201D}"
        )
    }

    func testEachFixCanBeTurnedOff() {
        let text = "Um, he said quote hashtag release end quote."
        XCTAssertEqual(TextFixes.apply(text, options: .allOff), text)
        var fillersOnly = TextFixOptions.allOff
        fillersOnly.removeFillers = true
        XCTAssertEqual(TextFixes.apply(text, options: fillersOnly), "He said quote hashtag release end quote.")
        var quotesOnly = TextFixOptions.allOff
        quotesOnly.spokenQuotes = true
        XCTAssertEqual(TextFixes.apply(text, options: quotesOnly), "Um, he said \u{201C}hashtag release\u{201D}.")
        var symbolsOnly = TextFixOptions.allOff
        symbolsOnly.spokenSymbols = true
        XCTAssertEqual(TextFixes.apply(text, options: symbolsOnly), "Um, he said quote #release end quote.")
    }

    func testDefaultsAreAllOn() {
        let options = TextFixOptions()
        XCTAssertTrue(options.removeFillers && options.spokenSymbols && options.spokenQuotes)
        XCTAssertEqual(options.quoteStyle, .curly)
    }

    func testFixesAreIdempotent() {
        let options = TextFixOptions()
        for text in [
            "Um, so, uh, tag it hashtag release and say open quote ship it close quote.",
            "my underscore variable and git push dash dash force",
            "He said, quote, um, I'll be there, end quote.",
            "这个um很重要 hashtag 发布",
            "Plain text.",
        ] {
            let once = TextFixes.apply(text, options: options)
            XCTAssertEqual(TextFixes.apply(once, options: options), once, "Applying twice changes nothing more: \(text)")
        }
    }

    // MARK: - Smart spacing

    func testSmartSpacingAddsOneSpaceAfterAWordOrSentence() {
        XCTAssertEqual(SmartSpacing.adjusted("how are you", before: .character("o")), " how are you")
        XCTAssertEqual(SmartSpacing.adjusted("How are you?", before: .character(".")), " How are you?")
        XCTAssertEqual(SmartSpacing.adjusted("and then", before: .character("7")), " and then")
        XCTAssertEqual(SmartSpacing.adjusted("\u{201C}quoted\u{201D}", before: .character(",")), " \u{201C}quoted\u{201D}")
        XCTAssertEqual(SmartSpacing.adjusted("#release", before: .character("t")), " #release")
    }

    func testSmartSpacingNeverAddsASpaceWhereNoneBelongs() {
        let text = "hello"
        XCTAssertEqual(SmartSpacing.adjusted(text, before: .fieldStart), text, "Start of the field")
        XCTAssertEqual(SmartSpacing.adjusted(text, before: .unknown), text, "Unreadable field: unchanged")
        for previous: Character in [" ", "\n", "\t", "(", "[", "{", "\u{201C}", "\"", "'", "-", "/", "@", "#"] {
            XCTAssertEqual(SmartSpacing.adjusted(text, before: .character(previous)), text, "After \(previous.debugDescription)")
        }
        XCTAssertEqual(SmartSpacing.adjusted(", then", before: .character("o")), ", then", "Text starting with punctuation")
        XCTAssertEqual(SmartSpacing.adjusted(" hello", before: .character("o")), " hello", "Already spaced")
        XCTAssertEqual(SmartSpacing.adjusted("", before: .character("o")), "")
        XCTAssertEqual(SmartSpacing.adjusted("世界", before: .character("o")), "世界", "CJK text")
        XCTAssertEqual(SmartSpacing.adjusted("hello", before: .character("好")), "hello", "After CJK")
    }

    func testSmartSpacingSkipsTerminals() {
        XCTAssertTrue(SmartSpacing.excludedBundleIDs.contains("com.apple.Terminal"))
        XCTAssertTrue(SmartSpacing.excludedBundleIDs.contains("com.mitchellh.ghostty"))
    }
}

/// The text fixes inside the pipeline: before cleanup when it is on, on
/// their own when it is off.
@MainActor
final class TextFixesPipelineTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-text-fixes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makePipeline(llm: RecordingLLM) -> DictationPipeline {
        let client = ProviderHTTPClient(requestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json")))
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.llmProviderOverride = { _ in llm }
        return pipeline
    }

    private static let raw = "Um, tag it hashtag release and he said quote ship it end quote."

    func testCleanupOffPastesTheFixedTranscript() async {
        let llm = RecordingLLM(reply: "unused")
        let pipeline = makePipeline(llm: llm)
        pipeline.cleanupEnabled = false

        let decided = await pipeline.decideText(forRaw: Self.raw, styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(decided?.text, "Tag it #release and he said \u{201C}ship it\u{201D}.")
        XCTAssertEqual(decided?.cleanupOff, true)
        XCTAssertEqual(llm.calls, 0)
    }

    func testCleanupOnSendsTheFixedTranscriptToTheModel() async {
        let llm = RecordingLLM(reply: "Tag it #release and he said \u{201C}ship it\u{201D}.")
        let pipeline = makePipeline(llm: llm)

        _ = await pipeline.decideText(forRaw: Self.raw, styleChoice: nil, updatesPhase: false)
        let message = llm.lastUserMessage ?? ""
        XCTAssertTrue(message.contains("Tag it #release and he said \u{201C}ship it\u{201D}."), message)
        XCTAssertFalse(message.contains("hashtag"))
        XCTAssertFalse(message.contains("Um,"))
    }

    func testCleanupFailureFallsBackToTheFixedTranscript() async {
        let pipeline = makePipeline(llm: RecordingLLM(reply: "", fails: true))
        let decided = await pipeline.decideText(forRaw: Self.raw, styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(decided?.text, "Tag it #release and he said \u{201C}ship it\u{201D}.")
        XCTAssertEqual(decided?.rawFallbackReason, .cleanupUnavailable)
    }

    func testCodeAppsGetStraightQuotes() async {
        let pipeline = makePipeline(llm: RecordingLLM(reply: "unused"))
        pipeline.cleanupEnabled = false
        let decided = await pipeline.decideText(
            forRaw: "set it to open quote hello close quote",
            styleChoice: nil,
            appBundleID: "com.apple.dt.Xcode",
            updatesPhase: false
        )
        XCTAssertEqual(decided?.text, "set it to \"hello\"")
        XCTAssertEqual(pipeline.textFixOptions(for: "com.apple.mail").quoteStyle, .curly)
        XCTAssertEqual(pipeline.textFixOptions(for: nil).quoteStyle, .curly)
    }

    func testSwitchedOffFixesLeaveTheTranscript() async {
        let pipeline = makePipeline(llm: RecordingLLM(reply: "unused"))
        pipeline.cleanupEnabled = false
        pipeline.textFixOptions = .allOff
        let decided = await pipeline.decideText(forRaw: Self.raw, styleChoice: nil, updatesPhase: false)
        XCTAssertEqual(decided?.text, Self.raw)
    }

    func testFillerOnlyDictationIsDismissed() async {
        let pipeline = makePipeline(llm: RecordingLLM(reply: "unused"))
        pipeline.cleanupEnabled = false
        let decided = await pipeline.decideText(forRaw: "Um.", styleChoice: nil, updatesPhase: false)
        XCTAssertNil(decided)
    }
}

private final class RecordingLLM: LLMProvider, @unchecked Sendable {
    static let providerID: LLMProviderID = .anthropic

    private let reply: String
    private let fails: Bool
    private(set) var calls = 0
    private(set) var lastUserMessage: String?

    init(reply: String, fails: Bool = false) {
        self.reply = reply
        self.fails = fails
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        calls += 1
        lastUserMessage = request.userMessage
        if fails { throw URLError(.badServerResponse) }
        return LLMResponse(text: reply, model: "fake-cleanup-model", promptTokens: nil, completionTokens: nil)
    }
}

/// "um" and "er" are words in German, Dutch and the Scandinavian languages.
final class FillerLanguageTests: XCTestCase {
    func testGermanAndScandinavianDictationsKeepUmAndEr() {
        var options = TextFixOptions()
        XCTAssertEqual(TextFixes.apply("wir treffen uns um drei", options: options), "wir treffen uns um drei")
        XCTAssertEqual(TextFixes.apply("Er sagt, er kommt um zehn.", options: options), "Er sagt, er kommt um zehn.")
        XCTAssertEqual(TextFixes.apply("Det er godt, hmm.", options: options), "Det er godt.", "Only the universal fillers go")
        options.spokenLanguages = ["en-US", "de-DE"]
        XCTAssertEqual(TextFixes.apply("wir treffen uns um drei", options: options), "wir treffen uns um drei")
        XCTAssertEqual(TextFixes.apply("um I think er we should go", options: options), "I think we should go",
                       "An English dictation from a German speaker still loses them")
    }

    func testUsersWhoSpeakNoneOfThoseLanguagesAlwaysLoseThem() {
        var options = TextFixOptions()
        options.spokenLanguages = ["en-AU", "es-MX"]
        XCTAssertFalse(FillerWords.umAndErAreWords(in: "wir treffen uns um drei", languages: options.spokenLanguages))
        XCTAssertEqual(TextFixes.apply("Hola, um, ¿qué tal?", options: options), "Hola, ¿qué tal?")
    }

    func testAutoDetectReadsEnglishAsEnglish() {
        XCTAssertFalse(FillerWords.umAndErAreWords(in: "um I kinda think we should uh leave it for now", languages: []))
        XCTAssertFalse(FillerWords.umAndErAreWords(in: "I think er we should go", languages: []))
    }
}

final class SpokenFlagTests: XCTestCase {
    func testDashJoinsOnlyInsideAFlag() {
        XCTAssertEqual(SpokenSymbols.apply(to: "npm install dash dash save dash dev typescript"), "npm install --save-dev typescript")
        XCTAssertEqual(SpokenSymbols.apply(to: "a dash of salt"), "a dash of salt")
        XCTAssertEqual(SpokenSymbols.apply(to: "add salt dash pepper"), "add salt dash pepper")
    }
}
