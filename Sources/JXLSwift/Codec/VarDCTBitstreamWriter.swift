// VarDCTBitstreamWriter — serialises a `VarDCTEncoder.Quantized`
// into a complete JPEG XL VarDCT codestream.
//
// This is the inverse of `JXLDecoder.decodeVarDCTPartial`, written
// section-for-section against that decoder's read sequence.
//
// Quantised DC **and AC** coefficients are written: the AC token
// stream (`generateACTokens`) is the exact inverse of
// `ACDecoder.decodeBlock` — per (block, channel) an `nzeros` token
// then `ZeroDensityContext`-routed coefficient tokens — so the
// frame is a genuine lossy compression, not just block averages.
//
// Scope: single-section frames (one AC group, one DC group, one
// pass — i.e. xsize, ysize ≤ group_dim ≈ 256 px), DCT8×8 only,
// default colour-correlation / quant matrices / block-context map,
// `used_orders = 0`, `num_histograms = 1`.
//
// Spec reference: ISO/IEC 18181-1 §K. libjxl: `enc_frame.cc`.

import Foundation

/// Serialises forward-transformed VarDCT data into a codestream.
public enum VarDCTBitstreamWriter {

    public enum WriterError: Error, Sendable {
        case unsupported(String)
    }

    /// libjxl `kOrderEnc` — the U32 distribution for `used_orders`.
    static let kOrderEnc: (UInt32Distribution, UInt32Distribution,
                           UInt32Distribution, UInt32Distribution) =
        (.literal(0x5F), .literal(0x13), .literal(0), .bits(13))

    /// Encode an 8-bit RGB/RGBA `ImageFrame` as a DC-only VarDCT
    /// JPEG XL file (naked codestream).
    public static func encode(frame: ImageFrame) throws -> Data {
        let q = try VarDCTEncoder.forward(frame: frame)
        let groupDim = 256
        guard q.xsize <= groupDim, q.ysize <= groupDim else {
            throw WriterError.unsupported(
                "VarDCT encode: \(q.xsize)×\(q.ysize) exceeds one "
                + "group — multi-section encode not implemented")
        }
        let blocksX = q.blocksX, blocksY = q.blocksY
        let nBlocks = blocksX * blocksY

        // --- Modular DC + ACMeta sub-images ----------------------
        // Both use the LfGlobal global tree; their residual tokens
        // share one pooled Huffman codebook. The DC modular image
        // stores the 3 channels in storage order {Y, X, B}.
        let dcChannels: [[Int32]] = [
            q.dcQuant[1], q.dcQuant[0], q.dcQuant[2],
        ]
        // ACMeta: YToX, YToB (one per 64-px tile, all-zero default
        // CfL), ACS+QF (count×2), EPF sharpness (all-zero).
        let cW = max(1, (blocksX + 7) / 8)
        let cH = max(1, (blocksY + 7) / 8)
        var acsQF = [Int32](repeating: 0, count: nBlocks * 2)
        for i in 0..<nBlocks {
            acsQF[i] = 0                       // ACS = DCT8
            acsQF[nBlocks + i] = q.qf - 1      // QF − 1 (decoder + 1)
        }
        let acMetaChannels: [(pix: [Int32], w: Int, h: Int)] = [
            ([Int32](repeating: 0, count: cW * cH), cW, cH),
            ([Int32](repeating: 0, count: cW * cH), cW, cH),
            (acsQF, nBlocks, 2),
            ([Int32](repeating: 0, count: nBlocks), blocksX, blocksY),
        ]

        // Pool residual tokens across every modular channel.
        let postCfg = HybridUintConfig.raw4
        var modHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var maxModToken = 0
        var dcPacked: [[UInt32]] = []
        for c in dcChannels {
            let p = modularResiduals(
                c, width: blocksX, height: blocksY,
                cfg: postCfg, histo: &modHisto, maxToken: &maxModToken)
            dcPacked.append(p)
        }
        var acMetaPacked: [[UInt32]] = []
        for ch in acMetaChannels {
            let p = modularResiduals(
                ch.pix, width: ch.w, height: ch.h,
                cfg: postCfg, histo: &modHisto, maxToken: &maxModToken)
            acMetaPacked.append(p)
        }
        let modAlphabet = maxModToken + 1
        let modLengths = lengthLimitedCanonicalHuffman(
            counts: Array(modHisto[0..<modAlphabet]),
            maxLength: 15, alphabetSize: modAlphabet)
        let modCodebook = MultiClusterCodebook(
            huffmanTables: [try PrefixCodeTable(lengths: modLengths)],
            ansCounts: [], alphabetSizes: [modAlphabet])
        let modHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [postCfg])

        // --- AC token codebook (HfGlobal) ------------------------
        // Generate the per-block AC tokens (nzeros + coefficients),
        // then pool their HybridUint symbols into one Huffman.
        let bctx = BlockCtxMap()
        let acContexts = bctx.numACContexts
        let acCfg = HybridUintConfig.raw4
        let acTokens = generateACTokens(q: q, bctx: bctx)
        var acHisto = [Int](repeating: 0, count: acCfg.maxToken + 1)
        var maxAcToken = 0
        for tok in acTokens {
            let t = Int(acCfg.encode(tok.value).token)
            acHisto[t] += 1
            if t > maxAcToken { maxAcToken = t }
        }
        // Keep the Huffman alphabet ≥ 2 (the canonical builder is
        // undefined for a single symbol — a flat image emits only
        // token 0).
        var acAlphabet = maxAcToken + 1
        var acCounts = Array(acHisto[0..<acAlphabet])
        if acAlphabet < 2 { acAlphabet = 2; acCounts.append(1) }
        let acLengths = lengthLimitedCanonicalHuffman(
            counts: acCounts, maxLength: 15, alphabetSize: acAlphabet)
        let acCodebook = MultiClusterCodebook(
            huffmanTables: [try PrefixCodeTable(lengths: acLengths)],
            ansCounts: [], alphabetSizes: [acAlphabet])
        let acHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: acContexts),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [acCfg])

        // --- Section 0 -------------------------------------------
        var sec = BitWriter()
        // LfGlobal.
        sec.writeBit(true)                       // DequantMatricesDC default
        try QuantizerParams(
            globalScale: q.globalScale, quantDC: q.quantDC
        ).write(to: &sec)
        sec.writeBit(true)                       // BlockCtxMap default
        sec.writeBit(true)                       // ColorCorrelation DC default
        sec.writeBit(true)                       // has_tree
        try writeModularTreeSection(
            to: &sec, postHeader: modHeader, postCodebook: modCodebook)
        // gi modular sub-image: 0 channels (no extra channels) ⇒
        // `ModularDecode` returns before reading anything.

        // DC group.
        sec.write(bits: 2, value: 0)             // dc_extra_precision = 0
        try GroupHeader.default.write(to: &sec)
        let dcWriter = TokenStreamWriter(
            header: modHeader, codebook: modCodebook)
        for packed in dcPacked {
            for v in packed {
                try dcWriter.writeToken(context: 0, value: v, to: &sec)
            }
        }
        // ACMetadata.
        let acMetaBits = Int(ceilLog2(UInt32(max(1, nBlocks))))
        if acMetaBits > 0 {
            sec.write(bits: acMetaBits, value: UInt32(nBlocks - 1))
        }
        try GroupHeader.default.write(to: &sec)
        let acMetaWriter = TokenStreamWriter(
            header: modHeader, codebook: modCodebook)
        for packed in acMetaPacked {
            for v in packed {
                try acMetaWriter.writeToken(
                    context: 0, value: v, to: &sec)
            }
        }

        // HfGlobal.
        sec.writeBit(true)                       // DequantMatricesAC default
        // num_histograms: 1 + ReadBits(CeilLog2(numGroups=1)) ⇒ 0 bits.
        try sec.writeU32(0, distributions: kOrderEnc)   // used_orders = 0
        try acHeader.write(to: &sec, numContexts: acContexts)
        try acCodebook.write(to: &sec, header: acHeader)

        // AC group — the per-block AC token stream.
        let acWriter = TokenStreamWriter(
            header: acHeader, codebook: acCodebook)
        for tok in acTokens {
            try acWriter.writeToken(
                context: tok.context, value: tok.value, to: &sec)
        }
        sec.alignToByte()
        let section0 = sec.finishToData()

        // --- Outer codestream (headers + TOC + section) ----------
        return try writeOuterCodestream(
            xsize: q.xsize, ysize: q.ysize, section0: section0)
    }

    // MARK: - Modular residual tokenisation

    /// Gradient-predict a channel and pack each residual; updates the
    /// shared histogram. Mirrors `SpecModularEncoder.buildSingleSection`.
    static func modularResiduals(
        _ pix: [Int32], width: Int, height: Int,
        cfg: HybridUintConfig, histo: inout [Int], maxToken: inout Int
    ) -> [UInt32] {
        var packed = [UInt32]()
        packed.reserveCapacity(width * height)
        for y in 0..<height {
            for x in 0..<width {
                let nbh = Neighbourhood(at: x, y, in: pix, width: width)
                let predicted = Predictor.gradient.apply(
                    to: nbh, lo: Int32.min, hi: Int32.max)
                let residual = pix[y * width + x] &- predicted
                let p = ZigZag.pack(residual)
                let t = Int(cfg.encode(p).token)
                histo[t] += 1
                if t > maxToken { maxToken = t }
                packed.append(p)
            }
        }
        return packed
    }

    // MARK: - AC token generation

    /// Generate the per-block AC token stream — the exact inverse of
    /// `ACDecoder.decodeBlock` driven over the AC-group block grid.
    /// Each (block, channel) emits one `nzeros` token followed by
    /// coefficient tokens up to the last non-zero. Channels are
    /// visited in libjxl's storage iteration order {Y, X, B}.
    static func generateACTokens(
        q: VarDCTEncoder.Quantized, bctx: BlockCtxMap
    ) -> [(context: Int, value: UInt32)] {
        var tokens: [(context: Int, value: UInt32)] = []
        let order = naturalCoeffOrderDCT8
        let bX = q.blocksX, bY = q.blocksY
        // Per-iteration-index nnz prediction planes.
        var nzPlanes = [[Int32]](
            repeating: [Int32](repeating: 0, count: bX * bY), count: 3)
        let iterToXYB = [1, 0, 2]                 // {Y, X, B}
        for by in 0..<bY {
            for bx in 0..<bX {
                let blk = by * bX + bx
                for iterIdx in 0..<3 {
                    let c = iterToXYB[iterIdx]
                    let ac = q.acQuant[blk][c]
                    var nnz = 0
                    for k in 1..<64 where ac[order[k]] != 0 { nnz += 1 }
                    // Predicted nnz from decoded neighbours
                    // (`ACDecoder.predictNnz`).
                    let plane = nzPlanes[iterIdx]
                    let predNnz: UInt32
                    if by == 0 {
                        predNnz = UInt32(bx == 0 ? 32 : plane[blk - 1])
                    } else if bx == 0 {
                        predNnz = UInt32(plane[(by - 1) * bX + bx])
                    } else {
                        predNnz = UInt32(
                            (plane[(by - 1) * bX + bx]
                             + plane[blk - 1] + 1) >> 1)
                    }
                    let blockCtx = bctx.context(
                        dcIdx: 0, qf: UInt32(q.qf), ord: 0, c: c)
                    tokens.append((
                        bctx.nonZeroContext(
                            nonZeros: predNnz, blockCtx: blockCtx),
                        UInt32(nnz)))
                    // Coefficient tokens, scan order, until the last
                    // non-zero (the decoder stops when nzeros hits 0).
                    let histoOffset = bctx.zeroDensityContextsOffset(
                        blockCtx: blockCtx)
                    var prev = (nnz > 64 / 16) ? 0 : 1
                    var rem = nnz
                    var k = 1
                    while k < 64 && rem != 0 {
                        let ctx = histoOffset + zeroDensityContext(
                            nonzerosLeft: rem, k: k,
                            coveredBlocks: 1, log2CoveredBlocks: 0,
                            prev: prev)
                        let u = ZigZag.pack(ac[order[k]])
                        tokens.append((ctx, u))
                        prev = (u != 0) ? 1 : 0
                        if u != 0 { rem -= 1 }
                        k += 1
                    }
                    nzPlanes[iterIdx][blk] = Int32(nnz)
                }
            }
        }
        return tokens
    }

    /// Write the LfGlobal global modular tree (a single
    /// ClampedGradient leaf) + the shared post-tree codebook.
    static func writeModularTreeSection(
        to w: inout BitWriter,
        postHeader: EntropySectionHeader,
        postCodebook: MultiClusterCodebook
    ) throws {
        let treeUintCfg = HybridUintConfig(
            splitExponent: 0, msbInToken: 0, lsbInToken: 0)
        let treeAlphabet = 16
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [try PrefixCodeTable(
                lengths: Array(repeating: 4, count: treeAlphabet))],
            ansCounts: [], alphabetSizes: [treeAlphabet])
        let treeHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 6),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [treeUintCfg])
        try treeHeader.write(to: &w, numContexts: 6)
        try treeCodebook.write(to: &w, header: treeHeader)
        let tree = ModularTree(nodes: [
            ModularTreeNode(
                property: -1, splitVal: 0,
                leftChildOrLeafId: 0, rightChild: 0,
                predictor: .gradient,
                predictorOffset: 0, multiplier: 1,
                rawPredictor: 5),
        ])
        let treeWriter = TokenStreamWriter(
            header: treeHeader, codebook: treeCodebook)
        try tree.encode { ctx, val in
            try treeWriter.writeToken(context: ctx, value: val, to: &w)
        }
        try postHeader.write(to: &w, numContexts: 1)
        try postCodebook.write(to: &w, header: postHeader)
    }

    // MARK: - Outer codestream

    /// Signature + SizeHeader + ImageMetadata + CustomTransformData +
    /// VarDCT FrameHeader + single-entry TOC + the section payload.
    static func writeOuterCodestream(
        xsize: Int, ysize: Int, section0: Data
    ) throws -> Data {
        var w = BitWriter()
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)
        try SizeHeader(
            xsize: UInt32(xsize), ysize: UInt32(ysize)).write(to: &w)
        let meta = ImageMetadata(
            allDefault: false, orientation: 1,
            intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: true,
            colorEncoding: .srgb,
            intensityTarget: 255.0, minNits: 0.0,
            relativeToMaxDisplay: false, linearBelow: 0.0)
        try meta.write(to: &w)
        w.writeBit(true)              // CustomTransformData all_default
        w.alignToByte()
        let fh = FrameHeader(
            allDefault: false,
            frameType: .regular, encoding: .varDCT,
            flags: 0, colorTransform: .xyb,
            chromaSubsampling: .default,
            upsampling: 1, extraChannelUpsampling: [],
            groupSizeShift: 1,
            xQmScale: 2, bQmScale: 2,
            passes: .default, dcLevel: 0,
            customSizeOrOrigin: false,
            frameOrigin: (0, 0), frameSize: nil,
            blendingInfo: .default,
            extraChannelBlendingInfo: [],
            animationFrame: .default,
            isLast: true,
            saveAsReference: 0,
            saveBeforeColorTransform: false,
            name: "",
            loopFilter: LoopFilter(
                allDefault: false, gab: false, epfIters: 0))
        try fh.write(to: &w, context: FrameHeaderContext(
            xybEncoded: true, numExtraChannels: 0,
            haveAnimation: false, haveTimecodes: false))
        let toc = TOC(
            hasPermutation: false,
            entrySizes: [UInt32(section0.count)],
            offsets: [0, UInt64(section0.count)])
        try toc.write(to: &w)
        var out = w.finishToData()
        out.append(section0)
        return out
    }
}
