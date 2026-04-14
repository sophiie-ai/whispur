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

    func transcribe(fileURL: URL, languages: [String]) async throws -> String {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        var query: [URLQueryItem] = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

        // Deepgram language routing (nova-3):
        //  - 1 language → send `language=<iso-639-1>` for best accuracy.
        //  - 2–3 languages all within nova-3's multi set → `language=multi`
        //    (handles code-switching within a single utterance).
        //  - 2–3 languages with any outside the multi set → constrained
        //    auto-detect via repeated `detect_language` params.
        let isoCodes = languages.map { STTLanguage(code: $0, displayName: "").iso639_1 }
        let languageSummary: String
        switch isoCodes.count {
        case 0:
            languageSummary = "auto"
        case 1:
            query.append(URLQueryItem(name: "language", value: isoCodes[0]))
            languageSummary = isoCodes[0]
        default:
            let allInMultiSet = isoCodes.allSatisfy { STTLanguageCatalog.deepgramNova3MultiISO.contains($0) }
            if allInMultiSet {
                query.append(URLQueryItem(name: "language", value: "multi"))
                languageSummary = "multi (\(isoCodes.joined(separator: ",")))"
            } else {
                for code in isoCodes {
                    query.append(URLQueryItem(name: "detect_language", value: code))
                }
                languageSummary = "detect(\(isoCodes.joined(separator: ",")))"
            }
        }

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
                language: \(languageSummary)
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
