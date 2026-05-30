// SpecRCT — full 42-variant Reversible Colour Transform decoder.
//
// ISO/IEC 18181-1 §C.7.7. The spec defines `rct_type` 0..41 — the
// concatenation of:
//
//   • permutation = rct_type / 7 (0..5):
//       0 → RGB (identity output channel order)
//       1 → GBR
//       2 → BRG
//       3 → RBG
//       4 → GRB
//       5 → BGR
//   • custom = rct_type % 7:
//       0 → noop (permutation only)
//       1..5 → Second-then-Third subtract pipeline
//             (Second: 0=nop, 1=SubtractFirst, 2=SubtractAvgFirstThird;
//              Third: 0=nop, 1=SubtractFirst — encoded in the low
//              bits of `custom`)
//       6 → YCoCg-R (the full reversible chroma-luma transform)
//
// Per libjxl `lib/jxl/modular/transform/rct.cc::InvRCT`. **Inverse
// only** — decoder-side. The encoder mirror is the existing
// `RCT.forward(_:channel0:channel1:channel2:)` for the YCoCg-R
// variant; full forward-spec coverage isn't required for this
// decoder milestone.
//
// `inverse(rctType:channel0:channel1:channel2:)` mutates the three
// supplied channel buffers in place. Channels must be the same
// length (all three colour channels at the same wire-level
// resolution after metaApply).

import Foundation

package enum SpecRCTError: Error, Sendable {
    case invalidType(UInt32)
    case mismatchedChannelLengths
}

package enum SpecRCT {

    /// Apply the inverse RCT for `rctType` 0..41 to a triple of
    /// equal-length channel buffers. The buffers are mutated in
    /// place. After return, `(channel0, channel1, channel2)` carries
    /// the post-inverse pixel values in the spec-mandated output
    /// channel order (so for `rct_type` with permutation=0, channel0
    /// holds R, channel1 G, channel2 B).
    package static func inverse(
        rctType: UInt32,
        channel0: inout [Int32],
        channel1: inout [Int32],
        channel2: inout [Int32]
    ) throws {
        guard channel0.count == channel1.count,
              channel1.count == channel2.count else {
            throw SpecRCTError.mismatchedChannelLengths
        }
        guard rctType < 42 else {
            throw SpecRCTError.invalidType(rctType)
        }
        if rctType == 0 {
            return  // Identity / no-op — permutation=0 + custom=0.
        }
        let permutation = Int(rctType / 7)
        let custom = Int(rctType % 7)

        // Apply the per-pixel custom transform to (in0, in1, in2),
        // then permute the outputs into (channel0, channel1, channel2)
        // per `permutation`. Doing the permute LAST (rather than
        // shuffling references upfront) keeps the inner loop simple.
        let n = channel0.count
        let in0 = channel0
        let in1 = channel1
        let in2 = channel2
        var out0 = [Int32](repeating: 0, count: n)
        var out1 = [Int32](repeating: 0, count: n)
        var out2 = [Int32](repeating: 0, count: n)

        if custom == 6 {
            // YCoCg-R inverse — same formula as our existing
            // `RCT.inverse(.ycocgR, ...)`.
            for i in 0..<n {
                let y = in0[i]; let co = in1[i]; let cg = in2[i]
                let tmp = y &- (cg &>> 1)
                let g = cg &+ tmp
                let b = tmp &- (co &>> 1)
                let r = b &+ co
                out0[i] = r; out1[i] = g; out2[i] = b
            }
        } else {
            // Second-then-Third subtract.
            // `second` = custom >> 1: 0=nop, 1=SubtractFirst,
            //                          2=SubtractAvgFirstThird.
            // `third`  = custom &  1: 0=nop, 1=SubtractFirst.
            let second = custom >> 1
            let third = custom & 1
            for i in 0..<n {
                let first = in0[i]
                var secondV = in1[i]
                var thirdV = in2[i]
                if third == 1 { thirdV = thirdV &+ first }
                if second == 1 {
                    secondV = secondV &+ first
                } else if second == 2 {
                    secondV = secondV &+ ((first &+ thirdV) &>> 1)
                }
                out0[i] = first
                out1[i] = secondV
                out2[i] = thirdV
            }
        }

        // Permute to spec output channel order.
        // `permutation`: 0=RGB, 1=GBR, 2=BRG, 3=RBG, 4=GRB, 5=BGR.
        // libjxl writes output to indices:
        //   permutation % 3
        //   (permutation + 1 + permutation/3) % 3
        //   (permutation + 2 - permutation/3) % 3
        let idx0 = permutation % 3
        let idx1 = (permutation + 1 + permutation / 3) % 3
        let idx2 = (permutation + 2 - permutation / 3) % 3
        var dst: [[Int32]] = [Array(repeating: 0, count: n),
                              Array(repeating: 0, count: n),
                              Array(repeating: 0, count: n)]
        dst[idx0] = out0
        dst[idx1] = out1
        dst[idx2] = out2
        channel0 = dst[0]
        channel1 = dst[1]
        channel2 = dst[2]
    }
}
