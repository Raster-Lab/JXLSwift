# Compression-library family — JXLSwift ↔ J2KSwift API parity

**Audience:** anyone touching public API or CLI surface in either
JXLSwift or J2KSwift.

**Goal:** the two libraries should be **drop-in replacements** for
each other. End users should be able to switch from `J2KEncoder` to
`JXLEncoder` (or `j2k` CLI to `jxl` CLI) without re-learning type
names, method signatures, or flag conventions.

**Direction:** the alignment is bidirectional. Either library can
move to match the other; the user has authorised changes to J2KSwift
in future releases to consolidate the family.

---

## 1. Public Swift API — current divergences

### Encoder

| Aspect | J2KSwift | JXLSwift | Diverges? |
|---|---|---|---|
| Type kind | `public struct J2KEncoder: Sendable` | `public final class JXLEncoder` | ⚠️ |
| Init param | `init(configuration: J2KConfiguration = J2KConfiguration())` | `init(options: EncodingOptions = EncodingOptions())` | ⚠️ |
| Encode signature | `encode(_ image: J2KImage) async throws -> Data` | `encode(_ frame: ImageFrame) throws -> EncodedImage` | ⚠️ |
| Returns | `Data` | `EncodedImage` (data + stats) | ⚠️ |
| Async | yes (`async throws`) | no (sync `throws`) | ⚠️ |
| Multi-frame | (TBC — likely separate API) | `encode(_ frames: [ImageFrame]) throws -> EncodedImage` | (similar pattern) |
| Progress callback | `encode(_:progress:)` overload | none | ⚠️ |

### Decoder

| Aspect | J2KSwift | JXLSwift | Diverges? |
|---|---|---|---|
| Type kind | `public struct J2KDecoder: Sendable` | `public final class JXLDecoder` | ⚠️ |
| Init param | `init()` | `init()` | matches |
| Decode signature | `decode(_ data: Data) async throws -> J2KImage` | `decode(_ data: Data) throws -> ImageFrame` | ⚠️ (async; image type) |
| Multi-frame | (TBC) | `decodeAll(_ data: Data) throws -> [ImageFrame]` | (J2K is single-image) |
| Inspect / metadata | (TBC) | `inspect(_:) -> JXLInspection` | ⚠️ |
| Progress callback | yes | none | ⚠️ |

### Image type

| Aspect | J2KSwift | JXLSwift | Diverges? |
|---|---|---|---|
| Name | `J2KImage` | `ImageFrame` | ⚠️ |
| `Sendable` | yes | yes | matches |
| Size fields | `width`, `height` | `width`, `height` | matches |
| Channels representation | `components: [J2KComponent]` (variable per-component bit depth) | `channels: Int` + `pixelType: PixelType` (uniform across channels) | ⚠️ structural |
| Colour space | `colorSpace: J2KColorSpace` | `colorSpace: ColorSpace` | partial (different enum names) |
| Tiling parameters | `tileWidth`, `tileHeight`, `tileOffsetX`, `tileOffsetY` | none | J2K-specific |
| Pixel data accessor | (per-component, via `J2KComponent.samples`) | flat `data: [UInt8]` (channel-interleaved) | ⚠️ structural |
| ICC profile | (TBC) | `iccProfile: Data?` | ⚠️ |
| Alpha | (TBC; via `components`?) | `alphaChannels: Int` (0 or 1) | ⚠️ |

### Configuration / options

| Aspect | J2KSwift | JXLSwift | Diverges? |
|---|---|---|---|
| Top-level type | `J2KConfiguration` (high-level: quality + lossless) | `EncodingOptions` (broader: `useM0Placeholder`, `m0Effort`, etc.) | ⚠️ |
| Detailed type | `J2KEncodingConfiguration` (full encode params) | (none — `EncodingOptions` is the only level) | ⚠️ |
| Static presets | `.lossless`, `.highQuality`, `.balanced`, `.fast` | (none on `EncodingOptions`) | ⚠️ |
| Quality field | `quality: Double` (0.0..1.0) | (TBC — JXL uses cjxl distance, not quality factor) | ⚠️ |
| Lossless flag | `lossless: Bool` | (implicit — Modular path is always lossless; VarDCT is lossy) | ⚠️ |

### Errors

| Aspect | J2KSwift | JXLSwift | Diverges? |
|---|---|---|---|
| Encode errors | `J2KError.encodingError(_:)`, `.invalidParameter(_:)` | `EncoderError.notImplemented(_:)`, `.unsupportedFrame(_:)`, `.bitstream(_:)` | ⚠️ |
| Decode errors | `J2KError.decodingError(_:)`, `.invalidParameter(_:)` | `DecoderError` (separate enum) | ⚠️ |
| Conforms to | `Error, LocalizedError, Sendable` | `Error, LocalizedError, Sendable` | matches |

### Module structure

| Aspect | J2KSwift | JXLSwift |
|---|---|---|
| Library products | 9 (J2KCore, J2KCodec, J2KAccelerate, J2KFileFormat, J2KMetal, J2KVulkan, JPIP, J2K3D, J2KXS) | 1 (JXLSwift) |
| CLI executable | `j2k` (target J2KCLI) | `jxl-tool` (target JXLTool) |

---

## 2. CLI — current divergences

### Command name

| J2KSwift | JXLSwift |
|---|---|
| `j2k` | `jxl-tool` |

For family parity, JXLSwift's CLI should be **`jxl`** (drop the
`-tool` suffix to match J2KSwift's pattern).

### Subcommand surface

| Subcommand | J2KSwift | JXLSwift |
|---|---|---|
| `encode` | ✅ | ✅ |
| `decode` | ✅ | ✅ |
| `info` | ✅ | ✅ |
| `transcode` | ✅ (lossless transcoding) | ✅ subcommand surface (since v0.12.0e); forward direction maps to the existing JPEG-decode + JXL-encode pixel-fallback path today; bit-perfect coefficient bridge + JXL → JPEG reverse are in-progress Phase J capstone work — see [Documentation/PHASE-J-COEFFICIENT-BRIDGE.md](PHASE-J-COEFFICIENT-BRIDGE.md). |
| `validate` | ✅ (conformance) | ❌ |
| `benchmark` | ✅ | ✅ |
| `compare` | ✅ (compare two images) | ❌ |
| `convert` | ✅ (image format convert) | ✅ (since v0.13.0-dev — PNM ↔ JXL, JPEG → PNM/JXL, format by extension) |
| `batch` | ✅ | ✅ (since v0.11.0bs — `encode` + `decode` sub-subcommands, `--recursive`, `--filter`, `--continue-on-error`, `--json`) |
| `completions` | ✅ (shell completions) | ❌ |
| `version` | ✅ | (via `--version` flag) |
| `help` | ✅ | (via `--help` flag) |
| `encode3d` | ✅ (3D volumetric) | ❌ (DICOM scope — out of charter) |
| `decode3d` | ✅ | ❌ (same) |
| `jpip` | ✅ (JPIP streaming) | ❌ (J2K-specific) |
| `encode-m0` / `decode-m0` | ❌ | ✅ (project-internal placeholder) |

**Common subcommands needed in both:** `encode`, `decode`, `info`,
`transcode`, `validate`, `benchmark`, `compare`, `convert`, `batch`,
`completions`, `version`, `help`.

**Library-specific (acceptable divergence):** `jpip`, `encode3d`,
`decode3d` for J2KSwift; `encode-m0`, `decode-m0` for JXLSwift
(internal-only — could be hidden behind `--internal` flag).

### Flag conventions

| Flag | J2KSwift | JXLSwift |
|---|---|---|
| Input | `-i, --input <path>` | `-i, --input <path>` ✅ |
| Output | `-o, --output <path>` | `-o, --output <path>` ✅ |
| Quality | `-q, --quality <0..1>` | `-q, --quality <0..100>` (lossy encode/convert) |
| Lossless | `--lossless` | `-l, --lossless` ✅ |
| Codec / variant | `--codec <variant>` | (no equivalent yet) |
| Preset | `--preset <fast\|balanced\|quality>` | (none) |
| Format | `--format <j2k\|jp2\|jpx\|jph>` | (none) |
| Region of interest | `--region <x,y,w,h>` | (none) |
| Resolution scale | `--scale <1\|2\|4\|8>` | (none) |

**Argument-parsing approach diverges too:** J2KSwift hand-rolls a
parser with British/American spelling normalisation
(`--colour` ↔ `--color`, `--optimise` ↔ `--optimize`, etc.).
JXLSwift uses **swift-argument-parser**. The user-visible flag
names should match; the parser implementation can stay separate.

---

## 3. Recommended alignment path (proposal — needs user confirmation)

The alignment is substantial. Recommend phasing:

### Phase A — non-breaking additions ✅ shipped (v0.9.0u)

All five Phase A items are landed:

1. **`JXLImage` typealias for `ImageFrame`** —
   [Sources/JXLSwift/Codec/ImageFrame.swift:131](../Sources/JXLSwift/Codec/ImageFrame.swift). Pin-down: `testFamilyParity_JXLImage_isImageFrame`.
2. **`EncodingOptions` static presets** (`.lossless`, `.highQuality`, `.balanced`, `.fast`) —
   [Sources/JXLSwift/Codec/EncodingOptions.swift](../Sources/JXLSwift/Codec/EncodingOptions.swift). Pin-down: `testFamilyParity_EncodingOptions_Presets`.
3. **`JXLConfiguration`** struct with `quality: Double` + `lossless: Bool` mapping to `EncodingOptions` via the `.encodingOptions` computed property. `JXLEncoder.init(configuration:)` convenience init added.
   [Sources/JXLSwift/Codec/EncodingOptions.swift](../Sources/JXLSwift/Codec/EncodingOptions.swift). Pin-down: `testFamilyParity_JXLConfiguration_MapsToEncodingOptions`.
4. **`jxl` CLI alias** — added as a second `.executable` product targeting the existing `JXLTool` target. SwiftPM compiles two binaries (`jxl` and `jxl-tool`) from one source.
   [Package.swift:23](../Package.swift).
5. **Family-parity subcommands** (`version`, `compare`, `completions`, `validate`) — in [Sources/JXLTool/Stubs.swift](../Sources/JXLTool/Stubs.swift), all registered in `JXLTool.subcommands`. **No longer stubs** — each is fully implemented (e.g. `compare` does per-frame pixel diffing, `completions` emits real shell completions, `validate` checks codestream structure). The parsing surface (flags, arg names) matches J2KSwift's `j2k` for drop-in compatibility.

> **Status update (v0.13.0-dev).** Since the text below was written: CLI flags
> are now `-i/-o` (not positional) in both repos; the `convert` subcommand has
> landed in JXLSwift (PNM ↔ JXL, JPEG → PNM/JXL); and `JXLToolVersion` reports
> `0.13.0-dev` (was a stale `0.5.0-pure-swift`). **One accidental divergence
> remains for the API freeze, needs a direction decision:** preset quality
> values differ — JXLSwift `JXLConfiguration.balanced = 0.9` / `.fast = 0.75`
> vs J2KSwift `.balanced = 0.85` / `.fast = 0.70`, and J2KSwift has a
> `.maxCompression = 0.50` preset JXLSwift lacks. Recommended: align JXLSwift
> to J2KSwift's values (0.85 / 0.70) and add `.maxCompression`, since J2KSwift
> shipped first; but this changes preset behaviour for existing JXL callers, so
> it is left for explicit sign-off rather than changed unilaterally (see §4).

### Phase B — parity migrations ✅ shipped (v0.9.0v–y)

Items 6–9 are landed. Item 10 is cross-repo and deferred.

6. **`JXLEncoder` / `JXLDecoder` are now `public struct: Sendable`** —
   converted from `final class`. Soft source change; existing
   callers using `JXLEncoder()` / `JXLDecoder()` work unchanged.
   The only break is for callers who relied on REFERENCE semantics.
   [Sources/JXLSwift/Codec/JXLEncoder.swift](../Sources/JXLSwift/Codec/JXLEncoder.swift),
   [Sources/JXLSwift/Codec/JXLDecoder.swift](../Sources/JXLSwift/Codec/JXLDecoder.swift).
7. **Async overloads** on `encode(_:)` / `decode(_:)` /
   `decodeAll(_:)` — [Sources/JXLSwift/Codec/AsyncOverloads.swift](../Sources/JXLSwift/Codec/AsyncOverloads.swift).
   Pin-down: `testFamilyParity_AsyncOverloads_RoundTrip`.
8. **Progress-callback overloads** on encode/decode with
   `JXLEncoderProgressUpdate` / `JXLDecoderProgressUpdate` types
   matching J2KSwift's shape. JXL-specific stage enums
   (`JXLEncodingStage`, `JXLDecodingStage`).
   [Sources/JXLSwift/Codec/Progress.swift](../Sources/JXLSwift/Codec/Progress.swift).
   Pin-down: `testFamilyParity_ProgressCallbacks`.
   **Granularity caveat**: callbacks fire at start (overallProgress=0)
   and end (overallProgress=1). Future revisions add per-stage updates.
9. **CLI canonical name renamed** to `jxl`. Both binaries
   (`jxl` and `jxl-tool`) display "jxl" in `--help` / `--version`.
   The legacy `jxl-tool` binary still ships as a Phase A.4 product
   alias and is functionally identical.
   [Sources/JXLTool/JXLTool.swift](../Sources/JXLTool/JXLTool.swift).

### Phase B item 10 — deferred (cross-repo)

10. **J2KSwift CLI parser switch** to `swift-argument-parser`
    (matching JXLSwift's parser library). This requires changes to
    the J2KSwift repo, not JXLSwift. Flag names already match per
    Phase A.5 — the parser-library divergence is implementation,
    not user-visible surface, so this is non-urgent.

### Phase C — final convergence ✅ shipped (v0.9.0z)

Items 11 and 13 are landed in JXLSwift. Item 12 is cross-repo
(J2KSwift) and deferred.

11. **`CompressionFamily` protocols** —
    [Sources/JXLSwift/CompressionFamily.swift](../Sources/JXLSwift/CompressionFamily.swift)
    defines four protocols:
    - `CompressionImage: Sendable` — minimal common ground (`width`,
      `height`).
    - `CompressionOutput: Sendable` — encoded-bitstream wrapper with
      `data: Data` accessor.
    - `CompressionEncoder: Sendable` — `associatedtype Image` +
      `associatedtype Output`, `encode(_:) async throws -> Output`.
    - `CompressionDecoder: Sendable` — `associatedtype Image`,
      `decode(_:) async throws -> Image`.

    JXLSwift conformances added: `ImageFrame: CompressionImage`,
    `EncodedImage: CompressionOutput`, `JXLEncoder:
    CompressionEncoder`, `JXLDecoder: CompressionDecoder`. Callers
    can write generic-over-codec helpers like:

        func encodeAll<E: CompressionEncoder>(
            _ enc: E, images: [E.Image]
        ) async throws -> [Data] { ... }

    Pin-downs:
    `testFamilyParity_GenericOverCompressionEncoder`,
    `testFamilyParity_GenericOverCompressionDecoder`.

13. **`CompressionError` umbrella protocol** — `EncoderError` and
    `DecoderError` both conform. Callers can `catch let e as
    CompressionError` regardless of which library emitted it.
    Pin-down: `testFamilyParity_CompressionError_UmbrellaCatch`.

### Phase C item 12 — deferred (cross-repo)

12. **J2KSwift `J2KImage` pixelType-style convenience constructor**
    — would let `J2KImage` be constructible from the same
    `(width, height, channels, bitDepth)` shape as `ImageFrame`.
    Requires changes to the J2KSwift repo. JXLSwift's
    `ImageFrame.init` is already in this shape, so the convergence
    will land bidirectionally once J2KSwift adopts.

### Cross-repo follow-ons (deferred to J2KSwift)

For the family-parity story to complete, J2KSwift must:
1. Mirror the four `CompressionFamily` protocols (or import them
   if we extract a shared package). Each conformance is a one-line
   extension if the existing types already match the shape.
2. Add the `J2KImage(width:height:channels:bitDepth:)` convenience
   constructor (Phase C.12).
3. Optionally switch its CLI parser to swift-argument-parser
   (Phase B.10) — non-urgent; flag surface already aligned.

---

## 4. What to NOT change unilaterally

These are foundational decisions where breaking changes need user
sign-off:

- Renaming `JXLEncoder` / `JXLDecoder` (would break all existing
  callers).
- Changing `encode` return type from `EncodedImage` to `Data`
  (loses the `CompressionStats` payload).
- Removing `decodeAll(_:)` (no J2K equivalent, but JXL-specific
  multi-frame use case is real).
- Adding `async` to existing sync APIs without keeping the sync
  overload (would be a forced migration).

---

## 5. Status

This document is a proposal. **No code changes have been made** to
align the APIs in this commit — it's a divergence audit + plan.
The user should:

1. Review the alignment plan and decide direction.
2. Decide which phases to execute, in which library.
3. Decide whether the canonical names should be J2K-style
   (`J2KConfiguration`-style verbose) or JXL-style
   (`EncodingOptions`-style terse) — both are defensible.

---

## 6. References

- JXLSwift public API: [Sources/JXLSwift/Codec/JXLEncoder.swift](../Sources/JXLSwift/Codec/JXLEncoder.swift), [Sources/JXLSwift/Codec/JXLDecoder.swift](../Sources/JXLSwift/Codec/JXLDecoder.swift), [Sources/JXLSwift/Codec/ImageFrame.swift](../Sources/JXLSwift/Codec/ImageFrame.swift), [Sources/JXLSwift/Codec/EncodingOptions.swift](../Sources/JXLSwift/Codec/EncodingOptions.swift)
- JXLSwift CLI: [Sources/JXLTool/JXLTool.swift](../Sources/JXLTool/JXLTool.swift)
- J2KSwift public API: `/Users/raster/Documents/raster/J2KSwift/Sources/J2KCodec/J2KCodec.swift`, `/Users/raster/Documents/raster/J2KSwift/Sources/J2KCore/J2KCore.swift`
- J2KSwift CLI: `/Users/raster/Documents/raster/J2KSwift/Sources/J2KCLI/`
