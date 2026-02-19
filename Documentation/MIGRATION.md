# Migration Guide: libjxl to JXLSwift

This guide helps you migrate from libjxl (the reference C++ implementation) to JXLSwift, a native Swift implementation of JPEG XL.

## Overview

JXLSwift provides a pure Swift API for JPEG XL encoding and decoding with hardware acceleration for Apple platforms. While the underlying format is compatible, the API is designed for Swift idioms and safety.

## Key Differences

### Language & Platform
- **libjxl**: C++ library, multi-platform, requires native build
- **JXLSwift**: Pure Swift, Swift Package Manager, Apple platforms (macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+)

### API Philosophy
- **libjxl**: C-style API with manual memory management, error codes
- **JXLSwift**: Swift value types, automatic memory management, typed errors

### Hardware Acceleration
- **libjxl**: x86 SIMD (SSE, AVX2), ARM NEON via Highway library
- **JXLSwift**: Apple Accelerate (vDSP), ARM NEON, optional Metal GPU

## API Comparison

### Encoding

#### libjxl (C++)
```cpp
#include "jxl/encode.h"
#include "jxl/encode_cxx.h"

// Create encoder
auto enc = JxlEncoderMake(nullptr);

// Set options
JxlEncoderFrameSettings* frame_settings = JxlEncoderFrameSettingsCreate(enc.get(), nullptr);
JxlEncoderSetFrameDistance(frame_settings, 1.0);
JxlEncoderSetFrameLossless(frame_settings, false);

// Set basic info
JxlBasicInfo basic_info;
JxlEncoderInitBasicInfo(&basic_info);
basic_info.xsize = 1920;
basic_info.ysize = 1080;
basic_info.bits_per_sample = 8;
basic_info.num_color_channels = 3;
JxlEncoderSetBasicInfo(enc.get(), &basic_info);

// Set color encoding
JxlColorEncoding color_encoding;
JxlColorEncodingSetToSRGB(&color_encoding, false);
JxlEncoderSetColorEncoding(enc.get(), &color_encoding);

// Add image frame
JxlPixelFormat pixel_format = {3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0};
JxlEncoderAddImageFrame(frame_settings, &pixel_format, pixels.data(), pixels.size());

// Process output
JxlEncoderProcessOutput(enc.get(), &next_out, &avail_out);
```

#### JXLSwift (Swift)
```swift
import JXLSwift

// Create image frame
var frame = ImageFrame(
    width: 1920,
    height: 1080,
    channels: 3,
    pixelType: .uint8,
    colorSpace: .sRGB
)

// Fill with pixel data
for y in 0..<frame.height {
    for x in 0..<frame.width {
        frame.setPixel(x: x, y: y, channel: 0, value: r)
        frame.setPixel(x: x, y: y, channel: 1, value: g)
        frame.setPixel(x: x, y: y, channel: 2, value: b)
    }
}

// Encode with options
let encoder = JXLEncoder(options: .lossy(quality: 90))
let result = try encoder.encode(frame)

// Access compressed data
let compressedData = result.data
print("Compressed: \(result.stats.compressionRatio)x")
```

### Decoding

#### libjxl (C++)
```cpp
#include "jxl/decode.h"
#include "jxl/decode_cxx.h"

// Create decoder
auto dec = JxlDecoderMake(nullptr);

// Subscribe to events
JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE);

// Set input
JxlDecoderSetInput(dec.get(), jxl_data.data(), jxl_data.size());

// Process
JxlDecoderStatus status;
while ((status = JxlDecoderProcessInput(dec.get())) != JXL_DEC_SUCCESS) {
    if (status == JXL_DEC_BASIC_INFO) {
        JxlBasicInfo info;
        JxlDecoderGetBasicInfo(dec.get(), &info);
        // Process basic info
    } else if (status == JXL_DEC_NEED_IMAGE_OUT_BUFFER) {
        size_t buffer_size;
        JxlDecoderImageOutBufferSize(dec.get(), &pixel_format, &buffer_size);
        buffer.resize(buffer_size);
        JxlDecoderSetImageOutBuffer(dec.get(), &pixel_format, buffer.data(), buffer.size());
    } else if (status == JXL_DEC_FULL_IMAGE) {
        // Image ready in buffer
        break;
    }
}
```

#### JXLSwift (Swift)
```swift
import JXLSwift

// Decode from data
let decoder = JXLDecoder()
let frame = try decoder.decode(jxlData)

// Access decoded pixels
for y in 0..<frame.height {
    for x in 0..<frame.width {
        let r = frame.getPixel(x: x, y: y, channel: 0)
        let g = frame.getPixel(x: x, y: y, channel: 1)
        let b = frame.getPixel(x: x, y: y, channel: 2)
        // Use pixel values
    }
}

// Progressive decoding
try decoder.decodeProgressive(jxlData) { pass, intermediateFrame in
    print("Pass \(pass): \(intermediateFrame.width)×\(intermediateFrame.height)")
    // Update UI with intermediate result
    return true  // Continue to next pass
}
```

### Quality/Distance Settings

#### libjxl
- Distance: `0.0` (lossless) to `15.0` (very lossy)
- Lower distance = higher quality
- `JxlEncoderSetFrameDistance(frame_settings, 1.0)`

#### JXLSwift
- Quality: `0` (low) to `100` (highest)
- Higher quality = better result
- Lossless mode: `.lossless`
- Lossy mode: `.lossy(quality: 90)`

**Quality to Distance Mapping:**
```swift
// JXLSwift automatically maps quality to distance
let quality = 90  // → distance ≈ 1.0
let quality = 75  // → distance ≈ 2.5
let quality = 50  // → distance ≈ 5.0
let quality = 25  // → distance ≈ 10.0
```

### Effort Levels

#### libjxl
- Effort: `1` (fast) to `9` (slow, best compression)
- `JxlEncoderFrameSettingsSetOption(frame_settings, JXL_ENC_FRAME_SETTING_EFFORT, 7)`

#### JXLSwift
- Effort: `.fastest` (1), `.fast` (3), `.balanced` (5), `.high` (7), `.maximum` (9)
- Or use custom: `EncodingOptions(mode: .lossy(quality: 90), effort: .effort(7))`

### Error Handling

#### libjxl
```cpp
JxlEncoderStatus status = JxlEncoderProcessOutput(enc.get(), &next_out, &avail_out);
if (status == JXL_ENC_ERROR) {
    // Handle error
}
```

#### JXLSwift
```swift
do {
    let result = try encoder.encode(frame)
} catch EncoderError.invalidImageDimensions {
    print("Invalid image dimensions")
} catch EncoderError.unsupportedChannelCount(let count) {
    print("Unsupported channel count: \(count)")
} catch {
    print("Encoding failed: \(error.localizedDescription)")
}
```

## Feature Comparison

| Feature | libjxl | JXLSwift |
|---------|--------|----------|
| **Encoding** |
| Lossless (Modular) | ✅ | ✅ |
| Lossy (VarDCT) | ✅ | ✅ |
| Progressive encoding | ✅ | ✅ |
| Animation | ✅ | ✅ |
| Extra channels | ✅ | ✅ |
| Alpha channels | ✅ | ✅ |
| Wide gamut (P3, Rec.2020) | ✅ | ✅ |
| HDR (PQ, HLG) | ✅ | ✅ |
| **Decoding** |
| Full decode | ✅ | ✅ |
| Progressive decode | ✅ | ✅ |
| Animation | ✅ | ✅ (frames) |
| Metadata (EXIF, XMP, ICC) | ✅ | ✅ |
| **Container** |
| Naked codestream | ✅ | ✅ |
| ISOBMFF container | ✅ | ✅ |
| **Advanced Features** |
| Patches | ✅ | ✅ |
| Splines | ✅ | ✅ |
| Noise synthesis | ✅ | ✅ |
| Reference frames | ✅ | ✅ |
| Region-of-Interest | ✅ | ✅ |
| EXIF orientation | ✅ | ✅ |
| **Hardware Acceleration** |
| x86 SIMD (SSE, AVX2) | ✅ | ✅ (scalar fallback) |
| ARM NEON | ✅ | ✅ |
| Apple Accelerate | ❌ | ✅ |
| Metal GPU | ❌ | ✅ |

## Common Migration Patterns

### 1. Simple Lossless Encoding

**Before (libjxl):**
```cpp
auto enc = JxlEncoderMake(nullptr);
auto frame_settings = JxlEncoderFrameSettingsCreate(enc.get(), nullptr);
JxlEncoderSetFrameLossless(frame_settings, true);
// ... set basic info ...
JxlEncoderAddImageFrame(frame_settings, &pixel_format, pixels.data(), pixels.size());
```

**After (JXLSwift):**
```swift
let encoder = JXLEncoder(options: .lossless)
let result = try encoder.encode(frame)
```

### 2. High-Quality Lossy Encoding

**Before (libjxl):**
```cpp
JxlEncoderSetFrameDistance(frame_settings, 1.0);
JxlEncoderFrameSettingsSetOption(frame_settings, JXL_ENC_FRAME_SETTING_EFFORT, 7);
```

**After (JXLSwift):**
```swift
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    effort: .high
)
let encoder = JXLEncoder(options: options)
```

### 3. Decoding with Metadata

**Before (libjxl):**
```cpp
JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_BASIC_INFO | JXL_DEC_BOX);
// ... complex event loop ...
```

**After (JXLSwift):**
```swift
let decoder = JXLDecoder()
let metadata = try decoder.extractMetadata(jxlData)
if let exif = metadata.exif {
    print("EXIF data: \(exif.count) bytes")
}
if let icc = metadata.iccProfile {
    print("ICC profile: \(icc.count) bytes")
}
let frame = try decoder.decode(jxlData)
```

### 4. Progressive Decoding

**Before (libjxl):**
```cpp
JxlDecoderSubscribeEvents(dec.get(), JXL_DEC_FRAME_PROGRESSION);
// ... event loop with multiple progressive steps ...
```

**After (JXLSwift):**
```swift
try decoder.decodeProgressive(jxlData) { pass, frame in
    switch pass {
    case 0: print("DC coefficients ready")
    case 1: print("Low-frequency AC ready")
    case 2: print("Full quality ready")
    default: break
    }
    updateUI(with: frame)  // Update display
    return true  // Continue to next pass
}
```

## Command-Line Tool Comparison

### libjxl CLI

```bash
# Encode
cjxl input.png output.jxl --quality 90 --effort 7

# Decode
djxl input.jxl output.png

# Info
jxlinfo input.jxl
```

### JXLSwift CLI (jxl-tool)

```bash
# Encode
jxl-tool encode input.png -o output.jxl --quality 90 --effort 7

# Decode
jxl-tool decode input.jxl -o output.png --format png

# Info
jxl-tool info input.jxl
```

## Performance Considerations

### libjxl Strengths
- Mature, highly optimized C++ code
- Extensive platform support (Windows, Linux, macOS, Android, iOS)
- Multi-threaded encoding with granular control
- Well-tested on diverse hardware

### JXLSwift Strengths
- Native Swift integration, no FFI overhead
- Optimized for Apple Silicon (M1/M2/M3)
- Leverages Apple Accelerate framework
- Optional Metal GPU acceleration
- Swift concurrency integration
- Type-safe API

### Performance Expectations
- **Apple Silicon (M1/M2/M3)**: JXLSwift can match or exceed libjxl performance due to Accelerate and NEON optimizations
- **Intel x86-64**: JXLSwift provides scalar fallbacks; libjxl may be faster with AVX2
- **Linux/Android**: Use libjxl (JXLSwift is Apple-platform only)

## Compatibility

### Bitstream Compatibility
✅ **JXLSwift produces JPEG XL bitstreams that can be decoded by libjxl**  
✅ **JXLSwift can decode JPEG XL files produced by libjxl**

The formats are fully compatible at the bitstream level.

### Metadata Compatibility
✅ **EXIF, XMP, ICC profiles are preserved**  
✅ **ISOBMFF container format matches libjxl**

### Quality/Compression
⚠️ **Compression ratios may differ slightly** due to different encoder implementations  
⚠️ **Quality metrics (PSNR, SSIM) should be comparable but not identical**

## Limitations

### Current JXLSwift Limitations
- Apple platforms only (macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+)
- Swift 6.2 or later required
- Animation encoding/decoding supported, but multi-frame API is different from libjxl
- Some advanced libjxl features may have slightly different APIs

### When to Use libjxl
- Cross-platform support required (Windows, Linux, Android)
- Integration with existing C/C++ codebase
- Need for the most mature, battle-tested implementation
- Require specific libjxl features not yet in JXLSwift

### When to Use JXLSwift
- Building native Swift applications for Apple platforms
- Want type-safe, Swift-idiomatic API
- Need tight integration with SwiftUI, Combine, or Swift Concurrency
- Targeting Apple Silicon for optimal performance
- Prefer SPM dependency management

## Best Practices

### Memory Management
```swift
// JXLSwift uses automatic memory management
let encoder = JXLEncoder()
let result = try encoder.encode(frame)
// No manual cleanup needed
```

### Error Handling
```swift
// Use typed errors
do {
    let result = try encoder.encode(frame)
} catch EncoderError.invalidImageDimensions {
    // Handle specific error
} catch {
    // Handle general error
}
```

### Concurrency
```swift
// Use Swift concurrency
Task {
    let result = try await encoder.encode(frame)
    await updateUI(with: result)
}
```

### Hardware Acceleration
```swift
// Hardware acceleration is automatic
// But you can control it:
let options = EncodingOptions(
    mode: .lossy(quality: 90),
    useAccelerate: true,  // Use Accelerate framework
    useMetal: true        // Use Metal GPU if available
)
```

## Migration Checklist

- [ ] Review API differences (C++ → Swift)
- [ ] Update quality/distance settings (0-15 → 0-100)
- [ ] Adopt Swift error handling (`try`/`catch`)
- [ ] Use Swift value types (`ImageFrame`, `EncodingOptions`)
- [ ] Leverage Swift concurrency (`async`/`await`) if needed
- [ ] Test on target Apple platforms
- [ ] Validate bitstream compatibility with libjxl
- [ ] Benchmark performance on your workload
- [ ] Update build system (Makefile/CMake → Swift Package Manager)
- [ ] Update documentation for Swift API

## Support & Resources

- **JXLSwift Repository**: https://github.com/Raster-Lab/JXLSwift
- **JXLSwift Documentation**: [API Reference](#)
- **libjxl Repository**: https://github.com/libjxl/libjxl
- **JPEG XL Specification**: ISO/IEC 18181
- **Issue Tracker**: https://github.com/Raster-Lab/JXLSwift/issues

## Conclusion

JXLSwift provides a modern, Swift-native API for JPEG XL encoding and decoding on Apple platforms. While the underlying format is compatible with libjxl, the API is designed to feel natural in Swift codebases with type safety, automatic memory management, and seamless integration with Apple frameworks.

For cross-platform projects or existing C++ codebases, libjxl remains the reference implementation. For new Swift projects on Apple platforms, JXLSwift offers a clean, performant, and idiomatic solution.
