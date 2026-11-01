import AVFoundation
import XCTest
@testable import Whispur

/// In-memory socket. `respond` sees every sent frame and may push replies.
final class FakeStreamSocket: STTStreamSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [STTSocketMessage] = []
    private let inbox: AsyncThrowingStream<STTSocketMessage, Error>
    private let inboxInput: AsyncThrowingStream<STTSocketMessage, Error>.Continuation
    private var iterator: AsyncThrowingStream<STTSocketMessage, Error>.AsyncIterator
    var respond: ((STTSocketMessage, FakeStreamSocket) -> Void)?
    private(set) var opened = false
    private(set) var closed = false

    init() {
        (inbox, inboxInput) = AsyncThrowingStream.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var sent: [STTSocketMessage] { lock.withLock { _sent } }

    func push(_ message: STTSocketMessage) { inboxInput.yield(message) }
    func drop() { inboxInput.finish(throwing: URLError(.networkConnectionLost)) }

    func open() { opened = true }

    func send(_ message: STTSocketMessage) async throws {
        lock.withLock { _sent.append(message) }
        respond?(message, self)
    }

    func receive() async throws -> STTSocketMessage {
        guard let message = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        return message
    }

    func close() {
        closed = true
        inboxInput.finish()
    }
}

private func json(_ message: STTSocketMessage) -> [String: Any] {
    guard case let .text(text) = message else { return [:] }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

private func text(_ object: [String: Any]) -> STTSocketMessage {
    let data = try! JSONSerialization.data(withJSONObject: object)
    return .text(String(data: data, encoding: .utf8)!)
}

final class STTStreamingTests: XCTestCase {

    private func elevenLabsSession(_ socket: FakeStreamSocket, chunkBytes: Int = 8) -> STTStreamingSession {
        STTStreamingSession(
            providerID: .elevenlabs,
            endpointDescription: "test",
            format: ElevenLabsRealtimeFormat(),
            socket: socket,
            chunkBytes: chunkBytes
        )
    }

    // MARK: - Session

    func testCommitReplyCompletesTheSessionWithAllCommittedText() async throws {
        let socket = FakeStreamSocket()
        socket.respond = { message, socket in
            if json(message)["commit"] as? Bool == true {
                socket.push(text(["message_type": "partial_transcript", "text": "world"]))
                socket.push(text(["message_type": "committed_transcript", "text": " world. "]))
            }
        }
        let session = elevenLabsSession(socket)
        session.start()
        socket.push(text(["message_type": "session_started", "session_id": "s"]))
        session.append(Data(repeating: 1, count: 20))
        session.append(Data(repeating: 2, count: 6))

        let result = try await session.finish(timeout: .seconds(2))
        XCTAssertEqual(result, "world.")
        XCTAssertTrue(socket.opened)
        XCTAssertTrue(socket.closed)

        let frames = socket.sent.map(json)
        XCTAssertEqual(frames.filter { $0["commit"] as? Bool == true }.count, 1, "Exactly one commit")
        XCTAssertEqual(frames.last?["commit"] as? Bool, true, "The commit rides on the last chunk")
        let bytes = frames.compactMap { ($0["audio_base_64"] as? String).flatMap { Data(base64Encoded: $0) } }
        XCTAssertEqual(bytes.reduce(0) { $0 + $1.count }, 26, "Every byte is sent once, in order")
        XCTAssertEqual(bytes.dropLast().map(\.count), Array(repeating: 8, count: bytes.count - 1))
        XCTAssertEqual(frames.first?["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(session.state, .completed("world."))
    }

    func testProviderErrorFailsFinishImmediately() async {
        let socket = FakeStreamSocket()
        let session = elevenLabsSession(socket)
        session.start()
        socket.push(text(["message_type": "auth_error", "error": "bad key"]))
        try? await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await session.finish(timeout: .seconds(5))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? STTStreamingError, .provider("auth_error: bad key"))
        }
        XCTAssertTrue(socket.closed)
    }

    func testDroppedConnectionFailsFinish() async {
        let socket = FakeStreamSocket()
        let session = elevenLabsSession(socket)
        session.start()
        session.append(Data(repeating: 1, count: 32))
        socket.drop()
        try? await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await session.finish(timeout: .seconds(5))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? STTStreamingError, .closed)
        }
    }

    func testMissingFinalTranscriptTimesOut() async {
        let socket = FakeStreamSocket()
        let session = elevenLabsSession(socket)
        session.start()
        session.append(Data(repeating: 1, count: 16))

        let started = ContinuousClock.now
        do {
            _ = try await session.finish(timeout: .milliseconds(200))
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? STTStreamingError, .timedOut)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertTrue(socket.closed)
    }

    func testEmptyFinalTranscriptFails() async {
        let socket = FakeStreamSocket()
        socket.respond = { message, socket in
            if json(message)["commit"] as? Bool == true {
                socket.push(text(["message_type": "committed_transcript", "text": "  "]))
            }
        }
        let session = elevenLabsSession(socket)
        session.start()
        session.append(Data(repeating: 1, count: 16))
        do {
            _ = try await session.finish(timeout: .seconds(2))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? STTStreamingError, .emptyTranscript)
        }
    }

    func testCancelFailsPendingFinishAndClosesTheSocket() async {
        let socket = FakeStreamSocket()
        let session = elevenLabsSession(socket)
        session.start()
        session.cancel()
        do {
            _ = try await session.finish(timeout: .seconds(2))
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? STTStreamingError, .cancelled)
        }
        XCTAssertTrue(socket.closed)
    }

    func testReadyGatedFormatHoldsAudioUntilTheHandshakeIsAccepted() async throws {
        let socket = FakeStreamSocket()
        let format = HandshakeFormat()
        socket.respond = { message, socket in
            if message == .text("end") {
                socket.push(.text("final:all of it"))
            }
        }
        let session = STTStreamingSession(providerID: .elevenlabs, endpointDescription: "t", format: format, socket: socket, chunkBytes: 4)
        session.start()
        session.append(Data(repeating: 1, count: 12))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(socket.sent, [.text("hello")], "No audio before the handshake reply")

        socket.push(.text("ready"))
        let result = try await session.finish(timeout: .seconds(2))
        XCTAssertEqual(result, "all of it")
        XCTAssertEqual(socket.sent.first, .text("hello"))
        XCTAssertEqual(socket.sent.last, .text("end"))
        XCTAssertEqual(socket.sent.filter { if case .data = $0 { true } else { false } }.count, 3)
    }

    // MARK: - ElevenLabs format

    func testLiveWordsAreTheCommittedSegmentsPlusTheInterimText() {
        let session = elevenLabsSession(FakeStreamSocket())
        var live: [String] = []
        session.onPartial = { live.append($0) }
        session.handle(.partial("can we"))
        session.handle(.partial(" can we push "))
        session.handle(.committed("Can we push the review?"))
        session.handle(.partial("to Thursday"))
        session.handle(.partial("  "))
        XCTAssertEqual(live, [
            "can we",
            "can we push",
            "Can we push the review?",
            "Can we push the review? to Thursday",
            "Can we push the review?",
        ])
        XCTAssertEqual(STTStreamingSession.liveText(committed: [], partial: "  "), "")
    }

    func testElevenLabsURLCarriesManualCommitLanguageAndKeyterms() throws {
        let url = try XCTUnwrap(ElevenLabsRealtimeFormat.url(
            language: .single(code: "de-DE"),
            vocabulary: ["Whispur", " ", "Sophiie AI"] + (0 ..< 60).map { "t\($0)" }
        ))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func values(_ name: String) -> [String] { items.filter { $0.name == name }.compactMap(\.value) }
        XCTAssertEqual(url.host, "api.elevenlabs.io")
        XCTAssertEqual(values("model_id"), ["scribe_v2_realtime"])
        XCTAssertEqual(values("audio_format"), ["pcm_16000"])
        XCTAssertEqual(values("commit_strategy"), ["manual"])
        XCTAssertEqual(values("language_code"), ["de"])
        XCTAssertEqual(values("keyterms").count, ElevenLabsRealtimeFormat.maxKeyterms)
        XCTAssertEqual(Array(values("keyterms").prefix(2)), ["Whispur", "Sophiie AI"])

        let auto = try XCTUnwrap(ElevenLabsRealtimeFormat.url(language: .auto, vocabulary: []))
        XCTAssertFalse(auto.absoluteString.contains("language_code"))
        XCTAssertFalse(auto.absoluteString.contains("keyterms"))
    }

    func testElevenLabsEmptyLastChunkStillCarriesTheCommit() {
        let messages = ElevenLabsRealtimeFormat().audioMessages(pcm: Data(), isLast: true)
        let frame = json(messages[0])
        XCTAssertEqual(frame["commit"] as? Bool, true)
        XCTAssertEqual((frame["audio_base_64"] as? String).flatMap { Data(base64Encoded: $0) }?.count, 320)
    }

    func testElevenLabsParse() {
        let format = ElevenLabsRealtimeFormat()
        XCTAssertEqual(format.parse(text(["message_type": "session_started"])), .ready)
        XCTAssertEqual(format.parse(text(["message_type": "partial_transcript", "text": "hi"])), .partial("hi"))
        XCTAssertEqual(format.parse(text(["message_type": "committed_transcript", "text": "Hi."])), .committed("Hi."))
        XCTAssertEqual(format.parse(text(["message_type": "quota_exceeded", "error": "out"])), .failed("quota_exceeded: out"))
        XCTAssertEqual(format.parse(text(["message_type": "warning", "warning": "w"])), .ignored)
        XCTAssertEqual(format.parse(.text("not json")), .ignored)
    }

    func testOnlyStreamingCapableProvidersOfferTheToggle() {
        XCTAssertTrue(STTProviderID.elevenlabs.supportsStreaming)
        XCTAssertTrue(STTProviderID.metaMuse.supportsStreaming)
        XCTAssertFalse(STTProviderID.apple.supportsStreaming)
        XCTAssertFalse(STTProviderID.openai.supportsStreaming)
    }
}

/// A ready-gated, close-frame format like Meta's, for session tests.
private struct HandshakeFormat: STTStreamingWireFormat {
    var waitsForReadyBeforeAudio: Bool { true }
    func openingMessages() -> [STTSocketMessage] { [.text("hello")] }
    func audioMessages(pcm: Data, isLast: Bool) -> [STTSocketMessage] { pcm.isEmpty ? [] : [.data(pcm)] }
    func closingMessages() -> [STTSocketMessage] { [.text("end")] }
    func parse(_ message: STTSocketMessage) -> STTStreamEvent {
        guard case let .text(text) = message else { return .ignored }
        if text == "ready" { return .ready }
        if text.hasPrefix("final:") { return .completed(String(text.dropFirst(6))) }
        return .ignored
    }
}

final class StreamingFallbackTests: XCTestCase {
    @MainActor
    func testStreamedTextIsUsedWithoutABatchRequest() async throws {
        let socket = FakeStreamSocket()
        socket.respond = { message, socket in
            if case let .text(body) = message, body.contains("\"commit\":true") {
                socket.push(.text(#"{"message_type":"committed_transcript","text":"From the stream."}"#))
            }
        }
        let session = STTStreamingSession(providerID: .elevenlabs, endpointDescription: "t", format: ElevenLabsRealtimeFormat(), socket: socket, chunkBytes: 8)
        session.start()
        session.append(Data(repeating: 1, count: 24))

        var batchCalls = 0
        var outcomes: [StreamingFallback.Outcome] = []
        let text = try await StreamingFallback.transcript(
            stream: session,
            timeout: .seconds(2),
            report: { outcomes.append($0) },
            batch: { batchCalls += 1; return "From the file." }
        )
        XCTAssertEqual(text, "From the stream.")
        XCTAssertEqual(batchCalls, 0)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNil(outcomes.first?.error)
    }

    @MainActor
    func testEveryStreamFailureFallsBackToTheRecording() async throws {
        let failures: [(String, (FakeStreamSocket, STTStreamingSession) -> Void)] = [
            ("dropped", { socket, _ in socket.drop() }),
            ("provider error", { socket, _ in socket.push(.text(#"{"message_type":"rate_limited","error":"slow down"}"#)) }),
            ("no reply", { _, _ in }),
        ]
        for (name, breakIt) in failures {
            let socket = FakeStreamSocket()
            let session = STTStreamingSession(providerID: .elevenlabs, endpointDescription: "t", format: ElevenLabsRealtimeFormat(), socket: socket, chunkBytes: 8)
            session.start()
            session.append(Data(repeating: 1, count: 24))
            breakIt(socket, session)

            var outcomes: [StreamingFallback.Outcome] = []
            let text = try await StreamingFallback.transcript(
                stream: session,
                timeout: .milliseconds(300),
                report: { outcomes.append($0) },
                batch: { "From the file." }
            )
            XCTAssertEqual(text, "From the file.", name)
            XCTAssertNotNil(outcomes.first?.error, name)
        }
    }

    @MainActor
    func testNoStreamGoesStraightToBatch() async throws {
        let text = try await StreamingFallback.transcript(stream: nil, timeout: .seconds(1), batch: { "batch" })
        XCTAssertEqual(text, "batch")
    }

    @MainActor
    func testBatchErrorsStillSurface() async {
        do {
            _ = try await StreamingFallback.transcript(stream: nil, timeout: .seconds(1), batch: { throw STTError.noAudioFile })
            XCTFail("Expected the batch error")
        } catch {
            XCTAssertNotNil(error as? STTError)
        }
    }
}

final class LivePCMConverterTests: XCTestCase {
    func testResamplesFloatTapBuffersToSixteenBitMono() throws {
        let input = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let converter = LivePCMConverter(targetSampleRate: 16_000)
        var total = 0
        var peak: Int16 = 0
        for index in 0 ..< 30 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0 ..< 2 {
                let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
                for frame in 0 ..< 4800 {
                    let t = Double(index * 4800 + frame) / 48_000
                    samples[frame] = Float(0.5 * sin(2 * .pi * 440 * t))
                }
            }
            let data = converter.convert(buffer)
            XCTAssertEqual(data.count % 2, 0)
            total += data.count / 2
            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) { peak = max(peak, abs(sample)) }
            }
        }
        // Three seconds at 48 kHz become about three seconds at 16 kHz. The
        // resampler holds back a few ms of priming, a constant offset.
        XCTAssertEqual(Double(total), 48_000, accuracy: 200)
        XCTAssertGreaterThan(peak, 8_000, "A half-scale tone stays audible after conversion")
    }
}

final class StreamingCancellationTests: XCTestCase {
    @MainActor
    func testCancellingTheDictationClosesTheStreamWithoutFallingBack() async {
        let socket = FakeStreamSocket()
        let session = STTStreamingSession(providerID: .elevenlabs, endpointDescription: "t", format: ElevenLabsRealtimeFormat(), socket: socket, chunkBytes: 8)
        session.start()
        session.append(Data(repeating: 1, count: 24))

        var batchCalls = 0
        let task = Task { @MainActor in
            try await StreamingFallback.transcript(stream: session, timeout: .seconds(10), batch: {
                batchCalls += 1
                return "batch"
            })
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let started = ContinuousClock.now
        let result = await task.result
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(batchCalls, 0)
        XCTAssertTrue(socket.closed)
    }
}

final class MetaMuseTests: XCTestCase {
    private func object(_ message: STTSocketMessage?) -> [String: Any] {
        guard case let .text(text)? = message else { return [:] }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }

    func testHandshakeCarriesCredentialModeAndBiasing() {
        let format = MetaMuseRealtimeFormat(apiKey: "k", language: .single(code: "fr-FR"), vocabulary: ["Whispur", " "])
        let handshake = object(format.openingMessages().first)
        XCTAssertEqual(handshake["mode"] as? String, "PUSH_TO_TALK")
        XCTAssertEqual((handshake["authorization"] as? [String: String])?["accessToken"], "Bearer k")
        XCTAssertEqual(handshake["audioEncoding"] as? String, "PCM_16KHZ")
        XCTAssertEqual(handshake["model"] as? String, "muse-voice-transcribe-1.0")
        XCTAssertEqual(handshake["partialMode"] as? String, "CUMULATIVE")
        XCTAssertEqual(handshake["keywords"] as? [String], ["Whispur"])
        XCTAssertEqual(handshake["languageBias"] as? [String], ["French"])
        XCTAssertTrue(format.waitsForReadyBeforeAudio)
        XCTAssertEqual(format.closingMessages(), [.text(#"{"type":"endStream"}"#)])
    }

    func testAutoLanguageAndEmptyVocabularySendNoBiasing() {
        let handshake = object(MetaMuseRealtimeFormat(apiKey: "k", language: .auto, vocabulary: []).openingMessages().first)
        XCTAssertNil(handshake["keywords"])
        XCTAssertNil(handshake["languageBias"])
    }

    func testAudioIsSentAsBinaryFrames() {
        let format = MetaMuseRealtimeFormat(apiKey: "k", language: .auto, vocabulary: [])
        XCTAssertEqual(format.audioMessages(pcm: Data([1, 2]), isLast: false), [.data(Data([1, 2]))])
        XCTAssertEqual(format.audioMessages(pcm: Data(), isLast: true), [])
    }

    func testParse() {
        let format = MetaMuseRealtimeFormat(apiKey: "k", language: .auto, vocabulary: [])
        XCTAssertEqual(format.parse(.text(#"{"sessionId":"abc"}"#)), .ready)
        XCTAssertEqual(format.parse(.text(#"{"type":"transcript","transcript":"hel","final":false}"#)), .partial("hel"))
        XCTAssertEqual(format.parse(.text(#"{"type":"transcript","transcript":"hello.","final":true}"#)), .completed("hello."))
        XCTAssertEqual(format.parse(.text(#"{"type":"error","message":"bad token","sessionId":""}"#)), .failed("bad token"))
        XCTAssertEqual(format.parse(.text(#"{"type":"speechStart","turnId":1}"#)), .ignored)
        XCTAssertEqual(format.parse(.data(Data([0]))), .ignored)
    }

    func testPushToTalkSessionEndsOnTheFinalTranscript() async throws {
        let socket = FakeStreamSocket()
        socket.respond = { message, socket in
            if case let .text(body) = message, body.contains("authorization") {
                socket.push(.text(#"{"sessionId":"s1"}"#))
            }
            if message == .text(#"{"type":"endStream"}"#) {
                socket.push(.text(#"{"type":"transcript","transcript":"Ship it.","final":false}"#))
                socket.push(.text(#"{"type":"transcript","transcript":"Ship it Friday.","final":true}"#))
            }
        }
        let session = STTStreamingSession(
            providerID: .metaMuse,
            endpointDescription: "t",
            format: MetaMuseRealtimeFormat(apiKey: "k", language: .auto, vocabulary: []),
            socket: socket,
            chunkBytes: 4
        )
        var partials: [String] = []
        session.onPartial = { partials.append($0) }
        session.start()
        session.append(Data(repeating: 7, count: 10))

        let text = try await session.finish(timeout: .seconds(2))
        XCTAssertEqual(text, "Ship it Friday.")
        XCTAssertEqual(partials, ["Ship it."])
        let audio = socket.sent.compactMap { if case let .data(data) = $0 { data } else { nil } }
        XCTAssertEqual(audio.reduce(0) { $0 + $1.count }, 10)
    }

    func testBatchRequestPartAndResponse() throws {
        let request = try XCTUnwrap(JSONSerialization.jsonObject(
            with: MetaMuseSTT.requestJSON(language: .single(code: "en-GB"), vocabulary: ["Whispur"])
        ) as? [String: Any])
        XCTAssertEqual(request["mode"] as? String, "PUSH_TO_TALK")
        XCTAssertEqual(request["audioEncoding"] as? String, "WAV")
        XCTAssertEqual(request["model"] as? String, MetaMuseSTT.model)
        XCTAssertEqual(request["languageBias"] as? [String], ["English"])
        XCTAssertEqual(request["keywords"] as? [String], ["Whispur"])

        let body = #"{"sessionId":"x","transcript":" Hello there. ","audioDurationMs":6800,"turns":[]}"#
        XCTAssertEqual(MetaMuseSTT.parseTranscript(Data(body.utf8)), "Hello there.")
        XCTAssertEqual(STTProviderID.metaMuse.keychainKeys, [.metaAPIKey])
        XCTAssertEqual(KeychainKey.metaAPIKey.rawValue, "meta-api-key")
    }
}
