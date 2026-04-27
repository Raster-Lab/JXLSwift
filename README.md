# JXLSwift

A Swift wrapper around [libjxl](https://github.com/libjxl/libjxl) for JPEG XL (ISO/IEC 18181), specialized for medical imaging.

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

## What it does that `cjxl` can't

| | cjxl | **jxl-tool** |
|---|---|---|
| Read DICOM (`.dcm`) directly, preserving 12/16-bit depth | ❌ requires `magick` → 8-bit PNG → cjxl | ✅ native, full bit depth |
| Group DICOM slices by `SeriesInstanceUID` into one multi-frame `.jxl` | ❌ | ✅ `--volume-aware` |
| Memory-bounded parallel batch | sequential per-process | ✅ `--max-memory-mb`, `--parallel N` |
| JSON manifest output for CI / automation | ❌ | ✅ `--manifest out.json` |

Compression and bitstream are **byte-identical to cjxl** (we use the same library) — the differentiation is the surface around it.

## Why JXL beats JPEG 2000 for medical imaging

Statistical benchmark on real 16-bit medical PGMs (CT 512×512, DX 2544×3056, MG 5928×4728), 145 MB total uncompressed, 24 wall-time samples per codec:

| Codec | Total wall (24 runs) | Median wall | **Compression ratio** |
|---|---:|---:|---:|
| **JXLSwift** | 17.12 s | 0.978 s | **3.581×** |
| libjxl `cjxl` (reference) | 16.25 s | 0.894 s | 3.581× |
| OpenJPEG `opj_compress` (DICOM Part 5 standard) | 23.18 s | 1.446 s | **2.290×** |
| zstd `-19` (general-purpose baseline) | 48.59 s | 1.371 s | 2.563× |

JPEG XL beats JPEG 2000 lossless by **56 %** on this corpus, in less wall time.

Reproduce: `ITERS=3 /tmp/jxl-it-runner/codec-bench.sh` after seeding the PGM corpus from your DICOM files (see [bench.sh](docs/bench.sh)).

## Setup

```bash
brew install jpeg-xl pkg-config
swift build -c release
swift test -c release           # 21 tests, ~7s
.build/release/jxl-tool --version
```

Requires macOS 13+ (the Homebrew libjxl dylib targets macOS 15; older macOS works at runtime if libjxl is statically linked).

## CLI

```bash
# Encode a single DICOM directly (preserves 16-bit)
jxl-tool encode --input scan.dcm --output scan.jxl --lossless --effort 9

# Encode a single PNG/JPEG/TIFF/BMP/PGM
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

The Swift surface is small and focused:

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

See `Sources/JXLSwift/` for the full surface; tests in `Tests/JXLSwiftTests/IntegrationTests.swift` exercise every public path.

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
| **Tests** | 21/21 pass; CI runs every push to `main` |
| **Cross-codec** | libjxl `djxl` decodes 100 % of JXLSwift output (and vice versa) |
| **Bitstream** | Byte-identical to `cjxl` on equivalent settings |
| **Backend** | libjxl 0.11.2 |
| **License** | See [LICENSE](LICENSE) |

## Documentation

- [CHANGELOG.md](CHANGELOG.md) — release notes
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview
- [CLAUDE.md](CLAUDE.md) — guidance for AI-assisted contributors
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history

## Contributing

PRs welcome. Please run `swift test` before opening one — the integration tests cover lossless round-trip, cross-codec compatibility, DICOM correctness, and rejection of malformed inputs.

The library API is intentionally small. Before adding a feature, check whether it can live as a CLI subcommand or external script that calls the public API.
