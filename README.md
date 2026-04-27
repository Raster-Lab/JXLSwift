# JXLSwift

A pure-Swift implementation of JPEG XL (ISO/IEC 18181), targeting Swift 6.2 strict concurrency. **No C dependencies, no native libraries.**

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
- `ANSDistribution` + `ANSEncoder` + `ANSDecoder` (§C.6.3) — 32-bit-state rANS with 16-bit renormalisation, tabSize=4096

Each primitive has round-trip tests; the compression-ratio sanity test confirms rANS reaches near-Shannon-entropy bounds on highly-skewed distributions (1000 symbols → < 50 bytes for a 0.08-bit-entropy stream).

`JXLDecoder.inspect(_:)` parses any spec-compliant `.jxl` and reports container form, box list, dimensions, bit depth, channel count, alpha, animation, and HDR metadata — useful as a JXL info tool today.

`JXLEncoder.encode(_:)` / `JXLDecoder.decode(_:)` throw `.notImplemented` because the codec layer isn't done yet. For a working JXL pipeline switch to the `libjxl-backend` branch.

See [ROADMAP.md](ROADMAP.md) for the spec-section status grid.

## Quickstart

```bash
swift build -c release
swift test  -c release           # 44 tests (foundation + headers + entropy primitives), ~50 ms
.build/release/jxl-tool --version
.build/release/jxl-tool info path/to/file.jxl
```

Requires Swift 6.2+ on macOS 13+. **No external dependencies.** (`swift-argument-parser` for the CLI is the only Swift-package dep.)

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
Sources/JXLSwift/Medical/     DICOMReader (pure Swift — unchanged from
                              earlier rounds, codec-agnostic)
Sources/JXLTool/              jxl-tool CLI (info works; encode/decode stubbed)
Tests/JXLSwiftTests/          44 tests across foundation, headers, entropy
```

## Branches

| Branch | What's there |
|---|---|
| `main` | This pure-Swift implementation (foundation only) |
| `libjxl-backend` | Working libjxl-backed implementation (preserved while pure-Swift catches up) |
| `pre-rewrite-snapshot` | Original failed pure-Swift attempt (preserved for reference / lessons learned) |
| Tag `v0.4-libjxl` | Last commit of the libjxl-backed `main` |

## Contributing

The development principles are spelled out in [ROADMAP.md](ROADMAP.md). Pick a phase, write tests against real `cjxl`-produced output as the oracle, submit a PR. Spec-driven only — no shortcuts that would produce non-spec-compliant bitstreams.

## Documentation

- [ROADMAP.md](ROADMAP.md) — phase-by-phase status against ISO/IEC 18181 sections
- [CHANGELOG.md](CHANGELOG.md) — release notes (libjxl-backed history archived)
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview (currently libjxl-backend; will be updated for pure-Swift as code lands)
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history

## Licence

See [LICENSE](LICENSE).
