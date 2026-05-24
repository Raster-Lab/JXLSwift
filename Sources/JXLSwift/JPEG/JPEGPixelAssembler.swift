// Assemble per-component sample planes from decoded coefficient
// blocks — eleventh step on the Phase J road. Walks each
// component's `JPEGComponentBlocks` grid, runs IDCT on each block,
// stitches the 8×8 sample tiles into a flat row-major plane sized
// to the component's full block grid.
//
// Chroma upsampling is handled separately by `upsampleNearest(...)`
// and `upsampleBilinear(...)` — at this layer each component is
// just "the dequantised sample plane for *this* component at *its*
// resolution". Callers that want full-resolution chroma feed the
// chroma planes through one of the upsamplers before YCbCr → RGB.
//
// Edge cropping: a component's block grid may extend past the
// nominal `(imageWidth × H_i / H_max) × (imageHeight × V_i / V_max)`
// sample extent (because the JPEG encoder emits whole 8×8 blocks).
// We don't crop here — that's a display-time decision and the
// transcoder cares about the full block grid.

import Foundation

/// One decoded sample plane for a single JPEG component. The
/// stored grid is the full block-aligned width/height; the
/// nominal "visible" width/height comes from the SOFn frame
/// dimensions scaled by the component's sampling factors.
public struct JPEGSamplePlane: Sendable {
    public let componentId: Int
    /// Pixel width of the stored plane — always a multiple of 8.
    public let width: Int
    /// Pixel height of the stored plane — always a multiple of 8.
    public let height: Int
    /// `samples[y * width + x]`. Element type is `Int32` so 12-bit
    /// extended-precision JPEGs round-trip without truncation; for
    /// 8-bit the values fit in 0..255.
    public var samples: [Int32]

    public init(componentId: Int, width: Int, height: Int,
                samples: [Int32]) {
        precondition(samples.count == width * height,
            "JPEGSamplePlane: samples count must equal w*h")
        self.componentId = componentId
        self.width = width
        self.height = height
        self.samples = samples
    }
}

public enum JPEGPixelAssembler {

    /// Take per-component blocks (from `JPEGScanDecoder`),
    /// dequantise each one with the right quant table, run IDCT,
    /// and stitch the resulting sample tiles into a flat plane.
    /// Returns one plane per input component, in the same order.
    public static func assemble(
        componentBlocks: [JPEGComponentBlocks],
        frameComponents: [JPEGFrameComponent],
        quantTables: [JPEGQuantTable],
        precision: Int = 8
    ) throws -> [JPEGSamplePlane] {
        var planes: [JPEGSamplePlane] = []
        planes.reserveCapacity(componentBlocks.count)
        for cb in componentBlocks {
            guard let fc = frameComponents.first(
                where: { $0.componentId == cb.componentId })
            else {
                throw JPEGAssembleError.unknownComponent(
                    componentId: cb.componentId)
            }
            guard let qt = quantTables.first(
                where: { $0.tableId == fc.quantTableId })
            else {
                throw JPEGAssembleError.missingQuantTable(
                    tableId: fc.quantTableId)
            }
            let pw = cb.blocksWide * 8
            let ph = cb.blocksHigh * 8
            var samples = [Int32](
                repeating: 0, count: pw * ph)
            for by in 0..<cb.blocksHigh {
                for bx in 0..<cb.blocksWide {
                    let block = cb.blocks[by * cb.blocksWide + bx]
                    let dq = JPEGDequantiser.dequantising(
                        block, using: qt)
                    let tile = JPEGIDCT.inverseTransform(
                        dq, precision: precision)
                    // Stitch tile into the plane at (bx*8, by*8).
                    for ty in 0..<8 {
                        let dstRow = (by * 8 + ty) * pw + bx * 8
                        for tx in 0..<8 {
                            samples[dstRow + tx]
                                = tile[ty * 8 + tx]
                        }
                    }
                }
            }
            planes.append(JPEGSamplePlane(
                componentId: cb.componentId,
                width: pw, height: ph,
                samples: samples))
        }
        return planes
    }

    /// Nearest-neighbour upsample of `plane` to `(targetWidth,
    /// targetHeight)`. Both targets must be ≥ the plane's
    /// dimensions and evenly divisible by them — that's what
    /// JPEG's whole-integer sampling factors guarantee
    /// (`H_max / H_i`, `V_max / V_i`).
    public static func upsampleNearest(
        _ plane: JPEGSamplePlane,
        toWidth targetWidth: Int, height targetHeight: Int
    ) -> JPEGSamplePlane {
        if plane.width == targetWidth && plane.height == targetHeight {
            return plane
        }
        precondition(
            targetWidth >= plane.width
            && targetHeight >= plane.height
            && targetWidth % plane.width == 0
            && targetHeight % plane.height == 0,
            "upsampleNearest: target must be an integer multiple "
            + "of the source size")
        let xRatio = targetWidth / plane.width
        let yRatio = targetHeight / plane.height
        var out = [Int32](
            repeating: 0, count: targetWidth * targetHeight)
        for y in 0..<targetHeight {
            let srcY = y / yRatio
            let srcRow = srcY * plane.width
            let dstRow = y * targetWidth
            for x in 0..<targetWidth {
                out[dstRow + x] = plane.samples[srcRow + (x / xRatio)]
            }
        }
        return JPEGSamplePlane(
            componentId: plane.componentId,
            width: targetWidth, height: targetHeight,
            samples: out)
    }
}

/// Errors raised when the component / quant-table set passed to
/// the assembler doesn't line up.
public enum JPEGAssembleError: Error, Sendable, Equatable,
                               LocalizedError {
    case unknownComponent(componentId: Int)
    case missingQuantTable(tableId: Int)

    public var errorDescription: String? {
        switch self {
        case .unknownComponent(let c):
            return "JPEG pixel assembler: component \(c) not in frame"
        case .missingQuantTable(let t):
            return "JPEG pixel assembler: quant table \(t) missing"
        }
    }
}
