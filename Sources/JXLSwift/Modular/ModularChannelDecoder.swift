// ModularChannelDecoder — drives the per-pixel decode loop for one
// Modular channel using a decoded MA-tree + a token stream reader.
//
// ISO/IEC 18181-1 §C.7 (libjxl `lib/jxl/modular/encoding/encoding.cc::
// DecodeModularChannelMAANS`). For each pixel `(x, y)`, the decoder:
//
//   1. Reads the 4-/6-neighbour patch from the partial channel buffer.
//   2. Computes the 16 standard properties (`ModularProperties.swift`).
//   3. Walks the MA-tree to find the leaf node whose context governs
//      this pixel's residual (`ModularTree.walk`).
//   4. Pulls a HybridUint-decoded token from the post-tree
//      `TokenStreamReader` at `context = leaf.leafId`.
//   5. Recovers the signed residual: `r = unpackSigned(token) * leaf.multiplier`.
//   6. Applies the leaf's predictor (with `leaf.predictorOffset` added):
//      `pixel = predictorOutput + leaf.predictorOffset + r`.
//
// **Limitations** at this point:
//   • Predictor 6 (Weighted) returns 0 — see `LibjxlPredictor.swift`.
//     Pixels gated on it decode incorrectly until the WP state machine
//     is wired through.
//   • Property 15 (kWPProp, weighted-predictor property) is also 0
//     in `computeModularProperties`; trees branching on it pick the
//     wrong leaf.
//   • Edge fall-backs follow `Neighbourhood.init(at:_:in:width:)`'s
//     spec-aligned rules: missing W/N substitute the available
//     neighbour or 0.
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
}

/// Decode one Modular channel. `width × height` pixel values fill
/// `out` in row-major order. `staticChannel` and `groupId` are the
/// values libjxl uses for properties 0 and 1 — pass the correct
/// indices so trees branching on those properties decode correctly.
public func decodeModularChannel(
    width: Int, height: Int,
    staticChannel: Int32, groupId: Int32,
    tree: ModularTree,
    stream: inout TokenStreamReader,
    from r: inout BitReader,
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
    for y in 0..<height {
        for x in 0..<width {
            let top      = neighbourValue(x,     y - 1)
            let left     = neighbourValue(x - 1, y)
            let topLeft  = neighbourValue(x - 1, y - 1)
            let topRight = neighbourValue(x + 1, y - 1)
            let topTop   = neighbourValue(x,     y - 2)
            let leftLeft = neighbourValue(x - 2, y)
            let props = computeModularProperties(
                staticChannel: staticChannel, groupId: groupId,
                x: Int32(x), y: Int32(y),
                top: top, left: left,
                topLeft: topLeft, topRight: topRight,
                leftLeft: leftLeft, topTop: topTop
            )
            let leaf: ModularTreeNode
            do { leaf = try tree.walk(properties: props) }
            catch let e as ModularTreeError {
                throw ModularChannelDecoderError.treeWalk(e)
            }
            // Read residual token at this leaf's context.
            let token: UInt32
            do { token = try stream.readToken(context: leaf.leafId, from: &r) }
            catch let e as TokenStreamReaderError {
                throw ModularChannelDecoderError.tokenReader(e)
            }
            // Predictor neighbourhood fall-backs are different from
            // FillProperties' zero substitution: they substitute
            // available neighbours.
            let nbh = Neighbourhood(at: x, y, in: out, width: width)
            let predicted = applyLibjxlPredictor(
                raw: leaf.rawPredictor, neighbourhood: nbh
            )
            let signedRes = ZigZag.unpack(token)
            let scaled = Int32(truncatingIfNeeded:
                Int64(signedRes) &* Int64(leaf.multiplier))
            let value = Int32(truncatingIfNeeded:
                Int64(predicted)
                &+ Int64(leaf.predictorOffset)
                &+ Int64(scaled))
            out[y * width + x] = value
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
    from r: inout BitReader
) throws -> [Int32] {
    var buf = [Int32](repeating: 0, count: width * height)
    try decodeModularChannel(
        width: width, height: height,
        staticChannel: staticChannel, groupId: groupId,
        tree: tree, stream: &stream, from: &r, out: &buf
    )
    return buf
}
