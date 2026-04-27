# J2KSwift ↔ JXLSwift API Migration Guide

This guide helps developers who are familiar with **J2KSwift** (Raster-Lab's JPEG 2000
codec) adopt **JXLSwift** (Raster-Lab's JPEG XL codec), and vice versa.

Both libraries share a common set of protocols defined in the `RasterImageEncoder`,
`RasterImageDecoder`, and `RasterImageCodec` umbrella types so that switching codecs
requires only minimal changes to calling code.

---

## Shared Protocol API

Both libraries adopt the same Raster-Lab codec protocols:

| Protocol | Description |
|---|---|
| `RasterImageEncoder` | Encode `ImageFrame` values to compressed bytes |
| `RasterImageDecoder` | Decode compressed bytes to `ImageFrame` values |
| `RasterImageCodec` | Typealias combining both protocols |

### Encoding via `RasterImageEncoder`

```swift
// Works with JXLEncoder and J2KEncoder alike
let encoder: any RasterImageEncoder = JXLEncoder()

let data: Data = try encoder.encode(frame: myFrame)
let animationData: Data = try encoder.encode(frames: [frame1, frame2])
```

### Decoding via `RasterImageDecoder`

```swift
// Works with JXLDecoder and J2KDecoder alike
let decoder: any RasterImageDecoder = JXLDecoder()

let frame: ImageFrame = try decoder.decode(data: compressedBytes)
```

---

## JXLSwift vs J2KSwift Naming Map

| Concept | JXLSwift | J2KSwift (expected) |
|---|---|---|
| Main encoder class | `JXLEncoder` | `J2KEncoder` |
| Main decoder class | `JXLDecoder` | `J2KDecoder` |
| Encoding options | `EncodingOptions` | `EncodingOptions` |
| Compression mode | `CompressionMode` | `CompressionMode` |
| Encoding effort | `EncodingEffort` | `EncodingEffort` |
| Image frame | `ImageFrame` | `ImageFrame` |
| Encoder errors | `EncoderError` | `EncoderError` |
| Decoder errors | `DecoderError` | `DecoderError` |
| Compression stats | `CompressionStats` | `CompressionStats` |
| Encoded result | `EncodedImage` | `EncodedImage` |
| Pixel type | `PixelType` | `PixelType` |
| Colour space | `ColorSpace` | `ColorSpace` |
| Shared encoder protocol | `RasterImageEncoder` | `RasterImageEncoder` |
| Shared decoder protocol | `RasterImageDecoder` | `RasterImageDecoder` |

---

## Switching from J2KSwift to JXLSwift

### Step 1 — Change the import

```swift
// Before
import J2KSwift

// After
import JXLSwift
```

### Step 2 — Change the encoder / decoder type

```swift
// Before (JPEG 2000)
let encoder = J2KEncoder(options: EncodingOptions(mode: .lossless))
let decoder = J2KDecoder()

// After (JPEG XL)
let encoder = JXLEncoder(options: EncodingOptions(mode: .lossless))
let decoder = JXLDecoder()
```

If your code stores the encoder/decoder as the shared protocol type, **no
change is needed** for the encoding/decoding calls:

```swift
// Protocol-based code — unchanged across both codecs
let encoder: any RasterImageEncoder = JXLEncoder() // was J2KEncoder()
let data = try encoder.encode(frame: myFrame)
```

### Step 3 — File extension

JPEG XL files use the `.jxl` extension. Update any file-writing logic
that previously used `.j2k` or `.jp2`.

---

## Switching from JXLSwift to J2KSwift

Follow the same steps in reverse — swap `JXLEncoder`/`JXLDecoder` for
`J2KEncoder`/`J2KDecoder` and update the import.

---

## Codec-Specific Features

Some features are unique to one codec. Use conditional code or the
codec-specific API when needed.

### JXLSwift-only features

- Progressive encoding/decoding (`JXLEncoder.encode` with
  `progressiveEncoding` in `EncodingOptions`)
- Responsive (quality-layered) encoding (`ResponsiveConfig`)
- XYB colour space encoding (`useXYBColorSpace`)
- ANS entropy coding (`ANSEncoder`)
- Metal GPU acceleration (`MetalOps`)
- Vulkan GPU compute (`VulkanOps`)
- DICOM-aware medical imaging metadata (`MedicalImageMetadata`)

### J2KSwift-only features

- JPEG 2000 tile-based encoding
- Packet-order encoding
- DWT wavelet transform options

---

## Concrete vs Protocol API

The shared `RasterImageEncoder` and `RasterImageDecoder` protocols return
`Data` (the raw compressed bytes) for maximum interoperability. The
concrete `JXLEncoder.encode(_:)` method returns an `EncodedImage` value
that additionally carries `CompressionStats`.

Choose the appropriate API for your use case:

```swift
// Protocol API — returns Data, works polymorphically
let data: Data = try encoder.encode(frame: frame)

// Concrete API — returns EncodedImage with stats
let result: EncodedImage = try (encoder as! JXLEncoder).encode(frame)
print("Ratio: \(result.stats.compressionRatio)×")
```

---

## Further Reading

- [JXLSwift README](../README.md)
- [JXLSwift API Documentation](./API_DOCUMENTATION.md)
- [JXLSwift MIGRATION Guide](./MIGRATION.md) — upgrading between JXLSwift versions
- [JXLSwift DICOM Integration](./DICOM_INTEGRATION.md)
