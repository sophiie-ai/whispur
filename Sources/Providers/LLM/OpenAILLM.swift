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
        model: String = LLMProviderID.openai.defaultModel,
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.providerID = providerID
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    var endpointOrigin: URL? { URL(string: baseURL) }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw LLMError.apiError(provider: providerID, message: "Invalid endpoint URL.", statusCode: nil)
        }

        let payload = OpenAIChatFormat.body(model: model, providerID: providerID, request: request)

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
                \(OpenAIChatFormat.settingsSummary(model: model, providerID: providerID, request: request))
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

            return try OpenAIChatFormat.parse(response.data, provider: providerID, model: model)
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

/// Chat Completions request/response shape, shared by OpenAI, Groq and
/// OpenAI-compatible gateways.
enum OpenAIChatFormat {
    /// The parameter set a model accepts. Users can type any model ID (and
    /// point the OpenAI provider at any compatible gateway), so the request
    /// is chosen per model family; unrecognised models get the classic
    /// chat-completions parameters every compatible server understands.
    enum ParameterStyle: Equatable {
        /// Classic chat model: `max_tokens` + `temperature`.
        case classic
        /// Reasoning model whose reasoning can be switched off
        /// (`reasoning_effort: "none"`), which re-enables `temperature`.
        case reasoningOff
        /// Reasoning model that always reasons: lowest effort, no sampling
        /// parameters (they are rejected while reasoning is on).
        case reasoningLow
        /// Groq-hosted gpt-oss: `reasoning_effort: "low"` (it has no
        /// `none`), reasoning dropped from the response, temperature allowed.
        case groqGptOSS
    }

    static func parameterStyle(model: String, providerID: LLMProviderID) -> ParameterStyle {
        let lowered = model.lowercased()
        let name = lowered.split(separator: "/").last.map(String.init) ?? lowered

        if name.hasPrefix("gpt-oss") {
            return providerID == .groq ? .groqGptOSS : .classic
        }
        guard providerID == .openai else { return .classic }

        // Documented as accepting `reasoning_effort: "none"`.
        let reasoningOffModels = ["gpt-6-luna", "gpt-6-sol", "gpt-6.1-terra"]
        if reasoningOffModels.contains(where: { name.hasPrefix($0) }) {
            return .reasoningOff
        }
        let reasoningPrefixes = ["gpt-6", "gpt-5", "o1", "o3", "o4"]
        if reasoningPrefixes.contains(where: { name.hasPrefix($0) }), !name.contains("chat") {
            return .reasoningLow
        }
        return .classic
    }

    static func body(model: String, providerID: LLMProviderID, request: LLMRequest) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.systemPrompt],
                ["role": "user", "content": request.userMessage],
            ],
        ]
        switch parameterStyle(model: model, providerID: providerID) {
        case .classic:
            payload["max_tokens"] = request.maxTokens
            payload["temperature"] = request.temperature
        case .reasoningOff:
            payload["max_completion_tokens"] = request.maxTokens
            payload["reasoning_effort"] = "none"
            payload["temperature"] = request.temperature
        case .reasoningLow:
            payload["max_completion_tokens"] = request.maxTokens
            payload["reasoning_effort"] = "low"
        case .groqGptOSS:
            payload["max_completion_tokens"] = request.maxTokens
            payload["reasoning_effort"] = "low"
            payload["include_reasoning"] = false
            payload["temperature"] = request.temperature
        }
        return payload
    }

    static func settingsSummary(model: String, providerID: LLMProviderID, request: LLMRequest) -> String {
        let body = body(model: model, providerID: providerID, request: request)
        let keys = ["max_tokens", "max_completion_tokens", "reasoning_effort", "include_reasoning", "temperature"]
        return keys.compactMap { key in body[key].map { "\(key): \($0)" } }.joined(separator: "\n")
    }

    /// Reads a chat completion. `finish_reason: "length"` means the output
    /// hit the token limit and is incomplete; `content_filter` means the
    /// provider withheld it. Both throw so the pipeline pastes raw text.
    static func parse(_ data: Data, provider: LLMProviderID, model: String) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw LLMError.emptyResponse(provider: provider)
        }

        switch choice["finish_reason"] as? String {
        case "length": throw LLMError.truncated(provider: provider)
        case "content_filter": throw LLMError.refused(provider: provider)
        default: break
        }

        if message["refusal"] as? String != nil {
            throw LLMError.refused(provider: provider)
        }

        let content = message["content"] as? String ?? ""
        let usage = json["usage"] as? [String: Any]
        return LLMResponse(
            text: LLMOutputSanitizer.stripReasoning(content),
            model: model,
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int
        )
    }
}
