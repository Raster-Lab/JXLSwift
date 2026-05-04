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
| `transcode` | ✅ (lossless transcoding) | ❌ (would map to JPEG↔JXL — Phase J on roadmap) |
| `validate` | ✅ (conformance) | ❌ |
| `benchmark` | ✅ | ✅ |
| `compare` | ✅ (compare two images) | ❌ |
| `convert` | ✅ (image format convert) | ❌ |
| `batch` | ✅ | ❌ |
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
| Input | `-i, --input <path>` | (positional) |
| Output | `-o, --output <path>` | (positional) |
| Quality | `-q, --quality <0..1>` | (varies by subcommand) |
| Lossless | `--lossless` | (implicit) |
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
5. **Stub subcommands** (`version`, `compare`, `completions`, `validate`) — tracked in [Sources/JXLTool/Stubs.swift](../Sources/JXLTool/Stubs.swift). All registered in `JXLTool.subcommands`. Each prints a "not yet implemented" message and exits with `JXLExitCode.notImplemented`. The parsing surface (flags, arg names) matches J2KSwift's `j2k` for drop-in compatibility.

### Phase B — parity migrations (next, with deprecation)

These change shape but preserve old-call compatibility:

6. **JXLSwift `JXLEncoder`/`JXLDecoder`**: convert from `final class`
   to `public struct: Sendable`. Deprecation cycle for class form.
7. **JXLSwift**: add async overloads on `encode(_:)` and `decode(_:)`.
   Keep sync versions as the default (Swift permits both).
8. **JXLSwift**: add progress-callback overload on encode/decode.
9. **JXLSwift CLI**: rename to `jxl` as the canonical name; alias
   `jxl-tool` as legacy.
10. **J2KSwift CLI**: switch to `swift-argument-parser` to match
    JXLSwift's parser library. Or keep both — flag names matter,
    not the library.

### Phase C — final convergence (optional, future)

11. Shared `CompressionFamily` umbrella product with
    `CompressionImage`/`CompressionEncoder`/`CompressionDecoder`
    protocols both libraries conform to. Callers can write
    `func encode<E: CompressionEncoder>(...)` and parameterise.
12. **J2KSwift `J2KImage`**: add a `pixelType`-style constructor
    when all components share bit depth (matches `ImageFrame` shape).
13. Common `CompressionError` parent enum, with library-specific
    refinements.

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
