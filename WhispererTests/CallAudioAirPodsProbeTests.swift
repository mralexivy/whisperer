//
//  CallAudioAirPodsProbeTests.swift
//  WhispererTests
//
//  Opt-in, hardware: what does the app's own call-audio path hear from a running call app? Start a call-like app
//  (a Chrome page that holds the microphone and plays a voice), put AirPods on, then:
//
//    TEST_RUNNER_PROBE_CALL_APP=com.google.Chrome xcodebuild test … -only-testing:WhispererTests/CallAudioAirPodsProbeTests
//

import XCTest
import CoreAudio
@testable import whisperer

@MainActor
final class CallAudioAirPodsProbeTests: XCTestCase {

    private static var keepAlive: [AnyObject] = []

    private func pump(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    func testWhatTheAppHearsFromTheCallApp() throws {
        guard let bundleID = ProcessInfo.processInfo.environment["PROBE_CALL_APP"] else { throw XCTSkip("set TEST_RUNNER_PROBE_CALL_APP") }
        let monitor = AudioProcessMonitor()
        let processes = monitor.processObjects(ownedBy: bundleID)
        print("PROBE processes owned by \(bundleID): \(processes.count)")
        for s in monitor.snapshots(of: processes) { print("PROBE   \(s.summary)") }
        print("PROBE active: \(monitor.activeProcessSnapshots().map(\.summary))")
        let out = SystemAudioCapture.defaultOutputDeviceID()
        let (route, name) = SystemAudioCapture.currentOutputRoute()
        print("PROBE output: \(name) route=\(route.rawValue) rate=\(out.flatMap { SystemAudioCapture.nominalSampleRate($0) } ?? 0)")

        let mixer = SystemAudioMixer()
        let capture = SystemAudioCapture(mixer: mixer)
        Self.keepAlive += [mixer, capture]
        try capture.start(target: .app(bundleID: bundleID, processes: processes))
        pump(10)
        let s = mixer.stats
        print("PROBE app-path result: appended=\(s.appended) mixed=\(s.mixed) dropped=\(s.dropped) underrun=\(s.underrun) PEAK=\(s.peak)")
        capture.stop()
    }
}
