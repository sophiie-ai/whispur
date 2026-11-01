import Foundation

/// Mistral Voxtral speech-to-text provider (`/v1/audio/transcriptions`).
///
/// Vocabulary goes to `context_bias`, one form field per term. The API reads
/// each entry as either a keyphrase or a free-text description of the audio.
struct MistralSTT: STTProvider {
    static let providerID: STTProviderID = .mistral
    static let defaultModel = "voxtral-mini-transcribe-3"
    static let endpoint = "https://api.mistral.ai/v1/audio/transcriptions"

    /// Context shares the model's window with the audio and has no documented
    /// cap of its own, so keep it to the same budget as other providers.
    static let maxContextTerms = 50

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = MistralSTT.defaultModel,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Text fields for one request, file part excluded. `.auto` omits
    /// `language` so Voxtral detects it.
    static func formFields(model: String, language: STTLanguageSelection, vocabulary: [String]) -> [MultipartFormField] {
        var fields = [MultipartFormField(name: "model", value: model)]
        if let code = STTLanguageResolver.iso639_1(for: language) {
            fields.append(MultipartFormField(name: "language", value: code))
        }
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxContextTerms)
        for term in terms {
            fields.append(MultipartFormField(name: "context_bias", value: term))
        }
        return fields
    }

    static func parseTranscript(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            throw STTError.apiError(provider: .mistral, message: "Invalid endpoint URL.", statusCode: nil)
        }
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        let fields = Self.formFields(model: model, language: language, vocabulary: vocabulary)

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        body.appendMultipart(boundary: boundary, fields: fields)
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
                \(fields.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .mistral,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            return Self.parseTranscript(response.data)
        } catch let error as STTError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw STTError.timeout(provider: .mistral)
        } catch {
            throw STTError.apiError(
                provider: .mistral,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
