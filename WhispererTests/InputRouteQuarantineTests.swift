import XCTest
import CoreAudio
@testable import whisperer

final class InputRouteQuarantineTests: XCTestCase {

    func testSuspectDeviceIsRemembered() {
        let q = InputRouteQuarantine(ttl: 60, now: { Date(timeIntervalSince1970: 0) })
        XCTAssertFalse(q.isSuspect(uid: "airpods"))
        q.markSuspect(uid: "airpods")
        XCTAssertTrue(q.isSuspect(uid: "airpods"))
        XCTAssertFalse(q.isSuspect(uid: "builtin"))
    }

    func testSuspicionExpires() {
        var clock = Date(timeIntervalSince1970: 0)
        let q = InputRouteQuarantine(ttl: 60, now: { clock })
        q.markSuspect(uid: "airpods")
        clock = Date(timeIntervalSince1970: 59)
        XCTAssertTrue(q.isSuspect(uid: "airpods"))
        clock = Date(timeIntervalSince1970: 61)
        XCTAssertFalse(q.isSuspect(uid: "airpods"), "a headset that was merely asleep gets another chance")
    }

    func testDisconnectedDeviceIsForgiven() {
        let q = InputRouteQuarantine()
        q.markSuspect(uid: "airpods")
        q.markSuspect(uid: "usb")
        q.forgetDevices(notIn: ["usb", "builtin"])
        XCTAssertFalse(q.isSuspect(uid: "airpods"), "a reconnect renegotiates the link")
        XCTAssertTrue(q.isSuspect(uid: "usb"))
    }

    func testRecoveryPrefersBuiltInOverWireless() {
        XCTAssertLessThan(InputTransportRank.rank(transport: kAudioDeviceTransportTypeBuiltIn),
                          InputTransportRank.rank(transport: kAudioDeviceTransportTypeUSB))
        XCTAssertLessThan(InputTransportRank.rank(transport: kAudioDeviceTransportTypeUSB),
                          InputTransportRank.rank(transport: kAudioDeviceTransportTypeBluetooth))
        XCTAssertTrue(InputTransportRank.isWireless(transport: kAudioDeviceTransportTypeContinuityCaptureWireless))
    }

    func testTerminalMessageNeverClaimsRecoveryIsRunning() {
        XCTAssertFalse(InputHealthVerdict.healthy.terminalMessage.contains("Trying"))
        XCTAssertTrue(InputHealthVerdict.healthy.userMessage.contains("Trying"))
        XCTAssertEqual(InputHealthVerdict.muted.terminalMessage, InputHealthVerdict.muted.userMessage)
    }
}
