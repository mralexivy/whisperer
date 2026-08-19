//
//  AuthoredGold.swift
//  WhispererTests
//
//  Loader for the LLM-authored gold corpora under `Tools/llm-eval/authoring/`.
//
//  One loader rather than one per test, because three tests now read these files and a private
//  `Decodable` in each is three chances to disagree about which field is the reference.
//
//  **What this corpus is, stated once so every caller inherits it.** The gold is authored from the
//  raw transcripts by an LLM and re-checked by an independent one, gated on script identity and
//  content-word similarity. It is good enough to detect *damage* between two arms scored against
//  the same reference, and to score punctuation. It is **not human truth**, and no absolute claim
//  may be made from a figure computed on it. It also encodes arm B's own edit policy, so it is a
//  second reference, not a neutral one — which is exactly why rule 5 requires a cell to clear its
//  bar here *and* against the whole-file `goldenTranscript` decode.
//

import Foundation

enum AuthoredGold {

    struct Case: Decodable {
        let id: String
        let language: String
        let input: String
        let gold: String
    }

    private struct Corpus: Decodable {
        let cases: [Case]
    }

    /// The reporting floor. Below it a language is `unmeasured`, never a point estimate — the same
    /// rule `assemble_gold.py` applies, restated because there is no shared constant across the
    /// two languages.
    static let minimumN = 20

    /// `#filePath` rather than the bundle: `Tools/` is not a test resource and is never copied in.
    static var evalDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()         // .../WhispererTests/Helpers
            .deletingLastPathComponent()         // .../WhispererTests
            .deletingLastPathComponent()         // repo root
            .appendingPathComponent("Tools/llm-eval")
    }

    /// The punctuation gold — every case carries at least one terminator, and it is the only
    /// corpus here that reaches the reporting floor in all three languages.
    ///
    /// Empty when the file is absent, so a caller degrades to reporting less rather than failing
    /// on a machine that has not run `assemble_gold.py`.
    static func punctuationCases() -> [Case] {
        cases(in: "authoring/gold-corpus-punctuation.json")
    }

    static func cases(in relativePath: String) -> [Case] {
        let url = evalDirectory.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else { return [] }
        return corpus.cases
    }
}
