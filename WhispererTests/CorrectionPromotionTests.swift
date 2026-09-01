//
//  CorrectionPromotionTests.swift
//  WhispererTests
//
//  The calibration table for auto-promotion, held as assertions.
//
//  Every pair below is real. They come from replaying the candidate miner over the 1,779
//  dictations and 220 genuine edit pairs in the user's Wispr Flow corpus, plus the 9 pairs Wispr's
//  own learner captured. The bar fixed before this code was written:
//
//      zero false auto-promotions on the corpus we have, reported with its n.
//
//  Not a precision percentage — n = 9 auto-learned pairs cannot certify a 99% claim
//  (benchmarking rule 13). The honest statement is the one above.
//
//  The named-pair assertions are disqualifiers. If `backend → firebase` ever reaches tier 1, the
//  feature is wrong and must not ship, regardless of how the aggregate looks.
//

import XCTest
@testable import whisperer

final class CorrectionPromotionTests: XCTestCase {

    private func tier(_ observed: String, _ corrected: String, tombstones: Set<String> = []) -> CorrectionPromotionTier {
        CorrectionPromotion.evaluate(observed: observed, corrected: corrected, tombstones: tombstones)
    }

    // MARK: - The pairs that must auto-promote

    /// The highest-value term in the corpus: used 105 times, wrong every time until learned.
    func testGenuineMishearingsAutoPromote() {
        XCTAssertEqual(tier("Glyn", "Glean"), .automatic)
        XCTAssertEqual(tier("ORCID", "Orkit"), .automatic)
    }

    // MARK: - The pairs that must never auto-promote (disqualifiers)

    func testDestructivePairsNeverReachTierOne() {
        // Rewrites, not mishearings. Each would fire on every future dictation of a common word.
        // `backend` appears in 87 dictations.
        XCTAssertNotEqual(tier("backend", "firebase"), .automatic, "backend → firebase must never auto-apply")
        XCTAssertNotEqual(tier("teams", "Antti"), .automatic, "teams → Antti must never auto-apply")
        XCTAssertNotEqual(tier("the", "our"), .automatic, "the → our must never auto-apply")
        XCTAssertNotEqual(tier("lead", "litserver"), .automatic, "lead → litserver must never auto-apply")
        XCTAssertNotEqual(tier("sink", "cost"), .automatic, "sink → cost must never auto-apply")
        XCTAssertNotEqual(tier("size", "image"), .automatic, "size → image must never auto-apply")
        XCTAssertNotEqual(tier("KVEN", "QwEN"), .automatic, "KVEN → QwEN must never auto-apply")
        XCTAssertNotEqual(tier("YouTube", "YT"), .automatic, "YouTube → YT must never auto-apply")
    }

    /// Short forms are the ones that do the most damage when wrong, and the ones the spell checker
    /// declines to judge. They are suggestions at best.
    func testShortObservedFormsAreNeverAutomatic() {
        XCTAssertEqual(tier("fan", "FN"), .suggestion)
        XCTAssertEqual(tier("SI", "CI"), .suggestion)
    }

    /// A valid English word is never silently redefined, however well the pair rhymes.
    func testValidEnglishObservedFormIsNeverAutomatic() {
        XCTAssertEqual(tier("lead", "leed"), .suggestion)
        XCTAssertEqual(tier("their", "there"), .suggestion)
    }

    // MARK: - Aggregate over the corpus (metric 3)

    /// Every auto-learned pair Wispr captured, scored in one place. The two genuine mishearings
    /// promote; the seven rewrites do not. n = 9, stated rather than extrapolated.
    func testWisprAutoLearnedCorpusYieldsNoFalsePromotions() {
        let genuineMishearings: Set<String> = ["glyn", "orcid"]
        let corpus: [(String, String)] = [
            ("Glyn", "Glean"),
            ("ORCID", "Orkit"),
            ("backend", "firebase"),
            ("teams", "Antti"),
            ("KVEN", "QwEN"),
            ("YouTube", "YT"),
            ("lead", "litserver"),
            ("fan", "FN"),
            ("SI", "CI"),
        ]

        var falsePromotions: [String] = []
        var truePromotions = 0
        for (observed, corrected) in corpus where tier(observed, corrected) == .automatic {
            if genuineMishearings.contains(observed.lowercased()) {
                truePromotions += 1
            } else {
                falsePromotions.append("\(observed) → \(corrected)")
            }
        }

        XCTAssertEqual(falsePromotions, [], "false auto-promotions over n=\(corpus.count)")
        XCTAssertEqual(truePromotions, genuineMishearings.count, "every genuine mishearing must promote")
    }

    // MARK: - Malformed input is rejected outright

    func testMalformedPairsAreRejectedNotSuggested() {
        XCTAssertEqual(tier("glean", "Glean"), .rejected(.identical))
        XCTAssertEqual(tier("a", "an"), .rejected(.tooShort))
        XCTAssertEqual(tier("open glyn", "open Glean"), .rejected(.notASingleWord))
        XCTAssertEqual(tier("2024", "2025"), .rejected(.notASingleWord))
        XCTAssertEqual(tier("test", "בדיקה"), .rejected(.scriptMismatch))
    }

    // MARK: - Tombstones (disqualifier)

    func testTombstonedPairIsNeverRelearnedHoweverOftenItIsSeen() {
        for _ in 0..<3 {
            XCTAssertEqual(tier("Glyn", "Glean", tombstones: ["glyn"]), .rejected(.tombstoned))
        }
        // The tombstone is keyed on the observed form, so a near-miss replacement is blocked too.
        XCTAssertEqual(tier("Glyn", "Gleen", tombstones: ["glyn"]), .rejected(.tombstoned))
    }

    func testTombstoneStorePersistsAndClears() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("tombstones.json")
        let store = CorrectionTombstoneStore(fileURL: url)

        await store.add("Glyn")
        var contains = await store.contains("glyn")
        XCTAssertTrue(contains, "lookup is case-insensitive")

        let reloaded = CorrectionTombstoneStore(fileURL: url)
        contains = await reloaded.contains("GLYN")
        XCTAssertTrue(contains, "tombstones must survive a relaunch")

        await reloaded.removeAll()
        contains = await reloaded.contains("glyn")
        XCTAssertFalse(contains)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
