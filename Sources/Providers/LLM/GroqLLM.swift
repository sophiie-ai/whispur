import Foundation

/// Groq LLM provider (OpenAI-compatible endpoint).
struct GroqLLM: LLMProvider {
    static let providerID: LLMProviderID = .groq

    private let inner: OpenAILLM

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = "llama-3.3-70b-versatile",
        timeoutSeconds: TimeInterval = 20
    ) {
        // Groq uses OpenAI-compatible API, so we delegate to OpenAILLM with a different base URL.
        self.inner = OpenAILLM(
            apiKey: apiKey,
            httpClient: httpClient,
            baseURL: "https://api.groq.com/openai/v1",
            providerID: .groq,
            model: model,
            timeoutSeconds: timeoutSeconds
        )
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        try await inner.complete(request: request)
    }
}
