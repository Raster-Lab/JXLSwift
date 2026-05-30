// Apply a `JPEGQuantTable` to a `JPEGCoefficientBlock` —
// eighth step on the Phase J road. The block decoder returns
// **quantised** integer coefficients in natural (row-major) order;
// this layer multiplies each coefficient by its quantisation
// factor, leaving still-integer dequantised coefficients ready
// for IDCT (the pixel-reconstruction route) or for the JXL
// VarDCT bridge (libjxl's transcode shortcut).
//
// Layout reminder:
//   - `JPEGCoefficientBlock.coefficients[n]` is the coefficient
//     at natural row-major index `n` (n = y*8 + x).
//   - `JPEGQuantTable.zigZagValues[k]` is the quant factor for
//     the coefficient at *zig-zag* position `k`, i.e. for the
//     coefficient at natural index `JPEGZigZag.order[k]`.
//
// So `dequantised[natural] = quantised[natural] * Q[inverseZigZag[natural]]`,
// equivalently
// `dequantised[JPEGZigZag.order[k]] = quantised[JPEGZigZag.order[k]] * Q[k]`.

import Foundation

/// Multiply a quantised JPEG coefficient block by its
/// quantisation table. Output is in natural (row-major) order,
/// same layout as the input block.
package enum JPEGDequantiser {

    /// Dequantise `block` in-place by `table`. Both inputs must
    /// describe an 8×8 block — `block.coefficients.count == 64`
    /// is enforced by `JPEGCoefficientBlock.init`,
    /// `table.zigZagValues.count == 64` is enforced by
    /// `JPEGQuantTable.parse`.
    ///
    /// Saturation note: at 8-bit JPEG precision, quantised
    /// coefficients fit in roughly ±16 384 and quant factors in
    /// 1..65 535, so the product fits comfortably in `Int32`. We
    /// don't clamp.
    package static func dequantise(
        _ block: inout JPEGCoefficientBlock,
        using table: JPEGQuantTable
    ) {
        precondition(table.zigZagValues.count == 64,
            "JPEGDequantiser: quant table must have 64 entries")
        for k in 0..<64 {
            let n = JPEGZigZag.order[k]
            block.coefficients[n] &*= Int32(table.zigZagValues[k])
        }
    }

    /// Functional flavour — returns a new dequantised block
    /// instead of mutating in place.
    package static func dequantising(
        _ block: JPEGCoefficientBlock,
        using table: JPEGQuantTable
    ) -> JPEGCoefficientBlock {
        var copy = block
        dequantise(&copy, using: table)
        return copy
    }
}
