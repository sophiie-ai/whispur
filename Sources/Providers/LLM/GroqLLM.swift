import Foundation

/// Groq LLM provider (OpenAI-compatible endpoint).
struct GroqLLM: LLMProvider {
    static let providerID: LLMProviderID = .groq

    private let inner: OpenAILLM

    init(
        apiKey: String,
        model: String = "llama-3.3-70b-versatile",
        timeoutSeconds: TimeInterval = 20
    ) {
        // Groq uses OpenAI-compatible API, so we delegate to OpenAILLM with a different base URL.
        self.inner = OpenAILLM(
            apiKey: apiKey,
            baseURL: "https://api.groq.com/openai/v1",
            model: model,
            timeoutSeconds: timeoutSeconds
        )
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        do {
            return try await inner.complete(request: request)
        } catch let error as LLMError {
            // Re-map provider ID from .openai to .groq for clearer error messages
            switch error {
            case let .apiError(_, message, statusCode):
                throw LLMError.apiError(provider: .groq, message: message, statusCode: statusCode)
            case .timeout:
                throw LLMError.timeout(provider: .groq)
            case .emptyResponse:
                throw LLMError.emptyResponse(provider: .groq)
            case let .rateLimited(_, retryAfter):
                throw LLMError.rateLimited(provider: .groq, retryAfter: retryAfter)
            default:
                throw error
            }
        }
    }
}
