import Foundation

/// Groq Whisper Large v3 speech-to-text provider.
///
/// Uses Groq's OpenAI-compatible `/audio/transcriptions` endpoint. The response
/// is returned as raw text (not JSON) to match the shape expected by the pipeline.
struct GroqWhisperSTT: STTProvider {
    static let providerID: STTProviderID = .groqWhisper

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        baseURL: String = "https://api.groq.com/openai/v1",
        model: String = "whisper-large-v3",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw STTError.apiError(provider: .groqWhisper, message: "Invalid endpoint URL.", statusCode: nil)
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
        body.appendMultipart(boundary: boundary, name: "model", value: model)
        body.appendMultipart(boundary: boundary, name: "response_format", value: "text")
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
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .groqWhisper,
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
            throw STTError.timeout(provider: .groqWhisper)
        } catch {
            throw STTError.apiError(
                provider: .groqWhisper,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
