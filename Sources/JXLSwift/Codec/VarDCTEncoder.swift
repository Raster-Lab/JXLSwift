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

        // Quant-weight tables for every multi-block AC strategy
        // emitted today: DCT16 / DCT32 / DCT64 (square), DCT8x16 /
        // DCT16x8 (ord 4), DCT16x32 / DCT32x16 (ord 6).
        let qweights16: [Float]
        let qweights32: [Float]
        let qweights64: [Float]
        let qweights8x16: [Float]
        let qweights16x32: [Float]
        let qweights32x64: [Float]
        do {
            qweights16 = try QuantWeights.getQuantWeights(
                rows: 16, cols: 16, bands: DefaultQuantBands.dct16x16)
            qweights32 = try QuantWeights.getQuantWeights(
                rows: 32, cols: 32, bands: DefaultQuantBands.dct32x32)
            qweights64 = try QuantWeights.getQuantWeights(
                rows: 64, cols: 64, bands: DefaultQuantBands.dct64x64)
            qweights8x16 = try QuantWeights.getQuantWeights(
                rows: 8, cols: 16, bands: DefaultQuantBands.dct8x16)
            qweights16x32 = try QuantWeights.getQuantWeights(
                rows: 16, cols: 32, bands: DefaultQuantBands.dct16x32)
            qweights32x64 = try QuantWeights.getQuantWeights(
                rows: 32, cols: 64, bands: DefaultQuantBands.dct32x64)
        } catch {
            throw EncoderError.unsupported(
                "VarDCT encode: multi-block quant weights failed: "
                + "\(error)")
        }
        // Small-block (single-cell) quant weights. `getDCT4QuantWeights`
        // and `getDCT4X8QuantWeights` are the libjxl `kQuantModeDCT4`
        // and `kQuantModeDCT4X8` fan-outs (4×4 / 4×8 weight tables
        // duplicated into the 3 × 8×8 small-block layout); the
        // DCT4×8 table is shared between DCT4×8 and DCT8×4.
        // `getDCT2QuantWeights` is the `kQuantModeDCT2X2` cascade
        // table — one 64-entry weight matrix per channel.
        let qweights4x4: [Float]
        let qweights4x8: [Float]
        let qweights2x2: [Float]
        let qweightsHornuss: [Float]
        let qweightsAFV: [Float]
        do {
            qweights4x4 = try QuantWeights.getDCT4QuantWeights(
                bands: DefaultQuantBands.dct4x4)
            qweights4x8 = try QuantWeights.getDCT4X8QuantWeights(
                bands: DefaultQuantBands.dct4x8)
            qweights2x2 = QuantWeights.getDCT2QuantWeights(
                DefaultQuantBands.dct2x2)
            qweightsHornuss = QuantWeights.getIdentityQuantWeights(
                DefaultQuantBands.identity)
            qweightsAFV = try QuantWeights.getAFVQuantWeights(
                dct4x8Bands: DefaultQuantBands.dct4x8,
                dct4x4Bands: DefaultQuantBands.dct4x4,
                afvWeights: DefaultQuantBands.afv)
        } catch {
            throw EncoderError.unsupported(
                "VarDCT encode: small-block quant weights failed: \(error)")
        }
        let dct32Raw = ACStrategy.dct32x32.rawValue
        let dct64Raw = ACStrategy.dct64x64.rawValue
        let dct16x8Raw = ACStrategy.dct16x8.rawValue
        let dct8x16Raw = ACStrategy.dct8x16.rawValue
        let dct32x16Raw = ACStrategy.dct32x16.rawValue
        let dct16x32Raw = ACStrategy.dct16x32.rawValue
        let dct64x32Raw = ACStrategy.dct64x32.rawValue
        let dct32x64Raw = ACStrategy.dct32x64.rawValue
        let dct4x4Raw = ACStrategy.dct4x4.rawValue
        let dct4x8Raw = ACStrategy.dct4x8.rawValue
        let dct8x4Raw = ACStrategy.dct8x4.rawValue
        let dct2x2Raw = ACStrategy.dct2x2.rawValue
        let hornussRaw = ACStrategy.hornuss.rawValue
        let afvRawByKind: [UInt8] = [
            ACStrategy.afv0.rawValue,
            ACStrategy.afv1.rawValue,
            ACStrategy.afv2.rawValue,
            ACStrategy.afv3.rawValue,
        ]

        // (3) Forward-transform + quantise with a hierarchical
        // **trial encode**. Every even-aligned 16×16 region is
        // quantised both as one DCT16×16 and as four DCT8×8s, the
        // cheaper kept; every 4-aligned 32×32 region additionally
        // trials one DCT32×32 against its four sub-regions' chosen
        // cost. Block-aligned grids keep a transform inside its
        // group; edges that cannot fit fall back to smaller blocks.
        let order8 = naturalCoeffOrderDCT8
        let order16 = CoeffOrders.naturalCoeffOrder(for: .dct16x16)
        let order32 = CoeffOrders.naturalCoeffOrder(for: .dct32x32)
        let order8x16 = CoeffOrders.naturalCoeffOrder(for: .dct8x16)
        let order16x32 = CoeffOrders.naturalCoeffOrder(for: .dct16x32)
        let order64 = CoeffOrders.naturalCoeffOrder(for: .dct64x64)
        let order32x64 = CoeffOrders.naturalCoeffOrder(for: .dct32x64)
        let qw8X = Array(qweights[0..<64])
        let qw8Y = Array(qweights[64..<128])
        let qw8B = Array(qweights[128..<192])
        let qw16X = Array(qweights16[0..<256])
        let qw16Y = Array(qweights16[256..<512])
        let qw16B = Array(qweights16[512..<768])
        let qw32X = Array(qweights32[0..<1024])
        let qw32Y = Array(qweights32[1024..<2048])
        let qw32B = Array(qweights32[2048..<3072])
        let qw8x16X = Array(qweights8x16[0..<128])
        let qw8x16Y = Array(qweights8x16[128..<256])
        let qw8x16B = Array(qweights8x16[256..<384])
        let qw16x32X = Array(qweights16x32[0..<512])
        let qw16x32Y = Array(qweights16x32[512..<1024])
        let qw16x32B = Array(qweights16x32[1024..<1536])
        let qw64X = Array(qweights64[0..<4096])
        let qw64Y = Array(qweights64[4096..<8192])
        let qw64B = Array(qweights64[8192..<12288])
        let qw32x64X = Array(qweights32x64[0..<2048])
        let qw32x64Y = Array(qweights32x64[2048..<4096])
        let qw32x64B = Array(qweights32x64[4096..<6144])
        let qw4x4X = Array(qweights4x4[0..<64])
        let qw4x4Y = Array(qweights4x4[64..<128])
        let qw4x4B = Array(qweights4x4[128..<192])
        let qw4x8X = Array(qweights4x8[0..<64])
        let qw4x8Y = Array(qweights4x8[64..<128])
        let qw4x8B = Array(qweights4x8[128..<192])
        let qw2x2X = Array(qweights2x2[0..<64])
        let qw2x2Y = Array(qweights2x2[64..<128])
        let qw2x2B = Array(qweights2x2[128..<192])
        let qwHornX = Array(qweightsHornuss[0..<64])
        let qwHornY = Array(qweightsHornuss[64..<128])
        let qwHornB = Array(qweightsHornuss[128..<192])
        let qwAFVX = Array(qweightsAFV[0..<64])
        let qwAFVY = Array(qweightsAFV[64..<128])
        let qwAFVB = Array(qweightsAFV[128..<192])
        var covered = [Bool](repeating: false, count: nBlocks)

        // Extract a `size`×`size` single-channel patch at block
        // origin `(bx, by)`.
        func patch(_ plane: [Float], _ bx: Int, _ by: Int,
                   _ size: Int) -> [Float] {
            let px0 = bx * 8, py0 = by * 8
            var out = [Float](repeating: 0, count: size * size)
            for r in 0..<size {
                let row = (py0 + r) * pw + px0
                for c in 0..<size {
                    out[r * size + c] = plane[row + c]
                }
            }
            return out
        }
        // The same, colour-decorrelated as `B − Y` for the B channel.
        func patchBmY(_ bx: Int, _ by: Int, _ size: Int) -> [Float] {
            let px0 = bx * 8, py0 = by * 8
            var out = [Float](repeating: 0, count: size * size)
            for r in 0..<size {
                let row = (py0 + r) * pw + px0
                for c in 0..<size {
                    out[r * size + c] =
                        planeB[row + c] - planeY[row + c]
                }
            }
            return out
        }
        // Rectangular extracts (asymmetric AC strategies). `wpx`/`hpx`
        // are pixel-space width / height.
        func patchRect(_ plane: [Float], _ bx: Int, _ by: Int,
                       _ wpx: Int, _ hpx: Int) -> [Float] {
            let px0 = bx * 8, py0 = by * 8
            var out = [Float](repeating: 0, count: wpx * hpx)
            for r in 0..<hpx {
                let row = (py0 + r) * pw + px0
                for c in 0..<wpx {
                    out[r * wpx + c] = plane[row + c]
                }
            }
            return out
        }
        func patchBmYRect(_ bx: Int, _ by: Int,
                          _ wpx: Int, _ hpx: Int) -> [Float] {
            let px0 = bx * 8, py0 = by * 8
            var out = [Float](repeating: 0, count: wpx * hpx)
            for r in 0..<hpx {
                let row = (py0 + r) * pw + px0
                for c in 0..<wpx {
                    out[r * wpx + c] =
                        planeB[row + c] - planeY[row + c]
                }
            }
            return out
        }
        // DCT8×8 of one block — quantised DC (3) + AC (3 × 64).
        func dct8Cell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardDCT8Block(
                patch: patch(planeX, bx, by, 8), quantWeights: qw8X,
                scale: acScale, qf: qf)
            let rY = forwardDCT8Block(
                patch: patch(planeY, bx, by, 8), quantWeights: qw8Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT8Block(
                patch: patchBmY(bx, by, 8), quantWeights: qw8B,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // DCT4×4 of one block — four 4×4 DCTs packed into the 8×8
        // libjxl small-block coef layout. Same outputs as `dct8Cell`
        // (3 DC + 3 × 64 AC), but a different transform.
        func dct4x4Cell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardDCT4x4Block(
                patch: patch(planeX, bx, by, 8), quantWeights: qw4x4X,
                scale: acScale, qf: qf)
            let rY = forwardDCT4x4Block(
                patch: patch(planeY, bx, by, 8), quantWeights: qw4x4Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT4x4Block(
                patch: patchBmY(bx, by, 8), quantWeights: qw4x4B,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // DCT4×8 of one block — two 4-tall × 8-wide DCTs stacked
        // vertically. Same outputs as `dct8Cell` (3 DC + 3 × 64 AC).
        func dct4x8Cell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardDCT4x8Block(
                patch: patch(planeX, bx, by, 8), quantWeights: qw4x8X,
                scale: acScale, qf: qf)
            let rY = forwardDCT4x8Block(
                patch: patch(planeY, bx, by, 8), quantWeights: qw4x8Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT4x8Block(
                patch: patchBmY(bx, by, 8), quantWeights: qw4x8B,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // DCT8×4 of one block — two 8-tall × 4-wide DCTs side-by-
        // side. Shares the DCT4×8 quant weights table.
        func dct8x4Cell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardDCT8x4Block(
                patch: patch(planeX, bx, by, 8), quantWeights: qw4x8X,
                scale: acScale, qf: qf)
            let rY = forwardDCT8x4Block(
                patch: patch(planeY, bx, by, 8), quantWeights: qw4x8Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT8x4Block(
                patch: patchBmY(bx, by, 8), quantWeights: qw4x8B,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // DCT2×2 of one block — hierarchical 2×2-Haar cascade.
        // Same outputs as `dct8Cell` (3 DC + 3 × 64 AC).
        func dct2x2Cell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardDCT2x2Block(
                patch: patch(planeX, bx, by, 8), quantWeights: qw2x2X,
                scale: acScale, qf: qf)
            let rY = forwardDCT2x2Block(
                patch: patch(planeY, bx, by, 8), quantWeights: qw2x2Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT2x2Block(
                patch: patchBmY(bx, by, 8), quantWeights: qw2x2B,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // Hornuss (IDENTITY) of one block — near-spatial transform.
        // Same outputs as `dct8Cell` (3 DC + 3 × 64 AC).
        func hornussCell(_ bx: Int, _ by: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardHornussBlock(
                patch: patch(planeX, bx, by, 8), quantWeights: qwHornX,
                scale: acScale, qf: qf)
            let rY = forwardHornussBlock(
                patch: patch(planeY, bx, by, 8), quantWeights: qwHornY,
                scale: acScale, qf: qf)
            let rB = forwardHornussBlock(
                patch: patchBmY(bx, by, 8), quantWeights: qwHornB,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // AFV (Asymmetric Frequency Variable) of one block at the
        // given `afvKind` orientation. Same outputs as `dct8Cell`.
        func afvCell(_ bx: Int, _ by: Int, kind: Int)
            -> (dc: [Int32], ac: [[Int32]]) {
            let rX = forwardAFVBlock(
                afvKind: kind,
                patch: patch(planeX, bx, by, 8), quantWeights: qwAFVX,
                scale: acScale, qf: qf)
            let rY = forwardAFVBlock(
                afvKind: kind,
                patch: patch(planeY, bx, by, 8), quantWeights: qwAFVY,
                scale: acScale, qf: qf)
            let rB = forwardAFVBlock(
                afvKind: kind,
                patch: patchBmY(bx, by, 8), quantWeights: qwAFVB,
                scale: acScale, qf: qf)
            return ([
                Int32((rX.dc / mulDC[0]).rounded()),
                Int32((rY.dc / mulDC[1]).rounded()),
                Int32((rB.dc / mulDC[2]).rounded()),
            ], [rX.ac, rY.ac, rB.ac])
        }
        // DCT16×16 of one region — quantised DC (3 × 4 cells) +
        // AC (3 × 256).
        func dct16Region(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT16Block(
                patch: patch(planeX, bx, by, 16), quantWeights: qw16X,
                scale: acScale, qf: qf)
            let rY = forwardDCT16Block(
                patch: patch(planeY, bx, by, 16), quantWeights: qw16Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT16Block(
                patch: patchBmY(bx, by, 16), quantWeights: qw16B,
                scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 4), count: 3)
            for i in 0..<4 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }

        // DCT16x8 of one vertical pair (cells stacked top + bottom)
        // — quantised DC (3 × 2 cells) + AC (3 × 128). The pair's
        // first-block sits at `(bx, by)`, its covered cell at
        // `(bx, by + 1)`; `dc[c][0]` is the top cell, `dc[c][1]` the
        // bottom.
        func dct16x8Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT16x8Block(
                patch: patchRect(planeX, bx, by, 8, 16),
                quantWeights: qw8x16X, scale: acScale, qf: qf)
            let rY = forwardDCT16x8Block(
                patch: patchRect(planeY, bx, by, 8, 16),
                quantWeights: qw8x16Y, scale: acScale, qf: qf)
            let rB = forwardDCT16x8Block(
                patch: patchBmYRect(bx, by, 8, 16),
                quantWeights: qw8x16B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 2), count: 3)
            for i in 0..<2 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT8x16 of one horizontal pair (cells side-by-side, left +
        // right). First-block at `(bx, by)`, covered at `(bx+1, by)`;
        // `dc[c][0]` is the left cell, `dc[c][1]` the right.
        func dct8x16Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT8x16Block(
                patch: patchRect(planeX, bx, by, 16, 8),
                quantWeights: qw8x16X, scale: acScale, qf: qf)
            let rY = forwardDCT8x16Block(
                patch: patchRect(planeY, bx, by, 16, 8),
                quantWeights: qw8x16Y, scale: acScale, qf: qf)
            let rB = forwardDCT8x16Block(
                patch: patchBmYRect(bx, by, 16, 8),
                quantWeights: qw8x16B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 2), count: 3)
            for i in 0..<2 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT32×16 of one vertical-half pair (cells: 2 cols × 4
        // rows, 16w × 32h pixel). First-block at `(bx, by)`,
        // covering `(bx..bx+1) × (by..by+3)` (8 cells). `dc[r*4+c]`
        // for r ∈ 0..2, c ∈ 0..4 — cell `(bx+r, by+c)`.
        func dct32x16Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT32x16Block(
                patch: patchRect(planeX, bx, by, 16, 32),
                quantWeights: qw16x32X, scale: acScale, qf: qf)
            let rY = forwardDCT32x16Block(
                patch: patchRect(planeY, bx, by, 16, 32),
                quantWeights: qw16x32Y, scale: acScale, qf: qf)
            let rB = forwardDCT32x16Block(
                patch: patchBmYRect(bx, by, 16, 32),
                quantWeights: qw16x32B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 8), count: 3)
            for i in 0..<8 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT16×32 of one horizontal-half pair (cells: 4 cols × 2
        // rows, 32w × 16h pixel). First-block at `(bx, by)`,
        // covering `(bx..bx+3) × (by..by+1)` (8 cells). `dc[r*4+c]`
        // for r ∈ 0..2, c ∈ 0..4 — cell `(bx+c, by+r)`.
        func dct16x32Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT16x32Block(
                patch: patchRect(planeX, bx, by, 32, 16),
                quantWeights: qw16x32X, scale: acScale, qf: qf)
            let rY = forwardDCT16x32Block(
                patch: patchRect(planeY, bx, by, 32, 16),
                quantWeights: qw16x32Y, scale: acScale, qf: qf)
            let rB = forwardDCT16x32Block(
                patch: patchBmYRect(bx, by, 32, 16),
                quantWeights: qw16x32B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 8), count: 3)
            for i in 0..<8 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT32×32 of one region — quantised DC (3 × 16 cells) +
        // AC (3 × 1024).
        func dct32Region(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT32Block(
                patch: patch(planeX, bx, by, 32), quantWeights: qw32X,
                scale: acScale, qf: qf)
            let rY = forwardDCT32Block(
                patch: patch(planeY, bx, by, 32), quantWeights: qw32Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT32Block(
                patch: patchBmY(bx, by, 32), quantWeights: qw32B,
                scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 16), count: 3)
            for i in 0..<16 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT64×32 of one vertical-half pair (cells: 4 cols × 8
        // rows, 32w × 64h pixel). First-block at (bx, by); covers
        // `(bx..bx+3) × (by..by+7)`. `dc[r*8+c]` ↔ cell `(bx+r, by+c)`.
        func dct64x32Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT64x32Block(
                patch: patchRect(planeX, bx, by, 32, 64),
                quantWeights: qw32x64X, scale: acScale, qf: qf)
            let rY = forwardDCT64x32Block(
                patch: patchRect(planeY, bx, by, 32, 64),
                quantWeights: qw32x64Y, scale: acScale, qf: qf)
            let rB = forwardDCT64x32Block(
                patch: patchBmYRect(bx, by, 32, 64),
                quantWeights: qw32x64B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 32), count: 3)
            for i in 0..<32 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT32×64 of one horizontal-half pair (cells: 8 cols × 4
        // rows, 64w × 32h pixel). First-block at (bx, by); covers
        // `(bx..bx+7) × (by..by+3)`. `dc[r*8+c]` ↔ cell `(bx+c, by+r)`.
        func dct32x64Pair(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT32x64Block(
                patch: patchRect(planeX, bx, by, 64, 32),
                quantWeights: qw32x64X, scale: acScale, qf: qf)
            let rY = forwardDCT32x64Block(
                patch: patchRect(planeY, bx, by, 64, 32),
                quantWeights: qw32x64Y, scale: acScale, qf: qf)
            let rB = forwardDCT32x64Block(
                patch: patchBmYRect(bx, by, 64, 32),
                quantWeights: qw32x64B, scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 32), count: 3)
            for i in 0..<32 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }
        // DCT64×64 of one region — quantised DC (3 × 64 cells) +
        // AC (3 × 4096).
        func dct64Region(_ bx: Int, _ by: Int)
            -> (dc: [[Int32]], ac: [[Int32]]) {
            let rX = forwardDCT64x64Block(
                patch: patch(planeX, bx, by, 64), quantWeights: qw64X,
                scale: acScale, qf: qf)
            let rY = forwardDCT64x64Block(
                patch: patch(planeY, bx, by, 64), quantWeights: qw64Y,
                scale: acScale, qf: qf)
            let rB = forwardDCT64x64Block(
                patch: patchBmY(bx, by, 64), quantWeights: qw64B,
                scale: acScale, qf: qf)
            var dc = [[Int32]](
                repeating: [Int32](repeating: 0, count: 64), count: 3)
            for i in 0..<64 {
                dc[0][i] = Int32((rX.dc[i] / mulDC[0]).rounded())
                dc[1][i] = Int32((rY.dc[i] / mulDC[1]).rounded())
                dc[2][i] = Int32((rB.dc[i] / mulDC[2]).rounded())
            }
            return (dc, [rX.ac, rY.ac, rB.ac])
        }

        let cellOffsets = [(0, 0), (1, 0), (0, 1), (1, 1)]
        // Commit one DCT8×8 block.
        // Per-cell trial — pick the cheapest single-cell strategy
        // among DCT8×8, DCT4×4, DCT4×8, DCT8×4, DCT2×2, Hornuss,
        // and the four AFV orientations. Sweet spots:
        //   • DCT8×8     — smooth gradients (low overall AC energy).
        //   • DCT4×4     — within-quadrant detail (cross-quadrant
        //                  high-freq wasted by DCT8×8).
        //   • DCT4×8     — sharp horizontal seam (top/bot halves flat).
        //   • DCT8×4     — sharp vertical seam (left/right halves flat).
        //   • DCT2×2     — multi-scale Haar detail (frequency content
        //                  at every cascade level simultaneously).
        //   • Hornuss    — near-spatial transform for flat / smooth
        //                  blocks where a full DCT would waste bits
        //                  on noise-floor high-frequency coefficients.
        //   • AFV0..3    — directional luminance edge concentrated
        //                  in one 4×4 corner (4 orientations).
        func bestSmallCell(_ bx: Int, _ by: Int)
            -> (strat: UInt8,
                dc: [Int32], ac: [[Int32]],
                cost: Int) {
            let c8 = dct8Cell(bx, by)
            let c44 = dct4x4Cell(bx, by)
            let c48 = dct4x8Cell(bx, by)
            let c84 = dct8x4Cell(bx, by)
            let c22 = dct2x2Cell(bx, by)
            let cH = hornussCell(bx, by)
            let cAFV = (0..<4).map { afvCell(bx, by, kind: $0) }
            var cost8 = 0, cost44 = 0, cost48 = 0
            var cost84 = 0, cost22 = 0, costH = 0
            var costAFV = [Int](repeating: 0, count: 4)
            for c in 0..<3 {
                cost8 += tokenCost(c8.ac[c], order: order8)
                cost44 += tokenCost(c44.ac[c], order: order8)
                cost48 += tokenCost(c48.ac[c], order: order8)
                cost84 += tokenCost(c84.ac[c], order: order8)
                cost22 += tokenCost(c22.ac[c], order: order8)
                costH += tokenCost(cH.ac[c], order: order8)
                for k in 0..<4 {
                    costAFV[k] += tokenCost(cAFV[k].ac[c], order: order8)
                }
            }
            var minCost = min(
                min(min(min(cost8, cost44), min(cost48, cost84)),
                    cost22),
                costH)
            for k in 0..<4 { minCost = min(minCost, costAFV[k]) }
            for k in 0..<4 where minCost == costAFV[k] {
                return (afvRawByKind[k],
                        cAFV[k].dc, cAFV[k].ac, costAFV[k])
            }
            if minCost == costH {
                return (hornussRaw, cH.dc, cH.ac, costH)
            }
            if minCost == cost22 {
                return (dct2x2Raw, c22.dc, c22.ac, cost22)
            }
            if minCost == cost44 {
                return (dct4x4Raw, c44.dc, c44.ac, cost44)
            }
            if minCost == cost48 {
                return (dct4x8Raw, c48.dc, c48.ac, cost48)
            }
            if minCost == cost84 {
                return (dct8x4Raw, c84.dc, c84.ac, cost84)
            }
            return (0, c8.dc, c8.ac, cost8)
        }
        // Commit one 8×8 cell with the cheapest single-cell strategy.
        func commitDCT8(_ bx: Int, _ by: Int) {
            let pick = bestSmallCell(bx, by)
            let idx = by * blocksX + bx
            dcQuant[0][idx] = pick.dc[0]
            dcQuant[1][idx] = pick.dc[1]
            dcQuant[2][idx] = pick.dc[2]
            acQuant[idx] = pick.ac
            acStrategy[idx] = pick.strat
            covered[idx] = true
        }
        // Commit one DCT16×8 vertical pair (top + bottom cells) —
        // first-block at (bx, by), covered cell at (bx, by+1).
        func commitDCT16x8Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            let coverIdx = (by + 1) * blocksX + bx
            for c in 0..<3 {
                dcQuant[c][firstIdx] = pair.dc[c][0]
                dcQuant[c][coverIdx] = pair.dc[c][1]
            }
            acStrategy[firstIdx] = dct16x8Raw
            acStrategy[coverIdx] = dct16x8Raw
            acQuant[firstIdx] = pair.ac
            acQuant[coverIdx] = [[], [], []]
            covered[firstIdx] = true
            covered[coverIdx] = true
        }
        // Commit one DCT8×16 horizontal pair (left + right cells) —
        // first-block at (bx, by), covered cell at (bx+1, by).
        func commitDCT8x16Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            let coverIdx = by * blocksX + (bx + 1)
            for c in 0..<3 {
                dcQuant[c][firstIdx] = pair.dc[c][0]
                dcQuant[c][coverIdx] = pair.dc[c][1]
            }
            acStrategy[firstIdx] = dct8x16Raw
            acStrategy[coverIdx] = dct8x16Raw
            acQuant[firstIdx] = pair.ac
            acQuant[coverIdx] = [[], [], []]
            covered[firstIdx] = true
            covered[coverIdx] = true
        }
        // Evaluate + commit one 16×16 region as the cheapest of four
        // partitionings: DCT16×16, two DCT16×8s (vertical split),
        // two DCT8×16s (horizontal split), or four DCT8×8s.
        func eval16Region(_ rx: Int, _ ry: Int) -> Int {
            let r16 = dct16Region(rx, ry)
            // Per-cell small-block trial — each of the 4 cells
            // independently picks the cheapest of DCT8/DCT4×4/
            // DCT4×8/DCT8×4 via `bestSmallCell`. The "four small
            // cells" cost is the sum of the per-cell minima.
            let cellPicks = cellOffsets.map {
                bestSmallCell(rx + $0.0, ry + $0.1)
            }
            // Vertical split — two DCT16×8 pairs (left + right cols).
            let pairV1 = dct16x8Pair(rx, ry)
            let pairV2 = dct16x8Pair(rx + 1, ry)
            // Horizontal split — two DCT8×16 pairs (top + bottom).
            let pairH1 = dct8x16Pair(rx, ry)
            let pairH2 = dct8x16Pair(rx, ry + 1)
            var cost16 = 0, costV = 0, costH = 0
            var costSmall = 0
            for pick in cellPicks { costSmall += pick.cost }
            for c in 0..<3 {
                cost16 += tokenCost(r16.ac[c], order: order16)
                costV += tokenCost(pairV1.ac[c], order: order8x16)
                costV += tokenCost(pairV2.ac[c], order: order8x16)
                costH += tokenCost(pairH1.ac[c], order: order8x16)
                costH += tokenCost(pairH2.ac[c], order: order8x16)
            }
            let minCost = min(min(cost16, costSmall), min(costV, costH))
            let firstIdx = ry * blocksX + rx
            if minCost == cost16 {
                for (i, off) in cellOffsets.enumerated() {
                    let cIdx = (ry + off.1) * blocksX + (rx + off.0)
                    acStrategy[cIdx] = dct16Raw
                    dcQuant[0][cIdx] = r16.dc[0][i]
                    dcQuant[1][cIdx] = r16.dc[1][i]
                    dcQuant[2][cIdx] = r16.dc[2][i]
                    acQuant[cIdx] = [[], [], []]
                    covered[cIdx] = true
                }
                acQuant[firstIdx] = r16.ac
                return cost16
            }
            if minCost == costV {
                commitDCT16x8Pair(rx, ry, pairV1)
                commitDCT16x8Pair(rx + 1, ry, pairV2)
                return costV
            }
            if minCost == costH {
                commitDCT8x16Pair(rx, ry, pairH1)
                commitDCT8x16Pair(rx, ry + 1, pairH2)
                return costH
            }
            for (i, off) in cellOffsets.enumerated() {
                let cIdx = (ry + off.1) * blocksX + (rx + off.0)
                let pick = cellPicks[i]
                acStrategy[cIdx] = pick.strat
                dcQuant[0][cIdx] = pick.dc[0]
                dcQuant[1][cIdx] = pick.dc[1]
                dcQuant[2][cIdx] = pick.dc[2]
                acQuant[cIdx] = pick.ac
                covered[cIdx] = true
            }
            return costSmall
        }

        // Commit one DCT32×16 pair (8 cells in a 2-col × 4-row
        // arrangement). `pair.dc[ch][r*4+c]` ↔ cell `(bx+r, by+c)`.
        func commitDCT32x16Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            for r in 0..<2 {
                for c in 0..<4 {
                    let cIdx = (by + c) * blocksX + (bx + r)
                    acStrategy[cIdx] = dct32x16Raw
                    for ch in 0..<3 {
                        dcQuant[ch][cIdx] = pair.dc[ch][r * 4 + c]
                    }
                    acQuant[cIdx] = [[], [], []]
                    covered[cIdx] = true
                }
            }
            acQuant[firstIdx] = pair.ac
        }
        // Commit one DCT16×32 pair (8 cells in a 4-col × 2-row
        // arrangement). `pair.dc[ch][r*4+c]` ↔ cell `(bx+c, by+r)`.
        func commitDCT16x32Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            for r in 0..<2 {
                for c in 0..<4 {
                    let cIdx = (by + r) * blocksX + (bx + c)
                    acStrategy[cIdx] = dct16x32Raw
                    for ch in 0..<3 {
                        dcQuant[ch][cIdx] = pair.dc[ch][r * 4 + c]
                    }
                    acQuant[cIdx] = [[], [], []]
                    covered[cIdx] = true
                }
            }
            acQuant[firstIdx] = pair.ac
        }
        // Commit one DCT64×32 pair (32 cells in a 4-col × 8-row
        // arrangement). `pair.dc[ch][r*8+c]` ↔ cell `(bx+r, by+c)`.
        func commitDCT64x32Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            for r in 0..<4 {
                for c in 0..<8 {
                    let cIdx = (by + c) * blocksX + (bx + r)
                    acStrategy[cIdx] = dct64x32Raw
                    for ch in 0..<3 {
                        dcQuant[ch][cIdx] = pair.dc[ch][r * 8 + c]
                    }
                    acQuant[cIdx] = [[], [], []]
                    covered[cIdx] = true
                }
            }
            acQuant[firstIdx] = pair.ac
        }
        // Commit one DCT32×64 pair (32 cells in an 8-col × 4-row
        // arrangement). `pair.dc[ch][r*8+c]` ↔ cell `(bx+c, by+r)`.
        func commitDCT32x64Pair(
            _ bx: Int, _ by: Int,
            _ pair: (dc: [[Int32]], ac: [[Int32]])
        ) {
            let firstIdx = by * blocksX + bx
            for r in 0..<4 {
                for c in 0..<8 {
                    let cIdx = (by + r) * blocksX + (bx + c)
                    acStrategy[cIdx] = dct32x64Raw
                    for ch in 0..<3 {
                        dcQuant[ch][cIdx] = pair.dc[ch][r * 8 + c]
                    }
                    acQuant[cIdx] = [[], [], []]
                    covered[cIdx] = true
                }
            }
            acQuant[firstIdx] = pair.ac
        }

        // 16 sub-cell offsets `(col, row)` within a 32×32 region.
        var cell16: [(Int, Int)] = []
        for r in 0..<4 { for c in 0..<4 { cell16.append((c, r)) } }
        // 64 sub-cell offsets `(col, row)` within a 64×64 region.
        var cell64: [(Int, Int)] = []
        for r in 0..<8 { for c in 0..<8 { cell64.append((c, r)) } }
        // Evaluate + commit one 32×32 region as the cheapest of
        // DCT32×32 / two DCT32×16 / two DCT16×32 / four 16×16
        // sub-regions (each itself a four-way trial). Returns the
        // chosen token cost so a larger enclosing 64×64 region can
        // compare its DCT64 cost against summed sub-region costs.
        func eval32Region(_ rx: Int, _ ry: Int) -> Int {
            let r32 = dct32Region(rx, ry)
            let pV1 = dct32x16Pair(rx, ry)
            let pV2 = dct32x16Pair(rx + 2, ry)
            let pH1 = dct16x32Pair(rx, ry)
            let pH2 = dct16x32Pair(rx, ry + 2)
            var cost32 = 0, costV = 0, costH = 0
            for c in 0..<3 {
                cost32 += tokenCost(r32.ac[c], order: order32)
                costV += tokenCost(pV1.ac[c], order: order16x32)
                costV += tokenCost(pV2.ac[c], order: order16x32)
                costH += tokenCost(pH1.ac[c], order: order16x32)
                costH += tokenCost(pH2.ac[c], order: order16x32)
            }
            var cost16group = 0
            for (sx, sy) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
                cost16group += eval16Region(rx + sx, ry + sy)
            }
            let minCost = min(
                min(cost32, cost16group),
                min(costV, costH))
            if minCost == cost16group { return cost16group }
            // A multi-block partitioning wins — overwrite the
            // sub-region commits.
            if minCost == cost32 {
                let firstIdx = ry * blocksX + rx
                for (i, off) in cell16.enumerated() {
                    let cIdx = (ry + off.1) * blocksX + (rx + off.0)
                    acStrategy[cIdx] = dct32Raw
                    dcQuant[0][cIdx] = r32.dc[0][i]
                    dcQuant[1][cIdx] = r32.dc[1][i]
                    dcQuant[2][cIdx] = r32.dc[2][i]
                    acQuant[cIdx] = [[], [], []]
                }
                acQuant[firstIdx] = r32.ac
                return cost32
            } else if minCost == costV {
                commitDCT32x16Pair(rx, ry, pV1)
                commitDCT32x16Pair(rx + 2, ry, pV2)
                return costV
            } else {
                commitDCT16x32Pair(rx, ry, pH1)
                commitDCT16x32Pair(rx, ry + 2, pH2)
                return costH
            }
        }
        // 64×64 pass — trial DCT64×64 / two DCT64×32 (vertical
        // halves) / two DCT32×64 (horizontal halves) against the
        // four sub-32×32-region cost (each itself a hierarchical
        // trial). The cheapest wins; the four sub-region commits
        // stand when none of the multi-block options beat them.
        for ry in stride(from: 0, to: blocksY - 7, by: 8) {
            for rx in stride(from: 0, to: blocksX - 7, by: 8) {
                let r64 = dct64Region(rx, ry)
                let pV1 = dct64x32Pair(rx, ry)         // left half
                let pV2 = dct64x32Pair(rx + 4, ry)      // right half
                let pH1 = dct32x64Pair(rx, ry)          // top half
                let pH2 = dct32x64Pair(rx, ry + 4)      // bottom half
                var cost64 = 0, costV = 0, costH = 0
                for c in 0..<3 {
                    cost64 += tokenCost(r64.ac[c], order: order64)
                    costV += tokenCost(pV1.ac[c], order: order32x64)
                    costV += tokenCost(pV2.ac[c], order: order32x64)
                    costH += tokenCost(pH1.ac[c], order: order32x64)
                    costH += tokenCost(pH2.ac[c], order: order32x64)
                }
                var cost32group = 0
                for (sx, sy) in [(0, 0), (4, 0), (0, 4), (4, 4)] {
                    cost32group += eval32Region(rx + sx, ry + sy)
                }
                let minCost = min(
                    min(cost64, cost32group),
                    min(costV, costH))
                if minCost == cost32group { continue }
                if minCost == cost64 {
                    let firstIdx = ry * blocksX + rx
                    for (i, off) in cell64.enumerated() {
                        let cIdx = (ry + off.1) * blocksX
                            + (rx + off.0)
                        acStrategy[cIdx] = dct64Raw
                        dcQuant[0][cIdx] = r64.dc[0][i]
                        dcQuant[1][cIdx] = r64.dc[1][i]
                        dcQuant[2][cIdx] = r64.dc[2][i]
                        acQuant[cIdx] = [[], [], []]
                    }
                    acQuant[firstIdx] = r64.ac
                } else if minCost == costV {
                    commitDCT64x32Pair(rx, ry, pV1)
                    commitDCT64x32Pair(rx + 4, ry, pV2)
                } else {
                    commitDCT32x64Pair(rx, ry, pH1)
                    commitDCT32x64Pair(rx, ry + 4, pH2)
                }
            }
        }
        // 32×32 pass — 4-aligned regions not already covered.
        for ry in stride(from: 0, to: blocksY - 3, by: 4) {
            for rx in stride(from: 0, to: blocksX - 3, by: 4) {
                if covered[ry * blocksX + rx] { continue }
                _ = eval32Region(rx, ry)
            }
        }
        // 16×16 pass — even-aligned regions not already covered.
        for ry in stride(from: 0, to: blocksY - 1, by: 2) {
            for rx in stride(from: 0, to: blocksX - 1, by: 2) {
                if covered[ry * blocksX + rx] { continue }
                _ = eval16Region(rx, ry)
            }
        }
        // Edge pass — any block still uncovered keeps DCT8×8.
        for by in 0..<blocksY {
            for bx in 0..<blocksX {
                if covered[by * blocksX + bx] { continue }
                commitDCT8(bx, by)
            }
        }

        return Quantized(
            xsize: xsize, ysize: ysize,
            blocksX: blocksX, blocksY: blocksY,
            globalScale: globalScale, quantDC: quantDC, qf: qf,
            dcExtraPrecision: 0,
            dcQuant: dcQuant, acStrategy: acStrategy, acQuant: acQuant)
    }

    /// Estimated token cost (in rough bit units) of one block's
    /// quantised AC coefficients — `4` for the `nzeros` token, `2`
    /// per scan position up to the last non-zero (the run
    /// structure), plus the magnitude bits of each non-zero. The AC
    /// coder emits a token for every scan position up to the last
    /// non-zero, so the cost is dominated by that position; this
    /// drives the DCT8 / DCT16 trial-encode choice.
    static func tokenCost(_ ac: [Int32], order: [Int]) -> Int {
        let size = ac.count
        let coveredBlocks = size / 64
        var lastNZ = 0
        for s in coveredBlocks..<size where ac[order[s]] != 0 {
            lastNZ = s
        }
        var cost = 4 + 2 * lastNZ
        if lastNZ >= coveredBlocks {
            for s in coveredBlocks...lastNZ {
                let q = ac[order[s]]
                if q != 0 {
                    cost += 32 - q.magnitude.leadingZeroBitCount
                }
            }
        }
        return cost
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

    // MARK: - DCT block analysis (AC strategy)

    /// Forward-transform + quantise one 8×8 single-channel patch as
    /// a DCT8×8 block. Returns the DC coefficient (float — the
    /// caller quantises DC) and the 63 quantised AC coefficients in
    /// natural grid layout (position 0 left 0). Pass a `B − Y` patch
    /// for the B channel to bake in the default colour correlation.
    static func forwardDCT8Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "DCT8 block needs an 8×8 patch + 64 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, size: 8)
        transpose8(&coef)
        var ac = [Int32](repeating: 0, count: 64)
        for k in 1..<64 {
            ac[k] = quantizeAC(
                coef[k], weight: quantWeights[k], scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

    /// Forward-transform + quantise one 8×8 single-channel patch as a
    /// DCT4×4 block — the analysis half of a `dct4x4` AC-strategy
    /// cell. The 8×8 cell is split into four 4×4 quadrants; each is
    /// forward-DCT'd, and the 64 output coefficients are laid out in
    /// the libjxl packed scheme: the four quadrant DCs combine by a
    /// 2×2 Haar into positions `(0,0)`, `(0,1)`, `(1,0)`, `(1,1)` of
    /// the 8×8 coef grid (the cell DC + three top-left AC), and each
    /// quadrant's 15 ACs are strided-scattered into positions
    /// `(y + iy·2, x + ix·2)` for `(iy, ix) ∈ [0,4) × [0,4) \ {(0,0)}`.
    /// Returns the cell-DC (which the caller routes through the DC
    /// plane) and the 63 quantised AC coefficients in the 64-entry
    /// natural grid (position 0 left 0). Exact inverse of
    /// `DCT4x4Transform.transformToPixels`.
    static func forwardDCT4x4Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "DCT4×4 block needs an 8×8 patch + 64 weights")
        // (1) Forward 4×4 DCT on each quadrant. The decoder applies
        // `transposeSquareInPlace(4) → idct2D(4)`; the encoder is its
        // inverse — `dct2D(4) → transposeSquareInPlace(4)`.
        var quadCoef = [[Float]](
            repeating: [Float](repeating: 0, count: 16), count: 4)
        var quadDC = [Float](repeating: 0, count: 4)
        for y in 0..<2 {
            for x in 0..<2 {
                var block = [Float](repeating: 0, count: 16)
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        block[iy * 4 + ix] =
                            patch[(y * 4 + iy) * 8 + x * 4 + ix]
                    }
                }
                AccelerateDCT.dct2D(&block, size: 4)
                transposeSquare(&block, size: 4)
                quadCoef[y * 2 + x] = block
                quadDC[y * 2 + x] = block[0]
            }
        }
        // (2) Inverse 2×2 Haar over the four quadrant DCs — undoes
        // the decoder's `dcs[k] = ±block00 ± block01 ± block10 ± block11`
        // packing into positions `block00/01/10/11`.
        let d0 = quadDC[0], d1 = quadDC[1], d2 = quadDC[2], d3 = quadDC[3]
        let b00 = (d0 + d1 + d2 + d3) * 0.25
        let b01 = (d0 + d1 - d2 - d3) * 0.25
        let b10 = (d0 - d1 + d2 - d3) * 0.25
        let b11 = (d0 - d1 - d2 + d3) * 0.25
        var coef = [Float](repeating: 0, count: 64)
        coef[0] = b00; coef[1] = b01
        coef[8] = b10; coef[9] = b11
        // (3) Strided-scatter each quadrant's 15 AC coefficients.
        for y in 0..<2 {
            for x in 0..<2 {
                let q = quadCoef[y * 2 + x]
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        if ix == 0 && iy == 0 { continue }
                        coef[(y + iy * 2) * 8 + x + ix * 2] =
                            q[iy * 4 + ix]
                    }
                }
            }
        }
        // (4) Quantise the 63 AC coefficients (position 0 = cell DC).
        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

    /// Forward AFV (Asymmetric Frequency Variable) transform — the
    /// analysis half of an `afv{0,1,2,3}` AC-strategy cell. AFV
    /// partitions the 8×8 cell into three sub-regions:
    ///   • 4×4 AFV-corner at `(afvY·4, afvX·4)` — uses `AFV.fdct4x4`
    ///     (orthonormal matrix transform).
    ///   • 4×4 IDCT-corner at the opposite-x half, same y-range —
    ///     uses forward DCT4×4 (`dct2D(4) → transpose`).
    ///   • 4×8 IDCT half at the opposite-y range, full width —
    ///     uses `dct2D(rows: 4, cols: 8)`.
    /// Three sub-DCs (`dc0`, `dc1`, `dc2`) — one per sub-region —
    /// combine into the top-left 2×2 (`coef[0]`, `coef[1]`, `coef[8]`)
    /// via the inverse of the decoder's mix `(dc0 = 4·(c[0]+c[8]+c[1])`,
    /// `dc1 = c[0]+c[8]−c[1]`, `dc2 = c[0]−c[8])`. Exact inverse of
    /// `AFV.transformToPixels(afvKind:)`.
    static func forwardAFVBlock(
        afvKind: Int, patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "AFV block needs an 8×8 patch + 64 weights")
        precondition(afvKind >= 0 && afvKind < 4,
                     "AFV kind must be 0..3")
        let afvX = afvKind & 1
        let afvY = afvKind / 2
        var coef = [Float](repeating: 0, count: 64)

        // (1) AFV 4×4 corner. Extract the 4×4 patch (with the
        // libjxl orientation flip), forward-AFV, scatter the 15
        // ACs to (iy·2, ix·2) positions, capture dc0.
        var afvPix = [Float](repeating: 0, count: 16)
        for iy in 0..<4 {
            for ix in 0..<4 {
                let srcY = (afvY == 1) ? (3 - iy) : iy
                let srcX = (afvX == 1) ? (3 - ix) : ix
                afvPix[srcY * 4 + srcX] =
                    patch[(iy + afvY * 4) * 8 + afvX * 4 + ix]
            }
        }
        var afvCoeffs = [Float](repeating: 0, count: 16)
        AFV.fdct4x4(afvPix, &afvCoeffs)
        let dc0 = afvCoeffs[0]
        for iy in 0..<4 {
            for ix in 0..<4 {
                if ix == 0 && iy == 0 { continue }
                coef[iy * 2 * 8 + ix * 2] = afvCoeffs[iy * 4 + ix]
            }
        }

        // (2) IDCT-4×4 corner (opposite-x, same y-range). Extract,
        // forward DCT4×4 with the transpose convention matching the
        // decoder's `transposeSquareInPlace → idct2D`, scatter the
        // 15 ACs to (iy·2, ix·2+1) positions, capture dc1.
        let idct4x4ColOrigin = (afvX == 1) ? 0 : 4
        var dct44Pix = [Float](repeating: 0, count: 16)
        for iy in 0..<4 {
            for ix in 0..<4 {
                dct44Pix[iy * 4 + ix] =
                    patch[(iy + afvY * 4) * 8 + idct4x4ColOrigin + ix]
            }
        }
        AccelerateDCT.dct2D(&dct44Pix, size: 4)
        transposeSquare(&dct44Pix, size: 4)
        let dc1 = dct44Pix[0]
        for iy in 0..<4 {
            for ix in 0..<4 {
                if ix == 0 && iy == 0 { continue }
                coef[iy * 2 * 8 + ix * 2 + 1] = dct44Pix[iy * 4 + ix]
            }
        }

        // (3) IDCT-4×8 half (opposite-y, full width). Extract,
        // forward `dct2D(rows: 4, cols: 8)` (ROWS<COLS, natural =
        // storage), scatter the 31 ACs to (1 + iy·2, ix) positions,
        // capture dc2.
        let idct4x8RowOrigin = (afvY == 1) ? 0 : 4
        var dct48Pix = [Float](repeating: 0, count: 32)
        for iy in 0..<4 {
            for ix in 0..<8 {
                dct48Pix[iy * 8 + ix] =
                    patch[(iy + idct4x8RowOrigin) * 8 + ix]
            }
        }
        AccelerateDCT.dct2D(&dct48Pix, rows: 4, cols: 8)
        let dc2 = dct48Pix[0]
        for iy in 0..<4 {
            for ix in 0..<8 {
                if ix == 0 && iy == 0 { continue }
                coef[(1 + iy * 2) * 8 + ix] = dct48Pix[iy * 8 + ix]
            }
        }

        // (4) Inverse the DC decomposition. Decoder:
        //   dc0 = 4·(c[0] + c[8] + c[1])
        //   dc1 = c[0] + c[8] − c[1]
        //   dc2 = c[0] − c[8]
        // Solving for (c[0], c[1], c[8]):
        //   q = dc0 / 4 = c[0] + c[8] + c[1]
        //   c[1] = (q − dc1) / 2
        //   c[0] = (q + dc1 + 2·dc2) / 4
        //   c[8] = (q + dc1 − 2·dc2) / 4
        let q = dc0 * 0.25
        coef[0] = (q + dc1 + 2 * dc2) * 0.25
        coef[1] = (q - dc1) * 0.5
        coef[8] = (q + dc1 - 2 * dc2) * 0.25

        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

    /// Forward IDENTITY ("hornuss") transform — the analysis half
    /// of a `hornuss` AC-strategy cell. Each 4×4 quadrant carries a
    /// 2×2-DCT-combined block DC plus 15 spatial residuals around a
    /// quadrant centre pixel (the `(1,1)` of the 4×4). Unlike the
    /// DCT strategies, this is a near-spatial transform — useful
    /// for flat / smooth-block content where a full DCT would waste
    /// bits on noise-floor high-frequency coefficients. Exact
    /// inverse of `IdentityTransform.transformToPixels`.
    static func forwardHornussBlock(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "Hornuss block needs an 8×8 patch + 64 weights")
        var coef = [Float](repeating: 0, count: 64)
        var blockDCs = [Float](repeating: 0, count: 4)
        for y in 0..<2 {
            for x in 0..<2 {
                let center = patch[(y * 4 + 1) * 8 + x * 4 + 1]
                var residualSum: Float = 0
                // 15 residuals — for (iy, ix) ∈ 4×4 \ {(0, 0)}, the
                // coef at the strided position `(y + iy·2, x + ix·2)`
                // is the residual of one specific pixel:
                //   • (iy, ix) = (1, 1) → pixel (y·4, x·4) — the
                //     decoder's "corner overwrite" — coef[(y+2)·8 + x+2]
                //     carries the (0,0)-pixel residual.
                //   • otherwise → pixel (y·4 + iy, x·4 + ix).
                for iy in 0..<4 {
                    for ix in 0..<4 {
                        if ix == 0 && iy == 0 { continue }
                        let coefIdx =
                            (y + iy * 2) * 8 + x + ix * 2
                        let pixIdx: Int
                        if ix == 1 && iy == 1 {
                            pixIdx = (y * 4) * 8 + (x * 4)
                        } else {
                            pixIdx =
                                (y * 4 + iy) * 8 + (x * 4 + ix)
                        }
                        let residual = patch[pixIdx] - center
                        coef[coefIdx] = residual
                        residualSum += residual
                    }
                }
                // Decoder: center = blockDC − residualSum / 16.
                // Encoder: blockDC = center + residualSum / 16.
                blockDCs[y * 2 + x] =
                    center + residualSum * (1.0 / 16.0)
            }
        }
        // 2×2 forward DCT of the four block DCs into coef[0]/[1]/[8]/[9].
        let d0 = blockDCs[0], d1 = blockDCs[1]
        let d2 = blockDCs[2], d3 = blockDCs[3]
        coef[0] = (d0 + d1 + d2 + d3) * 0.25
        coef[1] = (d0 + d1 - d2 - d3) * 0.25
        coef[8] = (d0 - d1 + d2 - d3) * 0.25
        coef[9] = (d0 - d1 - d2 + d3) * 0.25
        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

    /// Forward-transform + quantise one 8×8 single-channel patch as a
    /// DCT2×2 block — the analysis half of a `dct2x2` AC-strategy
    /// cell. DCT2×2 is the hierarchical 2×2-Haar cascade: at each
    /// scale `s ∈ {8, 4, 2}` the top-left `s×s` region's `(s/2)²`
    /// dense 2×2 pixel groups are each replaced by their 2×2 Haar
    /// (DC + 3 ACs), with the DC stored at `(y, x)` and the three
    /// ACs at `(y, x+s/2)`, `(y+s/2, x)`, `(y+s/2, x+s/2)`. The DC
    /// of the largest scale becomes the cell DC at coef[0], and
    /// each level's three ACs occupy the remaining 63 positions.
    /// Exact inverse of `DCT2x2Transform.transformToPixels`
    /// (`idct2TopBlock` cascade at s = 2 → 4 → 8).
    static func forwardDCT2x2Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "DCT2×2 block needs an 8×8 patch + 64 weights")
        var block = patch
        for s in [8, 4, 2] {
            var temp = block
            let num2x2 = s / 2
            for y in 0..<num2x2 {
                for x in 0..<num2x2 {
                    let t00 = block[2 * y * 8 + 2 * x]
                    let t01 = block[2 * y * 8 + 2 * x + 1]
                    let t10 = block[(2 * y + 1) * 8 + 2 * x]
                    let t11 = block[(2 * y + 1) * 8 + 2 * x + 1]
                    // Forward 2×2 Haar — exact inverse of the
                    // decoder's c00+c01+c10+c11 / ± expansion.
                    temp[y * 8 + x] =
                        (t00 + t01 + t10 + t11) * 0.25
                    temp[y * 8 + x + num2x2] =
                        (t00 + t01 - t10 - t11) * 0.25
                    temp[(y + num2x2) * 8 + x] =
                        (t00 - t01 + t10 - t11) * 0.25
                    temp[(y + num2x2) * 8 + x + num2x2] =
                        (t00 - t01 - t10 + t11) * 0.25
                }
            }
            for y in 0..<s {
                for x in 0..<s { block[y * 8 + x] = temp[y * 8 + x] }
            }
        }
        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                block[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (block[0], ac)
    }

    /// Forward-transform + quantise one 8×8 single-channel patch as a
    /// DCT4×8 block — the analysis half of a `dct4x8` AC-strategy
    /// cell. The 8×8 cell is split into two 4-tall × 8-wide halves
    /// stacked vertically; each is forward-DCT'd (ROWS<COLS, natural
    /// = storage layout), and the 64 output coefficients are packed
    /// into the libjxl small-block scheme: the two half DCs combine
    /// by a 1-D DCT-2 into `coef[0]` (sum / 2) and `coef[8]`
    /// (diff / 2), and each half's 31 ACs are strided-scattered to
    /// positions `(y + iy·2, ix)` for `(iy, ix) ∈ [0,4) × [0,8) \ {(0,0)}`.
    /// Exact inverse of `DCT4x8Transform.transformToPixels`.
    static func forwardDCT4x8Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "DCT4×8 block needs an 8×8 patch + 64 weights")
        var coef = [Float](repeating: 0, count: 64)
        var halfDC = [Float](repeating: 0, count: 2)
        for y in 0..<2 {
            // Extract the 4-tall × 8-wide half (natural layout).
            var half = [Float](repeating: 0, count: 32)
            for py in 0..<4 {
                for px in 0..<8 {
                    half[py * 8 + px] = patch[(y * 4 + py) * 8 + px]
                }
            }
            // ROWS<COLS: forward 2-D DCT, no transpose (natural ==
            // storage for `ScaledIDCT.transform`).
            AccelerateDCT.dct2D(&half, rows: 4, cols: 8)
            halfDC[y] = half[0]
            for iy in 0..<4 {
                for ix in 0..<8 {
                    if ix == 0 && iy == 0 { continue }
                    coef[(y + iy * 2) * 8 + ix] = half[iy * 8 + ix]
                }
            }
        }
        // 1-D DCT-2 combine of the two half DCs: dcs[0] = c[0]+c[8],
        // dcs[1] = c[0]-c[8] → c[0] = (dcs[0]+dcs[1])/2,
        // c[8] = (dcs[0]-dcs[1])/2.
        coef[0] = (halfDC[0] + halfDC[1]) * 0.5
        coef[8] = (halfDC[0] - halfDC[1]) * 0.5
        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

    /// Forward-transform + quantise one 8×8 single-channel patch as a
    /// DCT8×4 block — the analysis half of a `dct8x4` AC-strategy
    /// cell. The 8×8 cell is split into two 8-tall × 4-wide halves
    /// side-by-side; each is forward-DCT'd then transposed into the
    /// 4-row × 8-col storage layout (ROWS≥COLS — `ScaledIDCT.transform`
    /// transposes back before IDCT). Same 1-D DC combine and strided
    /// AC packing as DCT4×8, with the per-half indexing transposed:
    /// each half's 31 ACs strided-scatter to `(x + iy·2, ix)` for
    /// `(iy, ix) ∈ [0,4) × [0,8) \ {(0,0)}`. Exact inverse of
    /// `DCT8x4Transform.transformToPixels`.
    static func forwardDCT8x4Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: Float, ac: [Int32]) {
        precondition(patch.count == 64 && quantWeights.count == 64,
                     "DCT8×4 block needs an 8×8 patch + 64 weights")
        var coef = [Float](repeating: 0, count: 64)
        var halfDC = [Float](repeating: 0, count: 2)
        for x in 0..<2 {
            // Extract the 8-tall × 4-wide half (natural layout).
            var half = [Float](repeating: 0, count: 32)
            for py in 0..<8 {
                for px in 0..<4 {
                    half[py * 4 + px] = patch[py * 8 + x * 4 + px]
                }
            }
            // ROWS≥COLS: forward 2-D DCT in natural layout, then
            // transpose to storage (4 rows × 8 cols, the C×R form
            // `ScaledIDCT.transform` un-transposes before IDCT).
            AccelerateDCT.dct2D(&half, rows: 8, cols: 4)
            var storage = [Float](repeating: 0, count: 32)
            for r in 0..<8 {
                for c in 0..<4 {
                    storage[c * 8 + r] = half[r * 4 + c]
                }
            }
            halfDC[x] = storage[0]
            for iy in 0..<4 {
                for ix in 0..<8 {
                    if ix == 0 && iy == 0 { continue }
                    coef[(x + iy * 2) * 8 + ix] = storage[iy * 8 + ix]
                }
            }
        }
        coef[0] = (halfDC[0] + halfDC[1]) * 0.5
        coef[8] = (halfDC[0] - halfDC[1]) * 0.5
        var ac = [Int32](repeating: 0, count: 64)
        for np in 1..<64 {
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (coef[0], ac)
    }

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

    /// Forward-transform + quantise one 32×32 single-channel patch
    /// as a DCT32×32 block. A DCT32×32 covers a 4×4 grid of 8×8
    /// cells; its 16 lowest-frequency coefficients (the 4×4 corner
    /// of the 32×32 grid) become 16 DC-plane cell values via
    /// `dcFromLowestFrequencies32x32`. Returns those 16 float DC
    /// values (row-major over the covered cells — the caller
    /// quantises DC) and the 1008 quantised AC coefficients in the
    /// 1024-entry natural grid (the 16 LLF positions left 0).
    static func forwardDCT32Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 1024
                     && quantWeights.count == 1024,
                     "DCT32 block needs a 32×32 patch + 1024 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, size: 32)
        transposeSquare(&coef, size: 32)
        // The 16 LLF coefficients — the 4×4 low-frequency corner.
        var llf = [Float](repeating: 0, count: 16)
        for r in 0..<4 {
            for c in 0..<4 { llf[r * 4 + c] = coef[r * 32 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequencies32x32(llf: llf)
        var ac = [Int32](repeating: 0, count: 1024)
        for r in 0..<32 {
            for c in 0..<32 where !(r < 4 && c < 4) {
                let np = r * 32 + c
                ac[np] = quantizeAC(
                    coef[np], weight: quantWeights[np],
                    scale: scale, qf: qf)
            }
        }
        return (dc, ac)
    }

    /// Forward + quantise one 8-row × 16-col patch as a DCT8×16
    /// block (libjxl ord 4). The patch shares its layout with the
    /// decoder's `idct2D(rows: 8, cols: 16)` output for DCT8×16, so
    /// no transpose is needed. Returns the 2 LLF-derived DC values
    /// in the strategy's natural cell order (left-then-right) and
    /// 126 quantised AC coefficients (positions 0, 1 left 0).
    static func forwardDCT8x16Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 128
                     && quantWeights.count == 128,
                     "DCT8x16 block needs a 128-entry patch "
                     + "+ 128 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, rows: 8, cols: 16)
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd4Pair(llf: [coef[0], coef[1]])
        var ac = [Int32](repeating: 0, count: 128)
        for k in 2..<128 {
            ac[k] = quantizeAC(
                coef[k], weight: quantWeights[k],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }

    /// Forward + quantise one 16-row × 8-col patch as a DCT16×8
    /// block (libjxl ord 4). Pixel layout is 16h × 8w; the coef
    /// layout the decoder consumes is 8-row × 16-col, so the
    /// encoder transposes the patch before the DCT (the decoder
    /// transposes the IDCT output back to pixels). Returns the 2
    /// LLF-derived DC values (top-then-bottom) and 126 quantised
    /// AC coefficients (positions 0, 1 left 0).
    static func forwardDCT16x8Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 128
                     && quantWeights.count == 128,
                     "DCT16x8 block needs a 128-entry patch "
                     + "+ 128 weights")
        // Transpose 16-row × 8-col → 8-row × 16-col so the DCT's
        // coefficient layout matches the decoder's.
        var ar = [Float](repeating: 0, count: 128)
        for r in 0..<8 {
            for c in 0..<16 {
                ar[r * 16 + c] = patch[c * 8 + r]
            }
        }
        AccelerateDCT.dct2D(&ar, rows: 8, cols: 16)
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd4Pair(llf: [ar[0], ar[1]])
        var ac = [Int32](repeating: 0, count: 128)
        for k in 2..<128 {
            ac[k] = quantizeAC(
                ar[k], weight: quantWeights[k],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }

    /// Forward + quantise one 16-row × 32-col patch as a DCT16×32
    /// block (libjxl ord 6). Patch layout matches the decoder's
    /// `idct2D(rows: 16, cols: 32)` output, so no transpose. Returns
    /// 8 LLF-derived DC values laid out as `ord6Block`'s input
    /// expects (`dc[r*4+c]` for r ∈ 0..2, c ∈ 0..4) — for DCT16×32,
    /// `dc[r*4+c]` corresponds to the pixel-cell at `(bx+c, by+r)`.
    /// Returns 504 quantised AC coefficients (the 8 LLF positions
    /// 0..3 / 32..35 left 0).
    static func forwardDCT16x32Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 512
                     && quantWeights.count == 512,
                     "DCT16x32 block needs a 512-entry patch "
                     + "+ 512 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, rows: 16, cols: 32)
        // 8 LLF coefficients at the 4-col × 2-row corner.
        var llf = [Float](repeating: 0, count: 8)
        for r in 0..<2 {
            for c in 0..<4 { llf[r * 4 + c] = coef[r * 32 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd6Block(llf: llf)
        var ac = [Int32](repeating: 0, count: 512)
        for np in 0..<512 {
            let r = np / 32, c = np % 32
            if r < 2 && c < 4 { continue }
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }

    /// Forward + quantise one 32-row × 16-col patch as a DCT32×16
    /// block (libjxl ord 6). The decoder's coef layout is 16-row ×
    /// 32-col, so the encoder transposes the patch first. Returns
    /// 8 LLF-derived DC values laid out as `ord6Block`'s input
    /// expects — for DCT32×16, `dc[r*4+c]` corresponds to the
    /// pixel-cell at `(bx+r, by+c)`. Returns 504 quantised AC.
    static func forwardDCT32x16Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 512
                     && quantWeights.count == 512,
                     "DCT32x16 block needs a 512-entry patch "
                     + "+ 512 weights")
        // Transpose 32-row × 16-col → 16-row × 32-col.
        var ar = [Float](repeating: 0, count: 512)
        for r in 0..<16 {
            for c in 0..<32 {
                ar[r * 32 + c] = patch[c * 16 + r]
            }
        }
        AccelerateDCT.dct2D(&ar, rows: 16, cols: 32)
        var llf = [Float](repeating: 0, count: 8)
        for r in 0..<2 {
            for c in 0..<4 { llf[r * 4 + c] = ar[r * 32 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd6Block(llf: llf)
        var ac = [Int32](repeating: 0, count: 512)
        for np in 0..<512 {
            let r = np / 32, c = np % 32
            if r < 2 && c < 4 { continue }
            ac[np] = quantizeAC(
                ar[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }

    /// Forward + quantise one 64×64 single-channel patch as a
    /// DCT64×64 block (libjxl ord 7). The 64 lowest-frequency
    /// coefficients (the 8×8 corner of the 64×64 grid) become 64
    /// DC-plane cell values via `dcFromLowestFrequencies64x64`.
    /// Returns those 64 float DC values (row-major over the covered
    /// cells — the caller quantises DC) and the 4032 quantised AC
    /// coefficients in the 4096-entry natural grid (the 64 LLF
    /// positions left 0).
    static func forwardDCT64x64Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 4096
                     && quantWeights.count == 4096,
                     "DCT64 block needs a 64×64 patch + 4096 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, size: 64)
        transposeSquare(&coef, size: 64)
        // 64 LLF coefficients — the 8×8 corner.
        var llf = [Float](repeating: 0, count: 64)
        for r in 0..<8 {
            for c in 0..<8 { llf[r * 8 + c] = coef[r * 64 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequencies64x64(llf: llf)
        var ac = [Int32](repeating: 0, count: 4096)
        for r in 0..<64 {
            for c in 0..<64 where !(r < 8 && c < 8) {
                let np = r * 64 + c
                ac[np] = quantizeAC(
                    coef[np], weight: quantWeights[np],
                    scale: scale, qf: qf)
            }
        }
        return (dc, ac)
    }

    /// Forward + quantise one 32-row × 64-col patch as a DCT32×64
    /// block (libjxl ord 8). Coef layout matches the decoder's
    /// `idct2D(rows: 32, cols: 64)` output for DCT32×64 — no
    /// transpose. Returns 32 LLF-derived DC values (laid out as
    /// `ord8Block`'s input expects: `dc[r*8+c]` ↔ pixel-cell
    /// `(bx+c, by+r)`) and 2016 quantised AC coefficients (the 32
    /// LLF positions `[r*64+c]` for r ∈ 0..4, c ∈ 0..8 left 0).
    static func forwardDCT32x64Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 2048
                     && quantWeights.count == 2048,
                     "DCT32x64 block needs a 2048-entry patch "
                     + "+ 2048 weights")
        var coef = patch
        AccelerateDCT.dct2D(&coef, rows: 32, cols: 64)
        var llf = [Float](repeating: 0, count: 32)
        for r in 0..<4 {
            for c in 0..<8 { llf[r * 8 + c] = coef[r * 64 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd8Block(llf: llf)
        var ac = [Int32](repeating: 0, count: 2048)
        for np in 0..<2048 {
            let r = np / 64, c = np % 64
            if r < 4 && c < 8 { continue }
            ac[np] = quantizeAC(
                coef[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }

    /// Forward + quantise one 64-row × 32-col patch as a DCT64×32
    /// block (libjxl ord 8). The decoder's coef layout is 32-row ×
    /// 64-col, so the encoder transposes the patch first. Returns
    /// 32 LLF-derived DC values (`dc[r*8+c]` ↔ pixel-cell
    /// `(bx+r, by+c)`) and 2016 quantised AC.
    static func forwardDCT64x32Block(
        patch: [Float], quantWeights: [Float],
        scale: Float, qf: Int32
    ) -> (dc: [Float], ac: [Int32]) {
        precondition(patch.count == 2048
                     && quantWeights.count == 2048,
                     "DCT64x32 block needs a 2048-entry patch "
                     + "+ 2048 weights")
        // Transpose 64-row × 32-col → 32-row × 64-col.
        var ar = [Float](repeating: 0, count: 2048)
        for r in 0..<32 {
            for c in 0..<64 {
                ar[r * 64 + c] = patch[c * 32 + r]
            }
        }
        AccelerateDCT.dct2D(&ar, rows: 32, cols: 64)
        var llf = [Float](repeating: 0, count: 32)
        for r in 0..<4 {
            for c in 0..<8 { llf[r * 8 + c] = ar[r * 64 + c] }
        }
        let dc = LowestFrequenciesFromDC
            .dcFromLowestFrequenciesOrd8Block(llf: llf)
        var ac = [Int32](repeating: 0, count: 2048)
        for np in 0..<2048 {
            let r = np / 64, c = np % 64
            if r < 4 && c < 8 { continue }
            ac[np] = quantizeAC(
                ar[np], weight: quantWeights[np],
                scale: scale, qf: qf)
        }
        return (dc, ac)
    }
}
