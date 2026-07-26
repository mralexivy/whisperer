//
//  HistoryTestLoader.swift
//  WhispererTests
//
//  Reads real transcription records from the app's history SQLite database.
//  Uses the sqlite3 C API directly — no CoreData bootstrap needed in tests.
//

import Foundation
import SQLite3

// MARK: - RecordingFixture

struct RecordingFixture {
    let id: String
    let durationSec: Double
    let transcript: String          // raw whisper output — ZTRANSCRIPTION
    let aiEnhancedText: String?     // stored LLM output — ZAIENHANCEDTEXT
    let aiModeName: String?         // "Correct", "Grammar", etc. — ZAIMODENAME
    let language: String            // "en", "he", "ru" — ZLANGUAGE
    let audioURL: URL?              // resolved .wav path (nil if file missing on disk)
    let wordCount: Int

    var durationBucket: String {
        switch durationSec {
        case ..<15:  return "short"
        case ..<45:  return "medium"
        case ..<120: return "long"
        default:     return "very-long"
        }
    }
}

// MARK: - HistoryTestLoader

enum HistoryTestLoader {

    /// Loads recording fixtures from the app's history SQLite database.
    /// Tries both the non-sandbox and sandbox paths. Only returns fixtures
    /// whose `.wav` audio file actually exists on disk.
    static func loadFixtures(maxCount: Int = 300) -> [RecordingFixture] {
        guard let (dbPath, recordingsDir) = findDatabase() else {
            print("⚠️  HistoryTestLoader: No history.sqlite found at expected paths")
            return []
        }
        return query(dbPath: dbPath, recordingsDir: recordingsDir, limit: maxCount)
    }

    // MARK: - Private

    private static func findDatabase() -> (dbPath: String, recordingsDir: URL)? {
        let candidates: [URL] = [
            // Sandbox path first — when the app runs from Xcode with entitlements it writes
            // here even in Debug mode. This DB has the full recording history.
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/com.ivy.whisperer/Data/Library/Application Support/Whisperer/history.sqlite"),
            // Non-sandbox fallback (direct distribution / CI without entitlements)
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Whisperer/history.sqlite"),
        ]

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let dir = url.deletingLastPathComponent().appendingPathComponent("Recordings")
            return (url.path, dir)
        }
        return nil
    }

    private static func query(dbPath: String, recordingsDir: URL, limit: Int) -> [RecordingFixture] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            print("⚠️  HistoryTestLoader: Cannot open \(dbPath)")
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT ZID, ZDURATION, ZTRANSCRIPTION, ZWORDCOUNT, ZLANGUAGE,
                   ZAUDIOFILEURL, ZAIENHANCEDTEXT, ZAIMODENAME
            FROM ZTRANSCRIPTIONENTITY
            WHERE ZISINPROGRESS = 0
              AND ZTRANSCRIPTION IS NOT NULL
              AND length(ZTRANSCRIPTION) > 20
              AND (ZTARGETAPPNAME IS NULL OR ZTARGETAPPNAME != 'File Import')
            ORDER BY CASE WHEN ZAUDIOFILEURL IS NOT NULL THEN 0 ELSE 1 END ASC,
                     ABS(CAST(ZDURATION AS REAL) - 20.0) ASC
            LIMIT ?;
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("⚠️  HistoryTestLoader: Failed to prepare query")
            return []
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var fixtures: [RecordingFixture] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = column(stmt, 0) ?? UUID().uuidString
            let duration = sqlite3_column_double(stmt, 1)
            guard let transcript = column(stmt, 2), !transcript.isEmpty else { continue }
            let wordCount = Int(sqlite3_column_int(stmt, 3))
            let language = column(stmt, 4) ?? "en"
            let audioFile = column(stmt, 5)
            let aiEnhanced = column(stmt, 6)
            let aiMode = column(stmt, 7)

            let audioURL = resolvedAudioURL(filename: audioFile, dir: recordingsDir)

            fixtures.append(RecordingFixture(
                id: id,
                durationSec: duration,
                transcript: transcript,
                aiEnhancedText: aiEnhanced,
                aiModeName: aiMode,
                language: language,
                audioURL: audioURL,
                wordCount: wordCount
            ))
        }

        print("HistoryTestLoader: loaded \(fixtures.count) fixtures from \(dbPath)")
        return fixtures
    }

    private static func column(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    private static func resolvedAudioURL(filename: String?, dir: URL) -> URL? {
        guard let filename, !filename.isEmpty else { return nil }
        // ZAUDIOFILEURL may be a bare filename or a full path
        let candidate: URL
        if filename.hasPrefix("/") {
            candidate = URL(fileURLWithPath: filename)
        } else {
            candidate = dir.appendingPathComponent(filename)
        }
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }
}
