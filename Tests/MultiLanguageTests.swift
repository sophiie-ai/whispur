import XCTest
@testable import Whispur

/// A speech provider that answers from a table keyed by the forced language
/// ("" = auto), and records every call.
final class FakeSTT: STTProvider, @unchecked Sendable {
    static let providerID: STTProviderID = .groqWhisper

    var answers: [String: Result<ScoredTranscript, Error>] = [:]
    private let lock = NSLock()
    private var _calls: [STTLanguageSelection] = []
    var calls: [STTLanguageSelection] { lock.withLock { _calls } }

    private func answer(for language: STTLanguageSelection) throws -> ScoredTranscript {
        lock.withLock { _calls.append(language) }
        let key = language.singleISOCode ?? ""
        guard let result = answers[key] else { throw STTError.noAudioFile }
        return try result.get()
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        try answer(for: language).text
    }

    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript {
        try answer(for: language)
    }
}

final class LanguageMigrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "ai.sophiie.whispur.tests.languages"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private var migrated: String? {
        AppState.migrateSpokenLanguagesIfNeeded(defaults: defaults)
        return defaults.string(forKey: AppState.spokenLanguagesKey)
    }

    func testOneLanguageBecomesThatSet() {
        defaults.set("es-MX", forKey: AppState.singleLanguageKey)
        XCTAssertEqual(migrated, "es-MX")
        XCTAssertEqual(defaults.string(forKey: AppState.singleLanguageKey), "es-MX", "Old key stays for an older build")
    }

    func testAutoBecomesEmpty() {
        defaults.set("", forKey: AppState.singleLanguageKey)
        XCTAssertEqual(migrated, "")
        XCTAssertTrue(STTLanguageSelection(storageValue: migrated ?? "x").isAuto)
    }

    func testNothingStoredStaysUnset() {
        XCTAssertNil(migrated)
    }

    func testOriginalListKeepsEveryLanguage() {
        defaults.set("en-US, es-ES ,fr-FR", forKey: AppState.legacyLanguagesKey)
        XCTAssertEqual(migrated, "en-US,es-ES,fr-FR")
        XCTAssertNil(defaults.object(forKey: AppState.legacyLanguagesKey))
    }

    func testExistingSetIsNeverOverwritten() {
        defaults.set("en-US,es-ES", forKey: AppState.spokenLanguagesKey)
        defaults.set("ja-JP", forKey: AppState.singleLanguageKey)
        XCTAssertEqual(migrated, "en-US,es-ES")
        XCTAssertEqual(migrated, "en-US,es-ES", "Running twice changes nothing")
    }
}

final class LanguageRequestParameterTests: XCTestCase {
    private let none = STTLanguageSelection.auto
    private let one = STTLanguageSelection(codes: ["es-MX"])
    private let two = STTLanguageSelection(codes: ["en-US", "es-MX"])

    private func values(_ fields: [MultipartFormField], _ name: String) -> [String] {
        fields.filter { $0.name == name }.map(\.value)
    }

    func testGPTTranscribeSendsEveryLanguage() {
        XCTAssertEqual(values(OpenAISTT.formFields(model: "gpt-transcribe", language: none, vocabulary: []), "languages[]"), [])
        XCTAssertEqual(values(OpenAISTT.formFields(model: "gpt-transcribe", language: one, vocabulary: []), "languages[]"), ["es"])
        let fields = OpenAISTT.formFields(model: "gpt-transcribe", language: two, vocabulary: [])
        XCTAssertEqual(values(fields, "languages[]"), ["en", "es"])
        XCTAssertTrue(values(fields, "language").isEmpty, "gpt-transcribe must not get both fields")
    }

    func testWhisperModelsSendOnlyASingleLanguage() {
        for model in ["whisper-1", "gpt-4o-transcribe"] {
            XCTAssertEqual(values(OpenAISTT.formFields(model: model, language: none, vocabulary: []), "language"), [], model)
            XCTAssertEqual(values(OpenAISTT.formFields(model: model, language: one, vocabulary: []), "language"), ["es"], model)
            XCTAssertEqual(values(OpenAISTT.formFields(model: model, language: two, vocabulary: []), "language"), [], model)
        }
        XCTAssertEqual(values(OpenAISTT.formFields(model: "whisper-1", language: one, vocabulary: [], verbose: true), "response_format"), ["verbose_json"])
        XCTAssertEqual(values(OpenAISTT.formFields(model: "gpt-transcribe", language: one, vocabulary: [], verbose: true), "response_format"), [])
    }

    func testGroqSendsOnlyASingleLanguageAndVerboseForGuardRuns() {
        XCTAssertEqual(values(GroqWhisperSTT.formFields(model: "whisper-large-v3", language: none, vocabulary: []), "language"), [])
        XCTAssertEqual(values(GroqWhisperSTT.formFields(model: "whisper-large-v3", language: one, vocabulary: []), "language"), ["es"])
        XCTAssertEqual(values(GroqWhisperSTT.formFields(model: "whisper-large-v3", language: two, vocabulary: []), "language"), [])
        XCTAssertEqual(values(GroqWhisperSTT.formFields(model: "whisper-large-v3", language: two, vocabulary: []), "response_format"), ["text"])
        XCTAssertEqual(values(GroqWhisperSTT.formFields(model: "whisper-large-v3", language: one, vocabulary: [], verbose: true), "response_format"), ["verbose_json"])
    }

    func testDeepgramUsesMultiWithHintsForSeveral() {
        func query(_ selection: STTLanguageSelection) -> [String] {
            DeepgramSTT.languageQueryItems(for: selection).map { "\($0.name)=\($0.value ?? "")" }
        }
        XCTAssertEqual(query(none), ["language=multi"])
        XCTAssertEqual(query(one), ["language=es-MX"])
        XCTAssertEqual(query(two), ["language=multi", "language_hint=en", "language_hint=es"])
        XCTAssertEqual(query(STTLanguageSelection(codes: ["en-US", "en-GB"])), ["language=en-US"])
    }

    func testMistralSendsOnlyASingleLanguage() {
        XCTAssertEqual(values(MistralSTT.formFields(model: "m", language: none, vocabulary: []), "language"), [])
        XCTAssertEqual(values(MistralSTT.formFields(model: "m", language: one, vocabulary: []), "language"), ["es"])
        XCTAssertEqual(values(MistralSTT.formFields(model: "m", language: two, vocabulary: []), "language"), [])
    }

    func testElevenLabsRealtimeSendsOnlyASingleLanguage() throws {
        func codes(_ selection: STTLanguageSelection) throws -> [String] {
            let url = try XCTUnwrap(ElevenLabsRealtimeFormat.url(language: selection, vocabulary: []))
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return items.filter { $0.name == "language_code" }.compactMap(\.value)
        }
        XCTAssertEqual(try codes(none), [])
        XCTAssertEqual(try codes(one), ["es"])
        XCTAssertEqual(try codes(two), [])
    }

    func testMetaMuseBiasesTowardEveryLanguage() {
        XCTAssertNil(MetaMuseSTT.biasing(language: none, vocabulary: [])["languageBias"])
        XCTAssertEqual(MetaMuseSTT.biasing(language: one, vocabulary: [])["languageBias"] as? [String], ["Spanish"])
        XCTAssertEqual(MetaMuseSTT.biasing(language: two, vocabulary: [])["languageBias"] as? [String], ["English", "Spanish"])
    }

    func testWhisperVerboseConfidenceIsDurationWeighted() {
        let body = #"{"text":" Hola qué tal ","segments":[{"start":0,"end":1,"avg_logprob":-0.2},{"start":1,"end":4,"avg_logprob":-0.6}]}"#
        let scored = WhisperVerboseTranscript.parse(Data(body.utf8))
        XCTAssertEqual(scored.text, "Hola qué tal")
        XCTAssertEqual(scored.confidence ?? 0, -0.5, accuracy: 0.0001)
        XCTAssertNil(WhisperVerboseTranscript.parse(Data(#"{"text":"hi","segments":[]}"#.utf8)).confidence)
        XCTAssertEqual(WhisperVerboseTranscript.parse(Data("plain".utf8)).text, "plain")
    }
}

final class ScriptGuardTests: XCTestCase {
    private let englishSpanish = STTLanguageSelection(codes: ["en-US", "es-ES"])

    func testScriptTable() {
        XCTAssertEqual(WritingScript.of("a"), .latin)
        XCTAssertEqual(WritingScript.of("ñ"), .latin)
        XCTAssertEqual(WritingScript.of("ж"), .cyrillic)
        XCTAssertEqual(WritingScript.of("ل"), .arabic)
        XCTAssertEqual(WritingScript.of("ש"), .hebrew)
        XCTAssertEqual(WritingScript.of("क"), .devanagari)
        XCTAssertEqual(WritingScript.of("ก"), .thai)
        XCTAssertEqual(WritingScript.of("한"), .hangul)
        XCTAssertEqual(WritingScript.of("日"), .han)
        XCTAssertEqual(WritingScript.of("か"), .kana)
        XCTAssertEqual(WritingScript.of("λ"), .greek)
        XCTAssertNil(WritingScript.of("7"))
        XCTAssertNil(WritingScript.of("?"))
        XCTAssertNil(WritingScript.of(" "))
    }

    func testLanguageTable() {
        XCTAssertEqual(WritingScript.byLanguage["es"], [.latin])
        XCTAssertEqual(WritingScript.byLanguage["ru"], [.cyrillic])
        XCTAssertEqual(WritingScript.byLanguage["ja"], [.han, .kana])
        XCTAssertEqual(WritingScript.byLanguage["ko"], [.hangul, .han])
        XCTAssertEqual(WritingScript.byLanguage["ar"], [.arabic])
        for language in STTLanguageCatalog.all {
            XCTAssertNotNil(WritingScript.byLanguage[language.iso639_1], "Every catalog language needs a script: \(language.code)")
        }
    }

    func testArabicForASpanishSpeakerFails() throws {
        let check = try XCTUnwrap(ScriptGuard.check("أولاك تل", for: englishSpanish))
        XCTAssertTrue(check.fails)
        XCTAssertEqual(check.unexpectedScripts, [.arabic])
    }

    func testJapaneseForAnEnglishSpanishSpeakerFails() throws {
        XCTAssertTrue(try XCTUnwrap(ScriptGuard.check("こんにちは", for: englishSpanish)).fails)
    }

    func testLatinTextPasses() throws {
        XCTAssertFalse(try XCTUnwrap(ScriptGuard.check("Hola, ¿qué tal? Ship it Friday, 3:30.", for: englishSpanish)).fails)
    }

    func testOneStrayLetterInALongTranscriptIsTolerated() throws {
        let text = "We met at the café near the station and talked about the roadmap for an hour " + "日"
        XCTAssertFalse(try XCTUnwrap(ScriptGuard.check(text, for: englishSpanish)).fails)
        XCTAssertTrue(try XCTUnwrap(ScriptGuard.check("Hi 日本語です", for: englishSpanish)).fails)
    }

    func testNonLatinLanguagesAllowTheirScriptAndLatin() throws {
        let englishJapanese = STTLanguageSelection(codes: ["en-US", "ja-JP"])
        XCTAssertFalse(try XCTUnwrap(ScriptGuard.check("今日はiPhoneの話です", for: englishJapanese)).fails)
        XCTAssertTrue(try XCTUnwrap(ScriptGuard.check("Привет как дела", for: englishJapanese)).fails)
    }

    func testGuardOnlyAppliesToSeveralKnownLanguages() {
        XCTAssertNil(ScriptGuard.check("أولاك تل", for: .auto))
        XCTAssertNil(ScriptGuard.check("أولاك تل", for: .single(code: "es-ES")))
        XCTAssertNil(ScriptGuard.check("أولاك تل", for: STTLanguageSelection(codes: ["en-US", "en-GB"])))
        XCTAssertNil(ScriptGuard.check("أولاك تل", for: STTLanguageSelection(codes: ["en-US", "xx-XX"])), "Unknown language: can't judge")
    }
}

final class MultiLanguageTranscriptionTests: XCTestCase {
    private let englishSpanish = STTLanguageSelection(codes: ["en-US", "es-ES"])
    private let file = URL(fileURLWithPath: "/dev/null")

    private func run(_ fake: FakeSTT, _ language: STTLanguageSelection, initial: String? = nil) async throws -> (String, [MultiLanguageTranscription.GuardReport]) {
        var reports: [MultiLanguageTranscription.GuardReport] = []
        let text = try await MultiLanguageTranscription.transcribe(
            provider: fake, providerID: .groqWhisper, fileURL: file, language: language,
            vocabulary: [], initial: initial, onGuard: { reports.append($0) }
        )
        return (text, reports)
    }

    func testPassingTranscriptMakesOneRequest() async throws {
        let fake = FakeSTT()
        fake.answers[""] = .success(ScoredTranscript(text: "Hola qué tal", confidence: nil))
        let (text, reports) = try await run(fake, englishSpanish)
        XCTAssertEqual(text, "Hola qué tal")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(reports.isEmpty)
    }

    func testWrongScriptReRunsEachLanguageAndKeepsTheMostConfident() async throws {
        let fake = FakeSTT()
        fake.answers[""] = .success(ScoredTranscript(text: "أولاك تل", confidence: nil))
        fake.answers["en"] = .success(ScoredTranscript(text: "Hola, ke tal.", confidence: -0.9))
        fake.answers["es"] = .success(ScoredTranscript(text: "Hola, qué tal.", confidence: -0.2))
        let (text, reports) = try await run(fake, englishSpanish)
        XCTAssertEqual(text, "Hola, qué tal.")
        XCTAssertEqual(fake.calls.map { $0.singleISOCode ?? "" }.sorted(), ["", "en", "es"])
        XCTAssertEqual(reports.first?.chosenLanguage, "es")
        XCTAssertEqual(reports.first?.attempts.map(\.language), ["en", "es"])
        XCTAssertEqual(fake.calls.last.map { $0.codes.count }, 1, "Re-runs are forced to one language")
    }

    func testWithoutConfidencePrefersInScriptThenLongest() {
        let attempts: [MultiLanguageTranscription.GuardReport.Attempt] = [
            .init(language: "en", text: "Hola", confidence: nil, error: nil),
            .init(language: "es", text: "Hola qué tal", confidence: -0.1, error: nil),
            .init(language: "ja", text: "こんにちは、元気ですか", confidence: nil, error: nil),
        ]
        XCTAssertEqual(MultiLanguageTranscription.pick(attempts, for: englishSpanish)?.language, "es")
    }

    func testInScriptBeatsAMoreConfidentWrongScript() {
        let attempts: [MultiLanguageTranscription.GuardReport.Attempt] = [
            .init(language: "en", text: "أولاك", confidence: -0.01, error: nil),
            .init(language: "es", text: "Hola", confidence: -0.8, error: nil),
        ]
        XCTAssertEqual(MultiLanguageTranscription.pick(attempts, for: englishSpanish)?.language, "es")
    }

    func testFailedReRunsAreSkippedAndAllFailingKeepsTheOriginal() async throws {
        let fake = FakeSTT()
        fake.answers[""] = .success(ScoredTranscript(text: "أولاك تل", confidence: nil))
        fake.answers["es"] = .success(ScoredTranscript(text: "Hola qué tal", confidence: -0.4))
        var (text, reports) = try await run(fake, englishSpanish)
        XCTAssertEqual(text, "Hola qué tal")
        XCTAssertNotNil(reports.first?.attempts.first { $0.language == "en" }?.error)

        fake.answers["es"] = nil
        (text, reports) = try await run(fake, englishSpanish)
        XCTAssertEqual(text, "أولاك تل")
        XCTAssertNil(reports.first?.chosenLanguage)
    }

    func testRejectedStreamSkipsTheFirstRequest() async throws {
        let fake = FakeSTT()
        fake.answers["en"] = .success(ScoredTranscript(text: "Hello there", confidence: -0.3))
        fake.answers["es"] = .success(ScoredTranscript(text: "Jelou der", confidence: -1.2))
        let (text, _) = try await run(fake, englishSpanish, initial: "ハロー")
        XCTAssertEqual(text, "Hello there")
        XCTAssertFalse(fake.calls.contains { $0.isAuto })
        XCTAssertEqual(fake.calls.count, 2)
    }

    func testSingleLanguageNeverGuards() async throws {
        let fake = FakeSTT()
        fake.answers["es"] = .success(ScoredTranscript(text: "أولاك", confidence: nil))
        let (text, reports) = try await run(fake, .single(code: "es-ES"))
        XCTAssertEqual(text, "أولاك")
        XCTAssertEqual(fake.calls.count, 1)
        XCTAssertTrue(reports.isEmpty)
    }

    func testFirstRequestErrorsSurface() async {
        let fake = FakeSTT()
        do {
            _ = try await run(fake, englishSpanish)
            XCTFail("Expected the provider error")
        } catch {
            XCTAssertNotNil(error as? STTError)
        }
    }

    func testReRunsAreCapped() async throws {
        let fake = FakeSTT()
        let many = STTLanguageSelection(codes: ["en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR"])
        fake.answers[""] = .success(ScoredTranscript(text: "أولاك تل", confidence: nil))
        for code in ["en", "es", "fr", "de", "it", "pt"] {
            fake.answers[code] = .success(ScoredTranscript(text: "text \(code)", confidence: -0.5))
        }
        _ = try await run(fake, many)
        XCTAssertEqual(fake.calls.count, 1 + MultiLanguageTranscription.maxForcedRuns)
    }

    func testLogSummaryNamesTheScriptAndTheChoice() async throws {
        let fake = FakeSTT()
        fake.answers[""] = .success(ScoredTranscript(text: "أولاك تل", confidence: nil))
        fake.answers["es"] = .success(ScoredTranscript(text: "Hola qué tal", confidence: -0.4))
        let (_, reports) = try await run(fake, englishSpanish)
        let summary = MultiLanguageTranscription.logSummary(try XCTUnwrap(reports.first))
        XCTAssertTrue(summary.contains("arabic"))
        XCTAssertTrue(summary.contains("Kept: es"))
    }

    @MainActor
    func testRejectedStreamGoesToTheGuardedRetryWithItsText() async throws {
        let socket = FakeStreamSocket()
        socket.respond = { message, socket in
            if case let .text(body) = message, body.contains("\"commit\":true") {
                socket.push(.text(#"{"message_type":"committed_transcript","text":"أولاك تل"}"#))
            }
        }
        let session = STTStreamingSession(providerID: .elevenlabs, endpointDescription: "t", format: ElevenLabsRealtimeFormat(), socket: socket, chunkBytes: 8)
        session.start()
        session.append(Data(repeating: 1, count: 24))

        var retried: String?
        var outcomes: [StreamingFallback.Outcome] = []
        let text = try await StreamingFallback.transcript(
            stream: session,
            timeout: .seconds(2),
            report: { outcomes.append($0) },
            accept: { ScriptGuard.check($0, for: self.englishSpanish)?.fails == true ? "wrong script" : nil },
            retryRejected: { rejected in retried = rejected; return "Hola qué tal" },
            batch: { XCTFail("Plain batch should not run"); return "" }
        )
        XCTAssertEqual(text, "Hola qué tal")
        XCTAssertEqual(retried, "أولاك تل")
        XCTAssertEqual(outcomes.first?.error?.localizedDescription, "wrong script")
    }
}
