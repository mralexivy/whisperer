import Compression
import CryptoKit
import Foundation

/// Reads the encrypted polish-model package produced by `Tools/mmbert/package_model.py`.
///
/// Framing, outermost first — `Tools/mmbert/verify_package.py` is the executable
/// spec this is written against, and the two must not drift:
///
///     "WHSPMDL1" || uint32 chunk_size || uint64 compressed_size      (20-byte header)
///     repeated:  nonce(12) || ciphertext || tag(16)                  (AES-256-GCM)
///       -> LZFSE
///         -> "WPKG1\0\0\0" || uint32 index_len || index JSON || file bytes
///
/// Every chunk is authenticated with the header *and its own index* as associated
/// data, so a chunk cannot be reordered, dropped, or replayed from another build.
/// That is what makes it safe to decrypt incrementally rather than buffering all
/// 138 MB and verifying one tag at the end — which would stall for seconds at the
/// exact moment the progress bar reads 100%.
///
/// The encryption is deliberately a speed bump and not a security boundary: the
/// key ships in this binary. It keeps the public HuggingFace repo from being a
/// drop-in model download for someone else's project. Do not describe it as
/// protection.
enum PolishModelPackage {

    // MARK: - Manifest

    struct Manifest: Codable {
        let schema: Int
        let version: String
        let file: String
        let ciphertextBytes: Int64
        let compressedBytes: Int64
        let uncompressedBytes: Int64
        let uncompressedSha256: String
        let container: String
        let chunkSize: Int
        let chunks: Int
        let headerLen: Int
        let nonceLen: Int
        let tagLen: Int
        let magic: String
        let files: Int

        enum CodingKeys: String, CodingKey {
            case schema, version, file, container, chunks, magic, files
            case ciphertextBytes = "ciphertext_bytes"
            case compressedBytes = "compressed_bytes"
            case uncompressedBytes = "uncompressed_bytes"
            case uncompressedSha256 = "uncompressed_sha256"
            case chunkSize = "chunk_size"
            case headerLen = "header_len"
            case nonceLen = "nonce_len"
            case tagLen = "tag_len"
        }

        /// Bytes on the wire for one chunk: nonce, body, tag.
        var encryptedChunkStride: Int { nonceLen + chunkSize + tagLen }
    }

    struct IndexEntry: Codable {
        let path: String
        let bytes: Int64
        let sha256: String
    }

    private struct Index: Codable { let files: [IndexEntry] }

    // MARK: - Errors

    enum Failure: LocalizedError {
        case unsupportedSchema(Int)
        case badCipherMagic
        case badContainerMagic
        case sizeMismatch(expected: Int64, got: Int64)
        case digestMismatch(String)
        case truncated
        case decompressionFailed
        case pathEscapesRoot(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let n):
                return "Polish model manifest schema \(n) is newer than this build understands"
            case .badCipherMagic:      return "Polish model download is not a Whisperer package"
            case .badContainerMagic:   return "Polish model package is corrupt"
            case .sizeMismatch(let e, let g):
                return "Polish model unpacked to \(g) bytes, expected \(e)"
            case .digestMismatch(let what):
                return "Polish model failed its integrity check (\(what))"
            case .truncated:           return "Polish model download is incomplete"
            case .decompressionFailed: return "Polish model could not be decompressed"
            case .pathEscapesRoot(let p):
                return "Polish model package contains an unsafe path (\(p))"
            }
        }
    }

    // MARK: - Constants

    static let supportedSchema = 3
    private static let cipherMagic = Array("WHSPMDL1".utf8)
    private static let containerMagic: [UInt8] = Array("WPKG1".utf8) + [0, 0, 0]

    // MARK: - Install

    /// Decrypt, decompress and write the package into `destination`.
    ///
    /// Single pass, bounded memory: no stage ever holds more than one chunk plus
    /// whatever of the current file has not yet been flushed. `destination` is
    /// created fresh; callers stage into a temporary directory and rename, so a
    /// crash mid-write cannot leave a half-model that looks installed.
    ///
    /// - Parameter progress: fraction of ciphertext consumed, 0...1. Called on the
    ///   calling queue, roughly once per 4 MiB chunk.
    static func install(ciphertextAt source: URL,
                        manifest: Manifest,
                        keyHex: String,
                        destination: URL,
                        progress: (Double) -> Void,
                        isCancelled: () -> Bool) throws -> [IndexEntry] {
        guard manifest.schema <= supportedSchema else {
            throw Failure.unsupportedSchema(manifest.schema)
        }
        let key = SymmetricKey(data: Data(hexString: keyHex))

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }

        let header = try reader.read(upToCount: manifest.headerLen) ?? Data()
        guard header.count == manifest.headerLen,
              Array(header.prefix(cipherMagic.count)) == cipherMagic else {
            throw Failure.badCipherMagic
        }

        var decoder = try LZFSEDecoder()
        defer { decoder.finish() }

        var writer = try ContainerWriter(destination: destination)
        var plainDigest = SHA256()
        var plainTotal: Int64 = 0
        var chunkIndex = 0

        while chunkIndex < manifest.chunks {
            if isCancelled() { throw CancellationError() }
            guard let wire = try reader.read(upToCount: manifest.encryptedChunkStride),
                  wire.count > manifest.nonceLen + manifest.tagLen else {
                throw Failure.truncated
            }
            // AAD = header || big-endian chunk index. Binds position and build.
            var aad = header
            withUnsafeBytes(of: UInt32(chunkIndex).bigEndian) { aad.append(contentsOf: $0) }
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: wire.prefix(manifest.nonceLen)),
                ciphertext: wire.dropFirst(manifest.nonceLen).dropLast(manifest.tagLen),
                tag: wire.suffix(manifest.tagLen))
            let compressed = try AES.GCM.open(box, using: key, authenticating: aad)

            try decoder.push(compressed, final: chunkIndex == manifest.chunks - 1) { plain in
                plainDigest.update(data: plain)
                plainTotal += Int64(plain.count)
                try writer.consume(plain)
            }

            chunkIndex += 1
            progress(Double(chunkIndex) / Double(manifest.chunks))
        }

        guard plainTotal == manifest.uncompressedBytes else {
            throw Failure.sizeMismatch(expected: manifest.uncompressedBytes, got: plainTotal)
        }
        guard plainDigest.finalize().hexString == manifest.uncompressedSha256 else {
            throw Failure.digestMismatch("payload")
        }
        return try writer.finish(expecting: manifest.files)
    }

    // MARK: - Container writer

    /// Consumes the decompressed byte stream: reads the index off the front, then
    /// splits the remainder into files, hashing each as it lands.
    private struct ContainerWriter {
        private let destination: URL
        private var head = Data()
        private var entries: [IndexEntry] = []
        private var queue: ArraySlice<IndexEntry> = [][...]
        private var handle: FileHandle?
        private var current: IndexEntry?
        private var written: Int64 = 0
        private var digest = SHA256()
        private var completed: [IndexEntry] = []

        init(destination: URL) throws {
            self.destination = destination
            try FileManager.default.createDirectory(at: destination,
                                                    withIntermediateDirectories: true)
        }

        mutating func consume(_ block: Data) throws {
            var rest = block
            if entries.isEmpty {
                head.append(rest)
                let prefix = containerMagic.count + 4
                guard head.count >= prefix else { return }
                guard Array(head.prefix(containerMagic.count)) == containerMagic else {
                    throw Failure.badContainerMagic
                }
                let length = Int(UInt32(bigEndian: head
                    .subdata(in: containerMagic.count..<prefix)
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                guard head.count >= prefix + length else { return }
                let json = head.subdata(in: prefix..<(prefix + length))
                entries = try JSONDecoder().decode(Index.self, from: json).files
                queue = entries[...]
                rest = head.subdata(in: (prefix + length)..<head.count)
                head = Data()
                try openNext()
            }

            while !rest.isEmpty, let entry = current, let out = handle {
                let take = Int(min(entry.bytes - written, Int64(rest.count)))
                let slice = rest.prefix(take)
                out.write(slice)
                digest.update(data: slice)
                written += Int64(take)
                rest = rest.dropFirst(take)
                if written == entry.bytes {
                    try out.close()
                    guard digest.finalize().hexString == entry.sha256 else {
                        throw Failure.digestMismatch(entry.path)
                    }
                    completed.append(entry)
                    try openNext()
                }
            }
        }

        private mutating func openNext() throws {
            handle = nil
            current = queue.popFirst()
            written = 0
            digest = SHA256()
            guard let entry = current else { return }

            // The index is ours, but treat it as untrusted anyway: a `..` here
            // would write outside Application Support.
            let url = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard url.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw Failure.pathEscapesRoot(entry.path)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        mutating func finish(expecting count: Int) throws -> [IndexEntry] {
            guard current == nil, queue.isEmpty, completed.count == count else {
                throw Failure.truncated
            }
            return completed
        }
    }

    // MARK: - LZFSE

    /// Streaming LZFSE decode over `Compression.framework`.
    ///
    /// LZFSE rather than xz: measured on this 177 MB payload, xz is 2.7 MB smaller
    /// but takes 5.53 s to decode against LZFSE's 0.22 s. At any realistic link
    /// speed the smaller file loses. See `Tools/mmbert/lzfse_tool.swift`.
    private struct LZFSEDecoder {
        private let bufferSize = 1 << 20
        private let out: UnsafeMutablePointer<UInt8>
        private var stream: compression_stream
        private var done = false

        init() throws {
            out = .allocate(capacity: bufferSize)
            stream = compression_stream(dst_ptr: out, dst_size: bufferSize,
                                        src_ptr: UnsafePointer(out), src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE,
                                          COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
                out.deallocate()
                throw Failure.decompressionFailed
            }
            stream.dst_ptr = out
            stream.dst_size = bufferSize
        }

        mutating func push(_ input: Data, final: Bool,
                           _ emit: (Data) throws -> Void) throws {
            let flags = final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            // `withUnsafeBytes` must span every process() call that reads src_ptr.
            try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                stream.src_ptr = raw.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(out)
                stream.src_size = raw.count
                repeat {
                    let status = compression_stream_process(&stream, flags)
                    if status == COMPRESSION_STATUS_ERROR { throw Failure.decompressionFailed }
                    let produced = bufferSize - stream.dst_size
                    if produced > 0 {
                        try emit(Data(bytes: out, count: produced))
                        stream.dst_ptr = out
                        stream.dst_size = bufferSize
                    }
                    if status == COMPRESSION_STATUS_END { done = true; return }
                } while stream.src_size > 0 || flags != 0
            }
        }

        mutating func finish() {
            compression_stream_destroy(&stream)
            out.deallocate()
        }
    }
}

// MARK: - Small helpers

private extension Data {
    init(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex,
              let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) {
            bytes.append(UInt8(hexString[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}

private extension SHA256.Digest {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
