# JXLSwift

A ground-up, independent implementation of the JPEG XL Image Coding System (ISO/IEC 18181) written in **100% pure Swift 6.2 with strict concurrency**. **No C dependencies, no native libraries, no transitive runtime requirements.**

Primary target: **macOS on Apple Silicon (arm64)**. Modular support for macOS Intel and Linux Intel.

JXLSwift is intended for integration into the **DICOMkit** ecosystem but is fully independent and **not DICOM-aware** — the library is a general-purpose codec usable in any imaging or compression workflow.

See [ROADMAP.md](ROADMAP.md) for the full project summary and design constraints.

## Status: pre-codec spec layer complete

The codec layer (Modular tree, VarDCT, rANS entropy coding, color transforms) is the multi-person-year project ahead. Done today: every part of ISO/IEC 18181 that can be implemented *without* entropy coding.

**Phase F — Foundation (§2.4, §C.2, §C.3.1–§C.3.2):**
- LSB-first bitstream reader / writer
- Spec-defined `U32` / `U64` / `Enum` integer encodings
- ISOBMFF container parse + build (`ftyp`, `jxlc`, `jxlp`, naked codestreams)
- Codestream signature recognition
- `SizeHeader` read + write

**Phase H — Image headers (§C.3.3–§C.3.7):**
- `BitDepth` (uint8 / uint16 / float16 / float32 / custom)
- `ColorEncoding` (named primaries, white points, transfer functions)
- `ExtraChannelInfo` (alpha, depth, thermal, CFA, spot color, …)
- `ImageMetadata` (orientation, intrinsic size, preview, animation, tone mapping, extensions)

Every parser is paired with a writer; round-trip tests cover the medical-imaging cases (16-bit grayscale, RGBA16, EXIF orientation, float HDR, animation header).

**Phase E — Entropy primitives (§C.5–§C.6.3):**
- `HybridUintConfig` (§C.5) — variable-length integer split into (token, extra bits)
- `PrefixCodeTable` (§C.6.2) — canonical Huffman with O(1) encode + decode via lookup tables
- `SimplePrefixCodeFormat` + `ComplexPrefixCodeFormat` (§C.6.2.1) — bitstream serialisation of prefix-code tables, both simple (1–4 explicit symbols) and complex (meta-Huffman with run-length symbols 16/17) branches
- `ANSDistribution` + `ANSEncoder` + `ANSDecoder` (§C.6.3) — 32-bit-state rANS with 16-bit renormalisation, tabSize=4096
- `ANSDistributionFormat` (§C.6.3.2) — bitstream serialisation of rANS distributions: constant (1-symbol), simple (1–4 symbols with predefined splits), and flat (uniform). The full per-symbol-frequency mode is not yet implemented.
- `SimpleEntropyStream` — the integration layer that wires the entropy primitives into a single-context "encode a `[UInt32]` stream into a byte buffer; decode it back" round-trip. Useful as a building block for Phase M.

Each primitive has round-trip tests; the compression-ratio sanity test confirms rANS reaches near-Shannon-entropy bounds on highly-skewed distributions (1000 symbols → < 50 bytes for a 0.08-bit-entropy stream).

`JXLDecoder.inspect(_:)` parses any spec-compliant `.jxl` and reports container form, box list, dimensions, bit depth, channel count, alpha, animation, and HDR metadata — useful as a JXL info tool today.

`JXLEncoder.encode(_:)` / `JXLDecoder.decode(_:)` throw `.notImplemented` because the codec layer isn't done yet.

See [ROADMAP.md](ROADMAP.md) for the spec-section status grid.

## Quickstart

```bash
swift build -c release
swift test  -c release           # 121 tests (foundation + headers + entropy primitives + serialisation), ~50 ms
.build/release/jxl-tool --version
.build/release/jxl-tool info path/to/file.jxl
```

Requires Swift 6.2+ on macOS 13+. **No external dependencies.** (`swift-argument-parser` for the CLI is the only Swift-package dep.)

### M0 placeholder codec — exercise the pixel pipeline today

`encode-m0` / `decode-m0` round-trip 8/16-bit grayscale and RGB images through the **project-internal M0 placeholder format** (`MinimalLosslessCodec`). Reads/writes binary PNM (PGM for grayscale, PPM for RGB) so any tool that handles PNM can feed pixels in:

```bash
# turn a PNG into a PGM, encode through M0, decode back, compare
convert input.png input.pgm
.build/release/jxl-tool encode-m0 -i input.pgm -o out.m0
.build/release/jxl-tool decode-m0 -i out.m0   -o out.pgm
diff -q input.pgm out.pgm    # round-trip is pixel-exact
```

Sample compression ratios (32×32 synthetic data):

| Source | Raw size | M0 size | Ratio |
|---|---|---|---|
| 8-bit grayscale smooth gradient    | 1024 B | ~80 B | 8% |
| 16-bit grayscale large-step gradient | 2048 B | 1300 B | 63% |
| 8-bit correlated RGB (R≈G≈B)        | 3072 B | ~540 B | 18% |

The pipeline is `optional RCT (3-channel) → per-channel predictor selection → ZigZag-packed residuals → auto-selected distribution shape → SimpleEntropyStream`. **Output is NOT a JPEG XL file** — it has a 'M0' marker so a future spec-compliant decoder rejects it cleanly. The real codec (`encode` / `decode`) still throws `.notImplemented`.

## What works today

```swift
import JXLSwift
import Foundation

let data = try Data(contentsOf: URL(fileURLWithPath: "image.jxl"))

// Container parsing — works on naked codestreams and ISOBMFF wrappers
switch try parseJXLContainer(data) {
case .naked:
    print("naked codestream")
case .iso(let boxes):
    print("ISOBMFF: \(boxes.map(\.type).joined(separator: ", "))")
}

// Foundation-level inspection — gives dimensions without decoding pixels
let info = try JXLDecoder().inspect(data)
print("\(info.xsize)×\(info.ysize)")

// Bitstream primitives — write LSB-first, read back
var w = BitWriter()
w.write(bits: 4, value: 0b1011)
w.write(bits: 13, value: 5000)
let bytes = w.finishToData()

var r = BitReader(bytes)
print(try r.read(bits: 4))   // 11
print(try r.read(bits: 13))  // 5000

// JXL spec U32 / U64 codings
let dists: (UInt32Distribution, UInt32Distribution, UInt32Distribution, UInt32Distribution) = (
    .literal(0),
    .offset(constant: 1, extraBits: 4),
    .offset(constant: 17, extraBits: 8),
    .offset(constant: 273, extraBits: 30)
)
var w2 = BitWriter()
try w2.writeU32(50_000, distributions: dists)
```

## What does NOT work yet

Calling these throws `.notImplemented` — the codec layer is the multi-year project ahead:

```swift
try JXLEncoder().encode(frame)         // throws
try JXLDecoder().decode(jxlData)       // throws
try JXLDecoder().decodeAll(jxlData)    // throws
```

## Why pure Swift

The previous JXLSwift was a libjxl wrapper. Removing the C dependency means:

- No libjxl shared library at runtime — single-binary distribution.
- Native iOS / Linux / Windows builds without the Homebrew dependency story.
- Memory safety from Swift 6.2's strict concurrency throughout the codec.
- No transitive licence / patent surface from C++ codec libraries.

The trade-off: building a JPEG XL codec is comparable in scope to a small open-source codec project; the libjxl reference is approximately 150 KLOC of expert C++ compression code. ROADMAP.md tracks honest progress.

## Project layout

```
Sources/JXLSwift/Bitstream/   BitReader, BitWriter, U32/U64 spec integers
Sources/JXLSwift/Container/   ISOBMFF box parser/builder
Sources/JXLSwift/Codestream/  Signature + headers (SizeHeader, BitDepth,
                              ColorEncoding, ExtraChannelInfo,
                              ImageMetadata)
Sources/JXLSwift/Entropy/     HybridUint, PrefixCodeTable, rANS encoder/
                              decoder, ANSDistribution
Sources/JXLSwift/Codec/       JXLEncoder / JXLDecoder (currently stubs;
                              JXLDecoder.inspect(_:) IS implemented),
                              ImageFrame, EncodingOptions
Sources/JXLTool/              jxl-tool CLI (info works; encode/decode
                              throw .notImplemented until the codec lands)
Tests/JXLSwiftTests/          121 tests across foundation, headers, entropy
```

JXLSwift is **not DICOM-aware** — DICOM file format / metadata / transfer-syntax handling lives in DICOMkit, not here. JXLSwift accepts and emits raw pixel buffers (`ImageFrame`) at the bit depths medical imaging needs (8/10/12/16-bit, grayscale or RGB).

## Branches

| Branch | What's there |
|---|---|
| `main` | Pure-Swift implementation (active development) |
| `libjxl-backend` | Historical reference only — the libjxl-wrapped implementation that preceded the pure-Swift restart. **Not** a supported runtime path; libjxl is never a dependency, fallback, or required runtime for JXLSwift. |
| `pre-rewrite-snapshot` | Original failed pure-Swift attempt (preserved for lessons learned) |
| Tag `v0.4-libjxl` | Snapshot of the libjxl-wrapped `main` |

## Contributing

The development principles are spelled out in [ROADMAP.md](ROADMAP.md) and [CLAUDE.md](CLAUDE.md). Pick a phase, write a round-trip test (or, where the spec defines exact bytes, a hand-derived test vector), submit a PR. Spec-driven only — no shortcuts that would produce non-spec-compliant bitstreams.

## Documentation

- [ROADMAP.md](ROADMAP.md) — project summary + phase-by-phase status against ISO/IEC 18181 sections
- [CLAUDE.md](CLAUDE.md) — guidance for AI-assisted contributors
- [CHANGELOG.md](CHANGELOG.md) — release notes
- [Documentation/SESSION-NOTES.md](Documentation/SESSION-NOTES.md) — handoff notes for the next contributor
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview (libjxl-backed era; will be updated for pure-Swift as the codec lands)
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history (read-only)

## Licence

See [LICENSE](LICENSE).
