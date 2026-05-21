// VarDCTBitstreamWriter — serialises a `VarDCTEncoder.Quantized`
// into a complete JPEG XL VarDCT codestream.
//
// This is the inverse of `JXLDecoder.decodeVarDCTPartial`, written
// section-for-section against that decoder's read sequence.
//
// **First cut — DC-only.** Every block's AC coefficients are emitted
// as `nzeros = 0`: any image therefore encodes to a valid (blocky,
// DC-only) lossy frame that round-trips through the decoder. Real AC
// coefficient tokens (the `ZeroDensityContext` coefficient stream)
// are the next increment.
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
        // DC-only ⇒ every AC token is value 0 (`nzeros = 0`).
        let bctx = BlockCtxMap()
        let acContexts = bctx.numACContexts
        let acCfg = HybridUintConfig.raw4
        // DC-only emits only token 0; symbol 1 is a never-written
        // phantom that keeps the Huffman alphabet ≥ 2 (the canonical
        // Huffman builder is undefined for a 1-symbol alphabet).
        let acAlphabet = 2
        let acLengths = lengthLimitedCanonicalHuffman(
            counts: [nBlocks * 3, 1], maxLength: 15, alphabetSize: 2)
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

        // AC group — `nzeros = 0` per (block, channel).
        let acWriter = TokenStreamWriter(
            header: acHeader, codebook: acCodebook)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let predNnz: UInt32 =
                    (bx == 0 && by == 0) ? 32 : 0
                // libjxl storage iteration order {Y, X, B}.
                for storageC in [1, 0, 2] {
                    let blockCtx = bctx.context(
                        dcIdx: 0, qf: UInt32(q.qf), ord: 0, c: storageC)
                    let nzCtx = bctx.nonZeroContext(
                        nonZeros: predNnz, blockCtx: blockCtx)
                    try acWriter.writeToken(
                        context: nzCtx, value: 0, to: &sec)
                }
            }
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
