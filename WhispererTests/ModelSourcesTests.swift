//
//  ModelSourcesTests.swift
//  WhispererTests
//
//  Where weights come from in each market: the China table, the ModelScope listing parser and glob matching,
//  the market-aware defaults and pickers, and (opt-in, needs network) a real ModelScope download.
//

import XCTest
@testable import whisperer

@MainActor
final class ModelSourcesTests: XCTestCase {
    override func tearDown() async throws {
        #if DEBUG
        MarketPolicy.testOverride = nil
        #endif
    }

    private func inChina() throws {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .chinaMainland
        #else
        throw XCTSkip("needs a Debug build that is not the China edition")
        #endif
    }

    func testTheChinaTableNamesTheVerifiedRepos() {
        XCTAssertEqual(ModelSources.modelScopeRepo(for: "ggerganov/whisper.cpp", file: "ggml-base.bin"), "cjc1887415157/whisper.cpp")
        XCTAssertEqual(ModelSources.modelScopeRepo(for: "ggerganov/whisper.cpp", file: "ggml-large-v3-q5_0.bin"), "cjc1887415157/whisper.cpp")
        XCTAssertNil(ModelSources.modelScopeRepo(for: "ggerganov/whisper.cpp", file: "ggml-large-v3-turbo-q5_0.bin"), "turbo is not on ModelScope yet")
        XCTAssertEqual(ModelSources.modelScopeRepo(for: "mlx-community/Qwen3-ASR-1.7B-8bit"), "mlx-community/Qwen3-ASR-1.7B-8bit")
        XCTAssertEqual(ModelSources.modelScopeRepo(for: "ggml-org/whisper-vad", file: "ggml-silero-v6.2.0.bin"), "ggml-org/whisper-vad")
        XCTAssertNil(ModelSources.modelScopeRepo(for: "Youssofal/Qwen3.5-4B-MTPLX-Optimized-Speed"))
        XCTAssertNil(ModelSources.modelScopeRepo(for: "FluidInference/parakeet-tdt-0.6b-v3-coreml"))
    }

    func testFilesAreResolvedToModelScopeOnlyInChina() throws {
        let hf = URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/abc/ggml-silero-v6.2.0.bin")!
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .other
        XCTAssertEqual(ModelSources.resolve(huggingFaceURL: hf, repo: "ggml-org/whisper-vad", file: "ggml-silero-v6.2.0.bin"), hf)
        XCTAssertEqual(ModelSources.host, .huggingFace)
        #endif
        try inChina()
        XCTAssertEqual(ModelSources.host, .modelScope)
        XCTAssertEqual(ModelSources.resolve(huggingFaceURL: hf, repo: "ggml-org/whisper-vad", file: "ggml-silero-v6.2.0.bin").absoluteString,
                       "https://modelscope.cn/models/ggml-org/whisper-vad/resolve/master/ggml-silero-v6.2.0.bin")
        XCTAssertEqual(WhisperModel.base.downloadURL.host, "modelscope.cn")
        XCTAssertEqual(VADModel.sileroV6.downloadURL.host, "modelscope.cn")
    }

    func testListingParserKeepsMatchingBlobsAndTheirHashes() throws {
        let json = """
        {"Code":200,"Data":{"Files":[
          {"Type":"blob","Path":"config.json","Size":7188,"Sha256":"aa"},
          {"Type":"blob","Path":"model.safetensors","Size":2460000000,"Sha256":"bb"},
          {"Type":"blob","Path":"README.md","Size":1008,"Sha256":"cc"},
          {"Type":"tree","Path":"onnx","Size":0},
          {"Type":"blob","Path":"sub/tokenizer.json","Size":99,"Sha256":"dd"}]}}
        """.data(using: .utf8)!
        let entries = try ModelScopeFetcher.entries(fromListing: json, matching: ["*.json", "*.safetensors"])
        XCTAssertEqual(entries.map(\.path), ["config.json", "model.safetensors", "sub/tokenizer.json"])
        XCTAssertEqual(entries.first { $0.path == "model.safetensors" }?.sha256, "bb")
        XCTAssertThrowsError(try ModelScopeFetcher.entries(fromListing: Data("{\"Code\":404}".utf8), matching: []))
        XCTAssertTrue(ModelScopeFetcher.matches("merges.txt", glob: "merges.txt"))
        XCTAssertFalse(ModelScopeFetcher.matches("model.bin", glob: "*.safetensors"))
    }

    func testChinaDefaultsAndPickersOnlyOfferWhatCanBeDownloaded() throws {
        try inChina()
        XCTAssertEqual(BackendType.defaultBackend, .qwen3asr, "China is built around Qwen: Qwen3-ASR is the default engine")
        XCTAssertFalse(BackendType.selectable.contains(.parakeet))
        XCTAssertFalse(BackendType.selectable.contains(.whisperKit))
        XCTAssertTrue(BackendType.selectable.contains(.qwen3asr))
        XCTAssertTrue(BackendType.selectable.contains(.whisperCpp))

        XCTAssertEqual(LLMModelVariant.marketDefault, .qwen3_5_4B)
        XCTAssertFalse(LLMModelVariant.available.contains(.qwen3_5_4B_mtp))
        XCTAssertFalse(LLMModelVariant.available.contains(.whispererV3), "the Whisperer V3 LLM is not on ModelScope")
        XCTAssertTrue(LLMModelVariant.available.contains(.qwen3_5_9B))
        XCTAssertEqual(MeetingEngines.intelligenceVariant, .qwen3_5_4B)

        XCTAssertTrue(WhisperModel.primaryOrder.allSatisfy(\.isAvailableInThisMarket))
        XCTAssertEqual(WhisperModel.primaryOrder.first, .largeV3Q5)
        XCTAssertTrue(WhisperModel.displayOrder.allSatisfy(\.isAvailableInThisMarket))
        XCTAssertFalse(WhisperModel.displayOrder.contains(.largeTurboQ5))
        XCTAssertFalse(MeetingEngine.speakers.isAvailableInThisMarket)
        XCTAssertEqual(MeetingEngine.speakers.downloadBytes, 0)
    }

    func testOutsideChinaNothingChanges() {
        #if DEBUG && !CHINA_EDITION
        MarketPolicy.testOverride = .other
        XCTAssertEqual(BackendType.defaultBackend, .whisperCpp)
        XCTAssertEqual(LLMModelVariant.marketDefault, .qwen3_5_4B_mtp)
        XCTAssertEqual(LLMModelVariant.available.filter { $0 != .appleIntelligence }.count,
                       LLMModelVariant.allCases.filter { $0 != .appleIntelligence }.count)
        XCTAssertEqual(WhisperModel.primaryOrder, [.largeTurboQ5, .ivritLargeTurbo, .largeTurbo])
        XCTAssertTrue(MeetingEngine.speakers.isAvailableInThisMarket)
        XCTAssertTrue(BackendType.selectable.contains(.parakeet))
        #endif
    }

    /// Real download from modelscope.cn. Opt-in: `TEST_RUNNER_NETWORK_TESTS=1`.
    func testRealModelScopeSnapshotOfTheVADModel() async throws {
        guard ProcessInfo.processInfo.environment["NETWORK_TESTS"] != nil else { throw XCTSkip("set TEST_RUNNER_NETWORK_TESTS=1") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let last = Box<Double>(0)
        try await ModelScopeFetcher.snapshot(repo: "ggml-org/whisper-vad", globs: ["ggml-silero-v6.2.0.bin"], into: dir) { value in last.mutate { $0 = value } }
        let file = dir.appendingPathComponent("ggml-silero-v6.2.0.bin")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64, 885_098)
        XCTAssertEqual(last.value, 1, accuracy: 0.001)
        XCTAssertTrue(ModelScopeFetcher.verify(file, sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"))
    }

    /// The two models the China edition runs, fully downloaded from modelscope.cn with every file hash-verified.
    /// Opt-in (about 5.5 GB): `TEST_RUNNER_NETWORK_TESTS=1`.
    func testRealModelScopeDownloadOfTheChinaEditionQwenModels() async throws {
        guard ProcessInfo.processInfo.environment["NETWORK_TESTS"] != nil else { throw XCTSkip("set TEST_RUNNER_NETWORK_TESTS=1") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-qwen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (repo, globs) in [(Qwen3ASREngine.repoId, Qwen3ASREngine.downloadGlobs), (LLMModelVariant.qwen3_5_4B.huggingFaceId, ["*.safetensors", "*.json", "*.jinja"])] {
            let dir = root.appendingPathComponent(repo.replacingOccurrences(of: "/", with: "_"))
            try await ModelScopeFetcher.snapshot(repo: ModelSources.modelScopeRepo(for: repo) ?? repo, globs: globs, into: dir) { _ in }
            let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            XCTAssertTrue(files.contains("config.json"), "\(repo): config.json missing")
            XCTAssertTrue(files.contains { $0.hasSuffix(".safetensors") }, "\(repo): no weights")
        }
    }
}
