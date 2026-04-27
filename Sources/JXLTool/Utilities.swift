// Shared CLI utilities: stderr stream, byte formatter, ImageIO loader/saver.

import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
#endif
import JXLSwift

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
    return String(format: "%.2f MB", Double(bytes) / (1024 * 1024))
}

struct StandardError: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}
nonisolated(unsafe) var standardError = StandardError()

#if canImport(ImageIO)
/// Load PNG/JPEG/TIFF/BMP from disk into an `ImageFrame`. Auto-selects
/// grayscale vs RGB based on the source colour space; alpha is preserved
/// when present.
func loadImageFrame(from url: URL) -> ImageFrame? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = cg.width, h = cg.height
    let isGray = (cg.colorSpace?.model == .monochrome)
    let hasAlpha = cg.alphaInfo != .none && cg.alphaInfo != .noneSkipFirst && cg.alphaInfo != .noneSkipLast

    if isGray {
        let channels = hasAlpha ? 2 : 1
        var bytes = [UInt8](repeating: 0, count: w * h * channels)
        let cs = CGColorSpaceCreateDeviceGray()
        let bitmap = hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.none.rawValue
        let ok = bytes.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * channels,
                space: cs, bitmapInfo: bitmap
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var frame = ImageFrame(
            width: w, height: h, channels: channels,
            pixelType: .uint8, colorSpace: .grayscale,
            alphaChannels: hasAlpha ? 1 : 0
        )
        frame.data = bytes
        return frame
    } else {
        let channels = hasAlpha ? 4 : 3
        var bytes = [UInt8](repeating: 0, count: w * h * channels)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmap = (hasAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue)
            | CGBitmapInfo.byteOrder32Big.rawValue
        // CoreGraphics RGB contexts always have 4 bytes/pixel; if we want 3
        // channels in the output, we split into RGBA→RGB after draw.
        let cgBytesPerPixel = 4
        var rgba = [UInt8](repeating: 0, count: w * h * cgBytesPerPixel)
        let ok = rgba.withUnsafeMutableBufferPointer { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * cgBytesPerPixel,
                space: cs, bitmapInfo: bitmap
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        if channels == 4 {
            bytes = rgba
        } else {
            for i in 0..<(w * h) {
                bytes[i * 3]     = rgba[i * 4]
                bytes[i * 3 + 1] = rgba[i * 4 + 1]
                bytes[i * 3 + 2] = rgba[i * 4 + 2]
            }
        }
        var frame = ImageFrame(
            width: w, height: h, channels: channels,
            pixelType: .uint8, colorSpace: .sRGB,
            alphaChannels: hasAlpha ? 1 : 0
        )
        frame.data = bytes
        return frame
    }
}

/// Write a decoded `ImageFrame` to a PNG file (8-bit only for now).
func writePNG(_ frame: ImageFrame, to url: URL) -> Bool {
    guard frame.pixelType == .uint8 else { return false }
    let cs: CGColorSpace = (frame.channels <= 2)
        ? CGColorSpaceCreateDeviceGray()
        : CGColorSpaceCreateDeviceRGB()
    let bitmapInfo: UInt32
    let bitsPerPixel: Int
    switch frame.channels {
    case 1: bitmapInfo = CGImageAlphaInfo.none.rawValue
            bitsPerPixel = 8
    case 2: bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            bitsPerPixel = 16
    case 3: bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            bitsPerPixel = 32
    case 4: bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            bitsPerPixel = 32
    default: return false
    }
    // For 3-channel RGB, CG needs an RGBA buffer (skip alpha).
    var bufferBytes: [UInt8]
    var bytesPerRow: Int
    if frame.channels == 3 {
        bufferBytes = [UInt8](repeating: 0, count: frame.width * frame.height * 4)
        bytesPerRow = frame.width * 4
        for i in 0..<(frame.width * frame.height) {
            bufferBytes[i * 4]     = frame.data[i * 3]
            bufferBytes[i * 4 + 1] = frame.data[i * 3 + 1]
            bufferBytes[i * 4 + 2] = frame.data[i * 3 + 2]
        }
    } else {
        bufferBytes = frame.data
        bytesPerRow = frame.bytesPerRow
    }
    guard let provider = CGDataProvider(data: Data(bufferBytes) as CFData) else { return false }
    guard let cgImage = CGImage(
        width: frame.width, height: frame.height,
        bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
        bytesPerRow: bytesPerRow,
        space: cs, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
        provider: provider, decode: nil, shouldInterpolate: false,
        intent: .defaultIntent
    ) else { return false }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, cgImage, nil)
    return CGImageDestinationFinalize(dest)
}
#endif
