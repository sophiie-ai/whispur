import Foundation

/// ElevenLabs speech-to-text provider (Scribe API).
///
/// Vocabulary goes to `keyterms`, one form field per term. `scribe_v3` also
/// takes the user's other languages as `secondary_language_codes`;
/// `scribe_v2` takes a single `language_code`.
struct ElevenLabsSTT: STTProvider {
    static let providerID: STTProviderID = .elevenlabs
    static let defaultModel = "scribe_v3"

    /// The API's documented caps on `keyterms`: 1000 terms, each at most 50
    /// characters and 5 words. Stay in line with the other providers' 50.
    static let maxKeyterms = 50
    static let maxKeytermCharacters = 50
    static let maxKeytermWords = 5
    /// Characters the API refuses inside a key term.
    static let disallowedKeytermCharacters: Set<Character> = ["<", ">", "{", "}", "[", "]", "\\"]

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        model: String = ElevenLabsSTT.defaultModel,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    private static let endpointURL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")

    /// The key, for the realtime session's handshake header.
    var streamingAPIKey: String { apiKey }

    /// The realtime model that matches the batch model the user picked.
    var streamingModel: String { ElevenLabsRealtimeFormat.realtimeModel(for: model) }

    /// True for models that take `secondary_language_codes` (Scribe v3).
    static func acceptsSecondaryLanguages(model: String) -> Bool {
        model == "scribe_v3" || model.hasPrefix("scribe_v3_")
    }

    /// Text fields for one request, file part excluded.
    ///
    /// Scribe v3 gets the first of several languages as `language_code` and
    /// the rest as `secondary_language_codes`. Scribe v2 takes one
    /// `language_code`, so with several it auto-detects and the script guard
    /// checks the result. `.auto` omits the language either way.
    static func formFields(model: String, language: STTLanguageSelection, vocabulary: [String]) -> [MultipartFormField] {
        var fields = [
            MultipartFormField(name: "model_id", value: model),
            MultipartFormField(name: "file_format", value: "pcm_s16le_16"),
        ]
        if acceptsSecondaryLanguages(model: model) {
            let codes = language.isoCodes
            if let primary = codes.first {
                fields.append(MultipartFormField(name: "language_code", value: primary))
            }
            for code in codes.dropFirst() {
                fields.append(MultipartFormField(name: "secondary_language_codes", value: code))
            }
        } else if let code = STTLanguageResolver.iso639_1(for: language) {
            fields.append(MultipartFormField(name: "language_code", value: code))
        }
        for term in keyterms(from: vocabulary) {
            fields.append(MultipartFormField(name: "keyterms", value: term))
        }
        return fields
    }

    /// Trimmed, non-empty vocabulary terms that fit the API's documented
    /// limits, capped at `maxKeyterms`. A term that breaks a limit is dropped
    /// rather than sent, because one bad term can fail the whole request.
    static func keyterms(from vocabulary: [String]) -> [String] {
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { term in
                !term.isEmpty
                    && term.count <= maxKeytermCharacters
                    && term.split(whereSeparator: \.isWhitespace).count <= maxKeytermWords
                    && !term.contains(where: disallowedKeytermCharacters.contains)
            }
        return Array(terms.prefix(maxKeyterms))
    }

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

        let fields = Self.formFields(model: model, language: language, vocabulary: vocabulary)

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: fileURL.lastPathComponent, mimeType: "audio/wav", data: audioData)
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
