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
