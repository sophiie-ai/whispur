import AVFoundation
import Foundation
import os

private let realtimeLogger = Logger(subsystem: "ai.sophiie.whispur", category: "OpenAIRealtimeSTT")

/// Streams microphone audio to OpenAI Realtime transcription and accumulates
/// transcript deltas until recording ends.
actor OpenAIRealtimeTranscriptionSession {
    private let apiKey: String
    private let baseURL: String
    private let transcriptionModel: String
    private let onPartialTranscript: @Sendable (String) -> Void
    private let onError: @Sendable (String) -> Void
    private let urlSession: URLSession
    private let encoder = RealtimePCM16Encoder()

    private var webSocket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var itemOrder: [String] = []
    private var transcriptsByItemID: [String: String] = [:]
    private var isConnected = false
    private var isFinishing = false
    private var terminalError: Error?

    init(
        apiKey: String,
        baseURL: String = "https://api.openai.com/v1",
        transcriptionModel: String = "gpt-realtime-whisper",
        onPartialTranscript: @escaping @Sendable (String) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.transcriptionModel = transcriptionModel
        self.onPartialTranscript = onPartialTranscript
        self.onError = onError

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        self.urlSession = URLSession(configuration: configuration)
    }

    func connect(language: STTLanguageSelection, vocabulary: [String]) async throws {
        guard webSocket == nil else { return }
        guard let url = makeRealtimeURL() else {
            throw STTError.apiError(provider: .openaiRealtime, message: "Invalid Realtime endpoint URL.", statusCode: nil)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let task = urlSession.webSocketTask(with: request)
        webSocket = task
        task.resume()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            await self.receiveLoop()
        }

        try await sendSessionUpdate(language: language, vocabulary: vocabulary)
        isConnected = true
        realtimeLogger.info("Connected to OpenAI Realtime transcription with transcriptionModel=\(self.transcriptionModel, privacy: .public)")
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) async {
        guard isConnected, !isFinishing else { return }
        guard terminalError == nil else { return }

        do {
            let pcmData = try encoder.encode(buffer)
            guard !pcmData.isEmpty else { return }
            try await sendJSON([
                "type": "input_audio_buffer.append",
                "audio": pcmData.base64EncodedString()
            ])
        } catch is CancellationError {
            return
        } catch {
            realtimeLogger.error("Failed to append realtime audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func finish() async throws -> String {
        if let terminalError { throw terminalError }
        guard isConnected else { return transcript }
        isFinishing = true

        // Force any trailing speech out of the input buffer. If server VAD
        // already committed the final turn, the server may reject this; the
        // transcript accumulated so far is still usable.
        do {
            try await sendJSON(["type": "input_audio_buffer.commit"])
        } catch {
            realtimeLogger.info("Realtime commit skipped or rejected: \(error.localizedDescription, privacy: .public)")
        }

        try? await Task.sleep(for: .milliseconds(1_200))
        if let terminalError { throw terminalError }
        close()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        isFinishing = true
        close()
    }

    private func close() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        isConnected = false
    }

    private var transcript: String {
        itemOrder
            .compactMap { transcriptsByItemID[$0] }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeRealtimeURL() -> URL? {
        Self.realtimeURL(baseURL: baseURL)
    }

    nonisolated static func realtimeURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/realtime"
        components.queryItems = [URLQueryItem(name: "intent", value: "transcription")]
        return components.url
    }

    private func sendSessionUpdate(language: STTLanguageSelection, vocabulary: [String]) async throws {
        try await sendJSON(Self.sessionUpdatePayload(
            transcriptionModel: transcriptionModel,
            language: language,
            vocabulary: vocabulary
        ))
    }

    nonisolated static func sessionUpdatePayload(
        transcriptionModel: String,
        language: STTLanguageSelection,
        vocabulary: [String]
    ) -> [String: Any] {
        var transcription: [String: Any] = ["model": transcriptionModel]
        if let languageCode = STTLanguageResolver.iso639_1(for: language) {
            transcription["language"] = languageCode
        }

        let keywords = vocabulary
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(60)
            .joined(separator: ", ")
        if !keywords.isEmpty {
            transcription["prompt"] = "Keywords: \(keywords)"
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let webSocket else { throw URLError(.notConnectedToInternet) }
        let data = try JSONSerialization.data(withJSONObject: object)
        let string = String(decoding: data, as: UTF8.self)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            webSocket.send(.string(string)) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            do {
                guard let webSocket else { return }
                let message = try await receiveMessage(from: webSocket)
                try handle(message: message)
            } catch is CancellationError {
                return
            } catch {
                if !isFinishing {
                    realtimeLogger.error("Realtime receive loop ended: \(error.localizedDescription, privacy: .public)")
                    fail(with: error)
                }
                return
            }
        }
    }

    private func receiveMessage(from webSocket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            webSocket.receive { result in
                switch result {
                case .success(let message):
                    continuation.resume(returning: message)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let string):
            data = Data(string.utf8)
        @unknown default:
            return
        }

        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "conversation.item.input_audio_transcription.delta":
            guard let itemID = event["item_id"] as? String,
                  let delta = event["delta"] as? String
            else { return }
            append(delta: delta, itemID: itemID)
        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event["item_id"] as? String,
                  let completed = event["transcript"] as? String
            else { return }
            set(transcript: completed, itemID: itemID)
        case "error":
            let message = Self.errorMessage(from: event) ?? String(decoding: data, as: UTF8.self)
            realtimeLogger.error("OpenAI Realtime error: \(message, privacy: .public)")
            fail(with: STTError.apiError(provider: .openaiRealtime, message: message, statusCode: nil))
        default:
            break
        }
    }

    private func fail(with error: Error) {
        guard terminalError == nil else { return }
        terminalError = error
        onError(error.localizedDescription)
        close()
    }

    private static func errorMessage(from event: [String: Any]) -> String? {
        if let message = event["message"] as? String {
            return message
        }
        if let error = event["error"] as? [String: Any] {
            let message = error["message"] as? String
            let code = error["code"] as? String
            switch (message, code) {
            case let (.some(message), .some(code)) where !code.isEmpty:
                return "\(message) (\(code))"
            case let (.some(message), _):
                return message
            case let (_, .some(code)):
                return code
            default:
                return nil
            }
        }
        return nil
    }

    private func append(delta: String, itemID: String) {
        if transcriptsByItemID[itemID] == nil {
            itemOrder.append(itemID)
            transcriptsByItemID[itemID] = ""
        }
        transcriptsByItemID[itemID, default: ""] += delta
        publishPartialTranscript()
    }

    private func set(transcript completed: String, itemID: String) {
        if transcriptsByItemID[itemID] == nil {
            itemOrder.append(itemID)
        }
        transcriptsByItemID[itemID] = completed
        publishPartialTranscript()
    }

    private func publishPartialTranscript() {
        let current = transcript
        guard !current.isEmpty else { return }
        onPartialTranscript(current)
    }
}

private final class RealtimePCM16Encoder {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 24_000,
        channels: 1,
        interleaved: true
    )!

    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
        let converter = try converter(for: buffer.format)
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return Data()
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }

        guard status != .error else {
            throw STTError.invalidAudioFormat
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
            return Data()
        }
        return Data(bytes: bytes, count: Int(audioBuffer.mDataByteSize))
    }

    private func converter(for format: AVAudioFormat) throws -> AVAudioConverter {
        if let converter, inputFormat == format {
            return converter
        }

        guard let newConverter = AVAudioConverter(from: format, to: outputFormat) else {
            throw STTError.invalidAudioFormat
        }
        inputFormat = format
        converter = newConverter
        return newConverter
    }
}
