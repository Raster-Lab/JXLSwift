// Parse the per-component records that follow the basic SOFn
// header fields, and the full SOS (start-of-scan) header — the
// last structural step on the Phase J road before the entropy
// decoder takes over.
//
// SOFn per-component record (ITU-T T.81 §B.2.2):
//   u(8) Ci   — component identifier (1..255 per the spec, but
//               JFIF emitters typically use 1=Y, 2=Cb, 3=Cr)
//   u(4) Hi   — horizontal sampling factor (1..4)
//   u(4) Vi   — vertical sampling factor (1..4)
//   u(8) Tqi  — quant-table destination ID for this component
//
// SOS header (ITU-T T.81 §B.2.3):
//   u(8) Ns   — number of components in scan
//   Ns × (u(8) Cs_j + u(4) Td_j + u(4) Ta_j)
//   u(8) Ss   — start of spectral selection (0 for sequential)
//   u(8) Se   — end of spectral selection (63 for sequential)
//   u(4) Ah   — successive-approximation high bit (0 for seq.)
//   u(4) Al   — successive-approximation low bit (0 for seq.)

import Foundation

/// Per-component description from the SOFn header — sampling
/// factors + which quant table to pull factors from.
package struct JPEGFrameComponent: Sendable, Equatable {
    package let componentId: Int
    package let hSamplingFactor: Int  // 1..4
    package let vSamplingFactor: Int  // 1..4
    package let quantTableId: Int     // 0..3
}

/// Per-component scan binding from the SOS header — which DC and
/// AC Huffman tables to use for this component in this scan.
package struct JPEGScanComponent: Sendable, Equatable {
    package let componentId: Int
    package let dcTableId: Int        // 0..3
    package let acTableId: Int        // 0..3
}

/// One JPEG scan header — describes a chunk of entropy-coded data
/// in terms of which components it covers, which Huffman tables
/// they use, and (for progressive scans) which coefficient band +
/// approximation level it carries.
package struct JPEGScanHeader: Sendable, Equatable {
    package let components: [JPEGScanComponent]
    /// Start of spectral selection. 0 for a sequential scan.
    package let spectralSelectionStart: Int
    /// End of spectral selection. 63 for a sequential scan.
    package let spectralSelectionEnd: Int
    /// Successive-approximation high bit. 0 for sequential.
    package let successiveApproximationHigh: Int
    /// Successive-approximation low bit. 0 for sequential.
    package let successiveApproximationLow: Int

    /// True iff this looks like a baseline / sequential scan
    /// (covers the full 0..63 DCT band, no successive approximation).
    package var isSequential: Bool {
        spectralSelectionStart == 0
            && spectralSelectionEnd == 63
            && successiveApproximationHigh == 0
            && successiveApproximationLow == 0
    }
}

extension JPEGFrameComponent {
    /// Parse `Nf` per-component records from the SOFn payload.
    /// `payload` is the full SOFn segment payload starting at the
    /// `P` byte; this helper picks up from byte 6 (just past
    /// P/Y/X/Nf).
    package static func parseSOFComponents(
        sofPayload p: Data
    ) throws -> [JPEGFrameComponent] {
        guard p.count >= 6 else {
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xC0, length: p.count + 2)
        }
        let nf = Int(p[p.startIndex + 5])
        let bytesPerComp = 3
        let needed = 6 + nf * bytesPerComp
        guard p.count >= needed else {
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xC0, length: p.count + 2)
        }
        var out: [JPEGFrameComponent] = []
        out.reserveCapacity(nf)
        for k in 0..<nf {
            let off = 6 + k * 3
            let ci = Int(p[p.startIndex + off])
            let hv = p[p.startIndex + off + 1]
            let h = Int(hv >> 4)
            let v = Int(hv & 0x0F)
            let tq = Int(p[p.startIndex + off + 2])
            guard (1...4).contains(h), (1...4).contains(v) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC0, length: p.count + 2)
            }
            guard (0...3).contains(tq) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xC0, length: p.count + 2)
            }
            out.append(JPEGFrameComponent(
                componentId: ci,
                hSamplingFactor: h, vSamplingFactor: v,
                quantTableId: tq))
        }
        return out
    }
}

extension JPEGScanHeader {
    /// Parse one SOS segment payload into a `JPEGScanHeader`. The
    /// payload is the bytes AFTER the SOS marker's 2-byte length
    /// field — `Ns` is the first byte.
    package static func parse(
        sosPayload p: Data
    ) throws -> JPEGScanHeader {
        guard p.count >= 1 else {
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xDA, length: p.count + 2)
        }
        let ns = Int(p[p.startIndex])
        let perComp = 2
        // payload = 1 (Ns) + ns*perComp + 3 (Ss, Se, Ah/Al)
        let needed = 1 + ns * perComp + 3
        guard p.count >= needed else {
            throw JPEGParseError.invalidSegmentLength(
                marker: 0xDA, length: p.count + 2)
        }
        var comps: [JPEGScanComponent] = []
        comps.reserveCapacity(ns)
        for k in 0..<ns {
            let off = 1 + k * 2
            let csj = Int(p[p.startIndex + off])
            let td_ta = p[p.startIndex + off + 1]
            let td = Int(td_ta >> 4)
            let ta = Int(td_ta & 0x0F)
            guard (0...3).contains(td), (0...3).contains(ta) else {
                throw JPEGParseError.invalidSegmentLength(
                    marker: 0xDA, length: p.count + 2)
            }
            comps.append(JPEGScanComponent(
                componentId: csj,
                dcTableId: td, acTableId: ta))
        }
        let tailOff = 1 + ns * perComp
        let ss = Int(p[p.startIndex + tailOff])
        let se = Int(p[p.startIndex + tailOff + 1])
        let ahAl = p[p.startIndex + tailOff + 2]
        let ah = Int(ahAl >> 4)
        let al = Int(ahAl & 0x0F)
        return JPEGScanHeader(
            components: comps,
            spectralSelectionStart: ss,
            spectralSelectionEnd: se,
            successiveApproximationHigh: ah,
            successiveApproximationLow: al)
    }
}

extension JPEGStructure {
    /// Return the per-component records from the file's SOFn
    /// segment. Useful for the transcoder to learn the chroma
    /// subsampling (`(H,V)` factors) and the quant-table binding.
    package static func frameComponents(
        in data: Data
    ) throws -> [JPEGFrameComponent] {
        var reader = JPEGSegmentReader(data)
        while let seg = try reader.next() {
            if case .startOfFrame = seg.kind {
                return try JPEGFrameComponent
                    .parseSOFComponents(sofPayload: seg.payload)
            }
            if seg.kind == .endOfImage { break }
        }
        return []
    }

    /// Return every SOS scan header in document order. Baseline
    /// JPEGs have exactly one; progressive JPEGs typically have
    /// many (one per spectral / approximation pass).
    package static func scanHeaders(
        in data: Data
    ) throws -> [JPEGScanHeader] {
        var reader = JPEGSegmentReader(data)
        var out: [JPEGScanHeader] = []
        while let seg = try reader.next() {
            if seg.kind == .startOfScan {
                out.append(try JPEGScanHeader.parse(
                    sosPayload: seg.payload))
            }
            if seg.kind == .endOfImage { break }
        }
        return out
    }
}
