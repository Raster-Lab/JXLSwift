// `jxl-tool info` — parse a JXL file's container, SizeHeader, and
// ImageMetadata. Reports what the foundation can extract without
// running the codec layer.

import ArgumentParser
import Foundation
import JXLSwift

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print container + header info from a JPEG XL file"
    )

    @Argument(help: "JPEG XL file path")
    var input: String

    @Flag(name: .long,
          help: "List every frame's duration / isLast / encoding / section count (multi-frame animations).")
    var frames: Bool = false

    func run() throws {
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Error: file not found: \(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let data = try Data(contentsOf: url)
        // Phase J kickoff: `jxl info` recognises plain JPEG inputs
        // as a courtesy — useful for the transcoding workflow
        // where users will eventually feed `.jpg` into the same
        // tool. Pure structural read; no entropy decode.
        if JPEGSegmentReader.looksLikeJPEG(data) {
            try printJPEGInfo(path: input, data: data)
            return
        }
        let inspection = try JXLDecoder().inspect(data)

        print("File:         \(input)")
        print("Size:         \(formatBytes(data.count))")
        print("Form:         \(inspection.form == .naked ? "naked codestream" : "ISOBMFF container")")
        print("Dimensions:   \(inspection.xsize)×\(inspection.ysize)")
        if !inspection.boxTypes.isEmpty {
            print("Boxes:        \(inspection.boxTypes.joined(separator: ", "))")
        }
        if let m = inspection.metadata {
            print()
            print("--- ImageMetadata ---")
            print("All-default:  \(m.allDefault ? "yes" : "no")")
            print("Bit depth:    \(formatBitDepth(m.bitDepth))")
            print("Orientation:  \(m.orientation)")
            print("XYB-encoded:  \(m.xybEncoded ? "yes" : "no")")
            if !m.extraChannels.isEmpty {
                print("Extra ch:     \(m.extraChannels.count)")
                for (i, ec) in m.extraChannels.enumerated() {
                    let extra = ec.type == .alpha
                        ? " (\(ec.alphaAssociated ? "premultiplied" : "straight"))"
                        : ""
                    print("  [\(i)]:        \(ec.type)\(extra) — \(formatBitDepth(ec.bitDepth))\(ec.name.isEmpty ? "" : " '\(ec.name)'")")
                }
            }
            if let anim = m.animation {
                let frameCount = (try? JXLDecoder().countFrames(data))
                    ?? 0
                let countLabel = frameCount > 0
                    ? "\(frameCount) frame(s), "
                    : ""
                print("Animation:    \(countLabel)\(anim.tpsNumerator)/\(anim.tpsDenominator) tps, loops=\(anim.numLoops)")
            }
            if m.intensityTarget != 255.0 {
                print("HDR:          intensity target = \(m.intensityTarget) cd/m²")
            }
        } else {
            print()
            print("(ImageMetadata could not be parsed)")
        }

        // M0 placeholder fields, if the buffer carries the 'M0'
        // marker right after ImageMetadata. This is project-internal
        // diagnostic output — the marker is documented in
        // MinimalLosslessCodec.swift.
        if let m0 = try? MinimalLosslessCodec.inspectM0(data) {
            print()
            print("--- M0 placeholder ---")
            print("Channels:     \(m0.channels) (\(channelDescription(m0.channels)))")
            if m0.channels >= 3 {
                print("RCT variant:  \(rctLabel(m0.rctVariant))")
            }
            print("Predictors:   \(m0.channelPredictors.map(predictorLabel).joined(separator: ", "))")
        } else if !MinimalLosslessCodec.isM0(data) {
            // Frame structure for real cjxl-emitted codestreams (skip
            // for our project-internal M0 placeholder).
            let fi = JXLDecoder().inspectFrameStructure(data)
            if fi.encoding != nil || fi.tocSizes != nil {
                print()
                print("--- Frame structure ---")
                if let enc = fi.encoding {
                    print("Encoding:     \(enc == .modular ? "Modular" : "VarDCT")")
                }
                if let last = fi.isLast {
                    print("Last frame:   \(last ? "yes" : "no")")
                }
                if let flags = fi.flags, flags != 0 {
                    print("Flags:        0x\(String(flags, radix: 16))")
                }
                if let np = fi.numPasses, np > 1 {
                    print("Passes:       \(np)")
                }
                if let toc = fi.tocSizes {
                    print("TOC entries:  \(toc.count) (\(toc.map { "\($0)B" }.joined(separator: ", ")))")
                }
                if let ht = fi.hasModularTree {
                    print("MA-tree:      \(ht ? "present" : "default (single-leaf)")")
                    if let leaves = fi.modularTreeLeafCount {
                        print("Tree leaves:  \(leaves)")
                    }
                }
                if let upc = fi.usePrefixCode {
                    print("Pixel codec:  \(upc ? "prefix codes" : "rANS")")
                }
            }
            // Per-frame listing for multi-frame animations.
            if frames {
                if let summaries = try? JXLDecoder()
                    .inspectFrames(data) {
                    print()
                    print("--- Per-frame structure ---")
                    for s in summaries {
                        let enc = s.encoding == .modular
                            ? "Modular" : "VarDCT"
                        let lastFlag = s.isLast ? " (last)" : ""
                        print(
                            "  [\(s.index)] dur=\(s.duration) "
                            + "encoding=\(enc) "
                            + "sections=\(s.sectionCount) "
                            + "bytes=\(formatBytes(s.totalSectionBytes))"
                            + "\(lastFlag)")
                    }
                }
            }
        }
    }
}

private func rctLabel(_ v: RCTVariant) -> String {
    switch v {
    case .identity: return "identity (no RCT)"
    case .ycocgR:   return "YCoCg-R"
    }
}

private func predictorLabel(_ p: PredictorID) -> String {
    switch p {
    case .zero:             return "zero"
    case .west:             return "west"
    case .north:            return "north"
    case .avgWN:            return "avgWN"
    case .gradient:         return "gradient"
    case .medianWNGradient: return "medianWNGradient"
    case .ww:               return "ww"
    case .nn:               return "nn"
    }
}

private func formatBitDepth(_ bd: BitDepth) -> String {
    if bd.floatingPoint {
        return "\(bd.bitsPerSample)-bit float (exp=\(bd.exponentBitsPerSample))"
    }
    return "\(bd.bitsPerSample)-bit unsigned"
}

/// Print the high-level structure of a plain JPEG file. First step
/// on the Phase J (JXL ↔ JPEG transcoding) road — the same input
/// will eventually feed `jxl transcode` and produce a JXL output
/// that round-trips byte-for-byte back to the JPEG.
private func printJPEGInfo(path: String, data: Data) throws {
    let s: JPEGStructure
    do { s = try JPEGStructure.read(data) }
    catch let e as JPEGParseError {
        print("error parsing JPEG \(path): "
            + (e.errorDescription ?? "\(e)"),
              to: &standardError)
        throw JXLExitCode.generalError
    }
    print("File:         \(path)")
    print("Size:         \(formatBytes(data.count))")
    print("Form:         JPEG (ISO/IEC 10918-1)")
    print("Dimensions:   \(s.width)×\(s.height)")
    print("Components:   \(s.componentCount) "
        + "(\(channelDescription(s.componentCount)))")
    print("Precision:    \(s.precision)-bit")
    print("Frame kind:   \(s.frameKind.label)")
    print("DQT segments: \(s.dqtSegmentCount)")
    print("DHT segments: \(s.dhtSegmentCount)")
    // DC factor (zig-zag index 0) is the most diagnostic single
    // number from a quant table — small → high quality, large →
    // low quality. Cheap one-liner for the transcoder-curious.
    if let qts = try? JPEGStructure.quantTables(in: data),
       !qts.isEmpty {
        let dcs = qts.map { qt in
            "T\(qt.tableId)[DC]=\(qt.zigZagValues.first ?? 0)"
        }.joined(separator: ", ")
        print("Quant DC:     \(dcs)")
    }
    var markers: [String] = []
    if s.hasJFIF { markers.append("JFIF") }
    if s.hasEXIF { markers.append("EXIF") }
    if s.hasAdobe { markers.append("Adobe") }
    if !markers.isEmpty {
        print("Metadata:     \(markers.joined(separator: ", "))")
    }
    if s.usesArithmeticCoding {
        print("Coding:       arithmetic (uncommon)")
    }
    if s.hasRestartInterval {
        print("Restart:      DRI present")
    }
    // Phase J coefficient diagnostic — when the file is in scope
    // for `JPEGDecoder.decodeToCoefficients` (baseline-sequential
    // 1 or 3 components, 8-bit), report the coefficient-image
    // shape that the eventual JXL coefficient bridge will see.
    // For out-of-scope inputs (progressive / 12-bit / CMYK /
    // arithmetic-coded), silently skip — the basic structural
    // summary above is still useful and the throw shouldn't
    // poison `jxl info`.
    if let coef = try? JPEGDecoder.decodeToCoefficients(data) {
        print()
        print("--- JPEG coefficients (Phase J) ---")
        let totalBlocks = coef.quantisedComponents.reduce(0) {
            $0 + $1.blocks.count
        }
        print("Total coefs:  \(coef.totalCoefficientCount) "
            + "(\(totalBlocks) × 8×8 blocks)")
        for (i, cb) in coef.quantisedComponents.enumerated() {
            let fc = coef.frameComponents.first(
                where: { $0.componentId == cb.componentId })
            let sampling = fc.map {
                "H=\($0.hSamplingFactor) V=\($0.vSamplingFactor)"
            } ?? "?"
            let qt = fc.flatMap { fc in
                coef.quantTables.first(where: {
                    $0.tableId == fc.quantTableId
                })
            }
            let dc = qt?.zigZagValues.first.map(String.init)
                ?? "?"
            print("  [\(i)] comp=\(cb.componentId) "
                + "\(cb.blocksWide)×\(cb.blocksHigh) blocks "
                + "(\(sampling), qt=\(fc?.quantTableId ?? -1), "
                + "DC=\(dc))")
        }
    }
    print()
    print("Note: JPEG → JXL transcoding (Phase J) is on the roadmap "
        + "but not yet implemented. `jxl info` reads JPEG structure "
        + "today as the first Phase J deliverable.")
}
