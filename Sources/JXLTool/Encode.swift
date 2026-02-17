/// Encode subcommand — encode raw pixel data to JPEG XL
///
/// Encodes a source image (or generates a test pattern) to JPEG XL format.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL format"
    )

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "output.jxl"

    @Option(name: .shortAndLong, help: "Quality level (0–100, default 90). Ignored when --lossless is set.")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Distance parameter (overrides quality). Lower is higher quality.")
    var distance: Float?

    @Option(name: .shortAndLong, help: "Encoding effort (1–9, default 7)")
    var effort: Int = 7

    @Flag(name: .shortAndLong, help: "Use lossless compression")
    var lossless: Bool = false
    
    @Flag(name: .long, help: "Enable progressive encoding (DC → AC refinement passes)")
    var progressive: Bool = false

    @Flag(help: "Disable hardware acceleration")
    var noAccelerate: Bool = false

    @Flag(help: "Disable Metal GPU acceleration")
    var noMetal: Bool = false

    @Option(name: .shortAndLong, help: "Width of test image to generate")
    var width: Int = 256

    @Option(name: .long, help: "Height of test image to generate")
    var height: Int = 256
    
    @Option(name: .long, help: "EXIF orientation (1-8, default 1). 1=normal, 6=90°CW, 3=180°, 8=270°CW")
    var orientation: Int = 1

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Suppress all output except errors")
    var quiet: Bool = false

    func run() throws {
        if verbose && !quiet {
            print("JXLSwift v\(JXLSwift.version)")
            print("Standard: ISO/IEC \(JXLSwift.standardVersion)")
            print()
        }

        // Build encoding options
        let mode: CompressionMode
        if lossless {
            mode = .lossless
        } else if let d = distance {
            mode = .distance(d)
        } else {
            mode = .lossy(quality: quality)
        }

        guard let effortLevel = EncodingEffort(rawValue: effort) else {
            print("Error: Effort must be between 1 and 9", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let options = EncodingOptions(
            mode: mode,
            effort: effortLevel,
            progressive: progressive,
            useHardwareAcceleration: !noAccelerate,
            useAccelerate: !noAccelerate,
            useMetal: !noMetal
        )

        // Generate a test image (until file I/O is implemented)
        if verbose && !quiet {
            print("Generating \(width)×\(height) test image...")
        }
        
        // Validate orientation
        guard orientation >= 1 && orientation <= 8 else {
            print("Error: Orientation must be between 1 and 8", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        var frame = ImageFrame(
            width: width,
            height: height,
            channels: 3,
            pixelType: .uint8,
            colorSpace: .sRGB,
            orientation: UInt32(orientation)
        )

        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let r = UInt16((x * 255) / max(frame.width - 1, 1))
                let g = UInt16((y * 255) / max(frame.height - 1, 1))
                let b = UInt16(128)
                frame.setPixel(x: x, y: y, channel: 0, value: r)
                frame.setPixel(x: x, y: y, channel: 1, value: g)
                frame.setPixel(x: x, y: y, channel: 2, value: b)
            }
        }

        // Encode
        let encoder = JXLEncoder(options: options)
        let result = try encoder.encode(frame)

        // Write output
        let url = URL(fileURLWithPath: output)
        try result.data.write(to: url)

        // Print statistics
        if !quiet {
            print("Encoded \(width)×\(height) image to \(output)")
            print("  Original:    \(formatBytes(result.stats.originalSize))")
            print("  Compressed:  \(formatBytes(result.stats.compressedSize))")
            print("  Ratio:       \(String(format: "%.2f", result.stats.compressionRatio))×")
            print("  Time:        \(String(format: "%.3f", result.stats.encodingTime))s")

            if verbose {
                print("  Mode:        \(lossless ? "lossless" : "lossy")\(progressive ? " (progressive)" : "")")
                print("  Effort:      \(effortLevel) (\(effort))")
                print("  Orientation: \(orientation)")
                if !lossless {
                    if let d = distance {
                        print("  Distance:    \(d)")
                    } else {
                        print("  Quality:     \(quality)")
                    }
                }
            }
        }
    }

}
