// ContextMap — histogram clustering / context-to-cluster assignment.
//
// ISO/IEC 18181-1 §C.6.4. Real codestreams (Modular tree leaves,
// VarDCT contexts, etc.) use *many* rANS contexts — often hundreds —
// but training a separate distribution per context wastes bits when
// many contexts have similar shape. The encoder clusters similar
// contexts together; each cluster shares one distribution, and the
// codestream stores a `context_map[i] = cluster_index_for_context_i`
// alongside the per-cluster distributions.
//
// **Bit layout (matches libjxl `DecodeContextMap` exactly):**
//
//     // The caller knows num_contexts from the surrounding header
//     // (e.g. Modular tree leaf count). When num_contexts == 1, the
//     // surrounding code skips this section entirely — the map is
//     // implicitly [0] and zero bits are emitted.
//
//     is_simple          u(1)
//     if is_simple == 1:
//         bits_per_entry u(2)        // 0, 1, 2, or 3
//         if bits_per_entry == 0:
//             return [0] * num_contexts      // shortcut for trivial map
//         for i in 0..<num_contexts:
//             map[i]     u(bits_per_entry)
//     else:
//         use_mtf : u(1)
//         entropy-coded entries via DecodeHistograms + ANS
//         (see libjxl dec_context_map.cc — NOT YET IMPLEMENTED HERE)
//
// `num_clusters` is derived from the decoded map (`max(map) + 1`),
// not transmitted as a separate field. Earlier project-internal
// versions of this file emitted `num_clusters - 1` as a `u(8)` prefix
// — that drifted bits relative to a real codestream.
//
// **Caveats:** the simple-bits-per-entry path covers num_clusters in
// {1, 2, 4, 8} (i.e. up to 3 bits per entry). Anything wider needs
// the full entropy-coded path with the inverse move-to-front transform
// — not yet implemented. Callers requiring it get
// `.fullPathNotImplemented`.

import Foundation

public indirect enum ContextMapError: Error, Sendable, Equatable {
    case clusterIndexOutOfRange(index: Int, max: Int)
    case bitsPerEntryTooSmall(needed: Int, encoded: Int)
    case fullPathNotImplemented
    case bitstream(BitstreamError)
    /// Inner entropy section header for the full path failed to parse.
    case innerHeader(EntropySectionHeaderError)
    /// Inner per-cluster codebook for the full path failed to parse.
    case innerCodebook(MultiClusterCodebookError)
    /// Reading a context-map symbol from the inner ANS / prefix
    /// stream failed.
    case innerToken(TokenStreamReaderError)
    /// VerifyContextMap: not every cluster index in [0, numClusters)
    /// appears in the decoded map. libjxl rejects this as malformed.
    case incompleteMap

    public static func == (lhs: ContextMapError, rhs: ContextMapError) -> Bool {
        switch (lhs, rhs) {
        case (.clusterIndexOutOfRange(let a, let am),
              .clusterIndexOutOfRange(let b, let bm)):
            return a == b && am == bm
        case (.bitsPerEntryTooSmall(let a, let ae),
              .bitsPerEntryTooSmall(let b, let be)):
            return a == b && ae == be
        case (.fullPathNotImplemented, .fullPathNotImplemented):
            return true
        case (.bitstream(let a), .bitstream(let b)):
            return a == b
        case (.incompleteMap, .incompleteMap):
            return true
        case (.innerHeader, .innerHeader),
             (.innerCodebook, .innerCodebook),
             (.innerToken, .innerToken):
            // Inner cases compare type-only — the wrapped errors don't
            // all carry Equatable conformance.
            return true
        default:
            return false
        }
    }
}

public struct ContextMap: Sendable, Equatable {
    /// Number of contexts (i.e. `map.count`).
    public var numContexts: Int { map.count }
    /// Number of distinct clusters; `map[i] < numClusters` for all `i`.
    public let numClusters: Int
    /// Whether the inverse move-to-front transform is applied. Always
    /// `false` for the simple path; only relevant once the full path
    /// lands.
    public let useMTF: Bool
    /// `map[i]` = cluster index for context `i`.
    public let map: [UInt8]

    public init(numClusters: Int, useMTF: Bool = false, map: [UInt8]) throws {
        guard numClusters >= 1 && numClusters <= 256 else {
            throw ContextMapError.clusterIndexOutOfRange(index: numClusters, max: 256)
        }
        for (i, c) in map.enumerated() {
            guard Int(c) < numClusters else {
                throw ContextMapError.clusterIndexOutOfRange(
                    index: Int(c), max: numClusters - 1
                )
            }
            _ = i
        }
        self.numClusters = numClusters
        self.useMTF = useMTF
        self.map = map
    }

    /// Construct the trivial single-cluster map: every context routes
    /// to cluster 0.
    public static func trivial(numContexts: Int) -> ContextMap {
        // Bypass the `init` validator — this path is always valid.
        let m = [UInt8](repeating: 0, count: numContexts)
        return ContextMap(numClusters: 1, useMTF: false, mapAsserted: m)
    }

    /// Internal initialiser that skips validation; used only by
    /// `trivial(numContexts:)` and the decoder (which validates
    /// inline).
    fileprivate init(numClusters: Int, useMTF: Bool, mapAsserted: [UInt8]) {
        self.numClusters = numClusters
        self.useMTF = useMTF
        self.map = mapAsserted
    }
}

extension ContextMap {

    /// Serialise this context map. The caller is expected to skip
    /// calling `write` entirely when `numContexts <= 1` — the surrounding
    /// header carries the count, and an empty/single-entry map is
    /// implicit.
    public func write(to w: inout BitWriter) throws {
        if numContexts <= 1 {
            // Defensive: caller should not call us in this case.
            return
        }
        // Simple path: is_simple = 1, bits_per_entry, then entries.
        w.writeBit(true)
        let bitsNeeded = Int(ceilLog2(UInt32(numClusters)))
        // bits_per_entry ∈ {0, 1, 2, 3}; 0 means "all entries 0".
        guard bitsNeeded <= 3 else {
            throw ContextMapError.fullPathNotImplemented
        }
        w.write(bits: 2, value: UInt32(bitsNeeded))
        if bitsNeeded == 0 {
            // Trivial map: every context routes to cluster 0. Nothing
            // more to emit — `bits_per_entry == 0` is the shortcut.
            return
        }
        for c in map {
            w.write(bits: bitsNeeded, value: UInt32(c))
        }
    }

    /// Deserialise a context map. `numContexts` is supplied by the
    /// caller (the surrounding header tells us how many contexts the
    /// downstream consumer expects). When `numContexts <= 1` the
    /// caller should skip calling `read` and use the implicit `[0]`
    /// map directly.
    ///
    /// Two paths (libjxl `dec_context_map.cc::DecodeContextMap`):
    ///
    ///   • **Simple path** (`is_simple == 1`): a 2-bit `bits_per_entry`
    ///     field selects 0 / 1 / 2 / 3 bits per entry, then each
    ///     entry is read as `u(bits_per_entry)`. Caps cluster count at
    ///     2^bits_per_entry (≤ 8).
    ///
    ///   • **Full path** (`is_simple == 0`): a `use_mtf` flag + a full
    ///     entropy section (1 cluster, `disallow_lz77=numContexts<=2`)
    ///     + ANS-coded entries. After decoding, the inverse
    ///     move-to-front transform may be applied. This is the path
    ///     cjxl picks for streams with > 8 clusters (typical of
    ///     larger RGB images).
    public static func read(numContexts: Int, from r: inout BitReader) throws -> ContextMap {
        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        let pStart = r.position
        if numContexts <= 1 {
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE ContextMap.read trivial numContexts=\(numContexts) at pos=\(pStart)\n".utf8))
            }
            return ContextMap.trivial(numContexts: max(0, numContexts))
        }
        let isSimple: Bool
        do { isSimple = try r.readBit() }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        let cm: ContextMap
        if isSimple {
            cm = try readSimplePath(numContexts: numContexts, from: &r)
        } else {
            cm = try readFullPath(numContexts: numContexts, from: &r)
        }
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE ContextMap.read numContexts=\(numContexts) numClusters=\(cm.numClusters) isSimple=\(isSimple) bits=\(r.position-pStart) at pos=\(pStart) map=\(cm.map)\n".utf8))
        }
        return cm
    }

    /// Simple-bits-per-entry context map. Encodes up to 8 clusters
    /// (3 bits per entry).
    private static func readSimplePath(
        numContexts: Int, from r: inout BitReader
    ) throws -> ContextMap {
        let bitsPerEntry: UInt32
        do { bitsPerEntry = try r.read(bits: 2) }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        let bpe = Int(bitsPerEntry)
        var map = [UInt8](repeating: 0, count: numContexts)
        if bpe == 0 {
            // All entries are 0; map already initialised.
            return ContextMap(numClusters: 1, useMTF: false, mapAsserted: map)
        }
        var maxSym: UInt8 = 0
        for i in 0..<numContexts {
            let c: UInt32
            do { c = try r.read(bits: bpe) }
            catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
            map[i] = UInt8(c)
            if UInt8(c) > maxSym { maxSym = UInt8(c) }
        }
        let numClusters = Int(maxSym) + 1
        return ContextMap(numClusters: numClusters, useMTF: false, mapAsserted: map)
    }

    /// Full entropy-coded context map. libjxl
    /// `dec_context_map.cc::DecodeContextMap`:
    ///
    ///     use_mtf = u(1)
    ///     // Inner entropy section with 1 sink cluster.
    ///     // libjxl disallows LZ77 here when context_map.size() <= 2.
    ///     inner_header  = DecodeHistograms(num_histograms = 1)
    ///     inner_codebook = read per-cluster ANS / prefix codebook
    ///     for i in 0..<context_map.size():
    ///         map[i] = inner.readToken(context = 0) (with LZ77 enabled)
    ///     if use_mtf:
    ///         InverseMoveToFrontTransform(map)
    ///     num_clusters = max(map) + 1
    ///     verify every cluster 0..num_clusters-1 appears at least once
    private static func readFullPath(
        numContexts: Int, from r: inout BitReader
    ) throws -> ContextMap {
        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        let useMTFStart = r.position
        let useMTF: Bool
        do { useMTF = try r.readBit() }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        // Inner entropy section: one cluster, one context.
        let innerHdrStart = r.position
        let innerHdr: EntropySectionHeader
        do {
            innerHdr = try EntropySectionHeader.read(from: &r, numContexts: 1)
        } catch let e as EntropySectionHeaderError {
            throw ContextMapError.innerHeader(e)
        }
        let innerHdrBits = r.position - innerHdrStart
        let innerCBStart = r.position
        let innerCB: MultiClusterCodebook
        do {
            innerCB = try MultiClusterCodebook.read(from: &r, header: innerHdr)
        } catch let e as MultiClusterCodebookError {
            throw ContextMapError.innerCodebook(e)
        }
        let innerCBBits = r.position - innerCBStart
        let symbolsStart = r.position
        if trace {
            let prefix = innerHdr.usePrefixCode ? "prefix" : "rANS"
            let logAlpha = innerHdr.logAlphaSize
            // The cjxl-d=1 fixture's inner ContextMap section uses
            // a prefix-coded path with logAlpha=15. Our reader
            // produces the right *symbols* (verified by ctxMap
            // dump matching kDefaultBlockCtxMap byte-exact), but
            // the cumulative bit position after reading them
            // currently differs from libjxl's by some N bits we
            // can't pin without instrumented libjxl. The next
            // bite is to build libjxl with `JXL_BYTEPOS_TRACE`
            // and diff our trace against it line-by-line.
            let line = "TRACE ContextMap.readFullPath useMTF=\(useMTF) at \(useMTFStart) | innerHdr \(innerHdrBits)b (mode=\(prefix), logAlpha=\(logAlpha)) | innerCB \(innerCBBits)b | symbols start at \(symbolsStart)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        var stream = TokenStreamReader(header: innerHdr, codebook: innerCB)
        var map = [UInt8](repeating: 0, count: numContexts)
        var maxSym: UInt32 = 0
        for i in 0..<numContexts {
            let sym: UInt32
            do { sym = try stream.readToken(context: 0, from: &r) }
            catch let e as TokenStreamReaderError {
                throw ContextMapError.innerToken(e)
            }
            if sym >= 256 {
                throw ContextMapError.clusterIndexOutOfRange(
                    index: Int(sym), max: 255
                )
            }
            map[i] = UInt8(sym)
            if sym > maxSym { maxSym = sym }
        }
        if useMTF {
            inverseMoveToFrontTransform(&map)
            // After MTF the new max may differ; recompute.
            maxSym = 0
            for v in map {
                if UInt32(v) > maxSym { maxSym = UInt32(v) }
            }
        }
        let numClusters = Int(maxSym) + 1
        // Verify every cluster index 0..<numClusters appears (libjxl
        // `VerifyContextMap`).
        var seen = [Bool](repeating: false, count: numClusters)
        for v in map { seen[Int(v)] = true }
        if seen.contains(false) {
            throw ContextMapError.incompleteMap
        }
        return ContextMap(
            numClusters: numClusters, useMTF: useMTF, mapAsserted: map
        )
    }
}

/// Inverse Move-to-Front transform — libjxl
/// `inverse_mtf-inl.h::InverseMoveToFrontTransform`. Mutates `v` in
/// place. Maintains a 256-entry alphabet permutation (`mtf`); for each
/// input symbol `index`, the output is `mtf[index]` and (if `index !=
/// 0`) the entry at `index` is moved to the front of `mtf`.
public func inverseMoveToFrontTransform(_ v: inout [UInt8]) {
    var mtf = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 { mtf[i] = UInt8(i) }
    for i in 0..<v.count {
        let index = Int(v[i])
        v[i] = mtf[index]
        if index != 0 {
            // Shift mtf[0..<index] right by one, then mtf[0] = moved.
            let value = mtf[index]
            // Move-to-front: rotate mtf[0..<=index] so the entry at
            // `index` lands at position 0.
            var j = index
            while j > 0 {
                mtf[j] = mtf[j - 1]
                j -= 1
            }
            mtf[0] = value
        }
    }
}
