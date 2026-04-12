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
        case .bedrock: [.awsAccessKeyID, .awsSecretAccessKey]
        }
    }
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
}

// MARK: - Errors

enum LLMError: LocalizedError {
    case apiError(provider: LLMProviderID, message: String, statusCode: Int?)
    case timeout(provider: LLMProviderID)
    case missingAPIKey(provider: LLMProviderID)
    case emptyResponse(provider: LLMProviderID)
    case rateLimited(provider: LLMProviderID, retryAfter: TimeInterval?)

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
        }
    }
}
