# JXLSwift

A Swift wrapper around [libjxl](https://github.com/libjxl/libjxl) for JPEG XL (ISO/IEC 18181), with first-class support for medical imaging.

```swift
import JXLSwift

// Read a 16-bit DICOM, encode to JPEG XL losslessly, decode back —
// the pixel data round-trips exactly, the bit depth is preserved end-to-end.
let frame = try DICOMReader.read(URL(fileURLWithPath: "ct.dcm"))
let encoded = try JXLEncoder(options: EncodingOptions(mode: .lossless, effort: .squirrel))
    .encode(frame)
try encoded.data.write(to: URL(fileURLWithPath: "ct.jxl"))

let recovered = try JXLDecoder().decode(encoded.data)
assert(recovered.data == frame.data) // pixel-exact
```

## Capabilities

- **Native DICOM ingestion**: read `.dcm` files directly, preserving 12/16-bit depth (Implicit/Explicit VR LE + Explicit VR BE; signed pixels and Modality LUT surfaced via metadata).
- **Multi-frame JPEG XL**: encode a stack of `[ImageFrame]` as a single multi-frame `.jxl`; decode all frames back via `decodeAll(_:)`.
- **Memory-bounded parallel batch**: `jxl-tool batch --parallel N --max-memory-mb M`. Concurrent encodes are gated by an actor-based memory budget, defaulting to 25% of physical RAM.
- **Volume-aware grouping**: `--volume-aware` groups DICOM slices that share a `SeriesInstanceUID` into one multi-frame `.jxl` per series.
- **JSON manifest output**: `--manifest out.json` emits structured per-file metadata for CI / automation.
- **16-bit grayscale PNG output** for decoded frames whose source carried 16-bit data.
- **Graceful SIGINT shutdown**: in-flight batch encodes complete, new dispatch is skipped after Ctrl-C.

## Setup

```bash
brew install jpeg-xl pkg-config
swift build -c release
swift test -c release           # 21 tests, ~7s
.build/release/jxl-tool --version
```

Requires macOS 13+. The Homebrew libjxl dylib targets macOS 15; older macOS works at runtime if libjxl is built or linked statically against an older SDK.

## CLI

```bash
# Encode a single DICOM directly (preserves 16-bit depth)
jxl-tool encode --input scan.dcm --output scan.jxl --lossless --effort 9

# Encode a single PNG / JPEG / TIFF / BMP / PGM
jxl-tool encode --input photo.png --output photo.jxl --quality 90 --effort 7

# Decode (multi-frame .jxl writes <stem>_z000.png, <stem>_z001.png, ...)
jxl-tool decode --input scan.jxl --output scan.png

# Inspect a JXL file
jxl-tool info scan.jxl

# Batch-encode a directory tree, parallel + memory-bounded + JSON manifest
jxl-tool batch /path/to/scans \
    --output /path/to/jxl-out \
    --lossless --effort 7 \
    --parallel 8 --max-memory-mb 1000 \
    --manifest /path/to/manifest.json

# Group DICOM slices by SeriesInstanceUID into one multi-frame .jxl per series
jxl-tool batch /path/to/study \
    --output /path/to/series-jxl \
    --lossless --volume-aware
```

Run any subcommand with `--help` for the full flag list.

## Library API

```swift
public struct ImageFrame { … }           // pixel container (uint8/uint16/float32)
public struct EncodingOptions { … }      // mode, effort, progressive, numThreads
public final class JXLEncoder {
    func encode(_ frame: ImageFrame) throws -> EncodedImage
    func encode(_ frames: [ImageFrame]) throws -> EncodedImage  // multi-frame
}
public final class JXLDecoder {
    func decode(_ data: Data) throws -> ImageFrame
    func decodeAll(_ data: Data) throws -> [ImageFrame]         // multi-frame
}

public enum DICOMReader {
    static func read(_ url: URL) throws -> ImageFrame
    static func readWithMetadata(_ url: URL) throws -> (frame: ImageFrame, metadata: DICOMMetadata)
}
public struct DICOMMetadata: Sendable {
    let bitsStored, pixelRepresentation, signedBias: Int
    let rescaleSlope, rescaleIntercept: Double
    let seriesInstanceUID, studyInstanceUID, modality: String?
    // ...
}
```

See `Sources/JXLSwift/` for the full surface; tests in `Tests/JXLSwiftTests/IntegrationTests.swift` exercise every public path including malformed-input rejection and pixel-level idempotency.

## Project layout

```
Sources/Cjxl/             SwiftPM systemLibrary that re-exports libjxl's C API
Sources/JXLSwift/         Swift API: ImageFrame, EncodingOptions, JXLEncoder,
                          JXLDecoder, DICOMReader (+ DICOMMetadata)
Sources/JXLTool/          jxl-tool CLI (encode, decode, info, batch)
Tests/JXLSwiftTests/      Integration tests + DICOM correctness fuzz cases
Examples/                 EncodeDecode.swift — minimal end-to-end demo
Documentation/            ARCHITECTURE.md, legacy/ (pre-rewrite history)
```

## Status

| | |
|---|---|
| **Build** | `swift build -c release` clean on macOS 13+ |
| **Tests** | 21 / 21 pass; CI runs every push to `main` |
| **Backend** | libjxl 0.11.x via Homebrew |
| **Bitstream** | ISO/IEC 18181-compliant (produced by libjxl) |
| **License** | See [LICENSE](LICENSE) |

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — release notes
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview
- [CLAUDE.md](CLAUDE.md) — guidance for AI-assisted contributors
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history

## Contributing

PRs welcome. Please run `swift test` before opening one — the integration tests cover lossless round-trip, multi-frame round-trip, DICOM correctness, and rejection of malformed inputs.

The library API is intentionally small. Before adding a feature, check whether it can live as a CLI subcommand or external script that calls the public API.
