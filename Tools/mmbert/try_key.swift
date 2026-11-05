// try_key.swift -- does this AES key open a published polish package?
//
//   swift Tools/mmbert/try_key.swift <mmbert-vN.bin | .part> <64-hex-key | file> [...more]
//
// A file argument may hold one key or many: every 64-hex-character token in it is tried,
// so a list scraped from old logs or binaries can be checked in one run (~1 ms per key).
//
// Reads only the first chunk (4 MiB), so a partial download is enough. Layout and AAD mirror
// PolishModelPackage.swift: header(20) || [nonce(12) || ciphertext(<=4 MiB) || tag(16)]...,
// AAD = header || big-endian chunk index. A wrong key fails authentication; it cannot
// produce a false positive.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: try_key.swift <package> <hexkey|keyfile> ..."); exit(2) }
let headerLen = 20, nonceLen = 12, tagLen = 16, chunkSize = 4 * 1024 * 1024

guard let handle = FileHandle(forReadingAtPath: args[1]) else { print("cannot open \(args[1])"); exit(2) }
let header = try handle.read(upToCount: headerLen) ?? Data()
let wire = try handle.read(upToCount: nonceLen + chunkSize + tagLen) ?? Data()
guard header.count == headerLen, String(decoding: header.prefix(8), as: UTF8.self) == "WHSPMDL1" else {
    print("not a polish package (bad magic)"); exit(2)
}
guard wire.count > nonceLen + tagLen else { print("file too short for one chunk"); exit(2) }

var aad = header
withUnsafeBytes(of: UInt32(0).bigEndian) { aad.append(contentsOf: $0) }

func hex(_ s: String) -> Data? {
    var data = Data(); var i = s.startIndex
    while i < s.endIndex {
        guard let j = s.index(i, offsetBy: 2, limitedBy: s.endIndex),
              let b = UInt8(s[i..<j], radix: 16) else { return nil }
        data.append(b); i = j
    }
    return data
}

func tokens(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isHexDigit }).map(String.init).filter { $0.count == 64 }
}

var matched = false
var tried = Set<String>()
for arg in args.dropFirst(2) {
    let isFile = FileManager.default.fileExists(atPath: arg)
    let text = isFile ? ((try? String(contentsOfFile: arg, encoding: .utf8)) ?? "") : arg
    let keys = tokens(text)
    if keys.isEmpty { print("SKIP  \(arg): no 64-hex-character key in it"); continue }
    for clean in keys where tried.insert(clean.lowercased()).inserted {
        guard let keyData = hex(clean) else { continue }
        do {
            let box = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: wire.prefix(nonceLen)),
                ciphertext: wire.dropFirst(nonceLen).dropLast(tagLen),
                tag: wire.suffix(tagLen))
            _ = try AES.GCM.open(box, using: SymmetricKey(data: keyData), authenticating: aad)
            print("MATCH \(clean)  (from \(isFile ? arg : "argument"))")
            matched = true
        } catch {
            if keys.count == 1 { print("no    \(clean.prefix(8))…  (\(isFile ? arg : "argument"))") }
        }
    }
}
print("tried \(tried.count) distinct key(s): \(matched ? "MATCH FOUND" : "no match")")
exit(matched ? 0 : 1)
