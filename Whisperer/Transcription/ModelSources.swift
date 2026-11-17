//
//  ModelSources.swift
//  Whisperer
//
//  Where model weights are downloaded from, per market. huggingface.co is the source everywhere except
//  mainland China, where it is unreliable: there the same weights come from ModelScope (modelscope.cn),
//  which hosts the official Qwen models, the mlx-community re-uploads and a few community copies.
//
//  A file is offered in China only when the table below says ModelScope carries it. Anything without a
//  China source is hidden from the pickers (`isReachable`) instead of failing to download. Checksums pinned
//  in `ModelChecksums` still guard every whisper.cpp / VAD file, and ModelScope's own per-file SHA-256 guards
//  the rest. `scripts/verify-china-models.sh` checks every entry before a China build is submitted.
//
//  Adding a file for China: upload it to ModelScope under `mralexivy/whisperer-models` with the same file
//  name it has on Hugging Face, add it to `ownFiles`, run the verify script.
//

import Foundation
import CryptoKit

nonisolated enum ModelHost: String, Sendable {
    case huggingFace, modelScope
}

nonisolated enum ModelSources {

    /// The host this market downloads from.
    static var host: ModelHost { MarketPolicy.current == .chinaMainland ? .modelScope : .huggingFace }

    // MARK: ModelScope catalogue

    /// Repos that exist on ModelScope under the same id as on Hugging Face (verified against the file-list API).
    static let sameIdRepos: Set<String> = [
        "ggml-org/whisper-vad",
        "mlx-community/Qwen3-ASR-1.7B-8bit",
        "mlx-community/Qwen3.5-2B-MLX-4bit",
        "mlx-community/Qwen3.5-4B-MLX-4bit",
        "mlx-community/Qwen3.5-9B-MLX-4bit",
        "mlx-community/Qwen2.5-1.5B-Instruct-8bit",
        "argmaxinc/whisperkit-coreml",
    ]

    /// whisper.cpp weights come from a community re-upload. The bytes were compared with our pinned
    /// checksums (ggml-base.bin matches exactly), and the downloader still verifies every file.
    static let whisperCppRepo = "ggerganov/whisper.cpp"
    static let whisperCppModelScopeRepo = "cjc1887415157/whisper.cpp"
    static let whisperCppFiles: Set<String> = [
        "ggml-base.bin", "ggml-small.bin", "ggml-medium.bin", "ggml-large-v3.bin", "ggml-large-v3-q5_0.bin",
    ]

    /// Our own ModelScope repo for files nobody else mirrors (the turbo models, distil, Hebrew, the polish
    /// tagger). Empty until they are uploaded — a file listed here must really be there.
    static let ownRepo = "mralexivy/whisperer-models"
    static let ownFiles: Set<String> = []

    /// The ModelScope repo that carries `file` of `repo`, or nil when ModelScope does not.
    static func modelScopeRepo(for repo: String, file: String? = nil) -> String? {
        if repo == whisperCppRepo {
            guard let file else { return whisperCppModelScopeRepo }
            if whisperCppFiles.contains(file) { return whisperCppModelScopeRepo }
            return ownFiles.contains(file) ? ownRepo : nil
        }
        if let file, ownFiles.contains(file) { return ownRepo }
        return sameIdRepos.contains(repo) ? repo : nil
    }

    /// Whether the weights can be downloaded in this market.
    static func isReachable(repo: String, file: String? = nil) -> Bool {
        host == .huggingFace || modelScopeRepo(for: repo, file: file) != nil
    }

    static func modelScopeFileURL(repo: String, path: String) -> URL {
        URL(string: "https://modelscope.cn/models/\(repo)/resolve/master/\(path)")!
    }

    static func modelScopeListURL(repo: String) -> URL {
        URL(string: "https://www.modelscope.cn/api/v1/models/\(repo)/repo/files?Recursive=true&Revision=master")!
    }

    /// The URL for a single file in this market: Hugging Face as given, or the ModelScope copy.
    static func resolve(huggingFaceURL: URL, repo: String, file: String) -> URL {
        guard host == .modelScope, let target = modelScopeRepo(for: repo, file: file) else { return huggingFaceURL }
        return modelScopeFileURL(repo: target, path: file)
    }
}

// MARK: - Snapshot download from ModelScope

/// Downloads a repo's files (filtered by globs) into a directory, the way `HubApi.snapshot` does for Hugging Face,
/// so the loaders that read a local model directory work unchanged.
nonisolated enum ModelScopeFetcher {

    struct Entry: Equatable {
        let path: String
        let size: Int64
        let sha256: String?
    }

    enum FetchError: LocalizedError {
        case listing(String)
        case http(Int, String)
        case checksum(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .listing(let repo): return "Couldn't read the model list for \(repo)."
            case .http(let code, let file): return "Download failed (\(code)) for \(file)."
            case .checksum(let file): return "\(file) didn't download correctly. Try again."
            case .empty(let repo): return "No files to download for \(repo)."
            }
        }
    }

    /// Entries of the ModelScope file-list JSON that match any glob. Pure, so it is tested.
    static func entries(fromListing data: Data, matching globs: [String]) throws -> [Entry] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["Code"] as? Int) == 200,
              let files = (root["Data"] as? [String: Any])?["Files"] as? [[String: Any]] else {
            throw FetchError.listing("")
        }
        return files.compactMap { file in
            guard (file["Type"] as? String) == "blob", let path = file["Path"] as? String else { return nil }
            guard globs.isEmpty || globs.contains(where: { matches(path, glob: $0) }) else { return nil }
            let size = (file["Size"] as? NSNumber)?.int64Value ?? 0
            return Entry(path: path, size: size, sha256: file["Sha256"] as? String)
        }
    }

    /// `*` matches anything except a slash, as in the globs the loaders pass (`*.safetensors`, `*.json`).
    static func matches(_ path: String, glob: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let target = glob.contains("/") ? path : name
        return fnmatch(glob, target, 0) == 0
    }

    static func snapshot(repo: String, globs: [String], into directory: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let (listing, response) = try await URLSession.shared.data(from: ModelSources.modelScopeListURL(repo: repo))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FetchError.listing(repo) }
        let entries = try entries(fromListing: listing, matching: globs)
        guard !entries.isEmpty else { throw FetchError.empty(repo) }

        let total = max(1, entries.reduce(0) { $0 + $1.size })
        var done: Int64 = 0
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for entry in entries {
            let destination = directory.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A file that is already there with the right size and hash is kept (a retry resumes at the next file).
            if let existing = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64,
               existing == entry.size, verify(destination, sha256: entry.sha256) {
                done += entry.size
                progress(Double(done) / Double(total))
                continue
            }
            let url = ModelSources.modelScopeFileURL(repo: repo, path: entry.path)
            let (temp, fileResponse) = try await URLSession.shared.download(from: url)
            let status = (fileResponse as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw FetchError.http(status, entry.path) }
            guard verify(temp, sha256: entry.sha256) else {
                try? FileManager.default.removeItem(at: temp)
                throw FetchError.checksum(entry.path)
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
            done += entry.size
            progress(Double(done) / Double(total))
        }
        progress(1)
    }

    /// SHA-256 of a file, streamed; true when no hash is known.
    static func verify(_ file: URL, sha256 expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected.lowercased()
    }
}
