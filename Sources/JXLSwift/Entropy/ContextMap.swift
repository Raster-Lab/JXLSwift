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

public enum ContextMapError: Error, Sendable, Equatable {
    case clusterIndexOutOfRange(index: Int, max: Int)
    case bitsPerEntryTooSmall(needed: Int, encoded: Int)
    case fullPathNotImplemented
    case bitstream(BitstreamError)
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
    public static func read(numContexts: Int, from r: inout BitReader) throws -> ContextMap {
        if numContexts <= 1 {
            return ContextMap.trivial(numContexts: max(0, numContexts))
        }
        let isSimple: Bool
        do { isSimple = try r.readBit() }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        guard isSimple else {
            // The full path needs `use_mtf` + DecodeHistograms + ANS
            // and the inverse move-to-front transform. Not yet
            // implemented — see libjxl dec_context_map.cc.
            throw ContextMapError.fullPathNotImplemented
        }
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
}
