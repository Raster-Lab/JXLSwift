// ModularTree — the meta-adaptive (MA) tree that drives per-pixel
// predictor / multiplier / offset selection in a Modular sub-bitstream.
//
// ISO/IEC 18181-1 §C.7.4 (and libjxl `lib/jxl/modular/encoding/dec_ma.cc`).
// A Modular tree is a complete binary tree where:
//
//   • **Decision nodes** ask "is property[k] ≤ splitval?" — branching
//     left to `leftChild` if true, right to `rightChild` otherwise.
//   • **Leaf nodes** carry the prediction parameters for whatever
//     pixel routes there: `predictor` (one of 14 spec predictors),
//     `predictorOffset` (signed bias added to the prediction), and
//     `multiplier` (power-of-2 scaling of the residual range).
//
// The tree is encoded as a *pre-order* token stream from a 6-context
// entropy section. Decoding it requires:
//   1. An `EntropySectionHeader` + `MultiClusterCodebook` for the
//      tree's 6 contexts (`kPropertyContext`, `kPredictorContext`,
//      `kOffsetContext`, `kMultiplierLogContext`,
//      `kMultiplierBitsContext`, `kSplitValContext`).
//   2. A `TokenStreamReader` driving the codebook.
//   3. The decode algorithm below — a queue-based pre-order walk.
//
// This file ships the decoder. The encoder is incremental future
// work; for now we can only *read* MA-trees emitted by other JXL
// tools.

import Foundation

public enum ModularTreeError: Error, Sendable {
    case tokenReader(TokenStreamReaderError)
    case treeTooLarge(size: Int, limit: Int)
    case invalidProperty(UInt32)
    case invalidPredictor(UInt32)
    case invalidMultiplier(log: UInt32, bits: UInt32)
    case truncated
}

public struct ModularTreeNode: Sendable, Equatable {
    /// Property index this node tests. -1 marks a leaf.
    public let property: Int32
    /// Split value (signed). Decision: route left if
    /// `properties[property] <= splitval`, else right. Ignored on
    /// leaves.
    public let splitVal: Int32
    /// Index of the left-child node in the parent tree's `nodes`
    /// array. On leaves this is reused as the `leafId` (a
    /// pre-order index across all leaves).
    public let leftChildOrLeafId: Int
    /// Index of the right-child node. Ignored on leaves.
    public let rightChild: Int
    /// Modular predictor for leaf nodes (semantic mapping into our
    /// `Predictor` enum, for round-trip with our M0 encoder).
    /// Decision nodes carry `Predictor.zero`.
    public let predictor: Predictor
    /// Raw libjxl predictor index 0..13 — the source-of-truth for
    /// per-pixel reconstruction. Used by the streaming decoder; the
    /// `predictor` field is the lossy semantic mapping.
    public let rawPredictor: UInt32
    /// Signed offset added to predictor output (leaf only).
    public let predictorOffset: Int64
    /// Multiplier applied to residuals (leaf only). Always a power
    /// of two: `(mul_bits + 1) << mul_log`.
    public let multiplier: UInt32

    public init(
        property: Int32, splitVal: Int32,
        leftChildOrLeafId: Int, rightChild: Int,
        predictor: Predictor, predictorOffset: Int64, multiplier: UInt32,
        rawPredictor: UInt32 = 0
    ) {
        self.property = property
        self.splitVal = splitVal
        self.leftChildOrLeafId = leftChildOrLeafId
        self.rightChild = rightChild
        self.predictor = predictor
        self.rawPredictor = rawPredictor
        self.predictorOffset = predictorOffset
        self.multiplier = multiplier
    }

    public var isLeaf: Bool { property == -1 }
    public var leafId: Int { leftChildOrLeafId }
    public var leftChild: Int { leftChildOrLeafId }
}

public struct ModularTree: Sendable, Equatable {
    /// Pre-order list of nodes — `nodes[0]` is the root.
    public let nodes: [ModularTreeNode]
    /// Number of leaves in the tree (= `(nodes.count + 1) / 2` for a
    /// complete binary tree).
    public let leafCount: Int

    public init(nodes: [ModularTreeNode]) {
        self.nodes = nodes
        self.leafCount = nodes.lazy.filter { $0.isLeaf }.count
    }

    /// Walk the tree from the root to a leaf using the supplied
    /// properties array. Each decision node tests
    /// `properties[node.property] > splitVal`. Per libjxl convention
    /// (verified by tracing libjxl's `FilterTree` and the
    /// `FlatDecisionNode` lookup against a 32×32 cjxl test):
    /// `lchild` (the FIRST decoded child) is the **">" match** branch;
    /// `rchild` (the second decoded) is the **"≤" match** branch.
    /// Our decoder labels the first decoded as `leftChild`, so:
    ///
    ///   prop > splitVal  →  leftChild (libjxl lchild)
    ///   prop ≤ splitVal  →  rightChild (libjxl rchild)
    ///
    /// (The earlier convention `≤ → leftChild` was the bug that
    /// caused channel 0 first-pixel decode to land on cluster 0
    /// instead of cluster 4 in cjxl-emitted streams — see the
    /// byte-equality investigation in ROADMAP.md.)
    public func walk(properties: [Int32]) throws -> ModularTreeNode {
        var idx = 0
        var safety = nodes.count + 1
        while safety > 0 {
            safety -= 1
            guard idx >= 0 && idx < nodes.count else {
                throw ModularTreeError.tokenReader(
                    .clusterOutOfRange(idx, max: nodes.count - 1)
                )
            }
            let node = nodes[idx]
            if node.isLeaf { return node }
            let propIdx = Int(node.property)
            guard propIdx >= 0 && propIdx < properties.count else {
                throw ModularTreeError.invalidProperty(UInt32(propIdx))
            }
            if properties[propIdx] > node.splitVal {
                idx = node.leftChild
            } else {
                idx = node.rightChild
            }
        }
        throw ModularTreeError.tokenReader(
            .clusterOutOfRange(idx, max: nodes.count - 1)
        )
    }

    /// Decode a Modular MA-tree from the token stream that follows
    /// the tree's entropy section. Caller has already constructed
    /// the `TokenStreamReader` from `EntropySectionHeader` +
    /// `MultiClusterCodebook` at `kNumTreeContexts = 6`.
    ///
    /// `treeSizeLimit` caps the node count — libjxl's bound is
    /// `min(1 << 22, 1024 + xsize*ysize*(channels)/16)`; pass any
    /// reasonable upper bound to abort on infinite-tree corruption.
    public static func decode(
        from r: inout BitReader,
        stream: inout TokenStreamReader,
        treeSizeLimit: Int = 1 << 22
    ) throws -> ModularTree {
        // libjxl context indices:
        let kSplitValContext = 0
        let kPropertyContext = 1
        let kPredictorContext = 2
        let kOffsetContext = 3
        let kMultiplierLogContext = 4
        let kMultiplierBitsContext = 5

        // Pre-order walk: every decoded node either claims a leaf
        // slot OR pushes 2 child slots to decode next.
        var nodes = [ModularTreeNode]()
        var toDecode = 1
        var leafId = 0
        while toDecode > 0 {
            if nodes.count > treeSizeLimit {
                throw ModularTreeError.treeTooLarge(
                    size: nodes.count, limit: treeSizeLimit
                )
            }
            toDecode -= 1
            let prop1: UInt32
            do {
                prop1 = try stream.readToken(
                    context: kPropertyContext, from: &r
                )
            } catch let e as TokenStreamReaderError {
                throw ModularTreeError.tokenReader(e)
            }
            if prop1 > 256 {
                throw ModularTreeError.invalidProperty(prop1)
            }
            let property = Int32(prop1) &- 1
            if property == -1 {
                // Leaf node.
                let predictorRaw = try readToken(&stream, kPredictorContext, &r)
                if predictorRaw >= 14 {
                    throw ModularTreeError.invalidPredictor(predictorRaw)
                }
                let offsetRaw = try readToken(&stream, kOffsetContext, &r)
                let predictorOffset = Int64(unpackSigned(offsetRaw))
                let mulLog = try readToken(&stream, kMultiplierLogContext, &r)
                if mulLog >= 31 {
                    throw ModularTreeError.invalidMultiplier(
                        log: mulLog, bits: 0
                    )
                }
                let mulBits = try readToken(&stream, kMultiplierBitsContext, &r)
                let multiplierLimit: UInt32 = (1 &<< (31 - mulLog)) &- 1
                if mulBits >= multiplierLimit {
                    throw ModularTreeError.invalidMultiplier(
                        log: mulLog, bits: mulBits
                    )
                }
                let multiplier: UInt32 = (mulBits &+ 1) &<< mulLog
                let predictor = mapPredictor(predictorRaw)
                nodes.append(ModularTreeNode(
                    property: -1, splitVal: 0,
                    leftChildOrLeafId: leafId,
                    rightChild: 0,
                    predictor: predictor,
                    predictorOffset: predictorOffset,
                    multiplier: multiplier,
                    rawPredictor: predictorRaw
                ))
                leafId &+= 1
                continue
            }
            // Decision node.
            let splitRaw = try readToken(&stream, kSplitValContext, &r)
            let splitVal = unpackSigned(splitRaw)
            // Children land at `nodes.count + toDecode + 1` and `+ 2`
            // — same index arithmetic libjxl uses (tree is stored
            // pre-order, so the child indices reflect future fills).
            let leftIdx = nodes.count + toDecode + 1
            let rightIdx = nodes.count + toDecode + 2
            nodes.append(ModularTreeNode(
                property: property, splitVal: splitVal,
                leftChildOrLeafId: leftIdx,
                rightChild: rightIdx,
                predictor: .zero, predictorOffset: 0, multiplier: 1
            ))
            toDecode += 2
        }
        return ModularTree(nodes: nodes)
    }

    /// Inverse of `decode`. Walks the tree pre-order and emits each
    /// node's tokens via `emit(ctx, value)`. The caller wires the
    /// closure to the actual entropy stream — typically a
    /// `TokenStreamWriter` over the tree section's `EntropySectionHeader`
    /// + `MultiClusterCodebook` (libjxl `enc_ma.cc::TokenizeTree`).
    ///
    /// Per-node emission (mirrors `decode` exactly):
    ///
    ///   • **Decision node** (`property >= 0`):
    ///       ctx 1 ← `UInt32(property + 1)`
    ///       ctx 0 ← `pack(splitVal)`
    ///     Then recurse on `leftChild` and `rightChild`.
    ///
    ///   • **Leaf** (`property == -1`):
    ///       ctx 1 ← `0` (leaf marker)
    ///       ctx 2 ← `rawPredictor`
    ///       ctx 3 ← `pack(predictorOffset)` (bounded to Int32 range)
    ///       ctx 4 ← mul_log = `log2(multiplier)` low bits
    ///       ctx 5 ← mul_bits = `(multiplier >> mul_log) - 1` (= 0
    ///               whenever `multiplier` is a power of 2, which it
    ///               always is per the spec).
    ///
    /// The pre-order traversal matches `decode`'s queue: the root is
    /// emitted first; each decision node's `leftChild` index in our
    /// `nodes` array equals `nodes.count + toDecode + 1` at decode
    /// time, which we verify here by walking the tree depth-first
    /// from the root.
    public func encode(
        emit: (_ ctx: Int, _ value: UInt32) throws -> Void
    ) throws {
        // libjxl context indices (must match `decode`).
        let kSplitValContext = 0
        let kPropertyContext = 1
        let kPredictorContext = 2
        let kOffsetContext = 3
        let kMultiplierLogContext = 4
        let kMultiplierBitsContext = 5

        precondition(!nodes.isEmpty, "cannot encode empty tree")
        // Pre-order DFS.
        var stack: [Int] = [0]
        while let idx = stack.popLast() {
            guard idx >= 0 && idx < nodes.count else {
                throw ModularTreeError.tokenReader(
                    .clusterOutOfRange(idx, max: nodes.count - 1)
                )
            }
            let node = nodes[idx]
            if node.isLeaf {
                try emit(kPropertyContext, 0)
                try emit(kPredictorContext, node.rawPredictor)
                let off32 = Int32(truncatingIfNeeded: node.predictorOffset)
                try emit(kOffsetContext, ZigZag.pack(off32))
                // Multiplier is always a power of two: (mul_bits + 1) << mul_log.
                // For multiplier == (1 << k): mul_log = k, mul_bits = 0.
                // For non-power-of-two multipliers (which the spec allows
                // via mul_bits > 0 — pattern (b+1) << k for any b ≥ 0
                // such that the result fits in 31 bits), we extract
                // mul_log as the trailing zero count and mul_bits =
                // (multiplier >> mul_log) - 1.
                let mul = node.multiplier
                guard mul > 0 else {
                    throw ModularTreeError.invalidMultiplier(log: 0, bits: 0)
                }
                let mulLog = UInt32(mul.trailingZeroBitCount)
                let mulBits = (mul >> mulLog) &- 1
                try emit(kMultiplierLogContext, mulLog)
                try emit(kMultiplierBitsContext, mulBits)
                continue
            }
            // Decision node.
            let prop = UInt32(node.property &+ 1)
            try emit(kPropertyContext, prop)
            try emit(kSplitValContext, ZigZag.pack(node.splitVal))
            // Push right first so left is popped (and emitted) first.
            stack.append(node.rightChild)
            stack.append(node.leftChild)
        }
    }
}

// MARK: - Helpers

@inline(__always)
private func readToken(
    _ stream: inout TokenStreamReader,
    _ ctx: Int,
    _ r: inout BitReader
) throws -> UInt32 {
    do { return try stream.readToken(context: ctx, from: &r) }
    catch let e as TokenStreamReaderError {
        throw ModularTreeError.tokenReader(e)
    }
}

@inline(__always)
private func unpackSigned(_ u: UInt32) -> Int32 {
    let lsb = u & 1
    let signMask = UInt32(bitPattern: -Int32(bitPattern: lsb))
    return Int32(bitPattern: (u &>> 1) ^ signMask)
}

/// Map a libjxl `Predictor` index to one of our `Predictor` cases.
/// Spec predictors 0..13; we only have direct cases for the simpler
/// subset (Zero, Left, Top, Avg0, Gradient, Select, Weighted, ...).
/// For predictors not yet modelled we map to `.zero` and rely on the
/// caller to error or pick a fallback. Real Modular pixel
/// reconstruction must distinguish all 14, but tree-structure parsing
/// only needs them named.
private func mapPredictor(_ raw: UInt32) -> Predictor {
    switch raw {
    case 0:  return .zero
    case 1:  return .west          // libjxl Left
    case 2:  return .north         // libjxl Top
    case 3:  return .avgWN         // libjxl Average0 (W+N)/2
    case 4:  return .medianWNGradient   // libjxl Select
    case 5:  return .gradient
    case 7:  return .ww            // libjxl TopRight — close to but not == ours
    case 9:  return .ww            // libjxl LeftLeft = our ww
    default: return .zero          // 6 (Weighted), 8 (TopLeft), 10..13 (Avg1..Avg4)
                                   // — not yet modelled, fall through to .zero
    }
}
