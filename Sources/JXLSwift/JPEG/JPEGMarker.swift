// JPEG marker codes — first step on the Phase J (JXL ↔ JPEG
// reversible transcoding) road. This file is intentionally *just*
// the marker enum + a few helpers; segment walking lives in
// `JPEGSegmentReader.swift` and high-level structural extraction
// in `JPEGStructure.swift`.
//
// All marker codes per ITU-T T.81 / ISO/IEC 10918-1 §B.1.1 Table
// B.1. A JPEG marker is the byte 0xFF followed by a single
// non-0xFF, non-0x00 byte. Any number of consecutive 0xFF bytes
// before that distinguishing byte are "fill bytes" and ignored
// (§B.1.1.2). Inside entropy-coded data, 0xFF is byte-stuffed as
// 0xFF 0x00 to keep it from being mistaken for a marker
// (§F.1.2.3).

import Foundation

/// The high-level kind of a JPEG marker. Used to decide how to
/// read past a marker — stand-alone markers (SOI, EOI, RSTn, TEM)
/// have no payload; everything else has a 2-byte big-endian
/// length followed by length-2 bytes of payload (the length field
/// counts itself).
package enum JPEGMarkerKind: Sendable, Equatable {
    /// Start of image — must be the first marker.
    case startOfImage
    /// End of image — must be the last marker.
    case endOfImage
    /// Start-of-frame: baseline / extended / progressive / lossless
    /// DCT, with the differential variants. `nibble` is the low
    /// nibble of the marker byte (0..15), e.g. 0 for SOF0
    /// (baseline) and 2 for SOF2 (progressive DCT).
    case startOfFrame(nibble: Int)
    /// Define Huffman table(s).
    case defineHuffmanTable
    /// Define quantisation table(s).
    case defineQuantizationTable
    /// Start of scan — followed by entropy-coded data until the
    /// next non-RSTn marker.
    case startOfScan
    /// Define restart interval.
    case defineRestartInterval
    /// Restart marker, n ∈ 0..7.
    case restart(n: Int)
    /// Application-specific segment, n ∈ 0..15 (APP0..APP15).
    case applicationSegment(n: Int)
    /// Comment segment.
    case comment
    /// Temporary marker — has no payload (arithmetic-coded-only
    /// use; vanishingly rare in real files).
    case temporary
    /// Define arithmetic conditioning table — encountered only
    /// in arithmetic-coded JPEGs (uncommon outside specific
    /// industry pipelines).
    case defineArithmeticConditioning
    /// Define number of lines (rarely present; sometimes appended
    /// before SOS when the SOF height field is initially zero).
    case defineNumberOfLines
    /// Define hierarchical progression.
    case defineHierarchicalProgression
    /// Expand reference component.
    case expandReferenceComponent
    /// Any other reserved / non-stand-alone JPEG marker we haven't
    /// modelled yet — preserves the raw marker byte so the segment
    /// reader can still skip past it.
    case other(markerByte: UInt8)

    /// Stand-alone markers carry no payload — the next byte is the
    /// start of the following marker or entropy data.
    package var isStandalone: Bool {
        switch self {
        case .startOfImage, .endOfImage, .restart, .temporary:
            return true
        default:
            return false
        }
    }

    /// Identify a marker from its single distinguishing byte (the
    /// byte that follows one or more 0xFF padding bytes). Never
    /// returns nil — unknown marker codes fall through to
    /// `.other(markerByte:)` so the segment reader can still skip
    /// them by length.
    package static func from(markerByte b: UInt8) -> JPEGMarkerKind {
        switch b {
        case 0xD8: return .startOfImage
        case 0xD9: return .endOfImage
        case 0xD0...0xD7: return .restart(n: Int(b - 0xD0))
        case 0xC4: return .defineHuffmanTable
        case 0xCC: return .defineArithmeticConditioning
        case 0xDB: return .defineQuantizationTable
        case 0xDA: return .startOfScan
        case 0xDD: return .defineRestartInterval
        case 0xE0...0xEF:
            return .applicationSegment(n: Int(b - 0xE0))
        case 0xFE: return .comment
        case 0x01: return .temporary
        case 0xDC: return .defineNumberOfLines
        case 0xDE: return .defineHierarchicalProgression
        case 0xDF: return .expandReferenceComponent
        // SOFn occupy 0xC0..0xCF except 0xC4 (DHT), 0xC8 (reserved
        // for JPG extensions but not a SOF in practice), and 0xCC
        // (DAC, handled above).
        case 0xC0...0xC3, 0xC5...0xC7, 0xC9...0xCB, 0xCD...0xCF:
            return .startOfFrame(nibble: Int(b & 0x0F))
        default:
            return .other(markerByte: b)
        }
    }

    /// Human-readable label, for diagnostics.
    package var label: String {
        switch self {
        case .startOfImage: return "SOI"
        case .endOfImage: return "EOI"
        case .startOfFrame(let n): return "SOF\(n)"
        case .defineHuffmanTable: return "DHT"
        case .defineQuantizationTable: return "DQT"
        case .startOfScan: return "SOS"
        case .defineRestartInterval: return "DRI"
        case .restart(let n): return "RST\(n)"
        case .applicationSegment(let n): return "APP\(n)"
        case .comment: return "COM"
        case .temporary: return "TEM"
        case .defineArithmeticConditioning: return "DAC"
        case .defineNumberOfLines: return "DNL"
        case .defineHierarchicalProgression: return "DHP"
        case .expandReferenceComponent: return "EXP"
        case .other(let b):
            return "0x\(String(b, radix: 16, uppercase: true))"
        }
    }
}
