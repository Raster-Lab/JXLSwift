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

/// JXL frame `color_transform` choice for the JPEG bridge.
/// Matches libjxl `frame_header.h::ColorTransform`. The choice
/// determines the JPEG-component → JXL-channel mapping (see
/// `JPEGToJXLAdapter.jpegOrder(colorTransform:isGray:)`).
public enum JXLBridgeColorTransform: Sendable, Equatable {
    /// JPEG's YCbCr is treated as YCbCr by JXL — the decoder
    /// applies the YCbCr → RGB conversion at output time. JPEG
    /// component → JXL channel mapping under this mode is
    /// `(1, 0, 2)`: JXL X-slot = JPEG Cb, JXL Y-slot = JPEG Y,
    /// JXL B-slot = JPEG Cr. This is libjxl's choice for its
    /// JPEG transcoder.
    case ycbcr
    /// JPEG components are treated as opaque colour data with no
    /// JXL-side colour transform. Mapping is identity `(0, 1, 2)`.
    case none
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

/// Helper namespace for the JPEG → JXL coefficient bridge.
public enum JPEGToJXLAdapter {

    /// Port of libjxl `frame_header.h::JpegOrder`. Returns the
    /// `(jxlChannel0 → jpegComponent, jxlChannel1 → jpegComponent,
    /// jxlChannel2 → jpegComponent)` mapping for the chosen JXL
    /// `color_transform` and a flag indicating whether the source
    /// is grayscale (1 component).
    ///
    /// - `isGray == true`: returns `(0, 0, 0)` — JXL's three
    ///   channels all read from JPEG component 0.
    /// - `colorTransform == .ycbcr`: returns `(1, 0, 2)` — JXL
    ///   X-slot = Cb, Y-slot = Y, B-slot = Cr.
    /// - `colorTransform == .none`: returns `(0, 1, 2)` — identity.
    public static func jpegOrder(
        colorTransform: JXLBridgeColorTransform,
        isGray: Bool
    ) -> (Int, Int, Int) {
        if isGray { return (0, 0, 0) }
        switch colorTransform {
        case .ycbcr: return (1, 0, 2)
        case .none:  return (0, 1, 2)
        }
    }
}

extension JXLCoefficientPlanes {

    /// Apply the JPEG → JXL DC adjustment that libjxl's
    /// `enc_frame.cc::ComputeJPEGTranscodingData` performs (line
    /// 956 in libjxl 0.11.2): under `ColorTransform::kYCbCr` the
    /// JPEG DC is stored as-is (`DCzero = true`); under
    /// `ColorTransform::kNone` an offset of `1024 / qt[DC]` is
    /// added to each block's DC (`DCzero = false`), recentering
    /// the JPEG raw DC integer into JXL's expected range.
    ///
    /// `quantDCPerChannel` is the DC factor (zig-zag index 0)
    /// of each component's quant table, in the same channel
    /// order as `dcPerChannel`. For 4:4:4 inputs this matches
    /// the order produced by the shape adapter (JPEG component
    /// order; remap to JXL channel slots first if you've already
    /// applied `remappedForJXLBridge`).
    ///
    /// **What this does NOT do.** The AC-side CFL (chroma-from-
    /// luma) decorrelation that libjxl applies when
    /// `cparams.force_cfl_jpeg_recompression` is set is **off**
    /// by default in libjxl's own transcoder. Matching that
    /// default we don't apply it here; it can be a follow-on
    /// bite once the bridge has end-to-end pixel verification.
    public func applyJPEGBridgeDC(
        colorTransform: JXLBridgeColorTransform,
        quantDCPerChannel: [UInt16]
    ) -> JXLCoefficientPlanes {
        precondition(quantDCPerChannel.count == channelCount,
            "applyJPEGBridgeDC: quantDCPerChannel.count must "
            + "equal channelCount")
        var newDC = dcPerChannel
        switch colorTransform {
        case .ycbcr:
            // DCzero — DC stored as-is, no offset.
            break
        case .none:
            // Add 1024 / qt[DC] to every block of every channel.
            // Integer division matches libjxl's `1024 / qt[c*64]`.
            for c in 0..<channelCount {
                let qDC = Int32(quantDCPerChannel[c])
                guard qDC != 0 else {
                    // Should never happen — JPEG quant tables
                    // reject zero entries at parse time. If it
                    // does, leave DC unchanged rather than
                    // dividing by zero.
                    continue
                }
                let offset = Int32(1024) / qDC
                for i in 0..<newDC[c].count {
                    newDC[c][i] &+= offset
                }
            }
        }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: channelCount,
            dcPerChannel: newDC,
            acPerChannel: acPerChannel)
    }

    /// Reorder per-channel planes by the JPEG → JXL channel map
    /// for the chosen `color_transform`. Returns a new
    /// `JXLCoefficientPlanes` whose `dcPerChannel[i]` /
    /// `acPerChannel[i]` are the source's `[jpegOrder[i]]`. For
    /// grayscale (`channelCount == 1`) the input is returned
    /// unchanged.
    ///
    /// This is the channel-permutation that takes the
    /// adapter's output (JPEG channel order, [Y, Cb, Cr]) to JXL's
    /// XYB-slot order ([Cb, Y, Cr] under kYCbCr; [Y, Cb, Cr]
    /// under kNone).
    public func remappedForJXLBridge(
        colorTransform: JXLBridgeColorTransform
    ) -> JXLCoefficientPlanes {
        if channelCount == 1 { return self }
        precondition(channelCount == 3,
            "remappedForJXLBridge requires 1 or 3 channels")
        let order = JPEGToJXLAdapter.jpegOrder(
            colorTransform: colorTransform, isGray: false)
        let mapping = [order.0, order.1, order.2]
        let newDC = mapping.map { dcPerChannel[$0] }
        let newAC = mapping.map { acPerChannel[$0] }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: 3,
            dcPerChannel: newDC,
            acPerChannel: newAC)
    }
}

/// The data the eventual JXL bridge encoder will need to inject
/// a JPEG-derived quantisation table into the JXL DequantMatrices
/// payload via `kQuantModeRAW` (libjxl `quant_weights.h::RAW`).
///
/// - `qtable`: `3 × 64` Int32 values in JXL coef layout (channel-
///   major, **transposed** from JPEG natural order within each
///   8×8 — JXL's `ComputeScaledDCT` swaps rows and cols relative
///   to JPEG's row-major DCT layout, so the quant table follows).
/// - `qtableDen`: `1 / (8 × 255)` — the canonical value libjxl's
///   JPEG transcoder hard-codes (`quant_weights.h:181`,
///   `enc_modular.cc:1751`). Combined with `qtable[i]` via
///   `weight[i] = 1 / (qtableDen × qtable[i])` (the math from
///   v0.12.0f) this yields `weight = 8 × 255 / qtable[i]` per
///   coefficient — the JPEG quant value treated as a JXL weight.
/// - `dcQuantization`: per-channel `255 × 8 / qtableDC` —
///   feeds the JXL `DequantMatrices` DC slot (libjxl
///   `DequantMatricesSetCustomDC`).
public struct JXLBridgeRAWQuantPayload: Sendable {
    public let qtable: [Int32]
    public let qtableDen: Float
    public let dcQuantization: [Float]

    public init(qtable: [Int32], qtableDen: Float,
                dcQuantization: [Float]) {
        precondition(qtable.count == 3 * 64,
            "JXLBridgeRAWQuantPayload.qtable must be 3×64")
        precondition(dcQuantization.count == 3,
            "JXLBridgeRAWQuantPayload.dcQuantization must be "
            + "3 entries")
        self.qtable = qtable
        self.qtableDen = qtableDen
        self.dcQuantization = dcQuantization
    }
}

extension JPEGCoefficientImage {

    /// Build the RAW quant-matrix payload (step 3.4 from
    /// `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`) from this
    /// JPEG coefficient image's quant tables. Port of libjxl
    /// `enc_frame.cc::ComputeJPEGTranscodingData` lines 770–799
    /// (the `qt[192]` build + `QuantEncoding::RAW(std::move(qt))`).
    ///
    /// Three concerns it handles:
    ///
    ///   1. **Channel reorder** per `JpegOrder(colorTransform,
    ///      isGray)` (libjxl `frame_header.h::JpegOrder`). For 3-
    ///      component YCbCr inputs under `.ycbcr` the mapping is
    ///      `(1, 0, 2)` — JXL X-slot ← JPEG Cb's quant table,
    ///      JXL Y-slot ← JPEG Y's quant table, JXL B-slot ←
    ///      JPEG Cr's quant table. Grayscale `(0, 0, 0)` reads
    ///      JPEG component 0's quant table for all three slots.
    ///
    ///   2. **Zig-zag → natural** unpacking. Our
    ///      `JPEGQuantTable.zigZagValues` is zig-zag-ordered (as
    ///      the DQT payload stores it); libjxl's
    ///      `jpeg_data.quant[].values` is natural-order.
    ///
    ///   3. **Transpose** to JXL coef layout. libjxl comment:
    ///      "JPEG XL transposes the DCT, JPEG doesn't." So
    ///      `qt[c * 64 + 8 * x + y] = naturalQuant[8 * y + x]`.
    ///
    /// Returns a populated `JXLBridgeRAWQuantPayload` ready for
    /// the bridge encoder to package into `DequantMatrices` via
    /// `kQuantModeRAW`. The actual bitstream-write step
    /// (Modular sub-image of the qtable) is step 3.5+ work.
    public func buildJXLBridgeRAWQuantPayload(
        colorTransform: JXLBridgeColorTransform
    ) -> JXLBridgeRAWQuantPayload {
        let nc = frameComponents.count
        let isGray = (nc == 1)
        let order = JPEGToJXLAdapter.jpegOrder(
            colorTransform: colorTransform, isGray: isGray)
        let mapping = [order.0, order.1, order.2]

        var qt = [Int32](repeating: 1, count: 3 * 64)
        var dcQ = [Float](repeating: 1.0, count: 3)

        for jxlChannel in 0..<3 {
            let jpegC = mapping[jxlChannel]
            guard jpegC < nc else { continue }
            // Pull the quant table this JPEG component points at.
            let qtId = frameComponents[jpegC].quantTableId
            guard let qtable = quantTables.first(
                where: { $0.tableId == qtId }) else {
                continue
            }
            // Zig-zag → natural unpack. JPEG zig-zag position k
            // maps to natural row-major index `JPEGZigZag.order[k]`.
            var naturalQuant = [Int32](
                repeating: 1, count: 64)
            for k in 0..<64 {
                naturalQuant[JPEGZigZag.order[k]] =
                    Int32(qtable.zigZagValues[k])
            }
            // DC quantization per channel: 255 × 8 / qt[0].
            // qt[0] in natural order is the DC factor.
            let qDC = naturalQuant[0]
            dcQ[jxlChannel] = qDC != 0
                ? 255.0 * 8.0 / Float(qDC)
                : 1.0
            // Transpose into JXL's coef layout (rows ↔ cols).
            for y in 0..<8 {
                for x in 0..<8 {
                    qt[jxlChannel * 64 + 8 * x + y] =
                        naturalQuant[8 * y + x]
                }
            }
        }

        return JXLBridgeRAWQuantPayload(
            qtable: qt,
            qtableDen: 1.0 / (8.0 * 255.0),
            dcQuantization: dcQ)
    }

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
