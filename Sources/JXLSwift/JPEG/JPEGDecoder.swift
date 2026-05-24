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
//   - Baseline-sequential JPEGs (SOF0) with arbitrary sampling
//     factors (4:4:4, 4:2:2, 4:2:0, etc.).
//   - 1-component grayscale (returned as `channels: 1`) and
//     3-component YCbCr (returned as `channels: 3, ColorSpace.sRGB`,
//     YCbCr → RGB via JFIF BT.601 full-range).
//   - 8-bit precision.
//
// Not yet supported (throws `JPEGDecoderError.unsupported`):
//   - Progressive / extended-sequential / lossless (SOF1/2/3+)
//   - 12-bit precision
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

public enum JPEGDecoderError: Error, Sendable, Equatable,
                              LocalizedError {
    case missingFrame
    case missingScan
    case unsupported(String)

    public var errorDescription: String? {
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
public enum JPEGDecoder {

    /// Decode a JPEG file. Returns an 8-bit ImageFrame:
    /// `channels: 1` for grayscale, `channels: 3` for YCbCr.
    public static func decode(_ data: Data) throws -> ImageFrame {
        // Walk every segment, collecting state.
        var reader = JPEGSegmentReader(data)
        var dcMap = JPEGHuffmanCodebookMap()
        var acMap = JPEGHuffmanCodebookMap()
        var quantTables: [JPEGQuantTable] = []
        var frameComponents: [JPEGFrameComponent] = []
        var width = 0, height = 0
        var precision = 0
        var frameKind: JPEGStructure.FrameKind = .baselineDCT
        var scanHeader: JPEGScanHeader?
        var restartInterval = 0
        var entropyStartOffset = 0

        while let seg = try reader.next() {
            switch seg.kind {
            case .startOfFrame(let nibble):
                frameKind = JPEGStructure.FrameKind(
                    nibble: nibble)
                precision = Int(seg.payload[0])
                height = (Int(seg.payload[1]) << 8)
                    | Int(seg.payload[2])
                width = (Int(seg.payload[3]) << 8)
                    | Int(seg.payload[4])
                frameComponents = try JPEGFrameComponent
                    .parseSOFComponents(sofPayload: seg.payload)
            case .defineQuantizationTable:
                quantTables.append(contentsOf:
                    try JPEGQuantTable.parse(
                        dqtPayload: seg.payload))
            case .defineHuffmanTable:
                for t in try JPEGHuffmanTable.parse(
                    dhtPayload: seg.payload)
                {
                    let book = try t.buildCodebook()
                    if t.class == .dc {
                        dcMap[t.tableId] = (book, t.huffvals)
                    } else {
                        acMap[t.tableId] = (book, t.huffvals)
                    }
                }
            case .defineArithmeticConditioning:
                throw JPEGDecoderError.unsupported(
                    "arithmetic-coded JPEG")
            case .defineRestartInterval:
                if seg.payload.count == 2 {
                    restartInterval = (Int(seg.payload[0]) << 8)
                        | Int(seg.payload[1])
                }
            case .startOfScan:
                scanHeader = try JPEGScanHeader.parse(
                    sosPayload: seg.payload)
                entropyStartOffset = reader.byteOffset
            default:
                break
            }
            if seg.kind == .startOfScan { break }
            if seg.kind == .endOfImage { break }
        }

        guard !frameComponents.isEmpty else {
            throw JPEGDecoderError.missingFrame
        }
        guard let scan = scanHeader else {
            throw JPEGDecoderError.missingScan
        }
        guard precision == 8 else {
            throw JPEGDecoderError.unsupported(
                "\(precision)-bit precision (only 8-bit supported)")
        }
        guard frameKind == .baselineDCT else {
            throw JPEGDecoderError.unsupported(
                "non-baseline frame: \(frameKind.label)")
        }
        let nComponents = frameComponents.count
        guard nComponents == 1 || nComponents == 3 else {
            throw JPEGDecoderError.unsupported(
                "\(nComponents)-component frame "
                + "(only 1 or 3 supported)")
        }

        // Drive the scan.
        var bitReader = JPEGBitReader(data,
            startingAt: entropyStartOffset)
        let comps = try JPEGScanDecoder.decodeBaselineSequential(
            from: &bitReader,
            scanHeader: scan,
            frameComponents: frameComponents,
            imageWidth: width, imageHeight: height,
            dcCodebooks: dcMap, acCodebooks: acMap,
            restartInterval: restartInterval)

        // Dequantise + IDCT every block per component, producing
        // per-component sample planes at their native (possibly
        // chroma-subsampled) resolution.
        let planes = try JPEGPixelAssembler.assemble(
            componentBlocks: comps,
            frameComponents: frameComponents,
            quantTables: quantTables,
            precision: precision)

        // For 3-component YCbCr, upsample chroma to luma's
        // resolution, then run YCbCr → RGB. For 1-component
        // grayscale, just convert the plane to UInt8.
        if nComponents == 1 {
            let plane = planes[0]
            let buf = JPEGColorConversion
                .grayscaleToBuffer(plane)
            return try cropToFrame(
                rawBuffer: buf, planeWidth: plane.width,
                planeHeight: plane.height,
                visibleWidth: width, visibleHeight: height,
                channels: 1)
        }

        // 3-component case. We assume scan order matches frame
        // order, which is the JFIF convention (Y, Cb, Cr); a
        // strict implementation would re-order by component ID.
        let yPlane = planes[0]
        let cbRaw = planes[1]
        let crRaw = planes[2]
        let cb = JPEGPixelAssembler.upsampleNearest(
            cbRaw, toWidth: yPlane.width,
            height: yPlane.height)
        let cr = JPEGPixelAssembler.upsampleNearest(
            crRaw, toWidth: yPlane.width,
            height: yPlane.height)
        let rgb = JPEGColorConversion.ycbcrToRGB8(
            y: yPlane, cb: cb, cr: cr)
        return try cropToFrame(
            rawBuffer: rgb, planeWidth: yPlane.width,
            planeHeight: yPlane.height,
            visibleWidth: width, visibleHeight: height,
            channels: 3)
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
