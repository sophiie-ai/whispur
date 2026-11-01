import XCTest
@testable import Whispur

final class STTProviderTests: XCTestCase {

    // MARK: - OpenAI request shape

    func testGPTTranscribeSendsKeywordsAndLanguages() {
        let fields = OpenAISTT.formFields(
            model: "gpt-transcribe",
            language: .single(code: "fr-FR"),
            vocabulary: ["Whispur", "  Kubernetes ", ""]
        )
        XCTAssertEqual(fields, [
            MultipartFormField(name: "model", value: "gpt-transcribe"),
            MultipartFormField(name: "languages[]", value: "fr"),
            MultipartFormField(name: "keywords[]", value: "Whispur"),
            MultipartFormField(name: "keywords[]", value: "Kubernetes"),
        ])
        XCTAssertFalse(fields.contains { $0.name == "language" || $0.name == "prompt" || $0.name == "response_format" })
    }

    func testGPTTranscribeAutoLanguageSendsNoLanguageHint() {
        let fields = OpenAISTT.formFields(model: "gpt-transcribe", language: .auto, vocabulary: [])
        XCTAssertEqual(fields, [MultipartFormField(name: "model", value: "gpt-transcribe")])
    }

    func testOlderModelsKeepLanguageAndPrompt() {
        for model in ["whisper-1", "gpt-4o-transcribe", "my-gateway-model"] {
            let fields = OpenAISTT.formFields(model: model, language: .single(code: "en-US"), vocabulary: ["Whispur", "Sophiie"])
            XCTAssertEqual(fields, [
                MultipartFormField(name: "model", value: model),
                MultipartFormField(name: "language", value: "en"),
                MultipartFormField(name: "prompt", value: "Whispur, Sophiie"),
            ], model)
        }
    }

    func testKeywordsDropCharactersThatFailTheRequest() {
        let keywords = OpenAISTT.keywords(from: ["<b>Acme</b>", "two\nlines", "\r\n"] + (0 ..< 80).map { "term\($0)" })
        XCTAssertEqual(keywords.first, "bAcme/b")
        XCTAssertEqual(keywords[1], "twolines")
        XCTAssertEqual(keywords.count, OpenAISTT.maxKeywords)
        XCTAssertFalse(keywords.contains { $0.contains("<") || $0.contains(">") || $0.contains("\n") })
    }

    func testOpenAITranscriptParsesJSONAndPlainText() {
        XCTAssertEqual(OpenAISTT.parseTranscript(Data(#"{"text":" Hello there. ","languages":["en"]}"#.utf8)), "Hello there.")
        XCTAssertEqual(OpenAISTT.parseTranscript(Data(" plain body \n".utf8)), "plain body")
        XCTAssertEqual(OpenAISTT.parseTranscript(Data(#"{"usage":{}}"#.utf8)), "")
    }

    // MARK: - Models

    func testSpeechModelDefaults() {
        XCTAssertEqual(STTProviderID.openai.defaultModel, "gpt-transcribe")
        XCTAssertEqual(STTProviderID.groqWhisper.defaultModel, "whisper-large-v3")
        XCTAssertTrue(STTProviderID.groqWhisper.modelOptions.contains { $0.id == "whisper-large-v3-turbo" })
        XCTAssertTrue(STTProviderID.openai.modelOptions.contains { $0.id == "whisper-1" })
        XCTAssertEqual(STTProviderID.openai.modelStorageKey, "openaiSTTModel", "Existing custom models must keep working")
        XCTAssertEqual(STTProviderID.openai.displayName, "OpenAI")
    }

    func testSpeechModelStorageKeysAreUnique() {
        let keys = STTProviderID.allCases.compactMap(\.modelStorageKey)
        XCTAssertEqual(keys.count, Set(keys).count)
        for provider in STTProviderID.allCases {
            XCTAssertEqual(provider.modelStorageKey == nil, provider.modelOptions.isEmpty, provider.rawValue)
        }
    }

    func testSpeechModelResolutionFollowsTheDefaultUntilChosen() {
        let defaults = UserDefaults.standard
        for provider in STTProviderID.allCases {
            guard let key = provider.modelStorageKey else {
                XCTAssertNil(ProviderRegistry.sttModel(for: provider))
                continue
            }
            let saved = defaults.object(forKey: key)
            defer { defaults.set(saved, forKey: key) }

            defaults.removeObject(forKey: key)
            XCTAssertEqual(ProviderRegistry.sttModel(for: provider), provider.defaultModel)
            defaults.set("   ", forKey: key)
            XCTAssertEqual(ProviderRegistry.sttModel(for: provider), provider.defaultModel)
            defaults.set(" whisper-1 ", forKey: key)
            XCTAssertEqual(ProviderRegistry.sttModel(for: provider), "whisper-1")
        }
    }

    func testModelPickerIsOnlyOfferedWithChoices() {
        XCTAssertEqual(STTProviderID.openai.setupDescriptor.modelPicker?.defaultModel, "gpt-transcribe")
        XCTAssertEqual(STTProviderID.groqWhisper.setupDescriptor.modelPicker?.storageKey, "groqWhisperSTTModel")
        XCTAssertNil(STTProviderID.apple.setupDescriptor.modelPicker)
        XCTAssertNil(STTProviderID.deepgram.setupDescriptor.modelPicker)
    }
}
