import Foundation

/// Factory that creates provider instances from their IDs.
///
/// The registry reads API keys from the Keychain and instantiates
/// the appropriate provider. Returns nil if required keys are missing.
final class ProviderRegistry {
    private let keychain: KeychainManager

    init(keychain: KeychainManager = .shared) {
        self.keychain = keychain
    }

    // MARK: - STT

    func makeSTTProvider(for id: STTProviderID) -> (any STTProvider)? {
        switch id {
        case .openai:
            guard let key = keychain.get(.openaiAPIKey) else { return nil }
            return OpenAISTT(apiKey: key)
        case .deepgram:
            guard let key = keychain.get(.deepgramAPIKey) else { return nil }
            return DeepgramSTT(apiKey: key)
        case .elevenlabs:
            guard let key = keychain.get(.elevenlabsAPIKey) else { return nil }
            return ElevenLabsSTT(apiKey: key)
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
            return OpenAILLM(apiKey: key)
        case .anthropic:
            guard let key = keychain.get(.anthropicAPIKey) else { return nil }
            return AnthropicLLM(apiKey: key)
        case .groq:
            guard let key = keychain.get(.groqAPIKey) else { return nil }
            return GroqLLM(apiKey: key)
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
