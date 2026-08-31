// lzfse_tool.swift -- stdin -> stdout LZFSE, in exactly the framing
// `compression_stream(_, COMPRESSION_LZFSE)` produces and consumes.
//
//     swiftc -O lzfse_tool.swift -o lzfse_tool
//     ./lzfse_tool -c < plain.bin  > plain.lzfse
//     ./lzfse_tool -d < plain.lzfse > plain.bin
//
// Python has no LZFSE and pip is unreachable here, so `package_model.py` shells
// out to this for the compress step and `verify_package.py` for the decompress.
// It deliberately uses the *same API the client decodes with* rather than
// /usr/bin/compression_tool, which wraps its output in an Apple container header
// that `compression_stream` will not accept -- a mismatch that would only
// surface 138 MB into a user's download.
//
// Why LZFSE and not LZMA. Measured on the 177 MB mmBERT container, M2 Pro:
//
//     LZMA   135.7 MB   decode 5.53 s
//     LZFSE  138.4 MB   decode 0.22 s
//     ZLIB   137.2 MB   decode 0.61 s
//
// 2.7 MB more to download (~0.3 s on a 10 MB/s link) buys back five seconds of
// the user's first run, and LZFSE decode is fast enough to hide entirely behind
// the download rather than showing up as a stall at 100%.

import Foundation
import Compression

let args = CommandLine.arguments
let decoding = args.contains("-d")
guard decoding || args.contains("-c") else {
    FileHandle.standardError.write("usage: lzfse_tool -c|-d < in > out\n".data(using: .utf8)!)
    exit(64)
}

let inBuf = 1 << 20
let outBuf = 1 << 20
let src = FileHandle.standardInput
let dst = FileHandle.standardOutput

let out = UnsafeMutablePointer<UInt8>.allocate(capacity: outBuf)
defer { out.deallocate() }

var stream = compression_stream(dst_ptr: out, dst_size: outBuf,
                                src_ptr: UnsafePointer(out), src_size: 0, state: nil)
let op = decoding ? COMPRESSION_STREAM_DECODE : COMPRESSION_STREAM_ENCODE
guard compression_stream_init(&stream, op, COMPRESSION_LZFSE) == COMPRESSION_STATUS_OK else {
    FileHandle.standardError.write("compression_stream_init failed\n".data(using: .utf8)!)
    exit(1)
}
defer { compression_stream_destroy(&stream) }
stream.dst_ptr = out
stream.dst_size = outBuf

func drain() {
    let produced = outBuf - stream.dst_size
    if produced > 0 {
        dst.write(Data(bytes: out, count: produced))
        stream.dst_ptr = out
        stream.dst_size = outBuf
    }
}

var done = false
while !done {
    let chunk = src.readData(ofLength: inBuf)
    let flags = chunk.isEmpty ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
    // Bound to a local array so the buffer outlives every process() call below.
    let held = [UInt8](chunk)
    held.withUnsafeBufferPointer { buf in
        stream.src_ptr = buf.baseAddress ?? UnsafePointer(out)
        stream.src_size = buf.count
        repeat {
            let s = compression_stream_process(&stream, flags)
            if s == COMPRESSION_STATUS_ERROR {
                FileHandle.standardError.write("compression_stream_process failed\n"
                    .data(using: .utf8)!)
                exit(2)
            }
            drain()
            if s == COMPRESSION_STATUS_END { done = true; break }
        } while stream.src_size > 0 || flags != 0
    }
}
