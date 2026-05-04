// QuantWeights — VarDCT quant-matrix synthesis primitives.
//
// JPEG XL's per-coefficient quant matrices are NOT shipped as flat
// 64-float (or 256, 1024, …) tables. Instead each AC strategy
// declares a small set of "distance bands" — typically 4 floats
// per channel — that get expanded into the full matrix at decode/
// encode time via a parametric interpolation. This file provides
// just the primitive layer: the `Mult` helper that turns the
// signed band offsets into multiplicative steps, and the
// `interpolate` function that samples the resulting per-band
// piecewise-geometric curve at any normalised distance.
//
// Spec: ISO/IEC 18181-1 §K.7. libjxl: `lib/jxl/quant_weights.cc`,
// helpers `Mult`, `Interpolate`, `GetQuantWeights`.
//
// **Status**: math primitives only. The actual per-strategy table
// generation (`GetQuantWeights(rows, cols, bands)`) layers on top
// of these but lives with the rest of the dequantiser pipeline,
// which has dependencies on the AC strategy bitstream we haven't
// implemented yet.

import Foundation

public enum QuantWeights {

    /// Convert a signed band offset into a positive multiplicative
    /// step. Mirrors libjxl's `Mult`: positive offsets give
    /// `1 + v` (linear), negative offsets give `1 / (1 - v)`
    /// (reciprocal — keeps the curve monotonic across the band
    /// boundaries).
    @inline(__always)
    public static func mult(_ v: Float) -> Float {
        return v > 0 ? 1 + v : 1 / (1 - v)
    }

    /// Expand a `distance_bands` array (length `numBands`, encoded
    /// as `[base, mult₁, mult₂, …]`) into an absolute-magnitude
    /// curve. `out[0] = bands[0]`, `out[i] = out[i-1] · Mult(bands[i])`.
    /// Returns the expanded curve so callers can feed it to
    /// `interpolate`.
    public static func expandBands(_ bands: [Float]) -> [Float] {
        precondition(!bands.isEmpty)
        var out = [Float](repeating: 0, count: bands.count)
        out[0] = bands[0]
        for i in 1..<bands.count {
            out[i] = out[i - 1] * mult(bands[i])
        }
        return out
    }

    /// Sample the piecewise-geometric curve `array` (length `len`)
    /// at fractional position `pos` in `[0, max]`. Mirrors libjxl's
    /// `Interpolate(pos, max, array, len)`:
    ///
    ///     scaled_pos = pos · (len - 1) / max
    ///     idx = floor(scaled_pos)
    ///     weight = a · (b/a)^(scaled_pos - idx)     // geometric
    ///
    /// `pos == 0` returns `array[0]`; `pos == max` returns the
    /// last entry. Caller's responsibility to keep `pos ≤ max`.
    @inline(__always)
    public static func interpolate(
        pos: Float, max: Float, array: [Float]
    ) -> Float {
        let len = array.count
        precondition(len >= 1, "array must be non-empty")
        if len == 1 { return array[0] }
        let scaled = pos * Float(len - 1) / max
        let idx = Int(scaled)
        let clamped = min(max == 0 ? 0 : idx, len - 2)
        let a = array[clamped]
        let b = array[clamped + 1]
        let frac = scaled - Float(clamped)
        // a · (b/a)^frac == exp(frac · log(b/a) + log(a))
        return a * powf(b / a, frac)
    }

    /// Maximum normalised distance an `(x, y)` cell can be from the
    /// DC corner: `√2` (for a square block, the bottom-right cell).
    /// libjxl `quant_weights.cc` uses this as the curve's `max`.
    public static let kSqrt2: Float = 1.4142135623730951

    /// Synthesise a 3-plane per-coefficient quant-weight table for a
    /// `rows × cols` rectangular DCT block from per-channel distance
    /// bands. Mirrors libjxl `quant_weights.cc::GetQuantWeights`.
    ///
    /// `bands` is a 3-tuple of float arrays (one per channel); each
    /// channel's array has the same length. Output is row-major
    /// `out[c * rows * cols + y * cols + x]` and has length
    /// `3 * rows * cols`.
    ///
    /// The first band entry per channel is the absolute seed
    /// (already multiplied by 64 if the caller is reproducing
    /// libjxl's bitstream behaviour — see `DecodeDctParams` line
    /// `params->distance_bands[c][0] *= 64.0f`). Subsequent
    /// entries are signed multiplicative offsets piped through
    /// `mult(_:)`.
    public static func getQuantWeights(
        rows: Int, cols: Int,
        bands: (x: [Float], y: [Float], b: [Float])
    ) throws -> [Float] {
        precondition(rows >= 1 && cols >= 1)
        let perChannel: [[Float]] = [bands.x, bands.y, bands.b]
        guard let firstLen = perChannel.first?.count,
              perChannel.allSatisfy({ $0.count == firstLen }) else {
            throw QuantWeightsError.misshapedBands(
                "all three channels must declare the same number of bands"
            )
        }
        guard firstLen >= 1 else {
            throw QuantWeightsError.misshapedBands("bands must be non-empty")
        }
        var out = [Float](repeating: 0, count: 3 * rows * cols)
        for c in 0..<3 {
            let curve = expandBands(perChannel[c])
            // libjxl's per-axis scale: `(num_bands - 1) / (√2 + ε)`.
            // The +1e-6 guard mirrors libjxl exactly so byte-equal
            // reproduction is possible. `rcpcol` and `rcprow`
            // convert integer cell indices into the normalised
            // [0, √2] coordinate the band curve is sampled at.
            let scale = Float(firstLen - 1) / (kSqrt2 + 1e-6)
            let rcpcol = (cols == 1) ? 0 : scale / Float(cols - 1)
            let rcprow = (rows == 1) ? 0 : scale / Float(rows - 1)
            for y in 0..<rows {
                let dy = Float(y) * rcprow
                let dy2 = dy * dy
                for x in 0..<cols {
                    let dx = Float(x) * rcpcol
                    let dist = sqrtf(dx * dx + dy2)
                    // libjxl's `InterpolateVec` takes the already-
                    // scaled distance (in band-index units, ∈ [0,
                    // num_bands-1]) and uses it directly as the
                    // sample index. Our `dist` is in the same units
                    // (because `rcpcol`/`rcprow` already bake in
                    // `(num_bands-1)/√2`). Pass `max = curve.count - 1`
                    // so `interpolate` skips its own re-scaling and
                    // matches libjxl bit-for-bit.
                    let w = (firstLen == 1)
                        ? curve[0]
                        : interpolate(pos: dist,
                                      max: Float(curve.count - 1),
                                      array: curve)
                    out[c * rows * cols + y * cols + x] = w
                }
            }
        }
        return out
    }
}

public enum QuantWeightsError: Error, Sendable {
    case misshapedBands(String)
}

/// libjxl-frozen distance bands for the default AC strategies.
/// Each tuple's first entry is *raw* (not yet ×64) — call
/// `scaledForBitstream(_:)` to apply the libjxl scaling that the
/// bitstream-decoded form carries.
public enum DefaultQuantBands {

    /// DCT8x8 bands per libjxl `quant_weights.cc` `DCT()`.
    /// Channel order: X (red-green), Y (luma), B (yellow-blue).
    public static let dct8x8: (x: [Float], y: [Float], b: [Float]) = (
        x: [3150.0,    0.0, -0.4, -0.4, -0.4, -2.0],
        y: [ 560.0,    0.0, -0.3, -0.3, -0.3, -0.3],
        b: [ 512.0,   -2.0, -1.0,  0.0, -1.0, -2.0]
    )

    /// DCT16x16 bands per libjxl `quant_weights.cc` `DCT16X16()`.
    public static let dct16x16: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             8996.8725711814115328,
               -1.3000777393353804,
               -0.49424529824571225,
               -0.439093774457103443,
               -0.6350101832695744,
               -0.90177264050827612,
               -1.6162099239887414,
        ],
        y: [
             3191.48366296844234752,
               -0.67424582104194355,
               -0.80745813428471001,
               -0.44925837484843441,
               -0.35865440981033403,
               -0.31322389111877305,
               -0.37615025315725483,
        ],
        b: [
             1157.50408145487200256,
               -2.0531423165804414,
               -1.4,
               -0.50687130033378396,
               -0.42708730624733904,
               -1.4856834539296244,
               -4.9209142884401604,
        ]
    )

    /// DCT32x32 bands per libjxl `quant_weights.cc` `DCT32X32()`.
    public static let dct32x32: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             15718.40830982518931456,
                -1.025,
                -0.98,
                -0.9012,
                -0.4,
                -0.48819395464,
                -0.421064,
                -0.27,
        ],
        y: [
              7305.7636810695983104,
                -0.8041958212306401,
                -0.7633036457487539,
                -0.55660379990111464,
                -0.49785304658857626,
                -0.43699592683512467,
                -0.40180866526242109,
                -0.27321683125358037,
        ],
        b: [
              3803.53173721215041536,
                -3.060733579805728,
                -2.0413270132490346,
                -2.0235650159727417,
                -0.5495389509954993,
                -0.4,
                -0.4,
                -0.3,
        ]
    )

    /// DCT8x16 / DCT16x8 bands per libjxl `quant_weights.cc`
    /// `DCT8X16()`. (libjxl's DCT8X16 corresponds to a 16-tall ×
    /// 8-wide coefficient layout — same layout as DCT16X8 after
    /// `CoefficientLayout` swap, so they share the table.)
    public static let dct8x16: (x: [Float], y: [Float], b: [Float]) = (
        x: [7240.7734393502, -0.7, -0.7, -0.2, -0.2, -0.2, -0.5],
        y: [1448.15468787004, -0.5, -0.5, -0.5, -0.2, -0.2, -0.2],
        b: [ 506.854140754517, -1.4, -0.2, -0.5, -0.5, -1.5, -3.6]
    )

    /// DCT64x32 / DCT32x64 bands per libjxl `quant_weights.cc`
    /// `DCT32X64()`. Both share the 64×32 (after `CoefficientLayout`)
    /// coef layout. libjxl bakes a `0.65 *` factor into the seed.
    public static let dct32x64: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             Float(0.65 * 23629.073922049845),
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
        ],
        y: [
             Float(0.65 * 8611.3238710010046),
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
        ],
        b: [
             Float(0.65 * 4492.2486445538634),
                -1.2,
                -1.2,
                -0.8,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )

    /// DCT64x64 bands per libjxl `quant_weights.cc` `DCT64X64()`.
    /// Note: libjxl baked in a `0.9 *` factor on the seed values
    /// for this strategy.
    public static let dct64x64: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             Float(0.9 * 26629.073922049845),
                -1.025,
                -0.78,
                -0.65012,
                -0.19041574084286472,
                -0.20819395464,
                -0.421064,
                -0.32733845535848671,
        ],
        y: [
             Float(0.9 * 9311.3238710010046),
                -0.3041958212306401,
                -0.3633036457487539,
                -0.35660379990111464,
                -0.3443074455424403,
                -0.33699592683512467,
                -0.30180866526242109,
                -0.27321683125358037,
        ],
        b: [
             Float(0.9 * 4992.2486445538634),
                -1.2,
                -1.2,
                -0.8,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )

    /// DCT16x32 / DCT32x16 bands per libjxl `quant_weights.cc`
    /// `DCT16X32()`. Both share a 32×16 (after `CoefficientLayout`)
    /// coef layout and therefore the same quant table.
    public static let dct16x32: (x: [Float], y: [Float], b: [Float]) = (
        x: [
             13844.97076442300573,
                -0.97113799999999995,
                -0.658,
                -0.42026,
                -0.22712,
                -0.2206,
                -0.226,
                -0.6,
        ],
        y: [
              4798.964084220744293,
                -0.61125308982767057,
                -0.83770786552491361,
                -0.79014862079498627,
                -0.2692727459704829,
                -0.38272769465388551,
                -0.22924222653091453,
                -0.20719098826199578,
        ],
        b: [
              1807.236946760964614,
                -1.2,
                -1.2,
                -0.7,
                -0.7,
                -0.7,
                -0.4,
                -0.5,
        ]
    )

    /// libjxl's bitstream multiplies the seed band by 64 after
    /// reading (`DecodeDctParams` line
    /// `params->distance_bands[c][0] *= 64.0f`). Apply here so the
    /// resulting weights match what the decoder actually
    /// dequantises with.
    public static func scaledForBitstream(
        _ bands: (x: [Float], y: [Float], b: [Float])
    ) -> (x: [Float], y: [Float], b: [Float]) {
        var x = bands.x, y = bands.y, b = bands.b
        x[0] *= 64; y[0] *= 64; b[0] *= 64
        return (x: x, y: y, b: b)
    }

    // MARK: - DCT4X4 / DCT4X8 sub-block bands (used by AFV).

    /// DCT4X4 quant bands (libjxl `quant_weights.cc::DCT4X4()`).
    /// Used when building AFV quant matrices.
    public static let dct4x4: (x: [Float], y: [Float], b: [Float]) = (
        x: [2200.0, 0.0, 0.0, 0.0],
        y: [ 392.0, 0.0, 0.0, 0.0],
        b: [ 112.0, -0.25, -0.25, -0.5]
    )

    /// DCT4X8 quant bands (libjxl `quant_weights.cc::DCT4X8()`).
    /// Used when building AFV quant matrices.
    public static let dct4x8: (x: [Float], y: [Float], b: [Float]) = (
        x: [2198.050556016380522,  -0.96269623020744692,
            -0.76194253026666783,  -0.6551140670773547],
        y: [ 764.3655248643528689, -0.92630200888366945,
            -0.9675229603596517,   -0.27845290869168118],
        b: [ 527.107573587542228,  -1.4594385811273854,
            -1.450082094097871593, -1.5843722511996204]
    )

    // MARK: - AFV LIBRARY-default weights (libjxl `AFV0()`).

    /// AFV-mode 9-element weight tuples per libjxl's `AFV0()`
    /// LIBRARY default. Layout:
    /// ```
    /// [0]  = 4×8/4×4 DC tendency at (0, 1)
    /// [1]  = 4×8/4×4 DC tendency at (1, 0)
    /// [2]  = AFV corner weight at (0, 2)
    /// [3]  = AFV corner weight at (2, 0)
    /// [4]  = AFV corner weight at (2, 2)
    /// [5]  = AFV high-freq band[0] (seed)
    /// [6]  = AFV high-freq band[1] delta
    /// [7]  = AFV high-freq band[2] delta
    /// [8]  = AFV high-freq band[3] delta
    /// ```
    public static let afv: (x: [Float], y: [Float], b: [Float]) = (
        x: [3072, 3072, 256, 256, 256, 414, 0, 0, 0],
        y: [1024, 1024,  50,  50,  50,  58, 0, 0, 0],
        b: [ 384,  384,  12,  12,  12,  22, -0.25, -0.25, -0.25]
    )
}

// MARK: - AFV quant-matrix builder

extension QuantWeights {

    /// Per libjxl's `quant_weights.cc::ComputeQuantTable`
    /// `kQuantModeAFV` case (lines 240–320 of the 0.11.2 source).
    /// Builds a 3×64 AFV quant matrix: combines DCT4X8 weights
    /// (odd rows), DCT4X4 weights (even rows / odd cols), and
    /// AFV-specific weights (even rows / even cols, including the
    /// 5 hardcoded "corner" positions and 11 interpolated
    /// high-frequency positions per the libjxl `kFreqs` table).
    ///
    /// `dct4x8Bands`, `dct4x4Bands` are the DCT4X8 / DCT4X4 quant
    /// bands (caller passes the LIBRARY default + ×64 if needed).
    /// `afvWeights` is a 3-tuple of length-9 AFV weight vectors
    /// from ``DefaultQuantBands/afv``.
    public static func getAFVQuantWeights(
        dct4x8Bands: (x: [Float], y: [Float], b: [Float]),
        dct4x4Bands: (x: [Float], y: [Float], b: [Float]),
        afvWeights: (x: [Float], y: [Float], b: [Float])
    ) throws -> [Float] {
        let weights4x8 = try getQuantWeights(
            rows: 4, cols: 8, bands: dct4x8Bands)
        let weights4x4 = try getQuantWeights(
            rows: 4, cols: 4, bands: dct4x4Bands)

        // libjxl's `kFreqs` table — 16 entries, one per AFV 4×4
        // sub-block position (iy*4 + ix). Values at positions
        // (0,0..1) and (1,0..1) are unused (the 0xBAD entries —
        // those get overridden by the 5 AFV-specific corner
        // weights below, and (0,0) is the DC). The remaining 11
        // entries seed an interpolation against the 4-band
        // high-freq curve.
        let kFreqs: [Float] = [
            0,  // 0xBAD — unused (DC).
            0,  // 0xBAD — overridden at (0,1) below.
            0.8517778890324296,
            5.37778436506804,
            0,  // 0xBAD — overridden at (1,0) below.
            0,  // 0xBAD — but unused: (1,1) is in the IDCT 4x4 region.
            4.734747904497923,
            5.449245381693219,
            1.6598270267479331,
            4,
            7.275749096817861,
            10.423227632456525,
            2.662932286148962,
            7.630657783650829,
            8.962388608184032,
            12.97166202570235,
        ]
        let lo: Float = 0.8517778890324296
        let hi: Float = 12.97166202570235 - lo + 1e-6

        let afvPerChannel: [[Float]] = [afvWeights.x, afvWeights.y, afvWeights.b]
        var out = [Float](repeating: 0, count: 3 * 64)

        for c in 0..<3 {
            let aw = afvPerChannel[c]
            // High-freq bands seed + 3 deltas.
            var bands = [Float](repeating: 0, count: 4)
            bands[0] = aw[5]
            for i in 1..<4 {
                bands[i] = bands[i - 1] * mult(aw[i + 5])
            }

            let start = c * 64
            // The (0, 0) DC slot. libjxl writes 1.0 here (unused;
            // avoids MSAN false-positive).
            out[start] = 1.0
            // Hand-set 5 AFV special positions, mirroring libjxl's
            // `set_weight(x, y, val) { weights[start + y*8 + x] = val }`
            // signature exactly (so afv[0] lands at (x=0, y=1) — which
            // is row 1, col 0 in our row-major layout, offset 8).
            // Layout: out[start + y*8 + x].
            out[start + 1 * 8 + 0] = aw[0]   // set_weight(0, 1, afv[0])
            out[start + 0 * 8 + 1] = aw[1]   // set_weight(1, 0, afv[1])
            out[start + 2 * 8 + 0] = aw[2]   // set_weight(0, 2, afv[2])
            out[start + 0 * 8 + 2] = aw[3]   // set_weight(2, 0, afv[3])
            out[start + 2 * 8 + 2] = aw[4]   // set_weight(2, 2, afv[4])

            // Remaining AFV high-freq weights (even rows / even
            // cols, excluding the 4 hand-set positions plus DC).
            // Maps libjxl's `set_weight(2*x, 2*y, ...)` for
            // (x, y) in [0, 4) × [0, 4) where NOT (x < 2 && y < 2).
            for y in 0..<4 {
                for x in 0..<4 {
                    if x < 2 && y < 2 { continue }
                    let pos = kFreqs[y * 4 + x] - lo
                    let w = interpolate(pos: pos, max: hi, array: bands)
                    out[start + 2 * y * 8 + 2 * x] = w
                }
            }

            // 4×8 weights → odd rows of the 8×8 layout, all cols
            // except (0, 0).
            for y in 0..<4 {
                for x in 0..<8 {
                    if x == 0 && y == 0 { continue }
                    out[start + (2 * y + 1) * 8 + x] =
                        weights4x8[c * 32 + y * 8 + x]
                }
            }
            // 4×4 weights → even rows / odd cols, except (0, 1).
            for y in 0..<4 {
                for x in 0..<4 {
                    if x == 0 && y == 0 { continue }
                    out[start + (2 * y) * 8 + 2 * x + 1] =
                        weights4x4[c * 16 + y * 4 + x]
                }
            }
        }
        return out
    }
}
