import Foundation
import os

private let logger = Logger(subsystem: "ai.sophiie.whispur", category: "STTStreaming")

// MARK: - Provider surface

/// A speech provider that can also transcribe while the user talks.
///
/// Streaming never replaces the recording: the pipeline keeps writing the
/// WAV, and any streaming failure falls back to the provider's batch
/// `transcribe(fileURL:...)` on that file.
protocol STTStreamingProvider {
    static var providerID: STTProviderID { get }

    /// Sample rate of the 16-bit mono PCM the provider expects.
    var streamingSampleRate: Double { get }

    func makeStreamingSession(language: STTLanguageSelection, vocabulary: [String]) -> STTStreamingSession
}

extension STTProviderID {
    /// Providers that offer "Stream audio while you talk".
    var supportsStreaming: Bool {
        switch self {
        case .elevenlabs, .metaMuse: true
        default: false
        }
    }
}

// MARK: - Wire protocol

enum STTSocketMessage: Equatable {
    case text(String)
    case data(Data)
}

/// What a provider's server frame means to the session.
enum STTStreamEvent: Equatable {
    /// The provider accepted the session; audio may flow.
    case ready
    /// Interim text that may still change.
    case partial(String)
    /// A finalized segment. Completes the session once the final commit has
    /// been sent, for providers that use commits.
    case committed(String)
    /// The provider finished the stream. `nil` means "use the committed
    /// segments received so far".
    case completed(String?)
    case failed(String)
    case ignored
}

/// One provider's realtime message format. Pure, so it is unit-testable.
protocol STTStreamingWireFormat {
    /// Frames sent right after the socket opens (a handshake, for example).
    func openingMessages() -> [STTSocketMessage]

    /// Whether audio must wait for a `.ready` event before it is sent.
    var waitsForReadyBeforeAudio: Bool { get }

    /// Encodes a chunk of 16-bit mono PCM. `isLast` marks the final chunk
    /// of the recording.
    func audioMessages(pcm: Data, isLast: Bool) -> [STTSocketMessage]

    /// Frames sent after the last audio chunk.
    func closingMessages() -> [STTSocketMessage]

    func parse(_ message: STTSocketMessage) -> STTStreamEvent
}

// MARK: - Socket

protocol STTStreamSocket: AnyObject, Sendable {
    func open()
    func send(_ message: STTSocketMessage) async throws
    func receive() async throws -> STTSocketMessage
    func close()
}

/// `URLSessionWebSocketTask` behind `STTStreamSocket`.
final class URLSessionStreamSocket: STTStreamSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
    }

    func open() {
        task.resume()
    }

    func send(_ message: STTSocketMessage) async throws {
        switch message {
        case let .text(text): try await task.send(.string(text))
        case let .data(data): try await task.send(.data(data))
        }
    }

    func receive() async throws -> STTSocketMessage {
        switch try await task.receive() {
        case let .string(text): return .text(text)
        case let .data(data): return .data(data)
        @unknown default: return .data(Data())
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

// MARK: - Session

enum STTStreamingError: LocalizedError, Equatable {
    case provider(String)
    case closed
    case timedOut
    case cancelled
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case let .provider(message): "Streaming error: \(message)"
        case .closed: "The streaming connection closed before the transcript arrived."
        case .timedOut: "The streaming transcript did not arrive in time."
        case .cancelled: "Streaming was cancelled."
        case .emptyTranscript: "Streaming returned no text."
        }
    }
}

/// One live transcription. Audio arrives from the recording thread through
/// `append`, is grouped into fixed-size chunks, and is sent in order. When
/// the user stops, `finish` sends the last chunk plus any closing frames and
/// waits for the provider's final text.
///
/// Every failure (socket error, provider error, close, timeout) surfaces from
/// `finish` as a thrown error so the caller can fall back to batch.
final class STTStreamingSession: @unchecked Sendable {
    enum State: Equatable {
        case idle
        case streaming
        case finishing
        case completed(String)
        case failed(STTStreamingError)
    }

    let providerID: STTProviderID
    /// Where the stream goes, without credentials or query, for the
    /// Requests tab.
    let endpointDescription: String
    var onPartial: ((String) -> Void)?

    private let format: STTStreamingWireFormat
    private let socket: STTStreamSocket
    private let chunkBytes: Int

    private let lock = NSLock()
    private var _state: State = .idle
    private var committed: [String] = []
    private var commitEvents = 0
    /// Count of committed segments when the last chunk went out, or `nil`
    /// before then. Set before sending, so the reply can't race past it.
    private var committedCountAtFinal: Int?
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var isReady = false

    private let audio: AsyncStream<Data>
    private let audioInput: AsyncStream<Data>.Continuation
    private var senderTask: Task<Void, Never>?
    private var receiverTask: Task<Void, Never>?

    init(
        providerID: STTProviderID,
        endpointDescription: String,
        format: STTStreamingWireFormat,
        socket: STTStreamSocket,
        chunkBytes: Int
    ) {
        self.providerID = providerID
        self.endpointDescription = endpointDescription
        self.format = format
        self.socket = socket
        self.chunkBytes = max(2, chunkBytes - chunkBytes % 2)
        (audio, audioInput) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    }

    var state: State {
        lock.withLock { _state }
    }

    func start() {
        let shouldStart: Bool = lock.withLock {
            guard _state == .idle else { return false }
            _state = .streaming
            isReady = !format.waitsForReadyBeforeAudio
            return true
        }
        guard shouldStart else { return }

        socket.open()
        receiverTask = Task { [weak self] in await self?.receiveLoop() }
        senderTask = Task { [weak self] in await self?.sendLoop() }
    }

    /// Thread-safe. Called from the audio tap with 16-bit mono PCM.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        audioInput.yield(pcm)
    }

    /// Ends the audio and waits up to `timeout` for the final transcript.
    func finish(timeout: Duration) async throws -> String {
        let alreadyDone: Result<String, STTStreamingError>? = lock.withLock {
            switch _state {
            case let .completed(text): return .success(text)
            case let .failed(error): return .failure(error)
            case .idle: return .failure(.closed)
            case .streaming:
                _state = .finishing
                return nil
            case .finishing:
                return nil
            }
        }
        if let alreadyDone { return try alreadyDone.get() }

        audioInput.finish()

        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(.timedOut)
        }
        defer { timer.cancel() }

        let text = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let immediate: Result<String, STTStreamingError>? = lock.withLock {
                switch _state {
                case let .completed(text): return .success(text)
                case let .failed(error): return .failure(error)
                default:
                    waiters.append(continuation)
                    return nil
                }
            }
            if let immediate {
                continuation.resume(with: immediate.mapError { $0 as Error })
            }
        }
        return text
    }

    func cancel() {
        audioInput.finish()
        fail(.cancelled)
    }

    // MARK: Loops

    private func sendLoop() async {
        do {
            for message in format.openingMessages() {
                try await socket.send(message)
            }
            try await waitUntilReady()

            var pending = Data()
            for await chunk in audio {
                pending.append(chunk)
                while pending.count >= chunkBytes * 2 {
                    // Keep at least one chunk back so the last one sent can
                    // carry the end-of-audio marker.
                    let piece = pending.prefix(chunkBytes)
                    pending.removeFirst(chunkBytes)
                    for message in format.audioMessages(pcm: Data(piece), isLast: false) {
                        try await socket.send(message)
                    }
                }
            }

            guard !isTerminal else { return }
            while pending.count > chunkBytes {
                let piece = pending.prefix(chunkBytes)
                pending.removeFirst(chunkBytes)
                for message in format.audioMessages(pcm: Data(piece), isLast: false) {
                    try await socket.send(message)
                }
            }
            lock.withLock { committedCountAtFinal = commitEvents }
            for message in format.audioMessages(pcm: pending, isLast: true) {
                try await socket.send(message)
            }
            for message in format.closingMessages() {
                try await socket.send(message)
            }
        } catch {
            fail(Self.mapError(error))
        }
    }

    private func receiveLoop() async {
        while !isTerminal {
            let message: STTSocketMessage
            do {
                message = try await socket.receive()
            } catch {
                fail(isTerminal ? .cancelled : .closed)
                return
            }
            handle(format.parse(message))
        }
    }

    // MARK: Events

    func handle(_ event: STTStreamEvent) {
        switch event {
        case .ready:
            let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
                isReady = true
                defer { readyWaiters.removeAll() }
                return readyWaiters
            }
            waiting.forEach { $0.resume() }
        case let .partial(text):
            onPartial?(text)
        case let .committed(text):
            lock.withLock {
                commitEvents += 1
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { committed.append(trimmed) }
            }
            completeIfCommittedAfterFinish()
        case let .completed(text):
            let final = text ?? lock.withLock { committed.joined(separator: " ") }
            complete(with: final)
        case let .failed(message):
            fail(.provider(message))
        case .ignored:
            break
        }
    }

    /// Commit-based providers answer the final commit with one more
    /// committed segment; that segment ends the session.
    private func completeIfCommittedAfterFinish() {
        let text: String? = lock.withLock {
            guard let countAtFinal = committedCountAtFinal, commitEvents > countAtFinal else { return nil }
            return committed.joined(separator: " ")
        }
        if let text { complete(with: text) }
    }

    private func complete(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(.emptyTranscript)
            return
        }
        let waiting: [CheckedContinuation<String, Error>]? = lock.withLock {
            guard !isTerminalLocked else { return nil }
            _state = .completed(trimmed)
            defer { waiters.removeAll() }
            return waiters
        }
        guard let waiting else { return }
        waiting.forEach { $0.resume(returning: trimmed) }
        teardown()
    }

    private func fail(_ error: STTStreamingError) {
        let pending: ([CheckedContinuation<String, Error>], [CheckedContinuation<Void, Error>])? = lock.withLock {
            guard !isTerminalLocked else { return nil }
            _state = .failed(error)
            defer {
                waiters.removeAll()
                readyWaiters.removeAll()
            }
            return (waiters, readyWaiters)
        }
        guard let pending else { return }
        if error != .cancelled {
            logger.warning("\(self.providerID.rawValue, privacy: .public) stream failed: \(error.localizedDescription, privacy: .public)")
        }
        pending.0.forEach { $0.resume(throwing: error) }
        pending.1.forEach { $0.resume(throwing: error) }
        audioInput.finish()
        teardown()
    }

    private func teardown() {
        socket.close()
        receiverTask?.cancel()
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let result: Result<Void, STTStreamingError>? = lock.withLock {
                if case let .failed(error) = _state { return .failure(error) }
                if isReady { return .success(()) }
                readyWaiters.append(continuation)
                return nil
            }
            if let result { continuation.resume(with: result.mapError { $0 as Error }) }
        }
    }

    private var isTerminal: Bool {
        lock.withLock { isTerminalLocked }
    }

    private var isTerminalLocked: Bool {
        switch _state {
        case .completed, .failed: true
        default: false
        }
    }

    private static func mapError(_ error: Error) -> STTStreamingError {
        if let error = error as? STTStreamingError { return error }
        if error is CancellationError { return .cancelled }
        return .closed
    }
}

// MARK: - Fallback

/// The one rule for streamed dictation: use the streamed text when it
/// arrives, otherwise transcribe the same recording in batch. A dictation is
/// never lost to a streaming failure.
enum StreamingFallback {
    struct Outcome {
        let text: String?
        let error: Error?
        let elapsedMS: Int
    }

    /// The streamed text was fine as text but `accept` turned it down
    /// (the script guard). Reported like a stream failure.
    struct Rejected: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    /// - Parameters:
    ///   - accept: Returns nil to use the streamed text, or why it can't be
    ///     used. A rejected stream goes to `retryRejected` (or `batch` when
    ///     that's nil) with the rejected text.
    @MainActor
    static func transcript(
        stream: STTStreamingSession?,
        timeout: Duration,
        report: (Outcome) -> Void = { _ in },
        accept: (String) -> String? = { _ in nil },
        retryRejected: ((String) async throws -> String)? = nil,
        batch: () async throws -> String
    ) async throws -> String {
        var rejectedText: String?
        if let stream {
            let started = ContinuousClock.now
            func elapsedMS() -> Int {
                let elapsed = ContinuousClock.now - started
                return Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            }
            do {
                // Cancelling the dictation closes the socket right away
                // instead of waiting out the timeout.
                let text = try await withTaskCancellationHandler {
                    try await stream.finish(timeout: timeout)
                } onCancel: {
                    stream.cancel()
                }
                guard let reason = accept(text) else {
                    report(Outcome(text: text, error: nil, elapsedMS: elapsedMS()))
                    return text
                }
                report(Outcome(text: text, error: Rejected(reason: reason), elapsedMS: elapsedMS()))
                rejectedText = text
            } catch {
                if Task.isCancelled { throw CancellationError() }
                report(Outcome(text: nil, error: error, elapsedMS: elapsedMS()))
            }
        }
        if let rejectedText, let retryRejected {
            return try await retryRejected(rejectedText)
        }
        return try await batch()
    }
}
