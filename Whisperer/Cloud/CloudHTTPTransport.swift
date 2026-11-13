//
//  CloudHTTPTransport.swift
//  Whisperer
//
//  `CloudTransport` over URLSession: the control routes (/v1/sync/*) with the bearer session token, and the
//  data plane — signed Cloud Storage URLs — for the bytes.
//
//  Control plane: automatic one-time renewal on 401 through the injected token provider; every server error
//  code mapped to `CloudTransportError` (see `CloudTransportError.init(api:)`); `Retry-After` honoured on 429;
//  offline and timeouts are `.offline`.
//
//  Data plane, exactly as the grant says:
//   - small objects: PUT to the signed URL with the granted headers; 412 (object exists) is success;
//   - `grant.resumable`: POST (granted headers) starts a session, the `Location` header is the session URI;
//     the bytes go there in chunks (a multiple of 256 KiB) with `Content-Range`; after an interruption the
//     transfer asks `bytes */total` where it stands and continues from the committed offset; the session URI is
//     remembered per object so a later call resumes instead of starting over;
//   - downloads are ranged GETs of at most 64 MiB into a partial file that survives an interruption.
//

import Foundation
import CryptoKit

nonisolated final class CloudHTTPTransport: CloudTransport, @unchecked Sendable {
    nonisolated struct Configuration: Sendable {
        /// Resumable upload chunk. Cloud Storage demands a multiple of 256 KiB for every chunk but the last.
        var uploadChunkSize = 8 << 20
        /// Ranged download chunk (never more than 64 MiB).
        var downloadChunkSize = 32 << 20
        /// Consecutive transient failures inside one transfer before the call gives up with the last error.
        var maxAttempts = 6
        /// Pause before retry number `attempt` (1-based).
        var backoff: @Sendable (Int) -> TimeInterval = { min(0.5 * pow(2, Double($0 - 1)), 8) }
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
        var partialDirectory: URL = CloudHTTPTransport.defaultPartialDirectory()
        /// Called when the server answers that this Mac was removed from the account (device_revoked), so the account layer
        /// can sign the Mac out at once instead of when the one-hour token next renews.
        var onDeviceRevoked: (@Sendable () -> Void)?
    }

    static let chunkGranularity = 256 << 10
    static let maxDownloadChunk = 64 << 20

    private let api: CloudHTTP
    private let blobSession: URLSession
    private let tokens: CloudTokenProvider
    private let config: Configuration
    private let noRedirect = CloudNoRedirect()
    private let lock = NSLock()
    private var uploadSessions: [String: URL] = [:]

    /// `blobSession` carries bytes to and from Cloud Storage; it defaults to the API session.
    init(api: CloudHTTP, tokens: @escaping CloudTokenProvider, blobSession: URLSession? = nil, configuration: Configuration = Configuration()) {
        var configuration = configuration
        configuration.uploadChunkSize = max(Self.chunkGranularity, configuration.uploadChunkSize / Self.chunkGranularity * Self.chunkGranularity)
        configuration.downloadChunkSize = min(Self.maxDownloadChunk, max(1, configuration.downloadChunkSize))
        self.api = api
        self.tokens = tokens
        self.blobSession = blobSession ?? api.session
        self.config = configuration
    }

    static func defaultPartialDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("com.ivy.whisperer", isDirectory: true).appendingPathComponent("CloudPartials", isDirectory: true)
    }

    // MARK: - Control plane

    private func call(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        do {
            return try await api.authed(method, path, query: query, body: body, tokens: tokens)
        } catch let error as CloudAPIError {
            let mapped = CloudTransportError(api: error)
            if mapped == .deviceRevoked { config.onDeviceRevoked?() }
            throw mapped
        } catch let error as CloudTransportError {
            throw error // the token provider's own verdict (e.g. device revoked while renewing)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudTransportError.unauthorized
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try CloudJSON.decoder.decode(T.self, from: data) } catch { throw CloudTransportError.server(status: 200) }
    }

    func heads(since version: Int64?) async throws -> CloudHeads {
        var query: [URLQueryItem] = []
        if let version, version > 0 { query.append(URLQueryItem(name: "since", value: String(version))) }
        return try decode(CloudHeads.self, try await call("GET", "/v1/sync/heads", query: query))
    }

    nonisolated private struct UploadBody: Encodable { var objects: [CloudUploadRequest] }
    nonisolated private struct GrantsBody: Decodable { var grants: [CloudGrant] }

    func requestUploads(_ items: [CloudUploadRequest]) async throws -> [CloudGrant] {
        let body = try CloudJSON.encode(UploadBody(objects: items))
        return try decode(GrantsBody.self, try await call("POST", "/v1/sync/upload", body: body)).grants
    }

    nonisolated private struct CommitBody: Encodable {
        var device: String
        var seq: Int64
        var crc: UInt32
        var extra: [CloudObjectRef]?
        var snapshot: CloudSnapshotInfo?
    }

    func commit(device: String, seq: Int64, crc: UInt32, extra: [CloudObjectRef], snapshot: CloudSnapshotInfo?) async throws -> CloudCommitResult {
        let body = try CloudJSON.encode(CommitBody(device: device, seq: seq, crc: crc, extra: extra.isEmpty ? nil : extra, snapshot: snapshot))
        return try decode(CloudCommitResult.self, try await call("POST", "/v1/sync/commit", body: body))
    }

    nonisolated private struct RefsBody: Encodable { var objects: [CloudObjectRef] }

    func requestDownloads(_ refs: [CloudObjectRef]) async throws -> [CloudGrant] {
        let body = try CloudJSON.encode(RefsBody(objects: refs))
        return try decode(GrantsBody.self, try await call("POST", "/v1/sync/download", body: body)).grants
    }

    nonisolated private struct DeletedBody: Decodable { var deleted: Int }

    func delete(_ refs: [CloudObjectRef]) async throws -> Int {
        let body = try CloudJSON.encode(RefsBody(objects: refs))
        return try decode(DeletedBody.self, try await call("POST", "/v1/sync/delete", body: body)).deleted
    }

    // MARK: - Uploads

    func upload(_ data: Data, with grant: CloudGrant) async throws {
        try await upload(size: Int64(data.count), with: grant) { range in data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
    }

    func upload(fileAt url: URL, size: Int64, with grant: CloudGrant) async throws {
        try await upload(size: size, with: grant) { range in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.lowerBound))
            guard let bytes = try handle.read(upToCount: Int(range.upperBound - range.lowerBound)), bytes.count == Int(range.upperBound - range.lowerBound) else {
                throw CloudTransportError.server(status: 0)
            }
            return bytes
        }
    }

    private typealias ByteSource = @Sendable (Range<Int64>) throws -> Data

    private func upload(size: Int64, with grant: CloudGrant, read: ByteSource) async throws {
        guard let url = URL(string: grant.url) else { throw CloudTransportError.server(status: 0) }
        if grant.resumable == true {
            try await uploadResumable(size: size, url: url, grant: grant, read: read)
        } else {
            try await uploadSimple(url: url, grant: grant, body: try read(0..<size))
        }
    }

    private func request(_ method: String, _ url: URL, headers: [String: String]? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    /// One request to Cloud Storage; network failures become `.offline`.
    private func blob(_ request: URLRequest, upload: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await CloudHTTP.perform(blobSession, request, upload: upload, delegate: noRedirect)
        } catch let error as CloudAPIError {
            throw CloudTransportError(api: error)
        }
    }

    private func uploadSimple(url: URL, grant: CloudGrant, body: Data) async throws {
        var req = request("PUT", url, headers: grant.headers)
        req.timeoutInterval = 120
        let (_, response) = try await blob(req, upload: body)
        switch response.statusCode {
        case 200..<300, 412: return // 412: the object exists already — the commit's checksum decides whether it is ours
        case 429: throw CloudTransportError.rateLimited(retryAfter: CloudHTTP.retryAfter(response))
        default: throw CloudTransportError.server(status: response.statusCode)
        }
    }

    nonisolated private enum Progress { case complete, committed(Int64), gone }

    private func sessionURI(for name: String) -> URL? { lock.lock(); defer { lock.unlock() }; return uploadSessions[name] }
    private func remember(_ uri: URL?, for name: String) { lock.lock(); uploadSessions[name] = uri; lock.unlock() }

    /// Reads the answer of a chunk PUT or a `bytes */total` status query.
    private func progress(_ response: HTTPURLResponse) throws -> Progress {
        switch response.statusCode {
        case 200, 201, 412: return .complete // 412: another upload of the same object finished first; the commit decides
        case 308:
            guard let range = response.value(forHTTPHeaderField: "Range"), let dash = range.lastIndex(of: "-"),
                  let last = Int64(range[range.index(after: dash)...]) else { return .committed(0) }
            return .committed(last + 1)
        case 404, 410: return .gone
        case 429: throw CloudTransportError.rateLimited(retryAfter: CloudHTTP.retryAfter(response))
        default: throw CloudTransportError.server(status: response.statusCode)
        }
    }

    private func uploadResumable(size: Int64, url: URL, grant: CloudGrant, read: ByteSource) async throws {
        let name = grant.name
        var uri = sessionURI(for: name)
        var needsStatus = uri != nil // a remembered session: ask where it stands before sending anything
        var committed: Int64 = 0
        var failures = 0
        while true {
            do {
                try Task.checkCancellation()
                if uri == nil {
                    var start = request("POST", url, headers: grant.headers)
                    start.httpBody = nil
                    let (_, response) = try await blob(start)
                    if response.statusCode == 412 { remember(nil, for: name); return }
                    guard (200..<300).contains(response.statusCode) else {
                        throw response.statusCode == 429 ? CloudTransportError.rateLimited(retryAfter: CloudHTTP.retryAfter(response)) : CloudTransportError.server(status: response.statusCode)
                    }
                    guard let location = response.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
                        throw CloudTransportError.server(status: response.statusCode)
                    }
                    uri = session; remember(session, for: name); committed = 0; needsStatus = false
                }
                if needsStatus || committed >= size {
                    var query = request("PUT", uri!)
                    query.setValue("bytes */\(size)", forHTTPHeaderField: "Content-Range")
                    let (_, response) = try await blob(query, upload: Data())
                    switch try progress(response) {
                    case .complete: remember(nil, for: name); return
                    case .gone: uri = nil; remember(nil, for: name); needsStatus = false; committed = 0; continue
                    case .committed(let n):
                        if n >= size { throw CloudTransportError.server(status: 308) } // all bytes sent, not finalised: not ours to fix
                        committed = n; needsStatus = false
                    }
                }
                var end = min(committed + Int64(config.uploadChunkSize), size)
                if end < size { end = end / Int64(Self.chunkGranularity) * Int64(Self.chunkGranularity) }
                if end <= committed { end = size } // the committed offset is unaligned: send the rest as the final chunk
                let chunk = try read(committed..<end)
                var put = request("PUT", uri!)
                put.setValue("bytes \(committed)-\(end - 1)/\(size)", forHTTPHeaderField: "Content-Range")
                put.timeoutInterval = 120
                let (_, response) = try await blob(put, upload: chunk)
                switch try progress(response) {
                case .complete: remember(nil, for: name); return
                case .gone: uri = nil; remember(nil, for: name); needsStatus = false; committed = 0
                case .committed(let n): committed = n; failures = 0
                }
            } catch let error as CloudTransportError where error.isTransient {
                failures += 1
                if failures > config.maxAttempts { throw error } // the session stays remembered: the next call resumes it
                if case .rateLimited(let retryAfter?) = error { await config.sleep(retryAfter) } else { await config.sleep(config.backoff(failures)) }
                needsStatus = uri != nil
            }
        }
    }

    // MARK: - Downloads

    func download(with grant: CloudGrant) async throws -> Data {
        let (part, meta) = partialFiles(for: grant)
        try await fetch(grant, partial: part, meta: meta)
        defer { try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: meta) }
        do { return try Data(contentsOf: part) } catch { throw CloudTransportError.server(status: 0) }
    }

    func download(with grant: CloudGrant, to url: URL) async throws {
        let (part, meta) = partialFiles(for: grant)
        try await fetch(grant, partial: part, meta: meta)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            try fm.moveItem(at: part, to: url)
            try? fm.removeItem(at: meta)
        } catch { throw CloudTransportError.server(status: 0) }
    }

    nonisolated private struct PartialMeta: Codable { var generation: String?; var total: Int64? }

    private func partialFiles(for grant: CloudGrant) -> (partial: URL, meta: URL) {
        let id = Data(SHA256.hash(data: Data(grant.name.utf8))).prefix(16).map { String(format: "%02x", $0) }.joined()
        let dir = config.partialDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir.appendingPathComponent(id + ".part"), dir.appendingPathComponent(id + ".json"))
    }

    private func fetch(_ grant: CloudGrant, partial: URL, meta metaURL: URL) async throws {
        guard let url = URL(string: grant.url) else { throw CloudTransportError.server(status: 0) }
        let fm = FileManager.default
        var meta = (try? Data(contentsOf: metaURL)).flatMap { try? JSONDecoder().decode(PartialMeta.self, from: $0) } ?? PartialMeta()
        var offset = Int64((try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.int64Value ?? 0)
        if offset > 0 && meta.total == nil { offset = 0 } // a partial with no record of its object cannot be trusted
        if offset == 0 || !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil); offset = 0; meta = PartialMeta() }

        var failures = 0
        while true {
            do {
                try Task.checkCancellation()
                var get = request("GET", url, headers: grant.headers)
                get.setValue("bytes=\(offset)-\(offset + Int64(config.downloadChunkSize) - 1)", forHTTPHeaderField: "Range")
                get.timeoutInterval = 120
                let (body, response) = try await blob(get)
                switch response.statusCode {
                case 200:
                    // The server ignored the range and sent the whole object.
                    try body.write(to: partial, options: .atomic)
                    return
                case 206:
                    let generation = response.value(forHTTPHeaderField: "x-goog-generation")
                    if offset > 0, let known = meta.generation, let generation, known != generation {
                        offset = 0; meta = PartialMeta()
                        try Data().write(to: partial) // the object was replaced under us: start again
                        continue
                    }
                    guard !body.isEmpty else { throw CloudTransportError.server(status: 206) }
                    try append(body, at: offset, to: partial)
                    offset += Int64(body.count)
                    meta.generation = generation ?? meta.generation
                    meta.total = Self.total(of: response) ?? meta.total
                    if let data = try? JSONEncoder().encode(meta) { try? data.write(to: metaURL, options: .atomic) }
                    failures = 0
                    if let total = meta.total, offset >= total { return }
                    if meta.total == nil && Int64(body.count) < Int64(config.downloadChunkSize) { return }
                case 416:
                    if offset == 0 { try Data().write(to: partial); return } // an empty object
                    if let total = meta.total, offset >= total { return }
                    offset = 0; meta = PartialMeta(); try Data().write(to: partial) // our offset is past the object: start again
                case 429:
                    throw CloudTransportError.rateLimited(retryAfter: CloudHTTP.retryAfter(response))
                default:
                    throw CloudTransportError.server(status: response.statusCode)
                }
            } catch let error as CloudTransportError where error.isTransient {
                failures += 1
                if failures > config.maxAttempts { throw error } // the partial file stays: the next call resumes it
                if case .rateLimited(let retryAfter?) = error { await config.sleep(retryAfter) } else { await config.sleep(config.backoff(failures)) }
            }
        }
    }

    private func append(_ data: Data, at offset: Int64, to file: URL) throws {
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset)) // never keep bytes beyond what we have verified as ours
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch { throw CloudTransportError.server(status: 0) }
    }

    /// The object size from `Content-Range: bytes a-b/total`.
    private static func total(of response: HTTPURLResponse) -> Int64? {
        guard let range = response.value(forHTTPHeaderField: "Content-Range"), let slash = range.lastIndex(of: "/") else { return nil }
        return Int64(range[range.index(after: slash)...])
    }
}
