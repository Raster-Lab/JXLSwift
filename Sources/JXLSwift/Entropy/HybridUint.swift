// HybridUint — variable-length integer encoding (ISO/IEC 18181-1 §C.5).
//
// JPEG XL's entropy-coded streams don't directly emit arbitrary 32-bit
// values — they emit *tokens* (small integers from a finite alphabet)
// plus zero or more "extra bits" raw. This split lets entropy coders
// like rANS or prefix codes work over a manageable alphabet (typically
// ≤ 256 tokens) while still representing values up to 2^32.
//
// The split is parameterised by `HybridUintConfig`:
//
//     split_exponent  threshold below which the token == value directly
//     msb_in_token    number of high bits of large values folded into the token
//     lsb_in_token    number of low bits of large values folded into the token
//
// For value < (1 << split_exponent):
//     token = value
//     extra_bits = 0
//
// For value ≥ (1 << split_exponent):
//     n = position of the highest set bit (so 2^n ≤ value < 2^(n+1))
//     m = value - 2^n                          // value with leading 1 stripped
//     token = (1 << split_exponent)
//           + ((n - split_exponent) << (msb_in_token + lsb_in_token))
//           + ((m >> (n - msb_in_token)) << lsb_in_token)
//           + (m & ((1 << lsb_in_token) - 1))
//     extra_nbits = n - msb_in_token - lsb_in_token
//     extra_bits  = (m >> lsb_in_token) & ((1 << extra_nbits) - 1)
//
// The decoder runs the same formula in reverse: take a token, derive
// `n` and `m`, read `extra_nbits` from the stream, recompose the value.
//
// References:
//   • ISO/IEC 18181-1 §C.5
//   • libjxl HybridUintConfig (lib/jxl/dec_ans.h, lib/jxl/enc_ans.cc)

import Foundation

public struct HybridUintConfig: Sendable, Equatable {
    public let splitExponent: Int    // 0...15 in practice; 0...30 in theory
    public let msbInToken: Int       // 0...splitExponent
    public let lsbInToken: Int       // 0...splitExponent - msbInToken

    public init(splitExponent: Int, msbInToken: Int = 0, lsbInToken: Int = 0) {
        precondition(splitExponent >= 0 && splitExponent <= 30,
                     "split_exponent must be 0..30")
        precondition(msbInToken >= 0 && msbInToken <= splitExponent,
                     "msb_in_token must be 0..split_exponent")
        precondition(lsbInToken >= 0 && lsbInToken <= splitExponent - msbInToken,
                     "lsb_in_token must be 0..(split_exponent - msb_in_token)")
        self.splitExponent = splitExponent
        self.msbInToken = msbInToken
        self.lsbInToken = lsbInToken
    }

    /// libjxl's default for many distributions: a balanced 4/2/0 split
    /// that gives a 16-symbol "literal" range and packs MSB pairs into
    /// the token.
    public static let defaultConfig = HybridUintConfig(
        splitExponent: 4, msbInToken: 2, lsbInToken: 0
    )

    /// "Trivial" config with split_exponent = 4 and no MSB/LSB folding —
    /// values below 16 encode directly, larger values use a single token
    /// per "bit class" plus extra bits.
    public static let raw4 = HybridUintConfig(
        splitExponent: 4, msbInToken: 0, lsbInToken: 0
    )

    /// Maximum token value this config can produce. The token alphabet is
    /// `[0, maxToken]`. Used by the entropy coder to size its distribution.
    public var maxToken: Int {
        // For value up to 2^maxValueBits - 1 the largest token comes from
        // n = maxValueBits - 1, m = 2^n - 1.
        // Token = (1 << splitExp) + ((n - splitExp) << (msb + lsb))
        //       + ((m >> (n - msb)) << lsb) + (m & ((1<<lsb) - 1))
        // The largest token grows roughly as 2^splitExp + (32 - splitExp).
        // The library bound is alphabet ≤ 256, so:
        return (1 << splitExponent) + ((32 - splitExponent) << (msbInToken + lsbInToken)) - 1
    }
}

/// One step's output of HybridUint encoding: a token (used by the
/// entropy coder) and the raw extra bits to emit after the token.
public struct HybridUintToken: Sendable, Equatable {
    public let token: UInt32
    public let extraBits: UInt32
    public let extraNBits: Int
}

extension HybridUintConfig {

    /// Encode a value into (token, extra_bits, extra_nbits). The caller
    /// is responsible for emitting the token via the entropy coder and
    /// then writing `extra_nbits` of `extra_bits` to the bit writer.
    public func encode(_ value: UInt32) -> HybridUintToken {
        let split = UInt32(1) &<< UInt32(splitExponent)
        if value < split {
            return HybridUintToken(token: value, extraBits: 0, extraNBits: 0)
        }
        // Position of MSB of value: n = floor(log2(value)).
        let n = Int(31 - value.leadingZeroBitCount)
        let m = value &- (UInt32(1) &<< UInt32(n))
        // Number of bits that go into the token via msbInToken folding.
        let nMinusMsb = n &- msbInToken
        let msbBits = (m &>> UInt32(nMinusMsb)) & ((UInt32(1) &<< UInt32(msbInToken)) &- (msbInToken == 0 ? 0 : 1))
        let lsbMask: UInt32 = lsbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(lsbInToken)) &- 1
        let lsbBits = m & lsbMask

        let nMinusSplit = UInt32(n &- splitExponent)
        let msbLsb = UInt32(msbInToken + lsbInToken)
        let token: UInt32 =
            split
            + (nMinusSplit &<< msbLsb)
            + (msbBits &<< UInt32(lsbInToken))
            + lsbBits

        let extraN = n &- msbInToken &- lsbInToken
        let extraMask: UInt32
        if extraN >= 32 {
            extraMask = .max
        } else if extraN <= 0 {
            extraMask = 0
        } else {
            extraMask = (UInt32(1) &<< UInt32(extraN)) &- 1
        }
        let extraBits: UInt32 = lsbInToken == 0
            ? (m &>> UInt32(0)) & extraMask        // tendency: lsbInToken=0 is common
            : (m &>> UInt32(lsbInToken)) & extraMask

        return HybridUintToken(token: token, extraBits: extraBits, extraNBits: max(0, extraN))
    }

    /// Decode a value: given the token (already pulled from the entropy
    /// coder) and the bit reader (positioned at the extra-bits payload),
    /// recover the original value. Reads `extra_nbits` bits from `r` for
    /// large tokens; small tokens read 0 bits.
    public func decode(token: UInt32, from r: inout BitReader) throws -> UInt32 {
        let split = UInt32(1) &<< UInt32(splitExponent)
        if token < split {
            return token
        }
        let msbLsb = UInt32(msbInToken + lsbInToken)
        let rest = token &- split
        let nMinusSplit = Int(rest &>> msbLsb)
        // n - msb_in_token - lsb_in_token = number of extra bits to read.
        let nExtra = nMinusSplit &+ splitExponent &- msbInToken &- lsbInToken
        let extra = nExtra > 0 ? try r.read(bits: nExtra) : 0
        // Unpack the MSB/LSB fields baked into the token.
        let lsbMask: UInt32 = lsbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(lsbInToken)) &- 1
        let lsbBits = token & lsbMask
        let msbMask: UInt32 = msbInToken == 0 ? 0 : (UInt32(1) &<< UInt32(msbInToken)) &- 1
        let msbBits = (token &>> UInt32(lsbInToken)) & msbMask
        let n = nMinusSplit &+ splitExponent
        // m = (msbBits << (n - msb_in_token)) | (extra << lsb_in_token) | lsbBits
        let m: UInt32 =
            (msbBits &<< UInt32(n &- msbInToken))
            | (extra &<< UInt32(lsbInToken))
            | lsbBits
        return (UInt32(1) &<< UInt32(n)) &+ m
    }
}
