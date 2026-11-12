//
//  ModelChecksumsTests.swift
//  WhispererTests
//

import XCTest
@testable import whisperer

final class ModelChecksumsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ModelChecksumsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testEveryDownloadableModelHasAPinnedHash() {
        for model in WhisperModel.allCases {
            let hash = ModelChecksums.expectedSHA256(forFilename: model.rawValue)
            XCTAssertNotNil(hash, "\(model.rawValue) has no pinned hash")
            XCTAssertEqual(hash?.count, 64)
        }
        XCTAssertNotNil(ModelChecksums.expectedSHA256(forFilename: VADModel.sileroV6.rawValue))
    }

    func testDownloadURLsArePinnedToARevision() {
        for model in WhisperModel.allCases {
            XCTAssertFalse(model.downloadURL.absoluteString.contains("/resolve/main/"), "\(model.rawValue) follows a moving branch")
        }
        XCTAssertFalse(VADModel.sileroV6.downloadURL.absoluteString.contains("/resolve/main/"))
    }

    /// A file named like a known model whose bytes differ is refused, even on its very first load
    /// (trust-on-first-use alone would have accepted and remembered it).
    func testSwappedKnownModelIsRefusedOnFirstLoad() throws {
        let url = dir.appendingPathComponent("ggml-tiny.bin")
        try Data("not the real tiny model".utf8).write(to: url)
        UserDefaults.standard.removeObject(forKey: "modelSHA256_ggml-tiny.bin")
        XCTAssertThrowsError(try WhisperBridge.verifyModelIntegrity(at: url)) { error in
            guard case WhisperError.modelCorrupted = error else { return XCTFail("unexpected error \(error)") }
        }
    }

    /// An unlisted (user-imported) model keeps trust-on-first-use: accepted once, refused if it changes.
    func testUnlistedModelUsesTrustOnFirstUse() throws {
        let name = "ggml-imported-\(UUID().uuidString).bin"
        let key = "modelSHA256_\(name)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let url = dir.appendingPathComponent(name)
        try Data("first".utf8).write(to: url)
        XCTAssertNoThrow(try WhisperBridge.verifyModelIntegrity(at: url))
        XCTAssertNoThrow(try WhisperBridge.verifyModelIntegrity(at: url))
        try Data("changed".utf8).write(to: url)
        XCTAssertThrowsError(try WhisperBridge.verifyModelIntegrity(at: url))
    }
}
