//
//  AppEnvironment.swift
//  Whisperer
//
//  Which process are we actually running in.
//

import Foundation

enum AppEnvironment {

    /// True when this process is an XCTest host rather than the shipping app.
    ///
    /// `TEST_HOST` points the test bundle at `whisperer.app`, so `applicationDidFinishLaunching`
    /// runs in full inside every test process — with the *user's* real preferences domain, real
    /// CoreData store and real Application Support directory, because the host's bundle id is
    /// `com.ivy.whisperer`. Two consequences, both of which have already bitten:
    ///
    /// 1. **Heavy startup work corrupts measurements.** An unguarded
    ///    `MeetingDiarizerService.warm()` spent 4416 ms loading a Sortformer ANE bundle
    ///    concurrently with a latency test and failed it at 4156 ms against a 3000 ms budget —
    ///    a timing test failing for a reason entirely outside the code under test, which reads
    ///    as a real regression and sends debugging the wrong way.
    /// 2. **Launch-time maintenance mutates real user data.** Retention sweeps delete real
    ///    transcriptions, meetings and audio files.
    ///
    /// Anything at launch that loads a model, warms a cache, downloads, builds an index, starts
    /// a timer, binds a port, or deletes user data must check this first.
    static let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
