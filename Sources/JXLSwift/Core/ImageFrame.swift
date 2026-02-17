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
    
    /// Display P3 with sRGB transfer function
    /// Common on modern Apple devices
    public static var displayP3: ColorSpace {
        return .custom(primaries: .displayP3, transferFunction: .sRGB)
    }
    
    /// Display P3 with linear transfer function
    public static var displayP3Linear: ColorSpace {
        return .custom(primaries: .displayP3, transferFunction: .linear)
    }
    
    /// Rec. 2020 with PQ transfer function (HDR10)
    /// Standard for UHD HDR content
    public static var rec2020PQ: ColorSpace {
        return .custom(primaries: .rec2020, transferFunction: .pq)
    }
    
    /// Rec. 2020 with HLG transfer function
    /// Alternative HDR format, compatible with SDR displays
    public static var rec2020HLG: ColorSpace {
        return .custom(primaries: .rec2020, transferFunction: .hlg)
    }
    
    /// Rec. 2020 with linear transfer function
    public static var rec2020Linear: ColorSpace {
        return .custom(primaries: .rec2020, transferFunction: .linear)
    }
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
    
    /// Display P3 (DCI-P3 D65) primaries
    /// Used by Apple displays, wider gamut than sRGB
    public static let displayP3 = ColorPrimaries(
        redX: 0.680, redY: 0.320,
        greenX: 0.265, greenY: 0.690,
        blueX: 0.150, blueY: 0.060,
        whiteX: 0.3127, whiteY: 0.3290  // D65 white point
    )
    
    /// Rec. 2020 (BT.2020) primaries
    /// Ultra-wide gamut for UHD/HDR content
    public static let rec2020 = ColorPrimaries(
        redX: 0.708, redY: 0.292,
        greenX: 0.170, greenY: 0.797,
        blueX: 0.131, blueY: 0.046,
        whiteX: 0.3127, whiteY: 0.3290  // D65 white point
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

/// Alpha channel mode
public enum AlphaMode: Sendable {
    /// No alpha channel
    case none
    
    /// Straight (unassociated) alpha
    /// RGB values are independent of alpha
    case straight
    
    /// Premultiplied (associated) alpha
    /// RGB values are already multiplied by alpha
    case premultiplied
}

/// Extra channel type (per ISO/IEC 18181-1 §11.3.6)
///
/// Defines the semantic meaning of non-color channels.
/// These channels are stored separately from the main color channels.
public enum ExtraChannelType: UInt32, Sendable, Equatable {
    /// Alpha transparency channel
    case alpha = 0
    
    /// Depth map (distance from camera)
    case depth = 1
    
    /// Spot color (for printing)
    case spotColor = 2
    
    /// Selection mask
    case selectionMask = 3
    
    /// Black channel (for CMYK)
    case black = 4
    
    /// CFA (Color Filter Array) channel
    case cfa = 5
    
    /// Thermal/infrared data
    case thermal = 6
    
    /// Reserved for future use
    case reserved = 7
    
    /// Optional/application-specific channel
    case optional = 8
}

/// Extra channel information
///
/// Describes an additional channel beyond the main color channels.
/// Each extra channel has its own type, bit depth, and optional metadata.
public struct ExtraChannelInfo: Sendable, Equatable {
    /// Type of the extra channel
    public let type: ExtraChannelType
    
    /// Bits per sample for this channel (1-32)
    public let bitsPerSample: UInt32
    
    /// Dimension shift (for sub-sampled channels)
    /// 0 = full resolution, 1 = half resolution, etc.
    public let dimShift: UInt32
    
    /// Optional name for the channel (e.g., "Depth", "Thermal")
    public let name: String
    
    /// For alpha channels: whether it's premultiplied
    public let alphaPremultiplied: Bool
    
    /// For spot color channels: optional spot color values
    public let spotColor: [Float]
    
    /// Creates an extra channel info descriptor
    /// - Parameters:
    ///   - type: The semantic type of this channel
    ///   - bitsPerSample: Bits per sample (1-32), defaults to 8
    ///   - dimShift: Dimension shift for sub-sampling, defaults to 0 (full resolution)
    ///   - name: Optional descriptive name
    ///   - alphaPremultiplied: For alpha channels, whether RGB is premultiplied
    ///   - spotColor: For spot color channels, the color values [C, M, Y, K]
    public init(
        type: ExtraChannelType,
        bitsPerSample: UInt32 = 8,
        dimShift: UInt32 = 0,
        name: String = "",
        alphaPremultiplied: Bool = false,
        spotColor: [Float] = []
    ) {
        self.type = type
        self.bitsPerSample = max(1, min(32, bitsPerSample))
        self.dimShift = dimShift
        self.name = name
        self.alphaPremultiplied = alphaPremultiplied
        self.spotColor = spotColor
    }
    
    /// Creates a depth channel with default settings
    public static func depth(bitsPerSample: UInt32 = 16, name: String = "Depth") -> ExtraChannelInfo {
        return ExtraChannelInfo(type: .depth, bitsPerSample: bitsPerSample, name: name)
    }
    
    /// Creates a thermal channel with default settings
    public static func thermal(bitsPerSample: UInt32 = 16, name: String = "Thermal") -> ExtraChannelInfo {
        return ExtraChannelInfo(type: .thermal, bitsPerSample: bitsPerSample, name: name)
    }
    
    /// Creates an optional/application-specific channel
    public static func optional(bitsPerSample: UInt32 = 8, name: String) -> ExtraChannelInfo {
        return ExtraChannelInfo(type: .optional, bitsPerSample: bitsPerSample, name: name)
    }
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
    
    /// Alpha channel mode (only relevant if hasAlpha is true)
    public let alphaMode: AlphaMode
    
    /// Bits per sample (8, 10, 12, 16, 32)
    public let bitsPerSample: Int
    
    /// Orientation (1-8 per EXIF convention, 1 = normal/no rotation)
    /// Values 1-8 correspond to EXIF Orientation tag values:
    /// 1 = normal, 2 = flip horizontal, 3 = rotate 180°, 4 = flip vertical,
    /// 5 = rotate 270° + flip horizontal, 6 = rotate 90° CW,
    /// 7 = rotate 90° + flip horizontal, 8 = rotate 270° CW
    public let orientation: UInt32
    
    /// Extra channels beyond the main color and alpha channels
    /// These can include depth maps, thermal data, spectral bands, etc.
    public let extraChannels: [ExtraChannelInfo]
    
    /// Extra channel data (separate from main image data)
    /// Format: planar, one plane per extra channel
    /// Each plane has width * height samples in the channel's bit depth
    public var extraChannelData: [UInt8]
    
    public init(width: Int, height: Int, channels: Int, 
                pixelType: PixelType = .uint8,
                colorSpace: ColorSpace = .sRGB,
                hasAlpha: Bool = false,
                alphaMode: AlphaMode = .straight,
                bitsPerSample: Int = 8,
                orientation: UInt32 = 1,
                extraChannels: [ExtraChannelInfo] = []) {
        self.width = width
        self.height = height
        self.channels = channels
        self.pixelType = pixelType
        self.colorSpace = colorSpace
        self.hasAlpha = hasAlpha
        self.alphaMode = hasAlpha ? alphaMode : .none
        self.bitsPerSample = bitsPerSample
        self.orientation = min(8, max(1, orientation)) // Clamp to valid range
        self.extraChannels = extraChannels
        
        let totalSamples = width * height * channels
        let bytesPerSample = pixelType.bytesPerSample
        self.data = [UInt8](repeating: 0, count: totalSamples * bytesPerSample)
        
        // Allocate space for extra channel data
        var extraDataSize = 0
        for channelInfo in extraChannels {
            let samplesPerChannel = width * height
            let bytesPerSample = (Int(channelInfo.bitsPerSample) + 7) / 8
            extraDataSize += samplesPerChannel * bytesPerSample
        }
        self.extraChannelData = [UInt8](repeating: 0, count: extraDataSize)
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
    
    /// Get extra channel value at specific location
    /// - Parameters:
    ///   - x: X coordinate
    ///   - y: Y coordinate
    ///   - extraChannelIndex: Index in the extraChannels array (0-based)
    /// - Returns: The sample value scaled to UInt16 range
    public func getExtraChannelValue(x: Int, y: Int, extraChannelIndex: Int) -> UInt16 {
        guard extraChannelIndex < extraChannels.count else { return 0 }
        
        let channelInfo = extraChannels[extraChannelIndex]
        let samplesPerChannel = width * height
        
        // Calculate offset to this channel's data
        var offset = 0
        for i in 0..<extraChannelIndex {
            let prevChannelInfo = extraChannels[i]
            let bytesPerSample = (Int(prevChannelInfo.bitsPerSample) + 7) / 8
            offset += samplesPerChannel * bytesPerSample
        }
        
        // Add offset to pixel within this channel
        let pixelIndex = y * width + x
        let bytesPerSample = (Int(channelInfo.bitsPerSample) + 7) / 8
        offset += pixelIndex * bytesPerSample
        
        // Read value based on bit depth
        if channelInfo.bitsPerSample <= 8 {
            return UInt16(extraChannelData[offset])
        } else if channelInfo.bitsPerSample <= 16 {
            let lo = UInt16(extraChannelData[offset])
            let hi = UInt16(extraChannelData[offset + 1])
            return lo | (hi << 8)
        } else {
            // For >16 bits, scale down to 16-bit range
            let value = UInt32(extraChannelData[offset]) |
                       (UInt32(extraChannelData[offset + 1]) << 8) |
                       (UInt32(extraChannelData[offset + 2]) << 16) |
                       (UInt32(extraChannelData[offset + 3]) << 24)
            let maxValue = (UInt64(1) << channelInfo.bitsPerSample) - 1
            return UInt16((UInt64(value) * 65535) / maxValue)
        }
    }
    
    /// Set extra channel value at specific location
    /// - Parameters:
    ///   - x: X coordinate
    ///   - y: Y coordinate
    ///   - extraChannelIndex: Index in the extraChannels array (0-based)
    ///   - value: The sample value (in UInt16 range, will be scaled to channel's bit depth)
    public mutating func setExtraChannelValue(x: Int, y: Int, extraChannelIndex: Int, value: UInt16) {
        guard extraChannelIndex < extraChannels.count else { return }
        
        let channelInfo = extraChannels[extraChannelIndex]
        let samplesPerChannel = width * height
        
        // Calculate offset to this channel's data
        var offset = 0
        for i in 0..<extraChannelIndex {
            let prevChannelInfo = extraChannels[i]
            let bytesPerSample = (Int(prevChannelInfo.bitsPerSample) + 7) / 8
            offset += samplesPerChannel * bytesPerSample
        }
        
        // Add offset to pixel within this channel
        let pixelIndex = y * width + x
        let bytesPerSample = (Int(channelInfo.bitsPerSample) + 7) / 8
        offset += pixelIndex * bytesPerSample
        
        // Write value based on bit depth
        if channelInfo.bitsPerSample <= 8 {
            extraChannelData[offset] = UInt8(min(255, value))
        } else if channelInfo.bitsPerSample <= 16 {
            extraChannelData[offset] = UInt8(value & 0xFF)
            extraChannelData[offset + 1] = UInt8((value >> 8) & 0xFF)
        } else {
            // For >16 bits, scale up from 16-bit range
            let maxValue = (UInt64(1) << channelInfo.bitsPerSample) - 1
            let scaledValue = UInt32((UInt64(value) * maxValue) / 65535)
            extraChannelData[offset] = UInt8(scaledValue & 0xFF)
            extraChannelData[offset + 1] = UInt8((scaledValue >> 8) & 0xFF)
            extraChannelData[offset + 2] = UInt8((scaledValue >> 16) & 0xFF)
            extraChannelData[offset + 3] = UInt8((scaledValue >> 24) & 0xFF)
        }
    }
}
