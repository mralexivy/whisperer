//
//  WisprDictionaryImporter.swift
//  Whisperer
//
//  DEBUG-ONLY. Seeds the correction learner from a local Wispr Flow install.
//
//  This exists so the learner can be exercised against a year of real corrections on the
//  developer's own machine instead of waiting for the corpus to accumulate. It is compiled out
//  of Release and AppStore entirely: no Wispr data ships, nothing about it reaches other users,
//  and the app never writes to Wispr's database — it is opened `immutable=1`, read-only.
//
//  What it imports: only rows that carry an `observedSource`, i.e. pairs Wispr's own learner
//  mined from a mishearing. Those are the same shape as our candidates.
//
//  What it deliberately skips:
//    - Vocabulary-only rows (a name, an email address). Those would belong in prompt words, and
//      decoder-side biasing was measured and rejected (`3e343fc`, +0.0142 WER).
//    - Snippets and manual expansions (`btw → by the way`). Those are macros the user authored in
//      another app's idiom, not corrections, and importing them would silently rewrite dictation.
//
//  Everything imported lands in the suggestion store, never straight into the dictionary — even
//  the pairs that would clear the automatic gates. A bulk import is not a correction the user
//  just made, so it does not get the trust that a live correction gets.
//

#if DEBUG

import Foundation
import SQLite3

enum WisprDictionaryImporter {
    struct Report: Sendable {
        var pairsFound = 0
        var imported = 0
        var skippedVocabulary = 0
        var skippedSnippets = 0
        var skippedTombstoned = 0
        var skippedAlreadyKnown = 0

        var summary: String {
            "imported \(imported)/\(pairsFound) pairs "
            + "(skipped: \(skippedVocabulary) vocab, \(skippedSnippets) snippets, "
            + "\(skippedTombstoned) tombstoned, \(skippedAlreadyKnown) already known)"
        }
    }

    enum ImportError: LocalizedError {
        case databaseNotFound(URL)
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound(let url):
                return "No Wispr Flow database at \(url.path)"
            case .openFailed(let message):
                return "Could not open the Wispr Flow database: \(message)"
            }
        }
    }

    static var defaultDatabaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Wispr Flow/flow.sqlite")
    }

    /// Reads the Wispr dictionary and files every usable pair as a suggestion for review.
    @MainActor
    @discardableResult
    static func run(databaseURL: URL = defaultDatabaseURL) async throws -> Report {
        let rows = try readRows(at: databaseURL)
        var report = Report()

        let tombstones = await CorrectionTombstoneStore.shared.all()
        let existing = Set(DictionaryManager.shared.entries.map(\.incorrectForm))

        for row in rows {
            if row.replacement?.isEmpty == false {
                report.skippedSnippets += 1
                continue
            }
            guard let observed = row.observedSource, !observed.isEmpty else {
                report.skippedVocabulary += 1
                continue
            }
            report.pairsFound += 1

            let observedKey = observed.lowercased()
            guard !tombstones.contains(observedKey) else {
                report.skippedTombstoned += 1
                continue
            }
            guard !existing.contains(observedKey) else {
                report.skippedAlreadyKnown += 1
                continue
            }
            // The gates still run: a pair Wispr accepted that our promotion logic would reject
            // outright (multi-word, cross-script, numeric) should not become a suggestion either.
            if case .rejected = CorrectionPromotion.evaluate(
                observed: observed,
                corrected: row.phrase,
                tombstones: tombstones
            ) {
                continue
            }
            await CorrectionSuggestionStore.shared.record(observed, row.phrase)
            report.imported += 1
        }

        Logger.info("Wispr dictionary import: \(report.summary)", subsystem: .app)
        return report
    }

    // MARK: - SQLite

    private struct Row {
        let phrase: String
        let replacement: String?
        let observedSource: String?
    }

    private static func readRows(at url: URL) throws -> [Row] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.databaseNotFound(url)
        }

        // `immutable=1` promises SQLite the file will not change, which lets it open without a
        // write-ahead log or any lock — we must never disturb a running Wispr install.
        var handle: OpaquePointer?
        let uri = "file:\(url.path)?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw ImportError.openFailed(message)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT phrase, replacement, observedSource
            FROM Dictionary
            WHERE isDeleted = 0 AND manualEntry = 0
            ORDER BY frequencyUsed DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let stmt = statement else {
            throw ImportError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let phrase = column(stmt, 0) else { continue }
            rows.append(Row(
                phrase: phrase,
                replacement: column(stmt, 1),
                observedSource: column(stmt, 2)
            ))
        }
        return rows
    }

    private static func column(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }
}

#endif
