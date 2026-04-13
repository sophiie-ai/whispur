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

    init(session: URLSession = .shared, requestLog: ProviderRequestLog) {
        self.session = session
        self.requestLog = requestLog
    }

    func send(
        _ request: URLRequest,
        providerID: String,
        kind: ProviderRequestKind,
        requestBodySummary: String? = nil
    ) async throws -> ProviderHTTPResponse {
        let startedAt = Date()
        let endpointURL = Self.redactedURLString(from: request.url)
        let httpMethod = request.httpMethod ?? "GET"
        let requestSummary = Self.makeRequestSummary(for: request, requestBodySummary: requestBodySummary)

        do {
            let (data, response) = try await session.data(for: request)
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
            errorMessage: errorMessage
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
