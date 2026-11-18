import AVFoundation
import XCTest
@testable import Whispur

/// Dictation on a flaky connection: quiet retries in the HTTP client, a
/// smaller (lossless) upload, and Parakeet filling in when the cloud
/// provider can't be reached. No real network and no real model.
@MainActor
final class NetworkResilienceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        ScriptedProtocol.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        for provider in STTProviderID.allCases { UploadAudio.clearFLACRejection(for: provider) }
    }

    // MARK: - Retry policy

    func testRetriesADroppedConnectionButNotAnAnswer() {
        let policy = ProviderRetryPolicy.standard
        for code in [URLError.Code.networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            XCTAssertNotNil(policy.delay(afterError: URLError(code), kind: .stt, attempt: 1, elapsed: .zero), "\(code)")
            XCTAssertNotNil(policy.delay(afterError: URLError(code), kind: .llm, attempt: 1, elapsed: .zero), "\(code)")
        }
        // Nothing to wait for, or the user stopped it.
        XCTAssertNil(policy.delay(afterError: URLError(.notConnectedToInternet), kind: .stt, attempt: 1, elapsed: .zero))
        XCTAssertNil(policy.delay(afterError: URLError(.cancelled), kind: .stt, attempt: 1, elapsed: .zero))
        XCTAssertNil(policy.delay(afterError: CancellationError(), kind: .stt, attempt: 1, elapsed: .zero))
        // A provider that answered no would answer no again.
        for status in [400, 401, 403, 404, 413, 415, 422] {
            XCTAssertNil(policy.delay(afterStatus: status, retryAfter: nil, attempt: 1, elapsed: .zero), "\(status)")
        }
        for status in [408, 429, 500, 502, 503, 504] {
            XCTAssertNotNil(policy.delay(afterStatus: status, retryAfter: nil, attempt: 1, elapsed: .zero), "\(status)")
        }
        XCTAssertNil(policy.delay(afterStatus: 200, retryAfter: nil, attempt: 1, elapsed: .zero))
    }

    func testATimedOutUploadGetsOneMoreTryAndCleanupNone() {
        let policy = ProviderRetryPolicy.standard
        XCTAssertNotNil(policy.delay(afterError: URLError(.timedOut), kind: .stt, attempt: 1, elapsed: .zero))
        XCTAssertNil(policy.delay(afterError: URLError(.timedOut), kind: .stt, attempt: 2, elapsed: .zero))
        XCTAssertNil(policy.delay(afterError: URLError(.timedOut), kind: .llm, attempt: 1, elapsed: .zero))
    }

    func testRetriesStopAtTheAttemptCapAndTheTimeBudget() {
        let policy = ProviderRetryPolicy.standard
        let lost = URLError(.networkConnectionLost)
        XCTAssertEqual(policy.delay(afterError: lost, kind: .stt, attempt: 1, elapsed: .zero), .milliseconds(400))
        XCTAssertEqual(policy.delay(afterError: lost, kind: .stt, attempt: 2, elapsed: .zero), .milliseconds(1_200))
        XCTAssertNil(policy.delay(afterError: lost, kind: .stt, attempt: 3, elapsed: .zero))
        XCTAssertNil(policy.delay(afterError: lost, kind: .stt, attempt: 1, elapsed: .seconds(61)))
        // Cleanup gives up sooner: the raw transcript is waiting to paste.
        XCTAssertNotNil(policy.delay(afterError: lost, kind: .stt, attempt: 1, elapsed: .seconds(11)))
        XCTAssertNil(policy.delay(afterError: lost, kind: .llm, attempt: 1, elapsed: .seconds(11)))
        XCTAssertNil(policy.delay(afterStatus: 503, retryAfter: nil, kind: .llm, attempt: 1, elapsed: .seconds(11)))
    }

    func testHonoursAShortRetryAfterAndGivesUpOnALongOne() {
        let policy = ProviderRetryPolicy.standard
        XCTAssertEqual(policy.delay(afterStatus: 429, retryAfter: "2", attempt: 1, elapsed: .zero), .seconds(2))
        XCTAssertEqual(policy.delay(afterStatus: 429, retryAfter: "0", attempt: 1, elapsed: .zero), .milliseconds(400))
        XCTAssertNil(policy.delay(afterStatus: 429, retryAfter: "30", attempt: 1, elapsed: .zero))
        XCTAssertNotNil(policy.delay(afterStatus: 503, retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", attempt: 1, elapsed: .zero))
    }

    func testUploadTimeoutGrowsWithTheRecordingAndIsCapped() {
        XCTAssertEqual(ProviderHTTPClient.uploadTimeout(base: 30, bodyBytes: 0), 30)
        // A minute of 16 kHz WAV.
        XCTAssertEqual(ProviderHTTPClient.uploadTimeout(base: 30, bodyBytes: 1_920_000), 120)
        XCTAssertEqual(ProviderHTTPClient.uploadTimeout(base: 30, bodyBytes: 480_000), 60)
        XCTAssertEqual(ProviderHTTPClient.uploadTimeout(base: 30, bodyBytes: 50_000_000), 120)
        XCTAssertEqual(ProviderHTTPClient.uploadTimeout(base: 200, bodyBytes: 0), 200)

        var request = URLRequest(url: URL(string: "https://example.com")!)
        request.timeoutInterval = 30
        request.httpBody = Data(count: 480_000)
        XCTAssertEqual(ProviderHTTPClient.withUploadTimeout(request, kind: .stt).timeoutInterval, 60)
        XCTAssertEqual(ProviderHTTPClient.withUploadTimeout(request, kind: .llm).timeoutInterval, 30)
    }

    // MARK: - HTTP client

    func testClientRetriesADroppedConnectionAndLogsEveryAttempt() async throws {
        ScriptedProtocol.script = [.fail(.networkConnectionLost), .status(503), .status(200)]
        let (client, log) = makeClient()
        let response = try await client.send(makeRequest(), providerID: "openai", kind: .stt)
        XCTAssertEqual(response.response.statusCode, 200)
        XCTAssertEqual(ScriptedProtocol.requestCount, 3)
        for _ in 0 ..< 100 where log.items.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(log.items.count, 3)
        XCTAssertEqual(log.items.filter { $0.requestSummary.hasPrefix("Retry ") }.count, 2)
    }

    func testClientSendsARejectedRequestOnce() async throws {
        ScriptedProtocol.script = [.status(401), .status(200)]
        let (client, _) = makeClient()
        let response = try await client.send(makeRequest(), providerID: "openai", kind: .stt)
        XCTAssertEqual(response.response.statusCode, 401)
        XCTAssertEqual(ScriptedProtocol.requestCount, 1)
    }

    func testClientGivesUpAfterTheLastAttempt() async throws {
        ScriptedProtocol.script = [.fail(.networkConnectionLost), .fail(.networkConnectionLost), .fail(.networkConnectionLost), .status(200)]
        let (client, _) = makeClient()
        do {
            _ = try await client.send(makeRequest(), providerID: "openai", kind: .stt)
            XCTFail("Expected the dropped connection to surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(ScriptedProtocol.requestCount, 3)
    }

    func testAProviderMapsAnUnreachableHostToANetworkError() async throws {
        ScriptedProtocol.script = Array(repeating: .fail(.cannotConnectToHost), count: 3)
        let (client, _) = makeClient()
        let stt = OpenAISTT(apiKey: "test", httpClient: client)
        do {
            _ = try await stt.transcribe(fileURL: try makeWAV(seconds: 1), language: .auto, vocabulary: [])
            XCTFail("Expected a network error")
        } catch let error as STTError {
            guard case .network(.openai, _) = error else { return XCTFail("Got \(error)") }
            XCTAssertTrue(NetworkFailure.isNetworkFailure(error))
            XCTAssertEqual(error.localizedDescription, "OpenAI error: Could not reach the provider.")
        }
    }

    // MARK: - Upload format

    func testFLACIsLosslessAndSmaller() throws {
        let wav = try makeWAV(seconds: 3)
        let flac = try XCTUnwrap(FLACEncoding.encode(wavURL: wav))
        let wavSize = try XCTUnwrap(try wav.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertLessThan(flac.count, wavSize)

        let flacURL = scratch.appendingPathComponent("round-trip.flac")
        try flac.write(to: flacURL)
        XCTAssertEqual(try samples(of: flacURL), try samples(of: wav))
    }

    func testOnlyProvidersThatTakeFLACGetIt() throws {
        let wav = try makeWAV(seconds: 1)
        for provider in [STTProviderID.openai, .groqWhisper, .deepgram, .elevenlabs, .mistral] {
            XCTAssertEqual(try UploadAudio.load(wav, for: provider).mimeType, "audio/flac", "\(provider)")
        }
        let muse = try UploadAudio.load(wav, for: .metaMuse)
        XCTAssertEqual(muse.mimeType, "audio/wav")
        XCTAssertEqual(muse.data, try Data(contentsOf: wav))
    }

    @MainActor
    func testAProviderThatRejectsFLACGetsTheSameRecordingAsWAV() async throws {
        let pipeline = makePipeline()
        pipeline.selectedSTT = .openai
        let fake = FormatPickyFake()
        pipeline.sttProviderOverride = { _ in fake }
        let wav = try makeWAV(seconds: 1)

        let result = try await pipeline.retryTranscription(audioURL: wav, appBundleID: nil, dictationID: UUID())
        XCTAssertEqual(result.rawTranscript, "Heard it")
        XCTAssertEqual(fake.attempts, 2)
        XCTAssertFalse(UploadAudio.sendsFLAC(to: .openai))
        XCTAssertTrue(UploadAudio.sendsFLAC(to: .groqWhisper))
    }

    // MARK: - Parakeet fills in

    @MainActor
    func testParakeetFillsInWhenTheProviderIsUnreachable() async throws {
        let pipeline = makePipeline()
        pipeline.selectedSTT = .openai
        pipeline.parakeetInstalled = { true }
        pipeline.sttLanguageSelection = STTLanguageSelection(codes: ["en-US"])
        var asked: [STTProviderID] = []
        pipeline.sttProviderOverride = { id in
            asked.append(id)
            return id == .parakeet ? TextFake(text: "From Parakeet") : nil
        }
        let wav = try makeWAV(seconds: 1)
        let route = STTRoute(provider: .openai, fallbackFrom: nil)

        let text = await pipeline.offlineTranscript(after: STTError.network(provider: .openai, message: "x"), route: route, wavURL: wav)
        XCTAssertEqual(text, "From Parakeet")
        XCTAssertTrue(pipeline.transcribedOffline)
        XCTAssertEqual(pipeline.lastRoute, STTRoute(provider: .parakeet, fallbackFrom: .openai, afterNetworkFailure: true))
        XCTAssertEqual(asked, [.parakeet])
        XCTAssertTrue(DictationPipeline.onDeviceSummary(for: pipeline.lastRoute!).contains("couldn't be reached"))
    }

    @MainActor
    func testParakeetDoesNotFillInWhenItShouldNot() async throws {
        let wav = try makeWAV(seconds: 1)
        let cloud = STTRoute(provider: .openai, fallbackFrom: nil)
        let unreachable = STTError.network(provider: .openai, message: "x")

        func attempt(
            error: Error = unreachable,
            route: STTRoute = cloud,
            installed: Bool = true,
            languages: [String] = ["en-US"]
        ) async -> String? {
            let pipeline = makePipeline()
            pipeline.parakeetInstalled = { installed }
            pipeline.sttLanguageSelection = STTLanguageSelection(codes: languages)
            pipeline.sttProviderOverride = { _ in TextFake(text: "From Parakeet") }
            return await pipeline.offlineTranscript(after: error, route: route, wavURL: wav)
        }

        let none: String? = nil
        // The provider answered: a bad key or request is the user's to fix.
        let r1 = await attempt(error: STTError.apiError(provider: .openai, message: "bad key", statusCode: 401))
        XCTAssertEqual(r1, none)
        let r2 = await attempt(error: STTError.missingAPIKey(provider: .openai))
        XCTAssertEqual(r2, none)
        let r3 = await attempt(error: CancellationError())
        XCTAssertEqual(r3, none)
        let r4 = await attempt(installed: false)
        XCTAssertEqual(r4, none)
        // Japanese is outside Parakeet's languages.
        let r5 = await attempt(languages: ["en-US", "ja-JP"])
        XCTAssertEqual(r5, none)
        // Already on this Mac: nothing to fill in for.
        let r6 = await attempt(route: STTRoute(provider: .apple, fallbackFrom: nil))
        XCTAssertEqual(r6, none)

        // Every kind of unreachable counts.
        let r7 = await attempt(error: STTError.timeout(provider: .openai))
        XCTAssertEqual(r7, "From Parakeet")
        let r8 = await attempt(error: STTError.apiError(provider: .openai, message: "busy", statusCode: 503))
        XCTAssertEqual(r8, "From Parakeet")
    }

    @MainActor
    func testARetryFromActivityStaysWithTheChosenProvider() async throws {
        let pipeline = makePipeline()
        pipeline.selectedSTT = .openai
        pipeline.parakeetInstalled = { true }
        pipeline.sttProviderOverride = { id -> (any STTProvider)? in
            if id == .parakeet { return TextFake(text: "From Parakeet") }
            return FailingFake(error: STTError.network(provider: .openai, message: "x"))
        }
        do {
            _ = try await pipeline.retryTranscription(audioURL: try makeWAV(seconds: 1), appBundleID: nil, dictationID: UUID())
            XCTFail("Expected the network error")
        } catch {
            XCTAssertTrue(NetworkFailure.isNetworkFailure(error))
        }
        XCTAssertFalse(pipeline.transcribedOffline)
    }

    func testOfflineFallbackRoundTripsThroughHistory() throws {
        let result = PipelineResult(
            rawTranscript: "a", cleanedText: "a", sttProvider: .parakeet, llmProvider: .anthropic, llmModel: nil,
            timestamp: Date(), sttFallbackFrom: .openai, cleanupOff: true, sttFallbackOffline: true
        )
        let decoded = try JSONDecoder().decode(PipelineResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded.sttFallbackOffline, true)
        let plain = PipelineResult(rawTranscript: "a", cleanedText: "a", sttProvider: .openai, llmProvider: .anthropic, llmModel: nil, timestamp: Date())
        XCTAssertNil(try JSONDecoder().decode(PipelineResult.self, from: JSONEncoder().encode(plain)).sttFallbackOffline)
    }

    // MARK: - Helpers

    private func makeClient() -> (ProviderHTTPClient, ProviderRequestLog) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScriptedProtocol.self]
        let log = ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests-\(UUID().uuidString).json"))
        var policy = ProviderRetryPolicy.standard
        policy.delays = [.zero]
        let client = ProviderHTTPClient(session: URLSession(configuration: configuration), requestLog: log, retryPolicy: policy)
        return (client, log)
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: URL(string: "https://stt.example.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.httpBody = Data("audio".utf8)
        return request
    }

    @MainActor
    private func makePipeline() -> DictationPipeline {
        let log = ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests-\(UUID().uuidString).json"))
        let client = ProviderHTTPClient(requestLog: log)
        return DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history-\(UUID().uuidString).json")),
            httpClient: client
        )
    }

    /// A 16 kHz mono 16-bit WAV like the normalized recordings: a tone with
    /// some noise, and a stretch of silence.
    private func makeWAV(seconds: Double) throws -> URL {
        let url = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true))
        let frames = AVAudioFrameCount(16_000 * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.int16ChannelData?[0])
        var noise: UInt32 = 12_345
        for index in 0 ..< Int(frames) {
            noise = noise &* 1_103_515_245 &+ 12_345
            let jitter = Double(Int(noise >> 16) % 600) - 300
            samples[index] = index < Int(frames) / 3 ? 0 : Int16(6_000 * sin(Double(index) * 0.07) + jitter)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
            try file.write(from: buffer)
        }
        return url
    }

    private func samples(of url: URL) throws -> [Int16] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var all: [Int16] = []
        // A compressed file reads a packet run at a time, not all at once.
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard buffer.frameLength > 0 else { break }
            let pointer = try XCTUnwrap(buffer.int16ChannelData?[0])
            all += UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength))
        }
        return all
    }
}

private struct TextFake: STTProvider {
    static let providerID: STTProviderID = .parakeet
    let text: String

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String { text }
}

private struct FailingFake: STTProvider {
    static let providerID: STTProviderID = .openai
    let error: Error

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String { throw error }
}

/// Turns FLAC away with a 400, the way a provider without FLAC support would.
private final class FormatPickyFake: STTProvider, @unchecked Sendable {
    static let providerID: STTProviderID = .openai
    private(set) var attempts = 0

    func transcribe(fileURL: URL, language: STTLanguageSelection, vocabulary: [String]) async throws -> String {
        attempts += 1
        if try UploadAudio.load(fileURL, for: .openai).mimeType == "audio/flac" {
            throw STTError.apiError(provider: .openai, message: "Unsupported file format", statusCode: 400)
        }
        return "Heard it"
    }
}

/// Answers requests in order from `script`.
private final class ScriptedProtocol: URLProtocol {
    enum Step {
        case status(Int)
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) static var script: [Step] = []
    nonisolated(unsafe) private static var served = 0

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return served
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        script = []
        served = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let step = Self.served < Self.script.count ? Self.script[Self.served] : .status(500)
        Self.served += 1
        Self.lock.unlock()
        switch step {
        case let .status(code):
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(code == 200 ? #"{"text":"ok"}"#.utf8 : #"{"error":{"message":"nope"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}
