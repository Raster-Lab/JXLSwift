# DICOM Integration Guide

> **JXLSwift is a DICOM-independent library.**  
> It provides no DICOM parsing, no DICOM tag handling, and no DICOM file I/O.  
> The consumer application is responsible for all DICOM-specific concerns (e.g.
> reading `.dcm` files, extracting pixel data, mapping metadata to JXLSwift types).  
> This guide shows how to bridge between a DICOM toolkit (e.g. [DICOMKit](https://github.com/tobiasmadsen/dicomkit)) and JXLSwift.

---

## Contents

1. [Overview](#overview)
2. [Supported Pixel Formats](#supported-pixel-formats)
3. [Photometric Interpretation](#photometric-interpretation)
4. [Window / Level Metadata Passthrough](#window--level-metadata-passthrough)
5. [Lossless Encoding (Bit-Perfect)](#lossless-encoding-bit-perfect)
6. [Lossy Encoding with Quality Metrics](#lossy-encoding-with-quality-metrics)
7. [Multi-Frame Series (CT / MR Stacks)](#multi-frame-series-ct--mr-stacks)
8. [Large Image Support](#large-image-support)
9. [Convenience Initialisers](#convenience-initialisers)
10. [Platform Requirements](#platform-requirements)

---

## Overview

JPEG XL (ISO/IEC 18181) is well suited to medical imaging because it supports:

- Bit-perfect lossless compression for diagnostic-quality images.
- Extended bit depths: 8-bit, 12-bit, 16-bit unsigned, 16-bit signed (Hounsfield units),
  and 32-bit floating-point.
- Single-channel (grayscale) images — the dominant format in radiology.
- Efficient multi-frame encoding for CT/MR slice stacks.
- Compact lossy encoding for preview thumbnails (PSNR ≥ 45 dB at quality 95).

JXLSwift exposes these capabilities through a general-purpose API with no
DICOM knowledge baked in.

---

## Supported Pixel Formats

| DICOM Pixel Data Attribute | JXLSwift `PixelType` | `bitsPerSample` | Notes |
|---------------------------|----------------------|-----------------|-------|
| Unsigned 8-bit (`OB`, BitsStored=8) | `.uint8` | `8` | Standard 8-bit grayscale |
| Unsigned 12-bit (`OW`, BitsStored=12) | `.uint16` | `12` | 12-bit value in 16-bit storage |
| Unsigned 16-bit (`OW`, BitsStored=16) | `.uint16` | `16` | Standard 16-bit grayscale |
| Signed 16-bit (`SS`, BitsStored=16) | `.int16` | `16` | CT Hounsfield units |
| Float 32-bit (`OF`) | `.float32` | `32` | Dose maps, parametric images |
| Unsigned 32-bit (`OL`) | `.uint16` | `16` | Downscale to 16-bit before encoding |

### Creating a frame for each format

```swift
import JXLSwift

// 12-bit unsigned (CR, DX, MG)
let frame12 = ImageFrame.medical12bit(width: 2048, height: 2048)

// 16-bit unsigned (MR, NM, PT)
let frame16u = ImageFrame.medical16bit(width: 512, height: 512)

// 16-bit signed CT (Hounsfield units, typical range −1024 to +3071)
let frameCT = ImageFrame.medicalSigned16bit(
    width: 512, height: 512,
    rescaleIntercept: -1024.0,
    rescaleSlope: 1.0
)

// 32-bit float dose map
let frameDose = ImageFrame(
    width: 128, height: 128,
    channels: 1,
    pixelType: .float32,
    colorSpace: .grayscale,
    bitsPerSample: 32
)
```

---

## Photometric Interpretation

DICOM encodes how pixel values map to visual brightness via the
*Photometric Interpretation* attribute (0028,0004).  JXLSwift carries this
information as passthrough metadata:

| DICOM Value | JXLSwift enum case |
|-------------|-------------------|
| `MONOCHROME2` | `.monochrome2` *(default)* |
| `MONOCHROME1` | `.monochrome1` |
| `RGB` | `.rgb` |
| `YBR_FULL` / `YBR_FULL_422` | `.yCbCr` |

```swift
let meta = MedicalImageMetadata(
    photometricInterpretation: .monochrome1  // X-Ray (inverted)
)
let frame = ImageFrame(
    width: 2048, height: 2048,
    channels: 1,
    pixelType: .uint16,
    colorSpace: .grayscale,
    bitsPerSample: 16,
    medicalMetadata: meta
)
```

The codec does **not** invert or otherwise transform pixels based on this
value; interpretation is left to the rendering application.

---

## Window / Level Metadata Passthrough

Window centre (level) and window width control the display contrast of
medical images.  These are stored as passthrough metadata and have no effect
on encoding or decoding:

```swift
let meta = MedicalImageMetadata(
    photometricInterpretation: .monochrome2,
    windowLevels: [
        WindowLevel(centre: 40,   width: 400,  label: "Soft Tissue"),
        WindowLevel(centre: -600, width: 1500, label: "Lung"),
        WindowLevel(centre: 300,  width: 1500, label: "Bone"),
    ],
    rescaleIntercept: -1024.0,
    rescaleSlope: 1.0
)
```

Built-in window presets are also available:

```swift
let presets: [WindowLevel] = [.softTissue, .lung, .bone, .brain]
```

### Application-Specific Data

Arbitrary binary metadata (e.g. serialised DICOM tags, FHIR JSON) can be
stored in `applicationData` and will be preserved in the `ImageFrame`
object:

```swift
let dicomJson = Data("""
  {"PatientName": "Doe^John", "StudyDate": "20250201"}
""".utf8)

let meta = MedicalImageMetadata(applicationData: dicomJson)
```

> **Note:** `applicationData` is stored on the `ImageFrame` Swift object.
> It is not currently serialised into the JPEG XL bitstream; if round-trip
> persistence is required, store the metadata alongside the `.jxl` file.

---

## Lossless Encoding (Bit-Perfect)

Lossless encoding guarantees that decoded pixel values are identical to
the originals — a critical requirement for diagnostic images.

```swift
import JXLSwift

// Build a 16-bit CT frame from DICOM pixel data
var frame = ImageFrame.medicalSigned16bit(width: 512, height: 512)

// Populate from your DICOM toolkit's pixel buffer
let dicomPixels: [Int16] = /* ... your CT pixels ... */ []
for (i, hounsfield) in dicomPixels.enumerated() {
    let x = i % 512, y = i / 512
    frame.setPixelSigned(x: x, y: y, channel: 0, value: hounsfield)
}

// Encode losslessly
let encoder = JXLEncoder(options: .medicalLossless)
let result = try encoder.encode(frame)
print("Compressed \(result.stats.originalSize) → \(result.stats.compressedSize) bytes")

// Decode and verify
let decoder = JXLDecoder()
let decoded = try decoder.decode(result.data)

// Confirm every Hounsfield value is preserved exactly
for (i, original) in dicomPixels.enumerated() {
    let x = i % 512, y = i / 512
    let restored = decoded.getPixelSigned(x: x, y: y, channel: 0)
    assert(restored == original, "Lossless round-trip failed at pixel \(i)")
}
```

---

## Lossy Encoding with Quality Metrics

For preview thumbnails or non-diagnostic images, lossy encoding can
significantly reduce file size.  Medical applications typically require
PSNR ≥ 45 dB; `quality: 95` consistently achieves this.

```swift
let encoder = JXLEncoder(options: EncodingOptions(mode: .lossy(quality: 95)))
let result = try encoder.encode(frame)

let decoder = JXLDecoder()
let decoded = try decoder.decode(result.data)

let psnr = QualityMetrics.psnr(original: frame, reconstructed: decoded)
print("PSNR: \(psnr) dB")  // Expected: ≥ 45 dB
```

---

## Multi-Frame Series (CT / MR Stacks)

A CT or MR acquisition produces a series of consistently-sized slices.
Use `MedicalImageSeries` to validate the series and obtain the correct
animation configuration:

```swift
// Build 100 CT slices
var frames: [ImageFrame] = (0..<100).map { sliceIndex in
    var frame = ImageFrame.medicalSigned16bit(width: 512, height: 512)
    // ... fill from DICOM pixel data for this slice ...
    return frame
}

// Validate and wrap
let series = try MedicalImageSeries(frames: frames, description: "CT Abdomen")

// Encode as a multi-frame JXL
var opts = EncodingOptions.medicalLossless
opts.animationConfig = series.animationConfig  // fps=1, infinite loop

let encoder = JXLEncoder(options: opts)
let result = try encoder.encode(series.frames)
```

### Decoding a multi-frame series

```swift
let decoder = JXLDecoder()
// The decoder returns a single representative frame from the bitstream.
// Full animation decoding is available via the progressive/animation decode API.
let firstSlice = try decoder.decode(result.data)
```

---

## Large Image Support

JXLSwift validates large medical images before encoding:

```swift
// 4096×4096 16-bit (digital pathology, whole-slide)
let frame = ImageFrame.medical16bit(width: 4096, height: 4096)
try MedicalImageValidator.validate(frame)  // throws if > 16384×16384

let encoder = JXLEncoder(options: .medicalLossless)
let result = try encoder.encode(frame)
```

The maximum supported dimension is **16 384 pixels** on any side.  Total
pixel count must not exceed **16 384 × 16 384 = 268 435 456 pixels**.

---

## Convenience Initialisers

| Initialiser | Storage | bitsPerSample | Typical use |
|-------------|---------|---------------|-------------|
| `ImageFrame.medical12bit(width:height:)` | `uint16` | 12 | CR, DX, MG |
| `ImageFrame.medical16bit(width:height:)` | `uint16` | 16 | MR, NM, PT |
| `ImageFrame.medicalSigned16bit(width:height:)` | `int16` | 16 | CT (Hounsfield) |

All convenience initialisers default to:
- 1 channel (grayscale)
- `ColorSpace.grayscale`
- `PhotometricInterpretation.monochrome2`

---

## Platform Requirements

| Platform | Minimum Version |
|----------|----------------|
| macOS | 13.0+ |
| iOS | 16.0+ |
| tvOS | 16.0+ |
| watchOS | 9.0+ |
| visionOS | 1.0+ |
| Swift | 6.2+ |

No third-party dependencies are required.  The library works without any
DICOM toolkit — or alongside any DICOM toolkit of your choice.
