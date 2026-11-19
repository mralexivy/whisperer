import XCTest
@testable import whisperer

final class OutputAudibilityTests: XCTestCase {
    func testMutedOrZeroOutputIsSilentToUser() {
        XCTAssertTrue(OutputAudibility.Reading(volume: 0, muted: false).isSilentToUser)
        XCTAssertTrue(OutputAudibility.Reading(volume: 0.8, muted: true).isSilentToUser)
        XCTAssertFalse(OutputAudibility.Reading(volume: 0.5, muted: false).isSilentToUser)
        XCTAssertFalse(OutputAudibility.Reading(volume: nil, muted: nil).isSilentToUser, "no controls: nothing to repair")
    }

    func testRepairNeedsSustainedSoundOnInaudibleOutput() {
        let silent = OutputAudibility.Reading(volume: 0, muted: false)
        XCTAssertFalse(OutputAudibility.shouldRepair(silent, callSounding: true, consecutiveSoundingTicks: 1))
        XCTAssertTrue(OutputAudibility.shouldRepair(silent, callSounding: true, consecutiveSoundingTicks: 2))
        XCTAssertFalse(OutputAudibility.shouldRepair(silent, callSounding: false, consecutiveSoundingTicks: 5))
        XCTAssertFalse(OutputAudibility.shouldRepair(.init(volume: 0.5, muted: false), callSounding: true, consecutiveSoundingTicks: 5))
    }
}
