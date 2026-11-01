import Foundation

/// OpenAI speech-to-text provider (`/audio/transcriptions`).
///
/// `gpt-transcribe` takes vocabulary as `keywords[]` and language hints as
/// `languages[]`. The older models (`whisper-1`, `gpt-4o-*-transcribe`, and
/// whatever a compatible gateway serves) take a single `language` and a
/// free-text `prompt`.
struct OpenAISTT: STTProvider {
    static let providerID: STTProviderID = .openai
    static let defaultModel = "gpt-transcribe"
    static let defaultBaseURL = "https://api.openai.com/v1"

    /// Keyword hints sent to `gpt-transcribe`. The API documents no limit, so
    /// stay in line with the other providers' biasing caps.
    static let maxKeywords = 50

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        baseURL: String = OpenAISTT.defaultBaseURL,
        model: String = OpenAISTT.defaultModel,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// True for models that use the `keywords` / `languages` request shape.
    static func usesKeywordShape(model: String) -> Bool {
        model == "gpt-transcribe" || model.hasPrefix("gpt-transcribe-")
    }

    /// The text fields for one request, in send order (the file part is
    /// added separately). No `response_format` is sent by default: every
    /// model returns JSON with a `text` field.
    ///
    /// `gpt-transcribe` gets every language the user speaks as `languages[]`
    /// ("possible languages", a hint). The older models take one `language`,
    /// so with several they auto-detect and the script guard checks the
    /// result. `verbose` asks those models for `verbose_json` so a guard
    /// re-run can read the confidence; `gpt-transcribe` has no such format.
    static func formFields(model: String, language: STTLanguageSelection, vocabulary: [String], verbose: Bool = false) -> [MultipartFormField] {
        var fields = [MultipartFormField(name: "model", value: model)]

        if usesKeywordShape(model: model) {
            for code in language.isoCodes {
                fields.append(MultipartFormField(name: "languages[]", value: code))
            }
            for keyword in keywords(from: vocabulary) {
                fields.append(MultipartFormField(name: "keywords[]", value: keyword))
            }
        } else {
            if verbose {
                fields.append(MultipartFormField(name: "response_format", value: "verbose_json"))
            }
            if let languageCode = STTLanguageResolver.iso639_1(for: language) {
                fields.append(MultipartFormField(name: "language", value: languageCode))
            }
            if let prompt = WhisperVocabularyPrompt.build(from: vocabulary) {
                fields.append(MultipartFormField(name: "prompt", value: prompt))
            }
        }
        return fields
    }

    /// One keyword per vocabulary term. The API rejects the whole request
    /// when a keyword contains `<`, `>`, or a line break, so those are
    /// stripped rather than risking a failed dictation.
    static func keywords(from vocabulary: [String]) -> [String] {
        let terms = vocabulary.map { term in
            term.unicodeScalars
                .filter { !"<>\r\n".unicodeScalars.contains($0) }
                .reduce(into: "") { $0.unicodeScalars.append($1) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Array(terms.filter { !$0.isEmpty }.prefix(maxKeywords))
    }

    /// Reads `text` from the JSON body. A gateway that ignores the default
    /// and answers in plain text still works.
    static func parseTranscript(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        let data = try await send(fileURL: fileURL, fields: Self.formFields(model: model, language: language, vocabulary: vocabulary))
        return Self.parseTranscript(data)
    }

    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript {
        guard !Self.usesKeywordShape(model: model) else {
            return ScoredTranscript(text: try await transcribe(fileURL: fileURL, language: language, vocabulary: vocabulary), confidence: nil)
        }
        let data = try await send(fileURL: fileURL, fields: Self.formFields(model: model, language: language, vocabulary: vocabulary, verbose: true))
        return WhisperVerboseTranscript.parse(data)
    }

    private func send(fileURL: URL, fields: [MultipartFormField]) async throws -> Data {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw STTError.apiError(provider: .openai, message: "Invalid endpoint URL.", statusCode: nil)
        }
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

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
                    provider: .openai,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            return response.data
        } catch let error as STTError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw STTError.timeout(provider: .openai)
        } catch {
            throw STTError.apiError(
                provider: .openai,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
