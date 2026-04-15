import Foundation

/// OpenAI Whisper API speech-to-text provider.
struct OpenAISTT: STTProvider {
    static let providerID: STTProviderID = .openai

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "whisper-1",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func transcribe(fileURL: URL, languages: [String], vocabulary: [String]) async throws -> String {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw STTError.apiError(provider: .openai, message: "Invalid endpoint URL.", statusCode: nil)
        }
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        // Whisper accepts a single ISO-639-1 `language`. Send it only when the
        // user picked exactly one preferred language; otherwise let Whisper
        // auto-detect across the full language set.
        let languageParam: String? = languages.count == 1
            ? STTLanguage(code: languages[0], displayName: "").iso639_1
            : nil

        let promptParam = WhisperVocabularyPrompt.build(from: vocabulary)

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "text")
        if let languageParam {
            body.appendMultipart(boundary: boundary, name: "language", value: languageParam)
        }
        if let promptParam {
            body.appendMultipart(boundary: boundary, name: "prompt", value: promptParam)
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
                model: \(model)
                response_format: text
                language: \(languageParam ?? "auto")
                prompt: \(promptParam ?? "-")
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .openai,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            let text = String(data: response.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text
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
