//
//  ProviderHTTPClient.swift
//  Whisperer
//
//  Streaming HTTPS for the API providers. One place maps transport and HTTP failures to
//  `MeetingAIProviderError`, so every provider falls back the same way.
//

import Foundation

nonisolated enum ProviderHTTPClient {

    /// Session used for inference. Tests swap in one backed by a `URLProtocol` stub.
    nonisolated(unsafe) static var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 900
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// Streams `request` as SSE, calling `onEvent` for every event. Throws on a non-2xx
    /// response with the body read and classified.
    static func streamEvents(_ request: URLRequest,
                             onEvent: (SSEEvent) throws -> Void) async throws {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw map(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MeetingAIProviderError.server(status: 0, body: "No HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            var body = Data()
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > 64 * 1024 { break }
                }
            } catch {}
            throw error(status: http.statusCode, body: String(decoding: body, as: UTF8.self),
                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        }

        var parser = SSEStreamParser()
        var pending = Data()
        do {
            for try await byte in bytes {
                pending.append(byte)
                // Hand the parser whole lines; per-byte feeding would re-scan the buffer.
                if byte == 0x0A {
                    for event in parser.feed(pending) { try onEvent(event) }
                    pending.removeAll(keepingCapacity: true)
                }
            }
        } catch let providerError as MeetingAIProviderError {
            throw providerError
        } catch {
            throw map(error)
        }
        for event in parser.feed(pending) + parser.finish() { try onEvent(event) }
    }

    /// Plain JSON request (model lists, token exchange).
    static func json(_ request: URLRequest) async throws -> [String: Any] {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw map(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(decoding: data, as: UTF8.self)
        guard (200..<300).contains(status) else {
            throw error(status: status, body: body,
                        retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MeetingAIProviderError.server(status: status, body: String(body.prefix(500)))
        }
        return object
    }

    static func error(status: Int, body: String, retryAfter: String?) -> MeetingAIProviderError {
        let wait = retryAfter.flatMap(TimeInterval.init)
        let lower = body.lowercased()
        switch status {
        case 401, 403:
            return .unauthorized
        case 429:
            let quota = ["quota", "insufficient", "billing", "credit", "usage limit", "plan"]
            return quota.contains(where: lower.contains) ? .quotaExhausted(retryAfter: wait) : .rateLimited(retryAfter: wait)
        case 400, 413:
            if lower.contains("context") || lower.contains("too long") || lower.contains("too many tokens")
                || lower.contains("maximum") && lower.contains("token") {
                return .contextTooLong
            }
            return .server(status: status, body: String(body.prefix(500)))
        default:
            return .server(status: status, body: String(body.prefix(500)))
        }
    }

    static func map(_ error: Error) -> MeetingAIProviderError {
        if let provider = error as? MeetingAIProviderError { return provider }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .offline
            default: return .server(status: 0, body: url.localizedDescription)
            }
        }
        return .server(status: 0, body: error.localizedDescription)
    }

    static func jsonBody(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}
