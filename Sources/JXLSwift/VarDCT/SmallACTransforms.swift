// SmallACTransforms — the sub-8×8 VarDCT inverse transforms.
//
// DCT2X2 and DCT4X4 each cover a single 8×8 cell but transform it in
// smaller units: DCT2X2 as a hierarchical 2→4→8 Haar-like cascade,
// DCT4X4 as four independent 4×4 DCTs. Direct ports of libjxl
// `dec_transforms-inl.h::TransformToPixels` (`Type::DCT2X2`,
// `Type::DCT4X4`) and `IDCT2TopBlock`. Spec: ISO/IEC 18181-1 §K.9.

import Foundation

public enum DCT2x2Transform {

    /// libjxl `IDCT2TopBlock<S>` — a 2×2 butterfly over the top-left
    /// `S×S` region of an 8×8 block. `num_2x2 = S/2` sub-blocks are
    /// each expanded into a 2×2 patch. Returns a fresh 64-entry
    /// block (the top-left S×S overwritten, the rest copied through).
    @inline(__always)
    static func idct2TopBlock(_ block: [Float], s: Int) -> [Float] {
        var out = block
        var temp = [Float](repeating: 0, count: 64)
        let num2x2 = s / 2
        for y in 0..<num2x2 {
            for x in 0..<num2x2 {
                let c00 = block[y * 8 + x]
                let c01 = block[y * 8 + num2x2 + x]
                let c10 = block[(y + num2x2) * 8 + x]
                let c11 = block[(y + num2x2) * 8 + num2x2 + x]
                temp[y * 2 * 8 + x * 2]         = c00 + c01 + c10 + c11
                temp[y * 2 * 8 + x * 2 + 1]     = c00 + c01 - c10 - c11
                temp[(y * 2 + 1) * 8 + x * 2]   = c00 - c01 + c10 - c11
                temp[(y * 2 + 1) * 8 + x * 2 + 1] = c00 - c01 - c10 + c11
            }
        }
        for y in 0..<s {
            for x in 0..<s { out[y * 8 + x] = temp[y * 8 + x] }
        }
        return out
    }

    /// Inverse DCT2X2 transform: a dequantised 8×8 coefficient block
    /// → an 8×8 row-major pixel block. Applies the `IDCT2TopBlock`
    /// cascade at scales 2, 4, 8.
    public static func transformToPixels(_ coefficients: [Float]) -> [Float] {
        precondition(coefficients.count == 64)
        var c = idct2TopBlock(coefficients, s: 2)
        c = idct2TopBlock(c, s: 4)
        c = idct2TopBlock(c, s: 8)
        return c
    }
}

public enum DCT4x4Transform {

    /// Inverse DCT4X4 transform: a dequantised 8×8 coefficient block
    /// → an 8×8 row-major pixel block. The cell is split into four
    /// 4×4 quadrants; each quadrant's DC comes from a 2×2 DCT of the
    /// four corner coefficients, its 15 AC coefficients from a
    /// strided gather, and the quadrant is reconstructed with a 4×4
    /// `ComputeScaledIDCT` (= `IDCTSlow(coefᵀ)`).
    public static func transformToPixels(_ coefficients: [Float]) -> [Float] {
        precondition(coefficients.count == 64)
        var pixels = [Float](repeating: 0, count: 64)
        let block00 = coefficients[0]
        let block01 = coefficients[1]
        let block10 = coefficients[8]
        let block11 = coefficients[9]
        let dcs: [Float] = [
            block00 + block01 + block10 + block11,
            block00 + block01 - block10 - block11,
            block00 - block01 + block10 - block11,
            block00 - block01 - block10 + block11,
        ]
        for y in 0..<2 {
            for x in 0..<2 {
                var block = [Float](repeating: 0, count: 16)
                block[0] = dcs[y * 2 + x]
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        if ix == 0 && iy == 0 { continue }
                        block[iy * 4 + ix] =
                            coefficients[(y + iy * 2) * 8 + x + ix * 2]
                    }
                }
                // ComputeScaledIDCT<4,4> = IDCTSlow(blockᵀ).
                JXLDecoder.transposeSquareInPlace(&block, size: 4)
                AccelerateDCT.idct2D(&block, size: 4)
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        pixels[(y * 4 + iy) * 8 + x * 4 + ix] =
                            block[iy * 4 + ix]
                    }
                }
            }
        }
        return pixels
    }
}
