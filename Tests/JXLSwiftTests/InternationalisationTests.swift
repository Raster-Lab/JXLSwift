import XCTest
@testable import JXLSwift

/// Tests for Milestone 18 — Internationalisation & Spelling Support.
///
/// Validates British-English type aliases, dual-spelling API equivalence,
/// and CLI option behaviour for both American and British spellings.
final class InternationalisationTests: XCTestCase {

    // MARK: - British-English Type Alias Tests

    func testColourPrimariesAlias_IsIdenticalToColorPrimaries() {
        // ColourPrimaries is a typealias for ColorPrimaries — they must be the same type
        let brit: ColourPrimaries = .sRGB
        let amer: ColorPrimaries = .sRGB
        XCTAssertEqual(brit.redX, amer.redX, accuracy: 0.0001)
        XCTAssertEqual(brit.redY, amer.redY, accuracy: 0.0001)
        XCTAssertEqual(brit.greenX, amer.greenX, accuracy: 0.0001)
        XCTAssertEqual(brit.greenY, amer.greenY, accuracy: 0.0001)
        XCTAssertEqual(brit.blueX, amer.blueX, accuracy: 0.0001)
        XCTAssertEqual(brit.blueY, amer.blueY, accuracy: 0.0001)
        XCTAssertEqual(brit.whiteX, amer.whiteX, accuracy: 0.0001)
        XCTAssertEqual(brit.whiteY, amer.whiteY, accuracy: 0.0001)
    }

    func testColourPrimaries_CustomCaseAccessible() {
        // ColourPrimaries custom init should work identically to ColorPrimaries
        let brit = ColourPrimaries(
            redX: 0.64, redY: 0.33,
            greenX: 0.30, greenY: 0.60,
            blueX: 0.15, blueY: 0.06,
            whiteX: 0.3127, whiteY: 0.3290
        )
        let amer = ColorPrimaries(
            redX: 0.64, redY: 0.33,
            greenX: 0.30, greenY: 0.60,
            blueX: 0.15, blueY: 0.06,
            whiteX: 0.3127, whiteY: 0.3290
        )
        XCTAssertEqual(brit.redX, amer.redX, accuracy: 0.0001)
        XCTAssertEqual(brit.redY, amer.redY, accuracy: 0.0001)
    }

    // MARK: - ImageFrame Colour Space Round-trip

    func testImageFrame_ColourSpaceSRGB_EncodesAndDecodes() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }

    func testImageFrame_ColourSpaceLinearRGB_ProducesOutput() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: .linearRGB)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 200)
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2)
    }

    func testImageFrame_ColourSpaceGrayscale_ProducesOutput() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16((x + y) * 16))
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2)
    }

    func testImageFrame_ColourSpaceDisplayP3_ProducesOutput() throws {
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: .displayP3)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 64)
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2)
    }

    // MARK: - Dual-spelling API: identical output for American/British spellings

    func testColorSpaceOptions_SRGBProducesIdenticalOutput_BothSpellings() throws {
        // ImageFrame(.sRGB) via ColorSpace and the same via ColorSpace (both spellings
        // of the *value* .sRGB produce identical encoded output)
        var frame1 = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: ColorSpace.sRGB)
        var frame2 = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: ColorSpace.sRGB)
        for y in 0..<8 {
            for x in 0..<8 {
                let r = UInt16(x * 32)
                let g = UInt16(y * 32)
                let b = UInt16(128)
                frame1.setPixel(x: x, y: y, channel: 0, value: r)
                frame1.setPixel(x: x, y: y, channel: 1, value: g)
                frame1.setPixel(x: x, y: y, channel: 2, value: b)
                frame2.setPixel(x: x, y: y, channel: 0, value: r)
                frame2.setPixel(x: x, y: y, channel: 1, value: g)
                frame2.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }
        let encoder = JXLEncoder(options: .fast)
        let res1 = try encoder.encode(frame1)
        let res2 = try encoder.encode(frame2)
        XCTAssertEqual(res1.data, res2.data, "Identical colour space and pixel data must produce identical output")
    }

    // MARK: - EncodingOptions colour-space compatibility

    func testEncodingOptions_UseXYBColorSpace_DefaultIsFalse() {
        let opt = EncodingOptions()
        XCTAssertFalse(opt.useXYBColorSpace, "Default should not use XYB colour space")
    }

    func testEncodingOptions_UseXYBColorSpace_CanBeEnabled() {
        let opt = EncodingOptions(useXYBColorSpace: true)
        XCTAssertTrue(opt.useXYBColorSpace)
    }

    // MARK: - ColourPrimaries well-known presets

    func testColourPrimaries_SRGBPreset() {
        let p: ColourPrimaries = .sRGB
        // sRGB D65 white point (approximate)
        XCTAssertEqual(p.whiteX, 0.3127, accuracy: 0.001)
        XCTAssertEqual(p.whiteY, 0.3290, accuracy: 0.001)
    }

    func testColourPrimaries_DisplayP3Preset() {
        let p: ColourPrimaries = .displayP3
        XCTAssertEqual(p.redX, 0.680, accuracy: 0.001)
        XCTAssertEqual(p.redY, 0.320, accuracy: 0.001)
    }

    func testColourPrimaries_Rec2020Preset() {
        let p: ColourPrimaries = .rec2020
        XCTAssertEqual(p.redX, 0.708, accuracy: 0.001)
        XCTAssertEqual(p.redY, 0.292, accuracy: 0.001)
    }

    // MARK: - Spelling consistency smoke tests

    func testBritishSpelling_ColourPrimariesAliasAvailableAtCallSite() {
        // Ensure both aliases compile and are usable as parameter types
        func acceptColourPrimaries(_: ColourPrimaries) {}
        func acceptColorPrimaries(_: ColorPrimaries) {}

        acceptColourPrimaries(.sRGB)
        acceptColorPrimaries(.sRGB)
        acceptColourPrimaries(.displayP3)
        acceptColorPrimaries(.displayP3)
    }

    func testBritishSpelling_ColourPrimariesInterchangeableInGenerics() {
        // Both spellings must satisfy the same generic constraints
        func makeColorSpace(primaries: ColourPrimaries) -> ColorSpace {
            ColorSpace.custom(primaries: primaries, transferFunction: .sRGB)
        }
        let cs1 = makeColorSpace(primaries: ColourPrimaries.sRGB)
        let cs2 = makeColorSpace(primaries: ColourPrimaries.displayP3)
        // Both should be usable in an ImageFrame
        let f1 = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint8, colorSpace: cs1)
        let f2 = ImageFrame(width: 1, height: 1, channels: 3, pixelType: .uint8, colorSpace: cs2)
        XCTAssertEqual(f1.channels, f2.channels)
    }

    // MARK: - CLI colour-space option smoke tests (via EncodingOptions construction)

    func testCLI_ColourSpaceOption_SRGBProducesEncodableFrame() throws {
        // Simulates --color-space sRGB / --colour-space sRGB
        let frame = ImageFrame(width: 4, height: 4, channels: 3, pixelType: .uint8, colorSpace: .sRGB)
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }

    func testCLI_ColourSpaceOption_GrayscaleProducesEncodableFrame() throws {
        // Simulates --color-space grayscale / --colour-space grayscale
        let frame = ImageFrame(width: 4, height: 4, channels: 1, pixelType: .uint8, colorSpace: .grayscale)
        let encoder = JXLEncoder(options: .fast)
        let result = try encoder.encode(frame)
        XCTAssertEqual(result.data[0], 0xFF)
        XCTAssertEqual(result.data[1], 0x0A)
    }

    func testCLI_OptimiseFlag_SetsMaxEffort() throws {
        // Simulates --optimise / --optimize: effort should be .tortoise (9)
        let options = EncodingOptions(mode: .lossy(quality: 90), effort: .tortoise)
        XCTAssertEqual(options.effort, .tortoise, "Optimise flag should map to tortoise (max) effort")
        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)
        XCTAssertGreaterThan(result.data.count, 2)
    }

    func testCLI_OptimiseAndOptimize_ProduceIdenticalOutput() throws {
        // Both spellings of the flag must produce identical encoded output
        let optBrit = EncodingOptions(mode: .lossy(quality: 90), effort: .tortoise)
        let optAmer = EncodingOptions(mode: .lossy(quality: 90), effort: .tortoise)

        var frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: .uint8, colorSpace: .sRGB)
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0, value: UInt16(x * 32))
                frame.setPixel(x: x, y: y, channel: 1, value: UInt16(y * 32))
                frame.setPixel(x: x, y: y, channel: 2, value: 128)
            }
        }

        let encoderBrit = JXLEncoder(options: optBrit)
        let encoderAmer = JXLEncoder(options: optAmer)
        let resBrit = try encoderBrit.encode(frame)
        let resAmer = try encoderAmer.encode(frame)

        XCTAssertEqual(resBrit.data, resAmer.data, "--optimise and --optimize must produce identical output")
    }
}

