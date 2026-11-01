import Foundation

/// ElevenLabs Scribe realtime (`scribe_v2_realtime`) in manual commit mode:
/// audio goes up as base64 PCM chunks, the last chunk carries
/// `commit: true`, and the reply is a `committed_transcript`.
struct ElevenLabsRealtimeFormat: STTStreamingWireFormat {
    static let model = "scribe_v2_realtime"
    static let sampleRate = 16_000
    static let maxKeyterms = 50

    let sampleRate: Int

    init(sampleRate: Int = ElevenLabsRealtimeFormat.sampleRate) {
        self.sampleRate = sampleRate
    }

    static func url(language: STTLanguageSelection, vocabulary: [String]) -> URL? {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")
        var query = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        if let code = STTLanguageResolver.iso639_1(for: language) {
            query.append(URLQueryItem(name: "language_code", value: code))
        }
        let terms = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(maxKeyterms)
        for term in terms {
            query.append(URLQueryItem(name: "keyterms", value: term))
        }
        components?.queryItems = query
        return components?.url
    }

    var waitsForReadyBeforeAudio: Bool { false }

    func openingMessages() -> [STTSocketMessage] { [] }

    func audioMessages(pcm: Data, isLast: Bool) -> [STTSocketMessage] {
        // A commit needs a chunk to ride on. When the recording ends exactly
        // on a chunk boundary, send 10 ms of silence with the commit.
        let audio = (isLast && pcm.isEmpty) ? Data(count: sampleRate / 100 * 2) : pcm
        let payload: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": audio.base64EncodedString(),
            "commit": isLast,
            "sample_rate": sampleRate,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return [.text(text)]
    }

    func closingMessages() -> [STTSocketMessage] { [] }

    private static let errorTypes: Set<String> = [
        "error", "auth_error", "quota_exceeded", "commit_throttled", "unaccepted_terms",
        "rate_limited", "queue_overflow", "resource_exhausted", "session_time_limit_exceeded",
        "input_error", "invalid_request", "chunk_size_exceeded", "insufficient_audio_activity",
        "transcriber_error",
    ]

    func parse(_ message: STTSocketMessage) -> STTStreamEvent {
        guard case let .text(text) = message,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = json["message_type"] as? String
        else { return .ignored }

        switch type {
        case "session_started":
            return .ready
        case "partial_transcript":
            return .partial(json["text"] as? String ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            return .committed(json["text"] as? String ?? "")
        default:
            if Self.errorTypes.contains(type) {
                let detail = json["error"] as? String ?? json["message"] as? String ?? type
                return .failed("\(type): \(detail)")
            }
            return .ignored
        }
    }
}

extension ElevenLabsSTT: STTStreamingProvider {
    var streamingSampleRate: Double { Double(ElevenLabsRealtimeFormat.sampleRate) }

    func makeStreamingSession(language: STTLanguageSelection, vocabulary: [String]) -> STTStreamingSession {
        let format = ElevenLabsRealtimeFormat()
        let url = ElevenLabsRealtimeFormat.url(language: language, vocabulary: vocabulary)
            ?? URL(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var request = URLRequest(url: url)
        request.setValue(streamingAPIKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        return STTStreamingSession(
            providerID: .elevenlabs,
            endpointDescription: "wss://api.elevenlabs.io/v1/speech-to-text/realtime (\(ElevenLabsRealtimeFormat.model))",
            format: format,
            socket: URLSessionStreamSocket(request: request),
            // 100 ms per chunk.
            chunkBytes: ElevenLabsRealtimeFormat.sampleRate / 10 * 2
        )
    }
}
