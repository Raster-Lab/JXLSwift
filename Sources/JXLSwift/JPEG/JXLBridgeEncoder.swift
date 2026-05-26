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

/// Errors specific to the JXL bridge encoder.
public enum JXLBridgeEncoderError: Error, Sendable, Equatable,
                                   LocalizedError {
    /// Bitstream-write step needs encoder primitives that aren't
    /// yet ported. See PHASE-J-COEFFICIENT-BRIDGE.md for the
    /// dependency chain.
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let m):
            return "JXLBridgeEncoder: \(m)"
        }
    }
}

/// Bridge-encoder namespace.
public enum JXLBridgeEncoder {

    /// Emit a JXL codestream from a prepared `JXLBridgeEncoderState`.
    ///
    /// **Status today (v0.12.0q).** Throws `.notImplemented`. The
    /// write step requires three bitstream-write capabilities our
    /// codebase doesn't yet have:
    ///
    /// 1. **Modular sub-image encoder with a local tree
    ///    (`useGlobalTree = false`).** libjxl's `EncodeQuantTable`
    ///    embeds a small modular sub-image inside the
    ///    `DequantMatrices` RAW payload to carry the JPEG quant
    ///    table. Our `SpecModularEncoder.buildSingleSection` is
    ///    close but writes a *frame-level* section (with
    ///    `matrices_dc_default` + frame-`has_tree` prelude); the
    ///    embedded sub-image case wants `GroupHeader` (with
    ///    `useGlobalTree = false`) followed by a local tree
    ///    section + post-tree codebook + pixel tokens.
    ///
    /// 2. **VarDCT bitstream writer parallel path** that bypasses
    ///    `VarDCTEncoder.forward` and consumes pre-quantised
    ///    coefficients directly. The existing
    ///    `VarDCTBitstreamWriter.encode(frame:distance:…)` is
    ///    pixel-input only; the bridge needs an entry point that
    ///    accepts a `JXLBridgeEncoderState` and emits matching
    ///    DC plane, AC plane, and quant-matrix bitstream.
    ///
    /// 3. **Decoder-side local-tree decode**, for round-trip
    ///    validation. Our `JXLDecoder` throws `.notImplemented`
    ///    on `useGlobalTree = false` (see JXLDecoder.swift line
    ///    ~381). Validating the bridge output against
    ///    `JPEGDecoder.decode` pixels can use `djxl` instead in
    ///    the test corpus, so this dep is for general-purpose
    ///    decode of bridge-emitted files (and any cjxl
    ///    `--lossless_jpeg=1` output found in the wild) rather
    ///    than for verifying the bridge ships byte-faithful
    ///    output.
    ///
    /// See `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md` section
    /// 4a (sub-step 3.6 write) for the implementation order.
    /// Step 3.7 swaps `JXLEncoder.encodeFromJPEGCoefficients(_:)`
    /// to call `prepareFromJPEG` + `write` once this lands.
    public static func write(
        state: JXLBridgeEncoderState
    ) throws -> Data {
        // v0.12.0cc: wire-up — prelude + 4 section payloads + TOC
        // + concat. v0.12.0dd: histogram-derived post-tree + AC
        // codebooks replace the 1-symbol-on-zero placeholders,
        // lifting the all-zero-coefficient restriction.
        // Build the image-level prelude bytes (signature + size +
        // metadata + custom-transform-data, byte-aligned at end).
        // The FrameHeader + TOC will be written into a separate
        // BitWriter below so they share one continuous bitstream
        // (spec doesn't byte-align between them; writing them
        // separately would offset the TOC's `has_permutation`
        // bit relative to where libjxl reads it).
        let imagePrelude: Data
        do {
            var w = BitWriter()
            try VarDCTBitstreamWriter
                .writeBridgePreludeImageLevel(state: state, to: &w)
            imagePrelude = w.finishToData()
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge prelude (image-level): \(e)")
        }
        // Per-section codebooks, derived from the observed token
        // histograms (`buildBridgePostCodebook` + `buildBridgeACCodebook`).
        // Single-cluster Huffman in both — multi-cluster is a future
        // file-size optimisation, not a correctness requirement.
        let postHeader: EntropySectionHeader
        let postCodebook: MultiClusterCodebook
        let acHeader: EntropySectionHeader
        let acCodebook: MultiClusterCodebook
        let acContexts: Int
        let bctx = BlockCtxMap()
        do {
            (postHeader, postCodebook) =
                try VarDCTBitstreamWriter.buildBridgePostCodebook(
                    state: state)
            (acHeader, acCodebook, acContexts) =
                try VarDCTBitstreamWriter.buildBridgeACCodebook(
                    state: state, bctx: bctx)
        } catch {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge codebook construction: \(error)")
        }
        // **Single-section layout** — libjxl's `is_small_image` case
        // (`num_groups == 1 && num_passes == 1`) writes all four
        // sub-sections (LfGlobal, DC group, HfGlobal, AC group) into
        // ONE shared `BitWriter` (per `enc_frame.cc::ComputeEncodingData`
        // line 1265: `is_small_image ? 0 : index`). The sub-sections
        // flow as **continuous bits**, no byte alignment between them
        // — the reader expects bit N+1 of one sub-section to be the
        // start of the next. Writing them as separate BitWriters
        // byte-aligned at the boundary would shift the DC group's
        // `extra_precision` field by up to 7 bits relative to where
        // the reader looks for it, cascading into garbage parses of
        // every subsequent field.
        var combined = BitWriter()
        do {
            try VarDCTBitstreamWriter.writeBridgeLfGlobal(
                state: state, postHeader: postHeader,
                postCodebook: postCodebook, to: &combined)
            try VarDCTBitstreamWriter.writeBridgeDCGroup(
                state: state, postHeader: postHeader,
                postCodebook: postCodebook, to: &combined)
            try VarDCTBitstreamWriter.writeBridgeHfGlobal(
                state: state,
                rawSlotOverrides: [0: state.rawQuantPayload],
                acHeader: acHeader, acCodebook: acCodebook,
                acContexts: acContexts,
                numGroups: 1, to: &combined)
            try VarDCTBitstreamWriter.writeBridgeACGroup(
                state: state, groupIndex: 0,
                bctx: bctx,
                acHeader: acHeader, acCodebook: acCodebook,
                to: &combined)
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge section writer: \(e)")
        } catch {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge section writer: \(error)")
        }
        // Byte-align at the END of the section (libjxl
        // `enc_frame.cc:1419` `ZeroPadToByte() // end of group.`).
        combined.alignToByte()
        let sectionBytes = combined.finishToData()
        // FrameHeader + TOC into ONE BitWriter so the bitstream
        // stays continuous across the header → TOC boundary (spec
        // requires no byte-alignment between them; libjxl reads
        // the TOC's `has_permutation` bit at the FrameHeader's
        // end-of-bits position).
        var headerAndToc = BitWriter()
        do {
            try VarDCTBitstreamWriter.writeBridgeFrameHeader(
                state: state, to: &headerAndToc)
            try TOC(
                hasPermutation: false,
                entrySizes: [UInt32(sectionBytes.count)],
                offsets: [0, UInt64(sectionBytes.count)]
            ).write(to: &headerAndToc)
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge FrameHeader: \(e)")
        } catch {
            throw JXLBridgeEncoderError.notImplemented(
                "TOC write: \(error)")
        }
        // Assemble: imagePrelude + (FrameHeader + TOC) + sectionBytes.
        var out = imagePrelude
        out.append(headerAndToc.finishToData())
        out.append(sectionBytes)
        return out
    }

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
