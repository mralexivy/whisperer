//
//  PostProcessingCrashRegressionTests.swift
//  WhispererTests
//
//  Three traps on the every-transcript post-processing path — the one reported from a meeting
//  retranscribe and two found auditing the same bug class. All three are reachable from ordinary
//  dictation as well as from meetings, and all three kill the process rather than degrading.
//
//  The shared shape: an index or an integer derived from one representation of the text, then
//  used against another. A `String.Index` taken from a `lowercased()` copy and applied to the
//  original; a range whose bounds come from two different markers and can invert; an `Int`
//  accumulator with no ceiling. Every case below traps on the unfixed code.
//

import XCTest
@testable import whisperer

final class PostProcessingCrashRegressionTests: XCTestCase {

    // MARK: - ListFormatter: inverted range in tryPrefixedGroups

    /// `"one one two"` makes the second marker's `precedingWord` land *inside* the first marker,
    /// so `precedingWordStart < firstEnd` and `lower[firstEnd..<pwStart]` is backwards. The guard
    /// only checked `pwStart < lastStart`, which this input also satisfies.
    func testRepeatedMarkerWordDoesNotTrap() {
        XCTAssertNoThrow(ListFormatter.format("one one two"))
    }

    func testRepeatedMarkerWordVariantsDoNotTrap() {
        let inputs = [
            "one one two",
            "one one two two three",
            "first first second",
            "number one number one number two",
            "one one",
            "two two one",
        ]
        for input in inputs {
            XCTAssertNoThrow(ListFormatter.format(input), input)
        }
    }

    /// The fix narrows the guard that reaches the two-item conjunction check, so a prefixed group
    /// that should still form has to still form. (The conjunction check itself is not exercised by
    /// `"number one is ready but number two is not"` — that input reaches a different strategy and
    /// has always been formatted as a list; verified against the pre-fix build.)
    func testPrefixedGroupStillFormats() {
        let out = ListFormatter.format("step one update the database. step two restart the service")
            .components(separatedBy: "\n")
        XCTAssertEqual(out.count, 2, out.joined(separator: " | "))
        XCTAssertTrue(out[0].hasPrefix("1. "), out[0])
        XCTAssertTrue(out[1].hasPrefix("2. "), out[1])
    }

    // MARK: - ListFormatter: lowercased() index applied to the original

    /// `İ` (U+0130) grows by a byte when lowercased, so every index found in the `lower` copy sits
    /// past its counterpart in `text`. Enough of them ahead of a trigger and the slice runs off
    /// the end. `Ⱥ` (U+023A) and `Ⱦ` (U+023E) are the other two scalars with this property.
    func testLengthChangingLowercaseDoesNotTrap() {
        let inputs = [
            "İİİİİ dash a dash b",
            "ȺȺȺȺȺ dash a dash b dash c",
            "ȾȾȾȾȾ number one a number two b",
            "İstanbul plan. first a. second b. third c",
        ]
        for input in inputs {
            XCTAssertNoThrow(ListFormatter.format(input), input)
        }
    }

    /// The mapping has to be correct, not merely in-bounds: a wrong-but-valid index silently
    /// garbles the item text. With no length-changing scalar present, mapping is the identity.
    func testItemTextIsNotShiftedByCaseMapping() {
        let out = ListFormatter.format("Number one Update The Database. number two Restart It")
            .components(separatedBy: "\n")
        XCTAssertEqual(out.count, 2, out.joined(separator: " | "))
        XCTAssertTrue(out[0].contains("Update The Database"), out[0])
        XCTAssertTrue(out[1].contains("Restart It"), out[1])
    }

    // MARK: - SpokenNumberConverter: Int overflow

    /// `follows` accepts a scale after a scale, so "one hundred hundred hundred …" is a
    /// well-formed run as far as the grammar is concerned. Ten of them overflow Int64 in
    /// `current = max(current, 1) * value`, which traps in Swift rather than wrapping.
    func testRepeatedScaleWordsDoNotOverflow() {
        let polisher = DeterministicPolisher(splitsParagraphs: false)
        for count in [3, 6, 10, 12, 20, 40] {
            let text = "one " + Array(repeating: "hundred", count: count).joined(separator: " ")
            XCTAssertNoThrow(polisher.polish(chunks: [
                DeterministicPolisher.Chunk(text: text, start: 0, end: 2)
            ]), "\(count) scale words")
        }
    }

    func testRepeatedThousandAndMillionDoNotOverflow() {
        let polisher = DeterministicPolisher(splitsParagraphs: false)
        let inputs = [
            "one " + Array(repeating: "thousand", count: 8).joined(separator: " "),
            "one " + Array(repeating: "million", count: 8).joined(separator: " "),
            "nine hundred ninety nine " + Array(repeating: "thousand million", count: 6).joined(separator: " "),
        ]
        for text in inputs {
            XCTAssertNoThrow(polisher.polish(chunks: [
                DeterministicPolisher.Chunk(text: text, start: 0, end: 2)
            ]), text)
        }
    }

    /// Overflow ends the run early; it must not break the numbers people actually say.
    func testOrdinaryNumbersStillConvert() {
        let polisher = DeterministicPolisher(splitsParagraphs: false)
        let out = polisher.polish(chunks: [
            DeterministicPolisher.Chunk(text: "we need twenty five servers and three hundred gigabytes",
                                        start: 0, end: 3)
        ]).text
        XCTAssertTrue(out.contains("25"), out)
        XCTAssertTrue(out.contains("300"), out)
    }
}
