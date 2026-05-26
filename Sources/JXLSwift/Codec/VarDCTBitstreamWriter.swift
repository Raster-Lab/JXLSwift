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

    /// Intermediate output of a single-frame encode — the TOC
    /// sections plus the per-frame parameters the outer codestream
    /// writer needs. Used internally to share section-building
    /// between the single-frame `encode(_:)` and the multi-frame
    /// `encodeAnimation(frames:)` API.
    struct EncodedFrameSections {
        let sections: [Data]
        let xsize: Int
        let ysize: Int
        let hasAlpha: Bool
        let gaborish: Bool
    }

    /// Encode an 8-bit RGB/RGBA `ImageFrame` as a VarDCT JPEG XL
    /// file (naked codestream). Frames up to the 8192-px encoder cap
    /// are supported: ≤ 256 px as a single contiguous section, larger
    /// frames as a multi-section codestream with one AC group per
    /// 256-px tile and one DC group per 2048-px tile.
    public static func encode(
        frame: ImageFrame, distance: Float = 1.0,
        gaborish: Bool = true, adaptiveQF: Bool = true
    ) throws -> Data {
        let chunk = try buildFrameSections(
            frame: frame, distance: distance,
            gaborish: gaborish, adaptiveQF: adaptiveQF)
        return try writeOuterCodestream(
            xsize: chunk.xsize, ysize: chunk.ysize,
            hasAlpha: chunk.hasAlpha, gaborish: chunk.gaborish,
            sections: chunk.sections)
    }

    /// Run the encoder pipeline for one frame, returning the TOC
    /// section payloads + per-frame parameters. Caller is
    /// responsible for wrapping the result in an outer codestream
    /// (`writeOuterCodestream` for single-frame, the multi-frame
    /// path for animation).
    static func buildFrameSections(
        frame: ImageFrame, distance: Float = 1.0,
        gaborish: Bool = true, adaptiveQF: Bool = true
    ) throws -> EncodedFrameSections {
        let q = try VarDCTEncoder.forward(
            frame: frame, distance: distance,
            gaborish: gaborish, adaptiveQF: adaptiveQF)
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
                        // Per-block QF carried in ACMetadata. The
                        // decoder dequantises with `1/blockQF`, so
                        // the on-wire value is `qfPerBlock − 1`.
                        qfList.append(q.qfPerBlock[gIdx] - 1)
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
        let (acTokensPerGroup, nnzContexts, bigBlockCoefContexts) =
            generateACTokens(
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
        // Cluster 0 = nzeros contexts. For 2-cluster: cluster 1 =
        // coefficient contexts. For 3-cluster: cluster 1 = small-
        // block coefficient contexts, cluster 2 = big-block (ord ≥
        // 2 — DCT16+) coefficient contexts.
        var cluster2Map = [UInt8](repeating: 1, count: acContexts)
        for ctx in nnzContexts where ctx >= 0 && ctx < acContexts {
            cluster2Map[ctx] = 0
        }
        var cluster3Map = cluster2Map
        for ctx in bigBlockCoefContexts
        where ctx >= 0 && ctx < acContexts && cluster3Map[ctx] == 1 {
            cluster3Map[ctx] = 2
        }
        var acHisto1 = [Int](repeating: 0, count: acCfg.maxToken + 1)
        var maxTok1 = 0
        var cl2Histo = [[Int]](repeating:
            [Int](repeating: 0, count: acCfg.maxToken + 1), count: 2)
        var cl2Max = [0, 0]
        var cl3Histo = [[Int]](repeating:
            [Int](repeating: 0, count: acCfg.maxToken + 1), count: 3)
        var cl3Max = [0, 0, 0]
        for grp in acTokensPerGroup {
            for tok in grp {
                let t = Int(acCfg.encode(tok.value).token)
                acHisto1[t] += 1
                if t > maxTok1 { maxTok1 = t }
                let cl2 = Int(cluster2Map[tok.context])
                cl2Histo[cl2][t] += 1
                if t > cl2Max[cl2] { cl2Max[cl2] = t }
                let cl3 = Int(cluster3Map[tok.context])
                cl3Histo[cl3][t] += 1
                if t > cl3Max[cl3] { cl3Max[cl3] = t }
            }
        }
        let h1 = acHuff(acHisto1, maxTok1)
        let h2a = acHuff(cl2Histo[0], cl2Max[0])
        let h2b = acHuff(cl2Histo[1], cl2Max[1])
        let h3a = acHuff(cl3Histo[0], cl3Max[0])
        let h3b = acHuff(cl3Histo[1], cl3Max[1])
        let h3c = acHuff(cl3Histo[2], cl3Max[2])
        // Per-cluster codebook header slack: ≈ 512 bits per extra
        // cluster (canonical-Huffman lengths-of-lengths preamble +
        // RLE-packed cll stream). Context map is `acContexts` bits
        // simple-per-entry. Clustering is lossless — file size only.
        let twoBits = h2a.bits + h2b.bits + acContexts + 1024
        let threeBits =
            h3a.bits + h3b.bits + h3c.bits + acContexts + 1536
        let oneBits = h1.bits
        // Pick the cheapest of 1 / 2 / 3 clusters. Tie-breaker
        // prefers fewer clusters (smaller codebook overhead).
        let useThreeClusters =
            threeBits < twoBits && threeBits < oneBits
            && bigBlockCoefContexts.count > 0
        let useTwoClusters = !useThreeClusters
            && twoBits < oneBits
        if ProcessInfo.processInfo.environment["JXL_TRACE"] != nil {
            FileHandle.standardError.write(Data(
                ("TRACE AC clustering: 1-cluster=\(h1.bits)b "
                 + "2-cluster=\(h2a.bits + h2b.bits)b "
                 + "3-cluster=\(h3a.bits + h3b.bits + h3c.bits)b "
                 + "mapCost≈\(acContexts)b → "
                 + "\(useThreeClusters ? "3 clusters" : (useTwoClusters ? "2 clusters" : "1 cluster"))\n")
                .utf8))
        }
        let acCodebook: MultiClusterCodebook
        let acHeader: EntropySectionHeader
        if useThreeClusters {
            acCodebook = MultiClusterCodebook(
                huffmanTables: [
                    try PrefixCodeTable(lengths: h3a.lengths),
                    try PrefixCodeTable(lengths: h3b.lengths),
                    try PrefixCodeTable(lengths: h3c.lengths),
                ],
                ansCounts: [],
                alphabetSizes: [
                    h3a.alphabet, h3b.alphabet, h3c.alphabet])
            acHeader = EntropySectionHeader(
                lz77: .disabled,
                contextMap: try ContextMap(
                    numClusters: 3, useMTF: false, map: cluster3Map),
                usePrefixCode: true, logAlphaSize: 15,
                uintConfigs: [acCfg, acCfg, acCfg])
        } else if useTwoClusters {
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
                    numClusters: 2, useMTF: false, map: cluster2Map),
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

        return EncodedFrameSections(
            sections: sections, xsize: q.xsize, ysize: q.ysize,
            hasAlpha: hasAlpha, gaborish: q.gaborish)
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
          nnzContexts: Set<Int>,
          bigBlockCoefContexts: Set<Int>) {
        let orderDCT8 = naturalCoeffOrderDCT8
        let orderDCT16 = CoeffOrders.naturalCoeffOrder(for: .dct16x16)
        let orderDCT32 = CoeffOrders.naturalCoeffOrder(for: .dct32x32)
        let orderDCT8x16 = CoeffOrders.naturalCoeffOrder(for: .dct8x16)
        let orderDCT16x32 = CoeffOrders.naturalCoeffOrder(for: .dct16x32)
        let orderDCT64 = CoeffOrders.naturalCoeffOrder(for: .dct64x64)
        let orderDCT32x64 = CoeffOrders.naturalCoeffOrder(for: .dct32x64)
        let bX = q.blocksX, bY = q.blocksY
        let iterToXYB = [1, 0, 2]                 // {Y, X, B}
        var result: [[(context: Int, value: UInt32)]] = []
        var nnzContexts = Set<Int>()
        var bigBlockCoefContexts = Set<Int>()
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
                        case .dct16x16:            order = orderDCT16
                        case .dct32x32:            order = orderDCT32
                        case .dct64x64:            order = orderDCT64
                        case .dct16x8, .dct8x16:   order = orderDCT8x16
                        case .dct32x16, .dct16x32: order = orderDCT16x32
                        case .dct64x32, .dct32x64: order = orderDCT32x64
                        default:                   order = orderDCT8
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
                            // Use the first-block's per-block QF
                            // (matches what the decoder reads from
                            // ACMetadata for the block context).
                            let blockCtx = bctx.context(
                                dcIdx: 0,
                                qf: UInt32(q.qfPerBlock[blk]),
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
                            // Tag coefficient-token contexts for the
                            // optional 3-cluster split — big-block
                            // (DCT16+) coefficient tokens often have
                            // a different distribution to small-block
                            // ones, and a separate codebook can pack
                            // them tighter on textured content.
                            if ordBucket >= 2 && blockTokens.count > 1 {
                                for t in blockTokens.dropFirst() {
                                    bigBlockCoefContexts.insert(
                                        t.context)
                                }
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
        return (result, nnzContexts, bigBlockCoefContexts)
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

    /// Write the shared image-level prelude — Signature, SizeHeader,
    /// ImageMetadata, CustomTransformData. Identical for single-
    /// frame and multi-frame codestreams except for the metadata's
    /// `animation` block (`nil` for single-frame, a libjxl-default
    /// 100 tps `AnimationHeader` for multi-frame).
    static func writeCodestreamPrelude(
        xsize: Int, ysize: Int, hasAlpha: Bool,
        animation: AnimationHeader?
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
            intrinsicSize: nil, preview: nil, animation: animation,
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
        return w.finishToData()
    }

    /// Write one frame chunk — FrameHeader + TOC + section payloads.
    /// Used for both single-frame and per-frame multi-frame writes.
    /// `isLast = true` flags the last (or only) frame; `isLast = false`
    /// signals the decoder to expect another FrameHeader after this
    /// chunk's payloads.
    static func writeFrameChunk(
        hasAlpha: Bool, gaborish: Bool, isLast: Bool,
        animationFrame: AnimationFrame, haveAnimation: Bool,
        sections: [Data]
    ) throws -> Data {
        var w = BitWriter()
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
            animationFrame: animationFrame,
            isLast: isLast,
            saveAsReference: 0,
            saveBeforeColorTransform: false,
            name: "",
            loopFilter: LoopFilter(
                allDefault: false, gab: gaborish, epfIters: 0))
        try fh.write(to: &w, context: FrameHeaderContext(
            xybEncoded: true, numExtraChannels: hasAlpha ? 1 : 0,
            haveAnimation: haveAnimation, haveTimecodes: false))
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

    /// Signature + SizeHeader + ImageMetadata + CustomTransformData +
    /// VarDCT FrameHeader + TOC (one entry per section) + the
    /// concatenated section payloads. `hasAlpha` declares a single
    /// 8-bit alpha extra channel (RGBA frames).
    static func writeOuterCodestream(
        xsize: Int, ysize: Int, hasAlpha: Bool,
        gaborish: Bool, sections: [Data]
    ) throws -> Data {
        var out = try writeCodestreamPrelude(
            xsize: xsize, ysize: ysize,
            hasAlpha: hasAlpha, animation: nil)
        out.append(try writeFrameChunk(
            hasAlpha: hasAlpha, gaborish: gaborish, isLast: true,
            animationFrame: .default, haveAnimation: false,
            sections: sections))
        return out
    }

    /// **JPEG → JXL coefficient bridge — outer codestream prelude
    /// scaffold (v0.12.0v — step 3.6 dep 2 frame, partial).**
    ///
    /// Emits the bytes up to and including the FrameHeader for a
    /// `JXLBridgeEncoderState`. **No TOC, no section payloads** —
    /// the section-write half is the next bite. Output is enough
    /// for `JXLDecoder.inspect(_:)` to extract dimensions +
    /// metadata (it stops after `ImageMetadata`), which is the
    /// scaffold's verification path today.
    ///
    /// Differs from `writeCodestreamPrelude(xsize:…)` (the
    /// pixel-pipeline prelude) in several places:
    ///   - `xybEncoded = false` (bridge stores raw colour, not XYB)
    ///   - `colorEncoding = .grayscaleD65` for 1-component;
    ///     `.srgb` for 3-component
    ///   - `extraChannels = []` (alpha not currently supported by
    ///     the bridge; matches `JPEGDecoder.decode`'s envelope)
    ///   - `customTransformData` still all_default = true (the
    ///     non-XYB branch)
    /// And in the FrameHeader, from `state.frameHeaderParams`:
    ///   - `colorTransform = .yCbCr` or `.none` per the choice
    ///   - `chromaSubsampling = (0, 0, 0)` for 4:4:4 (lifted
    ///     when the adapter widens scope)
    ///   - `loopFilter` = bridge's `gab=false, epfIters=0`
    ///   - `xQmScale / bQmScale` only emitted with XYB, so the
    ///     defaults are fine here (the writer skips them
    ///     correctly when `colorTransform != .xyb`)
    /// Write the bridge frame's LfGlobal section body. Composes:
    ///
    ///   1. `DequantMatricesDC` — custom per-channel scales from
    ///      `state.rawQuantPayload.dcQuantization` (v0.12.0x).
    ///   2. `QuantizerParams` — placeholder `(globalScale=1,
    ///      quantDC=16)` matching libjxl's "InvGlobalScale = 1"
    ///      setup for transcoded frames (libjxl `enc_frame.cc:804`).
    ///   3. `BlockCtxMap` all_default (1 bit).
    ///   4. `ColorCorrelation` DC default (1 bit).
    ///   5. `has_tree = true` + `writeModularTreeSection` — default
    ///      single-leaf Gradient tree + minimal post-tree codebook.
    ///   6. No gi modular sub-image (bridge doesn't support alpha
    ///      yet; matches `JPEGDecoder.decode`'s envelope).
    ///
    /// **Status (v0.12.0y).** Structurally complete LfGlobal body.
    /// The bridge's DC/AC group + HfGlobal section writers are
    /// the next step; this section alone isn't yet a complete
    /// JXL frame (would need the rest of the sections + TOC).
    /// Verifiable today by feeding the prelude (v0.12.0v) + this
    /// LfGlobal payload as a partial section into `JXLDecoder.inspect`
    /// (still only reads up to ImageMetadata).
    static func writeBridgeLfGlobal(
        state: JXLBridgeEncoderState,
        to w: inout BitWriter
    ) throws {
        // 1. DequantMatricesDC — custom values per JXL channel.
        let dc = DequantMatricesDC(
            jpegBridgeScales: state.rawQuantPayload.dcQuantization)
        dc.write(to: &w)
        // 2. QuantizerParams — bridge defaults.
        try QuantizerParams(
            globalScale: 1, quantDC: 16).write(to: &w)
        // 3. BlockCtxMap all_default.
        w.writeBit(true)
        // 4. ColorCorrelation DC all_default.
        w.writeBit(true)
        // 5. has_tree = true + tree section + post-tree codebook.
        w.writeBit(true)
        // Minimal post-tree codebook: single-context 1-symbol
        // alphabet. Suitable when no gi modular data follows
        // (the bridge case). Subsequent sections will reuse this
        // codebook for their token streams; with a 1-symbol
        // alphabet emitted as a 0-bit prefix code, the codebook
        // size is small and any token written is 0 bits.
        let leafLengths: [UInt8] = [0]
        let leafTable = try PrefixCodeTable(lengths: leafLengths)
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [leafTable], ansCounts: [],
            alphabetSizes: [1])
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [HybridUintConfig.defaultConfig])
        try writeModularTreeSection(
            to: &w, postHeader: postHeader,
            postCodebook: postCodebook)
        // 6. No gi modular sub-image (bridge frames have no alpha).
    }

    /// Write the bridge frame's DC group section body. Mirrors
    /// the existing `writeDCGroup` inside `buildFrameSections`
    /// but consumes `state.planes.dcPerChannel` directly rather
    /// than `q.dcQuant` from `VarDCTEncoder.forward`.
    ///
    /// Section layout (libjxl `dec_modular.cc::DecodeDCGroup`):
    ///
    ///   1. `dc_extra_precision` (2 bits, value 0)
    ///   2. DC modular sub-image (3 channels):
    ///      - `GroupHeader.default` (useGlobalTree = true,
    ///        reuses the frame's LfGlobal tree)
    ///      - Per-channel gradient-predicted residual tokens
    ///        through the supplied post-tree codebook.
    ///   3. ACMetadata count (`CeilLog2(blockCount)` bits,
    ///      stored as `count - 1`).
    ///   4. ACMetadata modular sub-image (4 channels: per-block
    ///      QF, EPF sharpness, AC-strategy first-block delta,
    ///      AC-strategy code).
    ///      - `GroupHeader.default`
    ///      - For the bridge: every block uses DCT8×8 strategy
    ///        and uniform QF=1, so all ACMetadata residuals are
    ///        zero after gradient prediction → 0 bits per token
    ///        with the right codebook.
    ///
    /// **Status (v0.12.0z).** Structurally complete DC group
    /// body. The post-tree codebook (passed in as
    /// `postHeader` / `postCodebook`) must be one that can
    /// represent the DC residual + ACMetadata token alphabets;
    /// the LfGlobal section emits this codebook today as a
    /// 1-symbol-on-zero placeholder (v0.12.0y) — sufficient for
    /// the bridge's all-uniform ACMetadata case but **not** for
    /// arbitrary DC residuals. The "compute observed-residual
    /// histogram + build matching codebook" pass for LfGlobal is
    /// the next bite; until then, `writeBridgeDCGroup` will only
    /// produce decodable output for fixtures whose DC residuals
    /// happen to all be zero (e.g. constant-DC images).
    static func writeBridgeDCGroup(
        state: JXLBridgeEncoderState,
        postHeader: EntropySectionHeader,
        postCodebook: MultiClusterCodebook,
        to w: inout BitWriter
    ) throws {
        // 1. dc_extra_precision = 0 (2 bits).
        w.write(bits: 2, value: 0)
        // 2. DC modular sub-image: GroupHeader + per-channel
        //    gradient-predicted residual tokens.
        try GroupHeader.default.write(to: &w)
        let dcWriter = TokenStreamWriter(
            header: postHeader, codebook: postCodebook)
        let blocksX = state.planes.blocksX
        let blocksY = state.planes.blocksY
        let predictor: Predictor = .gradient
        // 8-bit precision; DC plane values are small JPEG DC
        // integers (typically ±100 after the DCzero adjustment).
        let sampleHi: Int32 = 127
        for ch in 0..<state.planes.channelCount {
            let plane = state.planes.dcPerChannel[ch]
            for by in 0..<blocksY {
                for bx in 0..<blocksX {
                    let nbh = Neighbourhood(
                        at: bx, by, in: plane, width: blocksX)
                    let pred = predictor.apply(
                        to: nbh, lo: 0, hi: sampleHi)
                    let residual = plane[by * blocksX + bx]
                        &- pred
                    let packed = ZigZag.pack(residual)
                    try dcWriter.writeToken(
                        context: 0, value: packed, to: &w)
                }
            }
        }
        // 3. ACMetadata count = total block count (every block
        //    is a first-block since the bridge uses all-DCT8×8).
        let blockCount = blocksX * blocksY
        let acMetaBits = Int(ceilLog2(
            UInt32(max(1, blockCount))))
        if acMetaBits > 0 {
            // count - 1 stored.
            w.write(bits: acMetaBits,
                    value: UInt32(max(0, blockCount - 1)))
        }
        // 4. ACMetadata sub-image — GroupHeader + tokens.
        //    Bridge ACMetadata is uniform (DCT8×8 strategy=0,
        //    QF=1, no EPF), so all tokens are ZigZag.pack(0) = 0.
        try GroupHeader.default.write(to: &w)
        let acMetaWriter = TokenStreamWriter(
            header: postHeader, codebook: postCodebook)
        // 4 ACMetadata channels per libjxl `DecodeACMetadata`
        // (Y QF, X sharpness, B AC-strategy first-block, B
        // AC-strategy code). Each gets blockCount tokens.
        for _ in 0..<4 {
            for _ in 0..<blockCount {
                try acMetaWriter.writeToken(
                    context: 0, value: 0, to: &w)
            }
        }
    }

    /// Write the bridge frame's HfGlobal section body. Mirrors
    /// the existing `writeHfGlobal` closure inside
    /// `buildFrameSections` but emits the custom
    /// `DequantMatrices` envelope from v0.12.0u (slot 0 RAW from
    /// `state.rawQuantPayload`, library defaults elsewhere)
    /// instead of the pixel-pipeline's `all_default = true` bit.
    ///
    /// Section layout (libjxl `dec_frame.cc::DecodeHfGlobal`):
    ///
    ///   1. `DequantMatrices` envelope — for the bridge: 1-bit
    ///      `all_default = false` + 17 per-slot encodings
    ///      (slot 0 RAW with the JPEG quant table; slots 1..16
    ///      library default).
    ///   2. `num_histograms = 1` — encoded as 0 in
    ///      `CeilLog2(numGroups)` bits. For the single-group
    ///      bridge case (numGroups = 1), this collapses to 0 bits.
    ///   3. `used_orders = 0` (default coefficient order) via the
    ///      libjxl `kOrderEnc` U32 distribution.
    ///   4. AC `EntropySectionHeader` + AC `MultiClusterCodebook`
    ///      — the codebook the per-AC-group section will use for
    ///      its coefficient tokens. Passed in by the caller so a
    ///      future histogram-derived codebook can swap in.
    ///
    /// **Status (v0.12.0aa).** Third of the four bridge section
    /// writers. The AC group writer (which uses this section's
    /// codebook) is the next bite.
    static func writeBridgeHfGlobal(
        state: JXLBridgeEncoderState,
        rawSlotOverrides: [Int: JXLBridgeRAWQuantPayload],
        acHeader: EntropySectionHeader,
        acCodebook: MultiClusterCodebook,
        acContexts: Int,
        numGroups: Int = 1,
        to w: inout BitWriter
    ) throws {
        // 1. DequantMatrices envelope (1-bit all_default + 17
        //    per-slot encodings if any override is present).
        try QuantEncodingBitstream.writeDequantMatrices(
            rawSlotOverrides: rawSlotOverrides, to: &w)
        // 2. num_histograms = 1 → encode 0 in CeilLog2(numGroups)
        //    bits. CeilLog2(1) = 0 → no bits written for the
        //    single-group case.
        let nhBits = Int(ceilLog2(
            UInt32(max(1, numGroups))))
        if nhBits > 0 {
            w.write(bits: nhBits, value: 0)
        }
        // 3. used_orders = 0 via kOrderEnc U32.
        try w.writeU32(0, distributions: kOrderEnc)
        // 4. AC EntropySectionHeader + codebook.
        try acHeader.write(to: &w, numContexts: acContexts)
        try acCodebook.write(to: &w, header: acHeader)
    }

    /// Synthesise a `VarDCTEncoder.Quantized` from a
    /// `JXLBridgeEncoderState` so the existing token-generation
    /// machinery (`generateACTokens`, `BlockCtxMap`, etc.) can be
    /// reused for the bridge path. All blocks are stamped with
    /// DCT8×8 strategy (raw value 0) — the bridge's all-DCT8×8
    /// invariant — and the QF is uniform 1.
    ///
    /// The DC + AC values come straight from `state.planes`,
    /// which has already had the DCzero adjustment + JpegOrder
    /// channel remap applied (v0.12.0l + j). So the synthetic
    /// `Quantized` carries the JPEG-derived coefficients in JXL
    /// XYB-slot indexing, ready for the AC tokeniser.
    static func buildBridgeQuantized(
        state: JXLBridgeEncoderState
    ) -> VarDCTEncoder.Quantized {
        let bX = state.planes.blocksX
        let bY = state.planes.blocksY
        let blockCount = bX * bY
        // Repack per-block AC: state.planes is [ch][blockIdx][k];
        // VarDCTEncoder.Quantized.acQuant is [blockIdx][ch][...].
        var acQuant = [[[Int32]]](
            repeating: [], count: blockCount)
        for bi in 0..<blockCount {
            var perChannel = [[Int32]](
                repeating: [Int32](repeating: 0, count: 64),
                count: 3)
            for ch in 0..<min(3, state.planes.channelCount) {
                perChannel[ch] = state.planes.acPerChannel[ch][bi]
            }
            acQuant[bi] = perChannel
        }
        // DC: state.planes.dcPerChannel is [ch][block]; Quantized
        // expects [ch][block] too. Pad missing channels with zeros
        // for grayscale fixtures (Quantized always has 3 slots).
        var dcQuant = [[Int32]](
            repeating: [Int32](
                repeating: 0, count: blockCount),
            count: 3)
        for ch in 0..<min(3, state.planes.channelCount) {
            dcQuant[ch] = state.planes.dcPerChannel[ch]
        }
        return VarDCTEncoder.Quantized(
            xsize: state.source.width,
            ysize: state.source.height,
            blocksX: bX, blocksY: bY,
            globalScale: 1, quantDC: 16, qf: 1,
            dcExtraPrecision: 0,
            dcQuant: dcQuant,
            acStrategy: [UInt8](
                repeating: 0, count: blockCount),  // all DCT8×8
            acQuant: acQuant,
            gaborish: false,
            qfPerBlock: [Int32](
                repeating: 1, count: blockCount))
    }

    /// Write the bridge frame's AC group section body. Reuses
    /// the existing `generateACTokens` (the same code that
    /// powers the pixel-pipeline VarDCT writer) by passing in a
    /// `VarDCTEncoder.Quantized` synthesised from the bridge
    /// state via `buildBridgeQuantized(state:)`. The token
    /// context routing is identical to the pixel-pipeline case;
    /// only the input data + DC handling differ.
    ///
    /// Section layout (libjxl `dec_group.cc::DecodeACGroup`):
    ///
    ///   - Sequence of `(context, value)` tokens — one `nzeros`
    ///     token per (block, channel) followed by one
    ///     coefficient token per non-zero AC coefficient in the
    ///     scan order. Channels are visited in libjxl's storage
    ///     order `{Y, X, B}` (= indices 1, 0, 2).
    ///
    /// **Status (v0.12.0bb).** Fourth and final bridge section
    /// writer. Composes everything from v0.12.0i–aa into one
    /// call. The TOC + section-concat into a full JXL frame is
    /// the wire-up bite (`JXLBridgeEncoder.write(state:)` swap).
    static func writeBridgeACGroup(
        state: JXLBridgeEncoderState,
        groupIndex: Int = 0,
        numGroupsX: Int = 1,
        numGroupsY: Int = 1,
        blocksPerGroup: Int = 32,
        bctx: BlockCtxMap = BlockCtxMap(),
        acHeader: EntropySectionHeader,
        acCodebook: MultiClusterCodebook,
        to w: inout BitWriter
    ) throws {
        let q = buildBridgeQuantized(state: state)
        let (perGroup, _, _) = generateACTokens(
            q: q, bctx: bctx,
            numGroupsX: numGroupsX,
            numGroupsY: numGroupsY,
            blocksPerGroup: blocksPerGroup)
        guard groupIndex < perGroup.count else {
            throw WriterError.unsupported(
                "writeBridgeACGroup: groupIndex \(groupIndex) "
                + "out of range (only \(perGroup.count) groups)")
        }
        let acWriter = TokenStreamWriter(
            header: acHeader, codebook: acCodebook)
        for tok in perGroup[groupIndex] {
            try acWriter.writeToken(
                context: tok.context, value: tok.value, to: &w)
        }
        // No alpha for the bridge.
    }

    static func writeBridgePrelude(
        state: JXLBridgeEncoderState
    ) throws -> Data {
        var w = BitWriter()
        // 1. Signature.
        w.write(bits: 8, value: 0xFF)
        w.write(bits: 8, value: 0x0A)
        // 2. SizeHeader from source dimensions.
        try SizeHeader(
            xsize: UInt32(state.source.width),
            ysize: UInt32(state.source.height)
        ).write(to: &w)
        // 3. ImageMetadata — non-XYB, matched to component count.
        let nch = state.planes.channelCount
        let colorEncoding: ColorEncoding
        switch nch {
        case 1: colorEncoding = .grayscaleD65
        case 3: colorEncoding = .srgb
        default:
            throw WriterError.unsupported(
                "bridge prelude: channel count \(nch) "
                + "(only 1 or 3 supported)")
        }
        let meta = ImageMetadata(
            allDefault: false, orientation: 1,
            intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: BitDepth(
                floatingPoint: false, bitsPerSample: 8),
            modular16BitBufferSufficient: true,
            extraChannels: [],
            xybEncoded: false,
            colorEncoding: colorEncoding,
            intensityTarget: 255.0, minNits: 0.0,
            relativeToMaxDisplay: false, linearBelow: 0.0)
        try meta.write(to: &w)
        // 4. CustomTransformData — non-XYB branch: 1-bit
        //    all_default = 1, then JumpToByteBoundary.
        w.writeBit(true)
        w.alignToByte()
        // 5. FrameHeader from bridge params.
        let p = state.frameHeaderParams
        let fh = FrameHeader(
            allDefault: false,
            frameType: .regular, encoding: p.encoding,
            flags: 0,
            colorTransform: p.colorTransform,
            chromaSubsampling: p.chromaSubsampling,
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
            loopFilter: p.loopFilter)
        try fh.write(to: &w, context: FrameHeaderContext(
            xybEncoded: false, numExtraChannels: 0,
            haveAnimation: false, haveTimecodes: false))
        return w.finishToData()
    }

    /// Encode N `ImageFrame`s as a single multi-frame VarDCT JPEG XL
    /// codestream (animation). All frames must share the same
    /// dimensions and alpha presence. `durations` is per-frame in
    /// tps units (the metadata declares 100 tps, so each unit is
    /// 10 ms by default). The decoder reads them via the frame
    /// header's `animationFrame.duration` field.
    public static func encodeAnimation(
        frames: [ImageFrame], distance: Float = 1.0,
        gaborish: Bool = true, adaptiveQF: Bool = true,
        frameDurations: [UInt32]? = nil
    ) throws -> Data {
        guard !frames.isEmpty else {
            throw WriterError.unsupported(
                "encodeAnimation: empty frames array")
        }
        let durations =
            frameDurations ?? [UInt32](
                repeating: 10, count: frames.count)
        guard durations.count == frames.count else {
            throw WriterError.unsupported(
                "encodeAnimation: durations.count "
                + "(\(durations.count)) must match frames.count "
                + "(\(frames.count))")
        }
        // Encode every frame to its own section list.
        var chunks: [EncodedFrameSections] = []
        chunks.reserveCapacity(frames.count)
        for frame in frames {
            chunks.append(try buildFrameSections(
                frame: frame, distance: distance,
                gaborish: gaborish, adaptiveQF: adaptiveQF))
        }
        // All frames must agree on dimensions + alpha presence.
        let first = chunks[0]
        for (i, c) in chunks.enumerated() where i > 0 {
            guard c.xsize == first.xsize, c.ysize == first.ysize,
                  c.hasAlpha == first.hasAlpha else {
                throw WriterError.unsupported(
                    "encodeAnimation: frame \(i) "
                    + "\(c.xsize)×\(c.ysize)/\(c.hasAlpha) "
                    + "differs from frame 0 "
                    + "\(first.xsize)×\(first.ysize)/"
                    + "\(first.hasAlpha)")
            }
        }
        // libjxl-default 100 tps timestamp resolution, infinite
        // playback loops, no SMPTE timecodes.
        let animation = AnimationHeader(
            tpsNumerator: 100, tpsDenominator: 1,
            numLoops: 0, haveTimecodes: false)
        var out = try writeCodestreamPrelude(
            xsize: first.xsize, ysize: first.ysize,
            hasAlpha: first.hasAlpha, animation: animation)
        for (i, c) in chunks.enumerated() {
            let isLast = (i == chunks.count - 1)
            let af = AnimationFrame(
                duration: durations[i], timecode: 0)
            out.append(try writeFrameChunk(
                hasAlpha: c.hasAlpha, gaborish: c.gaborish,
                isLast: isLast,
                animationFrame: af, haveAnimation: true,
                sections: c.sections))
        }
        return out
    }
}
