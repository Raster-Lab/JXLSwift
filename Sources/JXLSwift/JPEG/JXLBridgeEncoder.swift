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
        // v0.12.0cc: full wire-up — prelude + 4 section
        // payloads + TOC + concat. The four bridge section
        // writers (v0.12.0y/z/aa/bb) feed into the TOC + section-
        // bytes concat pattern that the pixel-pipeline encoder
        // already uses (`writeFrameChunk` style).
        //
        // **Caveat (v0.12.0cc).** The post-tree modular codebook
        // emitted in LfGlobal is a 1-symbol-on-zero placeholder
        // (v0.12.0y). It only handles fixtures whose DC residuals
        // + ACMetadata tokens all pack to token 0 (typically:
        // all-zero-coefficient fixtures). Real content needs the
        // histogram-derived codebook bite (planned next). Until
        // then this method will fail with a `bitstream` error
        // for any fixture whose post-tree token values exceed 0.
        // The AC group codebook is similar: 1-symbol-on-zero
        // with a context-map sized to `BlockCtxMap().numACContexts`
        // — works for all-zero AC fixtures only.
        let prelude: Data
        do {
            prelude = try VarDCTBitstreamWriter.writeBridgePrelude(
                state: state)
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge prelude: \(e)")
        }
        // Per-section codebooks (placeholders for v0.12.0cc).
        let leafTable: PrefixCodeTable
        do { leafTable = try PrefixCodeTable(lengths: [0]) }
        catch {
            throw JXLBridgeEncoderError.notImplemented(
                "placeholder codebook construction: \(error)")
        }
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [leafTable], ansCounts: [],
            alphabetSizes: [1])
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [HybridUintConfig.defaultConfig])
        let bctx = BlockCtxMap()
        let acCodebook = MultiClusterCodebook(
            huffmanTables: [leafTable], ansCounts: [],
            alphabetSizes: [1])
        let acHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(
                numContexts: bctx.numACContexts),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [HybridUintConfig.defaultConfig])
        // Build each section into its own BitWriter so we can
        // measure section sizes for the TOC.
        var lf = BitWriter()
        var dcg = BitWriter()
        var hf = BitWriter()
        var ag = BitWriter()
        do {
            try VarDCTBitstreamWriter.writeBridgeLfGlobal(
                state: state, to: &lf)
            try VarDCTBitstreamWriter.writeBridgeDCGroup(
                state: state, postHeader: postHeader,
                postCodebook: postCodebook, to: &dcg)
            try VarDCTBitstreamWriter.writeBridgeHfGlobal(
                state: state,
                rawSlotOverrides: [0: state.rawQuantPayload],
                acHeader: acHeader, acCodebook: acCodebook,
                acContexts: bctx.numACContexts,
                numGroups: 1, to: &hf)
            try VarDCTBitstreamWriter.writeBridgeACGroup(
                state: state, groupIndex: 0,
                bctx: bctx,
                acHeader: acHeader, acCodebook: acCodebook,
                to: &ag)
        } catch let e as VarDCTBitstreamWriter.WriterError {
            throw JXLBridgeEncoderError.notImplemented(
                "bridge section writer: \(e)")
        } catch {
            // Any bitstream/codebook error surfaces here — most
            // likely a non-zero post-tree token hit the
            // placeholder codebook. Future codebook-construction
            // bite lifts this.
            throw JXLBridgeEncoderError.notImplemented(
                "bridge section writer (likely codebook-too-small "
                + "for non-zero tokens; this is the documented "
                + "placeholder limit): \(error)")
        }
        // For a single-section frame layout (matches the
        // pixel-pipeline encoder's numGroups == 1 path), the
        // four sub-sections are concatenated into one section
        // body. Single TOC entry of that combined size.
        var combined = BitWriter()
        lf.alignToByte()
        combined.appendBytes(lf.finishToData())
        dcg.alignToByte()
        combined.appendBytes(dcg.finishToData())
        hf.alignToByte()
        combined.appendBytes(hf.finishToData())
        ag.alignToByte()
        combined.appendBytes(ag.finishToData())
        combined.alignToByte()
        let sectionBytes = combined.finishToData()
        // TOC: single entry sized to combined section bytes.
        var tocWriter = BitWriter()
        do {
            try TOC(
                hasPermutation: false,
                entrySizes: [UInt32(sectionBytes.count)],
                offsets: [0, UInt64(sectionBytes.count)]
            ).write(to: &tocWriter)
        } catch {
            throw JXLBridgeEncoderError.notImplemented(
                "TOC write: \(error)")
        }
        // Assemble: prelude + TOC + sectionBytes.
        var out = prelude
        out.append(tocWriter.finishToData())
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
