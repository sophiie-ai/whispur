import Foundation

/// Groq-hosted Whisper speech-to-text provider (Large v3 or Large v3 Turbo).
/// Groq bills every request as at least 10 seconds of audio.
///
/// Uses Groq's OpenAI-compatible `/audio/transcriptions` endpoint. The response
/// is returned as raw text (not JSON) to match the shape expected by the pipeline;
/// script-guard re-runs ask for `verbose_json` to read the confidence.
struct GroqWhisperSTT: STTProvider {
    static let providerID: STTProviderID = .groqWhisper
    static let defaultModel = "whisper-large-v3"

    private let apiKey: String
    private let httpClient: ProviderHTTPClient
    private let baseURL: String
    private let model: String
    private let timeoutSeconds: TimeInterval

    init(
        apiKey: String,
        httpClient: ProviderHTTPClient,
        baseURL: String = "https://api.groq.com/openai/v1",
        model: String = GroqWhisperSTT.defaultModel,
        timeoutSeconds: TimeInterval = 30
    ) {
        self.apiKey = apiKey
        self.httpClient = httpClient
        self.baseURL = baseURL
        self.model = model
        self.timeoutSeconds = timeoutSeconds
    }

    /// Text fields for one request, file part excluded. Groq's endpoint is
    /// OpenAI-compatible: one ISO-639-1 `language`, or none for auto-detect.
    /// `verbose_json` adds per-segment `avg_logprob`, which the script guard
    /// uses to pick between forced re-runs.
    static func formFields(model: String, language: STTLanguageSelection, vocabulary: [String], verbose: Bool = false) -> [MultipartFormField] {
        var fields = [
            MultipartFormField(name: "model", value: model),
            MultipartFormField(name: "response_format", value: verbose ? "verbose_json" : "text"),
        ]
        if let code = STTLanguageResolver.iso639_1(for: language) {
            fields.append(MultipartFormField(name: "language", value: code))
        }
        if let prompt = WhisperVocabularyPrompt.build(from: vocabulary) {
            fields.append(MultipartFormField(name: "prompt", value: prompt))
        }
        return fields
    }

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        let data = try await send(fileURL: fileURL, fields: Self.formFields(model: model, language: language, vocabulary: vocabulary))
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func transcribeScored(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> ScoredTranscript {
        let data = try await send(fileURL: fileURL, fields: Self.formFields(model: model, language: language, vocabulary: vocabulary, verbose: true))
        return WhisperVerboseTranscript.parse(data)
    }

    private func send(fileURL: URL, fields: [MultipartFormField]) async throws -> Data {
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
                    provider: .groqWhisper,
                    message: response.errorMessage ?? "The provider rejected the transcription request.",
                    statusCode: response.response.statusCode
                )
            }
            return response.data
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

/// Whisper's `verbose_json` response (OpenAI `whisper-1`, Groq).
enum WhisperVerboseTranscript {
    /// The text plus a confidence: segment `avg_logprob` averaged by segment
    /// duration (by count when durations are missing). Nil confidence when
    /// there are no segments.
    static func parse(_ data: Data) -> ScoredTranscript {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ScoredTranscript(text: text, confidence: nil)
        }
        let text = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = json["segments"] as? [[String: Any]] ?? []
        var weighted = 0.0
        var totalWeight = 0.0
        for segment in segments {
            guard let logprob = (segment["avg_logprob"] as? NSNumber)?.doubleValue else { continue }
            let start = (segment["start"] as? NSNumber)?.doubleValue ?? 0
            let end = (segment["end"] as? NSNumber)?.doubleValue ?? 0
            let weight = end > start ? end - start : 1
            weighted += logprob * weight
            totalWeight += weight
        }
        return ScoredTranscript(text: text, confidence: totalWeight > 0 ? weighted / totalWeight : nil)
    }
}
