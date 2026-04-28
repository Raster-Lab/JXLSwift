// Predictors — per-pixel prediction for the Modular sub-codec.
//
// ISO/IEC 18181-1 §C.7.5. The Modular path encodes a residual
// (`actual - predicted`) instead of the raw pixel; predictions
// exploit correlation with already-decoded neighbours so residuals
// cluster near zero and entropy-code more efficiently. The decoder
// applies the same predictor function on the same neighbourhood,
// then recovers `actual = predicted + residual`.
//
// Standard JXL predictors operate on these neighbours of pixel (x, y),
// where each value is the previously-decoded pixel at that offset:
//
//                     NW   N   NE
//                      W   ?
//
// W  = pixel at (x - 1, y)        — west / left
// N  = pixel at (x,     y - 1)    — north / above
// NW = pixel at (x - 1, y - 1)
// NE = pixel at (x + 1, y - 1)
//
// At image edges some neighbours are unavailable; the spec defines
// fall-backs (zero, or the available neighbour) which are encoded in
// the `Neighbourhood` helper below.
//
// **Predictors implemented here:**
//
// | Name           | Formula                              |
// |----------------|--------------------------------------|
// | zero           | 0                                    |
// | west           | W                                    |
// | north          | N                                    |
// | avgWN          | (W + N) / 2  (rounded)               |
// | gradient       | clamp(W + N − NW, lo, hi)            |
// | medianWNGradient (a.k.a. MED) | median(W, N, W + N − NW) |
//
// Higher-order predictors (`Self`, `SelectGradient`, etc.) and the
// per-pixel adaptive selection driven by the MA-tree (§C.7.4) are
// future work. The MA-tree decides which predictor each pixel uses;
// without it we have to pick one fixed predictor per channel.
//
// Operates on `Int32` pixels — wide enough for any 16-bit image and
// signed so subtraction can produce negative residuals before
// zig-zag encoding.

import Foundation

/// Identifies which predictor to apply.
public enum Predictor: Sendable, Equatable {
    case zero
    case west
    case north
    case avgWN
    case gradient
    case medianWNGradient
    /// `WW` — pixel two columns to the west, useful for column-period-2
    /// patterns and for completing the neighbourhood when prediction
    /// from W alone produces too much error.
    case ww
    /// `NN` — pixel two rows above; symmetric counterpart to `ww`.
    case nn
}

/// Bit-level tag for serialising a `Predictor` choice into the
/// codestream. The slot space is u(3) — 8 values; 6 are
/// definitively used and 2 are reserved for future spec-aligned
/// predictors.
public enum PredictorID: UInt32, Sendable, Equatable, CaseIterable {
    case zero             = 0
    case west             = 1
    case north            = 2
    case avgWN            = 3
    case gradient         = 4
    case medianWNGradient = 5
    case ww               = 6
    case nn               = 7

    /// The `Predictor` this ID names.
    public var predictor: Predictor {
        switch self {
        case .zero:             return .zero
        case .west:             return .west
        case .north:            return .north
        case .avgWN:            return .avgWN
        case .gradient:         return .gradient
        case .medianWNGradient: return .medianWNGradient
        case .ww:               return .ww
        case .nn:               return .nn
        }
    }
}

/// A 4-neighbour patch around a pixel plus the second-order WW/NN
/// values for higher-order predictors. Use `init(at:in:)` to read
/// from an `Int32` 2-D buffer with edge fall-backs.
public struct Neighbourhood: Sendable, Equatable {
    public let w:  Int32   // west
    public let n:  Int32   // north
    public let nw: Int32   // north-west
    public let ne: Int32   // north-east
    public let ww: Int32   // 2 columns west (= west of west)
    public let nn: Int32   // 2 rows north (= north of north)

    public init(w: Int32, n: Int32, nw: Int32, ne: Int32,
                ww: Int32 = 0, nn: Int32 = 0) {
        self.w = w; self.n = n; self.nw = nw; self.ne = ne
        self.ww = ww; self.nn = nn
    }

    /// Read the 4-neighbour patch around `(x, y)` from `buffer`,
    /// applying the spec's edge fall-backs:
    ///
    ///   • If a neighbour falls outside the image, substitute another
    ///     neighbour: prefer W, then N. If neither exists (top-left
    ///     pixel) substitute 0.
    ///   • `WW` falls back to W when only one column exists west;
    ///     `NN` falls back to N when only one row exists north.
    ///
    /// `buffer.count` must equal `width * height` and entries are
    /// row-major.
    public init(at x: Int, _ y: Int, in buffer: [Int32], width: Int) {
        let height = buffer.count / width
        precondition(x >= 0 && x < width, "x out of bounds")
        precondition(y >= 0 && y < height, "y out of bounds")

        @inline(__always) func at(_ x: Int, _ y: Int) -> Int32 {
            buffer[y * width + x]
        }

        let hasW  = x - 1 >= 0
        let hasN  = y - 1 >= 0
        let hasNW = hasW && hasN
        let hasNE = (x + 1 < width) && hasN
        let hasWW = x - 2 >= 0
        let hasNN = y - 2 >= 0

        let wVal:  Int32 = hasW  ? at(x - 1, y)     : (hasN ? at(x, y - 1) : 0)
        let nVal:  Int32 = hasN  ? at(x, y - 1)     : wVal
        let nwVal: Int32 = hasNW ? at(x - 1, y - 1) : (hasW ? wVal : nVal)
        let neVal: Int32 = hasNE ? at(x + 1, y - 1) : nVal
        let wwVal: Int32 = hasWW ? at(x - 2, y)     : wVal
        let nnVal: Int32 = hasNN ? at(x, y - 2)     : nVal

        self.w = wVal; self.n = nVal; self.nw = nwVal; self.ne = neVal
        self.ww = wwVal; self.nn = nnVal
    }
}

extension Predictor {

    /// Apply this predictor to a 4-neighbour patch and return the
    /// predicted value. The caller's responsibility to clamp into
    /// the channel's representable range *afterwards* (only the
    /// `gradient` and `medianWNGradient` predictors clamp internally).
    public func apply(to nbh: Neighbourhood,
                      lo: Int32 = .min, hi: Int32 = .max) -> Int32 {
        switch self {
        case .zero:
            return 0
        case .west:
            return nbh.w
        case .north:
            return nbh.n
        case .avgWN:
            // Rounding-down division is fine — encoder and decoder
            // use the same formula, so any consistent rounding works.
            return (nbh.w &+ nbh.n) &>> 1
        case .gradient:
            // W + N − NW, clamped into [min(W,N), max(W,N)].
            let g = nbh.w &+ nbh.n &- nbh.nw
            let mn = min(nbh.w, nbh.n)
            let mx = max(nbh.w, nbh.n)
            return min(max(g, mn), mx).clamped(lo: lo, hi: hi)
        case .medianWNGradient:
            // median(W, N, W + N − NW).
            let g = nbh.w &+ nbh.n &- nbh.nw
            return medianOf3(nbh.w, nbh.n, g).clamped(lo: lo, hi: hi)
        case .ww:
            return nbh.ww
        case .nn:
            return nbh.nn
        }
    }
}

// MARK: - ZigZag signed-integer pack/unpack
//
// JXL Modular emits signed residuals (`actual - predicted`) into a
// HybridUint+rANS pipeline that only handles unsigned values. The
// standard re-mapping is *zig-zag*: 0 → 0, -1 → 1, 1 → 2, -2 → 3,
// 2 → 4, … This packs small-magnitude signed integers into small
// unsigned tokens regardless of sign, which is exactly what the
// entropy coder needs for the cluster-near-zero residual
// distributions that prediction produces.

public enum ZigZag {

    /// Pack a signed `Int32` into its unsigned zig-zag representation.
    /// `pack(0)=0, pack(-1)=1, pack(1)=2, pack(-2)=3, pack(2)=4, …`.
    @inline(__always)
    public static func pack(_ v: Int32) -> UInt32 {
        // Standard formula: (v << 1) ^ (v >> 31). The arithmetic
        // shift produces 0 for non-negative v and -1 (all bits set)
        // for negative v; XOR-ing flips bits when v < 0.
        let signMask = UInt32(bitPattern: v &>> 31)
        return UInt32(bitPattern: v &<< 1) ^ signMask
    }

    /// Inverse of `pack`. Given a zig-zag-encoded `UInt32`, recover
    /// the original signed value.
    @inline(__always)
    public static func unpack(_ u: UInt32) -> Int32 {
        // (u >> 1) ^ -(u & 1)   — when u is odd, negate after shift.
        let lsb = u & 1
        let signMask = UInt32(bitPattern: -Int32(bitPattern: lsb))
        return Int32(bitPattern: (u &>> 1) ^ signMask)
    }
}

// MARK: - Helpers

private extension Int32 {
    @inline(__always)
    func clamped(lo: Int32, hi: Int32) -> Int32 {
        Swift.min(Swift.max(self, lo), hi)
    }
}

@inline(__always)
private func medianOf3(_ a: Int32, _ b: Int32, _ c: Int32) -> Int32 {
    // median = a + b + c - max(a,b,c) - min(a,b,c)
    return a &+ b &+ c
         &- Swift.max(a, Swift.max(b, c))
         &- Swift.min(a, Swift.min(b, c))
}
