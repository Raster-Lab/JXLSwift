/// EXIF orientation parsing utilities
///
/// Provides functions to extract orientation information from EXIF metadata.

import Foundation

/// EXIF orientation tag parser
public struct EXIFOrientation {
    /// EXIF Orientation tag ID (0x0112)
    private static let orientationTagID: UInt16 = 0x0112
    
    /// Extract orientation value from EXIF data
    /// - Parameter exifData: Raw EXIF data (TIFF-formatted)
    /// - Returns: Orientation value (1-8), or 1 if not found or invalid
    public static func extractOrientation(from exifData: Data) -> UInt32 {
        guard exifData.count >= 8 else { return 1 }
        
        // Read TIFF header (first 2 bytes indicate byte order)
        let tiffHeader = exifData.prefix(2)
        let isBigEndian: Bool
        
        if tiffHeader[0] == 0x4D && tiffHeader[1] == 0x4D {
            // "MM" = Motorola byte order (big-endian)
            isBigEndian = true
        } else if tiffHeader[0] == 0x49 && tiffHeader[1] == 0x49 {
            // "II" = Intel byte order (little-endian)
            isBigEndian = false
        } else {
            // Invalid TIFF header
            return 1
        }
        
        // Verify TIFF magic number (should be 42)
        guard exifData.count >= 4 else { return 1 }
        let magicNumber = readUInt16(from: exifData, at: 2, bigEndian: isBigEndian)
        guard magicNumber == 42 else { return 1 }
        
        // Read offset to first IFD
        guard exifData.count >= 8 else { return 1 }
        let ifdOffset = Int(readUInt32(from: exifData, at: 4, bigEndian: isBigEndian))
        guard ifdOffset < exifData.count - 2 else { return 1 }
        
        // Read IFD entry count
        let entryCount = Int(readUInt16(from: exifData, at: ifdOffset, bigEndian: isBigEndian))
        guard entryCount > 0 && entryCount < 1000 else { return 1 } // Sanity check
        
        let ifdStart = ifdOffset + 2
        let entrySize = 12 // Each IFD entry is 12 bytes
        
        // Search for orientation tag
        for i in 0..<entryCount {
            let entryOffset = ifdStart + (i * entrySize)
            guard entryOffset + entrySize <= exifData.count else { break }
            
            let tagID = readUInt16(from: exifData, at: entryOffset, bigEndian: isBigEndian)
            
            if tagID == orientationTagID {
                // Found orientation tag
                // Read the value (offset +8, SHORT type has value at offset +8-9)
                let tagType = readUInt16(from: exifData, at: entryOffset + 2, bigEndian: isBigEndian)
                
                // Type 3 = SHORT (2 bytes)
                if tagType == 3 {
                    let value = readUInt16(from: exifData, at: entryOffset + 8, bigEndian: isBigEndian)
                    let orientation = UInt32(value)
                    
                    // Validate orientation is in range 1-8
                    if orientation >= 1 && orientation <= 8 {
                        return orientation
                    }
                }
                break
            }
        }
        
        return 1 // Default orientation if not found
    }
    
    // MARK: - Private Helpers
    
    private static func readUInt16(from data: Data, at offset: Int, bigEndian: Bool) -> UInt16 {
        guard offset + 1 < data.count else { return 0 }
        
        let byte0 = UInt16(data[offset])
        let byte1 = UInt16(data[offset + 1])
        
        return bigEndian ? (byte0 << 8) | byte1 : (byte1 << 8) | byte0
    }
    
    private static func readUInt32(from data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 3 < data.count else { return 0 }
        
        let byte0 = UInt32(data[offset])
        let byte1 = UInt32(data[offset + 1])
        let byte2 = UInt32(data[offset + 2])
        let byte3 = UInt32(data[offset + 3])
        
        if bigEndian {
            return (byte0 << 24) | (byte1 << 16) | (byte2 << 8) | byte3
        } else {
            return (byte3 << 24) | (byte2 << 16) | (byte1 << 8) | byte0
        }
    }
}

/// Helper to create EXIF data with specific orientation for testing
public struct EXIFBuilder {
    /// Create minimal EXIF data with specified orientation
    /// - Parameter orientation: Orientation value (1-8)
    /// - Returns: TIFF-formatted EXIF data
    public static func createWithOrientation(_ orientation: UInt32) -> Data {
        let clampedOrientation = max(1, min(8, UInt16(orientation)))
        
        var exif = Data()
        
        // TIFF header - little-endian (Intel byte order)
        exif.append(contentsOf: [0x49, 0x49]) // "II"
        exif.append(contentsOf: [0x2A, 0x00]) // Magic number 42
        exif.append(contentsOf: [0x08, 0x00, 0x00, 0x00]) // Offset to first IFD (8 bytes)
        
        // IFD0 starts at offset 8
        exif.append(contentsOf: [0x01, 0x00]) // 1 entry in IFD
        
        // IFD entry: Orientation tag
        exif.append(contentsOf: [0x12, 0x01]) // Tag ID: 0x0112 (Orientation)
        exif.append(contentsOf: [0x03, 0x00]) // Type: SHORT (3)
        exif.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // Count: 1
        // Value (SHORT values stored directly in offset field if ≤4 bytes)
        exif.append(contentsOf: [UInt8(clampedOrientation & 0xFF), UInt8((clampedOrientation >> 8) & 0xFF)])
        exif.append(contentsOf: [0x00, 0x00]) // Padding
        
        // Offset to next IFD (0 = no more IFDs)
        exif.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        
        return exif
    }
}
