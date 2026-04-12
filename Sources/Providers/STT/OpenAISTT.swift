import Foundation

/// OpenAI Whisper API speech-to-text provider.
struct OpenAISTT: STTProvider {
    static let providerID: STTProviderID = .openai

    private let apiKey: String
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1",
        model: String = "whisper-1",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func transcribe(fileURL: URL) async throws -> String {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
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

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.apiError(provider: .openai, message: message, statusCode: httpResponse.statusCode)
        }

        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text
    }
}
