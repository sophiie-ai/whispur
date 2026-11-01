import Foundation

/// Identifies available LLM providers for post-processing.
enum LLMProviderID: String, Codable, CaseIterable, Identifiable {
    case openai
    case anthropic
    case groq
    case bedrock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openai: "OpenAI"
        case .anthropic: "Anthropic Claude"
        case .groq: "Groq"
        case .bedrock: "AWS Bedrock"
        }
    }

    var keychainKeys: [KeychainKey] {
        switch self {
        case .openai: [.openaiAPIKey]
        case .anthropic: [.anthropicAPIKey]
        case .groq: [.groqAPIKey]
        case .bedrock: [.awsBedrockAPIKey, .awsRegion]
        }
    }

    /// Model used when the user hasn't set a custom one in Settings.
    ///
    /// Only a typed custom model is ever persisted (`customModelStorageKey`);
    /// the default is never written to UserDefaults, so changing it here moves
    /// every user who didn't pick a model onto the new one.
    var defaultModel: String {
        switch self {
        case .openai: "gpt-6-luna"
        case .anthropic: "claude-haiku-5-5"
        case .groq: "openai/gpt-oss-20b"
        case .bedrock: "anthropic.claude-haiku-5-5"
        }
    }

    /// UserDefaults key for the optional custom model override.
    var customModelStorageKey: String { "\(rawValue)LLMModel" }
}

/// Input for an LLM completion request.
struct LLMRequest {
    let systemPrompt: String
    let userMessage: String
    let temperature: Double
    let maxTokens: Int

    init(
        systemPrompt: String,
        userMessage: String,
        temperature: Double = 0.0,
        maxTokens: Int = 2048
    ) {
        self.systemPrompt = systemPrompt
        self.userMessage = userMessage
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    /// Output budget for cleaning a transcript of `transcriptCharacters`
    /// characters. Cleanup output is roughly the size of its input (~4 chars
    /// per token), so this leaves 2x headroom plus room for any reasoning
    /// tokens the model spends, which count against the same limit on
    /// reasoning models. A response that still hits the cap is treated as
    /// truncated and the raw transcript is pasted instead.
    static func cleanupMaxTokens(forTranscriptCharacters transcriptCharacters: Int) -> Int {
        let estimate = transcriptCharacters / 2 + 512
        return min(max(estimate, 1024), 8192)
    }
}

/// Output from an LLM completion.
struct LLMResponse {
    let text: String
    let model: String
    let promptTokens: Int?
    let completionTokens: Int?
}

/// A provider that post-processes transcriptions via an LLM.
protocol LLMProvider {
    static var providerID: LLMProviderID { get }

    /// Send a completion request and return the response.
    func complete(request: LLMRequest) async throws -> LLMResponse

    /// Base host the provider talks to. The pipeline opens a TLS connection
    /// to this endpoint during `.transcribing` so the cleanup call doesn't
    /// pay for the handshake.
    var endpointOrigin: URL? { get }
}

extension LLMProvider {
    var endpointOrigin: URL? { nil }
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case apiError(provider: LLMProviderID, message: String, statusCode: Int?)
    case timeout(provider: LLMProviderID)
    case missingAPIKey(provider: LLMProviderID)
    case emptyResponse(provider: LLMProviderID)
    case rateLimited(provider: LLMProviderID, retryAfter: TimeInterval?)
    /// The provider stopped because the output hit the token limit, so the
    /// text is incomplete and must not be pasted as a finished cleanup.
    case truncated(provider: LLMProviderID)
    /// The provider declined the request (safety classifier / content filter).
    case refused(provider: LLMProviderID)

    var errorDescription: String? {
        switch self {
        case let .apiError(provider, message, code):
            "\(provider.displayName) error\(code.map { " (\($0))" } ?? ""): \(message)"
        case let .timeout(provider):
            "\(provider.displayName) request timed out."
        case let .missingAPIKey(provider):
            "\(provider.displayName) API key is not configured."
        case let .emptyResponse(provider):
            "\(provider.displayName) returned an empty response."
        case let .rateLimited(provider, retry):
            "\(provider.displayName) rate limited.\(retry.map { " Retry after \(Int($0))s." } ?? "")"
        case let .truncated(provider):
            "\(provider.displayName) stopped at the output token limit."
        case let .refused(provider):
            "\(provider.displayName) declined the request."
        }
    }
}

// MARK: - Output sanitizing

enum LLMOutputSanitizer {
    private static let closedReasoningBlock = try! NSRegularExpression(
        pattern: "<(think|thinking)>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let unclosedReasoningBlock = try! NSRegularExpression(
        pattern: "<(think|thinking)>.*\\z",
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )

    /// Removes reasoning that a model leaked into its visible reply
    /// (`<think>…</think>`), then trims. An unclosed opening tag means the
    /// rest of the reply is reasoning, so it is dropped too. Reasoning
    /// models are configured to keep reasoning out of `content`; this is the
    /// defensive layer for custom models or providers that ignore that.
    static func stripReasoning(_ text: String) -> String {
        var result = text
        var range = NSRange(result.startIndex..., in: result)
        result = closedReasoningBlock.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        range = NSRange(result.startIndex..., in: result)
        result = unclosedReasoningBlock.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
