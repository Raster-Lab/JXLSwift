// `jxl-tool info` — parse a JXL file's container + SizeHeader and report
// what the foundation can already extract. Does not require the full
// codec, so this works against the pure-Swift implementation as it
// stands.

import ArgumentParser
import Foundation
import JXLSwift

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print container + SizeHeader info from a JPEG XL file"
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

        print("File:       \(input)")
        print("Bytes:      \(formatBytes(data.count))")
        print("Form:       \(inspection.form == .naked ? "naked codestream" : "ISOBMFF container")")
        print("Dimensions: \(inspection.xsize)×\(inspection.ysize)")
        if !inspection.boxTypes.isEmpty {
            print("Boxes:      \(inspection.boxTypes.joined(separator: ", "))")
        }
    }
}
