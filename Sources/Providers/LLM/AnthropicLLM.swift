import Foundation

/// Anthropic Claude Messages API provider.
struct AnthropicLLM: LLMProvider {
    static let providerID: LLMProviderID = .anthropic

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = "claude-sonnet-4-20250514",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let endpointURL = URL(string: "https://api.anthropic.com/v1/messages")

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard let url = Self.endpointURL else {
            throw LLMError.apiError(provider: .anthropic, message: "Invalid endpoint URL.", statusCode: nil)
        }

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

        do {
            let response = try await httpClient.send(
                httpRequest,
                providerID: Self.providerID.rawValue,
                kind: .llm,
                requestBodySummary: """
                JSON payload
                model: \(model)
                max_tokens: \(request.maxTokens)
                system_prompt_chars: \(request.systemPrompt.count)
                user_message_chars: \(request.userMessage.count)
                """
            )

            if response.response.statusCode == 429 {
                let retryAfter = response.response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw LLMError.rateLimited(provider: .anthropic, retryAfter: retryAfter)
            }

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw LLMError.apiError(
                    provider: .anthropic,
                    message: response.errorMessage ?? "The provider rejected the completion request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
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
        } catch let error as LLMError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout(provider: .anthropic)
        } catch {
            throw LLMError.apiError(
                provider: .anthropic,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
