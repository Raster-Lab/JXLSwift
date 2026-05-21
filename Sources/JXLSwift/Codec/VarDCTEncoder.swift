// VarDCTEncoder — the forward (analysis) half of the lossy VarDCT
// codec: the inverse of the byte-exact `JXLDecoder` VarDCT path.
//
// This file is the **DSP core** of the encoder — it turns an
// `ImageFrame` into quantised DC + AC coefficient planes. The
// bitstream-serialisation layer (FrameHeader / TOC / LfGlobal /
// modular DC sub-image / AC entropy) is built on top of this and
// lands separately.
//
// Scope of this first cut, deliberately minimal so every step is
// the exact inverse of a proven decoder step:
//   • DCT8×8 for every block — no AC-strategy search.
//   • One global quantiser (`globalScale` / `quantDC` / `qf`) — no
//     adaptive quant field.
//   • Default colour-correlation (CfL slopes 0): the decoder still
//     folds `B += Y` (base correlation B = 1), so the encoder
//     decorrelates `B -= Y` on both DC and AC.
//   • `dc_extra_precision = 0`, `x/b_qm_scale = 2` (→ dm-multiplier
//     1, no quant-matrix scaling).
//
// Verification: `Tests` reconstructs the quantised output with the
// decoder's exact dequant + IDCT + inverse-XYB and checks the lossy
// round-trip error is bounded.
//
// Spec reference: ISO/IEC 18181-1 §K (VarDCT). libjxl: `enc_group.cc`,
// `enc_xyb.cc`, `enc_frame.cc`.

import Foundation

/// Forward VarDCT transform — `ImageFrame` → quantised coefficients.
public enum VarDCTEncoder {

    /// Quantised output of the forward transform — the input to the
    /// (separate) bitstream-serialisation layer.
    public struct Quantized: Sendable {
        public let xsize: Int
        public let ysize: Int
        /// Block grid (8×8 blocks, padded to cover the frame).
        public let blocksX: Int
        public let blocksY: Int
        /// Quantiser parameters written to `QuantizerParams`.
        public let globalScale: UInt32
        public let quantDC: UInt32
        /// Per-block quantisation factor (uniform in this first cut).
        public let qf: Int32
        /// `dc_extra_precision` (0 here).
        public let dcExtraPrecision: UInt32
        /// Per-channel quantised DC, XYB-indexed `[X,Y,B][by*blocksX+bx]`.
        /// B is colour-decorrelated (`B − Y`) ready for the modular
        /// DC sub-image.
        public let dcQuant: [[Int32]]
        /// Per-block quantised AC, `[blockIdx][xybChannel][64]`.
        /// Position 0 (DC) is 0; X/Y/B are colour-decorrelated.
        public let acQuant: [[[Int32]]]
    }

    /// libjxl `quant_weights.h::kInvDCQuant`, XYB-indexed.
    static let kInvDCQuant: [Float] = [4096.0, 512.0, 256.0]

    enum EncoderError: Error, Sendable {
        case unsupported(String)
    }

    /// Run the forward transform. `frame` must be 8-bit RGB or RGBA
    /// (alpha is ignored by this DSP core — extra channels are a
    /// bitstream-layer concern).
    /// Map a quality `distance` to the frame's global quantiser.
    /// `distance` is a monotone quality knob in the spirit of cjxl's
    /// `-d` (0.5 ≈ near-lossless, larger = smaller/lossier) — but a
    /// **crude global** mapping, not the perceptual butteraugli-
    /// driven adaptive quant libjxl uses. `distance = 1` reproduces
    /// the previous fixed quantiser (`global_scale = 5111`).
    public static func globalScale(forDistance distance: Float) -> UInt32 {
        let d = max(0.05, distance)
        let s = (5111.0 / d).rounded()
        return UInt32(max(1.0, min(65535.0, s)))
    }

    public static func forward(
        frame: ImageFrame, distance: Float = 1.0
    ) throws -> Quantized {
        let globalScale = globalScale(forDistance: distance)
        let quantDC: UInt32 = 17
        let qf: Int32 = 5
        guard frame.pixelType == .uint8, frame.channels >= 3 else {
            throw EncoderError.unsupported(
                "VarDCT encode: only 8-bit RGB/RGBA frames "
                + "(got \(frame.pixelType)/\(frame.channels)ch)")
        }
        let xsize = frame.width
        let ysize = frame.height
        let blocksX = (xsize + 7) / 8
        let blocksY = (ysize + 7) / 8
        let pw = blocksX * 8
        let ph = blocksY * 8
        let ch = frame.channels

        // (1) sRGB8 → linear → XYB, into three padded planes.
        var planeX = [Float](repeating: 0, count: pw * ph)
        var planeY = [Float](repeating: 0, count: pw * ph)
        var planeB = [Float](repeating: 0, count: pw * ph)
        for y in 0..<ph {
            let sy = min(y, ysize - 1)
            for x in 0..<pw {
                let sx = min(x, xsize - 1)
                let p = (sy * xsize + sx) * ch
                let r = srgb8ToLinear(frame.data[p + 0])
                let g = srgb8ToLinear(frame.data[p + 1])
                let b = srgb8ToLinear(frame.data[p + 2])
                let xyb = OpsinXYB.forward((r, g, b))
                let i = y * pw + x
                planeX[i] = xyb.X
                planeY[i] = xyb.Y
                planeB[i] = xyb.B
            }
        }

        // (2) Per-channel DCT8×8 quant weights (LIBRARY defaults, no
        // ×64 — matches the decoder's `getQuantWeights`).
        let qweights: [Float]
        do {
            qweights = try QuantWeights.getQuantWeights(
                rows: 8, cols: 8, bands: DefaultQuantBands.dct8x8)
        } catch {
            throw EncoderError.unsupported(
                "VarDCT encode: DCT8 quant weights failed: \(error)")
        }

        // Quantiser scalars — the exact reciprocals of the decoder.
        let invGlobalScale: Float = 65536.0 / Float(globalScale)
        let invQuantDC: Float = invGlobalScale / Float(quantDC)
        let mulDC: [Float] = (0..<3).map { invQuantDC / kInvDCQuant[$0] }
        let acScale: Float = Float(globalScale) / 65536.0   // = 1/invGlobalScale

        var dcQuant: [[Int32]] = [
            [Int32](repeating: 0, count: blocksX * blocksY),
            [Int32](repeating: 0, count: blocksX * blocksY),
            [Int32](repeating: 0, count: blocksX * blocksY),
        ]
        var acQuant = [[[Int32]]](
            repeating: [[Int32]](
                repeating: [Int32](repeating: 0, count: 64), count: 3),
            count: blocksX * blocksY)

        // (3) Per block: forward DCT each channel, colour-decorrelate,
        // quantise DC + AC.
        var blkX = [Float](repeating: 0, count: 64)
        var blkY = [Float](repeating: 0, count: 64)
        var blkB = [Float](repeating: 0, count: 64)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let ox = bx * 8, oy = by * 8
                for r in 0..<8 {
                    let row = (oy + r) * pw + ox
                    for c in 0..<8 {
                        blkX[r * 8 + c] = planeX[row + c]
                        blkY[r * 8 + c] = planeY[row + c]
                        blkB[r * 8 + c] = planeB[row + c]
                    }
                }
                // Forward DCT. The decoder runs `idct2D(transpose(coef))`
                // for ROWS≥COLS, so `coef = transpose(dct2D(pixels))`.
                // `AccelerateDCT.dct2D` is the exact forward partner of
                // the decoder's `AccelerateDCT.idct2D` (same libjxl
                // `ComputeScaledDCT` normalisation).
                AccelerateDCT.dct2D(&blkX, size: 8)
                AccelerateDCT.dct2D(&blkY, size: 8)
                AccelerateDCT.dct2D(&blkB, size: 8)
                transpose8(&blkX)
                transpose8(&blkY)
                transpose8(&blkB)
                let blockIdx = by * blocksX + bx

                // DC (coefficient 0). Default CfL: decoder folds
                // `B += Y` (base correlation B = 1) and `X += 0·Y`.
                let dcX = blkX[0]
                let dcY = blkY[0]
                let dcBStored = blkB[0] - dcY
                dcQuant[0][blockIdx] = Int32((dcX / mulDC[0]).rounded())
                dcQuant[1][blockIdx] = Int32((dcY / mulDC[1]).rounded())
                dcQuant[2][blockIdx] =
                    Int32((dcBStored / mulDC[2]).rounded())

                // AC (coefficients 1..63). Decorrelate B (`B − Y`),
                // quantise with the per-channel quant matrix.
                for k in 1..<64 {
                    let acX = blkX[k]
                    let acY = blkY[k]
                    let acBStored = blkB[k] - acY
                    acQuant[blockIdx][0][k] = quantizeAC(
                        acX, weight: qweights[0 * 64 + k],
                        scale: acScale, qf: qf)
                    acQuant[blockIdx][1][k] = quantizeAC(
                        acY, weight: qweights[1 * 64 + k],
                        scale: acScale, qf: qf)
                    acQuant[blockIdx][2][k] = quantizeAC(
                        acBStored, weight: qweights[2 * 64 + k],
                        scale: acScale, qf: qf)
                }
            }
        }

        return Quantized(
            xsize: xsize, ysize: ysize,
            blocksX: blocksX, blocksY: blocksY,
            globalScale: globalScale, quantDC: quantDC, qf: qf,
            dcExtraPrecision: 0,
            dcQuant: dcQuant, acQuant: acQuant)
    }

    // MARK: - Primitives

    /// One AC coefficient → quantised integer. The exact inverse of
    /// the decoder's `AdjustQuantBias(q) / qweight · invQuantAC`
    /// (the bias is a decode-side rounding refinement and is not
    /// inverted here — it self-corrects for `|q| ≥ 2`).
    @inline(__always)
    static func quantizeAC(
        _ coef: Float, weight: Float, scale: Float, qf: Int32
    ) -> Int32 {
        let v = coef * weight * scale * Float(qf)
        return Int32(v.rounded())
    }

    /// IEC 61966-2-1 sRGB inverse OETF — 8-bit code → linear [0,1].
    @inline(__always)
    static func srgb8ToLinear(_ v: UInt8) -> Float {
        let s = Float(v) / 255.0
        return s <= 0.04045
            ? s / 12.92
            : powf((s + 0.055) / 1.055, 2.4)
    }

    /// In-place 8×8 transpose.
    @inline(__always)
    static func transpose8(_ b: inout [Float]) {
        for r in 0..<8 {
            for c in (r + 1)..<8 {
                b.swapAt(r * 8 + c, c * 8 + r)
            }
        }
    }
}
