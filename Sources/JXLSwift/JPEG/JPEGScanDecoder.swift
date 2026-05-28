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

// MARK: - Progressive (SOF2) scan decoding

extension JPEGScanDecoder {

    /// Decode one **progressive** scan into a shared per-component
    /// coefficient buffer — the inverse of
    /// `JPEGScanEncoder.encodeProgressive`. A progressive JPEG is a
    /// sequence of scans, each refining part of the coefficient
    /// state; the caller allocates `components` once (zero-filled,
    /// sized like the baseline grids) and threads it through every
    /// scan in document order.
    ///
    /// Dispatches on Ss/Se (spectral selection) + Ah/Al (successive
    /// approximation), mirroring libjpeg `jdphuff.c`:
    ///   - DC first   (Ss==0, Ah==0): DPCM of the high DC bits.
    ///   - DC refine  (Ss==0, Ah!=0): one correction bit per block.
    ///   - AC first   (Ss>0,  Ah==0): run/size + EOB-run coding.
    ///   - AC refine  (Ss>0,  Ah!=0): correction bits + newly-nonzero
    ///     run/size + EOB-run.
    ///
    /// - Parameters:
    ///   - reader: positioned at the first entropy byte after the SOS.
    ///   - scanHeader: the parsed SOS header for this scan.
    ///   - frameComponents: SOFn component list (defines the grid).
    ///   - components: shared, in-out per-frame-component coefficient
    ///     grids (parallel to `frameComponents`). Refined in place.
    public static func decodeProgressive(
        from reader: inout JPEGBitReader,
        scanHeader: JPEGScanHeader,
        frameComponents: [JPEGFrameComponent],
        imageWidth: Int, imageHeight: Int,
        dcCodebooks: JPEGHuffmanCodebookMap,
        acCodebooks: JPEGHuffmanCodebookMap,
        restartInterval: Int,
        components: inout [JPEGComponentBlocks]
    ) throws {
        let ss = scanHeader.spectralSelectionStart
        let se = scanHeader.spectralSelectionEnd
        let ah = scanHeader.successiveApproximationHigh
        let al = scanHeader.successiveApproximationLow

        if ss == 0 {
            if ah == 0 {
                try decodeDCFirst(
                    al: al, from: &reader, scanHeader: scanHeader,
                    frameComponents: frameComponents,
                    dcCodebooks: dcCodebooks,
                    imageWidth: imageWidth, imageHeight: imageHeight,
                    restartInterval: restartInterval,
                    components: &components)
            } else {
                try decodeDCRefine(
                    al: al, from: &reader, scanHeader: scanHeader,
                    frameComponents: frameComponents,
                    imageWidth: imageWidth, imageHeight: imageHeight,
                    restartInterval: restartInterval,
                    components: &components)
            }
        } else {
            // AC scans are always single-component (§G.1.1.1.1).
            guard scanHeader.components.count == 1 else {
                throw JPEGScanDecodeError.notBaselineSequential(
                    reason: "progressive AC scan must be "
                    + "single-component (Ns=\(scanHeader.components.count))")
            }
            let sc = scanHeader.components[0]
            guard let fi = frameComponents.firstIndex(
                where: { $0.componentId == sc.componentId })
            else {
                throw JPEGScanDecodeError.unknownScanComponent(
                    componentId: sc.componentId)
            }
            guard let ac = acCodebooks[sc.acTableId] else {
                throw JPEGScanDecodeError.missingHuffmanTable(
                    component: sc.componentId,
                    kind: "AC", tableId: sc.acTableId)
            }
            if ah == 0 {
                try decodeACFirst(
                    ss: ss, se: se, al: al, from: &reader,
                    acCodebook: ac.codebook, acHuffvals: ac.huffvals,
                    restartInterval: restartInterval,
                    comp: &components[fi])
            } else {
                try decodeACRefine(
                    ss: ss, se: se, al: al, from: &reader,
                    acCodebook: ac.codebook, acHuffvals: ac.huffvals,
                    restartInterval: restartInterval,
                    comp: &components[fi])
            }
        }
    }

    // DC first scan (Ss==0, Ah==0). DPCM of `dc >> Al`, stored as
    // `(dc >> Al) << Al`. May be interleaved (Ns > 1): MCU walk
    // matches the baseline interleaved order.
    private static func decodeDCFirst(
        al: Int,
        from reader: inout JPEGBitReader,
        scanHeader: JPEGScanHeader,
        frameComponents: [JPEGFrameComponent],
        dcCodebooks: JPEGHuffmanCodebookMap,
        imageWidth: Int, imageHeight: Int,
        restartInterval: Int,
        components: inout [JPEGComponentBlocks]
    ) throws {
        struct DCDispatch {
            let frameIndex: Int
            let hi: Int, vi: Int
            let codebook: JPEGHuffmanCodebook
            let huffvals: [UInt8]
            var predictor: Int32
        }
        var disp: [DCDispatch] = []
        for sc in scanHeader.components {
            guard let fi = frameComponents.firstIndex(
                where: { $0.componentId == sc.componentId })
            else {
                throw JPEGScanDecodeError.unknownScanComponent(
                    componentId: sc.componentId)
            }
            guard let dc = dcCodebooks[sc.dcTableId] else {
                throw JPEGScanDecodeError.missingHuffmanTable(
                    component: sc.componentId,
                    kind: "DC", tableId: sc.dcTableId)
            }
            disp.append(DCDispatch(
                frameIndex: fi,
                hi: frameComponents[fi].hSamplingFactor,
                vi: frameComponents[fi].vSamplingFactor,
                codebook: dc.codebook, huffvals: dc.huffvals,
                predictor: 0))
        }

        let alShift = Int32(al)

        // Decode one block's DC into the shared buffer.
        func decodeOneDC(_ d: Int, blockIndex bi: Int) throws {
            guard let sByte = JPEGBlockDecoder.decodeSymbol(
                using: disp[d].codebook, huffvals: disp[d].huffvals,
                reader: &reader)
            else {
                throw JPEGBlockDecodeError.malformedDCSymbol
            }
            let s = Int(sByte)
            guard s <= 15 else {
                throw JPEGBlockDecodeError.dcSizeOutOfRange(s)
            }
            let diff = try JPEGBlockDecoder.readExtendedMagnitude(
                bits: s, from: &reader)
            disp[d].predictor &+= diff
            let fi = disp[d].frameIndex
            components[fi].blocks[bi].coefficients[0] =
                disp[d].predictor << alShift
        }

        var mcuCounter = 0
        func maybeRestart() {
            if restartInterval > 0
                && mcuCounter % restartInterval == 0 {
                for i in disp.indices { disp[i].predictor = 0 }
                reader.alignToByte()
            }
        }

        if disp.count == 1 {
            // Non-interleaved: raster grid of the single component.
            let fi = disp[0].frameIndex
            let total = components[fi].blocksWide
                * components[fi].blocksHigh
            for bi in 0..<total {
                try decodeOneDC(0, blockIndex: bi)
                mcuCounter += 1
                maybeRestart()
            }
        } else {
            // Interleaved MCU walk.
            let maxH = frameComponents.map(\.hSamplingFactor).max() ?? 1
            let maxV = frameComponents.map(\.vSamplingFactor).max() ?? 1
            let mcusWide = (imageWidth + 8 * maxH - 1) / (8 * maxH)
            let mcusHigh = (imageHeight + 8 * maxV - 1) / (8 * maxV)
            for mr in 0..<mcusHigh {
                for mc in 0..<mcusWide {
                    for d in disp.indices {
                        let fi = disp[d].frameIndex
                        let bw = components[fi].blocksWide
                        for v in 0..<disp[d].vi {
                            for h in 0..<disp[d].hi {
                                let row = mr * disp[d].vi + v
                                let col = mc * disp[d].hi + h
                                try decodeOneDC(
                                    d, blockIndex: row * bw + col)
                            }
                        }
                    }
                    mcuCounter += 1
                    maybeRestart()
                }
            }
        }
    }

    // DC refine scan (Ss==0, Ah!=0). One correction bit per block,
    // OR-ed into bit `Al` of the DC coefficient (libjpeg
    // `decode_mcu_DC_refine`).
    private static func decodeDCRefine(
        al: Int,
        from reader: inout JPEGBitReader,
        scanHeader: JPEGScanHeader,
        frameComponents: [JPEGFrameComponent],
        imageWidth: Int, imageHeight: Int,
        restartInterval: Int,
        components: inout [JPEGComponentBlocks]
    ) throws {
        let p1: Int32 = 1 << Int32(al)
        var frameIndices: [Int] = []
        for sc in scanHeader.components {
            guard let fi = frameComponents.firstIndex(
                where: { $0.componentId == sc.componentId })
            else {
                throw JPEGScanDecodeError.unknownScanComponent(
                    componentId: sc.componentId)
            }
            frameIndices.append(fi)
        }

        func refineOne(_ fi: Int, blockIndex bi: Int) throws {
            let bit = try reader.readBit()
            if bit != 0 {
                components[fi].blocks[bi].coefficients[0] |= p1
            }
        }

        var mcuCounter = 0
        func maybeRestart() {
            if restartInterval > 0
                && mcuCounter % restartInterval == 0 {
                reader.alignToByte()
            }
        }

        if frameIndices.count == 1 {
            let fi = frameIndices[0]
            let total = components[fi].blocksWide
                * components[fi].blocksHigh
            for bi in 0..<total {
                try refineOne(fi, blockIndex: bi)
                mcuCounter += 1
                maybeRestart()
            }
        } else {
            let maxH = frameComponents.map(\.hSamplingFactor).max() ?? 1
            let maxV = frameComponents.map(\.vSamplingFactor).max() ?? 1
            let mcusWide = (imageWidth + 8 * maxH - 1) / (8 * maxH)
            let mcusHigh = (imageHeight + 8 * maxV - 1) / (8 * maxV)
            for mr in 0..<mcusHigh {
                for mc in 0..<mcusWide {
                    for fi in frameIndices {
                        let fc = frameComponents[fi]
                        let bw = components[fi].blocksWide
                        for v in 0..<fc.vSamplingFactor {
                            for h in 0..<fc.hSamplingFactor {
                                let row = mr * fc.vSamplingFactor + v
                                let col = mc * fc.hSamplingFactor + h
                                try refineOne(
                                    fi, blockIndex: row * bw + col)
                            }
                        }
                    }
                    mcuCounter += 1
                    maybeRestart()
                }
            }
        }
    }

    // AC first scan (Ss>0, Ah==0). Single-component. run/size +
    // EOB-run coding of `ac >> Al`, stored as `(ac >> Al) << Al`
    // (libjpeg `decode_mcu_AC_first`).
    private static func decodeACFirst(
        ss: Int, se: Int, al: Int,
        from reader: inout JPEGBitReader,
        acCodebook: JPEGHuffmanCodebook, acHuffvals: [UInt8],
        restartInterval: Int,
        comp: inout JPEGComponentBlocks
    ) throws {
        let total = comp.blocksWide * comp.blocksHigh
        let alShift = Int32(al)
        var eobrun = 0
        var mcuCounter = 0
        for bi in 0..<total {
            if eobrun > 0 {
                eobrun -= 1
            } else {
                var k = ss
                while k <= se {
                    guard let token = JPEGBlockDecoder.decodeSymbol(
                        using: acCodebook, huffvals: acHuffvals,
                        reader: &reader)
                    else {
                        throw JPEGBlockDecodeError.malformedACSymbol
                    }
                    let r = Int(token >> 4)
                    let s = Int(token & 0x0F)
                    if s == 0 {
                        if r != 15 {
                            // EOBr: run of (2^r + bits) all-zero
                            // bands; current block is the first.
                            eobrun = (1 << r) - 1
                            if r > 0 {
                                eobrun += Int(try reader.readBits(r))
                            }
                            break
                        }
                        k += 16   // ZRL — skip 16 zero coefficients
                    } else {
                        k += r
                        guard k <= se else {
                            throw JPEGBlockDecodeError.runOverflow
                        }
                        let value = try JPEGBlockDecoder
                            .readExtendedMagnitude(bits: s, from: &reader)
                        comp.blocks[bi].coefficients[
                            JPEGZigZag.order[k]] = value << alShift
                        k += 1
                    }
                }
            }
            mcuCounter += 1
            if restartInterval > 0
                && mcuCounter % restartInterval == 0 {
                eobrun = 0
                reader.alignToByte()
            }
        }
    }

    // AC refine scan (Ss>0, Ah!=0). Single-component. Correction
    // bits for already-nonzero coeffs interleaved with newly-nonzero
    // run/size=1 + sign + EOB-run (libjpeg `decode_mcu_AC_refine`).
    private static func decodeACRefine(
        ss: Int, se: Int, al: Int,
        from reader: inout JPEGBitReader,
        acCodebook: JPEGHuffmanCodebook, acHuffvals: [UInt8],
        restartInterval: Int,
        comp: inout JPEGComponentBlocks
    ) throws {
        let total = comp.blocksWide * comp.blocksHigh
        let p1: Int32 = 1 << Int32(al)       // +bit to add/set
        let m1: Int32 = -(1 << Int32(al))    // -bit (libjpeg (-1)<<Al)
        var eobrun = 0
        var mcuCounter = 0

        // Apply one correction bit to an already-nonzero coefficient.
        func correct(_ bi: Int, _ natIdx: Int) throws {
            let coef = comp.blocks[bi].coefficients[natIdx]
            if coef != 0 {
                let bit = try reader.readBit()
                if bit != 0 && (coef & p1) == 0 {
                    comp.blocks[bi].coefficients[natIdx] =
                        coef + (coef >= 0 ? p1 : m1)
                }
            }
        }

        for bi in 0..<total {
            var k = ss
            if eobrun == 0 {
                while k <= se {
                    guard let token = JPEGBlockDecoder.decodeSymbol(
                        using: acCodebook, huffvals: acHuffvals,
                        reader: &reader)
                    else {
                        throw JPEGBlockDecodeError.malformedACSymbol
                    }
                    var r = Int(token >> 4)
                    let s = Int(token & 0x0F)
                    var newCoef: Int32 = 0
                    if s != 0 {
                        // New nonzero coef (size must be 1); read sign.
                        let bit = try reader.readBit()
                        newCoef = (bit != 0) ? p1 : m1
                    } else {
                        if r != 15 {
                            eobrun = 1 << r
                            if r > 0 {
                                eobrun += Int(try reader.readBits(r))
                            }
                            break   // EOB logic handles the rest
                        }
                        // r == 15: ZRL — skip 16 zero-history coeffs.
                    }
                    // Advance over `r` zero-history coeffs (plus any
                    // interspersed already-nonzero ones, which take
                    // correction bits), then land on the slot for the
                    // newly-nonzero coef. Mirrors libjpeg's do-while
                    // with `if (--r < 0) break`.
                    var landed = false
                    while k <= se {
                        let natIdx = JPEGZigZag.order[k]
                        if comp.blocks[bi].coefficients[natIdx] != 0 {
                            try correct(bi, natIdx)
                        } else {
                            r -= 1
                            if r < 0 { landed = true; break }
                        }
                        k += 1
                    }
                    if newCoef != 0 {
                        guard landed, k <= se else {
                            throw JPEGBlockDecodeError.runOverflow
                        }
                        comp.blocks[bi].coefficients[
                            JPEGZigZag.order[k]] = newCoef
                    }
                    k += 1
                }
            }
            if eobrun > 0 {
                // Trailing band after the last newly-nonzero coef:
                // apply correction bits to remaining nonzeros.
                while k <= se {
                    try correct(bi, JPEGZigZag.order[k])
                    k += 1
                }
                eobrun -= 1
            }
            mcuCounter += 1
            if restartInterval > 0
                && mcuCounter % restartInterval == 0 {
                eobrun = 0
                reader.alignToByte()
            }
        }
    }
}
