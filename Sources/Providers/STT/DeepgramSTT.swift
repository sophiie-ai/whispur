import Foundation

/// Deepgram speech-to-text provider.
struct DeepgramSTT: STTProvider {
    static let providerID: STTProviderID = .deepgram

    private let apiKey: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        model: String = "nova-3",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
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
        request.httpBody = try Data(contentsOf: fileURL)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw STTError.apiError(provider: .deepgram, message: message, statusCode: httpResponse.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let results = json?["results"] as? [String: Any]
        let channels = results?["channels"] as? [[String: Any]]
        let alternatives = channels?.first?["alternatives"] as? [[String: Any]]
        let transcript = alternatives?.first?["transcript"] as? String ?? ""

        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
