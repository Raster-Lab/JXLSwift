// `jxl-tool encode` — encode a PNG/JPEG/TIFF/BMP to JPEG XL via JXLSwift.

import ArgumentParser
import Foundation
import JXLSwift

struct Encode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Encode an image to JPEG XL"
    )

    @Option(name: .shortAndLong, help: "Input image path (PNG/JPEG/TIFF/BMP/DICOM .dcm)")
    var input: String

    @Option(name: .shortAndLong, help: "Output .jxl path")
    var output: String

    @Option(name: .shortAndLong, help: "Quality (0–100, ignored if --lossless or --distance)")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Distance (0 = lossless, 1 = visually lossless; overrides --quality)")
    var distance: Float?

    @Option(name: .shortAndLong, help: "Effort 1–9 (1 = fastest, 9 = best)")
    var effort: Int = 7

    @Flag(name: .shortAndLong, help: "Lossless compression (forces distance = 0)")
    var lossless: Bool = false

    @Flag(name: .long, help: "Enable progressive DC encoding")
    var progressive: Bool = false

    @Option(name: .long, help: "Number of encode threads (0 = libjxl default)")
    var threads: Int = 0

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    func run() throws {
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("Error: input file not found: \(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let ext = url.pathExtension.lowercased()
        let frames: [ImageFrame]

        switch ext {
        case "dcm":
            do {
                frames = [try DICOMReader.read(url)]
            } catch {
                print("Error: DICOM read failed for \(input): \(error.localizedDescription)", to: &standardError)
                throw JXLExitCode.generalError
            }
            if verbose {
                print("Loaded DICOM \(frames[0].width)×\(frames[0].height) (\(frames[0].pixelType.bitsPerSample)-bit grayscale)")
            }
        default:
            guard let loaded = loadImageFrame(from: url) else {
                print("Error: could not decode \(input) (supported: PNG, JPEG, TIFF, BMP, DICOM)", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            frames = [loaded]
        }

        let mode: CompressionMode
        if lossless { mode = .lossless }
        else if let d = distance { mode = .distance(d) }
        else { mode = .lossy(quality: quality) }

        guard let effortLevel = EncodingEffort(rawValue: effort) else {
            print("Error: --effort must be 1…9", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let opts = EncodingOptions(
            mode: mode,
            effort: effortLevel,
            progressive: progressive,
            numThreads: threads
        )
        let encoder = JXLEncoder(options: opts)
        let result = (frames.count == 1)
            ? try encoder.encode(frames[0])
            : try encoder.encode(frames)
        try result.data.write(to: URL(fileURLWithPath: output))

        let frameLabel = frames.count == 1 ? "" : " (\(frames.count) frames)"
        let f0 = frames[0]
        print("Encoded \(f0.width)×\(f0.height)\(frameLabel) (\(f0.channels)ch \(f0.pixelType.bitsPerSample)-bit) to \(output)")
        print("  Original:    \(formatBytes(result.stats.originalSize))")
        print("  Compressed:  \(formatBytes(result.stats.compressedSize))")
        print("  Ratio:       \(String(format: "%.2f", result.stats.compressionRatio))×")
        print("  Time:        \(String(format: "%.3f", result.stats.encodingTime))s")
        if verbose {
            print("  Mode:        \(mode)")
            print("  Effort:      \(effortLevel) (\(effort))")
            print("  Distance:    \(opts.distance)")
        }
    }
}
