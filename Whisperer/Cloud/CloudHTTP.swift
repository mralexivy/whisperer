//
//  CloudHTTP.swift
//  Whisperer
//
//  The shared HTTP layer of Whisperer Cloud: one place that turns a URLSession call into either bytes or a
//  typed error, so the identity client (`CloudClient`) and the sync transport (`CloudHTTPTransport`) cannot
//  disagree about what a 401, a 429 or a dropped connection means.
//
//  Rules baked in here:
//   - every network-level failure (no route, timeout, reset connection) is `offline`: a retry-later, never a
//     data problem;
//   - the server's `{"error":code,"message":text}` body becomes `CloudAPIError`, with `Retry-After` parsed;
//   - a 401 on an authenticated call renews the session token exactly once (through the injected provider)
//     and retries the call; a second 401 is surfaced;
//   - redirects are never followed (a 308 from Cloud Storage is an answer, not a redirect);
//   - tokens, JWS and keys are never logged and never put in an error.
//

import Foundation

/// Gives the current session token. `forceRefresh` is true after the server said 401.
typealias CloudTokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

// MARK: - Errors

/// What the server (or the network) answered, before it is interpreted by a caller. `status == 0` means no HTTP
/// answer at all (see `isOffline`).
nonisolated struct CloudAPIError: Error, Equatable, Sendable, CustomStringConvertible {
    var status: Int
    var code: String
    var message: String
    var retryAfter: TimeInterval?
    /// The raw JSON body, for answers that carry more than code and message (409 `sequence_conflict` has `head`,
    /// 409 `library_exists` has `library`).
    var body: Data

    static let offlineCode = "offline"
    static let offline = CloudAPIError(status: 0, code: offlineCode, message: "No connection to the server", retryAfter: nil, body: Data())

    var isOffline: Bool { status == 0 && code == Self.offlineCode }
    var description: String { "CloudAPIError(\(status) \(code))" }

    /// Decodes an extra field of the error body.
    func decode<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let value = object[key],
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? CloudJSON.decoder.decode(T.self, from: data)
    }
}

extension CloudTransportError {
    /// The mapping of every error code the sync routes can answer (server/internal/server/sync_http.go `syncFail`).
    init(api e: CloudAPIError) {
        if e.isOffline { self = .offline; return }
        switch (e.status, e.code) {
        case (401, _):
            self = .unauthorized
        case (403, "read_only"):
            self = .readOnly
        case (403, "device_revoked"), (403, "device_not_authorized"):
            self = .deviceRevoked
        case (403, "sealed"):
            self = .sealed
        case (403, "no_access"):
            self = .noAccess
        case (402, "over_quota"), (402, "storage_full"):
            self = .overQuota
        case (429, "download_limit"):
            self = .downloadLimit
        case (429, _):
            self = .rateLimited(retryAfter: e.retryAfter)
        case (409, "not_uploaded"):
            self = .notUploaded
        case (409, "checksum_mismatch"):
            self = .checksumMismatch
        case (409, "sequence_conflict"):
            self = .sequenceConflict(head: e.decode(CloudHead.self, key: "head") ?? CloudHead(seq: 0, crc: 0))
        default:
            self = .server(status: e.status)
        }
    }

    /// True for failures that are worth retrying inside one transfer (the network, 5xx, 408, 429).
    var isTransient: Bool {
        switch self {
        case .offline, .rateLimited: return true
        case .server(let status): return status >= 500 || status == 408
        default: return false
        }
    }
}

// MARK: - JSON

nonisolated enum CloudJSON {
    /// The server writes Go's RFC 3339 with up to nanosecond precision; ISO8601DateFormatter copes with 3 digits.
    static func parseDate(_ text: String) -> Date? {
        var normalized = text
        if let dot = text.firstIndex(of: ".") {
            let afterDot = text.index(after: dot)
            let digits = text[afterDot...].prefix(while: { $0.isASCII && $0.isNumber })
            let tail = text[text.index(afterDot, offsetBy: digits.count)...]
            let millis = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            normalized = String(text[..<dot]) + "." + millis + tail
            return fractional.date(from: normalized)
        }
        return plain.date(from: normalized)
    }

    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not an RFC 3339 date"))
            }
            return date
        }
        return d
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }
}

// MARK: - HTTP

/// Refuses every redirect: a 3xx from the server or from Cloud Storage (308 = "resume incomplete") is the answer.
nonisolated final class CloudNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated struct CloudHTTP: Sendable {
    let baseURL: URL
    let session: URLSession
    private let noRedirect = CloudNoRedirect()

    init(baseURL: URL, session: URLSession = CloudHTTP.makeSession()) {
        self.baseURL = baseURL
        self.session = session
    }

    /// A session with no cache, no cookies and no credentials storage: everything that matters is in headers we set.
    static func makeSession(requestTimeout: TimeInterval = 30, protocolClasses: [AnyClass]? = nil) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = requestTimeout
        c.timeoutIntervalForResource = 24 * 3600
        c.waitsForConnectivity = false
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let protocolClasses { c.protocolClasses = protocolClasses }
        return URLSession(configuration: c)
    }

    func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        var components = URLComponents(string: base + path)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// One request. Throws `CloudAPIError` for any non-2xx answer and for network failures (`isOffline`).
    @discardableResult
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, token: String? = nil) async throws -> Data {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await Self.perform(session, request, delegate: noRedirect)
        guard (200..<300).contains(response.statusCode) else { throw Self.apiError(status: response.statusCode, headers: response, body: data) }
        return data
    }

    /// Runs a request and returns the raw answer for any status (blob transfers interpret statuses themselves).
    static func perform(_ session: URLSession, _ request: URLRequest, upload: Data? = nil, delegate: URLSessionTaskDelegate? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response): (Data, URLResponse)
            if let upload {
                (data, response) = try await session.upload(for: request, from: upload, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: delegate)
            }
            guard let http = response as? HTTPURLResponse else { throw CloudAPIError.offline }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw CloudAPIError.offline
        }
    }

    static func apiError(status: Int, headers: HTTPURLResponse, body: Data) -> CloudAPIError {
        var code = "http_\(status)", message = ""
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let c = object["error"] as? String { code = c }
            if let m = object["message"] as? String { message = m }
        }
        return CloudAPIError(status: status, code: code, message: message, retryAfter: retryAfter(headers), body: body)
    }

    /// `Retry-After` as seconds (the server only sends the delta-seconds form).
    static func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"), let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds >= 0 else { return nil }
        return seconds
    }

    // MARK: Authenticated calls

    /// Sends with the session token; on a 401 asks the provider for a fresh token once and retries once.
    @discardableResult
    func authed(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil, tokens: CloudTokenProvider) async throws -> Data {
        let first = try await tokens(false)
        do {
            return try await send(method, path, query: query, body: body, token: first)
        } catch let error as CloudAPIError where error.status == 401 {
            let renewed = try await tokens(true)
            return try await send(method, path, query: query, body: body, token: renewed)
        }
    }
}
