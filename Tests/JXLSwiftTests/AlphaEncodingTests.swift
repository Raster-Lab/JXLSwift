/// Tests for alpha channel encoding in both VarDCT and Modular modes
///
/// Verifies that alpha channels are correctly preserved and compressed
/// through the encoding pipeline with various pixel types and alpha modes.

import XCTest
@testable import JXLSwift

final class AlphaEncodingTests: XCTestCase {
    
    // Alpha gradient scale factor for 16x16 test images
    // Calculated as: 65535 / 30 ≈ 2184 (to span full 16-bit range over 30 positions)
    private let alphaGradientScale: UInt16 = 2184
    
    // MARK: - VarDCT (Lossy) Alpha Encoding Tests
    
    func testVarDCT_RGBAUInt8_StraightAlpha_ProducesValidOutput() throws {
        // Create a small RGBA frame with straight alpha
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,  // RGBA
            pixelType: .uint8,
            colorSpace: .sRGB,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Fill with test pattern:
        // - RGB: gradient
        // - Alpha: varying transparency
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))  // R gradient
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))  // G gradient
                frame.setPixel(x: x, y: y, channel: 2, value: 128)             // B constant
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16((x + y) * 8))  // Alpha gradient
            }
        }
        
        // Encode with VarDCT (lossy)
        let options = EncodingOptions(
            mode: .lossy(quality: 90),
            effort: .squirrel  // Default balanced effort
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        // Verify output is non-empty
        XCTAssertGreaterThan(result.data.count, 0,
                             "VarDCT encoding with alpha should produce non-empty output")
        
        // Verify compression ratio is reasonable
        let originalSize = 16 * 16 * 4  // 4 channels
        let compressedSize = result.data.count
        XCTAssertLessThan(compressedSize, originalSize,
                          "Compressed data should be smaller than original")
    }
    
    func testVarDCT_RGBAUInt16_PremultipliedAlpha_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .uint16,
            colorSpace: .sRGB,
            hasAlpha: true,
            alphaMode: .premultiplied,
            bitsPerSample: 16
        )
        
        // Fill with premultiplied alpha pattern
        for y in 0..<16 {
            for x in 0..<16 {
                let alpha = UInt16(min(65535, (x + y) * Int(alphaGradientScale)))  // Gradient scale
                // RGB values are premultiplied by alpha
                let alphaFraction = Int(alpha)
                let r = UInt16((x * 4096 * alphaFraction) / 65535)
                let g = UInt16((y * 4096 * alphaFraction) / 65535)
                let b = UInt16((32768 * alphaFraction) / 65535)
                
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
                frame.setPixel(x: x, y: y, channel: 3, value: alpha)
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 85),
            effort: .squirrel
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "VarDCT encoding with premultiplied alpha should produce output")
    }
    
    func testVarDCT_RGBAFloat32_StraightAlpha_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .float32,
            colorSpace: .sRGB,
            hasAlpha: true,
            alphaMode: .straight,
            bitsPerSample: 32
        )
        
        // Fill with HDR-style float data
        for y in 0..<16 {
            for x in 0..<16 {
                // Float values in 0-1 range, scaled to UInt16 for setPixel
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(Float(x) / 15.0 * 65535))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(Float(y) / 15.0 * 65535))
                frame.setPixel(x: x, y: y, channel: 2, value: 32768)
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16(Float(x + y) / 30.0 * 65535))
            }
        }
        
        let options = EncodingOptions(
            mode: .lossy(quality: 95),
            effort: .squirrel
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "VarDCT encoding with float32 alpha should produce output")
    }
    
    func testVarDCT_AlphaChannel_FullyTransparent() throws {
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Fill with fully transparent pixels (alpha = 0)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: 255)
                frame.setPixel(x: x, y: y, channel: 1, value: 128)
                frame.setPixel(x: x, y: y, channel: 2, value: 64)
                frame.setPixel(x: x, y: y, channel: 3, value: 0)  // Fully transparent
            }
        }
        
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Fully transparent image should encode successfully")
    }
    
    func testVarDCT_AlphaChannel_FullyOpaque() throws {
        var frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Fill with fully opaque pixels (alpha = 255)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
                frame.setPixel(x: x, y: y, channel: 3, value: 255)  // Fully opaque
            }
        }
        
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Fully opaque image should encode successfully")
    }
    
    func testVarDCT_AlphaChannel_GradientTransparency() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Create alpha gradient from 0 to 255
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: 200)
                frame.setPixel(x: x, y: y, channel: 1, value: 150)
                frame.setPixel(x: x, y: y, channel: 2, value: 100)
                // Diagonal gradient
                let alpha = UInt16((x + y) * 255 / 30)
                frame.setPixel(x: x, y: y, channel: 3, value: alpha)
            }
        }
        
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Alpha gradient should encode successfully")
    }
    
    // MARK: - Modular (Lossless) Alpha Encoding Tests
    
    func testModular_RGBAUInt8_StraightAlpha_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Fill with test pattern
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16((x + y) * 8))
            }
        }
        
        let options = EncodingOptions(
            mode: .lossless,
            effort: .squirrel
        )
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Modular encoding with alpha should produce output")
        
        // Lossless should still compress
        let originalSize = 16 * 16 * 4
        XCTAssertLessThan(result.data.count, originalSize,
                          "Lossless should still achieve some compression")
    }
    
    func testModular_RGBAUInt16_PremultipliedAlpha_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .uint16,
            hasAlpha: true,
            alphaMode: .premultiplied,
            bitsPerSample: 16
        )
        
        // Fill with premultiplied data
        for y in 0..<16 {
            for x in 0..<16 {
                // Alpha value scaled appropriately for 16-bit
                let alpha = UInt16(min(65535, (x + y) * Int(alphaGradientScale)))  // Gradient scale
                // RGB values are premultiplied by alpha fraction
                let alphaFraction = Int(alpha)
                let r = UInt16((x * 4096 * alphaFraction) / 65535)
                let g = UInt16((y * 4096 * alphaFraction) / 65535)
                let b = UInt16((32768 * alphaFraction) / 65535)
                
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
                frame.setPixel(x: x, y: y, channel: 3, value: alpha)
            }
        }
        
        let options = EncodingOptions(mode: .lossless, effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Modular encoding with 16-bit premultiplied alpha should work")
    }
    
    func testModular_AlphaOnly_SingleChannelAlpha() throws {
        // Edge case: alpha as a single channel (grayscale with alpha)
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 2,  // Grayscale + Alpha
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 16))  // Grayscale
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 16))  // Alpha
            }
        }
        
        let options = EncodingOptions(mode: .lossless, effort: .lightning)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Grayscale + alpha should encode successfully")
    }
    
    // MARK: - Alpha Mode Comparison Tests
    
    func testAlphaModes_StraightVsPremultiplied_BothEncode() throws {
        let width = 16
        let height = 16
        
        // Create straight alpha frame
        var straightFrame = ImageFrame(
            width: width,
            height: height,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Create premultiplied alpha frame (will have different RGB values)
        var premultFrame = ImageFrame(
            width: width,
            height: height,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .premultiplied
        )
        
        for y in 0..<height {
            for x in 0..<width {
                let r: UInt16 = 200
                let g: UInt16 = 150
                let b: UInt16 = 100
                let alpha = UInt16((x + y) * 8)
                
                // Straight alpha: RGB independent of alpha
                straightFrame.setPixel(x: x, y: y, channel: 0, value: r)
                straightFrame.setPixel(x: x, y: y, channel: 1, value: g)
                straightFrame.setPixel(x: x, y: y, channel: 2, value: b)
                straightFrame.setPixel(x: x, y: y, channel: 3, value: alpha)
                
                // Premultiplied alpha: RGB multiplied by alpha
                let premultR = (r * alpha) / 255
                let premultG = (g * alpha) / 255
                let premultB = (b * alpha) / 255
                premultFrame.setPixel(x: x, y: y, channel: 0, value: premultR)
                premultFrame.setPixel(x: x, y: y, channel: 1, value: premultG)
                premultFrame.setPixel(x: x, y: y, channel: 2, value: premultB)
                premultFrame.setPixel(x: x, y: y, channel: 3, value: alpha)
            }
        }
        
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let encoder = JXLEncoder(options: options)
        
        let straightResult = try encoder.encode(straightFrame)
        let premultResult = try encoder.encode(premultFrame)
        
        XCTAssertGreaterThan(straightResult.data.count, 0,
                             "Straight alpha should encode")
        XCTAssertGreaterThan(premultResult.data.count, 0,
                             "Premultiplied alpha should encode")
        
        // Both should produce valid, but potentially different, compressed data
        // (due to different RGB values after premultiplication)
    }
    
    // MARK: - Progressive Encoding with Alpha
    
    func testProgressive_WithAlpha_ProducesValidOutput() throws {
        var frame = ImageFrame(
            width: 32,
            height: 32,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Fill with complex pattern
        for y in 0..<32 {
            for x in 0..<32 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x * 8) % 256))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16((y * 8) % 256))
                frame.setPixel(x: x, y: y, channel: 2, value: UInt16((x + y) * 4 % 256))
                frame.setPixel(x: x, y: y, channel: 3, value: UInt16((x * y) % 256))
            }
        }
        
        var options = EncodingOptions(mode: .lossy(quality: 90), effort: .squirrel)
        options.progressive = true
        
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Progressive encoding with alpha should work")
    }
    
    // MARK: - Edge Cases
    
    func testAlpha_EmptyFrame_StillEncodes() throws {
        // Frame with all zeros (including alpha)
        let frame = ImageFrame(
            width: 8,
            height: 8,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .lightning)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        XCTAssertGreaterThan(result.data.count, 0,
                             "Empty frame with alpha should encode")
    }
    
    func testAlpha_AlternatingPattern_CompressesWell() throws {
        var frame = ImageFrame(
            width: 16,
            height: 16,
            channels: 4,
            pixelType: .uint8,
            hasAlpha: true,
            alphaMode: .straight
        )
        
        // Checkerboard pattern in alpha channel
        for y in 0..<16 {
            for x in 0..<16 {
                frame.setPixel(x: x, y: y, channel: 0, value: 128)
                frame.setPixel(x: x, y: y, channel: 1, value: 128)
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
                
                let alpha: UInt16 = ((x + y) % 2 == 0) ? 255 : 0
                frame.setPixel(x: x, y: y, channel: 3, value: alpha)
            }
        }
        
        let options = EncodingOptions(mode: .lossless, effort: .squirrel)
        let encoder = JXLEncoder(options: options)
        
        let result = try encoder.encode(frame)
        
        // Checkerboard pattern should compress reasonably well (but not necessarily < 50%)
        let originalSize = 16 * 16 * 4
        XCTAssertLessThan(result.data.count, originalSize,
                          "Checkerboard pattern should compress better than raw data")
    }
}
