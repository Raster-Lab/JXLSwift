// `JPEGDecoder` — single-call facade over the eight Phase J layers
// underneath: segment walker, DQT / DHT / SOFn / SOS parsers,
// Huffman codebook builder, bit reader, block decoder, dequantiser,
// IDCT, pixel assembler, chroma upsampling, YCbCr → RGB. Thirteenth
// step on the Phase J road.
//
// Given a JPEG byte buffer, returns an `ImageFrame` in the standard
// JXLSwift shape — same type the JXL decoder returns, ready to feed
// to `PNM.write`, `ImageMetrics.compute`, the JXL encoder, etc.
//
// Scope:
//   - Baseline (SOF0), extended-sequential (SOF1), and progressive
//     (SOF2) DCT JPEGs with arbitrary sampling factors (4:4:4,
//     4:2:2, 4:2:0, etc.), plus lossless (SOF3) via
//     `JPEGLosslessDecoder` (routed automatically).
//   - 1-component grayscale (returned as `channels: 1`) and
//     3-component YCbCr (returned as `channels: 3, ColorSpace.sRGB`,
//     YCbCr → RGB via JFIF BT.601 full-range).
//   - 8-bit precision (`.uint8` output) and 12-bit / 16-bit
//     precision (`.uint16` output carrying the raw sample values).
//
// Not yet supported (throws `JPEGDecoderError.unsupported`):
//   - 4-component CMYK / YCCK (Adobe APP14)
//   - Arithmetic coding (DAC segments)
//
// **API stability — v0.11.0.** `JPEGDecoder.decode(_:)` is the
// intended-stable public surface and will remain so across the
// Phase J series. The layer types in `Sources/JXLSwift/JPEG/*`
// (`JPEGSegmentReader`, `JPEGStructure`, `JPEGQuantTable`,
// `JPEGHuffmanTable`, `JPEGHuffmanCodebook`, `JPEGBitReader`,
// `JPEGBlockDecoder`, `JPEGDequantiser`, `JPEGScanDecoder`,
// `JPEGIDCT`, `JPEGPixelAssembler`, `JPEGColorConversion`) are
// `public` because the eventual JPEG → JXL transcoding bridge
// (Phase J capstone, planned for v0.12.0) needs them, but their
// individual signatures may evolve when that bridge lands.
// Callers who only need "JPEG bytes → ImageFrame" should use
// `JPEGDecoder.decode(_:)` exclusively.

import Foundation

package enum JPEGDecoderError: Error, Sendable, Equatable,
                              LocalizedError {
    case missingFrame
    case missingScan
    case unsupported(String)

    package var errorDescription: String? {
        switch self {
        case .missingFrame:
            return "JPEG: no SOFn frame header found"
        case .missingScan:
            return "JPEG: no SOS scan header found"
        case .unsupported(let why):
            return "JPEG: unsupported input — \(why)"
        }
    }
}

/// High-level "JPEG bytes → ImageFrame" decoder.
package enum JPEGDecoder {

    /// Decode a JPEG file to an `ImageFrame`.
    ///
    /// Handles baseline (SOF0), extended-sequential (SOF1), and
    /// progressive (SOF2) DCT frames, 1-component grayscale and
    /// 3-component YCbCr, at 8-bit and 12-bit precision. 8-bit frames
    /// return a `.uint8` frame; 12-bit frames return a `.uint16` frame
    /// carrying raw `0…4095` sample values (djpeg's convention — the
    /// values are not rescaled to the 16-bit range). SOF3 lossless is
    /// decoded by ``decodeLossless(_:)``; this entry point routes to it
    /// automatically.
    package static func decode(_ data: Data) throws -> ImageFrame {
        // SOF3 (lossless) is a predictive codec with no DCT — route it
        // to the dedicated decoder rather than the DCT coefficient path.
        if try frameKind(of: data) == .lossless {
            return try decodeLossless(data)
        }
        // Decode to quantised DCT coefficients — this covers baseline
        // (SOF0), extended-sequential (SOF1), and progressive (SOF2) at
        // 8-bit and 12-bit. The pixel path then dequantises, runs the
        // IDCT, and colour-converts.
        let coef = try decodeToCoefficients(data)
        let nComponents = coef.frameComponents.count
        guard nComponents == 1 || nComponents == 3 else {
            throw JPEGDecoderError.unsupported(
                "\(nComponents)-component frame "
                + "(only 1 or 3 supported)")
        }
        // Dequantise + IDCT every block per component, producing
        // per-component sample planes at their native (possibly
        // chroma-subsampled) resolution.
        let planes = try JPEGPixelAssembler.assemble(
            componentBlocks: coef.quantisedComponents,
            frameComponents: coef.frameComponents,
            quantTables: coef.quantTables,
            precision: coef.precision)
        let width = coef.width, height = coef.height

        if coef.precision <= 8 {
            // ---- 8-bit output (unchanged from the baseline path) ----
            if nComponents == 1 {
                let buf = JPEGColorConversion
                    .grayscaleToBuffer(planes[0])
                return try cropToFrame(
                    rawBuffer: buf, planeWidth: planes[0].width,
                    planeHeight: planes[0].height,
                    visibleWidth: width, visibleHeight: height,
                    channels: 1)
            }
            // 3-component YCbCr. Scan order matches frame order (the
            // JFIF Y, Cb, Cr convention).
            let yPlane = planes[0]
            let cb = JPEGPixelAssembler.upsampleNearest(
                planes[1], toWidth: yPlane.width, height: yPlane.height)
            let cr = JPEGPixelAssembler.upsampleNearest(
                planes[2], toWidth: yPlane.width, height: yPlane.height)
            let rgb = JPEGColorConversion.ycbcrToRGB8(
                y: yPlane, cb: cb, cr: cr)
            return try cropToFrame(
                rawBuffer: rgb, planeWidth: yPlane.width,
                planeHeight: yPlane.height,
                visibleWidth: width, visibleHeight: height,
                channels: 3)
        }

        // ---- 12-bit output → uint16 frame (raw 0…4095 values) ----
        if nComponents == 1 {
            return cropToFrame16(
                samples: planes[0].samples, channels: 1,
                planeWidth: planes[0].width, planeHeight: planes[0].height,
                visibleWidth: width, visibleHeight: height)
        }
        let yPlane = planes[0]
        let cb = JPEGPixelAssembler.upsampleNearest(
            planes[1], toWidth: yPlane.width, height: yPlane.height)
        let cr = JPEGPixelAssembler.upsampleNearest(
            planes[2], toWidth: yPlane.width, height: yPlane.height)
        let rgb = JPEGColorConversion.ycbcrToRGB(
            y: yPlane, cb: cb, cr: cr, precision: coef.precision)
        return cropToFrame16(
            samples: rgb, channels: 3,
            planeWidth: yPlane.width, planeHeight: yPlane.height,
            visibleWidth: width, visibleHeight: height)
    }

    /// Peek at the SOFn marker to classify the frame without a full
    /// decode — used to route SOF3 (lossless) away from the DCT path.
    static func frameKind(
        of data: Data
    ) throws -> JPEGStructure.FrameKind {
        var reader = JPEGSegmentReader(data)
        while let seg = try reader.next() {
            if case .startOfFrame(let nibble) = seg.kind {
                return JPEGStructure.FrameKind(nibble: nibble)
            }
            if seg.kind == .startOfScan || seg.kind == .endOfImage {
                break
            }
        }
        throw JPEGDecoderError.missingFrame
    }

    /// Decode a SOF3 lossless JPEG (ITU-T T.81 §H — predictive, no
    /// DCT) to an `ImageFrame`. Implemented in `JPEGLosslessDecoder`.
    static func decodeLossless(_ data: Data) throws -> ImageFrame {
        try JPEGLosslessDecoder.decode(data)
    }

    /// Pack interleaved `Int32` samples (range `0…65535`, `channels`
    /// values per pixel) into a little-endian `.uint16` `ImageFrame`
    /// cropped to the visible dimensions.
    private static func cropToFrame16(
        samples: [Int32], channels: Int,
        planeWidth pw: Int, planeHeight ph: Int,
        visibleWidth vw: Int, visibleHeight vh: Int
    ) -> ImageFrame {
        var frame = ImageFrame(
            width: vw, height: vh, channels: channels,
            pixelType: .uint16,
            colorSpace: channels == 1 ? .grayscale : .sRGB)
        for y in 0..<vh {
            let srcRow = y * pw * channels
            let dstRow = y * vw * channels
            for x in 0..<(vw * channels) {
                let v = UInt16(clamping: samples[srcRow + x])
                frame.data[(dstRow + x) * 2]     = UInt8(v & 0xFF)
                frame.data[(dstRow + x) * 2 + 1] = UInt8((v >> 8) & 0xFF)
            }
        }
        return frame
    }

    /// Wrap a buffer-aligned-to-block-grid sample array into an
    /// ImageFrame cropped to the SOFn-declared visible dimensions.
    /// JPEG block-aligns to multiples of 8 (or H_max*8 / V_max*8
    /// when chroma-subsampled); the visible image can be smaller.
    private static func cropToFrame(
        rawBuffer: [UInt8],
        planeWidth pw: Int, planeHeight ph: Int,
        visibleWidth vw: Int, visibleHeight vh: Int,
        channels: Int
    ) throws -> ImageFrame {
        var frame = ImageFrame(
            width: vw, height: vh, channels: channels,
            pixelType: .uint8,
            colorSpace: channels == 1 ? .grayscale : .sRGB)
        for y in 0..<vh {
            let srcRow = y * pw * channels
            let dstRow = y * vw * channels
            for x in 0..<(vw * channels) {
                frame.data[dstRow + x] = rawBuffer[srcRow + x]
            }
        }
        return frame
    }
}
