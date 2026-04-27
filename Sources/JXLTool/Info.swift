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
                print("Animation:    \(anim.tpsNumerator)/\(anim.tpsDenominator) tps, loops=\(anim.numLoops)")
            }
            if m.intensityTarget != 255.0 {
                print("HDR:          intensity target = \(m.intensityTarget) cd/m²")
            }
        } else {
            print()
            print("(ImageMetadata could not be parsed)")
        }
    }
}

private func formatBitDepth(_ bd: BitDepth) -> String {
    if bd.floatingPoint {
        return "\(bd.bitsPerSample)-bit float (exp=\(bd.exponentBitsPerSample))"
    }
    return "\(bd.bitsPerSample)-bit unsigned"
}
