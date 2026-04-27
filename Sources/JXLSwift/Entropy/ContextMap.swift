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
// **Bit layout (this implementation, per spec interpretation §C.6.4):**
//
//     // The caller knows num_contexts from the surrounding header
//     // (e.g. Modular tree leaf count). When num_contexts == 1, the
//     // map is implicitly [0] and no bits are emitted.
//
//     if num_contexts == 1:
//         return [0]
//
//     num_clusters - 1   u(8)        // 1..256 clusters
//
//     if num_clusters == 1:
//         return [0, 0, …, 0]      // every context maps to cluster 0
//
//     is_simple          u(1)
//     if is_simple == 1:
//         bits_per_entry u(2)        // 0, 1, 2, or 3
//         if bits_per_entry == 0:
//             return [0] * num_contexts
//         for i in 0..<num_contexts:
//             map[i]     u(bits_per_entry)
//             // map[i] must be < num_clusters
//     else:
//         throw .fullPathNotImplemented
//
// **Caveats:** this implementation covers the simple-bits-per-entry
// path (which spans num_clusters in {1, 2, 4, 8} with an arbitrary
// number of contexts). The full entropy-coded path with the inverse
// move-to-front transform is not yet implemented — it's needed once
// the codestream uses > 8 clusters per histogram, which is rare for
// the simplest Modular images. Callers requiring it will get
// `.fullPathNotImplemented`.
//
// `num_clusters - 1` is encoded as a straight `u(8)` here. The actual
// JXL bitstream uses a variable-length U8-like encoding; this is
// placeholder until full-path lands. (Round-trip tests prove
// encoder/decoder agreement; libjxl byte cross-check is the only way
// to verify spec compliance.)

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

    /// Serialise this context map. The decoder reads `numContexts`
    /// from the surrounding header, so we don't emit it here.
    public func write(to w: inout BitWriter) throws {
        if numContexts <= 1 {
            // Trivial case: no bits emitted.
            return
        }
        guard numClusters - 1 <= 0xFF else {
            throw ContextMapError.clusterIndexOutOfRange(
                index: numClusters, max: 256
            )
        }
        w.write(bits: 8, value: UInt32(numClusters - 1))
        if numClusters == 1 {
            return
        }
        // We only emit the simple path right now.
        w.writeBit(true)
        let bitsNeeded = Int(ceilLog2(UInt32(numClusters)))
        // bits_per_entry ∈ {0, 1, 2, 3}; 0 only valid when num_clusters == 1.
        guard bitsNeeded <= 3 else {
            throw ContextMapError.fullPathNotImplemented
        }
        w.write(bits: 2, value: UInt32(bitsNeeded))
        for c in map {
            if bitsNeeded > 0 {
                w.write(bits: bitsNeeded, value: UInt32(c))
            }
        }
    }

    /// Deserialise a context map. `numContexts` is supplied by the
    /// caller (the surrounding header tells us how many contexts the
    /// downstream consumer expects).
    public static func read(numContexts: Int, from r: inout BitReader) throws -> ContextMap {
        if numContexts <= 1 {
            return ContextMap.trivial(numContexts: max(0, numContexts))
        }
        let numClustersMinus1: UInt32
        do { numClustersMinus1 = try r.read(bits: 8) }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        let numClusters = Int(numClustersMinus1) + 1
        if numClusters == 1 {
            return ContextMap.trivial(numContexts: numContexts)
        }
        let isSimple: Bool
        do { isSimple = try r.readBit() }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        guard isSimple else {
            throw ContextMapError.fullPathNotImplemented
        }
        let bitsPerEntry: UInt32
        do { bitsPerEntry = try r.read(bits: 2) }
        catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
        let bpe = Int(bitsPerEntry)
        // The decoder must reject an under-sized bits_per_entry — if
        // num_clusters needs more bits than encoded, the map can't
        // express the full range.
        let needed = Int(ceilLog2(UInt32(numClusters)))
        guard bpe >= needed else {
            throw ContextMapError.bitsPerEntryTooSmall(needed: needed, encoded: bpe)
        }
        var map = [UInt8](repeating: 0, count: numContexts)
        if bpe == 0 {
            // All entries are 0; map already initialised.
            return ContextMap(numClusters: numClusters, useMTF: false, mapAsserted: map)
        }
        for i in 0..<numContexts {
            let c: UInt32
            do { c = try r.read(bits: bpe) }
            catch let e as BitstreamError { throw ContextMapError.bitstream(e) }
            guard Int(c) < numClusters else {
                throw ContextMapError.clusterIndexOutOfRange(
                    index: Int(c), max: numClusters - 1
                )
            }
            map[i] = UInt8(c)
        }
        return ContextMap(numClusters: numClusters, useMTF: false, mapAsserted: map)
    }
}
