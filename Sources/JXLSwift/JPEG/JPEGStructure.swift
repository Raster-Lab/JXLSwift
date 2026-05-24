// High-level structural extraction from a JPEG file. Just the
// fields a transcoder or "jxl info"-style caller needs to decide
// what they're looking at — pixel data, Huffman tables, and
// quantisation tables stay opaque at this layer.
//
// Reads what's in the SOFn segment, counts DQT / DHT tables, picks
// up the JFIF / EXIF / Adobe APP markers, and notes whether the
// scan is baseline or progressive.

import Foundation

/// Lightweight structural description of a JPEG file — the kind
/// of summary `jxl info` prints, without doing any entropy decode.
public struct JPEGStructure: Sendable, Equatable {
    /// Image width in pixels (samples per line) — from the SOFn
    /// `X` field. `0` means "to be defined by DNL marker" (rare).
    public let width: Int
    /// Image height in pixels (number of lines) — from the SOFn
    /// `Y` field. `0` means "to be defined by DNL marker".
    public let height: Int
    /// Samples per pixel (component count). 1 = grayscale,
    /// 3 = YCbCr / RGB, 4 = CMYK / YCCK.
    public let componentCount: Int
    /// Bit precision per sample — `P` field of SOFn. Typically 8;
    /// 12-bit appears in lossless / extended modes.
    public let precision: Int
    /// Which SOFn the encoder picked — distinguishes baseline
    /// (SOF0), extended sequential (SOF1), progressive (SOF2),
    /// lossless (SOF3), etc.
    public let frameKind: FrameKind
    /// How many DQT marker payloads we saw. JPEG segments may
    /// declare more than one table per DQT — this is the marker
    /// count, not the table count.
    public let dqtSegmentCount: Int
    /// How many DHT marker payloads we saw.
    public let dhtSegmentCount: Int
    /// `true` iff a JFIF APP0 marker (`"JFIF\0"` magic) was seen.
    public let hasJFIF: Bool
    /// `true` iff an EXIF APP1 marker (`"Exif\0\0"` magic) was seen.
    public let hasEXIF: Bool
    /// `true` iff an Adobe APP14 marker was seen.
    public let hasAdobe: Bool
    /// `true` iff at least one DAC (arithmetic conditioning)
    /// segment was present — arithmetic-coded JPEGs are rare and
    /// the transcoder will need to handle them differently.
    public let usesArithmeticCoding: Bool
    /// `true` iff a DRI marker declared a non-zero restart
    /// interval.
    public let hasRestartInterval: Bool

    public enum FrameKind: Sendable, Equatable {
        case baselineDCT          // SOF0
        case extendedSequential   // SOF1
        case progressiveDCT       // SOF2
        case lossless             // SOF3
        case other(nibble: Int)   // SOF5..SOF15 (differential /
                                  // arithmetic variants)

        public init(nibble: Int) {
            switch nibble {
            case 0: self = .baselineDCT
            case 1: self = .extendedSequential
            case 2: self = .progressiveDCT
            case 3: self = .lossless
            default: self = .other(nibble: nibble)
            }
        }

        public var label: String {
            switch self {
            case .baselineDCT: return "baseline DCT (SOF0)"
            case .extendedSequential:
                return "extended sequential (SOF1)"
            case .progressiveDCT:
                return "progressive DCT (SOF2)"
            case .lossless: return "lossless (SOF3)"
            case .other(let n):
                return "SOF\(n) (differential / variant)"
            }
        }
    }

    /// Extract structural fields by walking the segment stream.
    /// `data` must be a complete JPEG file beginning with SOI.
    public static func read(_ data: Data) throws -> JPEGStructure {
        var reader = JPEGSegmentReader(data)
        var width = 0, height = 0, comp = 0, prec = 0
        var frameKind: FrameKind = .baselineDCT
        var dqtCount = 0, dhtCount = 0
        var hasJFIF = false, hasEXIF = false, hasAdobe = false
        var hasArith = false, hasRestart = false
        var sawSOF = false

        while let seg = try reader.next() {
            switch seg.kind {
            case .endOfImage: break
            case .startOfFrame(let n):
                guard !sawSOF else {
                    // Hierarchical / multi-frame JPEG — fall
                    // through with the first SOF; transcoder
                    // case can revisit later.
                    continue
                }
                try parseSOF(payload: seg.payload,
                             nibble: n,
                             precision: &prec,
                             height: &height,
                             width: &width,
                             componentCount: &comp,
                             frameKind: &frameKind)
                sawSOF = true
            case .defineQuantizationTable:
                dqtCount += 1
            case .defineHuffmanTable:
                dhtCount += 1
            case .defineArithmeticConditioning:
                hasArith = true
            case .defineRestartInterval:
                if seg.payload.count == 2 {
                    let interval = (Int(seg.payload[0]) << 8)
                        | Int(seg.payload[1])
                    if interval != 0 { hasRestart = true }
                }
            case .applicationSegment(let n):
                if n == 0, hasJFIFMagic(seg.payload) {
                    hasJFIF = true
                }
                if n == 1, hasEXIFMagic(seg.payload) {
                    hasEXIF = true
                }
                if n == 14, hasAdobeMagic(seg.payload) {
                    hasAdobe = true
                }
            default:
                break
            }
        }

        return JPEGStructure(
            width: width, height: height,
            componentCount: comp, precision: prec,
            frameKind: frameKind,
            dqtSegmentCount: dqtCount,
            dhtSegmentCount: dhtCount,
            hasJFIF: hasJFIF, hasEXIF: hasEXIF,
            hasAdobe: hasAdobe,
            usesArithmeticCoding: hasArith,
            hasRestartInterval: hasRestart)
    }

    // MARK: - private

    /// SOFn payload layout (ITU-T T.81 §B.2.2):
    ///   P (1B)   precision
    ///   Y (2B)   number of lines = height (big-endian)
    ///   X (2B)   samples per line = width (big-endian)
    ///   Nf (1B)  number of components
    ///   then Nf × (Ci, Hi/Vi packed, Tqi) — we don't need those
    ///   for structural summary.
    private static func parseSOF(
        payload: Data, nibble: Int,
        precision: inout Int, height: inout Int,
        width: inout Int, componentCount: inout Int,
        frameKind: inout FrameKind
    ) throws {
        guard payload.count >= 6 else {
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xC0 | UInt8(nibble),
                length: payload.count + 2)
        }
        precision = Int(payload[0])
        height = (Int(payload[1]) << 8) | Int(payload[2])
        width = (Int(payload[3]) << 8) | Int(payload[4])
        componentCount = Int(payload[5])
        frameKind = FrameKind(nibble: nibble)
    }

    private static func hasJFIFMagic(_ p: Data) -> Bool {
        // "JFIF\0" — 5 bytes
        guard p.count >= 5 else { return false }
        return p[0] == 0x4A && p[1] == 0x46 && p[2] == 0x49
            && p[3] == 0x46 && p[4] == 0x00
    }
    private static func hasEXIFMagic(_ p: Data) -> Bool {
        // "Exif\0\0" — 6 bytes
        guard p.count >= 6 else { return false }
        return p[0] == 0x45 && p[1] == 0x78 && p[2] == 0x69
            && p[3] == 0x66 && p[4] == 0x00 && p[5] == 0x00
    }
    private static func hasAdobeMagic(_ p: Data) -> Bool {
        // "Adobe" — 5 bytes
        guard p.count >= 5 else { return false }
        return p[0] == 0x41 && p[1] == 0x64 && p[2] == 0x6F
            && p[3] == 0x62 && p[4] == 0x65
    }
}
