// PNM — minimal Portable AnyMap reader/writer for the CLI.
//
// We support the binary variants:
//   • P5 — binary grayscale       (PGM, 1 channel)
//   • P6 — binary RGB             (PPM, 3 channels)
//   • P7 — Portable AnyMap        (PAM, 1–4 channels with optional alpha)
//
// PGM/PPM header form (no comments / multiline whitespace tolerated):
//
//     P5\n<width> <height>\n<maxval>\n<binary_data>
//
// PAM (P7) header form — needed for alpha-bearing images since plain
// PGM/PPM don't carry alpha:
//
//     P7\n
//     WIDTH <w>\n
//     HEIGHT <h>\n
//     DEPTH <channels>\n
//     MAXVAL <maxval>\n
//     TUPLTYPE <type>\n               // RGB_ALPHA, GRAYSCALE_ALPHA,
//                                     // RGB, GRAYSCALE
//     ENDHDR\n
//     <binary_data>
//
// `maxval` selects sample width in either form:
//   • maxval ≤ 255   → 1 byte per sample
//   • maxval ≤ 65535 → 2 bytes per sample, **big-endian**
//
// PNM/PAM are widely supported by ImageMagick / Pillow / netpbm
// tools, so users can convert PNG ↔ PNM at the shell with one
// command and feed real pixels through the JXLSwift M0 path:
//
//     convert input.png input.pgm        # 1ch
//     convert input.png input.ppm        # 3ch
//     convert input.png input.pam        # 1–4ch (with alpha)
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

    /// Decode a binary PNM file (P5 / P6 / P7) into an `ImageFrame`.
    static func read(_ data: Data) throws -> ImageFrame {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw PNMError.malformedHeader("buffer too short") }
        let magic = String(bytes: bytes[0..<2], encoding: .ascii) ?? ""
        switch magic {
        case "P5": return try readPGMOrPPM(bytes, isRGB: false)
        case "P6": return try readPGMOrPPM(bytes, isRGB: true)
        case "P7": return try readPAM(bytes)
        default:   throw PNMError.unsupportedMagic(magic)
        }
    }

    private static func readPGMOrPPM(_ bytes: [UInt8], isRGB: Bool) throws -> ImageFrame {
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
        guard i < bytes.count else { throw PNMError.truncated }
        guard bytes[i] == 0x20 || bytes[i] == 0x09
           || bytes[i] == 0x0A || bytes[i] == 0x0D else {
            throw PNMError.malformedHeader(
                "expected whitespace after maxval, got byte 0x\(String(bytes[i], radix: 16))"
            )
        }
        i += 1
        return try ingestPixels(
            bytes, offset: i, width: width, height: height,
            channels: isRGB ? 3 : 1,
            alphaChannels: 0, maxval: maxval, isRGB: isRGB
        )
    }

    private static func readPAM(_ bytes: [UInt8]) throws -> ImageFrame {
        // PAM: line-based header. We need WIDTH, HEIGHT, DEPTH,
        // MAXVAL — TUPLTYPE is informational and helps us label the
        // ColorSpace. Header ends at a line containing exactly
        // "ENDHDR\n", and the binary data begins right after that.
        var i = 3   // skip "P7\n"
        var width: Int?, height: Int?, depth: Int?, maxval: Int?, tupltype: String?
        func readLine() throws -> String {
            let start = i
            while i < bytes.count && bytes[i] != 0x0A {
                i += 1
            }
            guard i < bytes.count else { throw PNMError.truncated }
            let line = String(bytes: bytes[start..<i], encoding: .ascii) ?? ""
            i += 1   // consume the newline
            return line.trimmingCharacters(in: .whitespaces)
        }
        while i < bytes.count {
            let line = try readLine()
            if line == "ENDHDR" { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw PNMError.malformedHeader("PAM header line: '\(line)'")
            }
            let key = parts[0].uppercased()
            let val = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "WIDTH":    width = Int(val)
            case "HEIGHT":   height = Int(val)
            case "DEPTH":    depth = Int(val)
            case "MAXVAL":   maxval = Int(val)
            case "TUPLTYPE": tupltype = val
            default:         break    // informational
            }
        }
        guard let w = width, let h = height, let d = depth, let m = maxval else {
            throw PNMError.malformedHeader("PAM missing WIDTH/HEIGHT/DEPTH/MAXVAL")
        }
        guard m >= 1 && m <= 65535 else { throw PNMError.invalidMaxval(m) }
        guard (1...4).contains(d) else { throw PNMError.unsupportedChannelCount(d) }
        let isRGB: Bool
        let alphaChannels: Int
        switch (d, tupltype?.uppercased()) {
        case (1, _):                                    isRGB = false; alphaChannels = 0
        case (2, _):                                    isRGB = false; alphaChannels = 1
        case (3, "RGB"), (3, .none), (3, _):            isRGB = true;  alphaChannels = 0
        case (4, _):                                    isRGB = true;  alphaChannels = 1
        default:                                        throw PNMError.unsupportedChannelCount(d)
        }
        return try ingestPixels(
            bytes, offset: i, width: w, height: h,
            channels: d, alphaChannels: alphaChannels, maxval: m, isRGB: isRGB
        )
    }

    private static func ingestPixels(
        _ bytes: [UInt8], offset i: Int,
        width: Int, height: Int, channels: Int, alphaChannels: Int,
        maxval: Int, isRGB: Bool
    ) throws -> ImageFrame {
        let pixelType: PixelType = (maxval > 255) ? .uint16 : .uint8
        let bytesPerSample = pixelType.bytesPerSample
        let pixelByteCount = width * height * channels * bytesPerSample
        guard bytes.count - i >= pixelByteCount else { throw PNMError.truncated }

        var frame = ImageFrame(
            width: width, height: height, channels: channels,
            pixelType: pixelType,
            colorSpace: isRGB ? .sRGB : .grayscale,
            alphaChannels: alphaChannels
        )
        if pixelType == .uint8 {
            for k in 0..<pixelByteCount {
                frame.data[k] = bytes[i + k]
            }
        } else {
            for k in 0..<(width * height * channels) {
                let hi = bytes[i + k * 2]
                let lo = bytes[i + k * 2 + 1]
                frame.data[k * 2]     = lo
                frame.data[k * 2 + 1] = hi
            }
        }
        return frame
    }

    /// Encode an `ImageFrame` to a binary PNM (PGM for 1ch, PPM for
    /// 3ch, PAM for 2ch / 4ch — PNM doesn't natively carry alpha).
    static func write(_ frame: ImageFrame) throws -> Data {
        guard (1...4).contains(frame.channels) else {
            throw PNMError.unsupportedChannelCount(frame.channels)
        }
        guard frame.pixelType == .uint8 || frame.pixelType == .uint16 else {
            throw PNMError.malformedHeader(
                "unsupported pixel type \(frame.pixelType) (only uint8/uint16)"
            )
        }
        let maxval = (frame.pixelType == .uint8) ? 255 : 65535
        var out = Data()

        switch frame.channels {
        case 1:
            out.append(Data("P5\n\(frame.width) \(frame.height)\n\(maxval)\n".utf8))
        case 3:
            out.append(Data("P6\n\(frame.width) \(frame.height)\n\(maxval)\n".utf8))
        default:
            // 2ch (gray + alpha) or 4ch (RGBA) → PAM.
            let tupltype: String
            switch frame.channels {
            case 2: tupltype = "GRAYSCALE_ALPHA"
            case 4: tupltype = "RGB_ALPHA"
            default: tupltype = "UNKNOWN"
            }
            let header = """
                P7
                WIDTH \(frame.width)
                HEIGHT \(frame.height)
                DEPTH \(frame.channels)
                MAXVAL \(maxval)
                TUPLTYPE \(tupltype)
                ENDHDR

                """
            out.append(Data(header.utf8))
        }

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
