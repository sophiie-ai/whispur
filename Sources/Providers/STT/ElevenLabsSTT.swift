import Foundation

/// ElevenLabs speech-to-text provider (Scribe API).
struct ElevenLabsSTT: STTProvider {
    static let providerID: STTProviderID = .elevenlabs

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = "scribe_v2",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let endpointURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        guard let url = Self.endpointURL else {
            throw STTError.apiError(provider: .elevenlabs, message: "Invalid endpoint URL.", statusCode: nil)
        }
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        // Scribe accepts a single `language_code` (ISO-639-1) or omit for auto.
        let languageParam = STTLanguageResolver.iso639_1(for: language)

        // Scribe's `biased_keywords` takes a JSON array of terms with
        // optional `:weight` (1.0–5.0). Use a mid boost so Scribe prefers
        // the user's vocabulary without overriding the acoustic model.
        let biasedTerms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)
        let biasedKeywordsJSON: String? = {
            guard !biasedTerms.isEmpty else { return nil }
            let entries = biasedTerms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\":2.0" }
            return "[" + entries.joined(separator: ",") + "]"
        }()

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, mimeType: "audio/wav", data: audioData)
        body.appendMultipart(boundary: boundary, name: "model_id", value: model)
        body.appendMultipart(boundary: boundary, name: "file_format", value: "pcm_s16le_16")
        if let languageParam {
            body.appendMultipart(boundary: boundary, name: "language_code", value: languageParam)
        }
        if let biasedKeywordsJSON {
            body.appendMultipart(boundary: boundary, name: "biased_keywords", value: biasedKeywordsJSON)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let response = try await httpClient.send(
                request,
                providerID: Self.providerID.rawValue,
                kind: .stt,
                requestBodySummary: """
                multipart form-data
                file: \(fileURL.lastPathComponent) (audio/wav, \(audioData.count) bytes)
                model_id: \(model)
                file_format: pcm_s16le_16
                language_code: \(languageParam ?? "auto")
                biased_keywords: \(biasedKeywordsJSON ?? "-")
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .elevenlabs,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any]
            let text = json?["text"] as? String ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as STTError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw STTError.timeout(provider: .elevenlabs)
        } catch {
            throw STTError.apiError(
                provider: .elevenlabs,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
