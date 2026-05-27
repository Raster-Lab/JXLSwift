// `JPEG/JXLToJPEGAdapter.swift` — reverse direction of the JPEG
// coefficient bridge. Inverse of `JPEGToJXLAdapter`. Takes a JXL
// frame produced by the forward bridge plus its accompanying `jbrd`
// box and produces JPEG bytes that match the source JPEG byte-for-
// byte (when the source went through the forward bridge).
//
// Conceptual data flow:
//
// ```
// JXL bytes ──┬─► JXLDecoder.decode → coefficient planes (Y/Cb/Cr)
//             │
// jbrd box ───┼─► JBRDBox: marker order, quant tables, Huffman tables,
//             │              scan info, padding bits
//             │
//             ▼
//   JXLToJPEGAdapter.reconstruct → JPEG bytes (SOI..EOI)
// ```
//
// Phase J step 5i. v0.12.0g0 scaffold.
//
// Implementation order (planned bites, each becomes its own commit):
//
//  1. **Reverse adapter (coefficient planes → JPEGCoefficientImage)**
//     — invert `toJXLCoefficientPlanes()`. Includes:
//       - undo the JPEG-component-to-JXL-channel remap
//         (`remappedForJXLBridge` inverse)
//       - undo the 8×8 transpose (`block[y*8+x] = jpeg[x*8+y]` reverse)
//       - undo the DC offset added by `applyJPEGBridgeDC` for non-
//         DCzero (kNone) color transforms
//  2. **JPEG bitstream writer** — given a `JPEGCoefficientImage`
//     plus Huffman tables from `jbrd`, emit the JPEG SOS payload
//     (Huffman-coded DC + AC coefficients with byte-stuffing).
//  3. **JPEG container assembly** — walk `jbrd.markerOrder` and emit
//     SOI, COM, APP, DQT, SOF, DHT, DRI, SOS, EOI markers in the
//     recorded order, splicing in the marker payloads from `jbrd`
//     and the scan data from step 2.
//  4. **Padding-bit restoration** — re-apply `jbrd.paddingBits` at
//     the end of each scan so the encoded bits match byte-for-byte.

import Foundation

/// Errors raised by the reverse bridge.
public enum JXLToJPEGAdapterError: Error, Sendable {
    /// The JXL frame's coefficient planes don't match the shape
    /// the jbrd box says they should have.
    case shapeMismatch(String)
    /// A jbrd field has an invalid value or references something
    /// missing from the JXL frame.
    case malformedJBRD(String)
    /// A feature in the reverse bridge we haven't implemented yet.
    case notImplemented(String)
}

/// Reverse-bridge entry point. Given a JXL frame (produced by the
/// forward bridge) and its accompanying `jbrd` box, return the
/// byte-identical JPEG bytes.
public enum JXLToJPEGAdapter {

    /// Reconstruct the source JPEG bytes from a JXL frame + jbrd
    /// metadata.
    ///
    /// **Status (v0.12.0g0 scaffold)**. The implementation is split
    /// across several bites (see file header). At this stage we
    /// surface `notImplemented` so callers see a clean throw rather
    /// than wrong output.
    public static func reconstruct(
        coefficients: JXLCoefficientPlanes,
        jbrd: JBRDBox,
        colorTransform: JXLBridgeColorTransform
    ) throws -> Data {
        throw JXLToJPEGAdapterError.notImplemented(
            "JXLToJPEGAdapter.reconstruct — assembly pending; "
            + "see file header for the four-step plan")
    }
}

extension JXLCoefficientPlanes {

    /// Invert `remappedForJXLBridge` — given planes in JXL channel
    /// order (X=Cb, Y, B=Cr), return planes in JPEG component order
    /// (Y, Cb, Cr) for grayscale or 3-component frames.
    public func inverseJXLBridgeRemap(
        colorTransform: JXLBridgeColorTransform
    ) -> JXLCoefficientPlanes {
        if channelCount == 1 { return self }
        precondition(channelCount == 3,
            "inverseJXLBridgeRemap requires 1 or 3 channels")
        let forward = JPEGToJXLAdapter.jpegOrder(
            colorTransform: colorTransform, isGray: false)
        let forwardMap = [forward.0, forward.1, forward.2]
        // Inverse: for each JPEG component `j`, find the JXL slot
        // it ended up in. `inverseMap[j] = i` iff `forwardMap[i] = j`.
        var inverseMap = [Int](repeating: 0, count: 3)
        for i in 0..<3 {
            inverseMap[forwardMap[i]] = i
        }
        let newDC = inverseMap.map { dcPerChannel[$0] }
        let newAC = inverseMap.map { acPerChannel[$0] }
        let newBpc = inverseMap.map { blocksPerChannel[$0] }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: channelCount,
            dcPerChannel: newDC,
            acPerChannel: newAC,
            blocksPerChannel: newBpc)
    }

    /// Invert `applyJPEGBridgeDC` — for `colorTransform == .none`,
    /// subtract the `1024 / qt[DC]` offset that the forward bridge
    /// added. For `.ycbcr` (DCzero=true) the forward pass didn't
    /// modify DC, so this is a no-op.
    public func inverseJPEGBridgeDC(
        colorTransform: JXLBridgeColorTransform,
        quantDCPerChannel: [UInt16]
    ) -> JXLCoefficientPlanes {
        precondition(quantDCPerChannel.count == channelCount,
            "inverseJPEGBridgeDC: quantDCPerChannel.count must "
            + "equal channelCount")
        switch colorTransform {
        case .ycbcr:
            return self
        case .none:
            var newDC = dcPerChannel
            for c in 0..<channelCount {
                let qDC = Int32(quantDCPerChannel[c])
                guard qDC != 0 else { continue }
                let offset = Int32(1024) / qDC
                for i in 0..<newDC[c].count {
                    newDC[c][i] &-= offset
                }
            }
            return JXLCoefficientPlanes(
                blocksX: blocksX, blocksY: blocksY,
                channelCount: channelCount,
                dcPerChannel: newDC,
                acPerChannel: acPerChannel,
                blocksPerChannel: blocksPerChannel)
        }
    }

    /// Build a `JPEGCoefficientImage` from JXL coefficient planes by
    /// inverting both the channel remap and the 8×8 transpose the
    /// forward adapter applied (`ac[k=y*8+x] = jpeg[x*8+y]`).
    ///
    /// **Caller contract.** `self` must be in **JPEG component order**
    /// (i.e. caller has already applied `inverseJXLBridgeRemap` if the
    /// frame was kYCbCr-remapped) and DC values must be in JPEG raw
    /// form (caller has applied `inverseJPEGBridgeDC` if the forward
    /// pass added the `1024/qt[DC]` offset for `.none`).
    ///
    /// Inputs needed beyond `self`:
    ///   - `width`, `height` — SOFn dimensions (from jbrd / source).
    ///   - `frameComponents` — per-component sampling factors + quant
    ///     bindings (mirrors what `JPEGScanHeader.parse` produced for
    ///     the original JPEG; passed in because we don't reconstruct
    ///     SOFn from JXL alone).
    ///   - `quantTables` — per-table zig-zag matrices (from `jbrd`).
    ///   - `precision`, `frameKind` — typically 8 + `.baselineDCT`.
    ///
    /// **v0.12.0g1.** Forward path was:
    ///   `ac[bi][k = y*8+x] = jpeg.coefficients[x*8+y]` (transpose)
    /// Reverse path is the inverse:
    ///   `jpeg.coefficients[x*8+y] = ac[bi][y*8+x]`
    /// DC is just copied straight from `dcPerChannel[c][bi]`.
    public func toJPEGCoefficientImage(
        width: Int, height: Int,
        precision: Int = 8,
        frameKind: JPEGStructure.FrameKind = .baselineDCT,
        frameComponents: [JPEGFrameComponent],
        quantTables: [JPEGQuantTable]
    ) throws -> JPEGCoefficientImage {
        guard frameComponents.count == channelCount else {
            throw JXLToJPEGAdapterError.shapeMismatch(
                "frameComponents.count \(frameComponents.count) ≠ "
                + "channelCount \(channelCount)")
        }
        var components: [JPEGComponentBlocks] = []
        components.reserveCapacity(channelCount)
        for c in 0..<channelCount {
            let bX = blocksPerChannel[c].blocksX
            let bY = blocksPerChannel[c].blocksY
            let total = bX * bY
            guard dcPerChannel[c].count == total else {
                throw JXLToJPEGAdapterError.shapeMismatch(
                    "channel \(c): dcPerChannel.count "
                    + "\(dcPerChannel[c].count) ≠ "
                    + "blocksWide × blocksHigh \(total)")
            }
            guard acPerChannel[c].count == total else {
                throw JXLToJPEGAdapterError.shapeMismatch(
                    "channel \(c): acPerChannel.count "
                    + "\(acPerChannel[c].count) ≠ "
                    + "blocksWide × blocksHigh \(total)")
            }
            var blocks: [JPEGCoefficientBlock] = []
            blocks.reserveCapacity(total)
            for bi in 0..<total {
                var coeffs = [Int32](repeating: 0, count: 64)
                // DC at position 0.
                coeffs[0] = dcPerChannel[c][bi]
                // AC transpose-back: jpeg[x*8 + y] = ac[y*8 + x].
                let acBlock = acPerChannel[c][bi]
                for y in 0..<8 {
                    for x in 0..<8 {
                        let jxlIdx = y * 8 + x
                        if jxlIdx == 0 { continue }
                        coeffs[x * 8 + y] = acBlock[jxlIdx]
                    }
                }
                blocks.append(JPEGCoefficientBlock(coeffs))
            }
            components.append(JPEGComponentBlocks(
                componentId: frameComponents[c].componentId,
                blocksWide: bX, blocksHigh: bY,
                blocks: blocks))
        }
        return JPEGCoefficientImage(
            width: width, height: height,
            precision: precision,
            frameKind: frameKind,
            frameComponents: frameComponents,
            quantisedComponents: components,
            quantTables: quantTables)
    }
}
