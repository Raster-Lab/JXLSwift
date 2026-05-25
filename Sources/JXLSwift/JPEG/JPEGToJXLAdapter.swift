// Shape-adapter between the JPEG decode side and the JXL VarDCT
// encode side — first concrete piece of step 3 from the
// `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md` design doc.
//
// Converts a `JPEGCoefficientImage` (per-component quantised DCT
// coefficients in natural row-major order, JPEG channel order
// [Y, Cb, Cr]) into the JXL VarDCT bitstream writer's coefficient
// shape: per-channel DC plane + per-block per-channel AC arrays in
// XYB index order (X = 0 / Cb-equivalent, Y = 1 / Y-equivalent,
// B = 2 / Cr-equivalent).
//
// **Scope (v0.12.0i):** 4:4:4 chroma sampling only — every
// component must have the same `(H, V) = (H_max, V_max)` sampling
// factors, i.e. identical block grids. Subsampled chroma (4:2:2,
// 4:2:0) bridges to JXL's `chroma_subsampling` frame-header fields
// and is more involved; future bites lift the restriction.
//
// **Scope (v0.12.0i):** 1- and 3-component frames only — matches
// the `JPEGDecoder.decode(_:)` envelope.
//
// **What this layer does NOT do:**
//   - Color decorrelation (`B − Y`) — JXL's CFL (chroma-from-luma)
//     handling on the bridge path is its own bite; for now we hand
//     off the raw JPEG quantised values per component and let the
//     bridge encoder decide whether to recorrelate.
//   - Quant-matrix selection — the bridge encoder will pass the
//     `JPEGCoefficientImage.quantTables` through `kQuantModeRAW`
//     (v0.12.0f) when it lands.
//   - Frame-header construction — `color_transform = None`,
//     `chroma_subsampling = (0, 0)` for 4:4:4, all-DCT8×8 strategy
//     plane. Those are the bridge encoder's job.

import Foundation

/// Per-channel quantised DC + AC coefficient planes in the shape
/// the JXL VarDCT bitstream writer consumes.
///
/// - `dcPerChannel[channel][by * blocksX + bx]`: integer DC value.
/// - `acPerChannel[channel][firstBlockIdx][position 0..63]`:
///   integer AC value at natural-order position (position 0 is
///   left zero since DC is carried in `dcPerChannel`).
/// - `blocksX`, `blocksY`: shared block grid (4:4:4 only).
/// - `channelCount`: 1 for grayscale, 3 for 3-component (Y / Cb /
///   Cr; bridge encoder maps to JXL X / Y / B).
public struct JXLCoefficientPlanes: Sendable {
    public let blocksX: Int
    public let blocksY: Int
    public let channelCount: Int
    public let dcPerChannel: [[Int32]]
    public let acPerChannel: [[[Int32]]]

    public init(
        blocksX: Int, blocksY: Int, channelCount: Int,
        dcPerChannel: [[Int32]], acPerChannel: [[[Int32]]]
    ) {
        precondition(channelCount == 1 || channelCount == 3,
            "JXLCoefficientPlanes: channelCount must be 1 or 3")
        precondition(dcPerChannel.count == channelCount,
            "JXLCoefficientPlanes: dcPerChannel must have "
            + "\(channelCount) entries")
        precondition(acPerChannel.count == channelCount,
            "JXLCoefficientPlanes: acPerChannel must have "
            + "\(channelCount) entries")
        let totalBlocks = blocksX * blocksY
        for ch in 0..<channelCount {
            precondition(dcPerChannel[ch].count == totalBlocks,
                "JXLCoefficientPlanes: dcPerChannel[\(ch)] "
                + "count must equal blocksX × blocksY")
            precondition(acPerChannel[ch].count == totalBlocks,
                "JXLCoefficientPlanes: acPerChannel[\(ch)] "
                + "count must equal blocksX × blocksY")
        }
        self.blocksX = blocksX
        self.blocksY = blocksY
        self.channelCount = channelCount
        self.dcPerChannel = dcPerChannel
        self.acPerChannel = acPerChannel
    }
}

/// Errors specific to the JPEG → JXL coefficient adapter.
public enum JPEGToJXLAdapterError: Error, Sendable, Equatable,
                                   LocalizedError {
    /// Components have non-uniform sampling factors. The 4:4:4
    /// fast path in v0.12.0i requires identical `(H, V)` across
    /// all components. Subsampled chroma is a follow-on bite.
    case nonUniformSampling(String)
    /// Component count is outside the supported envelope.
    case unsupportedComponentCount(Int)

    public var errorDescription: String? {
        switch self {
        case .nonUniformSampling(let m):
            return "JPEG → JXL adapter: \(m)"
        case .unsupportedComponentCount(let n):
            return "JPEG → JXL adapter: \(n)-component frames "
                + "not supported (only 1 or 3)"
        }
    }
}

extension JPEGCoefficientImage {

    /// Convert this JPEG coefficient image into per-channel
    /// quantised DC + AC planes ready for the JXL VarDCT bridge
    /// encoder. **4:4:4 only** in this v0.12.0i bite — throws
    /// `.nonUniformSampling` for chroma-subsampled inputs.
    ///
    /// Channel order is preserved (component[0] → plane[0], etc.);
    /// the bridge encoder decides how to map these to XYB indices
    /// (typically JPEG Y → JXL Y = index 1, JPEG Cb → JXL X =
    /// index 0, JPEG Cr → JXL B = index 2).
    public func toJXLCoefficientPlanes(
    ) throws -> JXLCoefficientPlanes {
        let nch = frameComponents.count
        guard nch == 1 || nch == 3 else {
            throw JPEGToJXLAdapterError
                .unsupportedComponentCount(nch)
        }

        // 4:4:4 invariant: all components must share (H, V).
        // Detect by comparing every component to the first.
        let h0 = frameComponents[0].hSamplingFactor
        let v0 = frameComponents[0].vSamplingFactor
        for fc in frameComponents.dropFirst() {
            if fc.hSamplingFactor != h0
               || fc.vSamplingFactor != v0 {
                throw JPEGToJXLAdapterError.nonUniformSampling(
                    "components have different (H, V) sampling "
                    + "factors: this is chroma-subsampled JPEG "
                    + "(e.g. 4:2:0 or 4:2:2); the v0.12.0i "
                    + "bridge adapter handles 4:4:4 only — "
                    + "subsampled chroma is a follow-on bite.")
            }
        }

        // 4:4:4 — every component has the same block grid.
        // Pick component 0's grid as canonical.
        let blocksX = quantisedComponents[0].blocksWide
        let blocksY = quantisedComponents[0].blocksHigh
        let totalBlocks = blocksX * blocksY

        // Sanity: every component's grid must agree under 4:4:4.
        for ch in 1..<nch {
            let cb = quantisedComponents[ch]
            guard cb.blocksWide == blocksX,
                  cb.blocksHigh == blocksY else {
                throw JPEGToJXLAdapterError.nonUniformSampling(
                    "component \(ch) has "
                    + "\(cb.blocksWide)×\(cb.blocksHigh) "
                    + "blocks vs canonical "
                    + "\(blocksX)×\(blocksY); 4:4:4 invariant "
                    + "violated even though sampling factors "
                    + "matched (this would be a structural bug)")
            }
        }

        // Walk per channel: split each block into DC (position 0)
        // and AC (positions 1..63 with position 0 left zero).
        var dcPlanes = [[Int32]]()
        var acPlanes = [[[Int32]]]()
        dcPlanes.reserveCapacity(nch)
        acPlanes.reserveCapacity(nch)
        for ch in 0..<nch {
            var dc = [Int32](repeating: 0, count: totalBlocks)
            var ac = [[Int32]](
                repeating: [Int32](repeating: 0, count: 64),
                count: totalBlocks)
            for bi in 0..<totalBlocks {
                let block = quantisedComponents[ch].blocks[bi]
                dc[bi] = block.coefficients[0]
                for k in 1..<64 {
                    ac[bi][k] = block.coefficients[k]
                }
                // Position 0 of ac[bi] is intentionally 0 —
                // libjxl's VarDCT bitstream stores LLF
                // separately and zeros position 0 in the AC array.
            }
            dcPlanes.append(dc)
            acPlanes.append(ac)
        }

        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: nch,
            dcPerChannel: dcPlanes,
            acPerChannel: acPlanes)
    }
}
