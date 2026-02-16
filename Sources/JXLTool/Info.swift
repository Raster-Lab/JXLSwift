/// Info subcommand — display JPEG XL file information
///
/// Reads a JPEG XL file and displays metadata about its contents.

import ArgumentParser
import Foundation
import JXLSwift

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Display JPEG XL file information"
    )

    @Argument(help: "Path to .jxl file")
    var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)

        print("File: \(file)")
        print("Size: \(formatBytes(data.count))")

        // Validate signature
        guard data.count >= 2 else {
            print("Error: File too small to be a valid JPEG XL file")
            throw ExitCode.failure
        }

        if data[0] == 0xFF && data[1] == 0x0A {
            print("Format: JPEG XL codestream")
        } else {
            print("Format: Unknown (expected JPEG XL signature 0xFF 0x0A)")
            throw ExitCode.failure
        }

        // Parse basic header (simplified)
        if data.count >= 12 {
            let width = readU32(data, offset: 2)
            let height = readU32(data, offset: 6)
            let bitDepth = data.count > 10 ? data[10] : 0
            let channels = data.count > 11 ? data[11] : 0

            print("Dimensions: \(width)×\(height)")
            print("Bit depth: \(bitDepth)")
            print("Channels: \(channels)")
        }

        print("Signature bytes: \(data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " "))")
    }

    private func readU32(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset]) << 24 |
               UInt32(data[offset + 1]) << 16 |
               UInt32(data[offset + 2]) << 8 |
               UInt32(data[offset + 3])
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
    }
}
