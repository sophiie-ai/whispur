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
        model: String = LLMProviderID.anthropic.defaultModel,
        timeoutSeconds: TimeInterval = 20
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let endpointURL = URL(string: "https://api.anthropic.com/v1/messages")

    var endpointOrigin: URL? { URL(string: "https://api.anthropic.com") }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        guard let url = Self.endpointURL else {
            throw LLMError.apiError(provider: .anthropic, message: "Invalid endpoint URL.", statusCode: nil)
        }

        var payload = AnthropicMessagesFormat.body(model: model, request: request)
        payload["model"] = model

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
                \(AnthropicMessagesFormat.settingsSummary(model: model))
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

            return try AnthropicMessagesFormat.parse(response.data, provider: .anthropic, model: model)
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

/// Request/response shape shared by the Anthropic API and Bedrock, which
/// serves the same Messages API body through `InvokeModel`.
enum AnthropicMessagesFormat {
    /// What a given Claude model accepts for the knobs cleanup cares about.
    /// Users can type any model ID in Settings, so the request adapts to the
    /// model family instead of assuming the default.
    struct ModelProfile: Equatable {
        enum Thinking: Equatable {
            /// Leave `thinking` out of the request.
            case omit
            /// `{"type": "disabled"}`.
            case disabled
            /// `{"type": "between_tools"}`, Sonnet 5.5's thinking-off mode.
            case betweenTools
        }

        let thinking: Thinking
        /// `output_config.effort`, when the model supports effort levels.
        let effort: String?
        /// Whether the model still accepts a non-default `temperature`.
        let acceptsTemperature: Bool

        init(model: String) {
            guard let parsed = Self.parse(model) else {
                // Unknown naming: assume a current model. Effort `low` with
                // the default thinking mode and no sampling parameter is
                // valid on every current Claude model.
                self.init(thinking: .omit, effort: "low", acceptsTemperature: false)
                return
            }

            let (family, version) = parsed
            switch family {
            case "haiku" where version >= 5.5:
                // Thinks by default. `disabled` is accepted at effort ≤ high,
                // and only temperature 1 is accepted on API 2023-06-01.
                self.init(thinking: .disabled, effort: "low", acceptsTemperature: false)
            case "sonnet" where version >= 5.5:
                // `disabled` is a 400 here; `between_tools` is the off switch.
                self.init(thinking: .betweenTools, effort: "low", acceptsTemperature: false)
            case "opus" where version >= 5.5, "fable", "mythos":
                // Thinking can't be turned off; effort is the only lever.
                self.init(thinking: .omit, effort: "low", acceptsTemperature: false)
            case "opus" where version >= 5:
                // Thinks by default; `disabled` accepted at effort ≤ high.
                self.init(thinking: .disabled, effort: "low", acceptsTemperature: false)
            case _ where version >= 4.7:
                // Opus 4.7/4.8, Sonnet 5: no thinking unless asked, sampling
                // parameters removed.
                self.init(thinking: .omit, effort: "low", acceptsTemperature: false)
            case "opus" where version >= 4.5, "sonnet" where version >= 4.6:
                self.init(thinking: .omit, effort: "low", acceptsTemperature: true)
            default:
                // Haiku 4.5, Sonnet 4.x, Claude 3.x: no effort parameter
                // (it errors), temperature accepted.
                self.init(thinking: .omit, effort: nil, acceptsTemperature: true)
            }
        }

        init(thinking: Thinking, effort: String?, acceptsTemperature: Bool) {
            self.thinking = thinking
            self.effort = effort
            self.acceptsTemperature = acceptsTemperature
        }

        /// Extracts `(family, version)` from IDs like `claude-haiku-5-5`,
        /// `anthropic.claude-sonnet-4-20250514-v1:0`,
        /// `us.anthropic.claude-opus-4-6-v1` or `claude-3-5-sonnet-20241022`.
        static func parse(_ model: String) -> (family: String, version: Double)? {
            let lowered = model.lowercased()
            guard let range = lowered.range(of: "claude-") else { return nil }
            let tokens = lowered[range.upperBound...]
                .split(whereSeparator: { $0 == "-" || $0 == ":" || $0 == "@" })
                .map(String.init)
            let families: Set<String> = ["haiku", "sonnet", "opus", "fable", "mythos"]

            func version(from parts: ArraySlice<String>) -> Double? {
                guard let majorToken = parts.first, let major = Int(majorToken), majorToken.count <= 2 else { return nil }
                var value = Double(major)
                let rest = parts.dropFirst()
                if let minorToken = rest.first, minorToken.count <= 2, let minor = Int(minorToken) {
                    value += Double(minor) / 10
                }
                return value
            }

            if let first = tokens.first, families.contains(first) {
                guard let value = version(from: tokens.dropFirst()) else {
                    return first == "fable" || first == "mythos" ? (first, 5) : nil
                }
                return (first, value)
            }

            // Legacy "claude-3-5-sonnet-…" naming: version first, family after.
            guard let value = version(from: tokens[...]),
                  let family = tokens.first(where: { families.contains($0) })
            else { return nil }
            return (family, value)
        }
    }

    /// Messages API body without the `model` field (Bedrock puts the model
    /// in the URL and the Anthropic API adds it at the top level).
    static func body(model: String, request: LLMRequest) -> [String: Any] {
        let profile = ModelProfile(model: model)
        var payload: [String: Any] = [
            "max_tokens": request.maxTokens,
            "system": request.systemPrompt,
            "messages": [
                ["role": "user", "content": request.userMessage],
            ],
        ]
        switch profile.thinking {
        case .omit: break
        case .disabled: payload["thinking"] = ["type": "disabled"]
        case .betweenTools: payload["thinking"] = ["type": "between_tools"]
        }
        if let effort = profile.effort {
            payload["output_config"] = ["effort": effort]
        }
        // Current Claude models reject any temperature other than the default
        // (a 400), so it is sent only to the older models that accept it.
        if profile.acceptsTemperature {
            payload["temperature"] = request.temperature
        }
        return payload
    }

    static func settingsSummary(model: String) -> String {
        let profile = ModelProfile(model: model)
        return "thinking: \(profile.thinking) effort: \(profile.effort ?? "-") temperature_sent: \(profile.acceptsTemperature)"
    }

    /// Reads a Messages API response. The answer is the first `text` block:
    /// models that think put `thinking` blocks before it, so `content[0]` is
    /// not the answer. A response stopped by the token limit is incomplete
    /// and a refusal carries no cleanup, so both throw and the pipeline
    /// pastes the raw transcript instead.
    static func parse(_ data: Data, provider: LLMProviderID, model: String) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            throw LLMError.emptyResponse(provider: provider)
        }

        switch json["stop_reason"] as? String {
        case "max_tokens": throw LLMError.truncated(provider: provider)
        case "refusal": throw LLMError.refused(provider: provider)
        default: break
        }

        // No text block in a well-formed response is an intentional empty
        // cleanup; the pipeline decides what to paste.
        let rawText = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String ?? ""
        let usage = json["usage"] as? [String: Any]
        return LLMResponse(
            text: LLMOutputSanitizer.stripReasoning(rawText),
            model: model,
            promptTokens: usage?["input_tokens"] as? Int,
            completionTokens: usage?["output_tokens"] as? Int
        )
    }
}
