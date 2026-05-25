// Embedded modular sub-image — write + read. The bitstream layout
// libjxl's `ModularGenericCompress` / `ModularDecode` use for
// modular images embedded inside other payloads (the canonical
// case: the per-channel quant table inside `DequantMatrices`
// when `kQuantModeRAW` is selected).
//
// Layout (libjxl `modular/encoding/encoding.cc::ModularDecode`):
//
//     GroupHeader                          (useGlobalTree, WP, transforms)
//     if !useGlobalTree:
//         tree section                     (codebook + tree tokens)
//         post-tree pixel codebook         (codebook for residuals)
//     per-channel:
//         row-major pixel residual tokens
//
// This file ships **both halves** as a tightly-paired
// composition layer. Round-trip tests between them validate
// each side without needing a surrounding JXL frame for `djxl`.
//
// **Step 3.6 dep 1** from `Documentation/PHASE-J-COEFFICIENT-BRIDGE.md`:
// the JPEG → JXL coefficient bridge's `DequantMatrices` RAW
// write uses this encoder for the embedded 3×8×8 quant-table
// sub-image. The reader's main customer is the v0.12.0 line's
// future Dep 3 (decoder-side local-tree support); today it
// exists for the round-trip validation harness only.
//
// Scope (v0.12.0r): no transforms, single-leaf default tree
// (`Predictor.gradient`, multiplier 1, offset 0). Multi-leaf
// trees + transforms are follow-on extensions.

import Foundation

/// Embedded modular sub-image errors. Distinct from
/// `GroupHeaderError` etc. so a caller can tell "the embedded
/// sub-image is malformed" from "this frame's group header is
/// malformed".
public enum ModularSubImageError: Error, Sendable, Equatable,
                                  LocalizedError {
    case invalidInput(String)
    case truncated
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return "ModularSubImage: \(m)"
        case .truncated:           return "ModularSubImage: truncated"
        case .malformed(let m):    return "ModularSubImage: \(m)"
        }
    }
}

public enum ModularSubImage {

    /// Write an embedded modular sub-image. All channels must be
    /// the same dimensions; predictor is `Gradient` (libjxl raw
    /// id 5) via a single-leaf local tree.
    ///
    /// - Parameters:
    ///   - channels: per-channel row-major `[Int32]` buffers,
    ///     each of length `width × height`.
    ///   - width / height: shared per-channel dimensions.
    ///   - bitsPerSample: precision hint (informational; the
    ///     residual encoding is bit-depth-agnostic via HybridUint).
    ///   - w: target BitWriter (caller's bitstream).
    public static func write(
        channels: [[Int32]],
        width: Int, height: Int,
        bitsPerSample: Int,
        to w: inout BitWriter
    ) throws {
        guard width > 0 && height > 0 else {
            throw ModularSubImageError.invalidInput(
                "non-positive dimensions \(width)×\(height)")
        }
        let pixelCount = width * height
        for (i, ch) in channels.enumerated() {
            guard ch.count == pixelCount else {
                throw ModularSubImageError.invalidInput(
                    "channel \(i) has \(ch.count) pixels, "
                    + "expected \(pixelCount)")
            }
        }
        // 1. GroupHeader — useGlobalTree=false, default WP, no
        //    transforms. Embedded sub-images don't have access
        //    to a surrounding frame's global tree, so we always
        //    ship a local one.
        let gh = GroupHeader(
            useGlobalTree: false,
            wpHeader: .default, transforms: [])
        try gh.write(to: &w)

        // 2. Local tree section. Single leaf:
        //    predictor = Gradient (libjxl raw id 5),
        //    multiplier = 1, offset = 0.
        let rawPredictor: UInt32 = 5
        let predictor: Predictor = .gradient
        let treeUintCfg = HybridUintConfig(
            splitExponent: 0, msbInToken: 0, lsbInToken: 0)
        let treeAlphabet = 16
        let treeLengths: [UInt8] = Array(
            repeating: 4, count: treeAlphabet)
        let treeTable = try PrefixCodeTable(lengths: treeLengths)
        let treeCodebook = MultiClusterCodebook(
            huffmanTables: [treeTable], ansCounts: [],
            alphabetSizes: [treeAlphabet])
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
                predictor: predictor,
                predictorOffset: 0, multiplier: 1,
                rawPredictor: rawPredictor)
        ])
        let treeWriter = TokenStreamWriter(
            header: treeHeader, codebook: treeCodebook)
        try tree.encode { ctx, val in
            try treeWriter.writeToken(
                context: ctx, value: val, to: &w)
        }

        // 3. Compute residuals + pool histogram across channels.
        let postCfg = HybridUintConfig.raw4
        var packedPerChannel: [[UInt32]] = []
        packedPerChannel.reserveCapacity(channels.count)
        var fullHisto = [Int](
            repeating: 0, count: postCfg.maxToken + 1)
        var maxUsedToken = 0
        let sampleHi: Int32 = bitsPerSample >= 31
            ? Int32.max
            : (Int32(1) << Int32(bitsPerSample)) - 1
        for pix in channels {
            var packed: [UInt32] = []
            packed.reserveCapacity(pixelCount)
            for y in 0..<height {
                for x in 0..<width {
                    let nbh = Neighbourhood(
                        at: x, y, in: pix, width: width)
                    let pred = predictor.apply(
                        to: nbh, lo: 0, hi: sampleHi)
                    let residual = pix[y * width + x] &- pred
                    let p = ZigZag.pack(residual)
                    let exp = postCfg.encode(p)
                    let t = Int(exp.token)
                    fullHisto[t] += 1
                    if t > maxUsedToken { maxUsedToken = t }
                    packed.append(p)
                }
            }
            packedPerChannel.append(packed)
        }
        let alphabetSize = max(1, maxUsedToken + 1)
        let histo = Array(fullHisto[0..<alphabetSize])
        let postLengths = lengthLimitedCanonicalHuffman(
            counts: histo, maxLength: 15,
            alphabetSize: alphabetSize)
        let postLeafTable = try PrefixCodeTable(
            lengths: postLengths)
        let postCodebook = MultiClusterCodebook(
            huffmanTables: [postLeafTable], ansCounts: [],
            alphabetSizes: [alphabetSize])
        let postHeader = EntropySectionHeader(
            lz77: .disabled,
            contextMap: ContextMap.trivial(numContexts: 1),
            usePrefixCode: true, logAlphaSize: 15,
            uintConfigs: [postCfg])
        try postHeader.write(to: &w, numContexts: 1)
        try postCodebook.write(to: &w, header: postHeader)

        // 4. Per-channel pixel tokens.
        let postWriter = TokenStreamWriter(
            header: postHeader, codebook: postCodebook)
        for packed in packedPerChannel {
            for v in packed {
                try postWriter.writeToken(
                    context: 0, value: v, to: &w)
            }
        }
    }

    /// Read an embedded modular sub-image written by `write(...)`.
    /// Returns per-channel row-major `[Int32]` buffers.
    ///
    /// - Parameters:
    ///   - r: BitReader positioned at the start of the
    ///     embedded sub-image (the first GroupHeader bit).
    ///   - width / height: per-channel dimensions (the embedded
    ///     image format doesn't carry these — caller supplies).
    ///   - bitsPerSample: precision (for the predictor's clamp).
    ///   - channelCount: how many channels are expected.
    public static func read(
        from r: inout BitReader,
        width: Int, height: Int,
        bitsPerSample: Int, channelCount: Int
    ) throws -> [[Int32]] {
        guard width > 0 && height > 0 && channelCount > 0 else {
            throw ModularSubImageError.invalidInput(
                "non-positive dimensions / channelCount")
        }
        // 1. GroupHeader.
        let gh: GroupHeader
        do { gh = try GroupHeader.read(from: &r) }
        catch let e as GroupHeaderError {
            throw ModularSubImageError.malformed(
                "GroupHeader: \(e)")
        }
        guard !gh.useGlobalTree else {
            throw ModularSubImageError.malformed(
                "embedded sub-image must use a local tree "
                + "(useGlobalTree=false); got useGlobalTree=true")
        }
        guard gh.transforms.isEmpty else {
            throw ModularSubImageError.malformed(
                "embedded sub-image with transforms not yet "
                + "supported (got \(gh.transforms.count))")
        }

        // 2. Local tree section.
        let treeHeader: EntropySectionHeader
        do {
            treeHeader = try EntropySectionHeader.read(
                from: &r, numContexts: 6)
        } catch {
            throw ModularSubImageError.malformed(
                "tree EntropySectionHeader: \(error)")
        }
        let treeCodebook: MultiClusterCodebook
        do {
            treeCodebook = try MultiClusterCodebook.read(
                from: &r, header: treeHeader)
        } catch {
            throw ModularSubImageError.malformed(
                "tree MultiClusterCodebook: \(error)")
        }
        var treeReader = TokenStreamReader(
            header: treeHeader, codebook: treeCodebook)
        let tree: ModularTree
        do {
            tree = try ModularTree.decode(
                from: &r, stream: &treeReader)
        } catch {
            throw ModularSubImageError.malformed(
                "tree decode: \(error)")
        }
        guard tree.nodes.count == 1 else {
            throw ModularSubImageError.malformed(
                "embedded sub-image with multi-leaf tree not "
                + "yet supported (got \(tree.nodes.count) "
                + "nodes — v0.12.0r ships single-leaf only)")
        }
        let leaf = tree.nodes[0]
        let rawPredictor = leaf.rawPredictor
        let offset = Int32(leaf.predictorOffset)
        let multiplier = Int32(leaf.multiplier)

        // 3. Post-tree pixel-codebook.
        let postHeader: EntropySectionHeader
        do {
            postHeader = try EntropySectionHeader.read(
                from: &r, numContexts: 1)
        } catch {
            throw ModularSubImageError.malformed(
                "post-tree EntropySectionHeader: \(error)")
        }
        let postCodebook: MultiClusterCodebook
        do {
            postCodebook = try MultiClusterCodebook.read(
                from: &r, header: postHeader)
        } catch {
            throw ModularSubImageError.malformed(
                "post-tree MultiClusterCodebook: \(error)")
        }
        var postReader = TokenStreamReader(
            header: postHeader, codebook: postCodebook)

        // 4. Per-channel pixel residuals → reconstructed pixels.
        let sampleHi: Int32 = bitsPerSample >= 31
            ? Int32.max
            : (Int32(1) << Int32(bitsPerSample)) - 1
        var out: [[Int32]] = []
        out.reserveCapacity(channelCount)
        for _ in 0..<channelCount {
            var pix = [Int32](
                repeating: 0, count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    let raw: UInt32
                    do {
                        raw = try postReader.readToken(
                            context: 0, from: &r)
                    } catch {
                        throw ModularSubImageError.truncated
                    }
                    let residual = ZigZag.unpack(raw) * multiplier
                    let nbh = Neighbourhood(
                        at: x, y, in: pix, width: width)
                    let predicted = applyLibjxlPredictor(
                        raw: rawPredictor, neighbourhood: nbh,
                        wpResult: 0)
                    let reconstructed = residual &+ predicted &+ offset
                    pix[y * width + x] = reconstructed
                    _ = sampleHi
                }
            }
            out.append(pix)
        }
        return out
    }
}
