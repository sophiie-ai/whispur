import Foundation

/// A single cheap, read-only request that proves a provider accepts a key.
/// Every check lists models or reads the account, so it never transcribes,
/// completes, or bills. Providers without such an endpoint have no check.
struct ProviderKeyCheck: Equatable {
    enum Endpoint: Equatable {
        /// `GET {base}/models` with a Bearer key. The base comes from the
        /// user's override when one is set and valid.
        case openAIModels(baseURLStorageKey: String)
        case groqModels
        case anthropicModels
        case deepgramProjects
        case elevenLabsUser
    }

    static let openAIDefaultBaseURL = "https://api.openai.com/v1"

    let providerID: String
    let providerName: String
    let kind: ProviderRequestKind
    let key: KeychainKey
    let endpoint: Endpoint

    static func forSpeech(_ provider: STTProviderID) -> ProviderKeyCheck? {
        let endpoint: Endpoint
        switch provider {
        case .openai: endpoint = .openAIModels(baseURLStorageKey: "openaiSTTBaseURL")
        case .groqWhisper: endpoint = .groqModels
        case .deepgram: endpoint = .deepgramProjects
        case .elevenlabs: endpoint = .elevenLabsUser
        case .apple: return nil
        }
        guard let key = provider.keychainKeys.first else { return nil }
        return ProviderKeyCheck(providerID: provider.rawValue, providerName: provider.displayName, kind: .stt, key: key, endpoint: endpoint)
    }

    static func forCleanup(_ provider: LLMProviderID) -> ProviderKeyCheck? {
        let endpoint: Endpoint
        switch provider {
        case .openai: endpoint = .openAIModels(baseURLStorageKey: "openaiLLMBaseURL")
        case .anthropic: endpoint = .anthropicModels
        case .groq: endpoint = .groqModels
        // Bedrock API keys are scoped to model invocation, so a read-only
        // control-plane call can reject a key that dictation accepts.
        case .bedrock: return nil
        }
        guard let key = provider.keychainKeys.first else { return nil }
        return ProviderKeyCheck(providerID: provider.rawValue, providerName: provider.displayName, kind: .llm, key: key, endpoint: endpoint)
    }

    /// Builds the request for `secret`. `baseURLOverride` resolves a stored
    /// override the same way the provider registry does.
    func makeRequest(
        secret: String,
        baseURLOverride: (String) -> String? = ProviderRegistry.baseURLOverride(forKey:)
    ) -> URLRequest? {
        let urlString: String
        switch endpoint {
        case let .openAIModels(storageKey):
            urlString = (baseURLOverride(storageKey) ?? Self.openAIDefaultBaseURL) + "/models"
        case .groqModels:
            urlString = "https://api.groq.com/openai/v1/models"
        case .anthropicModels:
            urlString = "https://api.anthropic.com/v1/models?limit=1"
        case .deepgramProjects:
            urlString = "https://api.deepgram.com/v1/projects"
        case .elevenLabsUser:
            urlString = "https://api.elevenlabs.io/v1/user"
        }
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch endpoint {
        case .openAIModels, .groqModels:
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .anthropicModels:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .deepgramProjects:
            request.setValue("Token \(secret)", forHTTPHeaderField: "Authorization")
        case .elevenLabsUser:
            request.setValue(secret, forHTTPHeaderField: "xi-api-key")
        }
        return request
    }

    /// Maps a finished check to what the UI shows. Failures carry the
    /// provider's own message when it sent one.
    static func outcome(statusCode: Int, providerMessage: String?, providerName: String) -> ProviderKeyTestState {
        if (200 ... 299).contains(statusCode) {
            return .passed("\(providerName) accepted this key.")
        }
        let message = providerMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = (message?.isEmpty ?? true) ? "The provider rejected this key." : message!
        return .failed("HTTP \(statusCode): \(detail)")
    }
}

enum ProviderKeyTestState: Equatable {
    case running
    case passed(String)
    case failed(String)
}

/// Runs key checks for the Settings window and keeps the latest result per
/// provider. Checks go through `ProviderHTTPClient`, so each one is listed
/// in the Requests tab exactly like dictation traffic.
@MainActor
final class ProviderKeyTester: ObservableObject {
    @Published private(set) var results: [String: ProviderKeyTestState]

    private let httpClient: ProviderHTTPClient?

    init(requestLog: ProviderRequestLog?, results: [String: ProviderKeyTestState] = [:]) {
        self.results = results
        self.httpClient = requestLog.map { ProviderHTTPClient(session: Self.makeSession(), requestLog: $0) }
    }

    func result(for descriptorID: String) -> ProviderKeyTestState? {
        results[descriptorID]
    }

    /// Clears a stale result after the key it tested changes.
    func invalidate(key: KeychainKey) {
        results = results.filter { id, _ in
            !ProviderKeyTester.descriptorIDs(using: key).contains(id)
        }
    }

    func run(_ check: ProviderKeyCheck, descriptorID: String, credentials: ProviderCredentials) {
        guard results[descriptorID] != .running else { return }
        guard let secret = credentials.secret(check.key), let request = check.makeRequest(secret: secret) else {
            results[descriptorID] = .failed("Save a key first.")
            return
        }
        guard let httpClient else { return }
        results[descriptorID] = .running

        Task { [weak self] in
            let state: ProviderKeyTestState
            do {
                let response = try await httpClient.send(
                    request,
                    providerID: check.providerID,
                    kind: check.kind,
                    requestBodySummary: "Key check (read-only). No audio or text sent."
                )
                state = ProviderKeyCheck.outcome(
                    statusCode: response.response.statusCode,
                    providerMessage: response.errorMessage,
                    providerName: check.providerName
                )
            } catch {
                state = .failed(ProviderHTTPClient.transportErrorMessage(for: error))
            }
            self?.results[descriptorID] = state
        }
    }

    private static func descriptorIDs(using key: KeychainKey) -> [String] {
        STTProviderID.allCases.filter { $0.keychainKeys.contains(key) }.map { "stt.\($0.rawValue)" }
            + LLMProviderID.allCases.filter { $0.keychainKeys.contains(key) }.map { "llm.\($0.rawValue)" }
    }

    /// Fails fast instead of waiting for connectivity, unlike the dictation
    /// session: a key check should answer in seconds.
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }
}
