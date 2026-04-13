import Foundation

/// OpenAI chat completions LLM provider.
struct OpenAILLM: LLMProvider {
    static let providerID: LLMProviderID = .openai

    private let apiKey: String
    private let providerID: LLMProviderID
    private let httpClient: ProviderHTTPClient
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        baseURL: String = "https://api.openai.com/v1",
        providerID: LLMProviderID = .openai,
        model: String = "gpt-4o-mini",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.providerID = providerID
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.apiError(provider: providerID, message: "Invalid endpoint URL.", statusCode: nil)
        }

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

        do {
            let response = try await httpClient.send(
                httpRequest,
                providerID: providerID.rawValue,
                kind: .llm,
                requestBodySummary: """
                JSON payload
                model: \(model)
                temperature: \(request.temperature)
                max_tokens: \(request.maxTokens)
                system_prompt_chars: \(request.systemPrompt.count)
                user_message_chars: \(request.userMessage.count)
                """
            )

            if response.response.statusCode == 429 {
                let retryAfter = response.response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw LLMError.rateLimited(provider: providerID, retryAfter: retryAfter)
            }

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw LLMError.apiError(
                    provider: providerID,
                    message: response.errorMessage ?? "The provider rejected the completion request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let choices = json?["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            let content = message?["content"] as? String ?? ""
            let usage = json?["usage"] as? [String: Any]

            guard !content.isEmpty else {
                throw LLMError.emptyResponse(provider: providerID)
            }

            return LLMResponse(
                text: content.trimmingCharacters(in: .whitespacesAndNewlines),
                model: model,
                promptTokens: usage?["prompt_tokens"] as? Int,
                completionTokens: usage?["completion_tokens"] as? Int
            )
        } catch let error as LLMError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout(provider: providerID)
        } catch {
            throw LLMError.apiError(
                provider: providerID,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
