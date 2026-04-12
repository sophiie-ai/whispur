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

    func transcribe(fileURL: URL) async throws -> String {
        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
        ]

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
