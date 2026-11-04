import XCTest
@testable import Whispur

/// The cleanup connection is warmed when recording starts, through the
/// same URLSession the cleanup request uses, and only once per window.
@MainActor
final class CleanupWarmupTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("whispur-warmup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        WarmupRecordingProtocol.reset()
    }

    override func tearDown() {
        WarmupRecordingProtocol.reset()
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makePipeline() -> DictationPipeline {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WarmupRecordingProtocol.self]
        let client = ProviderHTTPClient(
            session: URLSession(configuration: configuration),
            requestLog: ProviderRequestLog(fileURL: scratch.appendingPathComponent("requests.json"))
        )
        let pipeline = DictationPipeline(
            recorder: AudioRecorder(),
            registry: ProviderRegistry(httpClient: client),
            historyStore: PipelineHistoryStore(fileURL: scratch.appendingPathComponent("history.json")),
            httpClient: client
        )
        pipeline.llmProviderOverride = { _ in OriginOnlyLLM() }
        return pipeline
    }

    /// Waits long enough for any resumed data task to reach the protocol.
    private func settle() async {
        let deadline = Date().addingTimeInterval(2)
        while WarmupRecordingProtocol.requests.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    func testStartingARecordingWarmsTheCleanupEndpoint() async {
        let pipeline = makePipeline()

        pipeline.startRecording()
        pipeline.cancel()
        await settle()

        let requests = WarmupRecordingProtocol.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "HEAD")
        XCTAssertEqual(requests.first?.url?.host, OriginOnlyLLM.origin.host)
    }

    func testRapidStartsWarmOnlyOnce() async {
        let pipeline = makePipeline()

        for _ in 0..<3 {
            pipeline.startRecording()
            pipeline.cancel()
        }
        pipeline.warmCleanupConnection()
        await settle()

        XCTAssertEqual(WarmupRecordingProtocol.requests.count, 1, "A fresh warm-up is reused, not repeated")
    }

    func testNoWarmupWhileCleanupIsOff() async {
        let pipeline = makePipeline()
        pipeline.cleanupEnabled = false

        pipeline.startRecording()
        pipeline.cancel()
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(WarmupRecordingProtocol.requests.isEmpty)
    }
}

/// A cleanup provider that only names its endpoint.
private struct OriginOnlyLLM: LLMProvider {
    static let providerID: LLMProviderID = .anthropic
    static let origin = URL(string: "https://warmup.whispur.test")!

    var endpointOrigin: URL? { Self.origin }

    func complete(request: LLMRequest) async throws -> LLMResponse {
        LLMResponse(text: request.userMessage, model: "unused", promptTokens: nil, completionTokens: nil)
    }
}

/// Records every request the session sends and answers 405, as provider
/// endpoints do for HEAD.
private final class WarmupRecordingProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        recorded = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 405, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
