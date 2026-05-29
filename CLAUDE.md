# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**JXLSwift** is a ground-up, independent implementation of the JPEG XL Image Coding System (ISO/IEC 18181). The codec is **Swift-first** — written in Swift 6.2 with strict concurrency — and **C/C++ is permitted only as an optional optimisation layer** (see constraint 1). See [ROADMAP.md](ROADMAP.md) for the full project summary; the load-bearing constraints are repeated here.

### Hard constraints (do not relax)

1. **Swift-first; C/C++ permitted only for measured optimisation.** The codec is implemented in Swift 6.2. New code defaults to Swift. C/C++ *is* allowed in the runtime, but **only** for a performance-critical hot path that profiling has shown to matter, and **only** behind a clean abstraction with a correct scalar-Swift implementation that remains the source of truth (see Design priorities — "the scalar Swift path is always the source of truth"). A C path must be byte-equivalent to the Swift path within a documented epsilon and deletable without disturbing the core. Do not reach for C for correctness-only logic (parsers, transforms, bitstream) — that stays Swift. libjxl specifically remains test-only (constraint 4): "allow C" does not mean "vendor libjxl". *(Amended 2026-05 — the original constraint was "no C/C++/Objective-C in the runtime"; relaxed by the project owner to permit an optional native optimisation layer.)*
2. **Strict concurrency complete.** Every public API is `Sendable` where applicable. No `nonisolated(unsafe)` mutable state outside narrow, audited situations (e.g. SIGINT handler flag in `JXLTool/Batch` from the libjxl-backend branch — that pattern is not allowed in `Sources/JXLSwift/`).
3. **No shared mutable global state.** Use `actor` for shared mutability; pass dependencies explicitly otherwise.
4. **libjxl is a test-only oracle.** It must never be a runtime dependency, never a fallback codec backend, never imported from `Sources/`. Acceptable usage: tests can shell out to `cjxl`/`djxl`/`jxlinfo` to validate output bytes; benchmarks can compare against libjxl numbers (but the comparison numbers must not be published in the repo's user-facing docs — see the legal-exposure scrub from earlier rounds).
5. **Not DICOM-aware.** JXLSwift is the codec. DICOM lives in DICOMkit. Any DICOM file format / metadata / transfer-syntax handling does not belong here. The earlier `Sources/JXLSwift/Medical/DICOMReader.swift` was moved to `Documentation/legacy/` for this reason.
6. **Family parity with J2KSwift.** JXLSwift is part of a Swift compression-library family alongside [J2KSwift](/Users/raster/Documents/raster/J2KSwift) (JPEG 2000). Public API + CLI surface should mirror J2KSwift so callers can switch between codecs without re-learning the syntax. Before adding or changing public types / methods / flags, check J2KSwift for the equivalent and align — see [Documentation/FAMILY-API-PARITY.md](Documentation/FAMILY-API-PARITY.md) for the current divergence audit. Bidirectional alignment is allowed (J2KSwift can change to match too).

### Design priorities (in order)

1. **Speed (throughput / latency).** Single-threaded throughput first; vectorise next.
2. **Compression performance** (rate–distortion efficiency).
3. **Resource efficiency** (memory and footprint).

Configurable trade-offs (`EncodingOptions`) must let callers pick which dimension dominates.

### Platform targets

- **Primary:** macOS on Apple Silicon (arm64).
- **Modular support:** macOS Intel (x86_64), Linux Intel (x86_64).
- Platform-specific code paths (e.g. x86 SSE/AVX) live behind a clean abstraction so they can be deleted later without disturbing the core.

### Optional acceleration (future, kept modular)

- ARM NEON / Swift SIMD types — primary optimisation path.
- Apple Accelerate framework for vectorised operations where applicable.
- Metal GPU compute for large-scale parallel workloads (optional).
- **C/C++ hot-path layer** — permitted for performance-critical routines (per constraint 1): a measured hot path may be reimplemented in C/C++ behind a clean SwiftPM `target` boundary, with the scalar Swift implementation kept as the always-correct reference.
- Vulkan on non-Apple platforms (future, optional).

None of these are required for correctness; the scalar Swift path is always the source of truth.

## Source layout

```
Sources/JXLSwift/Bitstream/   BitReader, BitWriter (LSB-first per §2.4),
                              U32 / U64 / Enum spec integers (§C.2)
Sources/JXLSwift/Container/   ISOBMFF box parser/builder (ISO/IEC 18181-2)
Sources/JXLSwift/Codestream/  Signature, SizeHeader, BitDepth,
                              ColorEncoding, ExtraChannelInfo,
                              ImageMetadata, FrameHeader
Sources/JXLSwift/Entropy/     HybridUint, PrefixCodeTable, ANSDistribution,
                              ANSEncoder, ANSDecoder, ContextMap,
                              LZ77Config, SimpleEntropyStream
Sources/JXLSwift/Modular/     Predictors (W/N/NW/NE/avgWN/gradient/MED),
                              Neighbourhood, ZigZag pack/unpack,
                              RCT (YCoCg-R reversible colour transform)
Sources/JXLSwift/Codec/       JXLEncoder + JXLDecoder (implemented:
                              lossless Modular encode/decode, lossy
                              VarDCT *decode*, JPEG⇄JXL transcode),
                              SpecModularEncoder (the spec lossless
                              encoder — the main lossless path),
                              ImageFrame, EncodingOptions
Sources/JXLTool/              jxl-tool CLI (info / encode / decode)
Tests/JXLSwiftTests/          ~688 round-trip + `djxl` byte-exact tests
Documentation/                ARCHITECTURE.md, SESSION-NOTES.md, legacy/
```

## Setup

```bash
swift build -c release
swift test  -c release           # ~688 tests, ~70 s (many shell out to djxl)
.build/release/jxl-tool --version
```

**Zero external dependencies** outside `swift-argument-parser` (CLI only). No Homebrew packages required for the library or tests to run.

## Implementation status (high level)

| Phase | Spec | Done? |
|---|---|---|
| F  | Foundation (bitstream + container + signature + SizeHeader) | ✅ |
| H  | Image headers (BitDepth, ColorEncoding, ExtraChannelInfo, ImageMetadata) | ✅ — read + write + round-trip |
| E1 | HybridUint encoding (§C.5) | ✅ |
| E2 | Prefix codes / canonical Huffman (§C.6.2) | ✅ |
| E3 | rANS (§C.6.3) | ✅ |
| E4a | Prefix-code-table serialisation (§C.6.2.1) — simple + complex | ✅ |
| E4b | rANS distribution serialisation (§C.6.3.2) — simple + flat shortcuts | ✅ (full mode pending) |
| E5 | Histogram clustering / context maps (§C.6.4) | ✅ simple + full path (>8-cluster `djxl` compliance pending) |
| E6 | LZ77 hybrid header (§C.6.5) | ✅ header only (back-references pending) |
| M0 | Project-internal vertical slice via `MinimalLosslessCodec` | ✅ |
| M  | Modular sub-codec (lossless path, real frame header §C.8.1) | ✅ — `SpecModularEncoder`: 8/16-bit gray / gray+alpha / RGB / RGBA, arbitrary dims ≤ 16384 (multi-group + multi-DC-group), multi-property MA-trees + learned thresholds, effort knob, `djxl`-byte-exact |
| V  | VarDCT (lossy path) | ✅ **decode** (`djxl`-matching, Phase R filters incl.); lossy *encode* deferred to the last phase (project focus is lossless) |
| R  | Restoration filters (Gaborish + EPF) | ✅ (decode) |
| J  | JPEG-XL ↔ JPEG reversible transcoding (no generational loss) | ✅ forward (JPEG→JXL, ~1.03–1.05× cjxl, ≤ 2048 px/side) + reverse (JXL→JPEG, byte-identical: baseline + progressive + ICC) |

Tracking detail and methodology in [ROADMAP.md](ROADMAP.md). Release-by-release detail in [CHANGELOG.md](CHANGELOG.md); current-state map in [Documentation/STATUS-AND-ROADMAP.md](Documentation/STATUS-AND-ROADMAP.md).

## Conventions

- **All public API needs `///` doc comments.**
- **No force unwraps (`!`) or force casts (`as!`) in production code.** Throws over traps in parsing paths.
- **Cite spec sections** in comments (e.g. `// §C.6.2`). Every byte the codec emits should trace to a spec section.
- **Tests catch lies.** Every claim of "X works" needs a round-trip test that fails when X breaks. The previous v1.0.0 attempt (preserved on `pre-rewrite-snapshot`) shipped non-spec-compliant output because tests didn't enforce spec compliance — don't repeat that.
- **British English** in user-facing strings.

## How to extend

| Want to | Add to |
|---|---|
| Implement a new spec section | Locate the right module under `Sources/JXLSwift/{Bitstream, Container, Codestream, Entropy, Codec}` and add a file. Each file should declare in a header comment which `§` section it implements. |
| Expose a new public knob | Property in `EncodingOptions`. Don't grow the API beyond what the spec actually parameterises. |
| Add a CLI subcommand | New file under `Sources/JXLTool/` and register in `JXLTool.swift`'s subcommands list. CLI must use only `JXLSwift`'s public API. |
| Add a benchmark | Use `XCTest`'s `measure` block; keep the bench script under `scripts/` (not committed to user-facing docs) — comparative numbers vs other codecs do NOT belong in the repo's prose. |

## What is intentionally NOT in this repo

- **Any libjxl source code, headers, or runtime.** libjxl-backend exists as a separate git branch for historical reference only.
- **DICOM file format or metadata handling.** That's DICOMkit's responsibility.
- **Comparative benchmark prose.** Performance comparison against named third-party codecs has legal-exposure considerations (covered in commit `d6913d3`); keep numbers in dev-time scripts, not in committed docs.
- **GPU-accelerated paths** in the current codebase. Those land later, behind feature flags, only when the scalar path is proven.

## Reference docs

- [ROADMAP.md](ROADMAP.md) — project summary + phase-by-phase status
- [README.md](README.md) — public-facing project description
- [CHANGELOG.md](CHANGELOG.md) — release notes
- [Documentation/ARCHITECTURE.md](Documentation/ARCHITECTURE.md) — design overview
- [Documentation/SESSION-NOTES.md](Documentation/SESSION-NOTES.md) — handoff guide for the next contributor
- [Documentation/legacy/](Documentation/legacy/) — pre-rewrite history (read-only)

## Branches

| | |
|---|---|
| `main` | Pure-Swift implementation (active development) |
| `libjxl-backend` | Historical reference only — the libjxl-wrapped implementation that preceded the pure-Swift restart. **Not** a supported runtime path. |
| `pre-rewrite-snapshot` | Original failed pure-Swift attempt — preserved for lessons learned |
| Tag `v0.4-libjxl` | Snapshot of the libjxl-wrapped `main` |
