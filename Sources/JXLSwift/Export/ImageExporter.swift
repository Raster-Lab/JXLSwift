/// Image format export support
///
/// Converts decoded `ImageFrame` data to standard image formats (PNG, TIFF, BMP)
/// using platform-native CoreGraphics and ImageIO facilities.
///
/// On Apple platforms (macOS, iOS, tvOS, watchOS, visionOS), this module uses
/// `CGImage` and `CGImageDestination` for high-performance format conversion.
/// Planar-to-interleaved pixel conversion is available on all platforms.

import Foundation

// MARK: - Output Format

/// Supported output image formats for export.
///
/// Each format maps to a platform-native UTI string used by `ImageIO`.
public enum OutputFormat: String, Sendable, CaseIterable {
    /// Portable Network Graphics — lossless, supports transparency
    case png
    /// Tagged Image File Format — lossless, supports 16-bit
    case tiff
    /// Windows Bitmap — uncompressed, no alpha support
    case bmp

    /// Detect output format from a file extension string.
    ///
    /// - Parameter fileExtension: The file extension (e.g., "png", "tiff", "bmp").
    /// - Returns: The matching `OutputFormat`, or `nil` if unrecognized.
    public static func from(fileExtension: String) -> OutputFormat? {
        switch fileExtension.lowercased() {
        case "png": return .png
        case "tiff", "tif": return .tiff
        case "bmp": return .bmp
        default: return nil
        }
    }
}

// MARK: - Exporter Errors

/// Errors that can occur during image export.
public enum ExporterError: Error, LocalizedError, Equatable {
    /// The image has invalid dimensions (zero or negative).
    case invalidImageDimensions(width: Int, height: Int)
    /// Failed to create a `CGImage` from the frame data.
    case cgImageCreationFailed
    /// Failed to create an `ImageIO` destination for writing.
    case destinationCreationFailed
    /// The `ImageIO` finalize step failed (write error).
    case writeFailed
    /// The channel count is not supported for export.
    case unsupportedChannelCount(Int)
    /// Image export is not available on this platform.
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case .invalidImageDimensions(let width, let height):
            return "Invalid image dimensions: \(width)×\(height)"
        case .cgImageCreationFailed:
            return "Failed to create CGImage from frame data"
        case .destinationCreationFailed:
            return "Failed to create image destination"
        case .writeFailed:
            return "Failed to write image data"
        case .unsupportedChannelCount(let count):
            return "Unsupported channel count for export: \(count)"
        case .unsupportedPlatform:
            return "Image export requires Apple platforms (macOS, iOS, tvOS, watchOS, visionOS)"
        }
    }
}

// MARK: - Pixel Conversion (All Platforms)

/// Utilities for converting between planar and interleaved pixel layouts.
///
/// `ImageFrame` stores pixel data in planar format (all R, then all G, then all B).
/// Standard image formats and `CGImage` expect interleaved format (RGBRGBRGB...).
/// These conversion functions bridge the two representations.
public enum PixelConversion {

    /// Convert an `ImageFrame` from planar to interleaved pixel layout.
    ///
    /// The returned byte array contains pixel data in interleaved order:
    /// - Grayscale: `[G0, G1, G2, ...]` or `[G0, A0, G1, A1, ...]`
    /// - RGB: `[R0, G0, B0, R1, G1, B1, ...]`
    /// - RGBA: `[R0, G0, B0, A0, R1, G1, B1, A1, ...]`
    ///
    /// For float32 pixel types, values are converted to uint8 ([0,1] → [0,255]).
    ///
    /// - Parameter frame: The image frame to convert.
    /// - Returns: A tuple of `(data, bytesPerComponent, componentCount)`.
    /// - Throws: `ExporterError` if the frame has invalid dimensions or channels.
    public static func interleave(_ frame: ImageFrame) throws -> (data: [UInt8], bytesPerComponent: Int, componentCount: Int) {
        guard frame.width > 0 && frame.height > 0 else {
            throw ExporterError.invalidImageDimensions(width: frame.width, height: frame.height)
        }
        guard frame.channels == 1 || frame.channels == 3 || frame.channels == 4 else {
            throw ExporterError.unsupportedChannelCount(frame.channels)
        }

        let isGrayscale = frame.channels == 1
        let hasAlpha = frame.hasAlpha && frame.channels >= 3
        let componentCount = isGrayscale ? (hasAlpha ? 2 : 1) : (hasAlpha ? 4 : 3)

        let result: [UInt8]
        let bytesPerComponent: Int

        switch frame.pixelType {
        case .uint8:
            bytesPerComponent = 1
            result = planarToInterleaved8(frame, componentCount: componentCount, hasAlpha: hasAlpha, isGrayscale: isGrayscale)
        case .uint16, .int16:
            bytesPerComponent = 2
            result = planarToInterleaved16(frame, componentCount: componentCount, hasAlpha: hasAlpha, isGrayscale: isGrayscale)
        case .float32:
            bytesPerComponent = 1
            result = planarToInterleavedFloat(frame, componentCount: componentCount, hasAlpha: hasAlpha, isGrayscale: isGrayscale)
        }

        return (result, bytesPerComponent, componentCount)
    }

    // MARK: - uint8 conversion

    /// Converts planar uint8 data to interleaved format.
    internal static func planarToInterleaved8(
        _ frame: ImageFrame,
        componentCount: Int,
        hasAlpha: Bool,
        isGrayscale: Bool
    ) -> [UInt8] {
        let pixelCount = frame.width * frame.height
        var result = [UInt8](repeating: 0, count: pixelCount * componentCount)

        if isGrayscale {
            for i in 0..<pixelCount {
                result[i * componentCount] = frame.data[i]
            }
            if hasAlpha {
                let alphaOffset = frame.channels >= 4 ? 3 * pixelCount : -1
                for i in 0..<pixelCount {
                    result[i * componentCount + 1] = alphaOffset >= 0 ? frame.data[alphaOffset + i] : 255
                }
            }
        } else {
            for i in 0..<pixelCount {
                for c in 0..<min(3, frame.channels) {
                    result[i * componentCount + c] = frame.data[c * pixelCount + i]
                }
                if hasAlpha {
                    let alphaOffset = frame.channels >= 4 ? 3 * pixelCount : -1
                    result[i * componentCount + 3] = alphaOffset >= 0 ? frame.data[alphaOffset + i] : 255
                }
            }
        }

        return result
    }

    // MARK: - uint16 conversion

    /// Converts planar uint16 data to interleaved format.
    internal static func planarToInterleaved16(
        _ frame: ImageFrame,
        componentCount: Int,
        hasAlpha: Bool,
        isGrayscale: Bool
    ) -> [UInt8] {
        let pixelCount = frame.width * frame.height
        let resultCount = pixelCount * componentCount * 2
        var result = [UInt8](repeating: 0, count: resultCount)

        if isGrayscale {
            for i in 0..<pixelCount {
                let srcOffset = i * 2
                let dstOffset = i * componentCount * 2
                result[dstOffset] = frame.data[srcOffset]
                result[dstOffset + 1] = frame.data[srcOffset + 1]
            }
            if hasAlpha {
                let alphaPlaneOffset = frame.channels >= 4 ? 3 * pixelCount * 2 : -1
                for i in 0..<pixelCount {
                    let dstOffset = i * componentCount * 2 + 2
                    if alphaPlaneOffset >= 0 {
                        let srcOffset = alphaPlaneOffset + i * 2
                        result[dstOffset] = frame.data[srcOffset]
                        result[dstOffset + 1] = frame.data[srcOffset + 1]
                    } else {
                        result[dstOffset] = 0xFF
                        result[dstOffset + 1] = 0xFF
                    }
                }
            }
        } else {
            for i in 0..<pixelCount {
                let dstBase = i * componentCount * 2
                for c in 0..<min(3, frame.channels) {
                    let srcOffset = (c * pixelCount + i) * 2
                    let dstOffset = dstBase + c * 2
                    result[dstOffset] = frame.data[srcOffset]
                    result[dstOffset + 1] = frame.data[srcOffset + 1]
                }
                if hasAlpha {
                    let alphaPlaneOffset = frame.channels >= 4 ? 3 * pixelCount * 2 : -1
                    let dstOffset = dstBase + 3 * 2
                    if alphaPlaneOffset >= 0 {
                        let srcOffset = alphaPlaneOffset + i * 2
                        result[dstOffset] = frame.data[srcOffset]
                        result[dstOffset + 1] = frame.data[srcOffset + 1]
                    } else {
                        result[dstOffset] = 0xFF
                        result[dstOffset + 1] = 0xFF
                    }
                }
            }
        }

        return result
    }

    // MARK: - float32 conversion

    /// Converts planar float32 data to interleaved uint8 format.
    /// Float values are expected in [0, 1] range and clamped/scaled to [0, 255].
    internal static func planarToInterleavedFloat(
        _ frame: ImageFrame,
        componentCount: Int,
        hasAlpha: Bool,
        isGrayscale: Bool
    ) -> [UInt8] {
        let pixelCount = frame.width * frame.height
        var result = [UInt8](repeating: 0, count: pixelCount * componentCount)

        if isGrayscale {
            for i in 0..<pixelCount {
                let floatVal = readFloat(from: frame.data, at: i * 4)
                result[i * componentCount] = clampToUInt8(floatVal)
            }
            if hasAlpha {
                let alphaPlaneOffset = frame.channels >= 4 ? 3 * pixelCount * 4 : -1
                for i in 0..<pixelCount {
                    if alphaPlaneOffset >= 0 {
                        let floatVal = readFloat(from: frame.data, at: alphaPlaneOffset + i * 4)
                        result[i * componentCount + 1] = clampToUInt8(floatVal)
                    } else {
                        result[i * componentCount + 1] = 255
                    }
                }
            }
        } else {
            for i in 0..<pixelCount {
                for c in 0..<min(3, frame.channels) {
                    let srcOffset = (c * pixelCount + i) * 4
                    let floatVal = readFloat(from: frame.data, at: srcOffset)
                    result[i * componentCount + c] = clampToUInt8(floatVal)
                }
                if hasAlpha {
                    let alphaPlaneOffset = frame.channels >= 4 ? 3 * pixelCount * 4 : -1
                    if alphaPlaneOffset >= 0 {
                        let floatVal = readFloat(from: frame.data, at: alphaPlaneOffset + i * 4)
                        result[i * componentCount + 3] = clampToUInt8(floatVal)
                    } else {
                        result[i * componentCount + 3] = 255
                    }
                }
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Read a Float32 value from a byte array at the given offset (little-endian).
    internal static func readFloat(from data: [UInt8], at offset: Int) -> Float {
        let bits = UInt32(data[offset]) |
                   (UInt32(data[offset + 1]) << 8) |
                   (UInt32(data[offset + 2]) << 16) |
                   (UInt32(data[offset + 3]) << 24)
        return Float(bitPattern: bits)
    }

    /// Clamp a float value (assumed [0, 1]) to a UInt8 in [0, 255].
    internal static func clampToUInt8(_ value: Float) -> UInt8 {
        return UInt8(max(0, min(255, Int(value * 255 + 0.5))))
    }
}

// MARK: - Image Exporter (Apple Platforms)

#if canImport(CoreGraphics) && canImport(ImageIO)

import CoreGraphics
import ImageIO

extension OutputFormat {
    /// The CoreGraphics UTI type identifier for this format.
    var utiType: CFString {
        switch self {
        case .png: return "public.png" as CFString
        case .tiff: return "public.tiff" as CFString
        case .bmp: return "com.microsoft.bmp" as CFString
        }
    }
}

/// Exports an `ImageFrame` to standard image formats using platform image I/O.
///
/// Supports PNG, TIFF, and BMP output formats. Handles uint8, uint16, and float32
/// pixel types, as well as grayscale (1 channel), RGB (3 channels), and
/// RGBA (3 channels + alpha) images.
///
/// ```swift
/// let frame = try decoder.decode(codestream)
/// let pngData = try ImageExporter.export(frame, format: .png)
/// try ImageExporter.export(frame, to: URL(fileURLWithPath: "output.png"))
/// ```
public enum ImageExporter {

    // MARK: - Public API

    /// Export an `ImageFrame` to in-memory data in the specified format.
    ///
    /// - Parameters:
    ///   - frame: The image frame to export.
    ///   - format: The target output format.
    /// - Returns: The encoded image data.
    /// - Throws: `ExporterError` if the image cannot be converted or written.
    public static func export(_ frame: ImageFrame, format: OutputFormat) throws -> Data {
        let cgImage = try createCGImage(from: frame)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            format.utiType,
            1,
            nil
        ) else {
            throw ExporterError.destinationCreationFailed
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExporterError.writeFailed
        }
        return data as Data
    }

    /// Export an `ImageFrame` to a file in the specified format.
    ///
    /// If `format` is `nil`, the format is inferred from the file extension.
    ///
    /// - Parameters:
    ///   - frame: The image frame to export.
    ///   - url: The destination file URL.
    ///   - format: The target output format, or `nil` to auto-detect from extension.
    /// - Throws: `ExporterError` if the format is unrecognized or the write fails.
    public static func export(_ frame: ImageFrame, to url: URL, format: OutputFormat? = nil) throws {
        let resolvedFormat: OutputFormat
        if let format = format {
            resolvedFormat = format
        } else if let detected = OutputFormat.from(fileExtension: url.pathExtension) {
            resolvedFormat = detected
        } else {
            resolvedFormat = .png
        }
        let data = try export(frame, format: resolvedFormat)
        try data.write(to: url)
    }

    /// Convert an `ImageFrame` to a `CGImage`.
    ///
    /// The resulting `CGImage` can be used directly with AppKit, UIKit, or SwiftUI.
    /// The pixel data is converted from planar to interleaved format as needed.
    ///
    /// - Parameter frame: The image frame to convert.
    /// - Returns: A `CGImage` representing the frame.
    /// - Throws: `ExporterError` if the image cannot be created.
    public static func createCGImage(from frame: ImageFrame) throws -> CGImage {
        let (interleaved, bytesPerComponent, componentCount) = try PixelConversion.interleave(frame)

        let bitsPerComponent = bytesPerComponent * 8
        let bitsPerPixel = bitsPerComponent * componentCount
        let bytesPerRow = frame.width * componentCount * bytesPerComponent

        let isGrayscale = frame.channels == 1
        let hasAlpha = frame.hasAlpha && frame.channels >= 3

        let colorSpace: CGColorSpace
        if isGrayscale {
            colorSpace = CGColorSpaceCreateDeviceGray()
        } else {
            colorSpace = CGColorSpaceCreateDeviceRGB()
        }

        var bitmapInfo: UInt32 = 0
        if hasAlpha {
            if frame.alphaMode == .premultiplied {
                bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            } else {
                bitmapInfo = CGImageAlphaInfo.last.rawValue
            }
        } else {
            bitmapInfo = CGImageAlphaInfo.none.rawValue
        }
        if bytesPerComponent == 2 {
            bitmapInfo |= CGBitmapInfo.byteOrder16Little.rawValue
        }

        guard let provider = CGDataProvider(data: Data(interleaved) as CFData) else {
            throw ExporterError.cgImageCreationFailed
        }

        guard let cgImage = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw ExporterError.cgImageCreationFailed
        }

        return cgImage
    }
}

#else

// MARK: - Unavailable Stubs (Non-Apple Platforms)

/// Image exporter — unavailable on non-Apple platforms.
///
/// On Linux and other non-Apple platforms, image export requires
/// CoreGraphics and ImageIO which are not available.
public enum ImageExporter {
    /// Export is not available on this platform.
    public static func export(_ frame: ImageFrame, format: OutputFormat) throws -> Data {
        throw ExporterError.unsupportedPlatform
    }

    /// Export is not available on this platform.
    public static func export(_ frame: ImageFrame, to url: URL, format: OutputFormat? = nil) throws {
        throw ExporterError.unsupportedPlatform
    }
}

#endif
