# JXLSwift

Swift wrapper around the [libjxl](https://github.com/libjxl/libjxl) reference codec for JPEG XL (ISO/IEC 18181). Provides a small, ergonomic Swift API for encoding and decoding `.jxl` files, plus a `jxl-tool` CLI.

## Status

| | |
|---|---|
| Build | `swift build -c release` ✓ |
| Tests | `swift test -c release` — 7/7 integration tests pass |
| Cross-codec | libjxl decodes 100 % of JXLSwift output and vice versa |
| Lossless ratio | 11.3× average on medical-imagery PNGs |
| Backend | libjxl 0.11.2 (Homebrew `jpeg-xl`) |
| Platforms | macOS 13+ (linked dylib needs macOS 15) |

## Why a wrapper, not a pure-Swift codec?

A faithful pure-Swift implementation of JPEG XL is multi-person-year work — libjxl itself is ~150 KLOC of expert compression code. An earlier iteration of this project attempted a from-scratch Swift implementation; the resulting bitstreams could not be decoded by the reference codec. This rewrite delegates compression to libjxl and exposes a clean Swift surface, so the produced files are **spec-compliant by construction** and round-trip cleanly with any other JXL implementation.

For the historical pure-Swift attempt, see the `pre-rewrite-snapshot` branch and `Documentation/legacy/`.

## Setup

```bash
brew install jpeg-xl pkg-config
swift build -c release
```

That's it.

## Library usage

```swift
import JXLSwift

// Build or load an ImageFrame however you like.
var frame = ImageFrame(width: 1024, height: 768, channels: 3,
                       pixelType: .uint8, colorSpace: .sRGB)
// ... fill frame.data ...

// Lossless encode at high effort.
let encoder = JXLEncoder(options: EncodingOptions(
    mode: .lossless, effort: .tortoise
))
let encoded = try encoder.encode(frame)
try encoded.data.write(to: URL(fileURLWithPath: "image.jxl"))

// Decode.
let bytes = try Data(contentsOf: URL(fileURLWithPath: "image.jxl"))
let decoded = try JXLDecoder().decode(bytes)
```

`EncodingOptions` knobs:

- `mode`: `.lossless` (libjxl distance = 0), `.lossy(quality: 0...100)`, or `.distance(0...25)` (smaller is higher quality)
- `effort`: `EncodingEffort` enum, `.lightning` (1) → `.tortoise` (9). Tortoise is best compression, slowest.
- `progressive`: enables libjxl's progressive DC encoding.
- `numThreads`: 0 = libjxl default, otherwise the worker-thread count for the parallel runner.

## CLI usage

```bash
swift run jxl-tool encode --input photo.png --output photo.jxl --lossless --effort 9
swift run jxl-tool decode --input photo.jxl --output recovered.png
swift run jxl-tool info photo.jxl
```

`jxl-tool encode` accepts PNG/JPEG/TIFF/BMP via ImageIO and emits a `.jxl` file. `jxl-tool decode` produces a PNG. Run any subcommand with `--help` for the full flag list.

## Project layout

```
Sources/Cjxl/          — module.modulemap + shim header re-exporting libjxl
Sources/JXLSwift/      — public Swift API
Sources/JXLTool/       — jxl-tool CLI
Tests/JXLSwiftTests/   — integration tests
Examples/              — minimal sample programs
Documentation/legacy/  — pre-rewrite docs (read-only history)
```

## Integration tests

The test suite at `Tests/JXLSwiftTests/IntegrationTests.swift` runs against PNGs derived from real medical DICOM data symlinked into the repo at `LocalDatasets/`. To populate the cache for local runs:

```bash
mkdir -p /tmp/jxl-it/png
SRC=path/to/LocalDatasets/medical-dicom-organized
# convert a sample of DICOM files to PNG via ImageMagick (5 per modality)
for modality in ct dx mg mr px xa; do
    i=0
    for f in "$SRC/$modality"/study_*/instance_*.dcm; do
        magick "$f" -depth 8 -colorspace Gray \
            "/tmp/jxl-it/png/${modality}_$(basename $(dirname "$f"))_$(basename "$f" .dcm).png"
        i=$((i+1)); [ $i -ge 5 ] && break
    done
done
```

Without the cache the integration tests `XCTSkipIf` cleanly.

## License

See [LICENSE](LICENSE).
