# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project (post-rewrite)

**JXLSwift** is a thin, ergonomic Swift wrapper around the **libjxl** reference codec (Homebrew `jpeg-xl`). The earlier "pure Swift" implementation was wiped because it produced bitstreams that the reference decoder could not read; the rewrite delegates compression to libjxl and exposes a small Swift-native public API.

**Layout:**

```
Sources/Cjxl/          — module.modulemap + shim.h re-exporting <jxl/*.h>
Sources/JXLSwift/      — public Swift API (ImageFrame, EncodingOptions,
                          JXLEncoder, JXLDecoder)
Sources/JXLTool/       — `jxl-tool` CLI (encode, decode, info subcommands)
Tests/JXLSwiftTests/   — integration tests against /tmp/jxl-it/png
                          (LocalDataset; tests skip when absent)
Examples/              — minimal example scripts using the new API
Documentation/legacy/  — pre-rewrite docs and examples (read-only history)
```

**Toolchain:**

- **Swift 6.2+** strict concurrency
- **Platforms:** macOS 13+ (the linked Homebrew libjxl was built for macOS 15; older targets get a deployment-target warning but run on the dev machine).
- **External deps:** Homebrew `jpeg-xl` (provides `libjxl`, `libjxl_threads`, `cjxl`/`djxl`/`jxlinfo`) and `pkg-config`. `swift-argument-parser` for the CLI.
- The project is **macOS-only** for now. Adding iOS/tvOS/watchOS/visionOS requires statically linking libjxl into the app bundle.

## Setup on a fresh machine

```bash
brew install jpeg-xl pkg-config
swift build -c release
swift test -c release        # 7 tests, ~10s
```

For the integration tests to actually run, populate `/tmp/jxl-it/png` with sample PNGs (see "Integration testing" below). Without them, all tests in `IntegrationTests` skip cleanly.

## Build / test commands

```bash
swift build -c release        # Build everything (~14 s clean)
swift test -c release         # Run integration tests
swift run jxl-tool encode --input in.png --output out.jxl --lossless --effort 9
swift run jxl-tool decode --input out.jxl --output recovered.png
swift run jxl-tool info out.jxl
```

## Public API surface (current)

- **`ImageFrame`** — row-major channel-interleaved pixel buffer with `width`, `height`, `channels`, `pixelType` (`uint8`/`uint16`/`float32`), `colorSpace`, optional ICC profile.
- **`EncodingOptions`** — `mode` (`.lossless` / `.lossy(quality:)` / `.distance(_:)`), `effort` (1-9), `progressive`, `numThreads`.
- **`JXLEncoder.encode(_:) -> EncodedImage`** — wraps `JxlEncoder*` with thread-pool parallel runner.
- **`JXLDecoder.decode(_:) -> ImageFrame`** — wraps `JxlDecoder*` state machine.
- The advanced types from v1 (`ResponsiveConfig`, `RegionOfInterest`, `PatchConfig`, `NoiseConfig`, `SplineConfig`, etc.) are **not implemented**; libjxl exposes its own knob set and adding Swift-side wrappers is incremental future work.

## Integration testing

The integration suite at [Tests/JXLSwiftTests/IntegrationTests.swift](Tests/JXLSwiftTests/IntegrationTests.swift) covers what the v1 codec failed at:

1. lossless round-trip is **pixel-exact** across all dataset samples
2. lossy quality 90 / distance 1.0 produces **PSNR ≥ 35 dB**
3. lossless output is **strictly smaller than the raw input**
4. **cross-codec**: libjxl `djxl` decodes JXLSwift output successfully
5. **cross-codec**: JXLSwift decodes `cjxl` output successfully
6. encoded bitstream carries the JXL signature

Tests pull samples from `/tmp/jxl-it/png` (PNGs derived from `LocalDatasets/medical-dicom-organized` via ImageMagick — the medical-DICOM data is symlinked from `J2KSwift/LocalDatasets`). When the directory is empty, the tests `XCTSkipIf` cleanly so CI without the dataset stays green.

To populate the dataset for local runs:

```bash
mkdir -p /tmp/jxl-it/png
SRC=/Users/raster/Documents/raster/J2KSwift/LocalDatasets/medical-dicom-organized
for modality in ct dx mg mr px xa; do
    for f in "$SRC/$modality"/study_*/instance_*.dcm; do
        out="/tmp/jxl-it/png/${modality}_$(basename $(dirname "$f"))_$(basename "$f" .dcm).png"
        magick "$f" -depth 8 -colorspace Gray "$out"
    done | head -5    # 5 per modality is plenty
done
```

## Conventions

- Public API needs `///` doc comments.
- No force unwraps (`!`) or force casts (`as!`) in production code.
- `Sendable` for types crossing concurrency boundaries.
- C interop happens **only** in `Sources/JXLSwift/JXLEncoder.swift` and `JXLDecoder.swift`. Other files are pure Swift.
- British English in user-facing strings (the CLI tool's `--colour-space` etc. is gone for now; the new CLI is minimal).

## Reference docs

- [README.md](README.md) — top-level project description and usage
- [CHANGELOG.md](CHANGELOG.md) — release notes
- [CONTRIBUTING.md](CONTRIBUTING.md) — contributor guide
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite docs and examples
- [pre-rewrite-snapshot](https://github.com/) branch — preserves the broken Native backend if anyone wants to study it

## What changed in the rewrite (2026-04-27)

- Wiped 53 927 lines of broken codec across 90 files (`Sources/JXLSwift/`, `Tests/JXLSwiftTests/`, `Sources/JXLTool/`, root milestone docs).
- New `Cjxl` SwiftPM systemLibrary target binds libjxl's C API.
- New ~600-line Swift API surface that produces spec-compliant JPEG XL bitstreams.
- New 7-test integration suite, all green; broader 30×6 = 180-run integration matrix, all 180 pass with **average lossless ratio 11.31×** (was 0.51× before, i.e. file *larger* than raw).
- The pre-rewrite state is saved on branch `pre-rewrite-snapshot` (commit `f0927ef`) so nothing is lost.
