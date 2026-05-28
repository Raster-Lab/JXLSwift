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
/// - `dcPerChannel[channel][by * blocksPerChannel[channel].x + bx]`:
///   integer DC value at channel's own block grid.
/// - `acPerChannel[channel][firstBlockIdx][position 0..63]`:
///   integer AC value at natural-order position (position 0 is
///   left zero since DC is carried in `dcPerChannel`).
/// - `blocksPerChannel[channel]`: per-channel `(blocksX, blocksY)`.
///   For 4:4:4 frames all entries are equal; for chroma-subsampled
///   frames the chroma channels have smaller grids.
/// - `blocksX`, `blocksY`: **maximum** (Y-channel = full-resolution)
///   block grid — useful as a canonical reference for AC group
///   iteration. Equals `blocksPerChannel` of the Y slot (channel 1
///   in libjxl color order under `kYCbCr`).
/// - `channelCount`: 1 for grayscale, 3 for 3-component (Y / Cb /
///   Cr; bridge encoder maps to JXL X / Y / B).
public struct JXLCoefficientPlanes: Sendable {
    public let blocksX: Int
    public let blocksY: Int
    public let channelCount: Int
    /// Per-channel block grid dimensions. `blocksPerChannel[ch] =
    /// (cx, cy)` is the number of blocks for channel `ch`. For
    /// 4:4:4 each entry equals `(blocksX, blocksY)`. For 4:2:0
    /// (kYCbCr remap = [Cb, Y, Cr]): `[(cx/2, cy/2), (cx, cy),
    /// (cx/2, cy/2)]`.
    public let blocksPerChannel: [(blocksX: Int, blocksY: Int)]
    public let dcPerChannel: [[Int32]]
    public let acPerChannel: [[[Int32]]]

    public init(
        blocksX: Int, blocksY: Int, channelCount: Int,
        dcPerChannel: [[Int32]], acPerChannel: [[[Int32]]],
        blocksPerChannel: [(blocksX: Int, blocksY: Int)]? = nil
    ) {
        precondition(channelCount == 1 || channelCount == 3,
            "JXLCoefficientPlanes: channelCount must be 1 or 3")
        precondition(dcPerChannel.count == channelCount,
            "JXLCoefficientPlanes: dcPerChannel must have "
            + "\(channelCount) entries")
        precondition(acPerChannel.count == channelCount,
            "JXLCoefficientPlanes: acPerChannel must have "
            + "\(channelCount) entries")
        // Default per-channel dims to (blocksX, blocksY) for all
        // channels (the 4:4:4 fast path). The adapter sets explicit
        // values for subsampled inputs.
        let resolved: [(blocksX: Int, blocksY: Int)]
        if let bpc = blocksPerChannel {
            precondition(bpc.count == channelCount,
                "JXLCoefficientPlanes: blocksPerChannel must have "
                + "\(channelCount) entries")
            resolved = bpc
        } else {
            resolved = Array(
                repeating: (blocksX, blocksY),
                count: channelCount)
        }
        for ch in 0..<channelCount {
            let total = resolved[ch].blocksX * resolved[ch].blocksY
            precondition(dcPerChannel[ch].count == total,
                "JXLCoefficientPlanes: dcPerChannel[\(ch)] count "
                + "\(dcPerChannel[ch].count) ≠ "
                + "\(resolved[ch].blocksX) × \(resolved[ch].blocksY)")
            precondition(acPerChannel[ch].count == total,
                "JXLCoefficientPlanes: acPerChannel[\(ch)] count "
                + "\(acPerChannel[ch].count) ≠ "
                + "\(resolved[ch].blocksX) × \(resolved[ch].blocksY)")
        }
        self.blocksX = blocksX
        self.blocksY = blocksY
        self.channelCount = channelCount
        self.blocksPerChannel = resolved
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
            acPerChannel: acPerChannel,
            blocksPerChannel: blocksPerChannel)
    }

    /// Expand a 1-channel (grayscale) plane set into the 3-channel
    /// YCbCr layout libjxl uses for grayscale JPEG transcode: the
    /// lone luma goes to the Y (XYB index 1) channel, X (0) and B (2)
    /// are all-zero. libjxl's VarDCT/colour machinery is inherently
    /// 3-channel — a 1-channel VarDCT frame is rejected by its
    /// decoder — so the forward bridge writes 3 channels even though
    /// the image metadata stays grayscale (the inverse of the reverse
    /// path's `extractingChannel(1)`).
    public func expandGrayscaleToThreeChannel() -> JXLCoefficientPlanes {
        precondition(channelCount == 1,
            "expandGrayscaleToThreeChannel requires 1 channel")
        let bpc = blocksPerChannel[0]
        let nBlocks = bpc.blocksX * bpc.blocksY
        let zeroDC = [Int32](repeating: 0, count: nBlocks)
        let zeroAC = Array(
            repeating: [Int32](repeating: 0, count: 64),
            count: nBlocks)
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY, channelCount: 3,
            dcPerChannel: [zeroDC, dcPerChannel[0], zeroDC],
            acPerChannel: [zeroAC, acPerChannel[0], zeroAC],
            blocksPerChannel: [bpc, bpc, bpc])
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
        // Per-channel block dims follow the same remap.
        let newBpc = mapping.map { blocksPerChannel[$0] }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: 3,
            dcPerChannel: newDC,
            acPerChannel: newAC,
            blocksPerChannel: newBpc)
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

/// All the JXL `FrameHeader` parameters the bridge encoder needs
/// to set, derived from the `JPEGCoefficientImage` and the
/// caller's choice of `color_transform`. Step 3.5 from
/// `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`.
///
/// Returned as a typed struct rather than a built `FrameHeader`
/// because the bridge encoder will assemble the rest of the
/// header (frame type, animation fields, blending info, etc.)
/// from its own state. This layer just resolves the
/// JPEG-derived fields.
public struct JXLBridgeFrameHeaderParams: Sendable, Equatable {
    /// `color_transform`. For .ycbcr the JXL decoder applies
    /// YCbCr → RGB at output. For .none JXL treats the channels
    /// as opaque colour data with no conversion.
    public let colorTransform: ColorTransform
    /// `chroma_subsampling`. For 4:4:4 (which is all the
    /// v0.12.0i adapter supports) this is all zeros.
    public let chromaSubsampling: YCbCrChromaSubsampling
    /// `loop_filter`. JPEG decoding doesn't apply Gaborish or
    /// EPF, so the bridge disables both so the JXL decode
    /// pipeline matches JPEG's. `gab = false, epfIters = 0`.
    public let loopFilter: LoopFilter
    /// `encoding`. Always VarDCT for the bridge.
    public let encoding: FrameEncoding
}

extension JPEGCoefficientImage {

    /// Build the JXL frame-header parameters the bridge encoder
    /// needs to set (step 3.5). **v0.12.0ft**: computes
    /// `chroma_subsampling` from the JPEG `(H, V)` sampling
    /// factors, supporting 4:4:4 / 4:2:0 / 4:2:2 (horizontal or
    /// vertical).
    public func buildJXLBridgeFrameHeaderParams(
        colorTransform: JXLBridgeColorTransform
    ) -> JXLBridgeFrameHeaderParams {
        let jxlCT: ColorTransform
        switch colorTransform {
        case .ycbcr: jxlCT = .yCbCr
        case .none:  jxlCT = .none
        }
        // libjxl `YCbCrChromaSubsampling::Set(hsample, vsample)`
        // walks JPEG-order sampling factors and picks the mode for
        // each libjxl channel `c` (`c < 2 ? c ^ 1 : c`):
        //   mode i where `(1 << kHShift[i]) == hsample[cjpeg]` and
        //                `(1 << kVShift[i]) == vsample[cjpeg]`.
        //   kHShift = {0, 1, 1, 0}, kVShift = {0, 1, 0, 1}.
        // We mirror that lookup here. Grayscale → all zeros.
        let css: YCbCrChromaSubsampling
        if frameComponents.count == 1 {
            css = YCbCrChromaSubsampling()
        } else {
            let kH: [UInt32] = [0, 1, 1, 0]
            let kV: [UInt32] = [0, 1, 0, 1]
            func modeFor(_ h: UInt32, _ v: UInt32) -> UInt32 {
                let want_h: UInt32 = h == 2 ? 1 : 0
                let want_v: UInt32 = v == 2 ? 1 : 0
                for i in 0..<4 {
                    if kH[i] == want_h && kV[i] == want_v {
                        return UInt32(i)
                    }
                }
                return 0  // fallback; should never reach here
            }
            // JPEG order: [Y=comp 0, Cb=comp 1, Cr=comp 2].
            // libjxl channel order: [X=Cb, Y, B=Cr] = JPEG [1, 0, 2].
            let yH = UInt32(frameComponents[0].hSamplingFactor)
            let yV = UInt32(frameComponents[0].vSamplingFactor)
            let cbH = UInt32(frameComponents[1].hSamplingFactor)
            let cbV = UInt32(frameComponents[1].vSamplingFactor)
            let crH = UInt32(frameComponents[2].hSamplingFactor)
            let crV = UInt32(frameComponents[2].vSamplingFactor)
            // YCbCrChromaSubsampling.write writes (channelModes.0,
            // channelModes.1, channelModes.2) = (Cb, Y, Cr) order.
            // Our struct's init labels them (y:, cb:, cr:) but
            // stores them at positions 0/1/2 as (y, cb, cr).
            // libjxl reads them at index c. So channelModes[c]:
            //   c=0 (libjxl X=Cb): mode of Cb
            //   c=1 (libjxl Y):    mode of Y
            //   c=2 (libjxl B=Cr): mode of Cr
            css = YCbCrChromaSubsampling(
                y: modeFor(cbH, cbV),   // channelModes.0 = Cb
                cb: modeFor(yH, yV),    // channelModes.1 = Y
                cr: modeFor(crH, crV))  // channelModes.2 = Cr
        }
        // JPEG decoding doesn't apply Gaborish/EPF, so disable
        // both. The non-default-LoopFilter writer in
        // `LoopFilter.write` supports `gab = false, epfIters = 0`
        // directly (this is the "Modular case" path).
        let lf = LoopFilter(
            allDefault: false, gab: false, epfIters: 0)
        return JXLBridgeFrameHeaderParams(
            colorTransform: jxlCT,
            chromaSubsampling: css,
            loopFilter: lf,
            encoding: .varDCT)
    }

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
    /// encoder.
    ///
    /// **v0.12.0ft**: Supports 4:4:4 and 4:2:0 / 4:2:2 chroma-
    /// subsampled inputs. The output `JXLCoefficientPlanes` carries
    /// per-channel block dimensions in `blocksPerChannel`. Any
    /// other sampling shape (asymmetric per-channel factors that
    /// don't fit one of `H1V1` / `H2V2` / `H2V1` / `H1V2`) throws
    /// `.nonUniformSampling`.
    ///
    /// Channel order is preserved (JPEG component `i` → JXL plane
    /// `i`); the bridge encoder applies the JpegOrder remap
    /// downstream to land Y at the JXL Y slot (index 1) etc.
    public func toJXLCoefficientPlanes(
    ) throws -> JXLCoefficientPlanes {
        let nch = frameComponents.count
        guard nch == 1 || nch == 3 else {
            throw JPEGToJXLAdapterError
                .unsupportedComponentCount(nch)
        }

        // Per-component sampling factors. For grayscale (nch=1)
        // there's only the Y component and the H/V are degenerate.
        // For 3-component, libjxl supports the four hsample/vsample
        // shapes that map to JXL chroma_subsampling modes:
        //   Y=H2V2, Cb=H1V1, Cr=H1V1  → 4:2:0
        //   Y=H2V1, Cb=H1V1, Cr=H1V1  → 4:2:2 (horizontal subsample)
        //   Y=H1V2, Cb=H1V1, Cr=H1V1  → 4:2:2 (vertical subsample)
        //   Y=H1V1, Cb=H1V1, Cr=H1V1  → 4:4:4
        // The Y component (index 0 in JPEG order) must have the
        // largest sampling factors; chroma must be H1V1.
        if nch == 3 {
            let yH = frameComponents[0].hSamplingFactor
            let yV = frameComponents[0].vSamplingFactor
            // Chroma components must be H1V1.
            for c in 1..<nch {
                let fc = frameComponents[c]
                guard fc.hSamplingFactor == 1
                    && fc.vSamplingFactor == 1 else {
                    throw JPEGToJXLAdapterError.nonUniformSampling(
                        "component \(c) sampling H\(fc.hSamplingFactor)V"
                        + "\(fc.vSamplingFactor) — bridge supports "
                        + "only chroma at H1V1 (chroma upsampling "
                        + "from JXL chroma_subsampling field)")
                }
            }
            // Y must be one of H1V1 / H2V1 / H1V2 / H2V2.
            guard (yH == 1 || yH == 2) && (yV == 1 || yV == 2) else {
                throw JPEGToJXLAdapterError.nonUniformSampling(
                    "Y component sampling H\(yH)V\(yV) outside "
                    + "supported set {H1V1, H2V1, H1V2, H2V2}")
            }
        }

        // Per-component block dims. JPEG component 0 (Y) is the
        // FULL-resolution grid; chroma blocks are scaled down.
        var blocksXPerComp = [Int](repeating: 0, count: nch)
        var blocksYPerComp = [Int](repeating: 0, count: nch)
        for c in 0..<nch {
            blocksXPerComp[c] = quantisedComponents[c].blocksWide
            blocksYPerComp[c] = quantisedComponents[c].blocksHigh
        }
        // Canonical (max = Y) block dim.
        let blocksX = blocksXPerComp[0]
        let blocksY = blocksYPerComp[0]

        // Walk per channel: split each block into DC (position 0)
        // and AC (positions 1..63 with position 0 left zero).
        var dcPlanes = [[Int32]]()
        var acPlanes = [[[Int32]]]()
        dcPlanes.reserveCapacity(nch)
        acPlanes.reserveCapacity(nch)
        for ch in 0..<nch {
            let bX = blocksXPerComp[ch]
            let bY = blocksYPerComp[ch]
            let totalBlocks = bX * bY
            var dc = [Int32](repeating: 0, count: totalBlocks)
            var ac = [[Int32]](
                repeating: [Int32](repeating: 0, count: 64),
                count: totalBlocks)
            for bi in 0..<totalBlocks {
                let block = quantisedComponents[ch].blocks[bi]
                dc[bi] = block.coefficients[0]
                // **Transpose** JPEG natural order (row=y, col=x at
                // index `8y + x`) → JXL natural order. libjxl's
                // VarDCT block layout swaps rows and columns
                // relative to JPEG's 8×8 DCT:
                //
                //   `enc_frame.cc:969:
                //    block[y*8 + x] = inputjpeg[base + x*8 + y];`
                //
                // The companion qtable in
                // `buildJXLBridgeRAWQuantPayload` is already
                // transposed to match (`qt[c*64 + 8*x + y] =
                // naturalQuant[8*y + x]` — see v0.12.0m). The AC
                // coefficients must follow the same transpose for
                // the dequant formula `coeff × weight × ...` to
                // recover the JPEG-domain coefficient values at
                // each frequency position. Without this, every
                // coefficient lands at the wrong frequency, and
                // the IDCT-then-YCbCr cascade produces scrambled
                // colours (max diff 139 on the real-JPEG bridge
                // test pre-fix).
                //
                // Position 0 (DC) is excluded from the loop and
                // stays 0 in `ac[bi]` — libjxl's VarDCT bitstream
                // stores LLF (the lowest frequency = DC) separately
                // via the DC sub-image, not as part of the AC.
                // (Applied v0.12.0fq.)
                for y in 0..<8 {
                    for x in 0..<8 {
                        let k = y * 8 + x
                        if k == 0 { continue }
                        ac[bi][k] = block.coefficients[x * 8 + y]
                    }
                }
            }
            dcPlanes.append(dc)
            acPlanes.append(ac)
        }

        // Build per-channel block dims. For grayscale all-same;
        // for 3-component pass the per-component dims through.
        let bpc: [(blocksX: Int, blocksY: Int)] = (0..<nch).map {
            (blocksX: blocksXPerComp[$0],
             blocksY: blocksYPerComp[$0])
        }
        return JXLCoefficientPlanes(
            blocksX: blocksX, blocksY: blocksY,
            channelCount: nch,
            dcPerChannel: dcPlanes,
            acPerChannel: acPlanes,
            blocksPerChannel: bpc)
    }
}
