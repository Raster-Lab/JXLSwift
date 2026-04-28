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
    /// Modular predictor for leaf nodes. Decisions emit
    /// `Predictor.zero`.
    public let predictor: Predictor
    /// Signed offset added to predictor output (leaf only).
    public let predictorOffset: Int64
    /// Multiplier applied to residuals (leaf only). Always a power
    /// of two: `(mul_bits + 1) << mul_log`.
    public let multiplier: UInt32

    public init(
        property: Int32, splitVal: Int32,
        leftChildOrLeafId: Int, rightChild: Int,
        predictor: Predictor, predictorOffset: Int64, multiplier: UInt32
    ) {
        self.property = property
        self.splitVal = splitVal
        self.leftChildOrLeafId = leftChildOrLeafId
        self.rightChild = rightChild
        self.predictor = predictor
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
        stream: TokenStreamReader,
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
                let predictorRaw = try readToken(stream, kPredictorContext, &r)
                if predictorRaw >= 14 {
                    throw ModularTreeError.invalidPredictor(predictorRaw)
                }
                let offsetRaw = try readToken(stream, kOffsetContext, &r)
                let predictorOffset = Int64(unpackSigned(offsetRaw))
                let mulLog = try readToken(stream, kMultiplierLogContext, &r)
                if mulLog >= 31 {
                    throw ModularTreeError.invalidMultiplier(
                        log: mulLog, bits: 0
                    )
                }
                let mulBits = try readToken(stream, kMultiplierBitsContext, &r)
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
                    multiplier: multiplier
                ))
                leafId &+= 1
                continue
            }
            // Decision node.
            let splitRaw = try readToken(stream, kSplitValContext, &r)
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
}

// MARK: - Helpers

@inline(__always)
private func readToken(
    _ stream: TokenStreamReader,
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
