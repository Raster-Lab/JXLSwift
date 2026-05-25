// `JXLBridgeEncoder` — the composition layer that turns a
// `JPEGCoefficientImage` into the complete intermediate state
// the (in-progress) JPEG → JXL coefficient bridge writer will
// consume.
//
// **Status today (v0.12.0o).** This file is the API surface for
// step 3.6 of `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`. The
// `prepareFromJPEG(_:colorTransform:)` entry point runs all five
// data-layer builders (planes adapter v0.12.0i, channel remap
// v0.12.0j, DC adjustment v0.12.0l, RAW quant payload v0.12.0m,
// frame-header params v0.12.0n) in sequence and returns a
// fully-populated `JXLBridgeEncoderState` struct. The actual
// `write(state:) -> Data` method that emits a JXL codestream
// from that state is the next bite — it requires a
// Modular-encoder-side `ModularGenericCompress` to write the
// RAW quant table's embedded sub-image (decoder side exists;
// encoder doesn't yet), plus the parallel-pipeline wiring in
// `VarDCTBitstreamWriter` that bypasses `VarDCTEncoder.forward`.
//
// Locking down `JXLBridgeEncoderState` now means the wire-up bite
// can be a structured single-responsibility commit ("take this
// known-good intermediate state and emit bytes") rather than
// re-deriving the data each time.

import Foundation

/// All the intermediate state the JXL bridge encoder needs to
/// emit a JPEG-derived JXL frame. Populated by
/// `JXLBridgeEncoder.prepareFromJPEG(_:colorTransform:)`.
public struct JXLBridgeEncoderState: Sendable {
    /// Source coefficient image (kept around so the bridge
    /// encoder can re-derive things like dimensions / precision
    /// without threading them through separate fields).
    public let source: JPEGCoefficientImage
    /// Chosen JXL `color_transform`. Determines the channel
    /// permutation and DC adjustment that have already been
    /// applied to `planes`.
    public let colorTransform: JXLBridgeColorTransform
    /// Per-channel quantised DC + AC planes in JXL channel order
    /// (X / Y / B slots), with the `DCzero` adjustment for the
    /// chosen color_transform applied. Ready to feed into the
    /// JXL VarDCT bitstream writer's DC and AC encoders.
    public let planes: JXLCoefficientPlanes
    /// `kQuantModeRAW` payload (qtable + qtable_den +
    /// dcQuantization) for the JXL `DequantMatrices` slot.
    public let rawQuantPayload: JXLBridgeRAWQuantPayload
    /// Frame-header parameters the bridge encoder must set
    /// (color_transform, chroma_subsampling, loop_filter,
    /// encoding).
    public let frameHeaderParams: JXLBridgeFrameHeaderParams
}

/// Bridge-encoder namespace.
public enum JXLBridgeEncoder {

    /// Run the five data-layer builders from v0.12.0i–n in
    /// sequence and return the fully-populated bridge state.
    /// The returned `JXLBridgeEncoderState` is the input the
    /// (in-progress) bitstream-write method will consume.
    ///
    /// Validates the input shape (4:4:4 chroma sampling, 1- or
    /// 3-component, 8-bit precision, baseline-DCT) before
    /// running the builders; throws `JPEGToJXLAdapterError` or
    /// the relevant builder error on out-of-scope inputs. Pre-
    /// validating here means the bitstream-write step can
    /// assume valid input without re-checking each invariant.
    public static func prepareFromJPEG(
        _ jpeg: JPEGCoefficientImage,
        colorTransform: JXLBridgeColorTransform = .ycbcr
    ) throws -> JXLBridgeEncoderState {
        // Step 3.1 — shape adapter (also runs the 4:4:4 check).
        let rawPlanes = try jpeg.toJXLCoefficientPlanes()
        // Step 3.2 — channel-order remap to JXL X / Y / B slots.
        let remapped = rawPlanes.remappedForJXLBridge(
            colorTransform: colorTransform)
        // Step 3.3 — DC adjustment (DCzero for .ycbcr, +1024/qt
        // for .none). The DC quant per JXL channel comes from
        // the raw payload below; build that first to share the
        // quant-table lookups.
        // Step 3.4 — RAW quant payload (also computes the DC
        // factor per JXL channel as 255 × 8 / qt[0]).
        let payload = jpeg.buildJXLBridgeRAWQuantPayload(
            colorTransform: colorTransform)
        // The DC adjustment needs the **per-channel DC quant
        // value** (the JPEG quant table's natural[0]), not the
        // payload's `dcQuantization` (which is the *scale*
        // 255×8 / qt[0]). Recover qt[0] per JXL channel from
        // `dcQuantization`: qt[0] = round(255 × 8 / dcQuant[c]).
        // For grayscale the same value sits in all three slots.
        var dcQuantPerChannel: [UInt16] = []
        for c in 0..<remapped.channelCount {
            let dcq = payload.dcQuantization[c]
            // dcq = 255 * 8 / qt[0] → qt[0] = 255 * 8 / dcq.
            // Guard against division-by-zero on the unused
            // grayscale chroma slots (where dcQuantization == 1
            // is the placeholder value).
            let qt0 = dcq > 1e-6
                ? UInt16(round(255.0 * 8.0 / dcq))
                : UInt16(1)
            dcQuantPerChannel.append(qt0)
        }
        let withDC = remapped.applyJPEGBridgeDC(
            colorTransform: colorTransform,
            quantDCPerChannel: dcQuantPerChannel)
        // Step 3.5 — frame-header parameters.
        let params = jpeg.buildJXLBridgeFrameHeaderParams(
            colorTransform: colorTransform)

        return JXLBridgeEncoderState(
            source: jpeg,
            colorTransform: colorTransform,
            planes: withDC,
            rawQuantPayload: payload,
            frameHeaderParams: params)
    }
}
