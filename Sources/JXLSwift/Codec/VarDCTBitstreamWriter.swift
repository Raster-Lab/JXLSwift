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
// Scope: frames up to one DC group (≤ 2048 px) — single-section
// when ≤ 256 px, otherwise a multi-section codestream of one AC
// group per 256-px tile. RGB and RGBA (one lossless modular alpha
// extra channel). DCT8×8 only, one pass, default colour-correlation
// / quant matrices / block-context map, `used_orders = 0`,
// `num_histograms = 1`.
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

    /// Encode an 8-bit RGB/RGBA `ImageFrame` as a VarDCT JPEG XL
    /// file (naked codestream). Frames up to the 8192-px encoder cap
    /// are supported: ≤ 256 px as a single contiguous section, larger
    /// frames as a multi-section codestream with one AC group per
    /// 256-px tile and one DC group per 2048-px tile.
    public static func encode(
        frame: ImageFrame, distance: Float = 1.0
    ) throws -> Data {
        let q = try VarDCTEncoder.forward(frame: frame, distance: distance)
        let groupDim = 256
        let sizeCap = 8192
        guard q.xsize <= sizeCap, q.ysize <= sizeCap else {
            throw WriterError.unsupported(
                "VarDCT encode: \(q.xsize)×\(q.ysize) exceeds the "
                + "\(sizeCap)-px encoder cap")
        }
        let blocksX = q.blocksX, blocksY = q.blocksY
        let blocksPerGroup = groupDim / 8        // 32
        let numGroupsX = (q.xsize + groupDim - 1) / groupDim
        let numGroupsY = (q.ysize + groupDim - 1) / groupDim
        let numGroups = numGroupsX * numGroupsY

        // --- Alpha extra channel (RGBA) --------------------------
        // A 4-channel frame's trailing channel is carried losslessly
        // as one modular alpha extra channel. Single-section frames
        // decode it whole in the LfGlobal `gi` global pass; for
        // frames spanning more than one 256-px group the channel is
        // larger than a modular group, so it defers per-AC-group
        // (the decoder's `extraGiImage` deferred path).
        let hasAlpha = frame.channels >= 4
        var alphaPix = [Int32]()
        if hasAlpha {
            let ch = frame.channels
            alphaPix = [Int32](repeating: 0, count: q.xsize * q.ysize)
            for i in 0..<(q.xsize * q.ysize) {
                alphaPix[i] = Int32(frame.data[i * ch + 3])
            }
        }

        // --- Modular DC + ACMeta sub-images, one set per DC group ---
        // A DC group covers up to 256×256 blocks (2048 px). Each
        // group's DC sub-image (3 channels {Y, X, B}) and ACMeta
        // sub-image (4 channels) decode independently, so the encoder
        // gradient-predicts each group's block sub-region on its own
        // (group-local neighbourhood, matching the decoder). Frames
        // ≤ 2048 px have a single DC group covering everything.
        // Every group's residuals share the LfGlobal global tree and
        // one pooled Huffman codebook.
        let dcBlocksPerGroup = 256             // 2048 px / 8
        let numDcGroupsX =
            (blocksX + dcBlocksPerGroup - 1) / dcBlocksPerGroup
        let numDcGroupsY =
            (blocksY + dcBlocksPerGroup - 1) / dcBlocksPerGroup
        let numDcGroups = numDcGroupsX * numDcGroupsY
        // DC channel storage order is {Y, X, B}.
        let dcStorage: [[Int32]] = [
            q.dcQuant[1], q.dcQuant[0], q.dcQuant[2],
        ]

        let postCfg = HybridUintConfig.raw4
        var modHisto = [Int](repeating: 0, count: postCfg.maxToken + 1)
        var maxModToken = 0
        var dcPackedByGroup: [[[UInt32]]] = []     // [dcG][0..2]
        var acMetaPackedByGroup: [[[UInt32]]] = []  // [dcG][0..3]
        var dcGroupBlockCount: [Int] = []           // [dcG] cell total
        var dcGroupFirstCount: [Int] = []           // [dcG] first-blocks
        for dgY in 0..<numDcGroupsY {
            for dgX in 0..<numDcGroupsX {
                let bx0 = dgX * dcBlocksPerGroup
                let by0 = dgY * dcBlocksPerGroup
                let gW = min(dcBlocksPerGroup, blocksX - bx0)
                let gH = min(dcBlocksPerGroup, blocksY - by0)
                let gBlocks = gW * gH
                dcGroupBlockCount.append(gBlocks)
                // DC channels — this group's sub-region of each
                // {Y, X, B} storage channel.
                var dcPacked: [[UInt32]] = []
                for chan in dcStorage {
                    var sub = [Int32](repeating: 0, count: gBlocks)
                    for yy in 0..<gH {
                        let srcRow = (by0 + yy) * blocksX + bx0
                        for xx in 0..<gW {
                            sub[yy * gW + xx] = chan[srcRow + xx]
                        }
                    }
                    dcPacked.append(modularResiduals(
                        sub, width: gW, height: gH,
                        cfg: postCfg, histo: &modHisto,
                        maxToken: &maxModToken))
                }
                dcPackedByGroup.append(dcPacked)
                // ACMeta: YToX, YToB (one per 64-px tile, all-zero
                // default CfL), ACS+QF, EPF sharpness (all-zero).
                let cW = max(1, (gW + 7) / 8)
                let cH = max(1, (gH + 7) / 8)
                // ACS+QF: walk the group's cells in raster order,
                // tracking covered cells; emit one (strategy, QF−1)
                // entry per transform first-block. The channel is
                // `count × 2` — `[ACS_0…, QF_0…]` (libjxl
                // `DecodeAcMetadata` / `ACStrategyImage`).
                var acsList: [Int32] = []
                var qfList: [Int32] = []
                var dgCovered = [Bool](
                    repeating: false, count: gBlocks)
                for ly in 0..<gH {
                    for lx in 0..<gW {
                        if dgCovered[ly * gW + lx] { continue }
                        let gIdx = (by0 + ly) * blocksX + (bx0 + lx)
                        let raw = q.acStrategy[gIdx]
                        acsList.append(Int32(raw))
                        qfList.append(q.qf - 1)
                        let strat = ACStrategy(rawValue: raw)
                            ?? .dct8x8
                        let cx = strat.blockCells.cellsX
                        let cy = strat.blockCells.cellsY
                        for iy in 0..<cy {
                            for ix in 0..<cx
                            where ly + iy < gH && lx + ix < gW {
                                dgCovered[(ly + iy) * gW
                                    + (lx + ix)] = true
                            }
                        }
                    }
                }
                let firstCount = acsList.count
                dcGroupFirstCount.append(firstCount)
                let acsQF = acsList + qfList
                let acMetaChannels: [(pix: [Int32], w: Int, h: Int)] = [
                    ([Int32](repeating: 0, count: cW * cH), cW, cH),
                    ([Int32](repeating: 0, count: cW * cH), cW, cH),
                    (acsQF, firstCount, 2),
                    ([Int32](repeating: 0, count: gBlocks), gW, gH),
                ]
                var acMetaPacked: [[UInt32]] = []
                for ch in acMetaChannels {
                    acMetaPacked.append(modularResiduals(
                        ch.pix, width: ch.w, height: ch.h,
                        cfg: postCfg, histo: &modHisto,
                        maxToken: &maxModToken))
                }
                acMetaPackedByGroup.append(acMetaPacked)
            }
        }
        // The alpha extra channel's residuals share the same pooled
        // post-tree codebook (decoded with the LfGlobal global tree).
        // Single-section: the whole channel, gradient-predicted once.
        // Multi-section: one gradient-predicted sub-rect per AC group
        // (the decoder decodes each group's rect independently).
        var alphaWholePacked: [UInt32] = []
        var alphaGroupPackedTmp: [[UInt32]] = []
        if hasAlpha {
            if numGroups == 1 {
                alphaWholePacked = modularResiduals(
                    alphaPix, width: q.xsize, height: q.ysize,
                    cfg: postCfg, histo: &modHisto, maxToken: &maxModToken)
            } else {
                for gy in 0..<numGroupsY {
                    for gx in 0..<numGroupsX {
                        let rx = gx * groupDim, ry = gy * groupDim
                        let rw = min(groupDim, q.xsize - rx)
                        let rh = min(groupDim, q.ysize - ry)
                        var sub = [Int32](repeating: 0, count: rw * rh)
                        for yy in 0..<rh {
                            let srcRow = (ry + yy) * q.xsize + rx
                            for xx in 0..<rw {
                                sub[yy * rw + xx] = alphaPix[srcRow + xx]
                            }
                        }
                        alphaGroupPackedTmp.append(modularResiduals(
                            sub, width: rw, height: rh,
                            cfg: postCfg, histo: &modHisto,
                            maxToken: &maxModToken))
                    }
                }
            }
        }
        // Bound as `let` so the @Sendable `writeACGroup` can capture it.
        let alphaPacked = alphaWholePacked
        let alphaPackedPerGroup = alphaGroupPackedTmp
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
        // Generate the per-AC-group token streams (nzeros +
        // coefficients) and choose between two AC entropy layouts:
        //
        //  • 1 cluster — one Huffman over every token, trivial map.
        //  • 2 clusters — a context map routes `nzeros` tokens to
        //    cluster 0 and coefficient tokens to cluster 1. Their
        //    value distributions differ sharply (small non-zero
        //    counts vs zig-zag-packed signed coefficients), so a
        //    per-cluster codebook fits each far better.
        //
        // The 2-cluster split needs an explicit context map costing
        // ~`acContexts` bits in the simple per-entry form, so it only
        // pays on frames whose token-stream saving beats that. The
        // encoder estimates both and keeps the smaller — clustering
        // is a pure lossless recode, so this never changes the
        // decoded pixels, only the file size.
        let bctx = BlockCtxMap()
        let acContexts = bctx.numACContexts
        let acCfg = HybridUintConfig.raw4
        let (acTokensPerGroup, nnzContexts) = generateACTokens(
            q: q, bctx: bctx,
            numGroupsX: numGroupsX, numGroupsY: numGroupsY,
            blocksPerGroup: blocksPerGroup)
        // Build Huffman lengths + the token-bit cost for a histogram.
        func acHuff(_ histo: [Int], _ maxTok: Int)
            -> (lengths: [UInt8], alphabet: Int, bits: Int) {
            // Keep the alphabet ≥ 2 — the canonical builder is
            // undefined for a single symbol.
            var alphabet = maxTok + 1
            var counts = Array(histo[0..<alphabet])
            if alphabet < 2 { alphabet = 2; counts.append(1) }
            let lengths = lengthLimitedCanonicalHuffman(
                counts: counts, maxLength: 15, alphabetSize: alphabet)
            var bits = 0
            for t in 0..<alphabet { bits += counts[t] * Int(lengths[t]) }
            return (lengths, alphabet, bits)
        }
        // Cluster 0 = nzeros contexts, cluster 1 = coefficient
        // contexts (the default for any context with no nzeros token).
        var clusterMap = [UInt8](repeating: 1, count: acContexts)
        for ctx in nnzContexts where ctx >= 0 && ctx < acContexts {
            clusterMap[ctx] = 0
        }
        var acHisto1 = [Int](repeating: 0, count: acCfg.maxToken + 1)
        var maxTok1 = 0
        var clHisto = [[Int]](repeating:
            [Int](repeating: 0, count: acCfg.maxToken + 1), count: 2)
        var clMax = [0, 0]
        for grp in acTokensPerGroup {
            for tok in grp {
                let t = Int(acCfg.encode(tok.value).token)
                acHisto1[t] += 1
                if t > maxTok1 { maxTok1 = t }
                let cl = Int(clusterMap[tok.context])
                clHisto[cl][t] += 1
                if t > clMax[cl] { clMax[cl] = t }
            }
        }
        let h1 = acHuff(acHisto1, maxTok1)
        let h2a = acHuff(clHisto[0], clMax[0])
        let h2b = acHuff(clHisto[1], clMax[1])
        // Use 2 clusters only when the token-bit saving clears the
        // context-map cost (`acContexts` bits) plus a 1024-bit slack
        // covering the extra per-cluster codebook header — so the
        // 2-cluster path is chosen strictly when it shrinks the file.
        let useTwoClusters =
            (h1.bits - h2a.bits - h2b.bits) > acContexts + 1024
        if ProcessInfo.processInfo.environment["JXL_TRACE"] != nil {
            FileHandle.standardError.write(Data(
                ("TRACE AC clustering: 1-cluster=\(h1.bits)b "
                 + "2-cluster=\(h2a.bits + h2b.bits)b "
                 + "mapCost≈\(acContexts)b → "
                 + "\(useTwoClusters ? "2 clusters" : "1 cluster")\n")
                .utf8))
        }
        let acCodebook: MultiClusterCodebook
        let acHeader: EntropySectionHeader
        if useTwoClusters {
            acCodebook = MultiClusterCodebook(
                huffmanTables: [
                    try PrefixCodeTable(lengths: h2a.lengths),
                    try PrefixCodeTable(lengths: h2b.lengths),
                ],
                ansCounts: [],
                alphabetSizes: [h2a.alphabet, h2b.alphabet])
            acHeader = EntropySectionHeader(
                lz77: .disabled,
                contextMap: try ContextMap(
                    numClusters: 2, useMTF: false, map: clusterMap),
                usePrefixCode: true, logAlphaSize: 15,
                uintConfigs: [acCfg, acCfg])
        } else {
            acCodebook = MultiClusterCodebook(
                huffmanTables: [try PrefixCodeTable(lengths: h1.lengths)],
                ansCounts: [], alphabetSizes: [h1.alphabet])
            acHeader = EntropySectionHeader(
                lz77: .disabled,
                contextMap: ContextMap.trivial(numContexts: acContexts),
                usePrefixCode: true, logAlphaSize: 15,
                uintConfigs: [acCfg])
        }

        // --- Section payloads ------------------------------------
        // Closures that append each logical sub-section to a writer
        // — shared by the single-section and multi-section paths.
        let writeLfGlobal: (inout BitWriter) throws -> Void = { w in
            w.writeBit(true)               // DequantMatricesDC default
            try QuantizerParams(
                globalScale: q.globalScale, quantDC: q.quantDC
            ).write(to: &w)
            w.writeBit(true)               // BlockCtxMap default
            w.writeBit(true)               // ColorCorrelation DC default
            w.writeBit(true)               // has_tree
            try writeModularTreeSection(
                to: &w, postHeader: modHeader, postCodebook: modCodebook)
            // gi modular sub-image: the alpha extra channel for RGBA
            // frames. Plain RGB has 0 modular channels here, so the
            // decoder's `ModularDecode` early-returns and nothing is
            // written. For RGBA the gi GroupHeader is always emitted;
            // a single-section frame then carries the whole alpha
            // channel here (gradient-predicted residual tokens — the
            // inverse of the decoder's gi global pass), while a
            // multi-section frame writes only the GroupHeader (the
            // channel exceeds one group and defers per-AC-group).
            if hasAlpha {
                try GroupHeader.default.write(to: &w)
                if numGroups == 1 {
                    let giWriter = TokenStreamWriter(
                        header: modHeader, codebook: modCodebook)
                    for v in alphaPacked {
                        try giWriter.writeToken(
                            context: 0, value: v, to: &w)
                    }
                }
            }
        }
        func writeDCGroup(_ w: inout BitWriter, _ dcG: Int) throws {
            w.write(bits: 2, value: 0)     // dc_extra_precision = 0
            try GroupHeader.default.write(to: &w)
            let dcWriter = TokenStreamWriter(
                header: modHeader, codebook: modCodebook)
            for packed in dcPackedByGroup[dcG] {
                for v in packed {
                    try dcWriter.writeToken(context: 0, value: v, to: &w)
                }
            }
            // ACMetadata `count` (number of transform first-blocks)
            // — CeilLog2(group cell count) bits, read back as
            // `count - 1`. The bit width is sized by the cell total;
            // the value is the (smaller) first-block count.
            let gBlocks = dcGroupBlockCount[dcG]
            let firstCount = dcGroupFirstCount[dcG]
            let acMetaBits = Int(ceilLog2(UInt32(max(1, gBlocks))))
            if acMetaBits > 0 {
                w.write(bits: acMetaBits,
                        value: UInt32(max(0, firstCount - 1)))
            }
            try GroupHeader.default.write(to: &w)
            let acMetaWriter = TokenStreamWriter(
                header: modHeader, codebook: modCodebook)
            for packed in acMetaPackedByGroup[dcG] {
                for v in packed {
                    try acMetaWriter.writeToken(
                        context: 0, value: v, to: &w)
                }
            }
        }
        let writeHfGlobal: (inout BitWriter) throws -> Void = { w in
            w.writeBit(true)               // DequantMatricesAC default
            // num_histograms = 1 ⇒ raw 0 in CeilLog2(numGroups) bits.
            let nhBits = Int(ceilLog2(UInt32(max(1, numGroups))))
            if nhBits > 0 { w.write(bits: nhBits, value: 0) }
            try w.writeU32(0, distributions: kOrderEnc)  // used_orders
            try acHeader.write(to: &w, numContexts: acContexts)
            try acCodebook.write(to: &w, header: acHeader)
        }
        @Sendable func writeACGroup(
            _ w: inout BitWriter, _ group: Int
        ) throws {
            let acWriter = TokenStreamWriter(
                header: acHeader, codebook: acCodebook)
            for tok in acTokensPerGroup[group] {
                try acWriter.writeToken(
                    context: tok.context, value: tok.value, to: &w)
            }
            // Deferred alpha extra channel (multi-section RGBA): the
            // VarDCT AC tokens are followed by a default modular
            // GroupHeader then this group's gradient-predicted alpha
            // sub-rect — the inverse of the decoder's per-AC-group
            // `extraGiImage` decode.
            if hasAlpha && numGroups > 1 {
                try GroupHeader.default.write(to: &w)
                let giWriter = TokenStreamWriter(
                    header: modHeader, codebook: modCodebook)
                for v in alphaPackedPerGroup[group] {
                    try giWriter.writeToken(context: 0, value: v, to: &w)
                }
            }
        }

        // --- Assemble sections -----------------------------------
        var sections: [Data] = []
        if numGroups == 1 {
            // Single-section: LfGlobal + DC group + HfGlobal + the
            // one AC group, all contiguous in section 0 (≤ 256 px, so
            // exactly one DC group).
            var sec = BitWriter()
            try writeLfGlobal(&sec)
            try writeDCGroup(&sec, 0)
            try writeHfGlobal(&sec)
            try writeACGroup(&sec, 0)
            sec.alignToByte()
            sections = [sec.finishToData()]
        } else {
            // Multi-section TOC layout (libjxl `NumTocEntries`):
            // [LfGlobal, DC×numDcGroups, HfGlobal, AC×numGroups].
            var lf = BitWriter(); try writeLfGlobal(&lf)
            lf.alignToByte(); sections.append(lf.finishToData())
            for dcG in 0..<numDcGroups {
                var dcg = BitWriter(); try writeDCGroup(&dcg, dcG)
                dcg.alignToByte(); sections.append(dcg.finishToData())
            }
            var hf = BitWriter(); try writeHfGlobal(&hf)
            hf.alignToByte(); sections.append(hf.finishToData())
            for g in 0..<numGroups {
                var ag = BitWriter()
                try writeACGroup(&ag, g)
                ag.alignToByte()
                sections.append(ag.finishToData())
            }
        }

        // --- Outer codestream (headers + TOC + sections) ---------
        return try writeOuterCodestream(
            xsize: q.xsize, ysize: q.ysize,
            hasAlpha: hasAlpha, sections: sections)
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

    /// Generate the AC token stream **per AC group** — the exact
    /// inverse of `ACDecoder.decodeBlock` driven over each group's
    /// block sub-grid. Each (block, channel) emits one `nzeros`
    /// token then coefficient tokens up to the last non-zero;
    /// channels are visited in libjxl's storage order {Y, X, B}.
    /// nnz prediction planes are per-group (libjxl resets them at
    /// each AC group boundary). Also returns the set of context
    /// indices used by `nzeros` tokens — the caller routes those to
    /// a separate Huffman cluster from the coefficient tokens.
    static func generateACTokens(
        q: VarDCTEncoder.Quantized, bctx: BlockCtxMap,
        numGroupsX: Int, numGroupsY: Int, blocksPerGroup bpg: Int
    ) -> (perGroup: [[(context: Int, value: UInt32)]],
          nnzContexts: Set<Int>) {
        let orderDCT8 = naturalCoeffOrderDCT8
        let orderDCT16 = CoeffOrders.naturalCoeffOrder(for: .dct16x16)
        let orderDCT32 = CoeffOrders.naturalCoeffOrder(for: .dct32x32)
        let orderDCT8x16 = CoeffOrders.naturalCoeffOrder(for: .dct8x16)
        let bX = q.blocksX, bY = q.blocksY
        let iterToXYB = [1, 0, 2]                 // {Y, X, B}
        var result: [[(context: Int, value: UInt32)]] = []
        var nnzContexts = Set<Int>()
        for gy in 0..<numGroupsY {
            for gx in 0..<numGroupsX {
                let bx0 = gx * bpg, by0 = gy * bpg
                let gW = min(bpg, bX - bx0)
                let gH = min(bpg, bY - by0)
                // Per-group, per-channel nnz prediction planes, and a
                // covered-cell mask so a multi-block transform's
                // covered cells emit no tokens of their own.
                var nzPlanes = [[Int32]](
                    repeating: [Int32](repeating: 0, count: gW * gH),
                    count: 3)
                var covered = [Bool](repeating: false, count: gW * gH)
                var tokens: [(context: Int, value: UInt32)] = []
                for ly in 0..<gH {
                    for lx in 0..<gW {
                        if covered[ly * gW + lx] { continue }
                        let blk = (by0 + ly) * bX + (bx0 + lx)
                        let strat = ACStrategy(
                            rawValue: q.acStrategy[blk]) ?? .dct8x8
                        let coveredBlocks = strat.coveredBlocks
                        let log2Covered = strat.log2CoveredBlocks
                        let order: [Int]
                        switch strat {
                        case .dct16x16:           order = orderDCT16
                        case .dct32x32:           order = orderDCT32
                        case .dct16x8, .dct8x16:  order = orderDCT8x16
                        default:                  order = orderDCT8
                        }
                        let ordBucket = strat.orderBucket
                        let cellsX = strat.blockCells.cellsX
                        let cellsY = strat.blockCells.cellsY
                        for iterIdx in 0..<3 {
                            let c = iterToXYB[iterIdx]
                            let ac = q.acQuant[blk][c]
                            // Predicted nnz from group-local
                            // neighbours (`ACDecoder.predictNnz`).
                            let plane = nzPlanes[iterIdx]
                            let predNnz: UInt32
                            if ly == 0 {
                                predNnz = UInt32(
                                    lx == 0 ? 32 : plane[lx - 1])
                            } else if lx == 0 {
                                predNnz = UInt32(plane[(ly - 1) * gW])
                            } else {
                                predNnz = UInt32(
                                    (plane[(ly - 1) * gW + lx]
                                     + plane[ly * gW + lx - 1] + 1) >> 1)
                            }
                            let blockCtx = bctx.context(
                                dcIdx: 0, qf: UInt32(q.qf),
                                ord: ordBucket, c: c)
                            // One transform's AC tokens —
                            // `ACEncoder.tokenize` is the shared,
                            // spec-verified inverse of
                            // `ACDecoder.decodeBlock`, generic over
                            // `coveredBlocks` (1 = DCT8, 4 = DCT16).
                            let (blockTokens, nnz) = ACEncoder.tokenize(
                                block: ac, order: order,
                                coveredBlocks: coveredBlocks,
                                log2CoveredBlocks: log2Covered,
                                blockCtx: blockCtx,
                                predictedNnz: predNnz,
                                ctxOffset: 0, ctxMap: bctx, shift: 0)
                            if let first = blockTokens.first {
                                nnzContexts.insert(first.context)
                            }
                            tokens.append(contentsOf: blockTokens)
                            // Stamp ⌈nnz / coveredBlocks⌉ over every
                            // covered cell so later first-blocks see
                            // consistent neighbours (libjxl
                            // `dec_group.cc` post-decode stamp).
                            let nzPerCell = Int32(
                                (nnz + coveredBlocks - 1)
                                    / coveredBlocks)
                            for cy in 0..<cellsY {
                                for cx in 0..<cellsX {
                                    nzPlanes[iterIdx][
                                        (ly + cy) * gW + (lx + cx)]
                                        = nzPerCell
                                }
                            }
                        }
                        for cy in 0..<cellsY {
                            for cx in 0..<cellsX {
                                covered[(ly + cy) * gW + (lx + cx)]
                                    = true
                            }
                        }
                    }
                }
                result.append(tokens)
            }
        }
        return (result, nnzContexts)
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
    /// VarDCT FrameHeader + TOC (one entry per section) + the
    /// concatenated section payloads. `hasAlpha` declares a single
    /// 8-bit alpha extra channel (RGBA frames).
    static func writeOuterCodestream(
        xsize: Int, ysize: Int, hasAlpha: Bool, sections: [Data]
    ) throws -> Data {
        var w = BitWriter()
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)
        try SizeHeader(
            xsize: UInt32(xsize), ysize: UInt32(ysize)).write(to: &w)
        // One default 8-bit alpha extra channel when the frame is RGBA.
        let extraChannels: [ExtraChannelInfo] = hasAlpha
            ? [ExtraChannelInfo(
                type: .alpha,
                bitDepth: BitDepth(floatingPoint: false, bitsPerSample: 8),
                dimShift: 0, name: "")]
            : []
        let meta = ImageMetadata(
            allDefault: false, orientation: 1,
            intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: extraChannels,
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
            xybEncoded: true, numExtraChannels: hasAlpha ? 1 : 0,
            haveAnimation: false, haveTimecodes: false))
        var entrySizes = [UInt32]()
        var offsets: [UInt64] = [0]
        var cumulative: UInt64 = 0
        for s in sections {
            entrySizes.append(UInt32(s.count))
            cumulative &+= UInt64(s.count)
            offsets.append(cumulative)
        }
        let toc = TOC(
            hasPermutation: false,
            entrySizes: entrySizes, offsets: offsets)
        try toc.write(to: &w)
        var out = w.finishToData()
        for s in sections { out.append(s) }
        return out
    }
}
