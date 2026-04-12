import Foundation

/// Anthropic Claude Messages API provider.
struct AnthropicLLM: LLMProvider {
    static let providerID: LLMProviderID = .anthropic

    private let apiKey: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        model: String = "claude-sonnet-4-20250514",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userMessage],
            ],
        ]

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        httpRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = timeoutSeconds
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        let httpResponse = response as! HTTPURLResponse

        if httpResponse.statusCode == 429 {
            let retryAfter = (httpResponse.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
            throw LLMError.rateLimited(provider: .anthropic, retryAfter: retryAfter)
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(provider: .anthropic, message: message, statusCode: httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = json?["content"] as? [[String: Any]]
        let text = content?.first?["text"] as? String ?? ""
        let usage = json?["usage"] as? [String: Any]

        guard !text.isEmpty else {
            throw LLMError.emptyResponse(provider: .anthropic)
        }

        return LLMResponse(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model,
            promptTokens: usage?["input_tokens"] as? Int,
            completionTokens: usage?["output_tokens"] as? Int
        )
    }
}
