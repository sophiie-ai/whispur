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
        case .bedrock:
            // TODO: Implement Bedrock STT with AWS SDK
            return nil
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
            return OpenAILLM(apiKey: key, httpClient: httpClient)
        case .anthropic:
            guard let key = keychain.get(.anthropicAPIKey) else { return nil }
            return AnthropicLLM(apiKey: key, httpClient: httpClient)
        case .groq:
            guard let key = keychain.get(.groqAPIKey) else { return nil }
            return GroqLLM(apiKey: key, httpClient: httpClient)
        case .bedrock:
            // TODO: Implement Bedrock LLM with AWS SDK
            return nil
        }
    }

    /// Returns provider IDs that have their API keys configured.
    func availableLLMProviders() -> [LLMProviderID] {
        LLMProviderID.allCases.filter { keychain.hasKeysFor(llm: $0) }
    }
}
