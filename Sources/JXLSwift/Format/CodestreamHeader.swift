/// JPEG XL Codestream Header — ISO/IEC 18181-1 §11
///
/// Implements the SizeHeader, ImageMetadata, and colour encoding structures
/// for the JPEG XL codestream header.

import Foundation

// MARK: - Size Header

/// JPEG XL Size Header per ISO/IEC 18181-1 §11.1
///
/// Encodes image dimensions using a variable-length scheme:
/// - Small dimensions (≤ 256) use 8 bits
/// - Medium dimensions (≤ 65536) use 16 bits
/// - Large dimensions (> 65536) use 32 bits
public struct SizeHeader: Sendable, Equatable {
    /// Image width in pixels (1 .. 2^30)
    public let width: UInt32

    /// Image height in pixels (1 .. 2^30)
    public let height: UInt32

    /// Maximum dimension allowed by the specification
    public static let maximumDimension: UInt32 = 1 << 30 // 1,073,741,824

    /// Creates a SizeHeader with the given dimensions.
    /// - Parameters:
    ///   - width: Image width in pixels (must be ≥ 1 and ≤ `maximumDimension`).
    ///   - height: Image height in pixels (must be ≥ 1 and ≤ `maximumDimension`).
    /// - Throws: `CodestreamError.invalidDimensions` if dimensions are out of range.
    public init(width: UInt32, height: UInt32) throws {
        guard width >= 1, width <= SizeHeader.maximumDimension,
              height >= 1, height <= SizeHeader.maximumDimension else {
            throw CodestreamError.invalidDimensions(width: width, height: height)
        }
        self.width = width
        self.height = height
    }

    /// Serialise the size header into the given bitstream writer.
    ///
    /// Encoding scheme (per spec §11.1):
    /// - 1-bit `small`: if both dimensions ≤ 256
    ///   - When small: each dimension encoded as `(value - 1)` in 8 bits
    /// - Otherwise:
    ///   - Each dimension uses a 2-bit selector:
    ///     - `00`: 9-bit value `(v - 1)` — up to 512
    ///     - `01`: 13-bit value `(v - 1)` — up to 8192
    ///     - `10`: 18-bit value `(v - 1)` — up to 262144
    ///     - `11`: 30-bit value `(v - 1)` — up to 1,073,741,824
    func serialise(to writer: inout BitstreamWriter) {
        let small = width <= 256 && height <= 256
        writer.writeBit(small)

        if small {
            // 8-bit encoded dimensions
            writer.writeBits(UInt32(height - 1), count: 8)
            writer.writeBits(UInt32(width - 1), count: 8)
        } else {
            writeDimension(height, to: &writer)
            writeDimension(width, to: &writer)
        }
    }

    /// Write a single dimension using the variable-length selector scheme.
    private func writeDimension(_ value: UInt32, to writer: inout BitstreamWriter) {
        let v = value - 1
        if v < (1 << 9) {
            writer.writeBits(0b00, count: 2)
            writer.writeBits(v, count: 9)
        } else if v < (1 << 13) {
            writer.writeBits(0b01, count: 2)
            writer.writeBits(v, count: 13)
        } else if v < (1 << 18) {
            writer.writeBits(0b10, count: 2)
            writer.writeBits(v, count: 18)
        } else {
            writer.writeBits(0b11, count: 2)
            writer.writeBits(v, count: 30)
        }
    }
}

// MARK: - Colour Encoding

/// Colour encoding per ISO/IEC 18181-1 §11.4
///
/// Describes how colour information is encoded in the codestream.
public struct ColourEncoding: Sendable, Equatable {
    /// Whether the colour space is signalled using an ICC profile
    public let useICCProfile: Bool

    /// Colour space type (when not using ICC)
    public let colourSpace: ColourSpace

    /// White point
    public let whitePoint: WhitePoint

    /// Primaries
    public let primaries: Primaries

    /// Transfer function (rendering intent)
    public let transferFunction: ColourTransferFunction

    /// Rendering intent
    public let renderingIntent: RenderingIntent

    /// Standard sRGB colour encoding (most common default)
    public static let sRGB = ColourEncoding(
        useICCProfile: false,
        colourSpace: .rgb,
        whitePoint: .d65,
        primaries: .sRGB,
        transferFunction: .sRGB,
        renderingIntent: .relative
    )

    /// Linear sRGB (linear light, sRGB primaries)
    public static let linearSRGB = ColourEncoding(
        useICCProfile: false,
        colourSpace: .rgb,
        whitePoint: .d65,
        primaries: .sRGB,
        transferFunction: .linear,
        renderingIntent: .relative
    )

    /// Greyscale sRGB
    public static let greyscale = ColourEncoding(
        useICCProfile: false,
        colourSpace: .grey,
        whitePoint: .d65,
        primaries: .sRGB,
        transferFunction: .sRGB,
        renderingIntent: .relative
    )

    /// Initialise a colour encoding.
    public init(
        useICCProfile: Bool = false,
        colourSpace: ColourSpace = .rgb,
        whitePoint: WhitePoint = .d65,
        primaries: Primaries = .sRGB,
        transferFunction: ColourTransferFunction = .sRGB,
        renderingIntent: RenderingIntent = .relative
    ) {
        self.useICCProfile = useICCProfile
        self.colourSpace = colourSpace
        self.whitePoint = whitePoint
        self.primaries = primaries
        self.transferFunction = transferFunction
        self.renderingIntent = renderingIntent
    }

    /// Serialise the colour encoding into the given bitstream writer.
    func serialise(to writer: inout BitstreamWriter) {
        // all_default flag: true when exactly sRGB
        let allDefault = (self == ColourEncoding.sRGB)
        writer.writeBit(allDefault)

        if allDefault { return }

        // Use ICC profile flag
        writer.writeBit(useICCProfile)

        if useICCProfile {
            // ICC profile data is written separately (see JXLContainer)
            return
        }

        // Colour space
        writer.writeBits(colourSpace.rawValue, count: 2)

        // White point
        writer.writeBits(whitePoint.rawValue, count: 2)
        if whitePoint == .custom {
            // Custom white point would need CIE xy coordinates — placeholder
            writer.writeBits(0, count: 32) // x
            writer.writeBits(0, count: 32) // y
        }

        // Primaries (only for RGB)
        if colourSpace == .rgb {
            writer.writeBits(primaries.rawValue, count: 2)
            if primaries == .custom {
                // 6 × 32-bit CIE coordinates — placeholder
                for _ in 0..<6 {
                    writer.writeBits(0, count: 32)
                }
            }
        }

        // Transfer function
        writer.writeBits(transferFunction.rawValue, count: 2)
        if transferFunction == .gamma {
            // 24-bit gamma value — placeholder
            writer.writeBits(0, count: 24)
        }

        // Rendering intent
        writer.writeBits(renderingIntent.rawValue, count: 2)
    }
}

/// Colour space type per spec §11.4
public enum ColourSpace: UInt32, Sendable, Equatable {
    case rgb = 0
    case grey = 1
    case xyb = 2
    case unknown = 3
}

/// White point per spec §11.4
public enum WhitePoint: UInt32, Sendable, Equatable {
    case d65 = 0
    case custom = 1
    case e = 2
    case dci = 3
}

/// Primaries per spec §11.4
public enum Primaries: UInt32, Sendable, Equatable {
    case sRGB = 0
    case custom = 1
    case bt2100 = 2
    case p3 = 3
}

/// Transfer function per spec §11.4
public enum ColourTransferFunction: UInt32, Sendable, Equatable {
    case bt709 = 0
    case unknown = 1
    case linear = 2
    case sRGB = 3
    case pq = 4
    case dci = 5
    case hlg = 6
    case gamma = 7
}

/// Rendering intent per spec §11.4
public enum RenderingIntent: UInt32, Sendable, Equatable {
    case perceptual = 0
    case relative = 1
    case saturation = 2
    case absolute = 3
}

// MARK: - Image Metadata

/// Image metadata per ISO/IEC 18181-1 §11.3
///
/// Describes global image properties stored in the codestream header.
public struct ImageMetadata: Sendable, Equatable {
    /// Bits per sample (1–32). Default is 8.
    public var bitsPerSample: UInt32

    /// Whether extra channels (alpha, depth, etc.) are present
    public var hasAlpha: Bool

    /// Number of extra channels (0 if no alpha/depth/etc.)
    public var extraChannelCount: UInt32

    /// XYB encoded flag (true for lossy VarDCT, false for modular)
    public var xybEncoded: Bool

    /// Colour encoding information
    public var colourEncoding: ColourEncoding

    /// Orientation (1–8 per EXIF convention, 1 = normal)
    public var orientation: UInt32

    /// Whether the image has intrinsic animation
    public var haveAnimation: Bool

    /// Animation ticks per second numerator (if haveAnimation)
    public var animationTpsNumerator: UInt32

    /// Animation ticks per second denominator (if haveAnimation)
    public var animationTpsDenominator: UInt32

    /// Animation loop count (0 = infinite, if haveAnimation)
    public var animationLoopCount: UInt32

    /// Creates image metadata with reasonable defaults.
    public init(
        bitsPerSample: UInt32 = 8,
        hasAlpha: Bool = false,
        extraChannelCount: UInt32 = 0,
        xybEncoded: Bool = false,
        colourEncoding: ColourEncoding = .sRGB,
        orientation: UInt32 = 1,
        haveAnimation: Bool = false,
        animationTpsNumerator: UInt32 = 0,
        animationTpsDenominator: UInt32 = 1,
        animationLoopCount: UInt32 = 0
    ) {
        self.bitsPerSample = bitsPerSample
        self.hasAlpha = hasAlpha
        self.extraChannelCount = extraChannelCount
        self.xybEncoded = xybEncoded
        self.colourEncoding = colourEncoding
        self.orientation = orientation
        self.haveAnimation = haveAnimation
        self.animationTpsNumerator = animationTpsNumerator
        self.animationTpsDenominator = animationTpsDenominator
        self.animationLoopCount = animationLoopCount
    }

    /// Serialise the image metadata into the given bitstream writer.
    func serialise(to writer: inout BitstreamWriter) {
        // all_default — true when 8-bit, no alpha, sRGB, no animation, orientation 1
        let allDefault = (bitsPerSample == 8 &&
                          !hasAlpha &&
                          extraChannelCount == 0 &&
                          !xybEncoded &&
                          colourEncoding == .sRGB &&
                          orientation == 1 &&
                          !haveAnimation)

        writer.writeBit(allDefault)
        if allDefault { return }

        // Bit depth
        let defaultBitDepth = (bitsPerSample == 8)
        writer.writeBit(defaultBitDepth)
        if !defaultBitDepth {
            if bitsPerSample <= 8 {
                writer.writeBits(0, count: 2) // selector 0: 8-bit field
                writer.writeBits(bitsPerSample, count: 8)
            } else if bitsPerSample <= 16 {
                writer.writeBits(1, count: 2) // selector 1: 16-bit field
                writer.writeBits(bitsPerSample, count: 16)
            } else {
                writer.writeBits(2, count: 2) // selector 2: 32-bit field
                writer.writeBits(bitsPerSample, count: 32)
            }
        }

        // Extra channels
        writer.writeBit(hasAlpha)
        if hasAlpha || extraChannelCount > 0 {
            writer.writeBits(extraChannelCount, count: 8)
        }

        // XYB encoded
        writer.writeBit(xybEncoded)

        // Colour encoding
        colourEncoding.serialise(to: &writer)

        // Orientation (only if not default 1)
        let defaultOrientation = (orientation == 1)
        writer.writeBit(defaultOrientation)
        if !defaultOrientation {
            writer.writeBits(orientation - 1, count: 3)
        }

        // Animation
        writer.writeBit(haveAnimation)
        if haveAnimation {
            writer.writeBits(animationTpsNumerator, count: 32)
            writer.writeBits(animationTpsDenominator, count: 32)
            writer.writeBits(animationLoopCount, count: 32)
        }
    }
}

// MARK: - Codestream Header

/// Complete JPEG XL codestream header per ISO/IEC 18181-1 §11
///
/// Combines the signature, size header, and image metadata into a single
/// unit that appears at the beginning of every JPEG XL codestream.
public struct CodestreamHeader: Sendable, Equatable {
    /// Size header (image dimensions)
    public let size: SizeHeader

    /// Image metadata
    public let metadata: ImageMetadata

    /// Creates a codestream header from an `ImageFrame`.
    /// - Parameter frame: The source image frame.
    /// - Throws: `CodestreamError.invalidDimensions` if the frame has invalid dimensions.
    public init(frame: ImageFrame) throws {
        self.size = try SizeHeader(
            width: UInt32(frame.width),
            height: UInt32(frame.height)
        )
        
        // Calculate total extra channel count: alpha (if present) + additional extra channels
        let totalExtraChannels = (frame.hasAlpha ? 1 : 0) + UInt32(frame.extraChannels.count)
        
        self.metadata = ImageMetadata(
            bitsPerSample: UInt32(frame.bitsPerSample),
            hasAlpha: frame.hasAlpha,
            extraChannelCount: totalExtraChannels,
            xybEncoded: false,
            colourEncoding: ColourEncoding.from(colorSpace: frame.colorSpace),
            orientation: frame.orientation,
            haveAnimation: false
        )
    }

    /// Creates a codestream header with explicit components.
    public init(size: SizeHeader, metadata: ImageMetadata) {
        self.size = size
        self.metadata = metadata
    }

    /// Serialise the entire codestream header (signature + size + metadata).
    /// - Returns: The serialised header bytes.
    public func serialise() -> Data {
        var writer = BitstreamWriter()

        // JPEG XL codestream signature: 0xFF 0x0A
        try? writer.writeSignature()

        // Size header
        size.serialise(to: &writer)

        // Image metadata
        metadata.serialise(to: &writer)

        writer.flushByte()
        return writer.data
    }
}

// MARK: - Colour Encoding Helpers

extension ColourEncoding {
    /// Convert from the library's `ColorSpace` enum to a `ColourEncoding`.
    static func from(colorSpace: ColorSpace) -> ColourEncoding {
        switch colorSpace {
        case .sRGB:
            return .sRGB
        case .linearRGB:
            return .linearSRGB
        case .grayscale:
            return .greyscale
        case .cmyk:
            // CMYK not natively supported in JXL; fall back to sRGB
            return .sRGB
        case .custom:
            // Custom primaries/transfer — use ICC profile path
            return ColourEncoding(
                useICCProfile: true,
                colourSpace: .rgb,
                whitePoint: .d65,
                primaries: .custom,
                transferFunction: .sRGB,
                renderingIntent: .relative
            )
        }
    }
}

// MARK: - Codestream Errors

/// Errors related to codestream header construction and serialisation.
public enum CodestreamError: Error, LocalizedError, Equatable, Sendable {
    /// Invalid image dimensions (out of range or zero).
    case invalidDimensions(width: UInt32, height: UInt32)

    /// Invalid bit depth.
    case invalidBitDepth(UInt32)

    /// Invalid orientation value (must be 1–8).
    case invalidOrientation(UInt32)

    /// Frame header construction error.
    case invalidFrameHeader(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let w, let h):
            return "Invalid image dimensions: \(w)×\(h)"
        case .invalidBitDepth(let depth):
            return "Invalid bit depth: \(depth)"
        case .invalidOrientation(let o):
            return "Invalid orientation: \(o) (must be 1–8)"
        case .invalidFrameHeader(let reason):
            return "Invalid frame header: \(reason)"
        }
    }
}
