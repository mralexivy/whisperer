//
//  StorageUsage.swift
//  Whisperer
//
//  How much disk the app uses, by what — recordings, transcripts, models, caches — and what share
//  of the disk that is. Read-only: it measures, it never deletes.
//
//  Sizes are *allocated* bytes (what the file actually costs on disk, as Finder's "Size on disk"
//  and System Settings → Storage report), not logical length, so the bar adds up with what the
//  user sees elsewhere. The scan is one pass over a few folders, run off the main actor.
//

import Foundation
import Combine

nonisolated enum StorageCategory: String, CaseIterable, Sendable, Identifiable {
    case meetingRecordings, dictationRecordings, transcripts, models, caches

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meetingRecordings: return "Meeting recordings"
        case .dictationRecordings: return "Dictation recordings"
        case .transcripts: return "Transcripts & data"
        case .models: return "Models"
        case .caches: return "Caches & logs"
        }
    }

    var detail: String {
        switch self {
        case .meetingRecordings: return "Audio of every meeting"
        case .dictationRecordings: return "Audio behind each dictation"
        case .transcripts: return "Text, summaries, notes, chats"
        case .models: return "Speech and language models — downloaded again when needed"
        case .caches: return "Temporary files, safe to clear"
        }
    }
}

nonisolated struct StorageSlice: Equatable, Sendable, Identifiable {
    var category: StorageCategory
    var bytes: Int64
    var files: Int
    var id: String { category.rawValue }
}

nonisolated struct StorageBreakdown: Equatable, Sendable {
    var slices: [StorageSlice]
    /// The volume the library lives on.
    var diskName: String?
    var diskTotal: Int64
    var diskAvailable: Int64

    var total: Int64 { slices.reduce(0) { $0 + $1.bytes } }
    /// What other apps and the system use: everything on the disk that is neither free nor ours.
    var otherUsed: Int64 { max(0, diskTotal - diskAvailable - total) }
    func slice(_ category: StorageCategory) -> StorageSlice { slices.first { $0.category == category } ?? StorageSlice(category: category, bytes: 0, files: 0) }
    var share: Double { diskTotal > 0 ? Double(total) / Double(diskTotal) : 0 }

    static let empty = StorageBreakdown(slices: StorageCategory.allCases.map { StorageSlice(category: $0, bytes: 0, files: 0) },
                                        diskName: nil, diskTotal: 0, diskAvailable: 0)
}

nonisolated enum StorageUsage {

    /// A folder to measure and how to file what is in it. `classify` gets the path *relative to
    /// the root* and returns the category, or nil to skip.
    struct Location: Sendable {
        var root: URL
        var classify: @Sendable (_ relative: String) -> StorageCategory?
    }

    private static let audioExtensions: Set<String> = ["opus", "caf", "wav", "m4a", "mp3", "aac", "flac"]

    /// The app's own folders, as filed by the rules in `classifyLibrary`.
    static var appLocations: [Location] {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Whisperer")
        return [
            Location(root: AudioLibraryPaths.root, classify: classifyLibrary),
            Location(root: support.appendingPathComponent("FluidAudio"), classify: { _ in .models }),
            Location(root: caches.appendingPathComponent("com.ivy.whisperer"), classify: { _ in .caches }),
            Location(root: logs, classify: { _ in .caches }),
        ]
    }

    /// Files in `Application Support/Whisperer`.
    @Sendable
    static func classifyLibrary(_ relative: String) -> StorageCategory? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return nil }
        let ext = (relative as NSString).pathExtension.lowercased()
        switch first {
        case "Recordings":
            return parts.count > 1 && parts[1] == "Meetings" ? .meetingRecordings : .dictationRecordings
        case "Sessions":
            return .meetingRecordings
        case "Meetings":
            return audioExtensions.contains(ext) ? .meetingRecordings : .transcripts
        case "ChatHistory":
            return .transcripts
        case "PolishModel", "whisperkit":
            return .models
        case "AppIcons":
            return .caches
        default:
            if first.hasPrefix("history.sqlite") { return .transcripts }
            if first.hasPrefix("ggml-") || ext == "bin" || ext == "mlmodelc" || ext == "safetensors" { return .models }
            return .caches
        }
    }

    /// One pass over `locations`. `diskOf` is the folder whose volume is reported (defaults to the
    /// first location).
    static func scan(_ locations: [Location] = appLocations, diskOf: URL? = nil) -> StorageBreakdown {
        let fm = FileManager.default
        var bytes: [StorageCategory: Int64] = [:]
        var files: [StorageCategory: Int] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        for location in locations {
            guard fm.fileExists(atPath: location.root.path),
                  let walker = fm.enumerator(at: location.root, includingPropertiesForKeys: keys,
                                             options: [], errorHandler: { _, _ in true }) else { continue }
            let prefix = location.root.standardizedFileURL.path + "/"
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let path = url.standardizedFileURL.path
                let relative = path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
                guard let category = location.classify(relative) else { continue }
                bytes[category, default: 0] += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
                files[category, default: 0] += 1
            }
        }
        let anchor = diskOf ?? locations.first?.root ?? URL(fileURLWithPath: "/")
        let disk = diskInfo(at: anchor)
        return StorageBreakdown(
            slices: StorageCategory.allCases.map { StorageSlice(category: $0, bytes: bytes[$0] ?? 0, files: files[$0] ?? 0) },
            diskName: disk.name, diskTotal: disk.total, diskAvailable: disk.available)
    }

    static func diskInfo(at url: URL) -> (name: String?, total: Int64, available: Int64) {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let v = try? probe.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey,
                                                    .volumeAvailableCapacityForImportantUsageKey])
        return (v?.volumeName, Int64(v?.volumeTotalCapacity ?? 0), v?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// Widths for the segments of a bar `width` points wide with `spacing` between them. Proportional
    /// to bytes, except that a slice that exists is never thinner than `minimum` — a 40 MB database
    /// next to 3 GB of audio is still a visible, hoverable segment — and the rest give up exactly what
    /// that costs, so the bar always fills the width.
    static func widths(for values: [Int64], width: CGFloat, spacing: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let present = values.indices.filter { values[$0] > 0 }
        guard !present.isEmpty, width > 0 else { return values.map { _ in 0 } }
        let room = max(0, width - spacing * CGFloat(present.count - 1))
        var result = [CGFloat](repeating: 0, count: values.count)
        var pinned = Set<Int>()
        var remaining = room
        var weight = Double(present.reduce(Int64(0)) { $0 + values[$1] })
        // Pin the thin ones at the minimum, then share what is left among the others by their bytes.
        var changed = true
        while changed {
            changed = false
            for i in present where !pinned.contains(i) {
                if remaining * CGFloat(Double(values[i]) / weight) < minimum {
                    pinned.insert(i); result[i] = minimum
                    remaining -= minimum; weight -= Double(values[i]); changed = true
                    break
                }
            }
        }
        for i in present where !pinned.contains(i) {
            result[i] = weight > 0 ? max(0, remaining) * CGFloat(Double(values[i]) / weight) : 0
        }
        return result
    }
}

// MARK: - Model

@MainActor
final class StorageUsageModel: ObservableObject {
    @Published private(set) var breakdown: StorageBreakdown = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false

    private let locations: [StorageUsage.Location]
    private var task: Task<Void, Never>?
    /// Tests inject a breakdown and must not have it replaced by a real scan on appear.
    private var frozen = false

    init(locations: [StorageUsage.Location]? = nil) {
        self.locations = locations ?? StorageUsage.appLocations
    }

    func refresh() {
        guard !isScanning, !frozen else { return }
        isScanning = true
        let locations = locations
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { StorageUsage.scan(locations) }.value
            guard !Task.isCancelled else { return }
            self?.breakdown = result
            self?.isScanning = false
            self?.hasScanned = true
        }
    }

    #if DEBUG
    func setForTesting(_ breakdown: StorageBreakdown, scanning: Bool = false, scanned: Bool = true) {
        self.breakdown = breakdown; isScanning = scanning; hasScanned = scanned; frozen = true
    }
    #endif
}
