// ImageFrame: the pixel container used by JXLSwift's Encoder and Decoder.

import Foundation

/// Per-pixel sample type.
public enum PixelType: Sendable, Equatable {
    case uint8
    case uint16
    /// Signed 16-bit samples (two's-complement, little-endian in
    /// `data`). JPEG XL codestreams have no native signed-sample
    /// type, so the encoder level-shifts `.int16` into unsigned
    /// offset-binary (sample + 32768, the JPEG convention) before
    /// encoding; ``JXLDecoder/decode(_:signedOutput:)`` recovers the
    /// signed frame. The primary DICOM use case is signed 16-bit CT.
    case int16
    case float32

    public var bitsPerSample: Int {
        switch self {
        case .uint8:          return 8
        case .uint16, .int16: return 16
        case .float32:        return 32
        }
    }

    public var bytesPerSample: Int {
        switch self {
        case .uint8:          return 1
        case .uint16, .int16: return 2
        case .float32:        return 4
        }
    }

    /// True for signed sample types (currently only ``int16``).
    public var isSigned: Bool { self == .int16 }
}

/// Colour space tag carried alongside the pixel data. JXLSwift currently
/// supports the spec-named combinations; for arbitrary ICC profiles, attach
/// the bytes via ``ImageFrame/iccProfile``.
public enum ColorSpace: Sendable, Equatable {
    case sRGB
    case linearRGB
    case grayscale
    case displayP3
    case rec2020
}

/// A raster frame: pixel data plus geometry and colour-space metadata.
///
/// Pixel layout is row-major, channel-interleaved. For an `n`-channel uint8
/// image, byte `bytes[(y * width + x) * n + c]` is the sample for column `x`,
/// row `y`, channel `c`.
public struct ImageFrame: Sendable {
    public let width: Int
    public let height: Int
    public let channels: Int
    public let pixelType: PixelType
    public let colorSpace: ColorSpace
    /// Number of trailing channels that are alpha (0 or 1).
    public let alphaChannels: Int
    /// Optional ICC profile bytes. When set, takes precedence over `colorSpace`.
    public let iccProfile: Data?
    /// Raw, channel-interleaved, row-major pixel bytes.
    public var data: [UInt8]

    public init(
        width: Int,
        height: Int,
        channels: Int,
        pixelType: PixelType = .uint8,
        colorSpace: ColorSpace = .sRGB,
        alphaChannels: Int = 0,
        iccProfile: Data? = nil
    ) {
        precondition(width > 0 && height > 0, "dimensions must be positive")
        precondition((1...4).contains(channels), "channels must be 1...4")
        precondition((0...1).contains(alphaChannels), "alphaChannels must be 0 or 1")
        precondition(alphaChannels <= channels, "alpha channel count exceeds total")
        self.width = width
        self.height = height
        self.channels = channels
        self.pixelType = pixelType
        self.colorSpace = colorSpace
        self.alphaChannels = alphaChannels
        self.iccProfile = iccProfile
        self.data = [UInt8](repeating: 0, count: width * height * channels * pixelType.bytesPerSample)
    }

    /// Bytes per row including all channels.
    public var bytesPerRow: Int { width * channels * pixelType.bytesPerSample }

    /// Bytes per pixel including all channels.
    public var bytesPerPixel: Int { channels * pixelType.bytesPerSample }

    /// Read a single sample as `UInt16` (works for `uint8`/`uint16`; for
    /// `float32` returns the rounded value clamped to `0…65535`).
    public func getPixel(x: Int, y: Int, channel: Int) -> UInt16 {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "coord out of bounds")
        precondition(channel >= 0 && channel < channels, "channel out of bounds")
        let i = (y * width + x) * channels + channel
        switch pixelType {
        case .uint8:
            return UInt16(data[i])
        case .uint16:
            let lo = UInt16(data[i * 2])
            let hi = UInt16(data[i * 2 + 1])
            return (hi << 8) | lo
        case .int16:
            // Stored two's-complement; return offset-binary
            // (sample + 32768) so the value is always 0…65535. XOR of
            // the sign bit is exactly the two's-complement ↔
            // offset-binary conversion.
            let lo = UInt16(data[i * 2])
            let hi = UInt16(data[i * 2 + 1])
            return ((hi << 8) | lo) ^ 0x8000
        case .float32:
            let bytes = Array(data[(i * 4)..<(i * 4 + 4)])
            let bits = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            let f = Float(bitPattern: bits)
            let scaled = max(0, min(65535, f * 65535))
            return UInt16(scaled)
        }
    }

    /// Write a single sample. `value` is interpreted in the natural range
    /// for the pixel type.
    public mutating func setPixel(x: Int, y: Int, channel: Int, value: UInt16) {
        precondition(x >= 0 && x < width && y >= 0 && y < height, "coord out of bounds")
        precondition(channel >= 0 && channel < channels, "channel out of bounds")
        let i = (y * width + x) * channels + channel
        switch pixelType {
        case .uint8:
            data[i] = UInt8(min(value, 255))
        case .uint16:
            data[i * 2]     = UInt8(value & 0xFF)
            data[i * 2 + 1] = UInt8((value >> 8) & 0xFF)
        case .int16:
            // `value` is offset-binary (sample + 32768); store the
            // two's-complement sample (XOR of the sign bit inverts
            // the conversion applied in `getPixel`).
            let raw = value ^ 0x8000
            data[i * 2]     = UInt8(raw & 0xFF)
            data[i * 2 + 1] = UInt8((raw >> 8) & 0xFF)
        case .float32:
            let f = Float(value) / 65535.0
            let bits = f.bitPattern
            data[i * 4]     = UInt8(bits & 0xFF)
            data[i * 4 + 1] = UInt8((bits >> 8)  & 0xFF)
            data[i * 4 + 2] = UInt8((bits >> 16) & 0xFF)
            data[i * 4 + 3] = UInt8((bits >> 24) & 0xFF)
        }
    }

    public var hasAlpha: Bool { alphaChannels > 0 }

    /// Level-shift a signed ``int16`` frame into an equivalent
    /// ``uint16`` frame whose samples are offset-binary
    /// (sample + 32768). This is the JPEG-style level shift the
    /// encoder applies so signed data flows through the unsigned
    /// VarDCT / Modular pipeline unchanged. Every 16-bit sample's
    /// sign bit is flipped — the two's-complement ↔ offset-binary
    /// conversion — which also level-shifts any alpha channel
    /// symmetrically (harmless: alpha is lossless, so it un-shifts
    /// exactly). Geometry, channel count, colour space and alpha
    /// count are preserved. No-op label change if already unsigned.
    public func levelShiftedToUnsigned16() -> ImageFrame {
        guard pixelType == .int16 else { return self }
        var out = ImageFrame(
            width: width, height: height, channels: channels,
            pixelType: .uint16, colorSpace: colorSpace,
            alphaChannels: alphaChannels, iccProfile: iccProfile)
        out.data = data
        var i = 1
        while i < out.data.count { out.data[i] ^= 0x80; i += 2 }
        return out
    }

    /// Inverse of ``levelShiftedToUnsigned16()``: reinterpret a
    /// ``uint16`` frame's offset-binary samples as signed ``int16``
    /// (sample − 32768). Used by
    /// ``JXLDecoder/decode(_:signedOutput:)`` to recover a signed
    /// frame from an unsigned decode. No-op label change if the frame
    /// is not ``uint16``.
    public func reinterpretedAsSignedInt16() -> ImageFrame {
        guard pixelType == .uint16 else { return self }
        var out = ImageFrame(
            width: width, height: height, channels: channels,
            pixelType: .int16, colorSpace: colorSpace,
            alphaChannels: alphaChannels, iccProfile: iccProfile)
        out.data = data
        var i = 1
        while i < out.data.count { out.data[i] ^= 0x80; i += 2 }
        return out
    }
}

/// Family-parity alias for ``ImageFrame``. JXLSwift is part of a Swift
/// compression-library family alongside J2KSwift (which uses
/// `J2KImage`); `JXLImage` lets callers write codec-agnostic call
/// sites that swap between the two libraries by name only. Both
/// names refer to the same type — `ImageFrame` remains the canonical
/// in-tree spelling.
///
/// See [Documentation/FAMILY-API-PARITY.md](../../../Documentation/FAMILY-API-PARITY.md)
/// for the full alignment plan.
public typealias JXLImage = ImageFrame
