# JXLSwift Architecture

This document explains why the codebase is shaped the way it is and what guarantees the design provides.

## One-line summary

A thin, ergonomic Swift surface over libjxl, plus medical-imaging integrations (DICOM, multi-frame, memory-bounded batch).

## Module map

```
┌──────────────────────────────────────────────────────────────┐
│ Sources/JXLTool/        — jxl-tool CLI                       │
│   • Encode.swift        single-file encode (PNG/JPG/TIFF/    │
│                         BMP/PGM/DICOM autodetect)            │
│   • Decode.swift        single + multi-frame decode → PNG    │
│   • Info.swift          JXL header inspection                │
│   • Batch.swift         parallel batch (TaskGroup),          │
│                         memory-bounded (MemoryBudget actor), │
│                         volume-aware DICOM grouping,         │
│                         JSON manifest output, SIGINT cancel  │
│   • Utilities.swift     ImageIO/PGM loaders, 8/16-bit PNG    │
│                         writer, magick fallback              │
└──────────────────────────────────────────────────────────────┘
                       depends on
                         ▼
┌──────────────────────────────────────────────────────────────┐
│ Sources/JXLSwift/       — public Swift API                   │
│   • ImageFrame.swift    pixel container (uint8 / uint16 /    │
│                         float32, sRGB / grayscale / Display  │
│                         P3 / Rec.2020 / linearRGB, optional  │
│                         ICC profile, alpha)                  │
│   • EncodingOptions.swift  mode (.lossless / .lossy(quality:)│
│                         / .distance(_:)), effort 1–9,        │
│                         progressive, numThreads              │
│   • JXLEncoder.swift    single + multi-frame encode          │
│   • JXLDecoder.swift    single (.decode) + multi-frame       │
│                         (.decodeAll) decode                  │
│   • DICOMReader.swift   Implicit/Explicit VR LE + Explicit   │
│                         VR BE; signed-pixel bias; Modality   │
│                         LUT; series/instance metadata         │
└──────────────────────────────────────────────────────────────┘
                       depends on
                         ▼
┌──────────────────────────────────────────────────────────────┐
│ Sources/Cjxl/           — SwiftPM systemLibrary              │
│   • module.modulemap    re-exports libjxl C API              │
│   • shim.h              umbrella include of <jxl/*.h>        │
└──────────────────────────────────────────────────────────────┘
                       depends on
                         ▼
                  Homebrew libjxl 0.11.x
                  (libjxl.dylib + libjxl_threads.dylib)
                  + pkg-config for include / link paths
```

## Why the layering

**`Cjxl` exists** so the C API is locatable without hand-rolled `-I` / `-L` flags scattered across `Package.swift`. SwiftPM's `pkgConfig: "libjxl"` declaration drives header and library discovery via the Homebrew-installed `.pc` files. If a user moves to a different libjxl install (e.g., system-wide on Linux), they only need a working `pkg-config` setup.

**`JXLSwift` is the only place that touches C interop.** `JXLEncoder.swift` and `JXLDecoder.swift` are the only files that import `Cjxl`. Everything else is pure Swift. This keeps the unsafe-pointer surface narrow and the rest of the codebase Sendable-friendly.

**`JXLTool` is a thin CLI shell.** Subcommands compose the public API; they don't reach around it. Anyone can build the same CLI by importing `JXLSwift` from their own project.

## Encoder lifecycle

`JXLEncoder.encode(_:)` is per-call. We don't pool `JxlEncoder` objects across calls; each invocation:

1. `JxlEncoderCreate(nil)` — returns a fresh encoder
2. `JxlThreadParallelRunnerCreate` — fresh thread pool
3. `JxlEncoderSetParallelRunner` — wire them up
4. `JxlEncoderSetBasicInfo`, `JxlEncoderSetColorEncoding`, `JxlEncoderFrameSettingsCreate`, `JxlEncoderSetFrameLossless` / `SetFrameDistance`, `JxlEncoderFrameSettingsSetOption`
5. `JxlEncoderAddImageFrame` (once per frame for multi-frame)
6. `JxlEncoderCloseInput`
7. `JxlEncoderProcessOutput` drain loop
8. `JxlEncoderDestroy` + `JxlThreadParallelRunnerDestroy` (via `defer`)

Cost of the per-call setup is ~50 ms in our measurements. Across a 20-file batch with `--parallel 4` the cost is < 1 s of the 17 s wall, so we don't pool. Pooling is a future option (see "What we punted" below).

`JxlEncoderProcessOutput` is called in a loop with a 64 KB scratch buffer until it returns `JXL_ENC_SUCCESS`. The output `Data` accumulates; for 16-bit DX scans that's ~7 MB, well within memory budget.

## Decoder lifecycle

`JXLDecoder.decodeAll(_:)` runs libjxl's event-driven state machine:

```
JxlDecoderCreate
  ▼
JxlDecoderSubscribeEvents(BASIC_INFO | COLOR_ENCODING | FULL_IMAGE)
  ▼
JxlDecoderSetInput(bytes)  →  JxlDecoderCloseInput
  ▼
loop:
  status = JxlDecoderProcessInput(dec)
  switch status:
    BASIC_INFO              → record dimensions, bit depth, channel count
    COLOR_ENCODING          → grab ICC profile if any
    NEED_IMAGE_OUT_BUFFER   → allocate `pendingPixels` and pass to libjxl
    FULL_IMAGE              → snapshot pendingPixels into a new ImageFrame,
                              append to `collected`. Continue looping —
                              more frames may follow for multi-frame inputs.
    SUCCESS                 → break
    ERROR / NEED_MORE_INPUT → throw DecoderError
```

`decode(_:)` is a thin wrapper that returns `collected.first`. This is back-compat with single-frame callers; multi-frame callers use `decodeAll`.

The decoder picks the natural pixel type from `JxlBasicInfo.bits_per_sample` and `exponent_bits_per_sample`: float32 if exponent bits > 0, uint16 if bits > 8, else uint8. Caller doesn't need to know in advance.

## Memory budget actor

`Sources/JXLTool/Batch.swift` defines `MemoryBudget` — an `actor` that gates concurrent encode-task dispatch:

```swift
actor MemoryBudget {
    private let total: Int
    private var used: Int = 0
    private var waiters: [(bytes: Int, cont: CheckedContinuation<Void, Never>)] = []

    func acquire(bytes: Int) async {
        if used + bytes <= total || used == 0 {
            used += bytes;  return
        }
        await withCheckedContinuation { cont in
            waiters.append((bytes, cont))
        }
        used += bytes
    }

    func release(bytes: Int) {
        used = max(0, used - bytes)
        while let head = waiters.first, used + head.bytes <= total || used == 0 {
            waiters.removeFirst();  head.cont.resume()
        }
    }
}
```

The `|| used == 0` guard prevents deadlock when a single task's request exceeds the total budget — admit one over-budget task rather than wedge the whole pipeline.

Per-file byte estimate = `file_size × --memory-overhead` (default 4×). For 16-bit DICOM where the file is mostly raw pixel bytes, this is a reasonable proxy for libjxl's working-set RSS. The actual peak per encode at high effort is ~3-5× the input pixel buffer — empirically validated.

## DICOM read path

`DICOMReader.parseWithMetadata(_:)` is a 280-line direct parser handling:

- Implicit VR Little Endian (`1.2.840.10008.1.2`)
- Explicit VR Little Endian (`1.2.840.10008.1.2.1`)
- Explicit VR Big Endian (`1.2.840.10008.1.2.2`)

Compressed transfer syntaxes (JPEG / JPEG-LS / JPEG 2000 / RLE) throw `DICOMError.unsupportedTransferSyntax`. The CLI's `loadDICOMViaMagick` wraps `magick` as a fallback, piping a 16-bit PGM into our PGM parser — works on every DICOM the magick install can decode, at the cost of an extra subprocess.

**Signed pixels.** When `(0028,0103) PixelRepresentation == 1`:

1. Sign-extend the `BitsStored`-bit value to `Int32` (handles cases where `BitsAllocated > BitsStored`, e.g. 12 stored in 16).
2. Add bias `2^(BitsStored - 1)` so the resulting value is unsigned in `[0, 2^BitsStored)`.
3. Clamp to `UInt16` (for 16-bit BitsAllocated).
4. Record bias in `DICOMMetadata.signedBias` so callers can recover original signed values.

**Modality LUT.** `(0028,1052) RescaleIntercept` and `(0028,1053) RescaleSlope` are read but **not applied** — applying would change pixel values and break the lossless contract. Surfaced via `DICOMMetadata.rescaleSlope` and `.rescaleIntercept` for downstream code that wants to render Hounsfield units correctly.

## What we punted

A few things were considered and explicitly deferred:

- **Encoder pooling**: re-using `JxlEncoder` instances across calls via `JxlEncoderReset` would save the per-call setup cost (~50 ms on this machine). On a typical batch run that's a small fraction of total wall time, not worth the API complexity right now.
- **Pipeline overlap (load while encode)**: Swift `TaskGroup` with `--parallel ≥ 2` already interleaves load/encode/write across in-flight tasks via the runtime scheduler. Explicit producer-consumer queues would only help when load is much faster than encode (rare on real DICOM).
- **NIfTI ingestion**: prototype was built and rolled back per request. Multi-frame remains in the codec — useful for any animation-style workflow.
- **Linux + iOS support**: pkg-config-driven libjxl works on Linux; on iOS we'd need to vendor libjxl statically. Not pursued in v0.4.

## Threading model

- One Swift `Task` per file in batch (capped by `--parallel`).
- One libjxl `JxlThreadParallelRunner` per encode call (defaults to `JxlThreadParallelRunnerDefaultNumWorkerThreads` = number of cores).
- The two compose: with `--parallel 4` and 8-core libjxl runners we'd see up to 32 active worker threads. This is fine on modern systems but is the reason peak RSS scales with `--parallel` (each runner has its own scratch state).
- `--threads N` on `jxl-tool batch` overrides the libjxl runner thread count. Setting `--threads 1` makes each encode single-threaded so `--parallel` provides all parallelism.

## Test surface

`Tests/JXLSwiftTests/IntegrationTests.swift` is the entire test suite — there are no unit tests for individual private helpers. The reasoning: the public API is small, every feature has an integration test that exercises real bytes through real codec, and synthetic cases (signed-pixel DICOM, malformed inputs, multi-frame) are constructed in-test so they don't depend on external corpus.

The 21 tests cover:

- **Round-trip** (lossless exact, lossy PSNR ≥ 35 dB)
- **Cross-codec** (libjxl decodes our output; we decode libjxl output)
- **Multi-frame** (uint8 + uint16 round-trip)
- **DICOM** (real-dataset reader + synthetic signed-pixel + Modality LUT extraction)
- **Hardening** (empty / random / truncated / mismatched-dim / garbage rejection; pixel-level idempotency)
- **Sanity** (JXL signature in encoded output; compression < raw size)

## Where to add new features

| Want to | Add to |
|---|---|
| Support a new CLI option | corresponding `Sources/JXLTool/{Encode,Decode,Batch}.swift` |
| Add a new ingestible format | reader in `Sources/JXLSwift/`, autodetect in `Encode.swift` `switch ext` |
| Expose a new libjxl knob | property in `EncodingOptions`, wire in `JXLEncoder.encodeRaw` |
| Add a non-libjxl codec backend | new module under `Sources/`; the public API can stay |

Don't touch `Sources/Cjxl/` unless you're upgrading libjxl or supporting a new platform.
