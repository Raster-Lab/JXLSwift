// JXLDecoder — pure-Swift JPEG XL decoder.
//
// STATUS: foundation only. The codec layers (Modular tree, VarDCT,
// rANS entropy coding, color transforms) are not yet implemented.
// Calling `decode(_:)` currently throws `DecoderError.notImplemented`,
// but the foundation can already:
//   • Parse a JXL ISOBMFF container into its boxes
//   • Locate / concatenate the codestream
//   • Verify the codestream signature
//   • Read a SizeHeader (xsize, ysize) — useful for `info`-style
//     workflows that don't need pixels
//
// `inspect(_:)` exposes the foundation work without the codec layer.

import Foundation

public enum DecoderError: Error, LocalizedError, Sendable {
    case notImplemented(String)
    case container(ContainerError)
    case bitstream(BitstreamError)
    case missingSignature

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let p):
            return "JXLDecoder: \(p) is not yet implemented in pure Swift. " +
                   "See ROADMAP.md."
        case .container(let e):  return "JXLDecoder container error: \(e)"
        case .bitstream(let e):  return "JXLDecoder bitstream error: \(e)"
        case .missingSignature:  return "JXLDecoder: input is not a JPEG XL file"
        }
    }
}

/// A best-effort summary of a JXL file produced from header inspection
/// alone — does not require the full codec.
public struct JXLInspection: Sendable {
    public enum Form: Sendable, Equatable {
        case naked
        case container
    }
    public let form: Form
    public let xsize: UInt32
    public let ysize: UInt32
    /// Box types found in container form (empty for naked codestreams).
    public let boxTypes: [String]
    /// Parsed image metadata. Nil if inspection failed before this point
    /// (e.g. SizeHeader-only inspection on truncated files).
    public let metadata: ImageMetadata?
}

/// Deeper inspection that walks past the image headers into the
/// frame structure. Reports what we can pull from the first frame —
/// the FrameHeader fields, the TOC entry sizes, and (for Modular
/// frames) the MA-tree structure if one is present. Fields are
/// nil-able so a caller can use this even on files where our
/// reader stops at an unsupported branch.
public struct JXLFrameInspection: Sendable {
    /// Encoding mode of the first frame.
    public let encoding: FrameEncoding?
    /// True if `is_last` was set on the first frame.
    public let isLast: Bool?
    /// Frame `flags` U64.
    public let flags: UInt64?
    /// Number of progressive passes.
    public let numPasses: UInt32?
    /// TOC entry sizes (one per group, plus DC if present).
    public let tocSizes: [UInt32]?
    /// True if the Modular global has a non-trivial MA-tree.
    public let hasModularTree: Bool?
    /// Number of leaves in the MA-tree (when `hasModularTree`).
    public let modularTreeLeafCount: Int?
    /// Whether the post-tree pixel-data section uses prefix codes
    /// (true) or rANS (false).
    public let usePrefixCode: Bool?
}

/// Floor of base-2 log for positive integers. `log2Floor(1) = 0`,
/// `log2Floor(2) = 1`, `log2Floor(8) = 3`.
@inline(__always)
private func log2Floor(_ x: Int) -> Int {
    precondition(x > 0, "log2Floor requires positive input")
    return 63 - UInt64(x).leadingZeroBitCount
}

public final class JXLDecoder {
    public init() {}

    /// Decode a JPEG XL byte stream into an `ImageFrame`. Detection
    /// order:
    ///   1. The project-internal `0x4D30` 'M0' marker — routes
    ///      through `MinimalLosslessCodec.decode(_:)` for the
    ///      legacy vertical-slice format.
    ///   2. Real spec frames — routed through `decodeModular(_:)`
    ///      for Modular frames; VarDCT frames still throw
    ///      `.notImplemented` until that codec lands.
    public func decode(_ data: Data) throws -> ImageFrame {
        if MinimalLosslessCodec.isM0(data) {
            do { return try MinimalLosslessCodec.decode(data) }
            catch { throw DecoderError.notImplemented("M0 decode failed: \(error)") }
        }
        // Inspect the frame to determine encoding (Modular vs VarDCT).
        let inspection = try inspect(data)
        guard let metadata = inspection.metadata else {
            throw DecoderError.notImplemented(
                "frame metadata could not be parsed"
            )
        }
        // Branch on encoding. The probe routes Modular frames
        // through `decodeModular`; VarDCT frames go through
        // `decodeVarDCTPartial` which currently parses headers +
        // `QuantizerParams` and throws structured `notImplemented`
        // for the layers we haven't built yet (DequantMatrices,
        // BlockCtxMap parser, AC global, etc.). The error message
        // names the next layer so callers and tests can pin
        // progress.
        let frameInspection = inspectFrameStructure(data)
        if frameInspection.encoding == FrameEncoding.varDCT {
            return try decodeVarDCTPartial(
                data: data, inspection: inspection,
                frame: frameInspection
            )
        }
        let modular: ModularImage
        do { modular = try decodeModular(data) }
        catch DecoderError.notImplemented(let m) where m.contains("Modular") {
            throw DecoderError.notImplemented(m)
        }
        return try assembleImageFrame(
            modular: modular, metadata: metadata,
            xsize: Int(inspection.xsize),
            ysize: Int(inspection.ysize)
        )
    }

    /// Skeleton VarDCT decoder. Parses what's tractable today and
    /// throws a structured `notImplemented` naming the first
    /// bitstream layer we can't yet read. As parsers for each
    /// layer land, the throw point moves further into the section.
    ///
    /// Section 0 layout (libjxl `dec_frame.cc::DecodeGlobalDCInfo`
    /// + `modular_frame_decoder::DecodeGlobalInfo`):
    ///
    ///   1. ✓ `QuantizerParams` — global_scale + quant_dc
    ///   2. ✓ `BlockCtxMap` all_default flag (1 bit; only the
    ///        default branch is parsed today)
    ///   3. ✓ `ColorCorrelationMap.DecodeDC` all_default flag
    ///        (1 bit; only the default branch)
    ///   4. ✗ `DequantMatrices.DecodeDC` — first unimplemented
    ///        layer; throws here.
    ///
    /// Layers 5+ (DequantMatrices full decode, DC group, AC global,
    /// AC group, Gaborish, OpsinXYB inverse) all have their math
    /// layer in `Sources/JXLSwift/VarDCT/` already; what's missing
    /// is the bitstream parsers + orchestration.
    private func decodeVarDCTPartial(
        data: Data, inspection: JXLInspection,
        frame: JXLFrameInspection
    ) throws -> ImageFrame {
        guard let codestream = unwrapCodestream(data) else {
            throw DecoderError.notImplemented(
                "VarDCT frame in unsupported container layout"
            )
        }
        guard let metadata = inspection.metadata else {
            throw DecoderError.notImplemented(
                "VarDCT frame: no parseable metadata"
            )
        }
        // Re-parse outer headers to position the cursor at section 0.
        // Same prep `decodeModular` runs.
        var r = BitReader(codestream, startingAt: 16)
        _ = try SizeHeader.read(from: &r)
        _ = try ImageMetadata.read(from: &r)
        _ = try? r.readCustomTransformData(xybEncoded: metadata.xybEncoded)
        try r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: metadata.xybEncoded,
            numExtraChannels: metadata.extraChannels.count,
            haveAnimation: metadata.animation != nil,
            haveTimecodes: metadata.animation?.haveTimecodes ?? false
        )
        let fh = try FrameHeader.read(from: &r, context: ctx)
        guard fh.encoding == .varDCT else {
            throw DecoderError.notImplemented(
                "decodeVarDCTPartial routed wrong-encoded frame: "
                + "got \(fh.encoding)"
            )
        }
        // TOC + section-0 BitReader.
        let groupDim = 128 << Int(fh.groupSizeShift)
        let xsize = Int(inspection.xsize)
        let ysize = Int(inspection.ysize)
        let numGroupsX = (xsize + groupDim - 1) / groupDim
        let numGroupsY = (ysize + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY
        let dcGroupDim = groupDim << 3
        let numDcGroupsX = (xsize + dcGroupDim - 1) / dcGroupDim
        let numDcGroupsY = (ysize + dcGroupDim - 1) / dcGroupDim
        let numDcGroups = numDcGroupsX * numDcGroupsY
        let numPasses = Int(fh.passes.numPasses)
        let tocEntries = TOC.numEntries(
            numGroups: numGroups, numDcGroups: numDcGroups,
            numPasses: numPasses
        )
        let toc = try TOC.read(from: &r, numEntries: tocEntries)
        // After TOC, the codestream is byte-aligned. Capture this byte
        // position — every TOC entry's offset is relative to it.
        let postTocBytePos = r.position / 8
        // Helper: section i starts at this bit position in the file.
        @inline(__always)
        func sectionBitStart(_ i: Int) -> Int {
            return postTocBytePos * 8 + Int(toc.offsets[i]) * 8
        }
        _ = sectionBitStart  // silence unused-warning when single-section

        // libjxl `dec_frame.cc::ProcessDCGlobal` order:
        //   1. (Splines, if frame.flags has Splines bit) — typical
        //      cjxl output doesn't set this.
        //   2. (Noise, if Noise bit) — also rare.
        //   3. `matrices.DecodeDC(br)` — DequantMatrices.DecodeDC
        //      (DC quant scalars). Read for ALL frame types.
        //   4. (VarDCT only) `DecodeGlobalDCInfo`: QuantizerParams +
        //      BlockCtxMap + cmap.DecodeDC.
        //   5. `modular_frame_decoder.DecodeGlobalInfo`: has_tree
        //      + (if true) tree + codebook + ModularGenericDecompress
        //      (gi).
        //   6. (VarDCT only) DequantMatrices.Decode (the AC matrices).
        if (fh.flags & 0x01) != 0 || (fh.flags & 0x08) != 0 {
            // Splines (bit 0) / Noise (bit 3) per libjxl
            // `frame_header.h::FrameFlag`.
            throw DecoderError.notImplemented(
                "VarDCT decode: frames with Splines or Noise flags "
                + "(flags=0x\(String(fh.flags, radix: 16))) not yet "
                + "supported"
            )
        }

        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        @inline(__always)
        func traceLayer(_ name: String, before: Int, after: Int) {
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE \(name) bits=\(after - before) pos=\(after)\n".utf8
                ))
            }
        }
        // (1) DequantMatrices.DecodeDC.
        let dcStart = r.position
        let dcQuant = try DequantMatricesDC.read(from: &r)
        traceLayer("DequantMatricesDC", before: dcStart, after: r.position)
        _ = dcQuant

        // (2) QuantizerParams.
        let qpStart = r.position
        let qp = try QuantizerParams.read(from: &r)
        traceLayer("QuantizerParams", before: qpStart, after: r.position)
        _ = qp

        // (3) BlockCtxMap.
        let bctxStart = r.position
        let bctx: BlockCtxMap
        do { bctx = try BlockCtxMap.read(from: &r) }
        catch let e as BlockCtxMapError {
            throw DecoderError.notImplemented(
                "VarDCT decode: BlockCtxMap.read failed: \(e)"
            )
        }
        traceLayer("BlockCtxMap", before: bctxStart, after: r.position)

        // (4) ColorCorrelationMap.DecodeDC.
        let cmapStart = r.position
        let cmapDC: ColorCorrelation
        do { cmapDC = try ColorCorrelation.readDC(from: &r) }
        catch ColorCorrelationError.notDefault {
            throw DecoderError.notImplemented(
                "VarDCT decode: ColorCorrelationMap.DecodeDC "
                + "non-default branch (color_factor + base "
                + "correlations + DC offsets)"
            )
        }
        traceLayer("cmap.DecodeDC", before: cmapStart, after: r.position)
        _ = cmapDC

        // (5) Modular global info — has_tree flag + (if true)
        // global tree section + post-tree codebook + GroupHeader.
        // The VarDCT path uses this tree/codebook for the DC-plane
        // modular sub-image AND for any RAW-mode quant tables.
        var globalTree: ModularTree? = nil
        var globalPostHeader: EntropySectionHeader? = nil
        var globalPostCodebook: MultiClusterCodebook? = nil
        let hasTreeStart = r.position
        let hasTree = try r.readBit()
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE has_tree=\(hasTree) at pos=\(hasTreeStart)\n".utf8
            ))
        }
        if hasTree {
            let p1 = r.position
            let treeHdr = try EntropySectionHeader.read(
                from: &r, numContexts: 6
            )
            traceLayer("treeHdr", before: p1, after: r.position)
            let p2 = r.position
            let treeCB = try MultiClusterCodebook.read(
                from: &r, header: treeHdr
            )
            traceLayer("treeCB", before: p2, after: r.position)
            let p3 = r.position
            var treeStream = TokenStreamReader(
                header: treeHdr, codebook: treeCB
            )
            globalTree = try ModularTree.decode(
                from: &r, stream: &treeStream
            )
            traceLayer("treeDecode", before: p3, after: r.position)
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE tree leafCount=\(globalTree!.leafCount)\n".utf8
                ))
            }
            let p4 = r.position
            globalPostHeader = try EntropySectionHeader.read(
                from: &r, numContexts: globalTree!.leafCount
            )
            traceLayer("postHdr", before: p4, after: r.position)
            let p5 = r.position
            globalPostCodebook = try MultiClusterCodebook.read(
                from: &r, header: globalPostHeader!
            )
            traceLayer("postCB", before: p5, after: r.position)
        }
        // (6) Meta-channels modular sub-image. libjxl
        // `dec_modular.cc::DecodeGlobalInfo`:
        //
        //     do_color = (frame.encoding == kModular)
        //     nb_chans = do_color ? (gray ? 1 : 3) : 0
        //     gi = Image::Create(... nb_chans + nb_extra)
        //     ModularGenericDecompress(reader, gi, ...)
        //
        // For VarDCT (do_color=false) with no extra channels, `gi`
        // has zero channels, so `ModularDecode` early-returns with
        // `image.channel.empty()` BEFORE reading GroupHeader. No
        // bits are consumed here in that case. Verified against
        // libjxl with `JXL_BYTEPOS_TRACE`: section-0 pos 296
        // (= end of post-tree codebook) flows directly into
        // `DecodeVarDCTDC`'s `ReadFixedBits<2>()` for
        // `extra_precision`.
        let nbColorChannels = 0  // VarDCT: do_color = false
        let nbExtraChannels = metadata.extraChannels.count
        let metaChannelCount = nbColorChannels + nbExtraChannels
        if metaChannelCount > 0 {
            // Non-empty meta-channels image (e.g. extra channels):
            // libjxl reads GroupHeader, transforms, etc. We don't
            // implement that yet.
            throw DecoderError.notImplemented(
                "VarDCT decode: meta-channels modular sub-image with "
                + "\(metaChannelCount) channel(s) — GroupHeader "
                + "read + meta-transforms + decodeAllChannels not "
                + "yet implemented (no test fixture currently "
                + "exercises this path)."
            )
        }
        let _ = (globalTree, globalPostHeader, globalPostCodebook)
        let _ = (kRequiredSizeX, kRequiredSizeY, DequantMatricesAC.self)

        // For multi-section frames, DC global ends at the boundary of
        // section 0 and DC group 0 lives at section 1. Seek the
        // BitReader to the section-1 byte boundary. Single-entry TOC
        // (1 group, 1 pass) skips this — all sections share the same
        // BitReader cursor.
        if tocEntries > 1 {
            let dcGroup0SecIdx = 1   // section index for DC group 0
            r = BitReader(r.data, startingAt: sectionBitStart(dcGroup0SecIdx))
        }

        // (7) DC group decode. libjxl `dec_modular.cc::DecodeVarDCTDC`
        // for our 1-DC-group fixture:
        //
        //     extra_precision = ReadFixedBits<2>()          // 2 bits
        //     Image image(DCGroupRect.xsize, .ysize, ..., 3)
        //     ModularGenericDecompress(reader, image,
        //         header=nullptr,    // local GroupHeader is read inside
        //         tree=&global_tree, code=&global_code,     // post-tree
        //         context_map=&global_ctx_map,
        //         undo_transforms=true)
        //
        // Inside `ModularGenericDecompress` → `ModularDecode`:
        //   • `Bundle::Read(br, &local_header)` — the local GroupHeader
        //     for this DC sub-image (use_global_tree, wp_header,
        //     num_transforms).
        //   • Apply meta-transforms.
        //   • If `use_global_tree`: reuse the global tree+code+ctx_map
        //     decoded above; else read a local tree+codebook.
        //   • `ANSSymbolReader::Create(code, br, dist_mul)` — reads a
        //     32-bit rANS state (ANS path) or 0 bits (prefix path).
        //   • For each channel: `DecodeModularChannelMAANS` — token
        //     stream over the per-pixel `(predictor, offset, multiplier)`
        //     tree leaves.
        //
        // For our 8×8 fixture: DCGroupRect = 1×1. Post-tree codebook is
        // **prefix code** (verified by structural trace), so
        // `ANSSymbolReader::Create` reads 0 bits.
        let dcExtraPrecision: UInt32
        do { dcExtraPrecision = try r.read(bits: 2) }
        catch let e as BitstreamError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC group extra_precision read "
                + "failed: \(e)"
            )
        }
        traceLayer("DCGroup.extra_precision=\(dcExtraPrecision)",
                   before: r.position - 2, after: r.position)

        // (8) DC group: local GroupHeader.
        let dcGHStart = r.position
        let dcGroupGH: GroupHeader
        do { dcGroupGH = try GroupHeader.read(from: &r) }
        catch let e as GroupHeaderError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC group GroupHeader read failed: \(e)"
            )
        }
        traceLayer("DCGroup.GroupHeader", before: dcGHStart, after: r.position)
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE DCGroup.GH useGlobalTree=\(dcGroupGH.useGlobalTree) wpDefault=\(dcGroupGH.wpHeader.allDefault) numTransforms=\(dcGroupGH.transforms.count)\n".utf8
            ))
        }

        // The DC group must use the global tree the meta-channels layer
        // would have set up. Since the meta-channels modular sub-image
        // is empty for VarDCT (verified above), the tree+codebook from
        // the post-tree section ARE the "global" set passed through.
        guard dcGroupGH.useGlobalTree else {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC group with useGlobalTree=false "
                + "(local tree read) not yet implemented"
            )
        }
        guard dcGroupGH.transforms.isEmpty else {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC group with \(dcGroupGH.transforms.count) "
                + "transform(s) — meta-transform application "
                + "(Squeeze/RCT/Palette) not yet implemented"
            )
        }
        guard let dcTree = globalTree,
              let dcPostHeader = globalPostHeader,
              let dcPostCodebook = globalPostCodebook
        else {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC group needs the global tree + "
                + "post-tree codebook but they were never decoded "
                + "(has_tree was false). Expected has_tree=true for "
                + "VarDCT frames."
            )
        }

        // (9) DC channel decode. libjxl iterates 3 channels (Y/Cb/Cr,
        // stored Cb/Y/Cr internally via the `c < 2 ? c ^ 1 : c` swap)
        // and for each calls `DecodeModularChannelMAANS`.
        //
        // For prefix-code path, `ANSSymbolReader::Create` reads zero
        // bits — no rANS state init. Each channel pixel reads one
        // token from the post-tree codebook at the leaf-context
        // assigned by the modular tree.
        //
        // DCGroupRect for an 8×8 frame = 1×1 (one DC sample per 8×8
        // block). Chroma subsampling shifts apply per-channel; for
        // the cjxl-d=1 fixture they're all zero.
        let dcGroupId: Int32 = 1 + Int32(numDcGroups) + 0
        let dcWidth = numDcGroupsX > 0 ? max(1, (xsize + 7) / 8) : 0
        let dcHeight = numDcGroupsY > 0 ? max(1, (ysize + 7) / 8) : 0
        let dcChannels: [ModularChannelGeometry] = [
            ModularChannelGeometry(width: dcWidth, height: dcHeight),
            ModularChannelGeometry(width: dcWidth, height: dcHeight),
            ModularChannelGeometry(width: dcWidth, height: dcHeight),
        ]
        var dcStream = TokenStreamReader(
            header: dcPostHeader, codebook: dcPostCodebook
        )
        let dcChStart = r.position
        let dcValues: [[Int32]]
        do {
            dcValues = try decodeAllChannels(
                channels: dcChannels,
                groupId: dcGroupId,
                tree: dcTree,
                stream: &dcStream,
                from: &r,
                wpHeader: dcGroupGH.wpHeader
            )
        } catch let e as ModularChannelDecoderError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DC channel decode failed: \(e)"
            )
        }
        traceLayer("DCGroup.channels", before: dcChStart, after: r.position)
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE DC values: \(dcValues)\n".utf8
            ))
        }

        // (10) ACMetadata. libjxl `dec_modular.cc::DecodeAcMetadata`:
        //
        //     upper_bound = DCGroupRect.xsize * DCGroupRect.ysize
        //     count = ReadBits(CeilLog2Nonzero(upper_bound)) + 1
        //     image = Image(DCGroupRect.xsize, DCGroupRect.ysize, ..., 4)
        //     channel[0] = (cr.xsize, cr.ysize)  // YToX, hshift=3, vshift=3
        //     channel[1] = (cr.xsize, cr.ysize)  // YToB
        //     channel[2] = (count, 2)            // ACS + QF
        //     channel[3] = (r.xsize, r.ysize)    // EPF sharpness
        //     ModularGenericDecompress(reader, image, header=nullptr,
        //         stream_id=ACMetadata.ID, ..., undo_transforms=true)
        //
        // For 8×8 fixture: r=1×1, cr=1×1 (= ceil(1/8)=1), so:
        //     count = ReadBits(0) + 1 = 1
        //     channel[0..3] sizes: 1×1, 1×1, 1×2, 1×1 → 5 pixels total.
        let acMetaUpperBound = dcWidth * dcHeight
        let acMetaCountBits = Int(ceilLog2(UInt32(max(1, acMetaUpperBound))))
        let acMetaCountStart = r.position
        let acMetaCount: Int
        do {
            let raw = try r.read(bits: acMetaCountBits)
            acMetaCount = Int(raw) + 1
        } catch let e as BitstreamError {
            throw DecoderError.notImplemented(
                "VarDCT decode: ACMetadata count read failed: \(e)"
            )
        }
        traceLayer("ACMetadata.count=\(acMetaCount)",
                   before: acMetaCountStart, after: r.position)

        // ACMetadata GroupHeader.
        let acMetaGHStart = r.position
        let acMetaGH: GroupHeader
        do { acMetaGH = try GroupHeader.read(from: &r) }
        catch let e as GroupHeaderError {
            throw DecoderError.notImplemented(
                "VarDCT decode: ACMetadata GroupHeader read failed: \(e)"
            )
        }
        traceLayer("ACMetadata.GroupHeader",
                   before: acMetaGHStart, after: r.position)
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE ACMeta.GH useGlobalTree=\(acMetaGH.useGlobalTree) wpDefault=\(acMetaGH.wpHeader.allDefault) numTransforms=\(acMetaGH.transforms.count)\n".utf8
            ))
        }
        guard acMetaGH.useGlobalTree else {
            throw DecoderError.notImplemented(
                "VarDCT decode: ACMetadata with useGlobalTree=false "
                + "(local tree read) not yet implemented"
            )
        }
        guard acMetaGH.transforms.isEmpty else {
            throw DecoderError.notImplemented(
                "VarDCT decode: ACMetadata with \(acMetaGH.transforms.count) "
                + "transform(s) not yet implemented"
            )
        }

        // (11) ACMetadata channel decode (4 channels).
        let cWidth = max(1, (dcWidth + 7) / 8)   // YToX/YToB at 8×8 tile
        let cHeight = max(1, (dcHeight + 7) / 8)
        let acMetaChannels: [ModularChannelGeometry] = [
            ModularChannelGeometry(width: cWidth, height: cHeight),  // YToX
            ModularChannelGeometry(width: cWidth, height: cHeight),  // YToB
            ModularChannelGeometry(width: acMetaCount, height: 2),   // ACS + QF
            ModularChannelGeometry(width: dcWidth, height: dcHeight), // EPF
        ]
        let acMetaGroupId: Int32 = 1 + 2 * Int32(numDcGroups) + 0
        var acMetaStream = TokenStreamReader(
            header: dcPostHeader, codebook: dcPostCodebook
        )
        let acMetaChStart = r.position
        let acMetaValues: [[Int32]]
        do {
            acMetaValues = try decodeAllChannels(
                channels: acMetaChannels,
                groupId: acMetaGroupId,
                tree: dcTree,
                stream: &acMetaStream,
                from: &r,
                wpHeader: acMetaGH.wpHeader
            )
        } catch let e as ModularChannelDecoderError {
            throw DecoderError.notImplemented(
                "VarDCT decode: ACMetadata channel decode failed: \(e)"
            )
        }
        traceLayer("ACMetadata.channels",
                   before: acMetaChStart, after: r.position)
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE ACMeta values: \(acMetaValues)\n".utf8
            ))
        }

        // ACMeta channel 2 carries per-block (ACS, QF) — flat layout
        // is `[ACS_0..ACS_{n-1}, QF_0..QF_{n-1}]` (n = `acMetaCount`).
        // Per libjxl `dec_modular.cc::DecodeAcMetadata`:
        //
        //     row_qf[ix] = 1 + clamp(row_in_2[num], 0, kQuantMax - 1)
        //
        // We extract this here so both the AC decode loop (block-ctx
        // routing for multi-cluster fixtures) and the dequant loop
        // can index it.
        let acMetaCh2 = acMetaValues[2]
        // Per-first-block QF in raster-scan order (same order ACMeta
        // channel 2 enumerates first-blocks). `firstBlockQF[i]` is
        // the QF of the i-th first-block.
        var firstBlockQF = [Int32]()
        firstBlockQF.reserveCapacity(acMetaCount)
        for i in 0..<acMetaCount {
            let raw = acMetaCh2.count > acMetaCount + i
                ? acMetaCh2[acMetaCount + i] : 0
            firstBlockQF.append(1 + max(0, min(raw, 255)))
        }
        let qfRow = firstBlockQF.first ?? 5

        // Build the per-cell AC strategy plane. ACMeta channel 2's
        // `count` first-block strategy IDs expand into the full
        // `numBlocksX × numBlocksY` grid via libjxl's raster-walk
        // covered-block tracking. First-blocks are the only cells
        // the AC decode loop visits — non-first cells (covered by
        // multi-block transforms like DCT16×16) are skipped.
        let xsizeBlocks = (xsize + 7) / 8
        let ysizeBlocks = (ysize + 7) / 8
        let acsImage: ACStrategyImage
        do {
            acsImage = try ACStrategyImage.build(
                from: acMetaCh2, count: acMetaCount,
                numBlocksX: xsizeBlocks, numBlocksY: ysizeBlocks
            )
        } catch let e as ACStrategyImageError {
            throw DecoderError.notImplemented(
                "VarDCT decode: AC strategy plane build failed: \(e)"
            )
        }
        if trace {
            // Tally strategies for visibility.
            var counts = [Int: Int]()
            for fb in acsImage.firstBlocks {
                let s = acsImage.at(x: fb.x, y: fb.y).strategy
                counts[Int(s.rawValue), default: 0] += 1
            }
            FileHandle.standardError.write(Data(
                "TRACE ACStrategyImage: \(acsImage.firstBlocks.count) first-blocks, strategies=\(counts)\n".utf8
            ))
        }

        // Build a per-CELL QF array (`perBlockQF`). The first-block-
        // ordered `firstBlockQF` carries a QF per first-block in
        // raster scan order; we stamp each first-block's QF onto all
        // its covered cells so subsequent indexers can use cell index
        // directly. Mirrors libjxl's `qf_row[bx]` semantics where the
        // QF for each cell equals its parent first-block's QF.
        var perBlockQF = [Int32](
            repeating: qfRow,
            count: xsizeBlocks * ysizeBlocks
        )
        for (i, fb) in acsImage.firstBlocks.enumerated() {
            guard i < firstBlockQF.count else { break }
            let qfVal = firstBlockQF[i]
            let s = acsImage.at(x: fb.x, y: fb.y).strategy
            let cells = s.blockCells
            for cy in 0..<cells.cellsY {
                for cx in 0..<cells.cellsX {
                    let cellX = fb.x + cx
                    let cellY = fb.y + cy
                    if cellX < xsizeBlocks && cellY < ysizeBlocks {
                        perBlockQF[cellY * xsizeBlocks + cellX] = qfVal
                    }
                }
            }
        }

        // For multi-section frames, AC global lives at section
        // `1 + num_dc_groups` (= 2 for our 1-DC-group fixtures).
        if tocEntries > 1 {
            let acGlobalSecIdx = 1 + numDcGroups
            r = BitReader(r.data, startingAt: sectionBitStart(acGlobalSecIdx))
        }

        // (12) ProcessACGlobal — DequantMatrices.Decode (all-default
        // shortcut). libjxl `dec_frame.cc::ProcessACGlobal`:
        //
        //     matrices.Decode(br)  // 1 bit all_default + (per-table reads)
        //     EnsureComputed(...)  // no bits
        //     num_histograms = 1 + ReadBits(CeilLog2Nonzero(num_groups))
        //     for each pass:
        //         used_orders = U32(kOrderEnc, br)
        //         DecodeCoeffOrders(...)      // permutation if used_orders > 0
        //         DecodeHistograms(...)       // AC histograms
        let _ = DequantMatricesAC.self
        let acGStart = r.position
        do { _ = try DequantMatricesAC.readDefaultOrThrow(from: &r) }
        catch DequantMatricesACError.notDefault {
            throw DecoderError.notImplemented(
                "VarDCT decode: ProcessACGlobal — DequantMatrices.Decode "
                + "non-default (per-table QuantEncoding reads) not yet "
                + "wired up. The 17-strategy parser exists in QuantEncoding.swift "
                + "but isn't reachable until the for-loop driver lands."
            )
        } catch let e as DequantMatricesACError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DequantMatrices.Decode read failed: \(e)"
            )
        }
        traceLayer("DequantMatricesAC.allDefault",
                   before: acGStart, after: r.position)

        // num_histograms = 1 + ReadBits(CeilLog2Nonzero(num_groups))
        // For num_groups=1 this is 0 bits; for larger groups it scales.
        let nhBits = Int(ceilLog2(UInt32(max(1, numGroups))))
        let nhStart = r.position
        let acNumHistograms: UInt32
        do {
            acNumHistograms = 1 + (nhBits == 0 ? 0 : try r.read(bits: nhBits))
        } catch let e as BitstreamError {
            throw DecoderError.notImplemented(
                "VarDCT decode: ProcessACGlobal num_histograms read "
                + "failed: \(e)"
            )
        }
        traceLayer("ACGlobal.num_histograms=\(acNumHistograms)",
                   before: nhStart, after: r.position)

        // used_orders U32 per pass. kOrderEnc = U32(Val(0x5F), Val(0x13),
        // Val(0), Bits(13)) per `frame_header.h:503`. For `cjxl -d 1`
        // typical fixtures, used_orders=0 (selector=2 → no orders
        // permuted, default zigzag-style order). 1 pass on a single
        // group is the usual cjxl shape.
        let numPassesActual = max(1, Int(fh.passes.numPasses))
        var usedOrdersPerPass: [UInt32] = []
        usedOrdersPerPass.reserveCapacity(numPassesActual)
        // Per-pass per-ord per-channel coeff orders. Empty when
        // `used_orders` bit is unset (caller falls back to natural).
        var coeffOrdersPerPass: [[Int: [[Int]]]] = []
        coeffOrdersPerPass.reserveCapacity(numPassesActual)
        for passIdx in 0..<numPassesActual {
            let uoStart = r.position
            let used: UInt32
            do {
                used = try r.readU32((
                    .literal(0x5F), .literal(0x13), .literal(0),
                    .bits(13)
                ))
            } catch let e as BitstreamError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: ACGlobal used_orders[\(passIdx)] "
                    + "read failed: \(e)"
                )
            }
            usedOrdersPerPass.append(used)
            traceLayer("ACGlobal.used_orders[\(passIdx)]=\(used)",
                       before: uoStart, after: r.position)
            // For non-zero used_orders, libjxl reads a permutation
            // entropy section here (kPermutationContexts contexts),
            // then per (ord, channel) reads a Lehmer-coded permutation.
            // We currently DISCARD the permutation (no AC strategy
            // beyond DCT8 fires per block in our fixtures yet) but
            // must still consume the bits.
            if used != 0 {
                let pHdrStart = r.position
                let pHdr: EntropySectionHeader
                do {
                    pHdr = try EntropySectionHeader.read(
                        from: &r, numContexts: CoeffOrders.kPermutationContexts
                    )
                } catch let e as EntropySectionHeaderError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation header "
                        + "read failed: \(e)"
                    )
                }
                let pCB: MultiClusterCodebook
                do {
                    pCB = try MultiClusterCodebook.read(from: &r, header: pHdr)
                } catch let e as MultiClusterCodebookError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation codebook "
                        + "read failed: \(e)"
                    )
                }
                traceLayer(
                    "ACGlobal.permHist[\(passIdx)]",
                    before: pHdrStart, after: r.position
                )
                var pStream = TokenStreamReader(header: pHdr, codebook: pCB)
                let decoded: [Int: [[Int]]]
                do {
                    decoded = try CoeffOrders.decodePermutations(
                        usedOrders: UInt16(used & 0xFFFF),
                        from: &r, stream: &pStream
                    )
                } catch let e as CoeffOrdersError {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: ACGlobal permutation read "
                        + "failed: \(e)"
                    )
                }
                coeffOrdersPerPass.append(decoded)
                if trace {
                    FileHandle.standardError.write(Data(
                        "TRACE ACGlobal.perms[\(passIdx)]: usedOrders=\(used), decoded ords=\(decoded.keys.sorted()), bits consumed at pos=\(r.position)\n".utf8
                    ))
                }
            } else {
                coeffOrdersPerPass.append([:])
            }
        }

        // (13) Per-pass AC DecodeHistograms. libjxl
        // `dec_frame.cc::ProcessACGlobal` (line 393-410):
        //
        //     for (size_t i = 0; i < num_passes; i++) {
        //         used_orders = U32(kOrderEnc, br);   // already read above
        //         DecodeCoeffOrders(...);             // skipped (used_orders=0)
        //         num_contexts = num_histograms × block_ctx_map.NumACContexts()
        //         DecodeHistograms(br, num_contexts, &code[i], &context_map[i])
        //     }
        //
        // `NumACContexts() = num_ctxs × (kNonZeroBuckets +
        // kZeroDensityContextCount) = num_ctxs × (37 + 458)`. For the
        // default kDefaultBlockCtxMap (15 clusters): 15 × 495 = 7425.
        // With num_histograms=1 → 7425 AC contexts.
        let acContexts = Int(acNumHistograms) * bctx.numACContexts
        var acHistsPerPass: [(EntropySectionHeader, MultiClusterCodebook)] = []
        acHistsPerPass.reserveCapacity(numPassesActual)
        for passIdx in 0..<numPassesActual {
            let acHdrStart = r.position
            let acHdr: EntropySectionHeader
            do {
                acHdr = try EntropySectionHeader.read(
                    from: &r, numContexts: acContexts
                )
            } catch let e as EntropySectionHeaderError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: AC histograms[\(passIdx)] header "
                    + "read failed: \(e). num_contexts=\(acContexts)"
                )
            }
            traceLayer("ACHist[\(passIdx)].header", before: acHdrStart,
                       after: r.position)
            let acCBStart = r.position
            let acCB: MultiClusterCodebook
            do {
                acCB = try MultiClusterCodebook.read(from: &r, header: acHdr)
            } catch let e as MultiClusterCodebookError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: AC histograms[\(passIdx)] codebook "
                    + "read failed: \(e). numHistograms=\(acHdr.numHistograms)"
                )
            }
            traceLayer("ACHist[\(passIdx)].codebook", before: acCBStart,
                       after: r.position)
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE ACHist[\(passIdx)]: numClusters=\(acHdr.contextMap.numClusters), usePrefix=\(acHdr.usePrefixCode), logAlpha=\(acHdr.logAlphaSize)\n".utf8
                ))
            }
            acHistsPerPass.append((acHdr, acCB))
        }

        // (14) Per-block AC coefficient stream — Bites 1+2. libjxl
        // `dec_group.cc::DecodeACVarBlock` reads, for each (block, channel):
        //
        //     block_ctx = block_ctx_map.Context(qdc, qf, ord, c)
        //     nzero_ctx = NonZeroContext(predicted_nnz, block_ctx) + ctx_offset
        //     nzeros = readToken(nzero_ctx)
        //     histo_offset = ctx_offset + ZeroDensityContextsOffset(block_ctx)
        //     for k in coveredBlocks..<size while nzeros != 0:
        //         ctx = histo_offset + ZeroDensityContext(nzeros, k, ...)
        //         u = readToken(ctx)
        //         coeff = UnpackSigned(u)        // ZigZag.unpack
        //         block[order[k]] += coeff << shift
        //         if u != 0: nzeros--
        //
        // `ANSSymbolReader::Create` reads a 32-bit rANS state on first
        // token. Our `TokenStreamReader` triggers that lazily inside
        // `readToken` via `ANSStreamDecoder`.
        //
        // For `cjxl -d 1` 8×8 fixture: 1 AC block (1×1 grid) × 3
        // channels (X/Y/B). AC strategy = DCT8 (covered_blocks=1,
        // size=64). All 7425 contexts route to cluster 0 (single
        // histogram), so block_ctx specifics don't change bit positions
        // — order does, but we use `Array(0..<64)` here since the
        // block-position payload is consumed by Bite 3 (Dequant + IDCT).
        // Multi-AC-group AC token decode. For multi-section frames,
        // each AC group lives at its own TOC entry — we seek the
        // BitReader to that section's byte boundary, create a fresh
        // `TokenStreamReader` (the rANS state initialises lazily on
        // first read), and decode the per-block AC tokens for that
        // group's block grid. Each AC group covers a `groupDim` x
        // `groupDim` pixel region (cropped at frame edges).
        let firstACHist = acHistsPerPass[0]
        let dctOrder = naturalCoeffOrderDCT8
        // Per-ord natural-order cache. Lazily populated during the AC
        // decode loop — most fixtures only touch DCT8 (ord 0) but
        // textured cjxl-d=1 frames mix in DCT16x16 (ord 2),
        // DCT32x16/16x32 (ord 6), etc.
        var naturalOrderCache: [Int: [Int]] = [:]
        let totalBlocksX = (xsize + 7) / 8
        let totalBlocksY = (ysize + 7) / 8
        // acBlocks[totalBlockIdx][iterC] is the 64-coef block for the
        // i-th decoded (block, channel) pair, indexed by GLOBAL block
        // position (totalBlocksX × totalBlocksY).
        var acBlocks: [[[Int32]]] = Array(
            repeating: Array(repeating: [Int32](repeating: 0, count: 64),
                             count: 3),
            count: totalBlocksX * totalBlocksY
        )
        let blocksPerGroup = groupDim / 8
        let acDecodeStart = r.position
        for groupIdx in 0..<numGroups {
            // Per-group block range (cropped at frame edges).
            let gx = groupIdx % numGroupsX
            let gy = groupIdx / numGroupsX
            let bxStart = gx * blocksPerGroup
            let byStart = gy * blocksPerGroup
            let bxEnd = min(bxStart + blocksPerGroup, totalBlocksX)
            let byEnd = min(byStart + blocksPerGroup, totalBlocksY)
            let groupBlocksX = bxEnd - bxStart
            // Seek to this group's section. AC group g (pass 0) lives
            // at TOC entry `2 + numDcGroups + g` for multi-section
            // frames; single-section reuses the cursor.
            if tocEntries > 1 {
                let acGroupSecIdx = 2 + numDcGroups + groupIdx
                r = BitReader(
                    r.data, startingAt: sectionBitStart(acGroupSecIdx)
                )
            }
            // Fresh ANS state per AC group (lazy init on first read).
            var acTokenStream = TokenStreamReader(
                header: firstACHist.0, codebook: firstACHist.1
            )
            // Per-group nzeros plane (per channel × cell grid). For
            // multi-block strategies (DCT16x16 etc.) we stamp the
            // first-block's nzeros to ALL covered cells so subsequent
            // first-blocks see the right neighbour values when
            // computing `predNnz`. Mirrors libjxl `dec_group.cc`'s
            // `nzeros_pos[(y+cy)*stride + (x+cx)] = nzeros` loop.
            let groupBlocksY = byEnd - byStart
            var nzPlane = [Int32](
                repeating: 0,
                count: 3 * groupBlocksY * groupBlocksX
            )
            @inline(__always) func nzPredict(
                c: Int, gx: Int, gy: Int
            ) -> UInt32 {
                let stride = groupBlocksX
                let chanOff = c * groupBlocksY * stride
                if gy == 0 && gx == 0 { return 32 }
                if gy == 0 {
                    return UInt32(nzPlane[chanOff + (gx - 1)])
                }
                if gx == 0 {
                    return UInt32(nzPlane[chanOff + (gy - 1) * stride + gx])
                }
                let above = nzPlane[chanOff + (gy - 1) * stride + gx]
                let left  = nzPlane[chanOff + gy * stride + (gx - 1)]
                return UInt32((above + left + 1) >> 1)
            }
            for by in byStart..<byEnd {
                let groupRowIdx = by - byStart
                for bx in bxStart..<bxEnd {
                    let groupColIdx = bx - bxStart
                    // Per-cell strategy lookup. Skip non-first-block
                    // cells (covered by a multi-block transform whose
                    // first-block we already decoded).
                    let entry = acsImage.at(x: bx, y: by)
                    if !entry.isFirstBlock { continue }
                    let strategy = entry.strategy
                    let strategySize = strategy.coveredBlocks * 64
                    let ord = strategy.orderBucket
                    // Default natural order for this ord (cached). Used
                    // when used_orders bit is unset; otherwise replaced
                    // by the per-channel decoded permutation below.
                    let naturalOrder: [Int] = {
                        if let cached = naturalOrderCache[ord] { return cached }
                        let computed = CoeffOrders.naturalCoeffOrder(for: strategy)
                        naturalOrderCache[ord] = computed
                        return computed
                    }()
                    let acBlockQF = UInt32(entry.qf)
                    var blockChannels: [[Int32]] = []
                    blockChannels.reserveCapacity(3)
                    let cellsX = strategy.blockCells.cellsX
                    let cellsY = strategy.blockCells.cellsY
                    // libjxl `dec_group.cc:554` iterates channels in
                    // STORAGE order `{1, 0, 2}` (X, then Y, then B —
                    // libjxl stores Y at slot 0 and X at slot 1, so
                    // storage 1 == X, storage 0 == Y, storage 2 == B).
                    // Iteration index `iterIdx` is also the XYB channel
                    // index after this mapping (0=X, 1=Y, 2=B).
                    for iterIdx in 0..<3 {
                        let storageC = [1, 0, 2][iterIdx]  // libjxl storage c
                        let xybC = iterIdx                  // 0=X, 1=Y, 2=B
                        var blk = [Int32](repeating: 0, count: strategySize)
                        let predNnz = nzPredict(
                            c: iterIdx, gx: groupColIdx, gy: groupRowIdx
                        )
                        // BlockCtxMap.Context takes libjxl STORAGE c
                        // (it does the `c^1 if c<2` swap internally
                        // to map storage→ctx_map row).
                        let blockCtx = bctx.context(
                            dcIdx: 0, qf: acBlockQF,
                            ord: strategy.orderBucket, c: storageC
                        )
                        // Per-channel coeff order. When the bitstream
                        // emitted a Lehmer-coded permutation for this
                        // (pass, ord, storage_c), use it; otherwise fall
                        // back to the default natural order.
                        let strategyOrder: [Int] = {
                            if let perOrd = coeffOrdersPerPass.first?[ord],
                               storageC < perOrd.count {
                                return perOrd[storageC]
                            }
                            return naturalOrder
                        }()
                        do {
                            try ACDecoder.decodeBlock(
                                block: &blk,
                                order: strategyOrder,
                                coveredBlocks: strategy.coveredBlocks,
                                log2CoveredBlocks: strategy.log2CoveredBlocks,
                                blockCtx: blockCtx,
                                predictedNnz: predNnz,
                                ctxOffset: 0,
                                ctxMap: bctx,
                                shift: 0,
                                stream: &acTokenStream,
                                from: &r
                            )
                        } catch let e as ACDecoderError {
                            throw DecoderError.notImplemented(
                                "VarDCT decode: AC group \(groupIdx) block "
                                + "(\(bx),\(by)) strategy=\(strategy) "
                                + "iter \(iterIdx) (xybC=\(xybC), "
                                + "storageC=\(storageC), blockCtx=\(blockCtx)) "
                                + "decode failed: \(e)"
                            )
                        }
                        // libjxl divides nz by coveredBlocks before
                        // stamping (so all covered cells share an
                        // "average" nnz). Round-up division matches
                        // `dec_group.cc::DecodeACVarBlock` post-stamp.
                        let nzTotal = Int32(
                            blk.lazy.filter { $0 != 0 }.count
                        )
                        let nzPerCell =
                            (nzTotal + Int32(strategy.coveredBlocks) - 1)
                                / Int32(strategy.coveredBlocks)
                        let stride = groupBlocksX
                        let chanOff = iterIdx * groupBlocksY * stride
                        for cy in 0..<cellsY {
                            for cx in 0..<cellsX {
                                nzPlane[chanOff
                                    + (groupRowIdx + cy) * stride
                                    + (groupColIdx + cx)] = nzPerCell
                            }
                        }
                        blockChannels.append(blk)
                    }
                    // Per-strategy IDCT support frontier: DCT8x8 is
                    // primary, DCT16x16 ships in v0.8.0d. Other multi-
                    // cell strategies still rely on the per-cell DC
                    // fallback (which gives the correct result only
                    // for all-zero AC — typical of solid-colour
                    // content). Throw early when the bitstream needs
                    // a path we don't ship yet.
                    let strategyIDCTSupported =
                        strategy == .dct8x8
                        || strategy == .dct16x16
                        || strategy == .dct8x16
                        || strategy == .dct16x8
                        || strategy == .dct32x16
                        || strategy == .dct16x32
                        || strategy == .dct32x32
                        || strategy == .dct64x64
                        || strategy == .dct64x32
                        || strategy == .dct32x64
                    if !strategyIDCTSupported {
                        let nzAny = blockChannels.contains {
                            $0.contains { $0 != 0 }
                        }
                        if nzAny {
                            throw DecoderError.notImplemented(
                                "VarDCT decode: AC strategy \(strategy) "
                                + "with non-zero AC at block (\(bx),\(by)) — "
                                + "per-strategy IDCT not yet implemented "
                                + "(next v0.8.0 bite). All-zero AC blocks "
                                + "(typical of solid-colour content) are "
                                + "handled by filling with DC value."
                            )
                        }
                    }
                    acBlocks[by * totalBlocksX + bx] = blockChannels
                }
            }
        }
        let numBlocksXAC = totalBlocksX
        let numBlocksYAC = totalBlocksY
        traceLayer("AC \(numGroups) group(s) "
                   + "(\(numBlocksXAC)×\(numBlocksYAC) blocks total)",
                   before: acDecodeStart, after: r.position)
        if trace {
            for (bIdx, blockChannels) in acBlocks.enumerated() {
                let nzCounts = blockChannels.map {
                    $0.filter { $0 != 0 }.count
                }
                FileHandle.standardError.write(Data(
                    "TRACE ACBlock[block=\(bIdx)]: nz per iter = \(nzCounts)\n".utf8
                ))
            }
        }

        // (15) Bite 3 — Dequant + IDCT. libjxl
        // `dec_xyb.cc::DequantDC` + per-block AC dequant in
        // `dec_group.cc` + `IDCT2DInPlace`.
        //
        //     // Quantizer derived values:
        //     inv_global_scale = (1 << 16) / global_scale
        //     inv_quant_dc = inv_global_scale / quant_dc
        //     mul_dc[c] = inv_quant_dc * (1 / kInvDCQuant[c])    // per channel
        //     // DC apply:
        //     dc_amp[c] = quantized_dc[c] * mul_dc[c] * (1 / (1 << extra_precision))
        //     // AC apply (per coefficient k in natural order):
        //     ac_amp[c][k] = quantized_ac[c][k] * dequant_matrix[c][k] * inv_quant_ac(qf)
        //         where dequant_matrix[c][k] = 1 / quant_weights[c][k]
        //         and inv_quant_ac(qf) = inv_global_scale / qf
        //     // 8x8 IDCT per channel block.
        //
        // For our fixture: extra_precision=1, qf=5, ord=DCT8,
        // global_scale=5111, quant_dc=17. Three (8x8) pixel-domain
        // blocks emerge, still in XYB-encoded space (color correlation
        // and inverse XYB lands in Bite 4).
        let kGlobalScaleDenomF: Float = Float(1 << 16)
        let invGlobalScale: Float = kGlobalScaleDenomF / Float(qp.globalScale)
        let invQuantDC: Float = invGlobalScale / Float(qp.quantDC)
        // libjxl `quant_weights.h::kInvDCQuant`. Indexed by **XYB
        // channel** (X=0, Y=1, B=2).
        let kInvDCQuant: [Float] = [4096.0, 512.0, 256.0]
        let mulDC: [Float] = (0..<3).map { invQuantDC / kInvDCQuant[$0] }
        let dcExtraFactor: Float = 1.0 / Float(1 << dcExtraPrecision)

        // libjxl `dec_cache.h:161-162` — per-channel AC-dequant
        // multiplier driven by frame-header qm_scale. Y is unscaled;
        // X and B get `pow(1/1.25, qm_scale - 2.0)`. Default
        // qm_scale=3 → multiplier = 0.8.
        let xDmMultiplier: Float = powf(
            1.0 / 1.25, Float(fh.xQmScale) - 2.0
        )
        let bDmMultiplier: Float = powf(
            1.0 / 1.25, Float(fh.bQmScale) - 2.0
        )
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE qm_scale: x=\(fh.xQmScale) (mul=\(xDmMultiplier)) b=\(fh.bQmScale) (mul=\(bDmMultiplier))\n".utf8
            ))
        }

        // Channel layout — libjxl swaps storage:
        //
        //   image.channel[c < 2 ? c ^ 1 : c]  for XYB c ∈ {0=X, 1=Y, 2=B}
        //
        // ⇒ storage slot 0 holds Y, slot 1 holds X, slot 2 holds B.
        //
        //   storageToXYB[storage_slot] = XYB channel index
        //
        // For DC, channels were decoded in storage order (slot 0 → 2),
        // so `dcValues[i]` lives at `storageToXYB[i]` in the XYB tables.
        //
        // For AC, libjxl's `LoadBlock` iterates STORAGE c ∈ {1, 0, 2}
        // (i.e., storage X, then Y, then B — the storage swap puts
        // X at slot 1, Y at slot 0). The AC decode loop above adopts
        // this iteration order via the same `[1, 0, 2]` table so that
        // `iterIdx` lines up directly with the XYB channel index
        // (iter 0 = X, iter 1 = Y, iter 2 = B). `acBlocks[blkIdx][i]`
        // is therefore indexed by XYB channel directly.
        let storageToXYB: [Int] = [1, 0, 2]
        let acIterToXYB: [Int] = [0, 1, 2]

        // ACMeta channel 2 shape = `count × 2` (row 0 = ACS values,
        // row 1 = QF values). Flat indices: [ACS_0..ACS_{n-1},
        // QF_0..QF_{n-1}]. Per-block `qf` per libjxl
        // `dec_modular.cc::DecodeAcMetadata`:
        //
        //     row_qf[ix] = 1 + clamp(row_in_2[num], 0, kQuantMax - 1)
        //
        // For our 8×8 fixture: count=1, ACS=[0], QF=[4] → qfPerBlock=[5].
        // For 16×16: count=4, QF=[5,5,6,5] → qfPerBlock=[6,6,7,6].
        // (perBlockQF + qfRow extracted earlier so the AC decode loop
        // can compute proper block_ctx routing for multi-cluster
        // fixtures.)
        _ = perBlockQF.count    // explicit reference, keeps tooling happy
        _ = qfRow               // ditto

        // DCT8 default quant weights: 3 × 64 floats. `qweights[c*64+k]`
        // is the QUANT weight (libjxl stores its inverse in `Matrix()`,
        // so `dequant_matrix = 1 / qweights`). Indexed by XYB channel.
        let dct8Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct8x8
        )
        let qweights: [Float]
        do {
            qweights = try QuantWeights.getQuantWeights(
                rows: 8, cols: 8, bands: dct8Bands
            )
        } catch let e as QuantWeightsError {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT8 quant weights computation failed: \(e)"
            )
        }

        // Multi-block dequant + IDCT + plane assembly. libjxl applies
        // CFL **at the coefficient level**, with DIFFERENT factors for
        // DC vs AC:
        //   • DC pixel: `cfl_dc_b = ytoBRatio(cmap.ytobDC)` (typically
        //     1.0 + 0/84 = 1 for default ColorCorrelation).
        //   • AC coefs: `cfl_ac_b = ytoBRatio(ytob_map[tile])` (depends
        //     on the per-color-tile slope from ACMeta channel 1).
        // We mirror that: DC pixel gets DC-CFL baked in, AC coefs get
        // AC-CFL baked in BEFORE the IDCT. After IDCT no further CFL
        // is applied. (For our 8×8 fixture both slopes are 0 so DC
        // and AC use the same factors and the bug was masked.)
        let dcCflX = cmapDC.ytoXRatio(slope: cmapDC.ytoxDC)
        let dcCflB = cmapDC.ytoBRatio(slope: cmapDC.ytobDC)
        // AC slopes from ACMeta (per-color-tile; for our small fixtures
        // it's a single tile covering the whole image).
        let ytoxSlopeAC = acMetaValues[0].first ?? 0
        let ytobSlopeAC = acMetaValues[1].first ?? 0
        let xCCMul = cmapDC.ytoXRatio(slope: ytoxSlopeAC)
        let bCCMul = cmapDC.ytoBRatio(slope: ytobSlopeAC)
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE CFL: dc=(x=\(dcCflX), b=\(dcCflB)) ac=(x=\(xCCMul), b=\(bCCMul)) (slopes dc=(\(cmapDC.ytoxDC),\(cmapDC.ytobDC)) ac=(\(ytoxSlopeAC),\(ytobSlopeAC)))\n".utf8
            ))
        }

        let planeWidth = numBlocksXAC * 8
        let planeHeight = numBlocksYAC * 8
        var planeXYB: [[Float]] = (0..<3).map { _ in
            [Float](repeating: 0, count: planeWidth * planeHeight)
        }

        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let blockIdx = by * numBlocksXAC + bx
                // v0.9.0h: dump first block's quantised AC values for
                // diagnostic vs djxl. Triggered by JXL_TRACE_AC env var.
                if blockIdx == 0,
                   ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
                    let labels = ["X", "Y", "B"]
                    for c in 0..<3 {
                        let xybC = c
                        let storageSlot = [1, 0, 2][xybC]
                        _ = storageSlot
                        let preview = (0..<8).map {
                            "\(acBlocks[0][c][$0])"
                        }.joined(separator: ",")
                        FileHandle.standardError.write(Data(
                            "TRACE_AC blk0 c=\(c) (\(labels[c])) first8=[\(preview)]\n".utf8
                        ))
                    }
                    FileHandle.standardError.write(Data(
                        "TRACE_AC blk0 dc=(\(dcValues[0][0]), \(dcValues[1][0]), \(dcValues[2][0])) qf=\(blockIdx < perBlockQF.count ? perBlockQF[blockIdx] : qfRow) globalScale=\(qp.globalScale)\n".utf8
                    ))
                }
                // Per-block invQuantAC from this block's QF.
                let blockQF = blockIdx < perBlockQF.count
                    ? perBlockQF[blockIdx] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // 1) Dequant DC for all 3 channels (XYB indexing).
                var dcPixelXYB = [Float](repeating: 0, count: 3)
                for storageSlot in 0..<3 {
                    let xybC = storageToXYB[storageSlot]
                    let dcQuant = Float(
                        dcValues[storageSlot][by * dcWidth + bx]
                    )
                    dcPixelXYB[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                }
                // 2) Apply DC-CFL: X' = X + dcCflX·Y, B' = B + dcCflB·Y.
                let dcY = dcPixelXYB[1]
                let dcCorrectedX = dcPixelXYB[0] + dcCflX * dcY
                let dcCorrectedB = dcPixelXYB[2] + dcCflB * dcY

                // 3) Locate iteration indices for each XYB channel.
                guard
                    let iterX = acIterToXYB.firstIndex(of: 0),
                    let iterY = acIterToXYB.firstIndex(of: 1),
                    let iterB = acIterToXYB.firstIndex(of: 2)
                else {
                    throw DecoderError.notImplemented(
                        "VarDCT decode: AC iter mapping incomplete"
                    )
                }
                let acYBlock = acBlocks[blockIdx][iterY]
                let acXBlock = acBlocks[blockIdx][iterX]
                let acBBlock = acBlocks[blockIdx][iterB]

                // 4) Build coefBlocks with DC at position 0, AC-CFL'd
                //    AC coefs at positions 1..63.
                var coefY = [Float](repeating: 0, count: 64)
                var coefX = [Float](repeating: 0, count: 64)
                var coefB = [Float](repeating: 0, count: 64)
                coefY[0] = dcY
                coefX[0] = dcCorrectedX
                coefB[0] = dcCorrectedB
                for k in 1..<64 {
                    let np = dctOrder[k]
                    let acYDequant = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights[1 * 64 + np] * blockInvQuantAC
                    let acXDequant = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights[0 * 64 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDequant = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights[2 * 64 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coefY[np] = acYDequant
                    coefX[np] = acXDequant + xCCMul * acYDequant
                    coefB[np] = acBDequant + bCCMul * acYDequant
                }
                // v0.9.0i: dump dequantised first-block AC values
                // (post-formula, pre-IDCT) for diagnostic.
                if blockIdx == 0,
                   ProcessInfo.processInfo.environment["JXL_TRACE_AC"] != nil {
                    let labels = ["X", "Y", "B"]
                    for (label, buf) in zip(labels, [coefX, coefY, coefB]) {
                        let preview = (0..<8).map {
                            String(format: "%.5f", buf[$0])
                        }.joined(separator: ",")
                        FileHandle.standardError.write(Data(
                            "TRACE_AC blk0 \(label) DEQUANT first8=[\(preview)]\n".utf8
                        ))
                    }
                    let qwy = qweights[1 * 64 + 1]
                    let qwx = qweights[0 * 64 + 1]
                    let qwb = qweights[2 * 64 + 1]
                    FileHandle.standardError.write(Data(
                        "TRACE_AC qweights[0,1] (X,Y,B)=(\(qwx), \(qwy), \(qwb)) blockInvQuantAC=\(blockInvQuantAC) xDmMul=\(xDmMultiplier) bDmMul=\(bDmMultiplier)\n".utf8
                    ))
                }
                // 5) libjxl-convention IDCT (no bridge factor needed —
                // LibjxlIDCT inverts the libjxl scaled-DCT directly,
                // unlike our orthonormal `DCT2D.inverse` which would
                // require a per-coefficient bridge to convert from
                // libjxl's DC=mean convention to orthonormal scale).
                AccelerateDCT.idct2D(&coefY, size: 8)
                AccelerateDCT.idct2D(&coefX, size: 8)
                AccelerateDCT.idct2D(&coefB, size: 8)
                // 6) Place 8×8 patches at (bx*8, by*8) in each plane.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                for py in 0..<8 {
                    let srcRow = py * 8
                    let dstRow = (yOrigin + py) * planeWidth + xOrigin
                    for px in 0..<8 {
                        planeXYB[0][dstRow + px] = coefX[srcRow + px]
                        planeXYB[1][dstRow + px] = coefY[srcRow + px]
                        planeXYB[2][dstRow + px] = coefB[srcRow + px]
                    }
                }
            }
        }

        // Per-strategy IDCT overlay pass. Iterates over first-blocks
        // and OVERWRITES the per-cell-DCT8 fallback output with the
        // proper per-strategy IDCT for the strategies we now ship
        // natively (currently DCT16x16; next bites add 32x32, 4x8/8x4,
        // 16x8/8x16, etc.). Solid-colour content (all-zero AC) was
        // already correct from the per-cell pass; the overlay just
        // handles textured content.
        let dct16Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct16x16
        )
        let qweights16: [Float]
        do {
            qweights16 = try QuantWeights.getQuantWeights(
                rows: 16, cols: 16, bands: dct16Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT16x16 quant weights computation failed: \(error)"
            )
        }
        guard
            let iterX16 = acIterToXYB.firstIndex(of: 0),
            let iterY16 = acIterToXYB.firstIndex(of: 1),
            let iterB16 = acIterToXYB.firstIndex(of: 2)
        else {
            throw DecoderError.notImplemented(
                "VarDCT decode: AC iter mapping incomplete (DCT16x16 pass)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct16x16 { continue }
                guard bx + 1 < numBlocksXAC, by + 1 < numBlocksYAC else {
                    continue  // safety net; ACStrategyImage.build already
                              // rejects overflowing strategies.
                }
                // Per-block QF (every covered cell shares the
                // first-block's QF — the per-cell perBlockQF entry
                // was set when ACMeta was decoded).
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per channel: build the 256-entry coefficient block,
                // dequant + bridge + IDCT, then place into the plane.
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 256),
                    count: 3
                )
                // Cell DC values (4 cells × 3 channels in pixel space,
                // already DC-CFL'd later — here we apply DC-CFL
                // ourselves since the per-cell loop handled CFL on
                // its 8×8 patches but we need it on the LLF coefs).
                let cellOffsets = [
                    (0, 0), (1, 0), (0, 1), (1, 1)
                ]
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 4)
                }
                for (i, off) in cellOffsets.enumerated() {
                    let (dx, dy) = off
                    let cellBX = bx + dx
                    let cellBY = by + dy
                    var cellDC = [Float](repeating: 0, count: 3)
                    for storageSlot in 0..<3 {
                        let xybC = storageToXYB[storageSlot]
                        let dcQuant = Float(
                            dcValues[storageSlot][cellBY * dcWidth + cellBX]
                        )
                        cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                    }
                    // Apply DC-CFL on the cell DC values (same factors
                    // the per-cell loop uses).
                    let dcY = cellDC[1]
                    dcXYB[0][i] = cellDC[0] + dcCflX * dcY
                    dcXYB[1][i] = dcY
                    dcXYB[2][i] = cellDC[2] + dcCflB * dcY
                }
                // LLF coefficients per channel via 2×2 forward DCT +
                // resample scaling. Map to natural-order positions
                // 0, 1, 16, 17 of the 16×16 coef grid.
                let llfX = LowestFrequenciesFromDC.dct16x16(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.dct16x16(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.dct16x16(dc: dcXYB[2])
                let llfPositions = [0, 1, 16, 17]
                for (i, pos) in llfPositions.enumerated() {
                    coef[0][pos] = llfX[i]
                    coef[1][pos] = llfY[i]
                    coef[2][pos] = llfB[i]
                }
                // AC coefficients per channel: dequant via DCT16x16
                // quant matrix + AC-CFL. AC tokens were stored in
                // natural-order layout already (decodeBlock writes
                // to block[order[k]]) so we iterate natural positions
                // directly — only the LLF positions (filled above)
                // are skipped.
                let acYBlock = acBlocks[blockIdxFirst][iterY16]
                let acXBlock = acBlocks[blockIdxFirst][iterX16]
                let acBBlock = acBlocks[blockIdxFirst][iterB16]
                let llfSet: Set<Int> = [0, 1, 16, 17]
                for np in 0..<256 where !llfSet.contains(np) {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights16[1 * 256 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights16[0 * 256 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights16[2 * 256 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // libjxl-convention IDCT (no bridge needed —
                // LibjxlIDCT inverts the libjxl scaled DCT directly).
                AccelerateDCT.idct2D(&coef[0], size: 16)
                AccelerateDCT.idct2D(&coef[1], size: 16)
                AccelerateDCT.idct2D(&coef[2], size: 16)
                // Place 16×16 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                for py in 0..<16 {
                    let srcRow = py * 16
                    let dstRow = (yOrigin + py) * planeWidth + xOrigin
                    for px in 0..<16 {
                        planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                        planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                        planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                    }
                }
            }
        }

        // DCT16x8 / DCT8x16 IDCT overlay (libjxl ord 4). Both share
        // the same 16×8 coefficient layout (after `CoefficientLayout`
        // swap), the same `dct8x16` quant matrix, the same √128
        // bridge factor, and the same 2-coef LLF region. The only
        // difference is pixel placement: DCT8x16 outputs 16w × 8h
        // pixels (matches coef layout), DCT16x8 outputs 8w × 16h
        // pixels (transposed from coef layout).
        let dct8x16Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct8x16
        )
        let qweights8x16: [Float]
        do {
            qweights8x16 = try QuantWeights.getQuantWeights(
                rows: 8, cols: 16, bands: dct8x16Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT8x16 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct8x16 && entry.strategy != .dct16x8 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct16x8  // 8w×16h
                let cellsX = isVerticalStack ? 1 : 2
                let cellsY = isVerticalStack ? 2 : 1
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per-channel coef block (128 entries in 8-row × 16-col
                // layout).
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 128),
                    count: 3
                )
                // Cell DC values + DC-CFL.
                let cellOffsets: [(Int, Int)] = isVerticalStack
                    ? [(0, 0), (0, 1)]   // DCT16x8: cells (bx,by), (bx,by+1)
                    : [(0, 0), (1, 0)]   // DCT8x16: cells (bx,by), (bx+1,by)
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 2)
                }
                for (i, off) in cellOffsets.enumerated() {
                    let (dx, dy) = off
                    let cellBX = bx + dx
                    let cellBY = by + dy
                    var cellDC = [Float](repeating: 0, count: 3)
                    for storageSlot in 0..<3 {
                        let xybC = storageToXYB[storageSlot]
                        let dcQuant = Float(
                            dcValues[storageSlot][cellBY * dcWidth + cellBX]
                        )
                        cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                    }
                    let dcY = cellDC[1]
                    dcXYB[0][i] = cellDC[0] + dcCflX * dcY
                    dcXYB[1][i] = dcY
                    dcXYB[2][i] = cellDC[2] + dcCflB * dcY
                }
                // 2 LLF coefficients per channel at natural-order
                // positions 0 and 1.
                let llfX = LowestFrequenciesFromDC.ord4Pair(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.ord4Pair(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.ord4Pair(dc: dcXYB[2])
                coef[0][0] = llfX[0]; coef[0][1] = llfX[1]
                coef[1][0] = llfY[0]; coef[1][1] = llfY[1]
                coef[2][0] = llfB[0]; coef[2][1] = llfB[1]
                // AC coefficients: dequant via DCT8x16 quant matrix
                // (8 rows × 16 cols layout) + AC-CFL.
                // iter index = XYB index (post v0.8.0e fix).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 2..<128 {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights8x16[1 * 128 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights8x16[0 * 128 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights8x16[2 * 128 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // libjxl-convention IDCT (replaces bridge×√128 + ortho IDCT).
                // Coef layout is 8 rows × 16 cols (after CoefficientLayout swap).
                AccelerateDCT.idct2D(&coef[0], rows: 8, cols: 16)
                AccelerateDCT.idct2D(&coef[1], rows: 8, cols: 16)
                AccelerateDCT.idct2D(&coef[2], rows: 8, cols: 16)
                // Place pixels. DCT8x16: 16w × 8h direct.
                // DCT16x8: 8w × 16h, transposed from the 16w × 8h
                // IDCT output (pixel[y][x] = coef_pix[x][y]).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT16x8: 8 wide × 16 tall pixels.
                    for py in 0..<16 {
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<8 {
                            // Transpose: coef layout (px=col, py=row)
                            // becomes pixel layout (py, px).
                            let srcIdx = px * 16 + py
                            planeXYB[0][dstRow + px] = coef[0][srcIdx]
                            planeXYB[1][dstRow + px] = coef[1][srcIdx]
                            planeXYB[2][dstRow + px] = coef[2][srcIdx]
                        }
                    }
                } else {
                    // DCT8x16: 16 wide × 8 tall pixels.
                    for py in 0..<8 {
                        let srcRow = py * 16
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<16 {
                            planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                            planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                            planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                        }
                    }
                }
            }
        }

        // DCT32x16 / DCT16x32 IDCT overlay (libjxl ord 6). Same
        // template as DCT16x8/DCT8x16 but on a 32×16 coef layout
        // with 8 LLF coefficients (4 cols × 2 rows in coef space).
        let dct16x32Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct16x32
        )
        let qweights16x32: [Float]
        do {
            qweights16x32 = try QuantWeights.getQuantWeights(
                rows: 16, cols: 32, bands: dct16x32Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT16x32 quant weights computation failed: \(error)"
            )
        }
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct32x16 && entry.strategy != .dct16x32 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct32x16  // 16w×32h
                let cellsX = isVerticalStack ? 2 : 4
                let cellsY = isVerticalStack ? 4 : 2
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per-channel coef block (32 cols × 16 rows = 512).
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 512),
                    count: 3
                )
                // 8 cell DC values + DC-CFL. Coef-layout order is
                // 4 cols × 2 rows (cx=4, cy=2 after CoefficientLayout).
                // For DCT32x16 (cellsX=2, cellsY=4): the coef layout
                // (4 cols × 2 rows) is the TRANSPOSE of the 2-col × 4-
                // row pixel-cell layout. We want dc[r * 4 + c] in
                // coef-layout = cell at pixel-cell (c'=r, r'=c) where
                // (c', r') indexes into the original 2×4 grid. So:
                //     dc[0..3] = (0,0), (1,0), (0,1), (1,1) of pix
                //     wait that's wrong. Let me think again.
                // Actually, libjxl's `dc_stride` is the DC plane
                // stride. For DCT32x16, the DC values it reads are:
                //   dc(bx + cx, by + cy) for cx in 0..covered_x=2,
                //                            cy in 0..covered_y=4.
                // In libjxl's input to ComputeScaledDCT<4, 2>, this
                // is laid out as 4 ROWS (cy=0..4) × 2 COLS (cx=0..2),
                // with stride dc_stride. So input[row, col] =
                // dc(bx+col, by+row).
                // Our `ord6Block` expects 4 cols × 2 rows row-major
                // (which is the COEF-layout transpose of input).
                // So we need: out[r * 4 + c] = input[c, r] = dc(bx+r, by+c).
                // For DCT32x16: out[r * 4 + c] = dc(bx + r, by + c)
                //   r in 0..2 (coef rows), c in 0..4 (coef cols).
                // Wait, ord6Block expects out[2 rows × 4 cols], so
                // r in 0..2, c in 0..4. And out[r * 4 + c] = ?
                // For DCT32x16 (cellsX=2, cellsY=4 in pix; covered_x=2,
                // covered_y=4): cells at (bx+cx, by+cy) for cx ∈ [0,2),
                // cy ∈ [0,4). After CoefficientLayout (cx_coef >=
                // cy_coef), the coef layout is cx_coef=4, cy_coef=2,
                // and the coef rows correspond to PIXEL cell rows
                // SWAPPED. The input to ord6Block is row-major in
                // COEF layout; for DCT32x16, that means:
                //   coef_row r ↔ pixel cell column r (cx=r)
                //   coef_col c ↔ pixel cell row c   (cy=c)
                //   ord6Block input[r * 4 + c] = dc(bx + r, by + c)
                // For DCT16x32 (cellsX=4, cellsY=2): coef layout is
                // ALREADY the same as pixel layout (cx_coef=4, cy_coef=2).
                //   ord6Block input[r * 4 + c] = dc(bx + c, by + r)
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 8)
                }
                for r in 0..<2 {
                    for c in 0..<4 {
                        let cellBX: Int
                        let cellBY: Int
                        if isVerticalStack {
                            // DCT32x16: input[r * 4 + c] = dc(bx+r, by+c)
                            cellBX = bx + r
                            cellBY = by + c
                        } else {
                            // DCT16x32: input[r * 4 + c] = dc(bx+c, by+r)
                            cellBX = bx + c
                            cellBY = by + r
                        }
                        var cellDC = [Float](repeating: 0, count: 3)
                        for storageSlot in 0..<3 {
                            let xybC = storageToXYB[storageSlot]
                            let dcQuant = Float(
                                dcValues[storageSlot][cellBY * dcWidth + cellBX]
                            )
                            cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                        }
                        let dcY = cellDC[1]
                        let idx = r * 4 + c
                        dcXYB[0][idx] = cellDC[0] + dcCflX * dcY
                        dcXYB[1][idx] = dcY
                        dcXYB[2][idx] = cellDC[2] + dcCflB * dcY
                    }
                }
                // 8 LLF coefficients per channel.
                let llfX = LowestFrequenciesFromDC.ord6Block(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.ord6Block(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.ord6Block(dc: dcXYB[2])
                // Place at top-left 4 cols × 2 rows of the 32-wide
                // coef block (natural-order positions 0..3, 32..35).
                for r in 0..<2 {
                    for c in 0..<4 {
                        let pos = r * 32 + c
                        coef[0][pos] = llfX[r * 4 + c]
                        coef[1][pos] = llfY[r * 4 + c]
                        coef[2][pos] = llfB[r * 4 + c]
                    }
                }
                // AC coefficients (skip the 8 LLF positions).
                let llfSet: Set<Int> = [
                    0, 1, 2, 3,
                    32, 33, 34, 35,
                ]
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 0..<512 where !llfSet.contains(np) {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights16x32[1 * 512 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights16x32[0 * 512 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights16x32[2 * 512 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // libjxl-convention IDCT (replaces bridge×√512 + ortho IDCT).
                // Coef layout 16 rows × 32 cols (after CoefficientLayout swap).
                AccelerateDCT.idct2D(&coef[0], rows: 16, cols: 32)
                AccelerateDCT.idct2D(&coef[1], rows: 16, cols: 32)
                AccelerateDCT.idct2D(&coef[2], rows: 16, cols: 32)
                // Place pixels.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT32x16: 16 wide × 32 tall (transposed from coef).
                    for py in 0..<32 {
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<16 {
                            let srcIdx = px * 32 + py
                            planeXYB[0][dstRow + px] = coef[0][srcIdx]
                            planeXYB[1][dstRow + px] = coef[1][srcIdx]
                            planeXYB[2][dstRow + px] = coef[2][srcIdx]
                        }
                    }
                } else {
                    // DCT16x32: 32 wide × 16 tall (matches coef layout).
                    for py in 0..<16 {
                        let srcRow = py * 32
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<32 {
                            planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                            planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                            planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                        }
                    }
                }
            }
        }

        // DCT32x32 IDCT overlay (libjxl ord 3). Square 32×32 strategy
        // with cellsX = cellsY = 4. LLF region is the 4×4 corner of
        // the 32×32 coef block (16 LLF positions). Bridge factor is
        // the square root of the area = √(32×32) = 32 (uniform).
        let dct32Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct32x32
        )
        let qweights32: [Float]
        do {
            qweights32 = try QuantWeights.getQuantWeights(
                rows: 32, cols: 32, bands: dct32Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT32x32 quant weights computation failed: \(error)"
            )
        }
        // 16 LLF natural-order positions in a 32-wide grid (top-left
        // 4 cols × 4 rows): (0..3, 0..3) → flat 0..3, 32..35, 64..67,
        // 96..99.
        let llfSet32x32: Set<Int> = {
            var s: Set<Int> = []
            for r in 0..<4 { for c in 0..<4 { s.insert(r * 32 + c) } }
            return s
        }()
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct32x32 { continue }
                guard bx + 4 <= numBlocksXAC,
                      by + 4 <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per-channel coef block (32 cols × 32 rows = 1024).
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 1024),
                    count: 3
                )
                // 16 cell DC values + DC-CFL.
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 16)
                }
                for r in 0..<4 {
                    for c in 0..<4 {
                        let cellBX = bx + c
                        let cellBY = by + r
                        var cellDC = [Float](repeating: 0, count: 3)
                        for storageSlot in 0..<3 {
                            let xybC = storageToXYB[storageSlot]
                            let dcQuant = Float(
                                dcValues[storageSlot][cellBY * dcWidth + cellBX]
                            )
                            cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                        }
                        let dcY = cellDC[1]
                        let idx = r * 4 + c
                        dcXYB[0][idx] = cellDC[0] + dcCflX * dcY
                        dcXYB[1][idx] = dcY
                        dcXYB[2][idx] = cellDC[2] + dcCflB * dcY
                    }
                }
                let llfX = LowestFrequenciesFromDC.dct32x32(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.dct32x32(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.dct32x32(dc: dcXYB[2])
                for r in 0..<4 {
                    for c in 0..<4 {
                        let pos = r * 32 + c
                        coef[0][pos] = llfX[r * 4 + c]
                        coef[1][pos] = llfY[r * 4 + c]
                        coef[2][pos] = llfB[r * 4 + c]
                    }
                }
                // AC coefficients (skip 16 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 0..<1024 where !llfSet32x32.contains(np) {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights32[1 * 1024 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights32[0 * 1024 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights32[2 * 1024 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // libjxl-convention IDCT (replaces bridge×32 + ortho IDCT).
                AccelerateDCT.idct2D(&coef[0], size: 32)
                AccelerateDCT.idct2D(&coef[1], size: 32)
                AccelerateDCT.idct2D(&coef[2], size: 32)
                // Place 32×32 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                for py in 0..<32 {
                    let srcRow = py * 32
                    let dstRow = (yOrigin + py) * planeWidth + xOrigin
                    for px in 0..<32 {
                        planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                        planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                        planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                    }
                }
            }
        }

        // DCT64x32 / DCT32x64 IDCT overlay (libjxl ord 8). Asymmetric
        // 64×32 coef layout (after CoefficientLayout swap). LLF is
        // the top-left 8×4 corner of that grid (32 LLF positions).
        // Pattern mirrors DCT32x16/16x32.
        let dct32x64Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct32x64
        )
        let qweights32x64: [Float]
        do {
            qweights32x64 = try QuantWeights.getQuantWeights(
                rows: 32, cols: 64, bands: dct32x64Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT32x64 quant weights computation failed: \(error)"
            )
        }
        let llfSet32x64: Set<Int> = {
            var s: Set<Int> = []
            for r in 0..<4 { for c in 0..<8 { s.insert(r * 64 + c) } }
            return s
        }()
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct64x32 && entry.strategy != .dct32x64 {
                    continue
                }
                let isVerticalStack = entry.strategy == .dct64x32  // 32w×64h px
                let cellsX = isVerticalStack ? 4 : 8
                let cellsY = isVerticalStack ? 8 : 4
                guard bx + cellsX <= numBlocksXAC,
                      by + cellsY <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per-channel coef block (64 cols × 32 rows = 2048).
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 2048),
                    count: 3
                )
                // 32 cell DC values + DC-CFL. Coef-layout order is
                // 8 cols × 4 rows (cx=8, cy=4 after CoefficientLayout).
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 32)
                }
                for r in 0..<4 {
                    for c in 0..<8 {
                        let cellBX: Int
                        let cellBY: Int
                        if isVerticalStack {
                            // DCT64x32 (cellsX=4, cellsY=8): coef row r
                            // ↔ pixel-cell column r; coef col c ↔ cell row c.
                            cellBX = bx + r
                            cellBY = by + c
                        } else {
                            // DCT32x64 (cellsX=8, cellsY=4): coef row r
                            // ↔ cell row r; coef col c ↔ cell col c.
                            cellBX = bx + c
                            cellBY = by + r
                        }
                        var cellDC = [Float](repeating: 0, count: 3)
                        for storageSlot in 0..<3 {
                            let xybC = storageToXYB[storageSlot]
                            let dcQuant = Float(
                                dcValues[storageSlot][cellBY * dcWidth + cellBX]
                            )
                            cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                        }
                        let dcY = cellDC[1]
                        let idx = r * 8 + c
                        dcXYB[0][idx] = cellDC[0] + dcCflX * dcY
                        dcXYB[1][idx] = dcY
                        dcXYB[2][idx] = cellDC[2] + dcCflB * dcY
                    }
                }
                let llfX = LowestFrequenciesFromDC.ord8Block(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.ord8Block(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.ord8Block(dc: dcXYB[2])
                for r in 0..<4 {
                    for c in 0..<8 {
                        let pos = r * 64 + c
                        coef[0][pos] = llfX[r * 8 + c]
                        coef[1][pos] = llfY[r * 8 + c]
                        coef[2][pos] = llfB[r * 8 + c]
                    }
                }
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 0..<2048 where !llfSet32x64.contains(np) {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights32x64[1 * 2048 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights32x64[0 * 2048 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights32x64[2 * 2048 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // 64×32 IDCT per channel (libjxl-convention).
                AccelerateDCT.idct2D(&coef[0], rows: 32, cols: 64)
                AccelerateDCT.idct2D(&coef[1], rows: 32, cols: 64)
                AccelerateDCT.idct2D(&coef[2], rows: 32, cols: 64)
                // Place pixels.
                let xOrigin = bx * 8
                let yOrigin = by * 8
                if isVerticalStack {
                    // DCT64x32: 32 wide × 64 tall (transposed from coef).
                    for py in 0..<64 {
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<32 {
                            let srcIdx = px * 64 + py
                            planeXYB[0][dstRow + px] = coef[0][srcIdx]
                            planeXYB[1][dstRow + px] = coef[1][srcIdx]
                            planeXYB[2][dstRow + px] = coef[2][srcIdx]
                        }
                    }
                } else {
                    // DCT32x64: 64 wide × 32 tall (matches coef layout).
                    for py in 0..<32 {
                        let srcRow = py * 64
                        let dstRow = (yOrigin + py) * planeWidth + xOrigin
                        for px in 0..<64 {
                            planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                            planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                            planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                        }
                    }
                }
            }
        }

        // DCT64x64 IDCT overlay (libjxl ord 7). Square 64×64 strategy
        // with cellsX = cellsY = 8 (covers 8×8 = 64 cells = 64×64 px).
        // LLF region is the 8×8 corner of the 64×64 coef block (64
        // LLF positions). Pattern mirrors DCT32x32.
        let dct64Bands = DefaultQuantBands.scaledForBitstream(
            DefaultQuantBands.dct64x64
        )
        let qweights64: [Float]
        do {
            qweights64 = try QuantWeights.getQuantWeights(
                rows: 64, cols: 64, bands: dct64Bands
            )
        } catch {
            throw DecoderError.notImplemented(
                "VarDCT decode: DCT64x64 quant weights computation failed: \(error)"
            )
        }
        let llfSet64x64: Set<Int> = {
            var s: Set<Int> = []
            for r in 0..<8 { for c in 0..<8 { s.insert(r * 64 + c) } }
            return s
        }()
        for by in 0..<numBlocksYAC {
            for bx in 0..<numBlocksXAC {
                let entry = acsImage.at(x: bx, y: by)
                if !entry.isFirstBlock { continue }
                if entry.strategy != .dct64x64 { continue }
                guard bx + 8 <= numBlocksXAC,
                      by + 8 <= numBlocksYAC
                else { continue }
                let blockIdxFirst = by * totalBlocksX + bx
                let blockQF = blockIdxFirst < perBlockQF.count
                    ? perBlockQF[blockIdxFirst] : qfRow
                let blockInvQuantAC = invGlobalScale / Float(blockQF)
                // Per-channel coef block (64 cols × 64 rows = 4096).
                var coef = [[Float]](
                    repeating: [Float](repeating: 0, count: 4096),
                    count: 3
                )
                // 64 cell DC values + DC-CFL.
                var dcXYB: [[Float]] = (0..<3).map { _ in
                    [Float](repeating: 0, count: 64)
                }
                for r in 0..<8 {
                    for c in 0..<8 {
                        let cellBX = bx + c
                        let cellBY = by + r
                        var cellDC = [Float](repeating: 0, count: 3)
                        for storageSlot in 0..<3 {
                            let xybC = storageToXYB[storageSlot]
                            let dcQuant = Float(
                                dcValues[storageSlot][cellBY * dcWidth + cellBX]
                            )
                            cellDC[xybC] = dcQuant * mulDC[xybC] * dcExtraFactor
                        }
                        let dcY = cellDC[1]
                        let idx = r * 8 + c
                        dcXYB[0][idx] = cellDC[0] + dcCflX * dcY
                        dcXYB[1][idx] = dcY
                        dcXYB[2][idx] = cellDC[2] + dcCflB * dcY
                    }
                }
                let llfX = LowestFrequenciesFromDC.dct64x64(dc: dcXYB[0])
                let llfY = LowestFrequenciesFromDC.dct64x64(dc: dcXYB[1])
                let llfB = LowestFrequenciesFromDC.dct64x64(dc: dcXYB[2])
                for r in 0..<8 {
                    for c in 0..<8 {
                        let pos = r * 64 + c
                        coef[0][pos] = llfX[r * 8 + c]
                        coef[1][pos] = llfY[r * 8 + c]
                        coef[2][pos] = llfB[r * 8 + c]
                    }
                }
                // AC coefficients (skip 64 LLF positions).
                let acYBlock = acBlocks[blockIdxFirst][1]
                let acXBlock = acBlocks[blockIdxFirst][0]
                let acBBlock = acBlocks[blockIdxFirst][2]
                for np in 0..<4096 where !llfSet64x64.contains(np) {
                    let acYDeq = AdjustQuantBias.adjust(
                        channel: 1, quant: acYBlock[np]
                    ) / qweights64[1 * 4096 + np] * blockInvQuantAC
                    let acXDeq = AdjustQuantBias.adjust(
                        channel: 0, quant: acXBlock[np]
                    ) / qweights64[0 * 4096 + np] * blockInvQuantAC
                        * xDmMultiplier
                    let acBDeq = AdjustQuantBias.adjust(
                        channel: 2, quant: acBBlock[np]
                    ) / qweights64[2 * 4096 + np] * blockInvQuantAC
                        * bDmMultiplier
                    coef[1][np] = acYDeq
                    coef[0][np] = acXDeq + xCCMul * acYDeq
                    coef[2][np] = acBDeq + bCCMul * acYDeq
                }
                // 64×64 IDCT per channel (libjxl-convention).
                AccelerateDCT.idct2D(&coef[0], size: 64)
                AccelerateDCT.idct2D(&coef[1], size: 64)
                AccelerateDCT.idct2D(&coef[2], size: 64)
                // Place 64×64 patch at (bx*8, by*8).
                let xOrigin = bx * 8
                let yOrigin = by * 8
                for py in 0..<64 {
                    let srcRow = py * 64
                    let dstRow = (yOrigin + py) * planeWidth + xOrigin
                    for px in 0..<64 {
                        planeXYB[0][dstRow + px] = coef[0][srcRow + px]
                        planeXYB[1][dstRow + px] = coef[1][srcRow + px]
                        planeXYB[2][dstRow + px] = coef[2][srcRow + px]
                    }
                }
            }
        }

        if trace {
            let labels = ["X", "Y", "B"]
            for c in 0..<3 {
                let block = planeXYB[c]
                let mean = block.reduce(0.0, +) / Float(block.count)
                let minVal = block.min() ?? 0
                let maxVal = block.max() ?? 0
                FileHandle.standardError.write(Data(
                    "TRACE plane[\(labels[c])]: dim=\(planeWidth)×\(planeHeight) mean=\(mean) range=[\(minVal), \(maxVal)]\n".utf8
                ))
            }
        }

        // (16) Bite 4 — Color correlation + inverse OpsinXYB +
        // sRGB OETF + 8-bit RGB output. libjxl applies color
        // correlation per-coefficient inside `DequantLane`:
        //
        //     dequant_x = x_cc_mul * dequant_y + dequant_x_cc
        //     dequant_b = b_cc_mul * dequant_y + dequant_b_cc
        //
        // Since IDCT is linear and `cc_mul` is constant per tile,
        // applying the same MulAdd in pixel domain is mathematically
        // equivalent. For our 1-tile fixture:
        //     x_cc_mul = base_correlation_x + ytox_map[0] / color_factor
        //              = 0 + 0/84 = 0
        //     b_cc_mul = base_correlation_b + ytob_map[0] / color_factor
        //              = 1 + 0/84 = 1
        // So X stays, B becomes Y + B.
        // CFL slopes are computed above (before the dequant loop).

        // CFL is already baked into the planes at the coefficient
        // level (DC-CFL on F[0,0], AC-CFL on F[k>0]). Just hand the
        // planes off to Gaborish + EPF + the inverse XYB stage.
        var planeX = planeXYB[0]
        var planeY = planeXYB[1]
        var planeB = planeXYB[2]

        // EXPERIMENT v0.9.0k: skip Gaborish + EPF to isolate raw IDCT pixels.
        let skipPhaseR = ProcessInfo.processInfo.environment["JXL_SKIP_PHASE_R"] != nil

        // Phase R restoration filters. libjxl pipeline order
        // (`dec_cache.cc::PreparePipeline`):
        //
        //     ChromaUpsampling → Gaborish (if lf.gab) → EPF (epf_iters
        //     stages) → ... → XYB (inverse OpsinXYB) → sRGB OETF
        //
        // Gaborish is a 3×3 separable-style smoothing convolution
        // applied per-channel. Default weights from libjxl
        // `loop_filter.cc::LoopFilter::SetDefault`:
        //   gab_x_weight1 = 0.115169424
        //   gab_x_weight2 = 0.061248592
        //   (same for Y and B; identical to our `Gaborish.defaultWeight*`)
        //
        // EPF is deferred until later in v0.6.0.
        if fh.loopFilter.gab && !skipPhaseR {
            Gaborish.apply(to: &planeX, width: planeWidth, height: planeHeight)
            Gaborish.apply(to: &planeY, width: planeWidth, height: planeHeight)
            Gaborish.apply(to: &planeB, width: planeWidth, height: planeHeight)
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE Gaborish applied to all 3 channels (\(planeWidth)×\(planeHeight))\n".utf8
                ))
            }
        }

        // EPF — edge-preserving filter, up to 3 iterations gated by
        // `lf.epfIters`. For our cjxl-d=1 fixture the EPF sharpness
        // field (ACMeta channel 3) is all zeros → no-op fast path.
        if fh.loopFilter.epfIters > 0 && !skipPhaseR {
            // Sharpness field per block (ACMeta channel 3).
            let totalBlocks = numBlocksXAC * numBlocksYAC
            let sharpField: [UInt8] = (acMetaValues.count > 3
                && acMetaValues[3].count >= totalBlocks)
                ? acMetaValues[3].prefix(totalBlocks).map { UInt8(clamping: $0) }
                : [UInt8](repeating: 0, count: totalBlocks)
            // Wire the per-block QF (already extracted above).
            let perBlockQFForEPF: [Int32] = (perBlockQF.count >= totalBlocks)
                ? Array(perBlockQF.prefix(totalBlocks))
                : [Int32](repeating: qfRow, count: totalBlocks)
            // Override params.epfIters with the loopFilter's value
            // since the default EPFParams uses 2.
            let epfParams = EPFParams(
                epfIters: Int(fh.loopFilter.epfIters),
                quantMul: EPFParams.default.quantMul,
                sharpLut: EPFParams.default.sharpLut,
                channelScale: EPFParams.default.channelScale,
                pass1ZeroFlush: EPFParams.default.pass1ZeroFlush,
                pass2ZeroFlush: EPFParams.default.pass2ZeroFlush,
                pass0SigmaScale: EPFParams.default.pass0SigmaScale,
                pass2SigmaScale: EPFParams.default.pass2SigmaScale,
                borderSadMul: EPFParams.default.borderSadMul
            )
            do {
                try EPF.applyAllStages(
                    planeX: &planeX, planeY: &planeY, planeB: &planeB,
                    width: planeWidth, height: planeHeight,
                    sharpnessField: sharpField,
                    perBlockQF: perBlockQFForEPF,
                    quantScale: Float(qp.globalScale)
                        / Float(1 << 16),
                    params: epfParams
                )
                if trace {
                    FileHandle.standardError.write(Data(
                        "TRACE EPF: \(fh.loopFilter.epfIters) iter(s); sharpness=\(sharpField); per-block QF=\(perBlockQFForEPF)\n".utf8
                    ))
                }
            } catch let e as EPFError {
                throw DecoderError.notImplemented(
                    "VarDCT decode: EPF stage failed: \(e)"
                )
            }
        }

        // Per-pixel XYB → linear RGB → sRGB → 8-bit. Crop the W*H plane
        // back to the frame's actual `xsize × ysize` (the plane is
        // padded out to a multiple of 8).
        var rgb8 = [UInt8](repeating: 0, count: xsize * ysize * 3)
        for y in 0..<ysize {
            for x in 0..<xsize {
                let pi = y * planeWidth + x
                let lin = OpsinXYB.inverse(
                    (X: planeX[pi], Y: planeY[pi], B: planeB[pi])
                )
                let oi = (y * xsize + x) * 3
                rgb8[oi + 0] = linearToSRGB8(lin.R)
                rgb8[oi + 1] = linearToSRGB8(lin.G)
                rgb8[oi + 2] = linearToSRGB8(lin.B)
            }
        }
        if trace {
            for y in 0..<min(3, ysize) {
                var row = "TRACE RGB row \(y):"
                for x in 0..<min(3, xsize) {
                    let i = (y * xsize + x) * 3
                    row += " (\(rgb8[i]),\(rgb8[i+1]),\(rgb8[i+2]))"
                }
                FileHandle.standardError.write(Data((row + "\n").utf8))
            }
        }

        // (17) Wire RGB into ImageFrame. Multi-block (v0.7.0) — for
        // frames that span multiple AC groups the AC decode loop
        // would need to be repeated per group with separate ANS
        // state; that's the v0.7.0+ multi-group milestone. For
        // single-AC-group frames (xsize, ysize ≤ group_dim, default
        // 256), the current pipeline is sufficient.
        // Multi-AC-group is now wired up. DC group support (frames
        // wider than ~2048 px) still needs additional plumbing.
        guard numDcGroups == 1 else {
            throw DecoderError.notImplemented(
                "VarDCT decode: \(xsize)×\(ysize) frame spans multiple "
                + "DC groups (numDcGroups=\(numDcGroups)). Multi-DC-group "
                + "support is a follow-on bite."
            )
        }
        let _ = (kRequiredSizeX, kRequiredSizeY)
        var frame = ImageFrame(width: xsize, height: ysize, channels: 3)
        frame.data = rgb8
        return frame
    }

    /// Per-IEC 61966-2-1 sRGB OETF: linear-light [0,1] → 8-bit code
    /// value. Clamps to [0, 255].
    @inline(__always)
    private func linearToSRGB8(_ linear: Float) -> UInt8 {
        let clamped = max(0, min(linear, 1))
        let encoded: Float
        if clamped <= 0.0031308 {
            encoded = 12.92 * clamped
        } else {
            encoded = 1.055 * powf(clamped, 1.0 / 2.4) - 0.055
        }
        let rounded = (encoded * 255.0).rounded()
        return UInt8(max(0, min(rounded, 255)))
    }

    /// Best-effort container unwrap: returns the naked codestream
    /// bytes for either form (signature-prefix or ISOBMFF).
    private func unwrapCodestream(_ data: Data) -> Data? {
        guard let form = try? parseJXLContainer(data) else { return nil }
        switch form {
        case .naked:
            return data
        case .iso(let boxes):
            return try? extractCodestream(from: boxes, in: data)
        }
    }

    /// Repack a successfully decoded `ModularImage` into an
    /// `ImageFrame` with the conventions the rest of the toolchain
    /// (CLI, PNM writer) expects: row-major channel-interleaved,
    /// 8-bit samples in `UInt8`, 9..16-bit samples packed as
    /// little-endian `UInt16` pairs.
    private func assembleImageFrame(
        modular: ModularImage, metadata m: ImageMetadata,
        xsize: Int, ysize: Int
    ) throws -> ImageFrame {
        let bps = m.bitDepth.bitsPerSample
        guard !m.bitDepth.floatingPoint else {
            throw DecoderError.notImplemented(
                "float-sample decode (bitsPerSample=\(bps), floating)"
            )
        }
        guard bps >= 1 && bps <= 16 else {
            throw DecoderError.notImplemented(
                "decode of \(bps)-bit samples (only 1..16 supported today)"
            )
        }
        let pixelType: PixelType = (bps <= 8) ? .uint8 : .uint16
        let isGray = (m.colorEncoding.colorSpace == .grayscale)
        let nbColor = isGray ? 1 : 3
        let nbExtra = m.extraChannels.count
        let totalChannels = nbColor + nbExtra
        guard modular.channels.count >= totalChannels else {
            throw DecoderError.notImplemented(
                "ModularImage has \(modular.channels.count) channels; "
                + "metadata declares \(totalChannels)"
            )
        }
        // We surface up to 1 extra channel as alpha. Spec allows
        // more (depth, spot colour, …) but `ImageFrame.alphaChannels`
        // is 0 or 1; everything else gets dropped here.
        let alphaIdx: Int? = (0..<nbExtra).first(where: {
            m.extraChannels[$0].type == .alpha
        }).map { nbColor + $0 }
        let outChannels: Int
        let alphaChannels: Int
        if alphaIdx != nil {
            outChannels = nbColor + 1
            alphaChannels = 1
        } else {
            outChannels = nbColor
            alphaChannels = 0
        }
        var frame = ImageFrame(
            width: xsize, height: ysize, channels: outChannels,
            pixelType: pixelType,
            colorSpace: isGray ? .grayscale : .sRGB,
            alphaChannels: alphaChannels
        )
        let bytesPerSample = pixelType.bytesPerSample
        let stride = outChannels * bytesPerSample
        // Helper to write one Int32 sample at the right byte offset.
        let writeSample: (Int, Int32) -> Void = { dstByte, value in
            let clamped = UInt32(max(0, value))
            switch bytesPerSample {
            case 1:
                frame.data[dstByte] = UInt8(min(clamped, 255))
            default:
                frame.data[dstByte] = UInt8(clamped & 0xff)
                frame.data[dstByte + 1] = UInt8((clamped >> 8) & 0xff)
            }
        }
        // Colour channels: 0..<nbColor.
        for ci in 0..<nbColor {
            let pixels = modular.channels[ci].pixels
            for i in 0..<(xsize * ysize) {
                writeSample(i * stride + ci * bytesPerSample, pixels[i])
            }
        }
        // Alpha (if present) follows the colour channels.
        if let aIdx = alphaIdx {
            let pixels = modular.channels[aIdx].pixels
            let aOffset = nbColor * bytesPerSample
            for i in 0..<(xsize * ysize) {
                writeSample(i * stride + aOffset, pixels[i])
            }
        }
        return frame
    }

    public func decodeAll(_ data: Data) throws -> [ImageFrame] {
        throw DecoderError.notImplemented("multi-frame decoding")
    }

    /// End-to-end Modular pixel decode. Walks the container + headers,
    /// decodes the MA-tree + post-tree codebook, reads the
    /// GroupHeader(s), applies meta-transforms, decodes every
    /// wire-level channel rect, then runs the inverse transform chain
    /// via `applyInverseTransforms`.
    ///
    /// **Validated against cjxl/djxl** with exact pixel match for
    /// 32×32 RGB and 256×256 grayscale tests (single-group), plus
    /// 512×512 grayscale (multi-group): every pixel of every channel
    /// after inverse transforms equals the original input image —
    /// healthcare-grade byte equality.
    ///
    /// **Scope** of cjxl-emitted files this currently handles:
    ///   • Single-group OR multi-group Modular lossless frames
    ///     (`numPasses == 1`).
    ///   • RCT (any of the 42 spec types, full coverage in `SpecRCT`).
    ///   • Squeeze (with libjxl's `SmoothTendency` predictor).
    ///   • Tree-decode predictors 0..5 + 6 (Weighted via
    ///     `WeightedPredictor`) + 7..13 (Average / TopRight / etc.).
    ///   • rANS or prefix-coded entropy sections.
    ///
    /// **Out of scope** (yet): multi-pass progressive frames,
    /// Palette transform, LZ77 length-token expansion, TOC
    /// permutation, VarDCT frames. These will throw structured errors.
    ///
    /// The `force` parameter is retained for backwards compatibility
    /// with the experimental-period gating; it's now a no-op.
    public func decodeModular(
        _ data: Data, force: Bool = true
    ) throws -> ModularImage {
        _ = force
        let inspection = try inspect(data)
        guard let m = inspection.metadata else {
            throw DecoderError.notImplemented(
                "ImageMetadata couldn't be parsed"
            )
        }
        let codestream: Data
        switch inspection.form {
        case .naked:
            codestream = data
        case .container:
            guard let parsed = try? parseJXLContainer(data),
                  case let .iso(boxes) = parsed,
                  let cs = try? extractCodestream(from: boxes, in: data) else {
                throw DecoderError.notImplemented(
                    "container codestream extraction failed"
                )
            }
            codestream = cs
        }
        var r = BitReader(codestream, startingAt: 16)
        _ = try SizeHeader.read(from: &r)
        _ = try ImageMetadata.read(from: &r)
        // CustomTransformData (libjxl `image_metadata.cc`): 1 bit when
        // all_default. For non-XYB images the body is just that one
        // bit, so we read & discard it before byte-aligning.
        _ = try? r.readCustomTransformData(xybEncoded: m.xybEncoded)
        try r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: m.xybEncoded,
            numExtraChannels: m.extraChannels.count,
            haveAnimation: m.animation != nil,
            haveTimecodes: m.animation?.haveTimecodes ?? false
        )
        let fh = try FrameHeader.read(from: &r, context: ctx)
        guard fh.encoding == .modular else {
            throw DecoderError.notImplemented(
                "decodeModular requires a Modular frame; got \(fh.encoding)"
            )
        }
        let xsize = Int(inspection.xsize)
        let ysize = Int(inspection.ysize)
        // libjxl `frame_dimensions.h::FrameDimensions::Set`:
        //   group_dim = (kGroupDim >> 1) << group_size_shift  // = 128 << shift
        //   dc_group_dim = group_dim * kBlockDim              // = group_dim * 8
        // shift∈{0,1,2,3} → group_dim∈{128,256,512,1024}.
        let groupDim = 128 << Int(fh.groupSizeShift)
        let dcGroupDim = groupDim << 3
        let numGroupsX = (xsize + groupDim - 1) / groupDim
        let numGroupsY = (ysize + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY
        let numDcGroupsX = (xsize + dcGroupDim - 1) / dcGroupDim
        let numDcGroupsY = (ysize + dcGroupDim - 1) / dcGroupDim
        let numDcGroups = numDcGroupsX * numDcGroupsY
        let numPasses = Int(fh.passes.numPasses)
        if numPasses != 1 {
            throw DecoderError.notImplemented(
                "Modular multi-pass progressive (numPasses=\(numPasses))"
            )
        }
        let tocEntries = TOC.numEntries(
            numGroups: numGroups, numDcGroups: numDcGroups,
            numPasses: numPasses
        )
        let toc = try TOC.read(from: &r, numEntries: tocEntries)
        let nbColor = (m.colorEncoding.colorSpace == .grayscale) ? 1 : 3
        let isMultiSection = !(numGroups == 1 && numPasses == 1)
        // Per-section byte starts (only meaningful when multi-section).
        // libjxl `toc.cc::ReadGroupOffsets` already computes per-logical-
        // section offsets (handling any TOC permutation), so we use
        // `toc.offsets[i]` directly rather than re-deriving from sizes.
        let section0Byte = r.position / 8
        var sectionByteStarts: [Int] = []
        if isMultiSection {
            for i in 0..<toc.entrySizes.count {
                sectionByteStarts.append(section0Byte &+ Int(toc.offsets[i]))
            }
        }
        // Section 0: matrices DC, has_tree, tree+codebook, GroupHeader,
        // and (single-section flow only) all pixel data. In the
        // multi-section flow, channels with `w ≤ groupDim && h ≤ groupDim`
        // also decode here ("global" channels); larger channels defer
        // to per-group AC sections.
        var s0 = isMultiSection
            ? BitReader(codestream, startingAt: sectionByteStarts[0] * 8)
            : r
        let matrixDcDefault = try s0.readBit()
        if !matrixDcDefault {
            for _ in 0..<3 { _ = try s0.read(bits: 16) }
        }
        // libjxl `dec_modular.cc::DecodeGlobalInfo` reads `has_tree`
        // here; if true, decodes the global MA-tree + post-tree
        // codebook. If false, both stay nil and each per-section
        // GroupHeader's `useGlobalTree` MUST be false (the per-section
        // tree+codebook is decoded inline before its pixel data).
        let hasTree = try s0.readBit()
        let globalTree: ModularTree?
        let globalPostHdr: EntropySectionHeader?
        let globalPostCB: MultiClusterCodebook?
        if hasTree {
            let treeHdr = try EntropySectionHeader.read(from: &s0, numContexts: 6)
            let treeCB = try MultiClusterCodebook.read(from: &s0, header: treeHdr)
            var treeStream = TokenStreamReader(header: treeHdr, codebook: treeCB)
            let tree = try ModularTree.decode(from: &s0, stream: &treeStream)
            let postHdr = try EntropySectionHeader.read(
                from: &s0, numContexts: tree.leafCount
            )
            let postCB = try MultiClusterCodebook.read(from: &s0, header: postHdr)
            globalTree = tree
            globalPostHdr = postHdr
            globalPostCB = postCB
        } else {
            globalTree = nil
            globalPostHdr = nil
            globalPostCB = nil
        }
        // libjxl `dec_modular.cc::DecodeGlobalInfo` reads the
        // GroupHeader directly after the post-tree codebook with NO
        // byte alignment. Match that.
        let globalGH = try GroupHeader.read(from: &s0)
        if ProcessInfo.processInfo.environment["JXL_TRACE"] != nil {
            let msg = "TRACE GH(no-align): useGlobal=\(globalGH.useGlobalTree), wpDefault=\(globalGH.wpHeader.allDefault), numTransforms=\(globalGH.transforms.count) numGroups=\(numGroups) hasTree=\(hasTree)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            for (ti, t) in globalGH.transforms.enumerated() {
                let tmsg = "TRACE   transform[\(ti)]: id=\(t.id) beginC=\(t.beginC) numC=\(t.numC) rctType=\(t.rctType)\n"
                FileHandle.standardError.write(Data(tmsg.utf8))
            }
        }
        // Build the modular image with both colour channels and any
        // declared extras. libjxl `dec_modular.cc::DecodeGlobalInfo`:
        //   gi.channel[ec].shrink(DivCeil(xsize_upsampled, ec_ups),
        //                          DivCeil(ysize_upsampled, ec_ups))
        //   gi.channel[ec].hshift = gi.channel[ec].vshift =
        //       log2(ec_ups) - log2(frame.upsampling)
        // For typical lossless cjxl output `ec_upsampling == 1` and
        // `frame.upsampling == 1`, so extras live at full resolution
        // with hshift = vshift = 0 — same as colour channels.
        let nbExtra = m.extraChannels.count
        var image = ModularImage.fresh(
            xsize: xsize, ysize: ysize,
            nbColor: nbColor, nbExtra: nbExtra
        )
        // Resize each extra channel per its `extra_channel_upsampling`
        // and the frame's main `upsampling` factor.
        if nbExtra > 0 {
            let frameUps = max(1, Int(fh.upsampling))
            let frameUpsLog = log2Floor(frameUps)
            for ec in 0..<nbExtra {
                let ecUps: Int
                if ec < fh.extraChannelUpsampling.count {
                    ecUps = max(1, Int(fh.extraChannelUpsampling[ec]))
                } else {
                    ecUps = 1
                }
                let ecW = (xsize + ecUps - 1) / ecUps
                let ecH = (ysize + ecUps - 1) / ecUps
                let shift = log2Floor(ecUps) - frameUpsLog
                let chIdx = nbColor + ec
                image.channels[chIdx] = ModularChannel(
                    width: ecW, height: ecH,
                    hshift: max(0, shift), vshift: max(0, shift)
                )
            }
        }
        try metaApplyTransforms(image: &image, transforms: globalGH.transforms)
        if !isMultiSection {
            // Single-section: pixel data follows the GroupHeader in
            // section 0. Decode every channel here. If the global
            // tree is present and the GroupHeader says useGlobalTree,
            // use it; otherwise decode a per-section tree.
            let useTree: ModularTree
            let usePostHdr: EntropySectionHeader
            let usePostCB: MultiClusterCodebook
            if globalGH.useGlobalTree, let gt = globalTree,
               let gh = globalPostHdr, let gc = globalPostCB {
                useTree = gt; usePostHdr = gh; usePostCB = gc
            } else {
                let lTreeHdr = try EntropySectionHeader.read(
                    from: &s0, numContexts: 6
                )
                let lTreeCB = try MultiClusterCodebook.read(
                    from: &s0, header: lTreeHdr
                )
                var lTreeStream = TokenStreamReader(
                    header: lTreeHdr, codebook: lTreeCB
                )
                useTree = try ModularTree.decode(
                    from: &s0, stream: &lTreeStream
                )
                usePostHdr = try EntropySectionHeader.read(
                    from: &s0, numContexts: useTree.leafCount
                )
                usePostCB = try MultiClusterCodebook.read(
                    from: &s0, header: usePostHdr
                )
            }
            var pixelStream = TokenStreamReader(
                header: usePostHdr, codebook: usePostCB
            )
            let geometries = image.channels.map {
                ModularChannelGeometry(width: $0.width, height: $0.height)
            }
            let decoded = try decodeAllChannels(
                channels: geometries, groupId: 0,
                tree: useTree, stream: &pixelStream, from: &s0,
                wpHeader: globalGH.wpHeader
            )
            for i in 0..<image.channels.count {
                image.channels[i].pixels = decoded[i]
            }
        } else {
            // Multi-section. Section 0 may carry "global" channels —
            // those whose post-shift dimensions both fit in one group.
            // Larger channels defer to per-group AC sections.
            // Section 0's "global" channel decode uses the global
            // tree if `globalGH.useGlobalTree` (otherwise it would
            // need its own tree, but cjxl's typical pattern is
            // useGlobalTree=true for section 0 when channels are present).
            if let gt = globalTree, let gh = globalPostHdr,
               let gc = globalPostCB, globalGH.useGlobalTree {
                var globalPixelStream = TokenStreamReader(
                    header: gh, codebook: gc
                )
                for ci in 0..<image.channels.count {
                    let ch = image.channels[ci]
                    if ch.width <= groupDim && ch.height <= groupDim {
                        var buf = [Int32](
                            repeating: 0, count: ch.width * ch.height
                        )
                        try decodeModularChannel(
                            width: ch.width, height: ch.height,
                            staticChannel: Int32(ci), groupId: 0,
                            tree: gt, stream: &globalPixelStream, from: &s0,
                            wpHeader: globalGH.wpHeader,
                            out: &buf
                        )
                        image.channels[ci].pixels = buf
                    }
                }
            }
            // Per-group AC sections. Layout (libjxl `NumTocEntries`):
            //   [0]                         DC global  (already read)
            //   [1 .. 1+numDcGroups)        DC groups  (empty for Modular)
            //   [1+numDcGroups]             AC global  (empty for Modular)
            //   [2+numDcGroups + g .. )     AC group g (per-group data)
            let acStartIdx = 2 + numDcGroups
            for groupIdx in 0..<numGroups {
                let gx = groupIdx % numGroupsX
                let gy = groupIdx / numGroupsX
                let sectionIdx = acStartIdx + groupIdx
                var gr = BitReader(
                    codestream, startingAt: sectionByteStarts[sectionIdx] * 8
                )
                let groupGH = try GroupHeader.read(from: &gr)
                // Tree + post-tree codebook for this section: either
                // the global ones (useGlobalTree=true) or per-section
                // ones decoded inline.
                let pgTree: ModularTree
                let pgPostHdr: EntropySectionHeader
                let pgPostCB: MultiClusterCodebook
                if groupGH.useGlobalTree, let gt = globalTree,
                   let gh = globalPostHdr, let gc = globalPostCB {
                    pgTree = gt; pgPostHdr = gh; pgPostCB = gc
                } else {
                    let lTreeHdr = try EntropySectionHeader.read(
                        from: &gr, numContexts: 6
                    )
                    let lTreeCB = try MultiClusterCodebook.read(
                        from: &gr, header: lTreeHdr
                    )
                    var lTreeStream = TokenStreamReader(
                        header: lTreeHdr, codebook: lTreeCB
                    )
                    pgTree = try ModularTree.decode(
                        from: &gr, stream: &lTreeStream
                    )
                    pgPostHdr = try EntropySectionHeader.read(
                        from: &gr, numContexts: pgTree.leafCount
                    )
                    pgPostCB = try MultiClusterCodebook.read(
                        from: &gr, header: pgPostHdr
                    )
                }
                var groupPixelStream = TokenStreamReader(
                    header: pgPostHdr, codebook: pgPostCB
                )
                // libjxl `ModularStreamId::ModularAC(group, pass).ID()`:
                //   id = 1 + numDcGroups + pass * numGroups + group
                // Pass=0 here (only single-pass Modular supported).
                // Tree property 1 ("group_id" static prop) branches on
                // this value when present, so byte-equality requires
                // the libjxl convention exactly.
                let streamId = 1 + numDcGroups + 0 * numGroups + groupIdx

                // Build the per-group sub-image (libjxl `gi` in
                // `dec_modular.cc::DecodeGroup`). It contains one
                // rect per too-big channel, in original-image order;
                // each rect's geometry is the channel's per-axis
                // group_dim quantum.
                struct GroupChannelMap {
                    let parentChannel: Int  // index in full image
                    let rectX0: Int
                    let rectY0: Int
                }
                var subImage = ModularImage(channels: [], nbMetaChannels: 0)
                var rectMap: [GroupChannelMap] = []
                for ci in 0..<image.channels.count {
                    let ch = image.channels[ci]
                    if ch.width <= groupDim && ch.height <= groupDim {
                        continue
                    }
                    let chGroupDimX = max(1, groupDim >> ch.hshift)
                    let chGroupDimY = max(1, groupDim >> ch.vshift)
                    let rectX0 = gx * chGroupDimX
                    let rectY0 = gy * chGroupDimY
                    if rectX0 >= ch.width || rectY0 >= ch.height {
                        continue
                    }
                    let rectW = min(chGroupDimX, ch.width - rectX0)
                    let rectH = min(chGroupDimY, ch.height - rectY0)
                    subImage.channels.append(ModularChannel(
                        width: rectW, height: rectH,
                        hshift: ch.hshift, vshift: ch.vshift
                    ))
                    rectMap.append(GroupChannelMap(
                        parentChannel: ci, rectX0: rectX0, rectY0: rectY0
                    ))
                }
                let preTransformChannelCount = subImage.channels.count
                // Apply per-group meta-transforms (libjxl
                // `ModularDecode` line 555: `for (Transform& t : ...) { t.MetaApply(image); }`).
                try metaApplyTransforms(
                    image: &subImage, transforms: groupGH.transforms
                )
                // Decode every (post-meta-apply) channel of the
                // sub-image in order. libjxl's MAANS decode iterates
                // until `channel.w > max_chan_size || channel.h > max_chan_size`,
                // but inside a per-group section every rect already
                // fits in group_dim by construction.
                for sci in 0..<subImage.channels.count {
                    let sch = subImage.channels[sci]
                    if sch.width == 0 || sch.height == 0 { continue }
                    var buf = [Int32](
                        repeating: 0, count: sch.width * sch.height
                    )
                    try decodeModularChannel(
                        width: sch.width, height: sch.height,
                        staticChannel: Int32(sci),
                        groupId: Int32(streamId),
                        tree: pgTree, stream: &groupPixelStream, from: &gr,
                        wpHeader: groupGH.wpHeader,
                        out: &buf
                    )
                    subImage.channels[sci].pixels = buf
                }
                // Inverse per-group transforms (libjxl
                // `ModularGenericDecompress` line 680: `image.undo_transforms(header->wp_header)`).
                try applyInverseTransforms(
                    image: &subImage, transforms: groupGH.transforms
                )
                // Sanity: post-undo channel count must match pre-meta-apply.
                guard subImage.channels.count == preTransformChannelCount else {
                    throw DecoderError.notImplemented(
                        "per-group transform changed channel count "
                        + "post-inverse (got \(subImage.channels.count) "
                        + "expected \(preTransformChannelCount))"
                    )
                }
                // Stitch each sub-image channel's rect into the
                // corresponding full-image channel.
                for (sci, info) in rectMap.enumerated() {
                    let sch = subImage.channels[sci]
                    let parentCh = image.channels[info.parentChannel]
                    let rectW = sch.width
                    let rectH = sch.height
                    for ry in 0..<rectH {
                        let srcStart = ry * rectW
                        let dstStart = (info.rectY0 + ry)
                            * parentCh.width + info.rectX0
                        for rx in 0..<rectW {
                            image.channels[info.parentChannel].pixels[dstStart + rx] =
                                sch.pixels[srcStart + rx]
                        }
                    }
                }
            }
        }
        try applyInverseTransforms(image: &image, transforms: globalGH.transforms)
        return image
    }

    /// Inspect frame-level structure of a JXL byte stream — the
    /// FrameHeader, TOC, and (for Modular frames) the MA-tree
    /// statistics. Best-effort: each field is `nil` if our reader
    /// hit an unsupported pattern at that layer or earlier. The
    /// fields-up-to-the-error path always works through whatever
    /// it could read.
    ///
    /// Useful as `jxl-tool info` material, and for diagnostics
    /// without running the full pixel decoder.
    public func inspectFrameStructure(_ data: Data) -> JXLFrameInspection {
        // Walk the headers we already know how to read.
        guard let inspection = try? inspect(data),
              let m = inspection.metadata else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // Re-position a reader at the start of the codestream and
        // walk past the headers.
        let codestream: Data
        if case .naked = inspection.form {
            codestream = data
        } else {
            // Container form — re-extract the codestream slice.
            guard let parsed = try? parseJXLContainer(data),
                  case let .iso(boxes) = parsed,
                  let cs = try? extractCodestream(from: boxes, in: data) else {
                return JXLFrameInspection(
                    encoding: nil, isLast: nil, flags: nil,
                    numPasses: nil, tocSizes: nil,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            codestream = cs
        }
        var r = BitReader(codestream, startingAt: 16)
        // Re-read SizeHeader + ImageMetadata to sync the reader.
        guard let _ = try? SizeHeader.read(from: &r),
              let _ = try? ImageMetadata.read(from: &r) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        _ = try? r.readCustomTransformData(xybEncoded: m.xybEncoded)
        try? r.alignToByte()
        let ctx = FrameHeaderContext(
            xybEncoded: m.xybEncoded,
            numExtraChannels: m.extraChannels.count,
            haveAnimation: m.animation != nil,
            haveTimecodes: m.animation?.haveTimecodes ?? false
        )
        guard let fh = try? FrameHeader.read(from: &r, context: ctx) else {
            return JXLFrameInspection(
                encoding: nil, isLast: nil, flags: nil,
                numPasses: nil, tocSizes: nil,
                hasModularTree: nil, modularTreeLeafCount: nil,
                usePrefixCode: nil
            )
        }
        // TOC entry count derives from FrameHeader.groupSizeShift +
        // image dims. libjxl `frame_dimensions.h::FrameDimensions::Set`:
        //   group_dim = 128 << group_size_shift
        //   dc_group_dim = group_dim * 8
        let xs = Int(inspection.xsize)
        let ys = Int(inspection.ysize)
        let groupDim = 128 << Int(fh.groupSizeShift)
        let dcGroupDim = groupDim << 3
        let numG = ((xs + groupDim - 1) / groupDim)
                 * ((ys + groupDim - 1) / groupDim)
        let numDG = ((xs + dcGroupDim - 1) / dcGroupDim)
                  * ((ys + dcGroupDim - 1) / dcGroupDim)
        let entries = TOC.numEntries(
            numGroups: numG, numDcGroups: numDG,
            numPasses: Int(fh.passes.numPasses)
        )
        let toc = try? TOC.read(from: &r, numEntries: entries)
        let tocSizes = toc?.entrySizes

        // For Modular frames, try to walk into the MA-tree section.
        // Position the reader at section 0 (first TOC entry's start).
        // For multi-section frames the reader is already there;
        // alignment was performed by TOC.read.
        var hasTree: Bool? = nil
        var leafCount: Int? = nil
        var usePrefix: Bool? = nil
        if fh.encoding == .modular {
            // Skip matrices.DecodeDC bit (1 if default).
            guard let matrixDcDefault = try? r.readBit() else {
                return JXLFrameInspection(
                    encoding: fh.encoding, isLast: fh.isLast,
                    flags: fh.flags, numPasses: fh.passes.numPasses,
                    tocSizes: tocSizes,
                    hasModularTree: nil, modularTreeLeafCount: nil,
                    usePrefixCode: nil
                )
            }
            if !matrixDcDefault {
                // Skip 3 × F16.
                for _ in 0..<3 {
                    guard let _ = try? r.read(bits: 16) else { break }
                }
            }
            if let ht = try? r.readBit() {
                hasTree = ht
                if ht {
                    if let treeHdr = try? EntropySectionHeader.read(
                        from: &r, numContexts: 6
                    ),
                    let treeCB = try? MultiClusterCodebook.read(
                        from: &r, header: treeHdr
                    ) {
                        var treeStream = TokenStreamReader(
                            header: treeHdr, codebook: treeCB
                        )
                        if let tree = try? ModularTree.decode(
                            from: &r, stream: &treeStream
                        ) {
                            leafCount = tree.leafCount
                            // Try the post-tree section for usePrefix info.
                            if let postHdr = try? EntropySectionHeader.read(
                                from: &r, numContexts: tree.leafCount
                            ) {
                                usePrefix = postHdr.usePrefixCode
                            }
                        }
                    }
                }
            }
        }

        return JXLFrameInspection(
            encoding: fh.encoding, isLast: fh.isLast,
            flags: fh.flags, numPasses: fh.passes.numPasses,
            tocSizes: tocSizes,
            hasModularTree: hasTree, modularTreeLeafCount: leafCount,
            usePrefixCode: usePrefix
        )
    }

    /// Inspect a JXL byte stream's container and codestream-header
    /// metadata without decoding any pixels. This *is* implemented.
    public func inspect(_ data: Data) throws -> JXLInspection {
        let form: JXLInspection.Form
        var codestream: Data
        var boxTypes: [String] = []
        do {
            switch try parseJXLContainer(data) {
            case .naked:
                form = .naked
                codestream = data
            case .iso(let boxes):
                form = .container
                boxTypes = boxes.map { $0.type }
                codestream = try extractCodestream(from: boxes, in: data)
            }
        } catch let e as ContainerError {
            throw DecoderError.container(e)
        }

        guard hasCodestreamSignature(codestream) else {
            throw DecoderError.missingSignature
        }
        var reader = BitReader(codestream, startingAt: 16) // skip 2-byte signature
        do {
            let size = try SizeHeader.read(from: &reader)
            // Best-effort: try to read ImageMetadata. If the spec branches
            // we don't yet handle (e.g. exotic extensions) trip us up,
            // fall back to size-only inspection — that's still useful.
            let metadata: ImageMetadata?
            do {
                metadata = try ImageMetadata.read(from: &reader)
            } catch {
                metadata = nil
            }
            return JXLInspection(form: form, xsize: size.xsize, ysize: size.ysize,
                                 boxTypes: boxTypes, metadata: metadata)
        } catch let e as BitstreamError {
            throw DecoderError.bitstream(e)
        }
    }
}

extension BitReader {
    /// libjxl `image_metadata.cc::CustomTransformData::VisitFields` —
    /// read between `ImageMetadata` and the JumpToByteBoundary that
    /// precedes the FrameHeader. For non-XYB images with all defaults
    /// (the common case), the body is a single `all_default = 1` bit.
    /// We don't yet support custom upsampling weights, so anything but
    /// all_default trips us up and is rejected by the surrounding
    /// `try?` — but no reader-side regression for the common case.
    mutating func readCustomTransformData(xybEncoded: Bool) throws {
        let allDefault = try readBit()
        if allDefault { return }
        if xybEncoded {
            throw BitstreamError.malformedValue(
                "custom opsin matrix not supported"
            )
        }
        // custom_weights_mask u(3); we only accept zero (no custom
        // upsampling weights). Anything else needs the per-mode kernel
        // tables libjxl hardcodes — not yet wired up.
        let mask = try read(bits: 3)
        if mask != 0 {
            throw BitstreamError.malformedValue(
                "custom upsampling weights mask=\(mask) not supported"
            )
        }
    }
}
