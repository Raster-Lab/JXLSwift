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
    case tokenAtPosition(x: Int, y: Int, inner: TokenStreamReaderError)
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
    @inline(__always) func at(_ x: Int, _ y: Int) -> Int32 {
        out[y * width + x]
    }
    // Property neighbours (libjxl uses simple zero fall-backs at the
    // edges for FillProperties — i.e. property values are derived from
    // *signed* pixel arithmetic with 0 substituted out of range; this
    // is *different* from the prediction neighbour fall-backs which
    // substitute the available neighbour). Match libjxl's behaviour.
    @inline(__always) func neighbourValue(_ x: Int, _ y: Int) -> Int32 {
        if x < 0 || y < 0 || x >= width || y >= height { return 0 }
        return at(x, y)
    }
    var wp = WeightedPredictor(header: wpHeader, xsize: width)
    for y in 0..<height {
        for x in 0..<width {
            let top      = neighbourValue(x,     y - 1)
            let left     = neighbourValue(x - 1, y)
            let topLeft  = neighbourValue(x - 1, y - 1)
            let topRight = neighbourValue(x + 1, y - 1)
            let topTop   = neighbourValue(x,     y - 2)
            let leftLeft = neighbourValue(x - 2, y)
            // Compute property 15 (WP property) BEFORE running predict
            // — libjxl `FillProperties` reads `WeightedPredictor::
            // PropertyValue` first, *then* invokes Predict if the leaf's
            // predictor is Weighted.
            let wpProp = wp.propertyValue(x: x, y: y, xsize: width)
            let props = computeModularProperties(
                staticChannel: staticChannel, groupId: groupId,
                x: Int32(x), y: Int32(y),
                top: top, left: left,
                topLeft: topLeft, topRight: topRight,
                leftLeft: leftLeft, topTop: topTop,
                wpProperty: wpProp
            )
            let leaf: ModularTreeNode
            do { leaf = try tree.walk(properties: props) }
            catch let e as ModularTreeError {
                throw ModularChannelDecoderError.treeWalk(e)
            }
            let token: UInt32
            do { token = try stream.readToken(context: leaf.leafId, from: &r) }
            catch let e as TokenStreamReaderError {
                throw ModularChannelDecoderError.tokenAtPosition(
                    x: x, y: y, inner: e
                )
            }
            // Predictor neighbourhood — substitute available
            // neighbours at edges (different rules from properties).
            let nbh = Neighbourhood(at: x, y, in: out, width: width)
            // Always run WP.predict so the state stays in sync, even
            // if the leaf doesn't use predictor 6. (libjxl drives WP
            // unconditionally for any tree that *might* use it; we
            // mirror that by always running predict + update.)
            let wpPred = wp.predict(
                x: x, y: y, xsize: width,
                n: top, w: left, ne: topRight, nw: topLeft, nn: topTop
            )
            let predicted = applyLibjxlPredictor(
                raw: leaf.rawPredictor, neighbourhood: nbh, wpResult: wpPred
            )
            let signedRes = ZigZag.unpack(token)
            let scaled = Int32(truncatingIfNeeded:
                Int64(signedRes) &* Int64(leaf.multiplier))
            let value = Int32(truncatingIfNeeded:
                Int64(predicted)
                &+ Int64(leaf.predictorOffset)
                &+ Int64(scaled))
            out[y * width + x] = value
            wp.update(actual: value, x: x, y: y, xsize: width)
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
