import Foundation

/// ElevenLabs speech-to-text provider (Scribe API).
struct ElevenLabsSTT: STTProvider {
    static let providerID: STTProviderID = .elevenlabs

    private let apiKey: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        model: String = "scribe_v1",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    func transcribe(fileURL: URL) async throws -> String {
        let url = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "audio", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        body.appendMultipart(boundary: boundary, name: "model_id", value: model)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.apiError(provider: .elevenlabs, message: message, statusCode: httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = json?["text"] as? String ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
