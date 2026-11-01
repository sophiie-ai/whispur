import XCTest
@testable import Whispur

final class CleanupTransportTests: XCTestCase {
    private let request = LLMRequest(systemPrompt: "system", userMessage: "user", maxTokens: 1500)

    private func json(_ string: String) -> Data { Data(string.utf8) }

    // MARK: - Default models

    func testDefaultModelsAreCurrent() {
        XCTAssertEqual(LLMProviderID.anthropic.defaultModel, "claude-haiku-5-5")
        XCTAssertEqual(LLMProviderID.bedrock.defaultModel, "anthropic.claude-haiku-5-5")
        XCTAssertEqual(LLMProviderID.openai.defaultModel, "gpt-6-luna")
        XCTAssertEqual(LLMProviderID.groq.defaultModel, "openai/gpt-oss-20b")
    }

    // MARK: - Anthropic / Bedrock responses

    private let thinkingThenText = """
    {"content":[{"type":"thinking","thinking":"","signature":"abc"},
                {"type":"text","text":"  Hello, world.  "}],
     "stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":5}}
    """

    func testAnthropicParsePicksFirstTextBlockAfterThinking() throws {
        let response = try AnthropicMessagesFormat.parse(json(thinkingThenText), provider: .anthropic, model: "m")
        XCTAssertEqual(response.text, "Hello, world.")
        XCTAssertEqual(response.promptTokens, 12)
        XCTAssertEqual(response.completionTokens, 5)
    }

    func testBedrockParsePicksFirstTextBlockAfterThinking() throws {
        let bedrockBody = """
        {"id":"msg_bdrk_1","type":"message","role":"assistant","model":"claude-haiku-5-5",
         "content":[{"type":"thinking","thinking":"","signature":"sig"},
                    {"type":"text","text":"Ship it on Friday."}],
         "stop_reason":"end_turn","usage":{"input_tokens":30,"output_tokens":6}}
        """
        let response = try AnthropicMessagesFormat.parse(json(bedrockBody), provider: .bedrock, model: "anthropic.claude-haiku-5-5")
        XCTAssertEqual(response.text, "Ship it on Friday.")
        XCTAssertEqual(response.model, "anthropic.claude-haiku-5-5")
    }

    func testAnthropicParseThrowsOnTruncationAndRefusal() {
        let truncated = #"{"content":[{"type":"text","text":"Half a sen"}],"stop_reason":"max_tokens"}"#
        XCTAssertThrowsError(try AnthropicMessagesFormat.parse(json(truncated), provider: .anthropic, model: "m")) { error in
            guard case .truncated(.anthropic) = error as? LLMError else { return XCTFail("\(error)") }
        }
        let refused = #"{"content":[],"stop_reason":"refusal"}"#
        XCTAssertThrowsError(try AnthropicMessagesFormat.parse(json(refused), provider: .bedrock, model: "m")) { error in
            guard case .refused(.bedrock) = error as? LLMError else { return XCTFail("\(error)") }
        }
    }

    func testAnthropicParseDistinguishesMalformedFromEmpty() throws {
        XCTAssertThrowsError(try AnthropicMessagesFormat.parse(json(#"{"error":"x"}"#), provider: .anthropic, model: "m")) { error in
            guard case .emptyResponse = error as? LLMError else { return XCTFail("\(error)") }
        }
        let empty = #"{"content":[{"type":"thinking","thinking":""}],"stop_reason":"end_turn"}"#
        XCTAssertEqual(try AnthropicMessagesFormat.parse(json(empty), provider: .anthropic, model: "m").text, "")
    }

    // MARK: - Anthropic / Bedrock request bodies

    func testHaiku55BodyDisablesThinkingAtLowEffortWithoutTemperature() {
        let body = AnthropicMessagesFormat.body(model: "claude-haiku-5-5", request: request)
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["model"])
        XCTAssertEqual(body["max_tokens"] as? Int, 1500)
        XCTAssertEqual(body["system"] as? String, "system")
    }

    func testBedrockBodyAddsAnthropicVersionToSharedBody() {
        let body = BedrockLLM.body(modelID: "anthropic.claude-haiku-5-5", request: request)
        XCTAssertEqual(body["anthropic_version"] as? String, "bedrock-2023-05-31")
        XCTAssertEqual(body["thinking"] as? [String: String], ["type": "disabled"])
        XCTAssertEqual(body["output_config"] as? [String: String], ["effort": "low"])
        XCTAssertNil(body["temperature"])
        XCTAssertNil(body["model"])
    }

    func testOlderClaudeCustomModelsKeepTemperatureZeroAndSkipEffort() {
        for model in ["claude-haiku-4-5", "anthropic.claude-sonnet-4-20250514-v1:0", "claude-3-5-sonnet-20241022"] {
            let body = AnthropicMessagesFormat.body(model: model, request: request)
            XCTAssertEqual(body["temperature"] as? Double, 0, model)
            XCTAssertNil(body["output_config"], model)
            XCTAssertNil(body["thinking"], model)
        }
    }

    func testNewerClaudeCustomModelsUseTheirThinkingOffSwitch() {
        XCTAssertEqual(
            AnthropicMessagesFormat.ModelProfile(model: "claude-sonnet-5-5"),
            .init(thinking: .betweenTools, effort: "low", acceptsTemperature: false)
        )
        XCTAssertEqual(
            AnthropicMessagesFormat.ModelProfile(model: "claude-opus-5-5"),
            .init(thinking: .omit, effort: "low", acceptsTemperature: false)
        )
        XCTAssertEqual(
            AnthropicMessagesFormat.ModelProfile(model: "us.anthropic.claude-opus-4-6-v1"),
            .init(thinking: .omit, effort: "low", acceptsTemperature: true)
        )
        XCTAssertEqual(
            AnthropicMessagesFormat.ModelProfile(model: "claude-fable-5-1"),
            .init(thinking: .omit, effort: "low", acceptsTemperature: false)
        )
    }

    // MARK: - OpenAI / Groq request bodies

    func testGpt6LunaTurnsReasoningOffAndSendsTemperatureZero() {
        let body = OpenAIChatFormat.body(model: "gpt-6-luna", providerID: .openai, request: request)
        XCTAssertEqual(body["reasoning_effort"] as? String, "none")
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1500)
        XCTAssertNil(body["max_tokens"])
    }

    func testOlderOpenAIChatModelsKeepClassicParameters() {
        for model in ["gpt-4o-mini", "gpt-4.1", "llama3.1:8b"] {
            let body = OpenAIChatFormat.body(model: model, providerID: .openai, request: request)
            XCTAssertEqual(body["max_tokens"] as? Int, 1500, model)
            XCTAssertEqual(body["temperature"] as? Double, 0, model)
            XCTAssertNil(body["reasoning_effort"], model)
            XCTAssertNil(body["max_completion_tokens"], model)
        }
    }

    func testAlwaysReasoningOpenAIModelsDropTemperature() {
        let body = OpenAIChatFormat.body(model: "o3-mini", providerID: .openai, request: request)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1500)
    }

    func testGroqGptOSSHidesReasoningAtLowEffort() {
        let body = OpenAIChatFormat.body(model: "openai/gpt-oss-20b", providerID: .groq, request: request)
        XCTAssertEqual(body["reasoning_effort"] as? String, "low")
        XCTAssertEqual(body["include_reasoning"] as? Bool, false)
        XCTAssertEqual(body["temperature"] as? Double, 0)
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 1500)
        XCTAssertNil(body["reasoning_format"])

        let llama = OpenAIChatFormat.body(model: "llama-3.1-8b-instant", providerID: .groq, request: request)
        XCTAssertNil(llama["include_reasoning"])
        XCTAssertEqual(llama["max_tokens"] as? Int, 1500)
    }

    // MARK: - OpenAI / Groq responses

    func testOpenAIParseTruncationAndThinkStripping() throws {
        let truncated = #"{"choices":[{"message":{"content":"Half"},"finish_reason":"length"}]}"#
        XCTAssertThrowsError(try OpenAIChatFormat.parse(json(truncated), provider: .groq, model: "m")) { error in
            guard case .truncated(.groq) = error as? LLMError else { return XCTFail("\(error)") }
        }

        let leaked = #"{"choices":[{"message":{"content":"<think>user wants cleanup</think>\nSee you at noon."},"finish_reason":"stop"}],"usage":{"prompt_tokens":9,"completion_tokens":4}}"#
        let response = try OpenAIChatFormat.parse(json(leaked), provider: .groq, model: "m")
        XCTAssertEqual(response.text, "See you at noon.")
        XCTAssertEqual(response.promptTokens, 9)
    }

    // MARK: - <think> stripping

    func testStripReasoningRemovesClosedAndUnclosedBlocks() {
        XCTAssertEqual(LLMOutputSanitizer.stripReasoning("<think>\nplan\nmore\n</think>\n\nFinal text."), "Final text.")
        XCTAssertEqual(LLMOutputSanitizer.stripReasoning("<THINKING>x</THINKING>Answer"), "Answer")
        XCTAssertEqual(LLMOutputSanitizer.stripReasoning("<think>never closed because it was cut off"), "")
        XCTAssertEqual(LLMOutputSanitizer.stripReasoning("  Plain text, no tags.  "), "Plain text, no tags.")
    }

    // MARK: - Final paste decision

    func testEmptyCleanupOfRealSpeechPastesRaw() {
        let raw = "can you send me the report by friday"
        for cleaned in ["", "   ", "EMPTY", "empty", "Thanks for watching!"] {
            XCTAssertEqual(
                TranscriptDecision.finalOutcome(raw: raw, cleaned: cleaned),
                .paste(raw, rawFallbackReason: .cleanupEmpty),
                "cleaned: \(cleaned)"
            )
        }
    }

    func testCleanupUsedWhenItHasText() {
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: "um send it friday", cleaned: " Send it Friday. "),
            .paste("Send it Friday.", rawFallbackReason: nil)
        )
    }

    func testFailedCleanupPastesRaw() {
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: "send it friday", cleaned: nil),
            .paste("send it friday", rawFallbackReason: .cleanupUnavailable)
        )
    }

    func testAssistantReplyFallsBackToRaw() {
        let raw = "what's the best way to cache this"
        let cleaned = "The best way to cache this is to add a TTL layer in front of the database calls."
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: raw, cleaned: cleaned),
            .paste(raw, rawFallbackReason: .assistantReply)
        )
    }

    func testNonSpeechRawTranscriptIsDismissed() {
        for raw in ["", "EMPTY", "[BLANK_AUDIO]", "(music playing)", "[phone ringing] [clicking]", "Thanks for watching!", "♪♪"] {
            XCTAssertNil(TranscriptDecision.normalizedRawTranscript(raw), raw)
            XCTAssertEqual(TranscriptDecision.finalOutcome(raw: raw, cleaned: "anything"), .dismiss, raw)
        }
    }

    func testShortRealRepliesSurvive() {
        for reply in ["thanks", "Thank you.", "Bye!", "goodbye", "Thank you so much"] {
            XCTAssertEqual(TranscriptDecision.normalizedRawTranscript(reply), reply, reply)
        }
        // "thanks" is too short to clean, so it reaches the paste step raw.
        XCTAssertFalse(TranscriptDecision.shouldRunCleanup(for: "thanks"))
        XCTAssertEqual(
            TranscriptDecision.finalOutcome(raw: "thanks", cleaned: nil),
            .paste("thanks", rawFallbackReason: .cleanupUnavailable)
        )
    }

    func testMixedAnnotationAndSpeechIsKept() {
        XCTAssertEqual(TranscriptDecision.normalizedRawTranscript("[clicking] okay ship it"), "[clicking] okay ship it")
    }

    // MARK: - Output budget

    func testCleanupMaxTokensScalesWithInput() {
        XCTAssertEqual(LLMRequest.cleanupMaxTokens(forTranscriptCharacters: 20), 1024)
        XCTAssertEqual(LLMRequest.cleanupMaxTokens(forTranscriptCharacters: 6000), 3512)
        XCTAssertEqual(LLMRequest.cleanupMaxTokens(forTranscriptCharacters: 100_000), 8192)
    }
}
