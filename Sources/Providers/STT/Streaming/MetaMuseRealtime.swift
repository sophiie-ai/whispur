import Foundation

/// Meta Muse realtime ASR in `PUSH_TO_TALK` mode: a JSON handshake carries
/// the credential and biasing, audio goes up as binary PCM frames, and
/// `{"type":"endStream"}` ends the turn. The `transcript` event with
/// `final: true` is the completion signal.
struct MetaMuseRealtimeFormat: STTStreamingWireFormat {
    static let url = URL(string: "wss://api.meta.ai/v1/asr/realtime")!
    static let sampleRate = 16_000

    let apiKey: String
    let language: STTLanguageSelection
    let vocabulary: [String]

    var waitsForReadyBeforeAudio: Bool { true }

    func handshake() -> [String: Any] {
        var handshake: [String: Any] = [
            "mode": "PUSH_TO_TALK",
            // The Bearer prefix is part of the value.
            "authorization": ["accessToken": "Bearer \(apiKey)"],
            "audioEncoding": "PCM_16KHZ",
            "model": MetaMuseSTT.model,
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false,
        ]
        handshake.merge(MetaMuseSTT.biasing(language: language, vocabulary: vocabulary)) { _, new in new }
        return handshake
    }

    func openingMessages() -> [STTSocketMessage] {
        guard let data = try? JSONSerialization.data(withJSONObject: handshake(), options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return [.text(text)]
    }

    func audioMessages(pcm: Data, isLast: Bool) -> [STTSocketMessage] {
        pcm.isEmpty ? [] : [.data(pcm)]
    }

    func closingMessages() -> [STTSocketMessage] {
        [.text(#"{"type":"endStream"}"#)]
    }

    func parse(_ message: STTSocketMessage) -> STTStreamEvent {
        guard case let .text(text) = message,
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { return .ignored }

        guard let type = json["type"] as? String else {
            // The handshake reply is the only frame without a type.
            return json["sessionId"] != nil ? .ready : .ignored
        }
        switch type {
        case "transcript":
            let transcript = json["transcript"] as? String ?? ""
            return (json["final"] as? Bool ?? false) ? .completed(transcript) : .partial(transcript)
        case "error":
            return .failed(json["message"] as? String ?? "The provider ended the session.")
        default:
            return .ignored
        }
    }
}

extension MetaMuseSTT: STTStreamingProvider {
    var streamingSampleRate: Double { Double(MetaMuseRealtimeFormat.sampleRate) }

    func makeStreamingSession(language: STTLanguageSelection, vocabulary: [String]) -> STTStreamingSession {
        var request = URLRequest(url: MetaMuseRealtimeFormat.url)
        request.timeoutInterval = 10
        return STTStreamingSession(
            providerID: .metaMuse,
            endpointDescription: "\(MetaMuseRealtimeFormat.url.absoluteString) (\(MetaMuseSTT.model))",
            format: MetaMuseRealtimeFormat(apiKey: streamingAPIKey, language: language, vocabulary: vocabulary),
            socket: URLSessionStreamSocket(request: request),
            // 80 ms per frame, the server's processing chunk.
            chunkBytes: MetaMuseRealtimeFormat.sampleRate * 2 * 80 / 1_000
        )
    }
}
