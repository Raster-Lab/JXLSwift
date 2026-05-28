// `JPEGCoefficientImage` — the structured handoff between the
// pure-Swift JPEG decoder and the *eventual* JXL VarDCT
// coefficient bridge (Phase J transcoding capstone, v0.12+).
//
// The pixel-side `JPEGDecoder.decode(_:) -> ImageFrame` runs the
// full pipeline through IDCT + colour conversion. The transcode
// route stops earlier: it wants the **dequantised DCT coefficients
// per component** plus enough metadata to drive a JXL frame that
// either (a) decodes to the same pixels as the original JPEG, or
// (b) reverse-transcodes back to bit-identical JPEG bytes (the
// second needs the `jbrd` box, gated on a pure-Swift Brotli that
// is not in v0.11.0 / v0.12.0a scope).
//
// Note on quantised vs dequantised: libjxl's JPEG → JXL bridge
// uses the **quantised** integer coefficients (as stored in the
// JPEG entropy stream) plus the JPEG quant tables, then arranges
// the JXL frame so its quantiser produces matching reconstruction.
// We expose **both** — `quantisedComponents` carries the
// straight-out-of-scan-decoder Int32 coefficients in natural
// row-major order; `quantTables` are the per-table-ID quant
// matrices in zig-zag order. The dequantised form is one
// `JPEGDequantiser.dequantise` call away on each block; we don't
// pre-materialise it because most transcode targets want the
// quantised form anyway.
//
// API stability (v0.12.0a): foundation type, public so the
// coefficient bridge can be implemented in a separate file
// without becoming intertwined with `JPEGDecoder`. The pixel
// `JPEGDecoder.decode(_:)` surface remains the recommended pin
// for "JPEG bytes → ImageFrame" callers; this type is for the
// transcoder path specifically.

import Foundation

/// All the information from a decoded JPEG that an eventual JXL
/// VarDCT coefficient bridge will need: dimensions, frame kind,
/// per-component sampling factors + quant-table bindings,
/// **quantised** DCT coefficient grids per component (natural
/// row-major order), and the quant tables themselves.
public struct JPEGCoefficientImage: Sendable {
    /// SOFn `X` field (samples per line) — visible image width.
    public let width: Int
    /// SOFn `Y` field (number of lines) — visible image height.
    public let height: Int
    /// SOFn `P` field — typically 8.
    public let precision: Int
    /// SOFn flavour — baseline / extended-sequential / progressive
    /// / lossless / other. The current scan decoder only emits
    /// `.baselineDCT`; a progressive bridge is a v0.13+ bite.
    public let frameKind: JPEGStructure.FrameKind
    /// Per-component sampling factors + quant-table binding,
    /// straight from the SOFn payload.
    public let frameComponents: [JPEGFrameComponent]
    /// Quantised DCT coefficient grids, one per scan component,
    /// in scan order. `blocks[r * blocksWide + c].coefficients[k]`
    /// is the *quantised* coefficient at natural index `k` of the
    /// block at column `c`, row `r`. Block grid sizes are aligned
    /// to the component's sampling-factor-relative resolution
    /// (i.e. they may extend past `width × height` for
    /// chroma-subsampled inputs — same shape as
    /// `JPEGScanDecoder.decodeBaselineSequential` returns).
    public let quantisedComponents: [JPEGComponentBlocks]
    /// Quant tables in zig-zag order, keyed by table destination
    /// ID. Each `frameComponent.quantTableId` points into this
    /// list. We don't dictionary-key by ID at this level because
    /// the canonical order in the JPEG matters for byte-exact
    /// reverse-encode (jbrd / Phase J capstone work).
    public let quantTables: [JPEGQuantTable]

    /// Total quantised coefficient count across every component
    /// in every block — useful as a one-number "how big is this
    /// image's coefficient state?" diagnostic.
    public var totalCoefficientCount: Int {
        quantisedComponents.reduce(0) {
            $0 + $1.blocks.count * 64
        }
    }
}

extension JPEGDecoder {

    /// Decode a JPEG to its dequantised-pending DCT coefficient
    /// state — the structured handoff the eventual JXL coefficient
    /// bridge will consume.
    ///
    /// Stops the standard decode pipeline after the scan decoder
    /// (i.e. before `JPEGDequantiser` / IDCT / colour conversion).
    /// Same scope envelope as `decode(_:)`: baseline-sequential 1-
    /// or 3-component 8-bit JPEGs; other shapes throw
    /// `JPEGDecoderError.unsupported`.
    public static func decodeToCoefficients(
        _ data: Data
    ) throws -> JPEGCoefficientImage {
        // Walk every segment, collecting state. Same prelude as
        // `decode(_:)` — kept duplicated here on purpose because
        // the two entry points may diverge as the coefficient
        // bridge work matures (e.g. progressive scan support
        // landing in `decodeToCoefficients` before `decode`).
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

        // Progressive (SOF2) accumulation: one zero-filled grid per
        // frame component, refined in place across every scan.
        var progressive: [JPEGComponentBlocks]?

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

            if seg.kind == .startOfScan {
                guard let scan = scanHeader else {
                    throw JPEGDecoderError.missingScan
                }
                guard !frameComponents.isEmpty else {
                    throw JPEGDecoderError.missingFrame
                }
                guard precision == 8 else {
                    throw JPEGDecoderError.unsupported(
                        "\(precision)-bit precision "
                        + "(only 8-bit supported)")
                }
                let nC = frameComponents.count
                guard nC == 1 || nC == 3 else {
                    throw JPEGDecoderError.unsupported(
                        "\(nC)-component frame "
                        + "(only 1 or 3 supported)")
                }
                if frameKind == .progressiveDCT {
                    // Decode this scan into the shared grids and keep
                    // walking — the next scan refines them further.
                    if progressive == nil {
                        progressive = allocateProgressiveGrids(
                            frameComponents: frameComponents,
                            width: width, height: height)
                    }
                    var br = JPEGBitReader(data,
                        startingAt: entropyStartOffset)
                    try JPEGScanDecoder.decodeProgressive(
                        from: &br, scanHeader: scan,
                        frameComponents: frameComponents,
                        imageWidth: width, imageHeight: height,
                        dcCodebooks: dcMap, acCodebooks: acMap,
                        restartInterval: restartInterval,
                        components: &progressive!)
                    continue   // resume segment walk for the next scan
                }
                // Sequential (baseline / extended): single scan, decode
                // and stop.
                break
            }
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
                "\(precision)-bit precision "
                + "(only 8-bit supported)")
        }
        let nComponents = frameComponents.count
        guard nComponents == 1 || nComponents == 3 else {
            throw JPEGDecoderError.unsupported(
                "\(nComponents)-component frame "
                + "(only 1 or 3 supported)")
        }

        // Progressive: every scan already folded into `progressive`.
        if frameKind == .progressiveDCT {
            guard let comps = progressive else {
                throw JPEGDecoderError.missingScan
            }
            return JPEGCoefficientImage(
                width: width, height: height,
                precision: precision, frameKind: frameKind,
                frameComponents: frameComponents,
                quantisedComponents: comps,
                quantTables: quantTables)
        }

        guard frameKind == .baselineDCT
            || frameKind == .extendedSequential else {
            throw JPEGDecoderError.unsupported(
                "non-baseline frame: \(frameKind.label)")
        }

        var bitReader = JPEGBitReader(data,
            startingAt: entropyStartOffset)
        let comps = try JPEGScanDecoder.decodeBaselineSequential(
            from: &bitReader,
            scanHeader: scan,
            frameComponents: frameComponents,
            imageWidth: width, imageHeight: height,
            dcCodebooks: dcMap, acCodebooks: acMap,
            restartInterval: restartInterval)

        return JPEGCoefficientImage(
            width: width, height: height,
            precision: precision, frameKind: frameKind,
            frameComponents: frameComponents,
            quantisedComponents: comps,
            quantTables: quantTables)
    }

    /// Allocate zero-filled per-component coefficient grids sized
    /// like the baseline-sequential decoder's output (each grid is
    /// `mcusWide·Hi × mcusHigh·Vi` blocks). Progressive scans refine
    /// these in place.
    private static func allocateProgressiveGrids(
        frameComponents: [JPEGFrameComponent],
        width: Int, height: Int
    ) -> [JPEGComponentBlocks] {
        let maxH = frameComponents.map(\.hSamplingFactor).max() ?? 1
        let maxV = frameComponents.map(\.vSamplingFactor).max() ?? 1
        let mcusWide = (width + 8 * maxH - 1) / (8 * maxH)
        let mcusHigh = (height + 8 * maxV - 1) / (8 * maxV)
        return frameComponents.map { fc in
            let bw = mcusWide * fc.hSamplingFactor
            let bh = mcusHigh * fc.vSamplingFactor
            return JPEGComponentBlocks(
                componentId: fc.componentId,
                blocksWide: bw, blocksHigh: bh,
                blocks: Array(
                    repeating: JPEGCoefficientBlock(),
                    count: bw * bh))
        }
    }
}
