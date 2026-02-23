# Examples

This directory contains example code demonstrating various features of JXLSwift.
All examples are standalone Swift scripts that import `JXLSwift` and can be
copied directly into your own project.

## Running an Example

Because the examples are standalone scripts (not SPM executable targets), run
them with `swift` from the repo root after building the library:

```bash
swift build
swift /path/to/Examples/BasicEncoding.swift
```

Or simply read them as reference implementations — every function in each file
is self-contained and can be pasted directly into an Xcode project or Swift
package.

---

## Available Examples

### BasicEncoding.swift
Default-settings lossy encoding of a 512×512 RGB image.
Shows the minimal API surface: create `ImageFrame`, call `JXLEncoder.encode(_:)`,
inspect `CompressionStats`.

### LosslessEncoding.swift
Bit-perfect lossless compression using Modular mode (`EncodingOptions.lossless`).
Includes a full round-trip decode verification that asserts zero pixel mismatches.

### LossyEncoding.swift
Lossy VarDCT encoding across multiple quality levels (50, 75, 90, 95).
Compares compressed size and ratio at each quality setting, and demonstrates the
`highQuality` convenience preset and ANS entropy coding.

### DecodingExample.swift
Decodes a JPEG XL codestream back to an `ImageFrame`.
Covers container extraction (`extractCodestream`), image header parsing
(`parseImageHeader`), pixel access, and progressive decoding with a per-pass
callback.

### AnimationExample.swift
Multi-frame animation with configurable frame rate and loop control.
Also shows reference frame delta-encoding combined with patch copying for
screen-content animations.

### AlphaChannelExample.swift
RGBA encoding in both straight and premultiplied alpha modes.
Verifies that lossless round-trip preserves exact alpha values.

### ExtraChannelsExample.swift
Encodes depth maps, thermal data, and application-specific channels alongside
the main colour image using `ExtraChannelInfo`.

### HDRExample.swift
High Dynamic Range and wide-gamut encoding:
- **HDR10** — Rec. 2020 primaries + PQ (SMPTE ST 2084) transfer, float32 pixels
- **HLG** — Rec. 2020 primaries + HLG transfer, SDR-compatible
- **Display P3** — Wide gamut with sRGB transfer, common on Apple devices

### ROIExample.swift
Region-of-Interest (ROI) encoding for selective quality control.
Defines a 64×64 high-quality centre region with a feathered transition.

### PatchEncodingExample.swift
Patch encoding for screen recordings and slideshows.
Compares file size with and without `PatchConfig.screenContent` on an 8-frame
animation with a large static background.

### NoiseSynthesisExample.swift
Film-grain / synthetic noise synthesis via `NoiseConfig`.
Shows amplitude, luma-strength, and chroma-strength configuration.

### SplineEncodingExample.swift
Vector spline encoding for line art and sharp edges via `SplineConfig` and
`SplineDetector`.

### HardwareDetectionExample.swift
Runtime detection of CPU architecture and all hardware capabilities
(`HardwareCapabilities.detect()`), and building optimal `EncodingOptions` for
the current machine.

### DICOMWorkflowExample.swift
DICOM-compatible medical imaging workflow:
- 16-bit signed CT image (Hounsfield units) via `ImageFrame.medicalSigned16bit`
- `MedicalImageValidator` for dimension / bit-depth checks
- `EncodingOptions.medicalLossless` preset for diagnostic-quality lossless encoding
- Multi-slice CT series encoding via `MedicalImageSeries`

### BatchProcessingExample.swift
Batch-encodes a catalogue of synthetic images, collecting per-image and aggregate
statistics (bytes saved, overall ratio, throughput in images per second).

### BenchmarkingExample.swift
Two benchmarks in one file:
- **Effort sweep** — encodes the same image at five effort levels and measures
  compressed size vs. encoding time.
- **Quality metrics** — decodes each compressed image and computes PSNR and SSIM
  via `QualityMetrics.compare(original:reconstructed:)`.

---

## Command Line Tool (jxl-tool)

For CLI usage examples see the man pages and the built-in help:

```bash
swift run jxl-tool --help
swift run jxl-tool encode --help
swift run jxl-tool decode --help
swift run jxl-tool benchmark --help
```
