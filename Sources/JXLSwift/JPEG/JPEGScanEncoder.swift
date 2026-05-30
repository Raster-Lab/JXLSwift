// `JPEG/JPEGScanEncoder.swift` — encode an entire JPEG scan
// (interleaved or non-interleaved) from per-component coefficient
// blocks. Inverse of `JPEGScanDecoder.decodeBaselineSequential`.
//
// The MCU walk:
//   - Interleaved scan (num_components > 1): each MCU contains
//     `Σ Hi × Vi` blocks from each component. Walk component-by-
//     component within an MCU, V-rows then H-cols.
//   - Non-interleaved scan (num_components == 1): each MCU is one
//     block from the single scan component.
//
// Restart interval (DRI marker):
//   - After every `restartInterval` MCUs (if non-zero), the
//     encoder writes an RST marker (0xFF Dn where n cycles 0..7),
//     flushes the bit accumulator to a byte boundary, and resets
//     all per-component DC predictors. The MCU counter doesn't
//     reset across RSTs (so the RST cycle increments monotonically).
//
// Phase J step 5i support. v0.12.0g3.

import Foundation

/// Errors raised by the scan encoder when component counts /
/// dimensions don't line up.
package enum JPEGScanEncodeError: Error, Sendable, Equatable {
    /// The scan header listed components not present in the
    /// per-component coefficient input.
    case unknownScanComponent(componentId: Int)
    /// A scan-component referenced a DC/AC table id outside 0..3.
    case invalidTableId(Int)
    /// The supplied component blocks didn't match the SOFn-derived
    /// MCU dimensions.
    case shapeMismatch(String)
    /// Encode propagated a block-encoder error.
    case blockEncodeFailed(JPEGBlockEncodeError, mcu: Int, comp: Int)
}

/// One per-component scan binding (mirrors `JPEGScanComponent`
/// from the existing reader, but indexed by the scan-component
/// position not the SOFn order).
package struct JPEGScanComponentEncode: Sendable, Equatable {
    package var componentIndex: Int       // index into `components`
    package var dcTableId: Int            // 0..3
    package var acTableId: Int            // 0..3
    package init(
        componentIndex: Int,
        dcTableId: Int, acTableId: Int
    ) {
        self.componentIndex = componentIndex
        self.dcTableId = dcTableId
        self.acTableId = acTableId
    }
}

package enum JPEGScanEncoder {

    /// Encode a baseline-sequential scan.
    ///
    /// - Parameters:
    ///   - components: per-frame component blocks (in SOFn order).
    ///     Must match the per-component dimensions implied by the
    ///     `frameComponents` H/V sampling factors.
    ///   - frameComponents: SOFn component definitions (id, H, V,
    ///     quant table). Used to compute MCU layout.
    ///   - scanComponents: per-scan component bindings (dc/ac
    ///     table ids and the SOFn-index they refer to). Ordering
    ///     of this array IS the MCU's scan-component iteration order.
    ///   - dcTables / acTables: per-table-id encode-side Huffman
    ///     tables (size 4 each; tables[i] = nil for unused slots).
    ///   - restartInterval: MCUs per RST cycle. 0 disables RST.
    ///   - imageWidth / imageHeight: in pixels — needed to compute
    ///     MCU row/col counts.
    /// - Returns: the SOS payload bytes (Huffman-coded + byte-stuffed,
    ///   with RST markers if `restartInterval > 0`).
    package static func encodeBaselineSequential(
        components: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        scanComponents: [JPEGScanComponentEncode],
        dcTables: [[JPEGHuffmanEncodeEntry]?],
        acTables: [[JPEGHuffmanEncodeEntry]?],
        restartInterval: Int,
        imageWidth: Int, imageHeight: Int
    ) throws -> Data {
        precondition(dcTables.count == 4 && acTables.count == 4,
            "JPEGScanEncoder: dcTables / acTables must have 4 slots")
        guard components.count == frameComponents.count else {
            throw JPEGScanEncodeError.shapeMismatch(
                "components.count \(components.count) ≠ "
                + "frameComponents.count \(frameComponents.count)")
        }
        // Compute max H/V sampling across all frame components.
        let maxH = frameComponents.map { $0.hSamplingFactor }.max() ?? 1
        let maxV = frameComponents.map { $0.vSamplingFactor }.max() ?? 1
        let mcusWide = (imageWidth + (8 * maxH) - 1) / (8 * maxH)
        let mcusHigh = (imageHeight + (8 * maxV) - 1) / (8 * maxV)

        // Set up per-component DC predictors (one per scan-component,
        // reset to 0 at start and at every RST).
        var predictors = Array(
            repeating: JPEGDCPredictor(),
            count: scanComponents.count)

        var writer = JPEGBitWriter()
        var mcuCounter = 0
        var rstCycle = 0

        for mcuRow in 0..<mcusHigh {
            for mcuCol in 0..<mcusWide {
                // Emit one MCU.
                for (sci, sc) in scanComponents.enumerated() {
                    let ci = sc.componentIndex
                    let fc = frameComponents[ci]
                    let hi = fc.hSamplingFactor
                    let vi = fc.vSamplingFactor
                    let bw = components[ci].blocksWide
                    guard let dcTable = dcTables[sc.dcTableId]
                    else {
                        throw JPEGScanEncodeError.invalidTableId(
                            sc.dcTableId)
                    }
                    guard let acTable = acTables[sc.acTableId]
                    else {
                        throw JPEGScanEncodeError.invalidTableId(
                            sc.acTableId)
                    }
                    for v in 0..<vi {
                        for h in 0..<hi {
                            let row = mcuRow * vi + v
                            let col = mcuCol * hi + h
                            let bi = row * bw + col
                            guard bi < components[ci].blocks.count
                            else {
                                throw JPEGScanEncodeError
                                    .shapeMismatch(
                                    "component \(ci) MCU (\(mcuRow),"
                                    + "\(mcuCol)) block \(v),\(h) "
                                    + "index \(bi) ≥ "
                                    + "\(components[ci].blocks.count)")
                            }
                            do {
                                try JPEGBlockEncoder.encode(
                                    components[ci].blocks[bi],
                                    dcCodeTable: dcTable,
                                    acCodeTable: acTable,
                                    dcPredictor: &predictors[sci],
                                    to: &writer)
                            } catch let e as JPEGBlockEncodeError {
                                throw JPEGScanEncodeError
                                    .blockEncodeFailed(
                                        e, mcu: mcuCounter, comp: ci)
                            }
                        }
                    }
                }
                mcuCounter += 1
                // RST marker handling.
                if restartInterval > 0
                    && mcuCounter % restartInterval == 0
                    && !(mcuRow == mcusHigh - 1
                         && mcuCol == mcusWide - 1)
                {
                    writer.flushPaddingOnes()
                    let rstByte = UInt8(0xD0 + (rstCycle & 0x07))
                    writer.appendRawMarker([0xFF, rstByte])
                    rstCycle += 1
                    // Reset DC predictors per component.
                    for i in 0..<predictors.count {
                        predictors[i].reset()
                    }
                }
            }
        }
        // Final flush.
        writer.flushPaddingOnes()
        return writer.data
    }

    /// Encode one **progressive** scan (SOF2). Dispatches on the
    /// spectral-selection (Ss/Se) + successive-approximation
    /// (Ah/Al) parameters to the four progressive entropy modes,
    /// mirroring the JPEG spec Annex G / libjpeg `jcphuff.c`:
    ///   - DC first   (Ss==0, Ah==0): DPCM of `dc >> Al`.
    ///   - DC refine  (Ss==0, Ah!=0): one bit `(dc >> Al) & 1`.
    ///   - AC first   (Ss>0,  Ah==0): run/size + EOB-run coding of
    ///     `ac >> Al` (magnitude shift).
    ///   - AC refine  (Ss>0,  Ah!=0): correction bits + newly-nonzero
    ///     run/size + EOB-run, with buffered correction bits.
    ///
    /// AC scans are always single-component (non-interleaved); DC
    /// scans may be interleaved (num_components > 1).
    package static func encodeProgressive(
        ss: Int, se: Int, ah: Int, al: Int,
        components: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        scanComponents: [JPEGScanComponentEncode],
        dcTables: [[JPEGHuffmanEncodeEntry]?],
        acTables: [[JPEGHuffmanEncodeEntry]?],
        restartInterval: Int,
        imageWidth: Int, imageHeight: Int
    ) throws -> Data {
        var writer = JPEGBitWriter()
        if ss == 0 {
            if ah == 0 {
                try encodeDCFirst(
                    al: al, components: components,
                    frameComponents: frameComponents,
                    scanComponents: scanComponents,
                    dcTables: dcTables, restartInterval: restartInterval,
                    imageWidth: imageWidth, imageHeight: imageHeight,
                    writer: &writer)
            } else {
                try encodeDCRefine(
                    al: al, components: components,
                    frameComponents: frameComponents,
                    scanComponents: scanComponents,
                    restartInterval: restartInterval,
                    imageWidth: imageWidth, imageHeight: imageHeight,
                    writer: &writer)
            }
        } else {
            // AC scans are single-component.
            let sc = scanComponents[0]
            let comp = components[sc.componentIndex]
            guard let acTable = acTables[sc.acTableId] else {
                throw JPEGScanEncodeError.invalidTableId(sc.acTableId)
            }
            if ah == 0 {
                try encodeACFirst(
                    ss: ss, se: se, al: al, comp: comp,
                    acTable: acTable, restartInterval: restartInterval,
                    writer: &writer)
            } else {
                try encodeACRefine(
                    ss: ss, se: se, al: al, comp: comp,
                    acTable: acTable, restartInterval: restartInterval,
                    writer: &writer)
            }
        }
        writer.flushPaddingOnes()
        return writer.data
    }

    // Block iteration for DC scans: interleaved MCUs when
    // num_components > 1, else the single component's raster grid.
    // Calls `body(componentIndex, blockIndex)` for each block, and
    // `restart()` at restart boundaries.
    private static func forEachDCBlock(
        components: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        scanComponents: [JPEGScanComponentEncode],
        restartInterval: Int,
        imageWidth: Int, imageHeight: Int,
        body: (Int, Int) throws -> Void,
        restart: () -> Void,
        rstMarker: (Int) -> Void
    ) rethrows {
        var mcuCounter = 0
        var rstCycle = 0
        func maybeRestart(isLast: Bool) {
            if restartInterval > 0
                && mcuCounter % restartInterval == 0 && !isLast {
                rstMarker(rstCycle & 7)
                rstCycle += 1
                restart()
            }
        }
        if scanComponents.count == 1 {
            let sc = scanComponents[0]
            let comp = components[sc.componentIndex]
            let total = comp.blocksWide * comp.blocksHigh
            for bi in 0..<total {
                try body(sc.componentIndex, bi)
                mcuCounter += 1
                maybeRestart(isLast: bi == total - 1)
            }
        } else {
            let maxH = frameComponents.map { $0.hSamplingFactor }.max() ?? 1
            let maxV = frameComponents.map { $0.vSamplingFactor }.max() ?? 1
            let mcusWide = (imageWidth + 8 * maxH - 1) / (8 * maxH)
            let mcusHigh = (imageHeight + 8 * maxV - 1) / (8 * maxV)
            let totalMCU = mcusWide * mcusHigh
            var done = 0
            for mr in 0..<mcusHigh {
                for mc in 0..<mcusWide {
                    for sc in scanComponents {
                        let fc = frameComponents[sc.componentIndex]
                        let bw = components[sc.componentIndex].blocksWide
                        for v in 0..<fc.vSamplingFactor {
                            for h in 0..<fc.hSamplingFactor {
                                let row = mr * fc.vSamplingFactor + v
                                let col = mc * fc.hSamplingFactor + h
                                try body(sc.componentIndex, row * bw + col)
                            }
                        }
                    }
                    mcuCounter += 1
                    done += 1
                    maybeRestart(isLast: done == totalMCU)
                }
            }
        }
    }

    private static func encodeDCFirst(
        al: Int,
        components: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        scanComponents: [JPEGScanComponentEncode],
        dcTables: [[JPEGHuffmanEncodeEntry]?],
        restartInterval: Int,
        imageWidth: Int, imageHeight: Int,
        writer: inout JPEGBitWriter
    ) throws {
        // Per-scan-component DC predictor, keyed by component index.
        var pred = [Int: Int32]()
        for sc in scanComponents { pred[sc.componentIndex] = 0 }
        // DC table per component index.
        var dcTableFor = [Int: [JPEGHuffmanEncodeEntry]]()
        for sc in scanComponents {
            guard let t = dcTables[sc.dcTableId] else {
                throw JPEGScanEncodeError.invalidTableId(sc.dcTableId)
            }
            dcTableFor[sc.componentIndex] = t
        }
        var capturedWriter = writer
        try forEachDCBlock(
            components: components, frameComponents: frameComponents,
            scanComponents: scanComponents,
            restartInterval: restartInterval,
            imageWidth: imageWidth, imageHeight: imageHeight,
            body: { ci, bi in
                let dc = components[ci].blocks[bi].coefficients[0]
                let val = dc >> Int32(al)          // arithmetic point transform
                let diff = val - pred[ci]!
                pred[ci] = val
                let size = JPEGBlockEncoder.bitsNeeded(diff)
                guard size <= 15 else {
                    throw JPEGScanEncodeError.blockEncodeFailed(
                        .dcDeltaOutOfRange(diff), mcu: bi, comp: ci)
                }
                let entry = dcTableFor[ci]![size]
                guard entry.length > 0 else {
                    throw JPEGScanEncodeError.blockEncodeFailed(
                        .missingHuffmanSymbol(UInt8(size)),
                        mcu: bi, comp: ci)
                }
                capturedWriter.writeBits(entry.code, count: entry.length)
                if size > 0 {
                    capturedWriter.writeBits(
                        JPEGBlockEncoder.magnitudeBits(diff, size: size),
                        count: size)
                }
            },
            restart: {
                capturedWriter.flushPaddingOnes()
                for k in pred.keys { pred[k] = 0 }
            },
            rstMarker: { n in
                capturedWriter.appendRawMarker([0xFF, UInt8(0xD0 + n)])
            })
        writer = capturedWriter
    }

    private static func encodeDCRefine(
        al: Int,
        components: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        scanComponents: [JPEGScanComponentEncode],
        restartInterval: Int,
        imageWidth: Int, imageHeight: Int,
        writer: inout JPEGBitWriter
    ) throws {
        var capturedWriter = writer
        try forEachDCBlock(
            components: components, frameComponents: frameComponents,
            scanComponents: scanComponents,
            restartInterval: restartInterval,
            imageWidth: imageWidth, imageHeight: imageHeight,
            body: { ci, bi in
                let dc = components[ci].blocks[bi].coefficients[0]
                capturedWriter.writeBit(Int((dc >> Int32(al)) & 1))
            },
            restart: { capturedWriter.flushPaddingOnes() },
            rstMarker: { n in
                capturedWriter.appendRawMarker([0xFF, UInt8(0xD0 + n)])
            })
        writer = capturedWriter
    }

    // Magnitude point transform: |coef| >> Al, sign preserved.
    @inline(__always)
    private static func acTransform(_ coef: Int32, _ al: Int) -> Int32 {
        if coef < 0 { return -((-coef) >> Int32(al)) }
        return coef >> Int32(al)
    }

    private static func encodeACFirst(
        ss: Int, se: Int, al: Int,
        comp: JPEGComponentBlocks,
        acTable: [JPEGHuffmanEncodeEntry],
        restartInterval: Int,
        writer: inout JPEGBitWriter
    ) throws {
        let total = comp.blocksWide * comp.blocksHigh
        var eobrun = 0
        var mcuCounter = 0
        var rstCycle = 0
        func emitEOBRun() {
            guard eobrun > 0 else { return }
            var nbits = 0
            var t = eobrun
            while t > 1 { t >>= 1; nbits += 1 }
            let sym = nbits << 4
            let e = acTable[sym]
            writer.writeBits(e.code, count: e.length)
            if nbits > 0 {
                writer.writeBits(UInt32(eobrun) & ((1 << nbits) - 1),
                                 count: nbits)
            }
            eobrun = 0
        }
        for bi in 0..<total {
            let natural = comp.blocks[bi].coefficients
            var run = 0
            for k in ss...se {
                let coef = acTransform(natural[JPEGZigZag.order[k]], al)
                if coef == 0 { run += 1; continue }
                emitEOBRun()
                while run > 15 {
                    let zrl = acTable[0xF0]
                    writer.writeBits(zrl.code, count: zrl.length)
                    run -= 16
                }
                let size = JPEGBlockEncoder.bitsNeeded(coef)
                let sym = (run << 4) | size
                let e = acTable[sym]
                guard e.length > 0 else {
                    throw JPEGScanEncodeError.blockEncodeFailed(
                        .missingHuffmanSymbol(UInt8(sym)), mcu: bi, comp: 0)
                }
                writer.writeBits(e.code, count: e.length)
                writer.writeBits(
                    JPEGBlockEncoder.magnitudeBits(coef, size: size),
                    count: size)
                run = 0
            }
            if run > 0 {
                eobrun += 1
                if eobrun == 0x7FFF { emitEOBRun() }
            }
            mcuCounter += 1
            if restartInterval > 0
                && mcuCounter % restartInterval == 0
                && bi != total - 1 {
                emitEOBRun()
                writer.flushPaddingOnes()
                writer.appendRawMarker([0xFF, UInt8(0xD0 + (rstCycle & 7))])
                rstCycle += 1
            }
        }
        emitEOBRun()
    }

    private static func encodeACRefine(
        ss: Int, se: Int, al: Int,
        comp: JPEGComponentBlocks,
        acTable: [JPEGHuffmanEncodeEntry],
        restartInterval: Int,
        writer: inout JPEGBitWriter
    ) throws {
        let total = comp.blocksWide * comp.blocksHigh
        var eobrun = 0
        // `bitBuffer` holds correction bits that are owed to the
        // decoder *after* the next EOBn symbol (the trailing
        // already-nonzero coeffs of EOB-run blocks). It persists
        // across EOB-run blocks and is flushed by `emitEOBRun`.
        var bitBuffer: [Int] = []
        var mcuCounter = 0
        var rstCycle = 0
        // Emit a pending EOB run (EOBn symbol + run bits) followed by
        // the buffered correction bits. No-op when no run is pending.
        func emitEOBRun() {
            guard eobrun > 0 else { return }
            var nbits = 0
            var t = eobrun
            while t > 1 { t >>= 1; nbits += 1 }
            let sym = nbits << 4
            let e = acTable[sym]
            writer.writeBits(e.code, count: e.length)
            if nbits > 0 {
                writer.writeBits(UInt32(eobrun) & ((1 << nbits) - 1),
                                 count: nbits)
            }
            eobrun = 0
            for b in bitBuffer { writer.writeBit(b) }
            bitBuffer.removeAll(keepingCapacity: true)
        }
        for bi in 0..<total {
            let natural = comp.blocks[bi].coefficients
            // EOB position = last newly-nonzero coef (|coef|>>Al == 1).
            var eobK = ss - 1
            for k in ss...se {
                let av = abs(acTransform(natural[JPEGZigZag.order[k]], al))
                if av == 1 { eobK = k }
            }
            let hasNewlyNonzero = eobK >= ss
            // A block that emits symbols closes any pending EOB run
            // (and flushes the trailing correction bits owed to it)
            // *before* its own symbols.
            if hasNewlyNonzero { emitEOBRun() }
            // Correction bits for already-nonzero coeffs skipped in
            // the current zero-history run, awaiting the next symbol.
            var runBuffer: [Int] = []
            var run = 0
            for k in ss...se {
                let coef = acTransform(natural[JPEGZigZag.order[k]], al)
                let av = abs(coef)
                if k > eobK {
                    // Past the last newly-nonzero: trailing coeffs go
                    // to the EOB run. Buffer correction bits for
                    // already-nonzero ones.
                    if av > 1 { bitBuffer.append(Int(av & 1)) }
                    continue
                }
                if av == 0 { run += 1; continue }
                // Nonzero coef at k ≤ eobK. Emit any pending ZRLs
                // FIRST — libjpeg `encode_mcu_AC_refine` runs the
                // `while (r > 15 && k <= EOB)` loop before *both* the
                // already-nonzero (correction-bit) branch and the
                // newly-nonzero branch. Doing it only for newly-
                // nonzero coeffs (the earlier draft) misorders the ZRL
                // and its buffered correction bits when a >15 zero run
                // precedes an already-nonzero coef — corrupting the
                // refinement scan (content-dependent; hit by some
                // progressive frames).
                while run > 15 {
                    let zrl = acTable[0xF0]
                    writer.writeBits(zrl.code, count: zrl.length)
                    for b in runBuffer { writer.writeBit(b) }
                    runBuffer.removeAll(keepingCapacity: true)
                    run -= 16
                }
                if av > 1 {
                    runBuffer.append(Int(av & 1)); continue
                }
                // av == 1: newly nonzero.
                let sym = (run << 4) | 1
                let e = acTable[sym]
                guard e.length > 0 else {
                    throw JPEGScanEncodeError.blockEncodeFailed(
                        .missingHuffmanSymbol(UInt8(sym)), mcu: bi, comp: 0)
                }
                writer.writeBits(e.code, count: e.length)
                writer.writeBit(coef > 0 ? 1 : 0)   // sign
                for b in runBuffer { writer.writeBit(b) }
                runBuffer.removeAll(keepingCapacity: true)
                run = 0
            }
            // If the block didn't end exactly at a newly-nonzero coef
            // at Se, it contributes an EOB (and its trailing
            // correction bits) to the run.
            if eobK < se {
                eobrun += 1
                if eobrun == 0x7FFF { emitEOBRun() }
            }
            mcuCounter += 1
            if restartInterval > 0
                && mcuCounter % restartInterval == 0
                && bi != total - 1 {
                emitEOBRun()
                writer.flushPaddingOnes()
                writer.appendRawMarker([0xFF, UInt8(0xD0 + (rstCycle & 7))])
                rstCycle += 1
            }
        }
        emitEOBRun()
    }
}
