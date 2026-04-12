import Foundation

/// OpenAI chat completions LLM provider.
struct OpenAILLM: LLMProvider {
    static let providerID: LLMProviderID = .openai

    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "gpt-4o-mini",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let url = URL(string: "\(baseURL)/chat/completions")!

        let payload: [String: Any] = [
            "model": model,
            "temperature": request.temperature,
            "max_tokens": request.maxTokens,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userMessage],
            ],
        ]

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = timeoutSeconds
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: httpRequest)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw LLMError.apiError(provider: .openai, message: message, statusCode: httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        let content = message?["content"] as? String ?? ""
        let usage = json?["usage"] as? [String: Any]

        guard !content.isEmpty else {
            throw LLMError.emptyResponse(provider: .openai)
        }

        return LLMResponse(
            text: content.trimmingCharacters(in: .whitespacesAndNewlines),
            model: model,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int
        )
    }
}
