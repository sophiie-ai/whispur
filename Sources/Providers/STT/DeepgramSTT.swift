import Foundation

/// Deepgram speech-to-text provider.
struct DeepgramSTT: STTProvider {
    static let providerID: STTProviderID = .deepgram

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = "nova-3",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Deepgram language routing. No languages → `language=multi` (nova-3
    /// code-switching). One → that code, for best single-language accuracy.
    /// Several → `language=multi` plus one `language_hint` per language:
    /// `language` takes a single value, and hints bias multi's detection
    /// without restricting it (they apply only with `multi`).
    static func languageQueryItems(for language: STTLanguageSelection) -> [URLQueryItem] {
        switch STTLanguageResolver.deepgram(for: language) {
        case let .single(code):
            return [URLQueryItem(name: "language", value: code)]
        case .multi:
            return [URLQueryItem(name: "language", value: "multi")]
                + language.isoCodes.map { URLQueryItem(name: "language_hint", value: $0) }
        }
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        // Nova-3 uses `keyterm` (exact-match phrase biasing). Older models
        // used `keywords` with optional `:boost`. Nova-3 ignores `keywords`,
        // so only send `keyterm` here — kept at a reasonable cap to avoid
        // ballooning the query string.
        let biasedTerms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)
        for term in biasedTerms {
            query.append(URLQueryItem(name: "keyterm", value: term))
        }

        let languageItems = Self.languageQueryItems(for: language)
        query.append(contentsOf: languageItems)
        let languageSummary = languageItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: " ")

        components.queryItems = query

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds
        let audioData = try Data(contentsOf: fileURL)
        request.httpBody = audioData

        do {
            let response = try await httpClient.send(
                request,
                providerID: Self.providerID.rawValue,
                kind: .stt,
                requestBodySummary: """
                raw audio/wav body
                file: \(fileURL.lastPathComponent) (\(audioData.count) bytes)
                model: \(model)
                smart_format: true
                punctuate: true
                \(languageSummary)
                keyterms: \(biasedTerms.isEmpty ? "-" : biasedTerms.joined(separator: ", "))
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .deepgram,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let results = json?["results"] as? [String: Any]
            let channels = results?["channels"] as? [[String: Any]]
            let alternatives = channels?.first?["alternatives"] as? [[String: Any]]
            let transcript = alternatives?.first?["transcript"] as? String ?? ""

            return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as STTError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw STTError.timeout(provider: .deepgram)
        } catch {
            throw STTError.apiError(
                provider: .deepgram,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
