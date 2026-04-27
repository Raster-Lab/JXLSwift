# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**JXLSwift** is a ground-up, independent implementation of the JPEG XL Image Coding System (ISO/IEC 18181) written in 100% pure Swift 6.2 with strict concurrency. **No native code, no C dependency, no transitive runtime libraries.** See [ROADMAP.md](ROADMAP.md) for the full project summary; the load-bearing constraints are repeated here.

### Hard constraints (do not relax)

1. **Pure Swift 6.2.** No C/C++/Objective-C in the runtime. The only acceptable foreign code is at testing time.
2. **Strict concurrency complete.** Every public API is `Sendable` where applicable. No `nonisolated(unsafe)` mutable state outside narrow, audited situations (e.g. SIGINT handler flag in `JXLTool/Batch` from the libjxl-backend branch — that pattern is not allowed in `Sources/JXLSwift/`).
3. **No shared mutable global state.** Use `actor` for shared mutability; pass dependencies explicitly otherwise.
4. **libjxl is a test-only oracle.** It must never be a runtime dependency, never a fallback codec backend, never imported from `Sources/`. Acceptable usage: tests can shell out to `cjxl`/`djxl`/`jxlinfo` to validate output bytes; benchmarks can compare against libjxl numbers (but the comparison numbers must not be published in the repo's user-facing docs — see the legal-exposure scrub from earlier rounds).
5. **Not DICOM-aware.** JXLSwift is the codec. DICOM lives in DICOMkit. Any DICOM file format / metadata / transfer-syntax handling does not belong here. The earlier `Sources/JXLSwift/Medical/DICOMReader.swift` was moved to `Documentation/legacy/` for this reason.

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
- Vulkan on non-Apple platforms (future, optional).

None of these are required for correctness; the scalar Swift path is always the source of truth.

## Source layout

```
Sources/JXLSwift/Bitstream/   BitReader, BitWriter (LSB-first per §2.4),
                              U32 / U64 / Enum spec integers (§C.2)
Sources/JXLSwift/Container/   ISOBMFF box parser/builder (ISO/IEC 18181-2)
Sources/JXLSwift/Codestream/  Signature, SizeHeader, BitDepth,
                              ColorEncoding, ExtraChannelInfo,
                              ImageMetadata
Sources/JXLSwift/Entropy/     HybridUint, PrefixCodeTable, ANSDistribution,
                              ANSEncoder, ANSDecoder
Sources/JXLSwift/Codec/       JXLEncoder, JXLDecoder (currently stubs;
                              JXLDecoder.inspect(_:) IS implemented),
                              ImageFrame, EncodingOptions
Sources/JXLTool/              jxl-tool CLI (info works; encode/decode
                              throw .notImplemented until the codec lands)
Tests/JXLSwiftTests/          44 round-trip tests across foundation,
                              headers, and entropy primitives
Documentation/                ARCHITECTURE.md, SESSION-NOTES.md, legacy/
```

## Setup

```bash
swift build -c release
swift test  -c release           # 71 tests, ~50 ms
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
| E5 | Histogram clustering / context maps (§C.6.4) | ⏳ |
| E6 | LZ77 hybrid (§C.6.5) | ⏳ |
| M  | Modular sub-codec (lossless path) | ⏳ |
| V  | VarDCT (lossy path) | ⏳ |
| R  | Restoration filters | ⏳ |
| J  | JPEG-XL ↔ JPEG reversible transcoding (no generational loss) | ⏳ |

Tracking detail and methodology in [ROADMAP.md](ROADMAP.md).

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
