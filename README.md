# JXLSwift

A pure-Swift implementation of JPEG XL (ISO/IEC 18181), targeting Swift 6.2 strict concurrency. **No C dependencies, no native libraries.**

## Status: foundation only

The codec layer (Modular tree, VarDCT, rANS entropy coding, color transforms) is in active development as a multi-person-year project. What works today is the foundation:

- LSB-first bitstream reader / writer (ISO/IEC 18181-1 §2.4)
- Spec-defined `U32` / `U64` / `Enum` integer encodings (§C.2)
- ISOBMFF container parse + build (parses real `cjxl`-produced files)
- Codestream signature recognition (§C.3.1)
- `SizeHeader` read + write (§C.3.2)

Calling `JXLEncoder.encode(_:)` / `JXLDecoder.decode(_:)` throws `.notImplemented`. `JXLDecoder.inspect(_:)` does work and returns the dimensions and box list of any spec-compliant `.jxl` file — useful as a JXL info tool while the codec layers are built up.

For a working JXL pipeline today, switch to the `libjxl-backend` branch (a libjxl-backed implementation preserved for users who need a functional codec while the pure-Swift codec is in progress).

See [ROADMAP.md](ROADMAP.md) for a detailed mapping of spec sections to implementation status.

## Quickstart

```bash
swift build -c release
swift test  -c release           # 16 foundation tests, ~50 ms
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
Sources/JXLSwift/Codestream/  Signature + headers (SizeHeader, more to come)
Sources/JXLSwift/Codec/       JXLEncoder / JXLDecoder (currently stubs),
                              ImageFrame, EncodingOptions
Sources/JXLSwift/Medical/     DICOMReader (pure Swift — unchanged from
                              earlier rounds, codec-agnostic)
Sources/JXLTool/              jxl-tool CLI (info works; encode/decode stubbed)
Tests/JXLSwiftTests/          Foundation tests + DICOM smoke
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
