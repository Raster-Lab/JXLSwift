// Decode a complete JPEG baseline-sequential scan — ninth step on
// the Phase J road, and the last layer before "raw JPEG bytes →
// quantised DCT coefficients per component" is solved end-to-end.
//
// MCU iteration (ITU-T T.81 §A.2):
//   - Each frame component carries (H_i, V_i) sampling factors.
//     `H_max = max(H_i)`, `V_max = max(V_i)`.
//   - Image is tiled in **MCUs** of `(H_max * 8) × (V_max * 8)`
//     pixels. `mcusWide = ceil(imageWidth / (H_max * 8))`,
//     `mcusHigh = ceil(imageHeight / (V_max * 8))`.
//   - One MCU contains, for each scan component (in scan order),
//     `V_i × H_i` 8×8 blocks. So for 4:2:0 luma (H=V=2) and chroma
//     (H=V=1), an MCU has 4 Y + 1 Cb + 1 Cr = 6 blocks.
//   - Per-component block grid: `blocksWide_i = mcusWide * H_i`,
//     `blocksHigh_i = mcusHigh * V_i`. Edge MCUs are decoded in
//     full even if they overlap image boundaries — the spec
//     emits the full grid and trims at display time.
//
// Restart intervals (ITU-T T.81 §F.2.1.3.1):
//   - DRI sets `Ri` MCUs between RST markers. After every `Ri`
//     MCUs, all DC predictors reset.
//   - The bit reader silently consumes RST markers (`0xFF D0..D7`).
//     We just have to reset predictors at the right MCU boundary
//     and align to the next byte (the bit reader's byte buffer
//     drains naturally when an RST is hit during `fillByte`).
//
// This implementation handles **baseline-sequential** scans only
// (covering the whole 0..63 DCT band, no successive
// approximation). Progressive scans are a follow-on bite.

import Foundation

/// Per-component grid of decoded JPEG DCT coefficient blocks in
/// row-major order. `blocks[r * blocksWide + c]` is the block at
/// the (c, r) position within the per-component grid.
public struct JPEGComponentBlocks: Sendable {
    public let componentId: Int
    public let blocksWide: Int
    public let blocksHigh: Int
    public var blocks: [JPEGCoefficientBlock]

    public init(
        componentId: Int,
        blocksWide: Int, blocksHigh: Int,
        blocks: [JPEGCoefficientBlock]
    ) {
        precondition(blocks.count == blocksWide * blocksHigh,
            "JPEGComponentBlocks: block count must equal "
            + "blocksWide × blocksHigh")
        self.componentId = componentId
        self.blocksWide = blocksWide
        self.blocksHigh = blocksHigh
        self.blocks = blocks
    }
}

/// Errors raised when a scan's structure doesn't line up with the
/// frame header — distinct from per-block decode errors so callers
/// can tell "scan config wrong" from "this block's tokens are
/// malformed".
public enum JPEGScanDecodeError: Error, Sendable, Equatable,
                                 LocalizedError {
    /// Scan referenced a component ID not in the frame's SOFn.
    case unknownScanComponent(componentId: Int)
    /// Scan referenced a DC or AC table ID not in the supplied
    /// codebook map.
    case missingHuffmanTable(component: Int, kind: String,
                             tableId: Int)
    /// Scan header has fields outside the baseline-sequential
    /// envelope (progressive / successive approximation).
    case notBaselineSequential(reason: String)
    /// Frame dimensions or sampling factors don't make sense.
    case invalidFrameGeometry(reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownScanComponent(let c):
            return "scan references component \(c) not in frame"
        case .missingHuffmanTable(let c, let k, let id):
            return "component \(c) needs \(k) Huffman table "
                + "\(id) but it was not supplied"
        case .notBaselineSequential(let r):
            return "scan is not baseline-sequential: \(r)"
        case .invalidFrameGeometry(let r):
            return "invalid frame geometry: \(r)"
        }
    }
}

/// A Huffman codebook + its underlying `huffvals` symbol array,
/// indexed by table destination ID. The scan decoder routes each
/// component through `dcCodebooks[scanComponent.dcTableId]` and
/// `acCodebooks[scanComponent.acTableId]`.
public typealias JPEGHuffmanCodebookMap =
    [Int: (codebook: JPEGHuffmanCodebook, huffvals: [UInt8])]

/// Drives one JPEG baseline-sequential scan to completion.
public enum JPEGScanDecoder {

    /// Decode every MCU of a baseline-sequential scan. Returns
    /// one `JPEGComponentBlocks` per scan component, in scan
    /// order.
    ///
    /// - Parameters:
    ///   - reader: positioned at the first byte of entropy data
    ///     following the SOS marker. On return, advanced to the
    ///     byte just past the last consumed entropy byte (i.e.
    ///     the start of the next marker or EOI).
    ///   - scanHeader: from `JPEGScanHeader.parse`.
    ///   - frameComponents: from `JPEGStructure.frameComponents`.
    ///   - imageWidth / imageHeight: SOFn `X` / `Y` fields.
    ///   - dcCodebooks / acCodebooks: keyed by table destination
    ///     ID. Build by parsing every DHT segment and calling
    ///     `buildCodebook` on each one.
    ///   - restartInterval: DRI value (0 = no restarts).
    public static func decodeBaselineSequential(
        from reader: inout JPEGBitReader,
        scanHeader: JPEGScanHeader,
        frameComponents: [JPEGFrameComponent],
        imageWidth: Int, imageHeight: Int,
        dcCodebooks: JPEGHuffmanCodebookMap,
        acCodebooks: JPEGHuffmanCodebookMap,
        restartInterval: Int = 0
    ) throws -> [JPEGComponentBlocks] {
        guard scanHeader.isSequential else {
            throw JPEGScanDecodeError.notBaselineSequential(
                reason: "Ss/Se/Ah/Al fields don't cover full "
                + "0..63 sequential band")
        }
        guard imageWidth > 0, imageHeight > 0 else {
            throw JPEGScanDecodeError.invalidFrameGeometry(
                reason: "non-positive dimensions "
                + "\(imageWidth)×\(imageHeight)")
        }
        guard !frameComponents.isEmpty else {
            throw JPEGScanDecodeError.invalidFrameGeometry(
                reason: "no frame components")
        }

        // Build per-scan-component dispatch state: the frame
        // record (for sampling factors), the DC + AC codebook
        // pair, and a DC predictor. Order matches scanHeader's
        // listing — that's the order MCU blocks are decoded in.
        struct Dispatch {
            let frameComponent: JPEGFrameComponent
            let dcCodebook: JPEGHuffmanCodebook
            let dcHuffvals: [UInt8]
            let acCodebook: JPEGHuffmanCodebook
            let acHuffvals: [UInt8]
            var predictor: JPEGDCPredictor
        }
        var dispatches: [Dispatch] = []
        for sc in scanHeader.components {
            guard let fc = frameComponents.first(
                where: { $0.componentId == sc.componentId })
            else {
                throw JPEGScanDecodeError
                    .unknownScanComponent(
                        componentId: sc.componentId)
            }
            guard let dc = dcCodebooks[sc.dcTableId] else {
                throw JPEGScanDecodeError.missingHuffmanTable(
                    component: sc.componentId,
                    kind: "DC", tableId: sc.dcTableId)
            }
            guard let ac = acCodebooks[sc.acTableId] else {
                throw JPEGScanDecodeError.missingHuffmanTable(
                    component: sc.componentId,
                    kind: "AC", tableId: sc.acTableId)
            }
            dispatches.append(Dispatch(
                frameComponent: fc,
                dcCodebook: dc.codebook,
                dcHuffvals: dc.huffvals,
                acCodebook: ac.codebook,
                acHuffvals: ac.huffvals,
                predictor: JPEGDCPredictor()))
        }

        // MCU geometry. H_max / V_max are taken across **frame**
        // components (not just scan components) because the
        // per-component sampling factors are defined relative to
        // the frame, not the scan (§A.1.1).
        let hMax = frameComponents.map(\.hSamplingFactor).max()
            ?? 1
        let vMax = frameComponents.map(\.vSamplingFactor).max()
            ?? 1
        let mcusWide = (imageWidth + hMax * 8 - 1)
            / (hMax * 8)
        let mcusHigh = (imageHeight + vMax * 8 - 1)
            / (vMax * 8)

        // Allocate per-component output grids — sized for the
        // *frame*'s component dimensions, which is what a
        // dequantiser / IDCT pipeline would expect downstream.
        // Edge MCUs decoded in full per §A.2.4.
        var outputs: [JPEGComponentBlocks] = []
        for d in dispatches {
            let bw = mcusWide * d.frameComponent.hSamplingFactor
            let bh = mcusHigh * d.frameComponent.vSamplingFactor
            outputs.append(JPEGComponentBlocks(
                componentId: d.frameComponent.componentId,
                blocksWide: bw, blocksHigh: bh,
                blocks: Array(
                    repeating: JPEGCoefficientBlock(),
                    count: bw * bh)))
        }

        // MCU walk. For each MCU, for each scan component (in
        // scan order), decode `Vi × Hi` blocks in row-major order
        // and place them at the right per-component grid offset.
        var mcuCounter = 0
        for mcuRow in 0..<mcusHigh {
            for mcuCol in 0..<mcusWide {
                for (ci, _) in dispatches.enumerated() {
                    let hi = dispatches[ci].frameComponent
                        .hSamplingFactor
                    let vi = dispatches[ci].frameComponent
                        .vSamplingFactor
                    for v in 0..<vi {
                        for h in 0..<hi {
                            let block = try JPEGBlockDecoder.decode(
                                from: &reader,
                                dcCodebook: dispatches[ci]
                                    .dcCodebook,
                                dcHuffvals: dispatches[ci]
                                    .dcHuffvals,
                                acCodebook: dispatches[ci]
                                    .acCodebook,
                                acHuffvals: dispatches[ci]
                                    .acHuffvals,
                                dcPredictor:
                                    &dispatches[ci].predictor)
                            let row = mcuRow * vi + v
                            let col = mcuCol * hi + h
                            let bw = outputs[ci].blocksWide
                            outputs[ci].blocks[row * bw + col]
                                = block
                        }
                    }
                }
                mcuCounter += 1
                if restartInterval > 0,
                   mcuCounter % restartInterval == 0 {
                    // RST marker boundary. The bit reader has
                    // already silently consumed the marker bytes
                    // when it next reads through them; reset all
                    // predictors and discard any partial bit
                    // accumulator so the next read starts byte-
                    // aligned.
                    for i in dispatches.indices {
                        dispatches[i].predictor.reset()
                    }
                    reader.alignToByte()
                }
            }
        }

        return outputs
    }
}
