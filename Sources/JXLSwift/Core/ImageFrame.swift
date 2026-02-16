/// Core image data structures for JPEG XL encoding
///
/// Defines the fundamental image representation used throughout the codec.

import Foundation

/// Color space representation
public enum ColorSpace: Sendable {
    case sRGB
    case linearRGB
    case grayscale
    case cmyk
    case custom(primaries: ColorPrimaries, transferFunction: TransferFunction)
}

/// Color primaries
public struct ColorPrimaries: Sendable {
    public let redX: Float
    public let redY: Float
    public let greenX: Float
    public let greenY: Float
    public let blueX: Float
    public let blueY: Float
    public let whiteX: Float
    public let whiteY: Float
    
    public init(redX: Float, redY: Float, greenX: Float, greenY: Float,
                blueX: Float, blueY: Float, whiteX: Float, whiteY: Float) {
        self.redX = redX
        self.redY = redY
        self.greenX = greenX
        self.greenY = greenY
        self.blueX = blueX
        self.blueY = blueY
        self.whiteX = whiteX
        self.whiteY = whiteY
    }
    
    /// sRGB/Rec.709 primaries
    public static let sRGB = ColorPrimaries(
        redX: 0.64, redY: 0.33,
        greenX: 0.30, greenY: 0.60,
        blueX: 0.15, blueY: 0.06,
        whiteX: 0.3127, whiteY: 0.3290
    )
}

/// Transfer function (gamma curve)
public enum TransferFunction: Sendable {
    case linear
    case sRGB
    case gamma(Float)
    case pq      // Perceptual Quantizer (HDR)
    case hlg     // Hybrid Log-Gamma (HDR)
}

/// Pixel data type
public enum PixelType: Sendable {
    case uint8
    case uint16
    case float32
    
    public var bytesPerSample: Int {
        switch self {
        case .uint8: return 1
        case .uint16: return 2
        case .float32: return 4
        }
    }
}

/// Image frame representation
public struct ImageFrame {
    /// Image width in pixels
    public let width: Int
    
    /// Image height in pixels
    public let height: Int
    
    /// Number of color channels
    public let channels: Int
    
    /// Pixel data type
    public let pixelType: PixelType
    
    /// Color space
    public let colorSpace: ColorSpace
    
    /// Raw pixel data (planar format: all R, then all G, then all B, etc.)
    public var data: [UInt8]
    
    /// Has alpha channel
    public let hasAlpha: Bool
    
    /// Bits per sample (8, 10, 12, 16, 32)
    public let bitsPerSample: Int
    
    public init(width: Int, height: Int, channels: Int, 
                pixelType: PixelType = .uint8,
                colorSpace: ColorSpace = .sRGB,
                hasAlpha: Bool = false,
                bitsPerSample: Int = 8) {
        self.width = width
        self.height = height
        self.channels = channels
        self.pixelType = pixelType
        self.colorSpace = colorSpace
        self.hasAlpha = hasAlpha
        self.bitsPerSample = bitsPerSample
        
        let totalSamples = width * height * channels
        let bytesPerSample = pixelType.bytesPerSample
        self.data = [UInt8](repeating: 0, count: totalSamples * bytesPerSample)
    }
    
    /// Get pixel value at specific location and channel
    public func getPixel(x: Int, y: Int, channel: Int) -> UInt16 {
        // Planar format: channel * (width * height) + (y * width + x)
        let index = channel * (width * height) + (y * width + x)
        
        switch pixelType {
        case .uint8:
            return UInt16(data[index])
        case .uint16:
            let offset = index * 2
            return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        case .float32:
            // For float, scale to 16-bit range
            let offset = index * 4
            let floatBits = UInt32(data[offset]) |
                           (UInt32(data[offset + 1]) << 8) |
                           (UInt32(data[offset + 2]) << 16) |
                           (UInt32(data[offset + 3]) << 24)
            let floatValue = Float(bitPattern: floatBits)
            return UInt16(max(0, min(65535, floatValue * 65535)))
        }
    }
    
    /// Set pixel value at specific location and channel
    public mutating func setPixel(x: Int, y: Int, channel: Int, value: UInt16) {
        // Planar format: channel * (width * height) + (y * width + x)
        let index = channel * (width * height) + (y * width + x)
        
        switch pixelType {
        case .uint8:
            data[index] = UInt8(min(255, value))
        case .uint16:
            let offset = index * 2
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8((value >> 8) & 0xFF)
        case .float32:
            let offset = index * 4
            let floatValue = Float(value) / 65535.0
            let floatBits = floatValue.bitPattern
            data[offset] = UInt8(floatBits & 0xFF)
            data[offset + 1] = UInt8((floatBits >> 8) & 0xFF)
            data[offset + 2] = UInt8((floatBits >> 16) & 0xFF)
            data[offset + 3] = UInt8((floatBits >> 24) & 0xFF)
        }
    }
}
