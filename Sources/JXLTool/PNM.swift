// PNM — minimal Portable AnyMap reader/writer for the CLI.
//
// We support the binary variants:
//   • P5 — binary grayscale (PGM)
//   • P6 — binary RGB     (PPM)
//
// Header form (no comments / multiline whitespace tolerated):
//
//     P5\n<width> <height>\n<maxval>\n<binary_data>
//
// `maxval` selects sample width:
//   • maxval ≤ 255   → 1 byte per sample
//   • maxval ≤ 65535 → 2 bytes per sample, **big-endian**
//
// PNM is widely supported by ImageMagick / Pillow / netpbm tools, so
// users can convert PNG ↔ PNM at the shell with one command and feed
// real pixels through the JXLSwift M0 path:
//
//     convert input.png input.pgm
//     jxl-tool encode-m0 -i input.pgm -o out.m0
//     jxl-tool decode-m0 -i out.m0 -o out.pgm
//     diff input.pgm out.pgm   # → no output

import Foundation
import JXLSwift

enum PNMError: Error, CustomStringConvertible {
    case unsupportedMagic(String)
    case malformedHeader(String)
    case truncated
    case invalidMaxval(Int)
    case unsupportedChannelCount(Int)

    var description: String {
        switch self {
        case .unsupportedMagic(let m):
            return "PNM: unsupported magic '\(m)'; only P5 (PGM) and P6 (PPM) supported"
        case .malformedHeader(let why):
            return "PNM: malformed header — \(why)"
        case .truncated:
            return "PNM: file truncated before all pixel data was read"
        case .invalidMaxval(let v):
            return "PNM: maxval \(v) out of range (must be 1…65535)"
        case .unsupportedChannelCount(let c):
            return "PNM: unsupported channel count \(c) (only 1 grayscale or 3 RGB)"
        }
    }
}

enum PNM {

    /// Decode a binary PNM file into an `ImageFrame`.
    static func read(_ data: Data) throws -> ImageFrame {
        // Step 1: parse the header. We need three whitespace-separated
        // tokens after the 2-character magic: width, height, maxval.
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw PNMError.malformedHeader("buffer too short") }
        let magic = String(bytes: bytes[0..<2], encoding: .ascii) ?? ""
        let isRGB: Bool
        switch magic {
        case "P5": isRGB = false
        case "P6": isRGB = true
        default: throw PNMError.unsupportedMagic(magic)
        }

        var i = 2
        func skipWhitespace() {
            while i < bytes.count && (bytes[i] == 0x20 || bytes[i] == 0x09
                                   || bytes[i] == 0x0A || bytes[i] == 0x0D) {
                i += 1
            }
        }
        func readToken() throws -> String {
            skipWhitespace()
            let start = i
            while i < bytes.count && bytes[i] != 0x20 && bytes[i] != 0x09
               && bytes[i] != 0x0A && bytes[i] != 0x0D {
                i += 1
            }
            guard i > start else { throw PNMError.malformedHeader("expected token") }
            return String(bytes: bytes[start..<i], encoding: .ascii) ?? ""
        }
        guard let width  = Int(try readToken()) else {
            throw PNMError.malformedHeader("width is not an integer")
        }
        guard let height = Int(try readToken()) else {
            throw PNMError.malformedHeader("height is not an integer")
        }
        guard let maxval = Int(try readToken()) else {
            throw PNMError.malformedHeader("maxval is not an integer")
        }
        guard maxval >= 1 && maxval <= 65535 else {
            throw PNMError.invalidMaxval(maxval)
        }
        // The byte immediately after maxval is a single whitespace
        // (newline). The pixel data begins right after that.
        guard i < bytes.count else { throw PNMError.truncated }
        guard bytes[i] == 0x20 || bytes[i] == 0x09
           || bytes[i] == 0x0A || bytes[i] == 0x0D else {
            throw PNMError.malformedHeader(
                "expected whitespace after maxval, got byte 0x\(String(bytes[i], radix: 16))"
            )
        }
        i += 1

        // Step 2: ingest pixels.
        let channels = isRGB ? 3 : 1
        let pixelType: PixelType = (maxval > 255) ? .uint16 : .uint8
        let bytesPerSample = pixelType.bytesPerSample
        let pixelByteCount = width * height * channels * bytesPerSample
        guard bytes.count - i >= pixelByteCount else { throw PNMError.truncated }

        var frame = ImageFrame(
            width: width, height: height, channels: channels,
            pixelType: pixelType,
            colorSpace: isRGB ? .sRGB : .grayscale
        )
        if pixelType == .uint8 {
            // Direct copy.
            for k in 0..<pixelByteCount {
                frame.data[k] = bytes[i + k]
            }
        } else {
            // 16-bit big-endian → little-endian within ImageFrame.data.
            for k in 0..<(width * height * channels) {
                let hi = bytes[i + k * 2]
                let lo = bytes[i + k * 2 + 1]
                frame.data[k * 2]     = lo
                frame.data[k * 2 + 1] = hi
            }
        }
        return frame
    }

    /// Encode an `ImageFrame` to a binary PNM (PGM for grayscale, PPM
    /// for RGB).
    static func write(_ frame: ImageFrame) throws -> Data {
        guard frame.channels == 1 || frame.channels == 3 else {
            throw PNMError.unsupportedChannelCount(frame.channels)
        }
        guard frame.pixelType == .uint8 || frame.pixelType == .uint16 else {
            throw PNMError.malformedHeader(
                "unsupported pixel type \(frame.pixelType) (only uint8/uint16)"
            )
        }
        let magic = (frame.channels == 1) ? "P5" : "P6"
        let maxval = (frame.pixelType == .uint8) ? 255 : 65535
        var out = Data()
        out.append(Data("\(magic)\n\(frame.width) \(frame.height)\n\(maxval)\n".utf8))
        if frame.pixelType == .uint8 {
            out.append(Data(frame.data))
        } else {
            // ImageFrame stores uint16 little-endian. PNM is big-endian.
            for k in 0..<(frame.width * frame.height * frame.channels) {
                out.append(frame.data[k * 2 + 1])
                out.append(frame.data[k * 2])
            }
        }
        return out
    }
}
