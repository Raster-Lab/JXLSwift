// ACStrategy — block-shape choice for VarDCT frames.
//
// VarDCT covers each 8×8 image cell with one of 27 block shapes
// (libjxl `enc_ac_strategy.h`/`AcStrategy`). Each shape is a
// `(width, height)` of 8-pixel cells with a specific DCT layout —
// e.g. `DCT8x8` is a single 8×8 block; `DCT16x16` is a 16×16 block
// covering 4 cells; `DCT4x8` and `DCT8x4` split an 8×8 cell into
// two halves; `IDENTITY` skips the DCT entirely (raw pixel mode
// for sharp edges).
//
// **Status**: enum + dimensional helpers only. The actual per-
// strategy DCT cascades and de-quant matrices land alongside the
// VarDCT decoder pixel pipeline.
//
// Spec reference: ISO/IEC 18181-1 §C.9.
// libjxl: `lib/jxl/ac_strategy.h`.

import Foundation

/// All AC strategy IDs in their libjxl-numbered order. The wire
/// format reads/writes these via a `u(5)` field per 8×8 cell.
public enum ACStrategy: UInt8, Sendable, CaseIterable {
    case dct8x8       = 0
    case hornuss      = 1   // 8×8 in spatial domain (smooth-block fast path)
    case dct2x2       = 2   // 4 sub-blocks
    case dct4x4       = 3
    case dct16x16     = 4
    case dct32x32     = 5
    case dct16x8      = 6
    case dct8x16      = 7
    case dct32x8      = 8
    case dct8x32      = 9
    case dct32x16     = 10
    case dct16x32     = 11
    case dct4x8       = 12
    case dct8x4       = 13
    case afv0         = 14  // asymmetric frequency variable, four orientations
    case afv1         = 15
    case afv2         = 16
    case afv3         = 17
    case dct64x64     = 18
    case dct64x32     = 19
    case dct32x64     = 20
    case dct128x128   = 21
    case dct128x64    = 22
    case dct64x128    = 23
    case dct256x256   = 24
    case dct256x128   = 25
    case dct128x256   = 26

    /// Block dimensions in 8-pixel cells (`cellsX` = horizontal,
    /// `cellsY` = vertical). libjxl name convention is `DCT[N]X[M]` =
    /// `N` tall × `M` wide, i.e. **height × width**, so
    /// `dct16x8 → (cellsX=1, cellsY=2)` (8 wide × 16 tall, = 1
    /// horizontal cell × 2 vertical cells). Cross-checked against
    /// libjxl `ac_strategy.h` `covered_blocks_x` / `covered_blocks_y`
    /// LUTs at `static constexpr uint8_t kLut[]`.
    public var blockCells: (cellsX: Int, cellsY: Int) {
        switch self {
        case .dct8x8, .hornuss, .dct2x2, .dct4x4,
             .dct4x8, .dct8x4, .afv0, .afv1, .afv2, .afv3:
            return (1, 1)
        case .dct16x16:                       return (2, 2)
        case .dct32x32:                       return (4, 4)
        case .dct16x8:                        return (1, 2)  // 8w × 16h
        case .dct8x16:                        return (2, 1)  // 16w × 8h
        case .dct32x8:                        return (1, 4)  // 8w × 32h
        case .dct8x32:                        return (4, 1)  // 32w × 8h
        case .dct32x16:                       return (2, 4)  // 16w × 32h
        case .dct16x32:                       return (4, 2)  // 32w × 16h
        case .dct64x64:                       return (8, 8)
        case .dct64x32:                       return (4, 8)  // 32w × 64h
        case .dct32x64:                       return (8, 4)  // 64w × 32h
        case .dct128x128:                     return (16, 16)
        case .dct128x64:                      return (8, 16) // 64w × 128h
        case .dct64x128:                      return (16, 8) // 128w × 64h
        case .dct256x256:                     return (32, 32)
        case .dct256x128:                     return (16, 32) // 128w × 256h
        case .dct128x256:                     return (32, 16) // 256w × 128h
        }
    }

    /// Full-pixel dimensions of this strategy's coverage area.
    public var blockPixels: (width: Int, height: Int) {
        let c = blockCells
        return (c.cellsX * 8, c.cellsY * 8)
    }

    /// libjxl-style ordering bucket (`kStrategyOrder`). 27
    /// strategies cluster into 13 ordering classes — same value
    /// for XxY / YxX pairs.
    public var orderBucket: Int {
        return Int(kStrategyOrder[Int(rawValue)])
    }

    /// Number of 8×8 cells covered (= cellsX × cellsY).
    public var coveredBlocks: Int {
        let c = blockCells
        return c.cellsX * c.cellsY
    }

    /// `log₂(coveredBlocks)`. AC strategies cover power-of-two
    /// cell counts so this is exact.
    public var log2CoveredBlocks: Int {
        let n = coveredBlocks
        precondition(n > 0 && (n & (n - 1)) == 0,
                     "coveredBlocks must be a power of two")
        return n.trailingZeroBitCount
    }
}
