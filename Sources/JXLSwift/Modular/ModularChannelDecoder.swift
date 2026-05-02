// ModularChannelDecoder — drives the per-pixel decode loop for one
// Modular channel using a decoded MA-tree + a token stream reader.
//
// ISO/IEC 18181-1 §C.7 (libjxl `lib/jxl/modular/encoding/encoding.cc::
// DecodeModularChannelMAANS`). For each pixel `(x, y)`, the decoder:
//
//   1. Reads the 4-/6-neighbour patch from the partial channel buffer.
//   2. Computes the WP property from the running weighted-predictor
//      state, then the 16 standard properties (`ModularProperties`).
//   3. Walks the MA-tree to find the leaf node whose context governs
//      this pixel's residual (`ModularTree.walk`).
//   4. Pulls a HybridUint-decoded token from the post-tree
//      `TokenStreamReader` at `context = leaf.leafId`.
//   5. Recovers the signed residual: `r = unpackSigned(token) * leaf.multiplier`.
//   6. Applies the leaf's predictor (with `leaf.predictorOffset` added):
//      `pixel = predictorOutput + leaf.predictorOffset + r`. Predictor
//      6 (Weighted) sources its prediction from the WP state machine.
//   7. Updates the WP state with the actual decoded pixel value.
//
// **Edge fall-backs** for prediction neighbours follow `Neighbourhood.
// init(at:_:in:width:)`'s spec-aligned rules: missing W/N substitute
// the available neighbour or 0. **Property-computation** neighbours
// substitute 0 (matching libjxl `FillProperties`).
//
// The decoder does NOT apply Modular Transforms (RCT, Squeeze,
// Palette) — those operate on the assembled channel arrays as a
// post-step (`Modular/RCT.swift`, `Squeeze.swift`). This component
// only fills the raw per-channel sample arrays the spec calls for
// before the inverse transform pass.

import Foundation

public enum ModularChannelDecoderError: Error, Sendable {
    case invalidPredictor(UInt32)
    case tokenReader(TokenStreamReaderError)
    case treeWalk(ModularTreeError)
    case tokenOutOfRange(token: UInt32, leafId: Int)
    /// Wraps a token-read error with the (x, y) position where it
    /// occurred — useful for diagnostics when the decoder gives up.
    case tokenAtPosition(x: Int, y: Int, channel: Int32, inner: TokenStreamReaderError)
}

/// Decode one Modular channel. `width × height` pixel values fill
/// `out` in row-major order. `staticChannel` and `groupId` are the
/// values libjxl uses for properties 0 and 1 — pass the correct
/// indices so trees branching on those properties decode correctly.
/// `wpHeader` parameterises the weighted predictor (predictor 6 +
/// property 15); pass the parsed `WeightedPredictorHeader` from the
/// frame's `GroupHeader`.
public func decodeModularChannel(
    width: Int, height: Int,
    staticChannel: Int32, groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default,
    out: inout [Int32]
) throws {
    precondition(out.count == width * height,
                 "out must be sized width*height")
    var wp = WeightedPredictor(header: wpHeader, xsize: width)
    // Hoist the env-var check out of the per-pixel loop — looking it
    // up via `ProcessInfo.processInfo.environment` 16M times in a
    // 4096² decode dominated runtime.
    let traceEnabled = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
    // Reused 16-element properties array — allocating a fresh
    // `[Int32]` per pixel was a measurable hot spot.
    var props = [Int32](repeating: 0, count: 16)
    // Tree-walk fast path: when there's exactly one leaf, every
    // pixel routes to that leaf with no property lookup needed.
    let isSingleLeafTree = (tree.nodes.count == 1 && tree.nodes[0].isLeaf)
    let singleLeaf = tree.nodes[0]
    // WP fast-path: if no leaf uses predictor 6 (Weighted) AND no
    // decision node branches on property 15 (the WP property), we
    // can skip both `wp.propertyValue` and the heavyweight
    // `wp.predict`/`wp.update` entirely. libjxl makes the same
    // decision via its `is_wp_only` / `tree_has_wp_prop_or_pred`
    // flags in `DecodeModularChannelMAANS`.
    var treeUsesWP = false
    for node in tree.nodes {
        if node.isLeaf {
            if node.rawPredictor == 6 { treeUsesWP = true; break }
        } else if node.property == 15 {
            treeUsesWP = true; break
        }
    }
    try out.withUnsafeMutableBufferPointer { outBuf in
        for y in 0..<height {
            for x in 0..<width {
                // libjxl edge fall-backs (per `lib/jxl/modular/encoding/
                // context_predict.h::Predict`):
                //   left:     x>0 ? pp[-1] : (y>0 ? pp[-onerow] : 0)
                //   top:      y>0 ? pp[-onerow] : left
                //   topleft:  (x && y) ? pp[-1-onerow] : left
                //   topright: (x+1<w && y) ? pp[1-onerow] : top
                //   leftleft: x>1 ? pp[-2] : left
                //   toptop:   y>1 ? pp[-2*onerow] : top
                let rowBase = y * width
                let prevRow = (y - 1) * width
                let prev2Row = (y - 2) * width
                let left: Int32
                if x > 0 {
                    left = outBuf[rowBase + x - 1]
                } else if y > 0 {
                    left = outBuf[prevRow + x]
                } else {
                    left = 0
                }
                let top: Int32 = y > 0 ? outBuf[prevRow + x] : left
                let topLeft: Int32 = (x > 0 && y > 0)
                    ? outBuf[prevRow + x - 1] : left
                let topRight: Int32 = (x + 1 < width && y > 0)
                    ? outBuf[prevRow + x + 1] : top
                let leftLeft: Int32 = x > 1 ? outBuf[rowBase + x - 2] : left
                let topTop: Int32 = y > 1 ? outBuf[prev2Row + x] : top
                // Property 15 (WP property) only needed when the tree
                // branches on it OR uses predictor 6 — `treeUsesWP`
                // captures both. Skipping `wp.propertyValue` for
                // non-WP trees saves a per-pixel function call.
                let wpProp: Int32 = treeUsesWP
                    ? wp.propertyValue(x: x, y: y, xsize: width)
                    : 0
                let leaf: ModularTreeNode
                if isSingleLeafTree {
                    // Skip the property fill + tree walk entirely.
                    leaf = singleLeaf
                } else {
                    fillModularProperties(
                        into: &props,
                        staticChannel: staticChannel, groupId: groupId,
                        x: Int32(x), y: Int32(y),
                        top: top, left: left,
                        topLeft: topLeft, topRight: topRight,
                        leftLeft: leftLeft, topTop: topTop,
                        wpProperty: wpProp
                    )
                    do { leaf = try tree.walk(properties: props) }
                    catch let e as ModularTreeError {
                        throw ModularChannelDecoderError.treeWalk(e)
                    }
                }
                let token: UInt32
                do {
                    token = try stream.readToken(
                        context: leaf.leafId, from: &r
                    )
                } catch let e as TokenStreamReaderError {
                    throw ModularChannelDecoderError.tokenAtPosition(
                        x: x, y: y, channel: staticChannel, inner: e
                    )
                }
                // Predictor neighbourhood — substitute available
                // neighbours at edges (different rules from properties).
                let nbh = Neighbourhood(
                    w: left, n: top, nw: topLeft, ne: topRight,
                    ww: leftLeft, nn: topTop
                )
                // Run WP only when the tree might consult it. For the
                // common default-tree case (single leaf, predictor 5
                // = Gradient) WP is dead work and skipping it gives a
                // significant per-pixel speedup.
                let wpPred: Int32
                if treeUsesWP {
                    wpPred = wp.predict(
                        x: x, y: y, xsize: width,
                        n: top, w: left,
                        ne: topRight, nw: topLeft, nn: topTop
                    )
                } else {
                    wpPred = 0
                }
                let predicted = applyLibjxlPredictor(
                    raw: leaf.rawPredictor, neighbourhood: nbh,
                    wpResult: wpPred
                )
                let signedRes = ZigZag.unpack(token)
                let scaled = Int32(truncatingIfNeeded:
                    Int64(signedRes) &* Int64(leaf.multiplier))
                let value = Int32(truncatingIfNeeded:
                    Int64(predicted)
                    &+ Int64(leaf.predictorOffset)
                    &+ Int64(scaled))
                outBuf[rowBase + x] = value
                if traceEnabled, x < 4, y == 0 {
                    let msg = "TRACE pixel ch=\(staticChannel) (\(x),\(y)) leaf=\(leaf.leafId) rawPred=\(leaf.rawPredictor) wpPred=\(wpPred) predicted=\(predicted) token=\(token) residual=\(signedRes) value=\(value)\n"
                    FileHandle.standardError.write(Data(msg.utf8))
                }
                if treeUsesWP {
                    wp.update(actual: value, x: x, y: y, xsize: width)
                }
            }
        }
    }
}

/// Convenience: decode one Modular channel into a fresh `[Int32]`
/// buffer. See `decodeModularChannel(...)` for parameter semantics.
public func decodeModularChannel(
    width: Int, height: Int,
    staticChannel: Int32, groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default
) throws -> [Int32] {
    var buf = [Int32](repeating: 0, count: width * height)
    try decodeModularChannel(
        width: width, height: height,
        staticChannel: staticChannel, groupId: groupId,
        tree: tree, stream: &stream, from: &r,
        wpHeader: wpHeader, out: &buf
    )
    return buf
}

/// One channel's geometry for `decodeAllChannels(...)`. `width` and
/// `height` are post-shift dimensions (i.e., already accounting for
/// `hshift` / `vshift` in chroma-subsampled inputs).
public struct ModularChannelGeometry: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Decode every channel listed in `channels` from a single shared
/// `TokenStreamReader`. Each channel gets its own fresh
/// `WeightedPredictor` state (the WP arrays are per-channel, not
/// shared). Channel index becomes property 0 (`staticChannel`); pass
/// the same `groupId` for all channels in a group.
///
/// Returns one `[Int32]` buffer per input channel, in the same order.
public func decodeAllChannels(
    channels: [ModularChannelGeometry],
    groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
    wpHeader: WeightedPredictorHeader = .default
) throws -> [[Int32]] {
    var out = [[Int32]]()
    out.reserveCapacity(channels.count)
    for (i, g) in channels.enumerated() {
        let buf = try decodeModularChannel(
            width: g.width, height: g.height,
            staticChannel: Int32(i), groupId: groupId,
            tree: tree, stream: &stream, from: &r, wpHeader: wpHeader
        )
        out.append(buf)
    }
    return out
}
