import Foundation

/// Meta Muse Voice Transcribe. Batch requests go to `/v1/asr/transcribe`
/// as a JSON `request` part plus the WAV; live streaming uses the realtime
/// WebSocket in push-to-talk mode (see `MetaMuseRealtimeFormat`).
struct MetaMuseSTT: STTProvider {
    static let providerID: STTProviderID = .metaMuse
    static let model = "muse-voice-transcribe-1.0"
    static let endpoint = "https://api.meta.ai/v1/asr/transcribe"
    static let maxKeywords = 50

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let timeoutSeconds: TimeInterval

    init(apiKey: String, httpClient: ProviderHTTPClient, timeoutSeconds: TimeInterval = 30) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.timeoutSeconds = timeoutSeconds
    }

    var streamingAPIKey: String { apiKey }

    /// Biasing shared by the batch request and the realtime handshake.
    /// `languageBias` takes language names ("English"), not codes.
    static func biasing(language: STTLanguageSelection, vocabulary: [String]) -> [String: Any] {
        var fields: [String: Any] = [:]
        let keywords = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxKeywords)
        if !keywords.isEmpty {
            fields["keywords"] = Array(keywords)
        }
        let names = languageNames(for: language)
        if !names.isEmpty {
            fields["languageBias"] = names
        }
        return fields
    }

    /// Every language the user speaks, as English names. `languageBias`
    /// takes several and steers toward them without forcing one.
    static func languageNames(for selection: STTLanguageSelection) -> [String] {
        selection.isoCodes.compactMap { Locale(identifier: "en_US").localizedString(forLanguageCode: $0) }
    }

    /// The JSON `request` part for a batch call.
    static func requestJSON(language: STTLanguageSelection, vocabulary: [String]) -> Data {
        var request: [String: Any] = [
            "mode": "PUSH_TO_TALK",
            "model": model,
            "audioEncoding": "WAV",
        ]
        request.merge(biasing(language: language, vocabulary: vocabulary)) { _, new in new }
        return (try? JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])) ?? Data()
    }

    static func parseTranscript(_ data: Data) -> String {
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        guard let url = URL(string: Self.endpoint) else {
            throw STTError.apiError(provider: .metaMuse, message: "Invalid endpoint URL.", statusCode: nil)
        }
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeoutSeconds

        let requestJSON = Self.requestJSON(language: language, vocabulary: vocabulary)
        let audioData = try Data(contentsOf: fileURL)
        var body = Data()
        body.appendMultipart(boundary: boundary, name: "request", mimeType: "application/json", data: requestJSON)
        body.appendMultipart(boundary: boundary, name: "audio", filename: "audio.wav", mimeType: "audio/wav", data: audioData)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        do {
            let response = try await httpClient.send(
                request,
                providerID: Self.providerID.rawValue,
                kind: .stt,
                requestBodySummary: """
                multipart form-data
                request: \(String(data: requestJSON, encoding: .utf8) ?? "-")
                audio: \(fileURL.lastPathComponent) (audio/wav, \(audioData.count) bytes)
                """
            )

            guard (200 ... 299).contains(response.response.statusCode) else {
                throw STTError.apiError(
                    provider: .metaMuse,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }

            return Self.parseTranscript(response.data)
        } catch let error as STTError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw STTError.timeout(provider: .metaMuse)
        } catch {
            throw STTError.apiError(
                provider: .metaMuse,
                message: ProviderHTTPClient.transportErrorMessage(for: error),
                statusCode: nil
            )
        }
    }
}
