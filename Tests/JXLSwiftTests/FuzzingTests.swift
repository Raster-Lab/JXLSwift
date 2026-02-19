import XCTest
@testable import JXLSwift

/// Fuzzing tests for malformed input handling.
/// Tests that the decoder gracefully handles invalid, corrupted, and malformed JPEG XL data.
final class FuzzingTests: XCTestCase {
    
    // MARK: - Empty and Minimal Input Tests
    
    func testDecoder_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        let emptyData = Data()
        
        XCTAssertThrowsError(try decoder.decode(emptyData)) { error in
            // Should fail gracefully, not crash
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    func testDecoder_SingleByte_ThrowsError() {
        let decoder = JXLDecoder()
        let singleByte = Data([0xFF])
        
        XCTAssertThrowsError(try decoder.decode(singleByte)) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    func testDecoder_TwoBytes_ThrowsError() {
        let decoder = JXLDecoder()
        let twoBytes = Data([0xFF, 0x0A])  // Valid signature but incomplete
        
        XCTAssertThrowsError(try decoder.decode(twoBytes)) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    // MARK: - Invalid Signature Tests
    
    func testDecoder_InvalidSignature_ThrowsError() {
        let decoder = JXLDecoder()
        
        // Create data with invalid signature (must be >= 14 bytes for header parsing)
        var invalidData = Data([0xFF, 0xFF])  // Wrong signature
        invalidData.append(contentsOf: [0, 0, 1, 0])  // Dummy width
        invalidData.append(contentsOf: [0, 0, 1, 0])  // Dummy height
        invalidData.append(contentsOf: [8, 3, 0, 0])  // bps, channels, padding
        
        XCTAssertThrowsError(try decoder.decode(invalidData)) { error in
            if case DecoderError.invalidSignature = error {
                // Expected error
            } else {
                XCTFail("Expected invalidSignature error, got \(error)")
            }
        }
    }
    
    func testDecoder_CorruptedSignature_ThrowsError() {
        let decoder = JXLDecoder()
        let corruptedData = Data([0x00, 0x0A, 0, 0, 1, 0, 0, 0, 1, 0])
        
        XCTAssertThrowsError(try decoder.decode(corruptedData))
    }
    
    // MARK: - Truncated Header Tests
    
    func testDecoder_TruncatedHeader_ThrowsError() {
        let decoder = JXLDecoder()
        
        // Valid signature but truncated header
        var data = Data([0xFF, 0x0A])  // Valid signature
        data.append(contentsOf: [0, 0, 1])  // Incomplete width
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    func testDecoder_PartialHeader_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 1, 0])  // Width
        data.append(contentsOf: [0, 0])  // Incomplete height
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    // MARK: - Invalid Dimensions Tests
    
    func testDecoder_ZeroWidth_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0, 0])  // Width = 0
        data.append(contentsOf: [0, 0, 1, 0])  // Height = 256
        data.append(contentsOf: [8, 3, 0, 0])  // bps, channels, colorSpace, hasAlpha
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            if case DecoderError.invalidDimensions = error {
                // Expected
            } else {
                XCTFail("Expected invalidDimensions, got \(error)")
            }
        }
    }
    
    func testDecoder_ZeroHeight_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 1, 0])  // Width = 256
        data.append(contentsOf: [0, 0, 0, 0])  // Height = 0
        data.append(contentsOf: [8, 3, 0, 0])  // bps, channels, colorSpace, hasAlpha
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            if case DecoderError.invalidDimensions = error {
                // Expected
            } else {
                XCTFail("Expected invalidDimensions, got \(error)")
            }
        }
    }
    
    func testDecoder_ExcessiveDimensions_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Width = UInt32.max
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Height = UInt32.max
        data.append(contentsOf: [8, 3, 0, 0])
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            // Should fail due to memory allocation or dimension limits
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    // MARK: - Invalid Channel Count Tests
    
    func testDecoder_ZeroChannels_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0x10, 0])  // Width = 16
        data.append(contentsOf: [0, 0, 0x10, 0])  // Height = 16
        data.append(contentsOf: [8, 0, 0, 0])  // channels = 0
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            // Should fail with invalid header or unsupported encoding
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    func testDecoder_ExcessiveChannels_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0x10, 0])
        data.append(contentsOf: [0, 0, 0x10, 0])
        data.append(contentsOf: [8, 255, 0, 0])  // channels = 255
        
        XCTAssertThrowsError(try decoder.decode(data)) { error in
            // Should fail with invalid header or unsupported encoding
            XCTAssertTrue(error is DecoderError)
        }
    }
    
    // MARK: - Truncated Data Tests
    
    func testDecoder_TruncatedPayload_ThrowsError() {
        let decoder = JXLDecoder()
        
        // Create valid header but no payload
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0x08, 0])  // Width = 8
        data.append(contentsOf: [0, 0, 0x08, 0])  // Height = 8
        data.append(contentsOf: [8, 3, 0, 0])  // 8-bit, 3 channels
        // No mode byte or payload
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_PartialModularData_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0x08, 0])
        data.append(contentsOf: [0, 0, 0x08, 0])
        data.append(contentsOf: [8, 3, 0, 0])
        data.append(0b10000000)  // Mode bit = 1 (Modular)
        // Incomplete modular data
        data.append(contentsOf: [0, 1, 2])  // Few random bytes
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_PartialVarDCTData_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 0x08, 0])
        data.append(contentsOf: [0, 0, 0x08, 0])
        data.append(contentsOf: [8, 3, 0, 0])
        data.append(0b00000000)  // Mode bit = 0 (VarDCT)
        // Incomplete VarDCT header
        data.append(contentsOf: [0, 0, 1])  // Few bytes
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    // MARK: - Random Data Tests
    
    func testDecoder_RandomData_DoesNotCrash() {
        let decoder = JXLDecoder()
        
        // Test with various sizes of random data
        let sizes = [10, 50, 100, 500, 1000, 5000]
        
        for size in sizes {
            var randomData = Data(count: size)
            for i in 0..<size {
                randomData[i] = UInt8.random(in: 0...255)
            }
            
            // Should throw error, not crash
            XCTAssertThrowsError(try decoder.decode(randomData)) { _ in
                // Any error is acceptable, just don't crash
            }
        }
    }
    
    func testDecoder_AllZeros_DoesNotCrash() {
        let decoder = JXLDecoder()
        let zeros = Data(count: 1000)
        
        XCTAssertThrowsError(try decoder.decode(zeros))
    }
    
    func testDecoder_AllOnes_DoesNotCrash() {
        let decoder = JXLDecoder()
        let ones = Data(repeating: 0xFF, count: 1000)
        
        XCTAssertThrowsError(try decoder.decode(ones))
    }
    
    func testDecoder_AlternatingBytes_DoesNotCrash() {
        let decoder = JXLDecoder()
        var data = Data()
        for i in 0..<1000 {
            data.append(UInt8(i % 2 == 0 ? 0xAA : 0x55))
        }
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    // MARK: - Container Format Tests
    
    func testDecoder_InvalidContainerBox_ThrowsError() {
        let decoder = JXLDecoder()
        
        // Start with valid ISOBMFF header but corrupt box
        var data = Data([0x00, 0x00, 0x00, 0x0C])  // Box size = 12
        data.append(contentsOf: [0x4A, 0x58, 0x4C, 0x20])  // "JXL "
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])  // Invalid box type
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_TruncatedContainerBox_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0x00, 0x00, 0x00, 0x64])  // Box size = 100 bytes
        data.append(contentsOf: [0x6A, 0x78, 0x6C, 0x63])  // "jxlc"
        // Only 8 bytes, but claims to be 100
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    // MARK: - Metadata Extraction Tests
    
    func testDecoder_ExtractMetadata_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        
        XCTAssertThrowsError(try decoder.extractMetadata(Data()))
    }
    
    func testDecoder_ExtractMetadata_InvalidSignature_ThrowsError() {
        let decoder = JXLDecoder()
        let invalidData = Data([0x00, 0x00, 0x00, 0x00])
        
        XCTAssertThrowsError(try decoder.extractMetadata(invalidData))
    }
    
    func testDecoder_ExtractMetadata_TruncatedData_ThrowsError() {
        let decoder = JXLDecoder()
        // Data that looks like a container box (not bare codestream) but is truncated:
        // box size claims 16 bytes but only 8 are present
        let truncatedData = Data([0x00, 0x00, 0x00, 0x10, 0x6A, 0x78, 0x6C, 0x63])
        
        XCTAssertThrowsError(try decoder.extractMetadata(truncatedData))
    }
    
    // MARK: - Progressive Decoding Tests
    
    func testDecoder_ProgressiveDecoding_EmptyData_ThrowsError() {
        let decoder = JXLDecoder()
        
        XCTAssertThrowsError(try decoder.decodeProgressive(Data()) { _, _ in
            XCTFail("Should not call callback for empty data")
        })
    }
    
    func testDecoder_ProgressiveDecoding_InvalidData_ThrowsError() {
        let decoder = JXLDecoder()
        let invalidData = Data([0x00, 0x00, 0x00, 0x00])
        
        XCTAssertThrowsError(try decoder.decodeProgressive(invalidData) { _, _ in
            XCTFail("Should not call callback for invalid data")
        })
    }
    
    // MARK: - Stress Tests
    
    func testDecoder_VeryLargeClaimedDimensions_DoesNotCrash() {
        let decoder = JXLDecoder()
        
        // Create header claiming extremely large dimensions
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])  // Width = 2^31-1
        data.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF])  // Height = 2^31-1
        data.append(contentsOf: [8, 3, 0, 0])
        
        // Should fail gracefully without allocating massive memory
        XCTAssertThrowsError(try decoder.decode(data)) { _ in
            // Success: didn't crash or OOM
        }
    }
    
    func testDecoder_RepeatedInvalidDecoding_DoesNotCrash() {
        let decoder = JXLDecoder()
        let invalidData = Data([0xFF, 0xFF, 0xFF, 0xFF])
        
        // Call decoder multiple times with invalid data
        for _ in 0..<100 {
            XCTAssertThrowsError(try decoder.decode(invalidData))
        }
    }
    
    func testDecoder_MultipleDecodersWithInvalidData_DoesNotCrash() {
        let invalidData = Data([0x00, 0x00, 0x00, 0x00])
        
        // Create multiple decoders and attempt decoding
        for _ in 0..<50 {
            let decoder = JXLDecoder()
            XCTAssertThrowsError(try decoder.decode(invalidData))
        }
    }
    
    // MARK: - Edge Case Tests
    
    func testDecoder_ValidHeaderButNoPayload_ThrowsError() {
        let decoder = JXLDecoder()
        
        // Create minimal valid header
        var data = Data([0xFF, 0x0A])  // Signature
        data.append(contentsOf: [0, 0, 8, 0])  // Width = 8
        data.append(contentsOf: [0, 0, 8, 0])  // Height = 8
        data.append(contentsOf: [8, 3, 0, 0])  // 8-bit RGB
        // No mode or payload
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_UnsupportedBitsPerSample_ThrowsError() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 8, 0])
        data.append(contentsOf: [0, 0, 8, 0])
        data.append(contentsOf: [7, 3, 0, 0])  // 7-bit per sample (unsupported)
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_MixedValidAndInvalidSequence_DoesNotCrash() {
        let decoder = JXLDecoder()
        
        // Start with valid signature
        var data = Data([0xFF, 0x0A])
        data.append(contentsOf: [0, 0, 8, 0])  // Valid width
        
        // Then add random invalid data
        for _ in 0..<100 {
            data.append(UInt8.random(in: 0...255))
        }
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    // MARK: - Memory Safety Tests
    
    func testDecoder_BufferOverreadProtection_ValidSignatureInvalidRest() {
        let decoder = JXLDecoder()
        
        // Data that could cause buffer overread if not checked properly
        var data = Data([0xFF, 0x0A])  // Valid signature
        data.append(0xFF)  // Single byte that could be misinterpreted
        
        XCTAssertThrowsError(try decoder.decode(data))
    }
    
    func testDecoder_IntegerOverflowProtection_LargeDimensions() {
        let decoder = JXLDecoder()
        
        var data = Data([0xFF, 0x0A])
        // Dimensions that could cause Int overflow: 65536 * 65536
        data.append(contentsOf: [0, 0, 0, 1])  // Width = 65536
        data.append(contentsOf: [0, 0, 0, 1])  // Height = 65536
        data.append(contentsOf: [8, 3, 0, 0])
        
        // Should handle gracefully without overflow
        XCTAssertThrowsError(try decoder.decode(data)) { _ in
            // Success: no crash or overflow
        }
    }
}
