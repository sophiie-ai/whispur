import Foundation

/// Anthropic Claude on AWS Bedrock, authenticated with a Bedrock API key
/// (`AWS_BEARER_TOKEN_BEDROCK`) sent as `Authorization: Bearer …`.
struct BedrockLLM: LLMProvider {
    static let providerID: LLMProviderID = .bedrock

    private let apiKey: String
    private let region: String
    private let httpClient: ProviderHTTPClient
    private let modelID: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        region: String,
        httpClient: ProviderHTTPClient,
        modelID: String = "anthropic.claude-sonnet-4-20250514-v1:0",
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.region = region
        self.httpClient = httpClient
        self.modelID = modelID
        self.timeoutSeconds = timeoutSeconds
    }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        let encodedModel = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(encodedModel)/invoke") else {
            throw LLMError.apiError(provider: .bedrock, message: "Invalid endpoint URL.", statusCode: nil)
        }

        let payload: [String: Any] = [
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": request.maxTokens,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userMessage],
            ],
        ]

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        httpRequest.timeoutInterval = timeoutSeconds
        httpRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        do {
            let response = try await httpClient.send(
                httpRequest,
                providerID: Self.providerID.rawValue,
                kind: .llm,
                requestBodySummary: """
                JSON payload
                model: \(modelID)
                region: \(region)
                max_tokens: \(request.maxTokens)
                system_prompt_chars: \(request.systemPrompt.count)
                user_message_chars: \(request.userMessage.count)
                """
            )

            if response.response.statusCode == 429 {
                let retryAfter = response.response.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw LLMError.rateLimited(provider: .bedrock, retryAfter: retryAfter)
            }

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw LLMError.apiError(
                    provider: .bedrock,
                    message: response.errorMessage ?? "The provider rejected the completion request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let content = json?["content"] as? [[String: Any]]
            let text = content?.first?["text"] as? String ?? ""
            let usage = json?["usage"] as? [String: Any]

            guard !text.isEmpty else {
                throw LLMError.emptyResponse(provider: .bedrock)
            }

            return LLMResponse(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                model: modelID,
                promptTokens: usage?["input_tokens"] as? Int,
                completionTokens: usage?["output_tokens"] as? Int
            )
        } catch let error as LLMError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw LLMError.timeout(provider: .bedrock)
        } catch {
            throw LLMError.apiError(
                provider: .bedrock,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
