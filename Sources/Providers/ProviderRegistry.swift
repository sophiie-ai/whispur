import Foundation

/// Factory that creates provider instances from their IDs.
///
/// The registry reads API keys from the Keychain and instantiates
/// the appropriate provider. Returns nil if required keys are missing.
final class ProviderRegistry {
    private let keychain: KeychainManager
    private let httpClient: ProviderHTTPClient

    init(
        keychain: KeychainManager = .shared,
        httpClient: ProviderHTTPClient
    ) {
        self.keychain = keychain
        self.httpClient = httpClient
    }

    // MARK: - STT

    func makeSTTProvider(for id: STTProviderID) -> (any STTProvider)? {
        switch id {
        case .openai:
            guard let key = keychain.get(.openaiAPIKey) else { return nil }
            let baseURL = Self.baseURLOverride(forKey: "openaiSTTBaseURL")
            let model = Self.textOverride(forKey: "openaiSTTModel")
            if baseURL != nil || model != nil {
                return OpenAISTT(
                    apiKey: key,
                    httpClient: httpClient,
                    baseURL: baseURL ?? "https://api.openai.com/v1",
                    model: model ?? "whisper-1"
                )
            }
            return OpenAISTT(apiKey: key, httpClient: httpClient)
        case .groqWhisper:
            guard let key = keychain.get(.groqAPIKey) else { return nil }
            return GroqWhisperSTT(apiKey: key, httpClient: httpClient)
        case .deepgram:
            guard let key = keychain.get(.deepgramAPIKey) else { return nil }
            return DeepgramSTT(apiKey: key, httpClient: httpClient)
        case .elevenlabs:
            guard let key = keychain.get(.elevenlabsAPIKey) else { return nil }
            return ElevenLabsSTT(apiKey: key, httpClient: httpClient)
        case .apple:
            return AppleSTT()
        }
    }

    /// Returns provider IDs that have their API keys configured.
    func availableSTTProviders() -> [STTProviderID] {
        STTProviderID.allCases.filter { keychain.hasKeysFor(stt: $0) }
    }

    // MARK: - LLM

    func makeLLMProvider(for id: LLMProviderID) -> (any LLMProvider)? {
        switch id {
        case .openai:
            guard let key = keychain.get(.openaiAPIKey) else { return nil }
            let baseURL = Self.baseURLOverride(forKey: "openaiLLMBaseURL")
            let model = Self.textOverride(forKey: "openaiLLMModel")
            if baseURL != nil || model != nil {
                return OpenAILLM(
                    apiKey: key,
                    httpClient: httpClient,
                    baseURL: baseURL ?? "https://api.openai.com/v1",
                    model: model ?? "gpt-4o-mini"
                )
            }
            return OpenAILLM(apiKey: key, httpClient: httpClient)
        case .anthropic:
            guard let key = keychain.get(.anthropicAPIKey) else { return nil }
            return AnthropicLLM(apiKey: key, httpClient: httpClient)
        case .groq:
            guard let key = keychain.get(.groqAPIKey) else { return nil }
            return GroqLLM(apiKey: key, httpClient: httpClient)
        case .bedrock:
            guard let key = keychain.get(.awsBedrockAPIKey),
                  let region = keychain.get(.awsRegion)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !region.isEmpty
            else { return nil }
            return BedrockLLM(apiKey: key, region: region, httpClient: httpClient)
        }
    }

    /// Returns provider IDs that have their API keys configured.
    func availableLLMProviders() -> [LLMProviderID] {
        LLMProviderID.allCases.filter { keychain.hasKeysFor(llm: $0) }
    }

    /// Reads an OpenAI-compatible base URL override from UserDefaults.
    /// Trims whitespace and a trailing slash so callers can append `/chat/completions` etc.
    private static func baseURLOverride(forKey key: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return nil }
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private static func textOverride(forKey key: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
