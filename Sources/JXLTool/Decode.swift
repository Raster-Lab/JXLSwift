// `jxl-tool decode` — decode a JPEG XL file to PNG via JXLSwift.
// Multi-frame bitstreams are decoded into N PNGs at <stem>_zNNN.png.

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file to PNG (multi-frame inputs become N PNGs)"
    )

    @Option(name: .shortAndLong, help: "Input .jxl path")
    var input: String

    @Option(name: .shortAndLong, help: "Output .png path (single-frame) or stem (multi-frame)")
    var output: String

    @Flag(name: .long, help: "Show verbose output")
    var verbose: Bool = false

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            print("Error: input file not found: \(input)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        let bytes = try Data(contentsOf: inputURL)
        let frames = try JXLDecoder().decodeAll(bytes)

        if frames.count == 1 {
            let outputURL = URL(fileURLWithPath: output)
            guard writePNG(frames[0], to: outputURL) else {
                print("Error: failed to write PNG to \(output)", to: &standardError)
                throw JXLExitCode.generalError
            }
            print("Decoded \(frames[0].width)×\(frames[0].height) (\(frames[0].channels)ch) → \(output)")
        } else {
            // Multi-frame: write <stem>_zNNN.png per frame.
            let outputURL = URL(fileURLWithPath: output)
            let stem = outputURL.deletingPathExtension()
            let dir = stem.deletingLastPathComponent()
            let baseName = stem.lastPathComponent
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pad = String(format: "%03d", frames.count)
            _ = pad
            let width = max(3, String(frames.count).count)
            for (i, f) in frames.enumerated() {
                let idx = String(format: "%0\(width)d", i)
                let url = dir.appendingPathComponent("\(baseName)_z\(idx).png")
                guard writePNG(f, to: url) else {
                    print("Error: failed to write \(url.path)", to: &standardError)
                    throw JXLExitCode.generalError
                }
            }
            print("Decoded multi-frame \(frames.count) × \(frames[0].width)×\(frames[0].height) → \(dir.path)/\(baseName)_z*.png")
        }
        if verbose, let f = frames.first {
            print("  Pixel type:   \(f.pixelType)")
            print("  Colour space: \(f.colorSpace)")
            print("  Has alpha:    \(f.hasAlpha)")
        }
    }
}
