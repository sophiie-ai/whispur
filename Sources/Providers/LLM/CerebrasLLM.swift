import Foundation

/// Cerebras LLM provider (OpenAI-compatible endpoint).
struct CerebrasLLM: LLMProvider {
    static let providerID: LLMProviderID = .cerebras

    private let inner: OpenAILLM

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = LLMProviderID.cerebras.defaultModel,
        timeoutSeconds: TimeInterval = 20
    ) {
        // Cerebras serves an OpenAI-compatible API, so this delegates to OpenAILLM with a different base URL.
        self.inner = OpenAILLM(
            apiKey: apiKey,
            httpClient: httpClient,
            baseURL: "https://api.cerebras.ai/v1",
            providerID: .cerebras,
            model: model,
            timeoutSeconds: timeoutSeconds
        )
    }

    var endpointOrigin: URL? { inner.endpointOrigin }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        try await inner.complete(request: request)
    }
}
