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
        /// DC sub-image. Every 8×8 cell has a DC value, including the
        /// four cells a DCT16×16 covers.
        public let dcQuant: [[Int32]]
        /// Per-block AC strategy, raster-indexed `ACStrategy.rawValue`
        /// (`0` = DCT8×8, `4` = DCT16×16). A multi-block transform's
        /// first-block and its covered cells carry the same value;
        /// the first-block / covered split is recovered by a raster
        /// walk (libjxl `ACStrategyImage`).
        public let acStrategy: [UInt8]
        /// Per-block quantised AC, `[blockIdx][xybChannel][...]`.
        /// A DCT8×8 first-block holds 64 coefficients; a DCT16×16
        /// first-block holds 256 (natural grid layout); covered cells
        /// of a multi-block transform are empty. LLF positions are 0
        /// (carried by the DC plane); X/Y/B are colour-decorrelated.
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

        let nBlocks = blocksX * blocksY
        var dcQuant: [[Int32]] = [
            [Int32](repeating: 0, count: nBlocks),
            [Int32](repeating: 0, count: nBlocks),
            [Int32](repeating: 0, count: nBlocks),
        ]
        // Per first-block AC; covered cells of a multi-block
        // transform stay empty `[[], [], []]`.
        var acQuant = [[[Int32]]](
            repeating: [[Int32]](repeating: [], count: 3),
            count: nBlocks)
        var acStrategy = [UInt8](repeating: 0, count: nBlocks)
        let dct16Raw = ACStrategy.dct16x16.rawValue

        // DCT16×16 quant weights (3 channels × 256) for the
        // AC-strategy DCT16 path.
        let qweights16: [Float]
        do {
            qweights16 = try QuantWeights.getQuantWeights(
                rows: 16, cols: 16, bands: DefaultQuantBands.dct16x16)
        } catch {
            throw EncoderError.unsupported(
                "VarDCT encode: DCT16 quant weights failed: \(error)")
        }

        // (3a) AC-strategy plane. A 16×16 region uses DCT16×16 when
        // it is flat enough that one large transform codes it better
        // than four DCT8×8 blocks. Regions sit on the even 2×2 block
        // grid, so a transform never straddles a group boundary
        // (group dims are multiples of 2 blocks). Edges that cannot
        // fit a 2×2 region keep DCT8×8.
        for ry in stride(from: 0, to: blocksY - 1, by: 2) {
            for rx in stride(from: 0, to: blocksX - 1, by: 2) {
                guard regionUsesDCT16(
                    planeY: planeY, bx: rx, by: ry, pw: pw) else {
                    continue
                }
                for (cdx, cdy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    acStrategy[(ry + cdy) * blocksX + (rx + cdx)]
                        = dct16Raw
                }
            }
        }

        // (3b) Per block: forward-transform + quantise. Walk blocks
        // in raster order tracking covered cells; an uncovered cell
        // is a transform's first-block.
        var covered = [Bool](repeating: false, count: nBlocks)
        var blkX = [Float](repeating: 0, count: 64)
        var blkY = [Float](repeating: 0, count: 64)
        var blkB = [Float](repeating: 0, count: 64)
        var patchX = [Float](repeating: 0, count: 256)
        var patchY = [Float](repeating: 0, count: 256)
        var patchBmY = [Float](repeating: 0, count: 256)
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                let blockIdx = by * blocksX + bx
                if covered[blockIdx] { continue }
                if acStrategy[blockIdx] == dct16Raw {
                    // --- DCT16×16 first-block --------------------
                    let px0 = bx * 8, py0 = by * 8
                    for r in 0..<16 {
                        let row = (py0 + r) * pw + px0
                        for c in 0..<16 {
                            let yv = planeY[row + c]
                            patchX[r * 16 + c] = planeX[row + c]
                            patchY[r * 16 + c] = yv
                            patchBmY[r * 16 + c] = planeB[row + c] - yv
                        }
                    }
                    let resX = forwardDCT16Block(
                        patch: patchX,
                        quantWeights: Array(qweights16[0..<256]),
                        scale: acScale, qf: qf)
                    let resY = forwardDCT16Block(
                        patch: patchY,
                        quantWeights: Array(qweights16[256..<512]),
                        scale: acScale, qf: qf)
                    let resB = forwardDCT16Block(
                        patch: patchBmY,
                        quantWeights: Array(qweights16[512..<768]),
                        scale: acScale, qf: qf)
                    // The 4 covered cells take their LLF-derived DC.
                    for (i, off) in [(0, 0), (1, 0), (0, 1), (1, 1)]
                        .enumerated() {
                        let cIdx = (by + off.1) * blocksX
                            + (bx + off.0)
                        dcQuant[0][cIdx] =
                            Int32((resX.dc[i] / mulDC[0]).rounded())
                        dcQuant[1][cIdx] =
                            Int32((resY.dc[i] / mulDC[1]).rounded())
                        dcQuant[2][cIdx] =
                            Int32((resB.dc[i] / mulDC[2]).rounded())
                        covered[cIdx] = true
                    }
                    acQuant[blockIdx] = [resX.ac, resY.ac, resB.ac]
                } else {
                    // --- DCT8×8 block ----------------------------
                    // The decoder runs `idct2D(transpose(coef))` for
                    // ROWS≥COLS, so `coef = transpose(dct2D(pixels))`.
                    let ox = bx * 8, oy = by * 8
                    for r in 0..<8 {
                        let row = (oy + r) * pw + ox
                        for c in 0..<8 {
                            blkX[r * 8 + c] = planeX[row + c]
                            blkY[r * 8 + c] = planeY[row + c]
                            blkB[r * 8 + c] = planeB[row + c]
                        }
                    }
                    AccelerateDCT.dct2D(&blkX, size: 8)
                    AccelerateDCT.dct2D(&blkY, size: 8)
                    AccelerateDCT.dct2D(&blkB, size: 8)
                    transpose8(&blkX)
                    transpose8(&blkY)
                    transpose8(&blkB)
                    // DC (coefficient 0). Default CfL: decoder folds
                    // `B += Y` (base correlation B = 1), `X += 0·Y`.
                    let dcBStored = blkB[0] - blkY[0]
                    dcQuant[0][blockIdx] =
                        Int32((blkX[0] / mulDC[0]).rounded())
                    dcQuant[1][blockIdx] =
                        Int32((blkY[0] / mulDC[1]).rounded())
                    dcQuant[2][blockIdx] =
                        Int32((dcBStored / mulDC[2]).rounded())
                    // AC (1..63), B decorrelated (`B − Y`).
                    var acX = [Int32](repeating: 0, count: 64)
                    var acY = [Int32](repeating: 0, count: 64)
                    var acB = [Int32](repeating: 0, count: 64)
                    for k in 1..<64 {
                        acX[k] = quantizeAC(
                            blkX[k], weight: qweights[0 * 64 + k],
                            scale: acScale, qf: qf)
                        acY[k] = quantizeAC(
                            blkY[k], weight: qweights[1 * 64 + k],
                            scale: acScale, qf: qf)
                        acB[k] = quantizeAC(
                            blkB[k] - blkY[k],
                            weight: qweights[2 * 64 + k],
                            scale: acScale, qf: qf)
                    }
                    acQuant[blockIdx] = [acX, acY, acB]
                    covered[blockIdx] = true
                }
            }
        }

        return Quantized(
            xsize: xsize, ysize: ysize,
            blocksX: blocksX, blocksY: blocksY,
            globalScale: globalScale, quantDC: quantDC, qf: qf,
            dcExtraPrecision: 0,
            dcQuant: dcQuant, acStrategy: acStrategy, acQuant: acQuant)
    }

    /// AC-strategy selection — true when the 16×16 Y region whose
    /// top-left 8×8 cell is block `(bx, by)` is flat enough to
    /// favour one DCT16×16 over four DCT8×8 transforms. A
    /// deliberately conservative variance test; a rate-distortion
    /// search is a later milestone.
    static func regionUsesDCT16(
        planeY: [Float], bx: Int, by: Int, pw: Int
    ) -> Bool {
        let px0 = bx * 8, py0 = by * 8
        var sum: Float = 0, sumSq: Float = 0
        for r in 0..<16 {
            let row = (py0 + r) * pw + px0
            for c in 0..<16 {
                let v = planeY[row + c]
                sum += v
                sumSq += v * v
            }
        }
        let n: Float = 256
        let mean = sum / n
        let variance = max(0, sumSq / n - mean * mean)
        // XYB-Y spans ~0…1; a near-flat region has tiny variance.
        return variance < 0.0008
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

    /// In-place N×N square transpose.
    @inline(__always)
    static func transposeSquare(_ b: inout [Float], size n: Int) {
        for r in 0..<n {
            for c in (r + 1)..<n {
                b.swapAt(r * n + c, c * n + r)
            }
        }
    }

    // MARK: - DCT16×16 block (AC-strategy foundation)

    /// Forward-transform + quantise one 16×16 single-channel patch
    /// as a DCT16×16 block — the analysis half of an `dct16x16`
    /// AC-strategy block.
    ///
    /// A DCT16×16 covers a 2×2 grid of 8×8 cells. Its 4
    /// lowest-frequency coefficients (grid positions 0, 1, 16, 17)
    /// are not AC-coded; they are converted to 4 DC-plane cell
    /// values via `dcFromLowestFrequencies16x16`. The returned
    /// `dc` holds those 4 float values (row-major over the covered
    /// cells — the caller quantises DC). `ac` is the 252 quantised
    /// AC coefficients laid out in the 256-entry natural grid (the
    /// 4 LLF positions are left 0; the AC coder skips them).
    ///
    /// `quantWeights` is this channel's 256-entry DCT16×16 quant
    /// matrix; `scale` and `qf` match `quantizeAC` for DCT8×8.
    static func forwardDCT16Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 256 && quantWeights.count == 256,
                     "DCT16 block needs a 16×16 patch + 256 weights")
        // Forward DCT16: `coef = transpose(dct2D(patch))` — the
        // bitstream coefficient layout (inverse of the decoder's
        // `transpose` + `idct2D` reconstruction).
        var coef = patch
        AccelerateDCT.dct2D(&coef, size: 16)
        transposeSquare(&coef, size: 16)
        // Split the 4 LLF coefficients into the DC-plane cells.
        let llf = [coef[0], coef[1], coef[16], coef[17]]
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequencies16x16(llf: llf)
        // Quantise the 252 AC coefficients in place.
        var ac = [Int32](repeating: 0, count: 256)
        for np in 0..<256
        where np != 0 && np != 1 && np != 16 && np != 17 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }
}
