/// Compare subcommand — compare JXLSwift output with libjxl
///
/// Compares two JPEG XL files byte-by-byte and reports differences.
/// Can also compute quality metrics (PSNR, SSIM) between encoded images.

import ArgumentParser
import Foundation
import JXLSwift

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two JPEG XL files or encoding results"
    )

    @Argument(help: "Path to first .jxl file")
    var file1: String

    @Argument(help: "Path to second .jxl file")
    var file2: String

    @Flag(name: .long, help: "Show byte-level comparison details")
    var bytes: Bool = false

    @Flag(name: .long, help: "Output comparison results in JSON format")
    var json: Bool = false

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    func run() throws {
        let url1 = URL(fileURLWithPath: file1)
        let url2 = URL(fileURLWithPath: file2)

        // Read both files
        let data1: Data
        let data2: Data
        do {
            data1 = try Data(contentsOf: url1)
        } catch {
            throw CompareError.fileNotFound(file1)
        }
        do {
            data2 = try Data(contentsOf: url2)
        } catch {
            throw CompareError.fileNotFound(file2)
        }

        // Validate both files have JXL signatures
        guard data1.count >= 2, data1[0] == 0xFF, data1[1] == 0x0A else {
            throw CompareError.invalidSignature(file1)
        }
        guard data2.count >= 2, data2[0] == 0xFF, data2[1] == 0x0A else {
            throw CompareError.invalidSignature(file2)
        }

        // Perform comparison
        let result = compareFiles(data1: data1, data2: data2)

        if json {
            printJSON(result: result)
        } else {
            printHuman(result: result)
        }

        // Exit with code 1 if files differ
        if !result.identical {
            throw JXLExitCode.generalError
        }
    }

    // MARK: - Comparison Logic

    /// Compare two JXL file data buffers and return a structured result.
    private func compareFiles(data1: Data, data2: Data) -> CompareResult {
        let size1 = data1.count
        let size2 = data2.count
        let identical = data1 == data2

        // Byte-level comparison
        let minLen = min(size1, size2)
        var differingBytes = 0
        var firstDiffOffset: Int?

        for i in 0..<minLen {
            if data1[i] != data2[i] {
                differingBytes += 1
                if firstDiffOffset == nil {
                    firstDiffOffset = i
                }
            }
        }

        // Account for size difference
        differingBytes += abs(size1 - size2)

        let sizeRatio: Double
        if size2 > 0 {
            sizeRatio = Double(size1) / Double(size2)
        } else if size1 > 0 {
            sizeRatio = Double.infinity
        } else {
            sizeRatio = 1.0
        }

        return CompareResult(
            file1: file1,
            file2: file2,
            size1: size1,
            size2: size2,
            identical: identical,
            differingBytes: differingBytes,
            firstDiffOffset: firstDiffOffset,
            sizeRatio: sizeRatio,
            sizeDifference: size1 - size2
        )
    }

    // MARK: - Output Formatting

    private func printHuman(result: CompareResult) {
        print("=== JXLSwift File Comparison ===")
        print()
        print("File 1: \(result.file1)")
        print("  Size: \(formatBytes(result.size1))")
        print("File 2: \(result.file2)")
        print("  Size: \(formatBytes(result.size2))")
        print()

        if result.identical {
            print("Result: ✅ Files are identical")
        } else {
            print("Result: ❌ Files differ")
            print()
            print("Differences:")
            print("  Size difference:  \(result.sizeDifference > 0 ? "+" : "")\(result.sizeDifference) bytes")
            print("  Size ratio:       \(String(format: "%.4f", result.sizeRatio))")
            print("  Differing bytes:  \(result.differingBytes)")

            if let offset = result.firstDiffOffset {
                print("  First diff at:    offset \(offset) (0x\(String(offset, radix: 16, uppercase: true)))")
            }

            if verbose && bytes {
                printByteDetails(result: result)
            }
        }
    }

    private func printByteDetails(result: CompareResult) {
        let url1 = URL(fileURLWithPath: result.file1)
        let url2 = URL(fileURLWithPath: result.file2)

        guard let data1 = try? Data(contentsOf: url1),
              let data2 = try? Data(contentsOf: url2) else {
            return
        }

        print()
        print("Byte-level differences (first 20):")
        let minLen = min(data1.count, data2.count)
        var shown = 0

        for i in 0..<minLen where shown < 20 {
            if data1[i] != data2[i] {
                print(String(
                    format: "  Offset 0x%04X: %02X vs %02X",
                    i, data1[i], data2[i]
                ))
                shown += 1
            }
        }
    }

    private func printJSON(result: CompareResult) {
        var entries: [String] = []
        entries.append("  \"file1\": \"\(escapeJSON(result.file1))\"")
        entries.append("  \"file2\": \"\(escapeJSON(result.file2))\"")
        entries.append("  \"size1\": \(result.size1)")
        entries.append("  \"size2\": \(result.size2)")
        entries.append("  \"identical\": \(result.identical)")
        entries.append("  \"differingBytes\": \(result.differingBytes)")
        if let offset = result.firstDiffOffset {
            entries.append("  \"firstDiffOffset\": \(offset)")
        } else {
            entries.append("  \"firstDiffOffset\": null")
        }
        entries.append("  \"sizeRatio\": \(String(format: "%.6f", result.sizeRatio))")
        entries.append("  \"sizeDifference\": \(result.sizeDifference)")

        print("{\n\(entries.joined(separator: ",\n"))\n}")
    }

    /// Escape special characters for JSON string values.
    private func escapeJSON(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

// MARK: - Supporting Types

/// Result of comparing two JXL files.
struct CompareResult {
    let file1: String
    let file2: String
    let size1: Int
    let size2: Int
    let identical: Bool
    let differingBytes: Int
    let firstDiffOffset: Int?
    let sizeRatio: Double
    let sizeDifference: Int
}

/// Errors specific to the compare subcommand.
enum CompareError: Error, LocalizedError {
    case fileNotFound(String)
    case invalidSignature(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .invalidSignature(let path):
            return "Not a valid JPEG XL file (missing 0xFF 0x0A signature): \(path)"
        }
    }
}
