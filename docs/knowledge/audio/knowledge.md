# Audio — Knowledge

## Opus on macOS (measured, Aug 2026, macOS 26 / Apple Silicon)

Measured with a standalone `swiftc` harness plus `afconvert` / `afinfo`, writing
`AVAudioFile(forWriting:settings: [AVFormatIDKey: kAudioFormatOpus, …])` and
feeding it the app's existing 16 kHz mono Float32 `AVAudioPCMBuffer`s.

### Core Audio can read Ogg Opus but cannot write it

`afconvert -hf` advertises `'Oggf' = Ogg (.opus, .ogg, .oga)` with
`data_formats: 'opus'`. The **writer does not work**:

| Attempt | Result |
|---|---|
| `afconvert -f Oggf -d opus -b 24000 in.caf out.opus` | `Error: ExtAudioFileClose failed ('pck?')`, no file |
| same at `-d opus@48000` | identical — **not** a sample-rate problem |
| `AVAudioFile(forWriting: x.opus, …)` | opens, then either throws `1885563711` (`'pck?'`) on `write(from:)` or silently produces a **0-byte file** |

Reading is fine: an `.opus` produced by `ffmpeg -c:a libopus` opens through
`AVAudioFile(forReading:)` (48 kHz mono, exact frame count), converts through
`AVAudioConverter` to 16 kHz Float32, and plays in `AVAudioPlayer`.

**So: Core Audio can read Ogg Opus but not write it.** Writing standard `.opus`
requires bridging libogg/libopus directly — measured separately below.

### Writable Opus containers

| Extension | Write | Note |
|---|---|---|
| `.caf` | ✅ | the choice — Apple's own recommendation for recording |
| `.mp4` | ✅ | works, but an audio-only `.mp4` reads as video everywhere |
| `.m4a` | ❌ | `1718449215` (`'fmt?'`) — the sane audio extension rejects Opus |
| `.opus` / `.ogg` | ❌ | 0-byte file, see above |
| `.wav` | ❌ | `'fmt?'`, as expected |

### The encoder accepts 16 kHz — no resample needed

`AVAudioFile(forWriting:)` with `AVSampleRateKey` at **8000 / 12000 / 16000 /
24000 / 48000** all open *and* write. At 16 kHz the writer's `processingFormat`
comes back as `1 ch, 16000 Hz, Float32` and compares `==` to the app's
`whisperFormat`, so `AudioRecorder` hands its existing buffers to `write(from:)`
unchanged — ExtAudioFile's client-format conversion does the encode.

Output framing: 320 frames/packet (20 ms), ~104 frames of encoder priming,
max packet 96 B. `AVEncoderBitRateKey` is honoured: `-b 24000` measures 24498 bps.

### Seeking is frame-exact, not packet-granular

Setting `framePosition` to deliberately unaligned indices (53 477, 799 999) on a
CAF/Opus file returns *exactly* that position and decodes correct audio.
`AVAudioFile` handles the packet-to-frame mapping internally, so
`SessionStorage.readFloat32Window` and `WaveformGenerator` need no tolerance
change and `MeetingTranscriptRefiner`'s 0.5 s lead-in is not load-bearing here.

### A SIGKILL'd Opus recording is fully readable

This was the one real risk in writing a VBR codec live. It does not
materialise: write 30 s, `kill -9` without closing the `AVAudioFile`, reopen —
`length` is the full 480 000 frames, the first *and* last second decode with
correct amplitude, and `AVAudioPlayer` reports 30.0 s.

The reason is visible in the file layout (below): ExtAudioFile pre-reserves
space for the packet table and updates it in place as it writes, precisely so
the file is valid at any instant. No rotation scheme or
`kAudioFilePropertyDeferSizeUpdates` fiddling is needed.

### CAF reserves a flat ~236 KB packet-table pad

A CAF written by `AVAudioFile` carries a `free` chunk sized so that
`pakt + free ≈ 241.5 KB`, independent of duration:

```
roundtrip.caf (60 s)   desc 32  kuki 28  chan 12  pakt 3025  free 238483  data 183807
w.caf          (1 s)   desc 32  kuki 28  chan 12  pakt   75  free 241433  data   3470
```

At ~1 byte per packet that reservation covers ~240 000 packets ≈ 21 hours, so it
is never outgrown. But it dominates short files:

| Duration | `.caf` | `.mp4` | asymptote |
|---|---|---|---|
| 10 s | 273 KB | 97 KB | |
| 60 s | 425 KB | 249 KB | |
| 600 s | 2.07 MB | 2.02 MB | **~11 MB/hour** |

`AudioFileOptimize()` returns `noErr` and reclaims **nothing**.

What does work: rewriting the file without its `free` chunk. CAF is a flat
`(4-byte type, big-endian Int64 size, payload)` chunk list, and `free` is by
definition discardable — dropping it took a 60 s file from 425 467 B to
186 972 B, and the result still passes `afinfo` (3001 packets, 60.000000 s) and
`afplay`. Worth doing at archive time for dictations, where the pad is several
times the audio; irrelevant for meetings.

### Playback and Finder

`AVAudioPlayer(contentsOf:)` opens CAF/Opus directly and reports exact duration,
so `AudioPlayerView` and `MeetingPlayerCard` need no change. `qlmanage -t`
produces a thumbnail. `mdls` reports `kMDItemDurationSeconds = null`, but it
does so for `.m4a` and `.opus` too — not an Opus-specific gap.

## Writing real Ogg Opus with swift-ogg (measured, Aug 2026)

Core Audio's inability to write Ogg is a Core Audio limitation, not a platform
one. [element-hq/swift-ogg](https://github.com/element-hq/swift-ogg) wraps
libogg + libopus and writes standard `.opus`. Harness at `/tmp/oggspike`
(`probe | crashwrite | crashread`), deliberately mirroring the CAF harness so
the two are directly comparable.

### It encodes incrementally to disk — no buffer-the-whole-recording

`OGGConverter`'s two public entry points are whole-file, but the primitives
under them are streaming. Driving `OGGEncoder` directly:

```swift
let enc = try OGGEncoder(pcmRate: 16000, pcmChannels: 1, pcmBytesPerFrame: 2,
                         opusRate: 16000, application: .voip)
fh.write(enc.bitstream(flush: true))        // OpusHead + OpusTags
// per audio buffer:
try enc.encode(pcm: int16Bytes)             // Int16 only
fh.write(enc.bitstream(flush: false))       // completed ogg pages only
```

File size after 1 / 2 / 3 / 60 s = `141 / 4360 / 4360 / 144094` B. It grows
during recording, but **page-granular**: `ogg_stream_pageout` only emits once a
page has filled (~4 KB nominal), so at ~2.4 KB/s a page lands every ~1.7 s and
the tail sits in the encoder's `oggCache` until then. Passing `flush: true`
periodically forces a page out at any point.

### Numbers

| | swift-ogg `.opus` | Opus-in-CAF |
|---|---|---|
| 10 s | **23.7 KB** | 273 KB (34 KB after stripping `free`) |
| 60 s | 141 KB | 425 KB (187 KB stripped) |
| 600 s | 1.36 MB | 2.07 MB |
| per hour | **8.3 MB** | ~11 MB |
| bitrate | 18 689 bps (`afinfo`) | 24 498 bps for `-b 24000` |
| encode CPU | 486 ms per 60 s = **0.81% of one core** | — |

`afinfo` reports `Oggf`, `1 ch, 48000 Hz, opus`, 60.000000 s, 3000 packets, max
packet 71 B. `ffprobe` reads it as a clean `ogg / opus, 48000 Hz, mono`.

### Reads back at 48 kHz, not 16 kHz

`AVAudioFile(forReading:)` opens it and reports **48 000 Hz** and 2 880 000
frames for a 60 s file — Ogg Opus always presents 48 kHz to decoders regardless
of the encoder's input rate. Duration is exact and `AVAudioPlayer` reports
60.00 s.

This is the one real integration cost: `SessionStorage.readFloat32Window` builds
its own 16 kHz Float32 format and seeks by 16 kHz sample index, which is **3×
off** against a 48 kHz-reporting file. The fix is to derive positions from
`file.processingFormat.sampleRate` instead of a hardcoded 16 000 — which is more
correct anyway.

**Correction to an earlier note here: reading is *not* fine on its own.**
`AVAudioFile.read(into:frameCount:)` does **not** convert into a
differently-formatted client buffer — it fills at the file's own rate and
returns that many frames. Measured against a 16 kHz client buffer on a
48 kHz-reporting `.opus`: **146 cycles where 440 were expected**, i.e. the read
delivered 3× fewer 16 kHz frames than the caller asked for, silently. The
window must be read at `processingFormat` and pushed through an explicit
`AVAudioConverter` to reach 16 kHz Float32. That is what
`SessionStorage.readFloat32Window` now does.

Seeking is **frame-exact**, same as CAF — `framePosition` 0 / 53 477 / 480 000 /
799 999 all return exactly that index with correct audio (peaks 0.467–0.599
against a 0.5 input tone).

### A SIGKILL'd Ogg recording is fully readable

Write 30 s page-by-page, `kill -9` with no final flush and **no `e_o_s`
packet** (`OGGEncoder.endstream()` is `internal`, so a consumer cannot set it):
the 72 139 B truncated file reopens at 1 438 080 frames = **29.96 s of 30 s**,
first *and* last second decode, `AVAudioPlayer` reports 30.0 s, and
`OGGDecoder` recovers the full 30 s. Ogg is a page-framed container with a CRC
per page — a decoder simply stops at the last complete page. Loss is bounded by
the unflushed page, ~1.7 s at this bitrate.

### `OGGDecoder` decodes at the OpusHead input rate

Despite `opus_decoder_create(48000, …)` in `init`, line 232 re-creates the
decoder at `header.input_sample_rate`, so a file we wrote at 16 kHz decodes to
**16 kHz Float32** — whisper's exact input format, no conversion. But it decodes
the **whole file into RAM with no seek API** (230 MB for a 1-hour meeting), so
`AVAudioFile` stays the right reader.

### API gaps in the library

| Gap | Consequence |
|---|---|
| `encoder` (the `opus_encoder` handle) is `private` | `opus_encoder_ctl` / `OPUS_SET_BITRATE` unreachable — bitrate is locked to libopus's default (~19 kbps at 16 kHz mono VoIP) |
| `endstream()` is `internal` | no `e_o_s` on the last packet — harmless, see crash test |
| `OGGDecoder.sampleRate` / `numChannels` are `internal` | a consumer cannot interpret `pcmData` without assuming |
| Refuses `pcmRate != opusRate` | caller must resample; irrelevant at 16 kHz |
| `encode` takes Int16 only | recorder must convert its Float32 buffers (trivial, ~1 line) |
| `OpusTags` hardcodes `ENCODER=IBM Mobile Innovation Lab` | shows in `ffprobe` on every file |

### Dependency shape

`SwiftOGG` (source) → `vector-im/opus-swift` 0.8.4 + `vector-im/ogg-swift` 0.8.3,
both **prebuilt binary xcframeworks**, last released 2022:

- `macos-arm64_x86_64` slices present — 1.12 MB (Opus) + 188 KB (Ogg)
- **dynamic** Mach-O universal libraries, not static
- **ad-hoc signed** (`Identifier=im.vector.opus-swift`, `TeamIdentifier=not set`),
  minos 11.0 / sdk 12.3

Dynamic + ad-hoc-signed means they land in `Contents/Frameworks` and must be
re-signed with our team ID at archive time (Xcode "Embed & Sign"). For an app
with five App Store rejections behind it, that is the one non-trivial risk in
adopting the library — not a technical blocker, but new archive surface.

## Storage cost of the formats in play

Per hour of 16 kHz mono:

| Format | Rate | Per hour |
|---|---|---|
| Float32 LPCM (`Recordings/*.wav` today) | 64 KB/s | 230 MB |
| Int16 LPCM (`Sessions/*.caf`, `Meetings/*.caf` today) | 32 KB/s | 115 MB |
| Opus @ 24 kbps | ~3 KB/s | ~11 MB |

A dictation currently costs **96 KB/s**, not 32 — the session CAF is transcoded
into a Float32 WAV and the source is then never deleted
(`SessionStorage.deleteSessionFile` has zero call sites; `deleteOrphanedSessions`
only reaps it on a launch 7+ days later).
