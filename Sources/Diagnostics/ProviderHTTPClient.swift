import Foundation
import os

private let providerHTTPLogger = Logger(subsystem: "ai.sophiie.whispur", category: "Providers")

private struct LoggedTransportError: Error {
    let underlying: Error
}

struct ProviderHTTPResponse {
    let data: Data
    let response: HTTPURLResponse
    let errorMessage: String?
}

final class ProviderHTTPClient {
    private let session: URLSession
    private let requestLog: ProviderRequestLog
    private let retryPolicy: ProviderRetryPolicy

    init(session: URLSession? = nil, requestLog: ProviderRequestLog, retryPolicy: ProviderRetryPolicy = .standard) {
        self.session = session ?? Self.makeDefaultSession()
        self.requestLog = requestLog
        self.retryPolicy = retryPolicy
    }

    /// Returns a URLSession tuned for dictation's hot path:
    /// - HTTP/2 multiplexing via generous per-host connection budget
    /// - Long request timeout (STT uploads of minutes-long audio)
    /// - Waits on flaky networks instead of failing fast
    /// - Keeps sockets warm between transcription and cleanup calls
    private static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    /// Opens a TCP/TLS connection to the given endpoint so the first real
    /// request skips the handshake. Safe to call repeatedly; the session's
    /// connection pool dedupes.
    func warmConnection(to url: URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        // We don't care about the response — HEAD just forces the socket open.
        // Provider endpoints return 404/405 for HEAD; that's fine.
        let task = session.dataTask(with: request) { _, _, _ in }
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }

    /// Sends `request`, retrying quietly when a flaky connection (a dropped
    /// cellular link, a provider's brief 5xx) is the likely cause. Every
    /// attempt is listed in the Requests tab. See `ProviderRetryPolicy`.
    func send(
        _ request: URLRequest,
        providerID: String,
        kind: ProviderRequestKind,
        requestBodySummary: String? = nil
    ) async throws -> ProviderHTTPResponse {
        let request = Self.withUploadTimeout(request, kind: kind)
        let firstStarted = ContinuousClock.now
        var attempt = 1
        while true {
            let delay: Duration
            do {
                let response = try await sendOnce(
                    request,
                    providerID: providerID,
                    kind: kind,
                    requestBodySummary: requestBodySummary,
                    attempt: attempt
                )
                guard let next = retryPolicy.delay(
                    afterStatus: response.response.statusCode,
                    retryAfter: response.response.value(forHTTPHeaderField: "Retry-After"),
                    kind: kind,
                    attempt: attempt,
                    elapsed: firstStarted.duration(to: .now)
                ) else { return response }
                delay = next
            } catch {
                guard let next = retryPolicy.delay(
                    afterError: error,
                    kind: kind,
                    attempt: attempt,
                    elapsed: firstStarted.duration(to: .now)
                ) else { throw error }
                delay = next
            }
            providerHTTPLogger.notice("\(providerID, privacy: .public) \(kind.rawValue, privacy: .public) retrying (attempt \(attempt + 1, privacy: .public))")
            try await Task.sleep(for: delay)
            attempt += 1
        }
    }

    /// An STT upload's idle timeout, stretched for long recordings: on a slow
    /// uplink the body trickles out, and once it is sent a long recording
    /// keeps the provider busy before the first response byte. Capped so a
    /// dead connection still fails in reasonable time.
    static func withUploadTimeout(_ request: URLRequest, kind: ProviderRequestKind) -> URLRequest {
        guard kind == .stt, let bodySize = request.httpBody?.count else { return request }
        var request = request
        request.timeoutInterval = uploadTimeout(base: request.timeoutInterval, bodyBytes: bodySize)
        return request
    }

    /// `base`, plus a second per 16 KB of body (about half a second per
    /// second of 16 kHz WAV), at most 120 seconds.
    static func uploadTimeout(base: TimeInterval, bodyBytes: Int) -> TimeInterval {
        let scaled = 30 + Double(bodyBytes) / 16_000
        return max(base, min(120, scaled))
    }

    private func sendOnce(
        _ request: URLRequest,
        providerID: String,
        kind: ProviderRequestKind,
        requestBodySummary: String?,
        attempt: Int
    ) async throws -> ProviderHTTPResponse {
        let startedAt = Date()
        let endpointURL = Self.redactedURLString(from: request.url)
        let httpMethod = request.httpMethod ?? "GET"
        var requestSummary = Self.makeRequestSummary(for: request, requestBodySummary: requestBodySummary)
        if attempt > 1 { requestSummary = "Retry \(attempt - 1) of a request that hit a network problem.\n\n" + requestSummary }
        let watchdog = ConnectivityWatchdog(grace: retryPolicy.offlineGrace)

        do {
            let (data, response): (Data, URLResponse)
            do {
                (data, response) = try await session.data(for: request, delegate: watchdog)
            } catch let error as URLError where error.code == .cancelled && watchdog.gaveUp {
                // The watchdog cancelled a request that sat waiting for a
                // network; report it as offline, not as a user cancel.
                throw URLError(.notConnectedToInternet)
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                let message = "Received a non-HTTP response from the server."
                let durationMS = Self.durationMS(since: startedAt)
                await record(
                    providerID: providerID,
                    kind: kind,
                    endpointURL: endpointURL,
                    httpMethod: httpMethod,
                    statusCode: nil,
                    durationMS: durationMS,
                    requestSummary: requestSummary,
                    responseBodyPreview: "",
                    errorMessage: message
                )
                providerHTTPLogger.error("\(providerID, privacy: .public) \(kind.rawValue, privacy: .public) \(httpMethod, privacy: .public) \(endpointURL, privacy: .public) failed: \(message, privacy: .public)")
                throw LoggedTransportError(underlying: URLError(.badServerResponse))
            }

            let errorMessage = Self.errorMessage(from: data, statusCode: httpResponse.statusCode)
            let responsePreview = Self.responsePreview(from: data)
            let durationMS = Self.durationMS(since: startedAt)

            await record(
                providerID: providerID,
                kind: kind,
                endpointURL: endpointURL,
                httpMethod: httpMethod,
                statusCode: httpResponse.statusCode,
                durationMS: durationMS,
                requestSummary: requestSummary,
                responseBodyPreview: responsePreview,
                errorMessage: errorMessage
            )

            if let errorMessage {
                providerHTTPLogger.error("\(providerID, privacy: .public) \(kind.rawValue, privacy: .public) \(httpMethod, privacy: .public) \(endpointURL, privacy: .public) -> \(httpResponse.statusCode) in \(durationMS)ms: \(errorMessage, privacy: .public)")
            } else {
                providerHTTPLogger.info("\(providerID, privacy: .public) \(kind.rawValue, privacy: .public) \(httpMethod, privacy: .public) \(endpointURL, privacy: .public) -> \(httpResponse.statusCode) in \(durationMS)ms")
            }

            return ProviderHTTPResponse(data: data, response: httpResponse, errorMessage: errorMessage)
        } catch let error as LoggedTransportError {
            throw error.underlying
        } catch {
            let message = Self.transportErrorMessage(for: error)
            let durationMS = Self.durationMS(since: startedAt)

            await record(
                providerID: providerID,
                kind: kind,
                endpointURL: endpointURL,
                httpMethod: httpMethod,
                statusCode: nil,
                durationMS: durationMS,
                requestSummary: requestSummary,
                responseBodyPreview: "",
                errorMessage: message
            )

            providerHTTPLogger.error("\(providerID, privacy: .public) \(kind.rawValue, privacy: .public) \(httpMethod, privacy: .public) \(endpointURL, privacy: .public) transport failure in \(durationMS)ms: \(message, privacy: .public)")
            throw error
        }
    }

    /// Lists a finished streaming session in the Requests tab next to the
    /// HTTP traffic. `durationMS` is the time from release to the result.
    func recordStream(
        providerID: String,
        endpointURL: String,
        durationMS: Int,
        responsePreview: String,
        errorMessage: String?
    ) {
        Task {
            await record(
                providerID: providerID,
                kind: .stt,
                endpointURL: endpointURL,
                httpMethod: "WS",
                statusCode: nil,
                durationMS: durationMS,
                requestSummary: "WebSocket stream. Live audio sent while recording; time shown is from release to the final transcript.",
                responseBodyPreview: String(responsePreview.prefix(500)),
                errorMessage: errorMessage
            )
        }
    }

    /// The HTTP method shown for script-guard entries in the Requests tab.
    static let scriptGuardMethod = "GUARD"
    /// The method shown for transcriptions that ran on this Mac.
    static let onDeviceMethod = "LOCAL"

    /// Lists an on-device transcription in the Requests tab, next to the
    /// HTTP traffic: which provider ran it and how long it took.
    func recordOnDevice(
        providerID: String,
        summary: String,
        durationMS: Int,
        responsePreview: String,
        errorMessage: String?
    ) {
        Task {
            await record(
                providerID: providerID,
                kind: .stt,
                endpointURL: "On this Mac",
                httpMethod: Self.onDeviceMethod,
                statusCode: nil,
                durationMS: durationMS,
                requestSummary: summary,
                responseBodyPreview: String(responsePreview.prefix(500)),
                errorMessage: errorMessage
            )
        }
    }

    /// Lists a script-guard firing in the Requests tab, next to the re-runs
    /// it caused.
    func recordScriptGuard(providerID: String, summary: String, keptText: String) {
        Task {
            await record(
                providerID: providerID,
                kind: .stt,
                endpointURL: "Transcript in an unexpected script, re-ran per language",
                httpMethod: Self.scriptGuardMethod,
                statusCode: nil,
                durationMS: 0,
                requestSummary: summary,
                responseBodyPreview: String(keptText.prefix(500)),
                errorMessage: nil
            )
        }
    }

    static func transportErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "The request timed out."
            case .notConnectedToInternet:
                return "No internet connection."
            case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost:
                return "Could not reach the provider."
            case .userAuthenticationRequired:
                return "Authentication is required."
            default:
                return urlError.localizedDescription
            }
        }

        return (error as NSError).localizedDescription
    }

    private func record(
        providerID: String,
        kind: ProviderRequestKind,
        endpointURL: String,
        httpMethod: String,
        statusCode: Int?,
        durationMS: Int,
        requestSummary: String,
        responseBodyPreview: String,
        errorMessage: String?
    ) async {
        let entry = ProviderRequestLogEntry(
            id: UUID(),
            timestamp: Date(),
            providerID: providerID,
            kind: kind,
            endpointURL: endpointURL,
            httpMethod: httpMethod,
            statusCode: statusCode,
            durationMS: durationMS,
            requestSummary: requestSummary,
            responseBodyPreview: responseBodyPreview,
            errorMessage: errorMessage,
            dictationID: ProviderRequestContext.dictationID
        )
        await requestLog.record(entry)
    }

    private static func durationMS(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1_000)
    }

    private static func makeRequestSummary(for request: URLRequest, requestBodySummary: String?) -> String {
        var lines: [String] = []
        lines.append("\(request.httpMethod ?? "GET") \(redactedURLString(from: request.url))")

        let headers = redactedHeaders(from: request.allHTTPHeaderFields ?? [:])
        if !headers.isEmpty {
            let renderedHeaders = headers
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            lines.append("Headers:\n\(renderedHeaders)")
        }

        if let requestBodySummary, !requestBodySummary.isEmpty {
            lines.append("Body:\n\(requestBodySummary)")
        }

        return lines.joined(separator: "\n\n")
    }

    private static func redactedHeaders(from headers: [String: String]) -> [String: String] {
        headers.reduce(into: [String: String]()) { result, item in
            if isSensitiveHeader(item.key) {
                result[item.key] = "<redacted>"
            } else {
                result[item.key] = item.value
            }
        }
    }

    private static func isSensitiveHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "authorization", "xi-api-key", "x-api-key":
            return true
        default:
            return false
        }
    }

    private static func redactedURLString(from url: URL?) -> String {
        guard let url else { return "unknown" }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.queryItems = components.queryItems?.map { item in
            if item.name.lowercased() == "api_key" {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }

        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func responsePreview(from data: Data) -> String {
        guard !data.isEmpty else { return "" }

        let limit = 512
        let prefix = data.prefix(limit)
        var preview = String(decoding: prefix, as: UTF8.self)
        if data.count > limit {
            preview += "\n... truncated ..."
        }
        return preview.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(from data: Data, statusCode: Int) -> String? {
        guard !(200 ... 299).contains(statusCode) else { return nil }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let message = extractMessage(from: jsonObject),
           !message.isEmpty {
            return message
        }

        let preview = responsePreview(from: data)
        return preview.isEmpty ? "HTTP \(statusCode)" : preview
    }

    private static func extractMessage(from value: Any) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let dictionary = value as? [String: Any] {
            for key in ["message", "detail", "description", "reason", "title", "err_msg", "error"] {
                if let nested = dictionary[key], let message = extractMessage(from: nested) {
                    return message
                }
            }

            for nested in dictionary.values {
                if let message = extractMessage(from: nested) {
                    return message
                }
            }
        }

        if let array = value as? [Any] {
            let messages = array.compactMap(extractMessage(from:)).filter { !$0.isEmpty }
            if !messages.isEmpty {
                return messages.joined(separator: "; ")
            }
        }

        return nil
    }
}

// MARK: - Retries

/// When a failed provider request is worth sending again.
///
/// Retried: a connection that dropped or couldn't open (common on cellular),
/// a provider's 5xx, 408 and 429 (with a short `Retry-After`). An STT request
/// that timed out gets one more try; a cleanup request that timed out gets
/// none, and a cleanup retry only starts within its first 10 seconds, since
/// the raw transcript is pasted instead and a retry would only make the user
/// wait. Never retried: other 4xx (a bad key or request fails
/// the same way again), no network at all (nothing to wait for), and
/// cancellation.
struct ProviderRetryPolicy {
    /// Total tries, the first included.
    var maxAttempts = 3
    /// The wait before each retry; the last entry repeats.
    var delays: [Duration] = [.milliseconds(400), .milliseconds(1_200)]
    /// No retry starts once this much time has gone by since the first try.
    var budget: Duration = .seconds(60)
    /// The same for a cleanup request, kept short: when cleanup fails the
    /// raw transcript is pasted, and waiting on retries would only delay it.
    var cleanupBudget: Duration = .seconds(10)
    /// How long a request may wait for a network to appear before it fails
    /// as offline. The session waits for connectivity so a brief dropout
    /// doesn't fail a dictation, but a long one shouldn't hang it for the
    /// session's five-minute resource timeout.
    var offlineGrace: TimeInterval = 10
    /// The longest `Retry-After` honoured; longer means don't retry.
    var maxRetryAfter: Duration = .seconds(5)

    static let standard = ProviderRetryPolicy()

    static let retriedTransportCodes: Set<URLError.Code> = [
        .networkConnectionLost,
        .cannotConnectToHost,
        .cannotFindHost,
        .dnsLookupFailed,
        .secureConnectionFailed,
        .badServerResponse,
    ]

    static let retriedStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]

    func delay(afterError error: Error, kind: ProviderRequestKind, attempt: Int, elapsed: Duration) -> Duration? {
        guard canRetry(attempt: attempt, elapsed: elapsed, kind: kind), let urlError = error as? URLError else { return nil }
        if urlError.code == .timedOut {
            return kind == .stt && attempt == 1 ? delay(for: attempt) : nil
        }
        return Self.retriedTransportCodes.contains(urlError.code) ? delay(for: attempt) : nil
    }

    func delay(afterStatus status: Int, retryAfter: String?, kind: ProviderRequestKind = .stt, attempt: Int, elapsed: Duration) -> Duration? {
        guard Self.retriedStatusCodes.contains(status), canRetry(attempt: attempt, elapsed: elapsed, kind: kind) else { return nil }
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            let requested = Duration.milliseconds(Int(seconds * 1_000))
            return requested <= maxRetryAfter ? max(requested, delay(for: attempt)) : nil
        }
        return delay(for: attempt)
    }

    private func canRetry(attempt: Int, elapsed: Duration, kind: ProviderRequestKind) -> Bool {
        attempt < maxAttempts && elapsed < (kind == .llm ? cleanupBudget : budget)
    }

    private func delay(for attempt: Int) -> Duration {
        guard !delays.isEmpty else { return .zero }
        return delays[min(attempt - 1, delays.count - 1)]
    }
}

/// Cancels a request that has waited `grace` seconds for a network without
/// sending a byte, and remembers doing so.
private final class ConnectivityWatchdog: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let grace: TimeInterval
    private let lock = NSLock()
    private var didGiveUp = false

    init(grace: TimeInterval) {
        self.grace = grace
    }

    var gaveUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return didGiveUp
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self, weak task] in
            guard let self, let task, task.state == .running,
                  task.countOfBytesSent == 0, task.countOfBytesReceived == 0 else { return }
            self.lock.lock()
            self.didGiveUp = true
            self.lock.unlock()
            task.cancel()
        }
    }
}
