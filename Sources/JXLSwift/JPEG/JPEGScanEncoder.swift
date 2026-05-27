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
public enum JPEGScanEncodeError: Error, Sendable, Equatable {
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
public struct JPEGScanComponentEncode: Sendable, Equatable {
    public var componentIndex: Int       // index into `components`
    public var dcTableId: Int            // 0..3
    public var acTableId: Int            // 0..3
    public init(
        componentIndex: Int,
        dcTableId: Int, acTableId: Int
    ) {
        self.componentIndex = componentIndex
        self.dcTableId = dcTableId
        self.acTableId = acTableId
    }
}

public enum JPEGScanEncoder {

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
    public static func encodeBaselineSequential(
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
}
