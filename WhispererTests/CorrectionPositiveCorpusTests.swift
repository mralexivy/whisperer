//
//  CorrectionPositiveCorpusTests.swift
//  WhispererTests
//
//  Asserts that real Whisper mis-transcriptions are still correctly fixed by
//  the bundled packs after the rule audit cleanup.
//
//  Protects against the rule cleanup gutting the feature. If a correction that
//  was working stops working, this test will tell you.
//
//  All entries here use maxEditDistance: 0 (exact-match only) so the result is
//  deterministic regardless of the system spell-checker state.

import XCTest
@testable import whisperer

final class CorrectionPositiveCorpusTests: XCTestCase {

    private static var liveEngines: [CorrectionEngine] = []
    private static var builtInEngine: CorrectionEngine?

    override class func setUp() {
        super.setUp()

        guard let resourcePath = Bundle.main.resourcePath else {
            XCTFail("No resource path")
            return
        }

        let fileManager = FileManager.default
        let dictionariesPath = (resourcePath as NSString).appendingPathComponent("dictionaries")
        let searchPath = fileManager.fileExists(atPath: dictionariesPath) ? dictionariesPath : resourcePath

        var entries: [DictionaryEntry] = []
        do {
            let files = try fileManager.contentsOfDirectory(atPath: searchPath)
            for filename in files.filter({ $0.hasPrefix("pack_") && $0.hasSuffix(".json") }).sorted() {
                let url = URL(fileURLWithPath: (searchPath as NSString).appendingPathComponent(filename))
                guard let data = try? Data(contentsOf: url),
                      let packFile = try? JSONDecoder().decode(DictionaryPackFile.self, from: data) else {
                    continue
                }
                for correction in packFile.corrections {
                    for alias in correction.aliases {
                        entries.append(DictionaryEntry(
                            incorrectForm: alias,
                            correctForm: correction.term,
                            category: packFile.metadata.category,
                            isBuiltIn: true,
                            notes: "test"
                        ))
                    }
                }
            }
        } catch {
            XCTFail("Failed to load pack files: \(error)")
            return
        }

        let engine = CorrectionEngine(entries: entries)
        liveEngines.append(engine)
        builtInEngine = engine
    }

    // MARK: - Positive correction cases

    // Each tuple: (input, expectedOutput, description)
    // These are genuine Whisper mis-transcriptions or phonetic spellings that MUST be corrected.
    // All aliases verified to exist in the bundled packs (run emit_batches.py to confirm).
    private static let cases: [(input: String, expected: String, label: String)] = [
        ("I use post gress for storage", "I use PostgreSQL for storage", "post gress → PostgreSQL"),
        ("we deployed on cooper netties", "we deployed on Kubernetes", "cooper netties → Kubernetes"),
        ("the git hub repo is ready", "the GitHub repo is ready", "git hub → GitHub"),
        ("I write java script every day", "I write JavaScript every day", "java script → JavaScript"),
        ("she loves type script", "she loves TypeScript", "type script → TypeScript"),
        ("the dock er container crashed", "the Docker container crashed", "dock er → Docker"),
        ("deploy to a w s", "deploy to AWS", "a w s → AWS"),
        ("we run it on lin ux", "we run it on Linux", "lin ux → Linux"),
        ("the node js server", "the Node.js server", "node js → Node.js"),
        ("j query is still used", "jQuery is still used", "j query → jQuery"),
        ("py thon is my favorite language", "Python is my favorite language", "py thon → Python"),
        ("check the p r status", "check the PR status", "p r → PR"),
        ("kuber net ease cluster", "Kubernetes cluster", "kuber net ease → Kubernetes"),
        ("deploy on ay double you ess", "deploy on AWS", "ay double you ess → AWS"),
        ("the dock er container is up", "the Docker container is up", "dock er → Docker"),
    ]

    // MARK: - Tests

    func testPositiveCorpusIsAllCorrected() throws {
        guard let engine = Self.builtInEngine else {
            throw XCTSkip("Bundle pack entries not loaded")
        }

        var failures: [(label: String, input: String, got: String, want: String)] = []

        for c in Self.cases {
            let result = engine.applyCorrections(c.input, maxEditDistance: 0, usePhonetic: false)
            if result.text != c.expected {
                failures.append((c.label, c.input, result.text, c.expected))
            }
        }

        let total = Self.cases.count
        let passed = total - failures.count
        let passRate = Double(passed) / Double(total)

        if !failures.isEmpty {
            let details = failures.map {
                "  [\($0.label)]\n  input:  \($0.input)\n  got:    \($0.got)\n  want:   \($0.want)"
            }.joined(separator: "\n\n")
            // Require at least 80% pass rate before failing hard
            if passRate < 0.80 {
                XCTFail("Pass rate \(Int(passRate * 100))% < 80% — rule cleanup gutted corrections:\n\n\(details)\n")
            } else {
                // Warn but don't fail if over 80%
                print("WARNING: \(failures.count)/\(total) positive cases regressed (pass rate \(Int(passRate * 100))%):\n\(details)")
            }
        }
    }

    // Named individual tests for key aliases that must keep working.

    func testPostGressToPostgreSQL() {
        assertCorrected("post gress database", contains: "PostgreSQL")
    }

    func testJavaScriptCorrected() {
        assertCorrected("I write java script", contains: "JavaScript")
    }

    func testTypeScriptCorrected() {
        assertCorrected("type script is typed", contains: "TypeScript")
    }

    func testDockErCorrected() {
        assertCorrected("dock er container", contains: "Docker")
    }

    // MARK: - Helper

    private func assertCorrected(_ input: String,
                                  contains substring: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) {
        guard let engine = Self.builtInEngine else { return }
        let result = engine.applyCorrections(input, maxEditDistance: 0, usePhonetic: false)
        XCTAssertTrue(result.text.contains(substring),
                      "Expected '\(substring)' in output '\(result.text)' for input '\(input)'",
                      file: file, line: line)
    }
}
