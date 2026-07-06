// JPEGLosslessDecoder — SOF3 lossless JPEG (ITU-T T.81 Annex H).
//
// Lossless JPEG is a *predictive* codec, not DCT-based. Each sample
// `s(row,col)` is predicted from already-reconstructed neighbours
//
//     Ra = s(row,   col-1)   (left)
//     Rb = s(row-1, col)     (above)
//     Rc = s(row-1, col-1)   (above-left)
//
// via one of seven selection-value predictors (SOS `Ss` field,
// §H.1.2.1):
//
//     1: Ra                    5: Ra + ((Rb − Rc) >> 1)
//     2: Rb                    6: Rb + ((Ra − Rc) >> 1)
//     3: Rc                    7: (Ra + Rb) >> 1
//     4: Ra + Rb − Rc
//
// The Huffman-coded difference (DC-class tables, same receive-and-
// extend primitive as the DCT DC term, plus an SSSS = 16 → 32768
// special case) is added back modulo 2^16 (§H.1.2.1). Edge rules:
// the first sample of the scan / of each restart interval uses the
// constant `2^(P − Pt − 1)`; the first row otherwise uses Ra; the
// first column of subsequent rows uses Rb.
//
// This shares the JPEG segment framing, Huffman tables, and bit
// reader with the DCT path, but none of the DCT / quantisation /
// zig-zag machinery. Scope: 1-component (grayscale — the dominant
// DICOM lossless case) and 3-component (stored components, no colour
// transform) frames at 2…16-bit precision, interleaved or
// non-interleaved scans, with restart intervals. Point transform
// (near-lossless, `Pt > 0`) is honoured via a final left shift.

import Foundation

package enum JPEGLosslessDecoder {

    /// Decode a SOF3 lossless JPEG to an `ImageFrame`. 8-bit output
    /// returns a `.uint8` frame; higher precision returns a `.uint16`
    /// frame carrying the raw sample values.
    package static func decode(_ data: Data) throws -> ImageFrame {
        var reader = JPEGSegmentReader(data)
        var dcMap = JPEGHuffmanCodebookMap()
        var frameComponents: [JPEGFrameComponent] = []
        var width = 0, height = 0, precision = 0
        var restartInterval = 0

        // Per-component reconstructed sample planes (built lazily once
        // the SOF is seen). Index parallels `frameComponents`.
        var planes: [[Int]] = []
        var planeW: [Int] = [], planeH: [Int] = []
        var hMax = 1, vMax = 1

        while let seg = try reader.next() {
            switch seg.kind {
            case .startOfFrame:
                precision = Int(seg.payload[seg.payload.startIndex])
                height = (Int(seg.payload[seg.payload.startIndex + 1]) << 8)
                    | Int(seg.payload[seg.payload.startIndex + 2])
                width = (Int(seg.payload[seg.payload.startIndex + 3]) << 8)
                    | Int(seg.payload[seg.payload.startIndex + 4])
                frameComponents = try JPEGFrameComponent
                    .parseSOFComponents(sofPayload: seg.payload)
                guard precision >= 2 && precision <= 16 else {
                    throw JPEGDecoderError.unsupported(
                        "lossless JPEG precision \(precision) "
                        + "(supported: 2…16)")
                }
                guard width > 0, height > 0 else {
                    throw JPEGDecoderError.unsupported(
                        "lossless JPEG bad dimensions "
                        + "\(width)×\(height)")
                }
                let nC = frameComponents.count
                guard nC == 1 || nC == 3 else {
                    throw JPEGDecoderError.unsupported(
                        "lossless JPEG \(nC)-component frame "
                        + "(only 1 or 3 supported)")
                }
                hMax = frameComponents.map(\.hSamplingFactor).max() ?? 1
                vMax = frameComponents.map(\.vSamplingFactor).max() ?? 1
                for fc in frameComponents {
                    let w = ceilDiv(width * fc.hSamplingFactor, hMax)
                    let h = ceilDiv(height * fc.vSamplingFactor, vMax)
                    planeW.append(w)
                    planeH.append(h)
                    planes.append([Int](repeating: 0, count: w * h))
                }
            case .defineHuffmanTable:
                for t in try JPEGHuffmanTable.parse(
                    dhtPayload: seg.payload) where t.class == .dc {
                    dcMap[t.tableId] = (try t.buildCodebook(), t.huffvals)
                }
            case .defineArithmeticConditioning:
                throw JPEGDecoderError.unsupported(
                    "arithmetic-coded lossless JPEG")
            case .defineRestartInterval:
                if seg.payload.count == 2 {
                    restartInterval =
                        (Int(seg.payload[seg.payload.startIndex]) << 8)
                        | Int(seg.payload[seg.payload.startIndex + 1])
                }
            case .startOfScan:
                guard !frameComponents.isEmpty else {
                    throw JPEGDecoderError.missingFrame
                }
                let scan = try JPEGScanHeader.parse(
                    sosPayload: seg.payload)
                var br = JPEGBitReader(
                    data, startingAt: reader.byteOffset)
                try decodeScan(
                    scan: scan, reader: &br,
                    frameComponents: frameComponents,
                    imageWidth: width, imageHeight: height,
                    precision: precision,
                    restartInterval: restartInterval,
                    hMax: hMax, vMax: vMax,
                    dcMap: dcMap,
                    planes: &planes, planeW: planeW, planeH: planeH)
                continue   // resume the segment walk for the next scan
            case .endOfImage:
                break
            default:
                break
            }
        }

        guard !frameComponents.isEmpty else {
            throw JPEGDecoderError.missingFrame
        }
        return try assemble(
            frameComponents: frameComponents,
            planes: planes, planeW: planeW, planeH: planeH,
            width: width, height: height, precision: precision,
            hMax: hMax, vMax: vMax)
    }

    // MARK: - Scan decode

    private static func decodeScan(
        scan: JPEGScanHeader,
        reader: inout JPEGBitReader,
        frameComponents: [JPEGFrameComponent],
        imageWidth: Int, imageHeight: Int,
        precision: Int,
        restartInterval: Int,
        hMax: Int, vMax: Int,
        dcMap: JPEGHuffmanCodebookMap,
        planes: inout [[Int]], planeW: [Int], planeH: [Int]
    ) throws {
        let psv = scan.spectralSelectionStart          // Ss = predictor
        let pt = scan.successiveApproximationLow        // Al = point xform
        let defaultPred = 1 << (precision - pt - 1)

        // Resolve each scan component → (frame index, DC codebook).
        struct SC {
            let frameIndex: Int
            let hi: Int, vi: Int
            let book: JPEGHuffmanCodebook
            let huffvals: [UInt8]
        }
        var scs: [SC] = []
        for c in scan.components {
            guard let fi = frameComponents.firstIndex(
                where: { $0.componentId == c.componentId }) else {
                throw JPEGDecoderError.unsupported(
                    "lossless scan references unknown component "
                    + "\(c.componentId)")
            }
            guard let dc = dcMap[c.dcTableId] else {
                throw JPEGDecoderError.unsupported(
                    "lossless scan missing DC Huffman table "
                    + "\(c.dcTableId)")
            }
            scs.append(SC(
                frameIndex: fi,
                hi: frameComponents[fi].hSamplingFactor,
                vi: frameComponents[fi].vSamplingFactor,
                book: dc.codebook, huffvals: dc.huffvals))
        }

        // Restart bookkeeping. Per §H.2.1 the *first line* of each
        // restart interval (and of the scan) uses horizontal (Ra)
        // prediction — its first sample the constant `defaultPred`,
        // the rest Ra — because the "row above" from the previous
        // interval is not a valid predictor after a reset.
        // `intervalStartRow[fi]` is the sample row on which the
        // current interval began for component `fi`; a sample on that
        // row is a first-line sample. `restartPending` marks the
        // components whose next sample opens a fresh interval (so its
        // row becomes the new interval-start row). Restart intervals
        // are constrained to whole MCU rows, so an interval always
        // opens at column 0.
        var restartCountdown = restartInterval
        var intervalStartRow = [Int](
            repeating: 0, count: frameComponents.count)
        var restartPending = Set<Int>()

        // Decode one sample of component `sc` at plane position
        // (row, col), writing the reconstructed value.
        func decodeSample(_ sc: SC, row: Int, col: Int) throws {
            let fi = sc.frameIndex
            let w = planeW[fi]
            if restartPending.contains(fi) {
                intervalStartRow[fi] = row
                restartPending.remove(fi)
            }
            let diff = try decodeDifference(
                book: sc.book, huffvals: sc.huffvals, reader: &reader)
            let firstLine = (row == intervalStartRow[fi])
            let pred: Int
            if firstLine {
                // First line: default for the first sample, Ra after.
                pred = col == 0 ? defaultPred
                    : planes[fi][row * w + col - 1]         // Ra
            } else if col == 0 {
                pred = planes[fi][(row - 1) * w]            // Rb
            } else {
                let ra = planes[fi][row * w + col - 1]
                let rb = planes[fi][(row - 1) * w + col]
                let rc = planes[fi][(row - 1) * w + col - 1]
                switch psv {
                case 1:  pred = ra
                case 2:  pred = rb
                case 3:  pred = rc
                case 4:  pred = ra + rb - rc
                case 5:  pred = ra + ((rb - rc) >> 1)
                case 6:  pred = rb + ((ra - rc) >> 1)
                case 7:  pred = (ra + rb) >> 1
                default: pred = defaultPred     // Psv 0 (differential)
                }
            }
            planes[fi][row * w + col] = (pred + diff) & 0xFFFF
        }

        func maybeRestart() {
            guard restartInterval > 0 else { return }
            restartCountdown -= 1
            if restartCountdown == 0 {
                restartCountdown = restartInterval
                reader.alignToByte()
                restartPending = Set(scs.map { $0.frameIndex })
            }
        }

        if scs.count == 1 {
            // Non-interleaved: raster scan of the one component's plane.
            let sc = scs[0]
            let fi = sc.frameIndex
            let w = planeW[fi], h = planeH[fi]
            for row in 0..<h {
                for col in 0..<w {
                    try decodeSample(sc, row: row, col: col)
                    maybeRestart()
                }
            }
        } else {
            // Interleaved: MCU walk of Hmax×Vmax-sample MCUs; each
            // component contributes Hi×Vi samples per MCU.
            let mw = ceilDiv(imageWidth, hMax)
            let mh = ceilDiv(imageHeight, vMax)
            for my in 0..<mh {
                for mx in 0..<mw {
                    for sc in scs {
                        let w = planeW[sc.frameIndex]
                        let h = planeH[sc.frameIndex]
                        for v in 0..<sc.vi {
                            for hh in 0..<sc.hi {
                                let row = my * sc.vi + v
                                let col = mx * sc.hi + hh
                                if row < h && col < w {
                                    try decodeSample(
                                        sc, row: row, col: col)
                                }
                            }
                        }
                    }
                    maybeRestart()
                }
            }
        }
    }

    // MARK: - Difference decode

    /// Decode one lossless difference: a DC-class Huffman symbol
    /// `SSSS` (0…16) then the receive-and-extend magnitude. `SSSS = 0`
    /// is a zero difference; `SSSS = 16` is the special value 32768
    /// (no extra bits, §H.1.2.2); otherwise it is the signed
    /// `SSSS`-bit magnitude.
    private static func decodeDifference(
        book: JPEGHuffmanCodebook,
        huffvals: [UInt8],
        reader: inout JPEGBitReader
    ) throws -> Int {
        guard let s = JPEGBlockDecoder.decodeSymbol(
            using: book, huffvals: huffvals, reader: &reader) else {
            throw JPEGBlockDecodeError.malformedDCSymbol
        }
        let ssss = Int(s)
        if ssss == 0 { return 0 }
        if ssss == 16 { return 32768 }
        guard ssss <= 15 else {
            throw JPEGBlockDecodeError.dcSizeOutOfRange(ssss)
        }
        return Int(try JPEGBlockDecoder.readExtendedMagnitude(
            bits: ssss, from: &reader))
    }

    // MARK: - Assembly

    private static func assemble(
        frameComponents: [JPEGFrameComponent],
        planes: [[Int]], planeW: [Int], planeH: [Int],
        width: Int, height: Int, precision: Int,
        hMax: Int, vMax: Int
    ) throws -> ImageFrame {
        let nC = frameComponents.count
        let maxSample = (1 << precision) - 1

        if nC == 1 {
            if precision <= 8 {
                var frame = ImageFrame(
                    width: width, height: height, channels: 1,
                    pixelType: .uint8, colorSpace: .grayscale)
                let w = planeW[0]
                for y in 0..<height {
                    for x in 0..<width {
                        frame.data[y * width + x] =
                            UInt8(clamping: planes[0][y * w + x])
                    }
                }
                return frame
            }
            var frame = ImageFrame(
                width: width, height: height, channels: 1,
                pixelType: .uint16, colorSpace: .grayscale)
            let w = planeW[0]
            for y in 0..<height {
                for x in 0..<width {
                    let v = UInt16(clamping:
                        min(planes[0][y * w + x], maxSample))
                    frame.data[(y * width + x) * 2]     = UInt8(v & 0xFF)
                    frame.data[(y * width + x) * 2 + 1] = UInt8(v >> 8)
                }
            }
            return frame
        }

        // 3-component: stored components, no colour transform. Require
        // no subsampling (all Hi = Vi = 1) — the common lossless-RGB
        // layout; subsampled lossless colour is out of scope.
        guard frameComponents.allSatisfy({
            $0.hSamplingFactor == 1 && $0.vSamplingFactor == 1 }) else {
            throw JPEGDecoderError.unsupported(
                "subsampled 3-component lossless JPEG")
        }
        if precision <= 8 {
            var frame = ImageFrame(
                width: width, height: height, channels: 3,
                pixelType: .uint8, colorSpace: .sRGB)
            for y in 0..<height {
                for x in 0..<width {
                    for c in 0..<3 {
                        frame.data[(y * width + x) * 3 + c] =
                            UInt8(clamping: planes[c][y * planeW[c] + x])
                    }
                }
            }
            return frame
        }
        var frame = ImageFrame(
            width: width, height: height, channels: 3,
            pixelType: .uint16, colorSpace: .sRGB)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<3 {
                    let v = UInt16(clamping:
                        min(planes[c][y * planeW[c] + x], maxSample))
                    let o = ((y * width + x) * 3 + c) * 2
                    frame.data[o]     = UInt8(v & 0xFF)
                    frame.data[o + 1] = UInt8(v >> 8)
                }
            }
        }
        return frame
    }

    // MARK: - Helpers

    @inline(__always)
    private static func ceilDiv(_ a: Int, _ b: Int) -> Int {
        (a + b - 1) / b
    }
}
