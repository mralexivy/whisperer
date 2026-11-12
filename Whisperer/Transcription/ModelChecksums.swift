//
//  ModelChecksums.swift
//  Whisperer
//
//  Pinned SHA-256 of every whisper.cpp model the app downloads
//

import Foundation

/// Known-good SHA-256 for each downloadable ggml file, keyed by the filename the app stores it under.
///
/// The download URLs are pinned to the same Hugging Face commits (`revision`), so these hashes stay
/// valid even if an upstream repo later replaces a file. A pinned hash is checked on every load: a file
/// that was truncated, damaged or swapped is refused instead of being handed to whisper.cpp. Files not
/// listed here (user-imported models) keep the trust-on-first-use check in `WhisperBridge`.
///
/// Values are the Git LFS `oid` from the Hugging Face API at the pinned revision; refresh both together.
nonisolated enum ModelChecksums {
    static let whisperCppRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"
    static let distilLargeRevision = "0d78dd96ed9fc152325f63b53788fec3b43de031"
    static let distilSmallRevision = "d2700d7959085b51059f2644e3fa7b1cbf852d4f"
    static let ivritRevision = "2130c78e4a9cb4914cc4df91a1c3031407789705"
    static let vadRevision = "9ffd54a1e1ee413ddf265af9913beaf518d1639b"

    private static let sha256: [String: String] = [
        "ggml-tiny.bin": "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21",
        "ggml-base.bin": "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
        "ggml-small.bin": "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b",
        "ggml-medium.bin": "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208",
        "ggml-large-v3.bin": "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2",
        "ggml-large-v3-turbo.bin": "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69",
        "ggml-large-v3-turbo-q5_0.bin": "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
        "ggml-large-v3-q5_0.bin": "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1",
        "ggml-distil-large-v3.bin": "2883a11b90fb10ed592d826edeaee7d2929bf1ab985109fe9e1e7b4d2b69a298",
        "ggml-distil-small.en.bin": "7691eb11167ab7aaf6b3e05d8266f2fd9ad89c550e433f86ac266ebdee6c970a",
        "ggml-ivrit-v3-turbo.bin": "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1",
        "ggml-silero-v6.2.0.bin": "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987",
    ]

    static func expectedSHA256(forFilename filename: String) -> String? {
        sha256[filename]
    }
}
