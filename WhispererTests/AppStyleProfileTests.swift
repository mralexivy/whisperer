//
//  AppStyleProfileTests.swift
//  WhispererTests
//
//  Verdict rule for workstream 3, metrics 1 and 2.
//
//  The edit this suite guards cannot be scored against any reference we hold — see
//  `TrailingPeriodSuppressor`'s header and `docs/knowledge/benchmarking/rules.md` rules 15 and
//  24. So the bar is not "is the output better", which is unanswerable here. The bar is:
//
//    1. suppression fires *only* in the narrow condition (the table below), and
//    2. every non-messaging profile produces byte-identical output to today.
//
//  Metric 2 is the safety property that makes the change shippable without a quality number: a
//  change that is provably inert outside one narrow case cannot regress the other cases.
//

import XCTest
@testable import whisperer

final class AppStyleProfileTests: XCTestCase {

    // MARK: - Classification

    func testKnownBundleIDsClassify() {
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.tinyspeck.slackmacgap"), .messaging)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.apple.MobileSMS"), .messaging)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.apple.dt.Xcode"), .code)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.apple.mail"), .prose)
    }

    /// The conservative default is the whole safety argument: an app we have not classified must
    /// behave exactly as it did before this type existed.
    func testUnknownBundleIDsAreUnknown() {
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.example.NeverSeenBefore"), .unknown)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: ""), .unknown)
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: nil), .unknown)
    }

    func testOverrideBeatsBuiltIn() {
        let overrides: [String: AppStyleProfile] = ["com.apple.dt.Xcode": .prose]
        XCTAssertEqual(AppStyleProfile.profile(forBundleID: "com.apple.dt.Xcode", overrides: overrides), .prose)
    }

    /// `terminatesUtteranceEnd` is inverted relative to `suppressesTrailingPeriod` by
    /// construction — messaging is the one profile that neither adds nor keeps a final period.
    func testBehaviourFlagsAgreeAcrossAllProfiles() {
        for profile in AppStyleProfile.allCases {
            XCTAssertEqual(profile.terminatesUtteranceEnd, !profile.suppressesTrailingPeriod,
                           "profile \(profile.rawValue) disagrees with itself about the final period")
        }
    }

    // MARK: - Metric 1: suppression fires only in the narrow condition

    func testSuppressionFiresOnSingleSentenceMessaging() {
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("on my way.", profile: .messaging), "on my way")
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("sounds good to me.", profile: .messaging),
                       "sounds good to me")
    }

    func testQuestionAndExclamationPreserved() {
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("are you around?", profile: .messaging),
                       "are you around?")
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("ship it!", profile: .messaging), "ship it!")
    }

    func testMultiSentencePreserved() {
        let input = "I looked at it. It works."
        XCTAssertEqual(TrailingPeriodSuppressor.suppress(input, profile: .messaging), input)

        let mixed = "did you see it? yes."
        XCTAssertEqual(TrailingPeriodSuppressor.suppress(mixed, profile: .messaging), mixed)
    }

    func testEllipsisPreserved() {
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("well...", profile: .messaging), "well...")
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("well\u{2026}", profile: .messaging), "well\u{2026}")
    }

    func testNoTerminatorIsUntouched() {
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("on my way", profile: .messaging), "on my way")
    }

    /// The period belongs to the token, not the sentence. Stripping it produces a misspelling or
    /// a broken identifier.
    func testTokenOwnedPeriodsPreserved() {
        for input in ["ship it, tests and docs etc.",
                      "look at config.js.",
                      "we are on version 3.",
                      "it is in whisper.cpp.",
                      "ask Dr.",
                      "signed Alexander I."] {
            XCTAssertEqual(TrailingPeriodSuppressor.suppress(input, profile: .messaging), input,
                           "should not have stripped the period in: \(input)")
        }
    }

    func testDegenerateInputsAreUntouched() {
        for input in ["", ".", " ", "..."] {
            XCTAssertEqual(TrailingPeriodSuppressor.suppress(input, profile: .messaging), input,
                           "degenerate input changed: \(input.debugDescription)")
        }
    }

    func testSurroundingWhitespacePreserved() {
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("  on my way.  ", profile: .messaging),
                       "  on my way  ")
        XCTAssertEqual(TrailingPeriodSuppressor.suppress("on my way.\n", profile: .messaging),
                       "on my way\n")
    }

    // MARK: - Metric 2: every non-messaging profile is byte-identical to today

    /// The disqualifier. If this fails, the change is not scoped and must not ship — a profile
    /// that alters text it was not meant to alter is exactly the silent degradation this
    /// workstream's gate exists to prevent.
    func testNonMessagingProfilesAreByteIdentical() {
        let corpus = [
            "on my way.",
            "sounds good to me.",
            "are you around?",
            "ship it!",
            "I looked at it. It works.",
            "well...",
            "on my way",
            "ship it, tests and docs etc.",
            "look at config.js.",
            "we are on version 3.",
            "",
            ".",
            "  padded.  ",
        ]

        for profile in AppStyleProfile.allCases where profile != .messaging {
            for input in corpus {
                XCTAssertEqual(TrailingPeriodSuppressor.suppress(input, profile: profile), input,
                               "profile \(profile.rawValue) modified \(input.debugDescription)")
            }
        }
    }
}
