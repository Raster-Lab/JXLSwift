// `jxl-tool batch` — parallel batch encoder.
//
// Recursively encodes every PNG/JPEG/TIFF/BMP/DICOM under an input
// directory into JPEG XL, in a single long-lived process. The advantage
// over a shell loop calling cjxl per file is twofold:
//   • no per-file process startup cost
//   • DICOM input is read at native bit depth (cjxl can't read .dcm)

import ArgumentParser
import Foundation
import JXLSwift

struct Batch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Batch encode an input directory tree into JPEG XL (parallel)."
    )

    @Argument(help: "Input directory")
    var inputDirectory: String

    @Option(name: .shortAndLong, help: "Output directory (default: same as input)")
    var output: String?

    @Option(name: .shortAndLong, help: "Quality (0–100, ignored if --lossless or --distance)")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Distance (0 = lossless, overrides --quality)")
    var distance: Float?

    @Option(name: .shortAndLong, help: "Effort 1–9")
    var effort: Int = 7

    @Flag(name: .shortAndLong, help: "Lossless compression")
    var lossless: Bool = false

    @Flag(name: .long, help: "Recurse into subdirectories")
    var recursive: Bool = false

    @Option(name: .long, help: "Number of files to encode concurrently (default: 4)")
    var parallel: Int = 4

    @Option(name: .long, help: "Per-encode worker threads (0 = libjxl default)")
    var threads: Int = 1

    @Flag(name: .long, help: "Overwrite existing .jxl outputs")
    var overwrite: Bool = false

    @Flag(name: .long, help: "Quiet (no per-file progress)")
    var quiet: Bool = false

    @Option(name: .long, help: "Write a JSON manifest with per-file results to this path")
    var manifest: String?

    private static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "tif", "bmp", "dcm"]

    func run() async throws {
        let fm = FileManager.default
        let inputURL = URL(fileURLWithPath: inputDirectory).resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: inputURL.path, isDirectory: &isDir), isDir.boolValue else {
            print("Error: not a directory: \(inputDirectory)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let outputURL = output.map(URL.init(fileURLWithPath:))?.resolvingSymlinksInPath() ?? inputURL
        if outputURL != inputURL, !fm.fileExists(atPath: outputURL.path) {
            try fm.createDirectory(at: outputURL, withIntermediateDirectories: true)
        }

        let inputs = findInputs(in: inputURL, recursive: recursive)
        guard !inputs.isEmpty else {
            if !quiet { print("No supported images found in \(inputDirectory)") }
            return
        }

        let mode: CompressionMode = lossless
            ? .lossless
            : (distance.map(CompressionMode.distance) ?? .lossy(quality: quality))
        guard let effortLevel = EncodingEffort(rawValue: effort) else {
            print("Error: --effort must be 1…9", to: &standardError)
            throw JXLExitCode.invalidArguments
        }
        let opts = EncodingOptions(
            mode: mode, effort: effortLevel, progressive: false, numThreads: threads
        )

        if !quiet {
            print("=== JXLSwift Batch ===")
            print("Input:        \(inputURL.path)")
            print("Output:       \(outputURL.path)")
            print("Files:        \(inputs.count)")
            print("Mode:         \(modeDescription(mode))")
            print("Effort:       \(effortLevel) (\(effort))")
            print("Parallelism:  \(parallel) files × \(threads) threads/file")
            print()
        }

        let start = Date()
        let summary = await runConcurrently(
            inputs: inputs, inputBase: inputURL, outputBase: outputURL,
            options: opts, parallel: max(1, parallel), overwrite: overwrite, quiet: quiet
        )
        let elapsed = Date().timeIntervalSince(start)

        if !quiet {
            print()
            print("=== Summary ===")
            print("Encoded:       \(summary.encoded) / \(inputs.count)")
            if summary.skipped > 0 { print("Skipped:       \(summary.skipped) (already existed; use --overwrite to redo)") }
            if summary.failed > 0  { print("Failed:        \(summary.failed)") }
            print("Total input:   \(formatBytes(summary.bytesIn))")
            print("Total output:  \(formatBytes(summary.bytesOut))")
            if summary.bytesOut > 0 {
                let ratio = Double(summary.bytesIn) / Double(summary.bytesOut)
                print("Average ratio: \(String(format: "%.2f", ratio))×")
            }
            print("Wall time:     \(String(format: "%.2f", elapsed))s  (≈ \(String(format: "%.1f", Double(summary.encoded) / max(elapsed, 1e-9))) files/s)")
        }

        if let manifestPath = manifest {
            try writeManifest(
                to: manifestPath,
                inputBase: inputURL,
                outputBase: outputURL,
                results: summary.perFile,
                wallClock: elapsed,
                mode: opts.mode,
                effort: effortLevel
            )
            if !quiet { print("Manifest:      \(manifestPath)") }
        }

        if summary.failed > 0 { throw JXLExitCode.generalError }
    }

    /// Write a JSON manifest with per-file results.
    private func writeManifest(
        to path: String,
        inputBase: URL, outputBase: URL,
        results: [(URL, EncodeResult)],
        wallClock: TimeInterval,
        mode: CompressionMode, effort: EncodingEffort
    ) throws {
        struct Entry: Encodable {
            let input: String
            let output: String
            let bytesIn: Int
            let bytesOut: Int
            let ratio: Double
            let width: Int
            let height: Int
            let channels: Int
            let frames: Int
            let bitDepth: Int
            let encodeTimeS: Double
            let status: String
        }
        struct Manifest: Encodable {
            let mode: String
            let effort: Int
            let parallel: Int
            let wallTimeS: Double
            let totalBytesIn: Int
            let totalBytesOut: Int
            let avgRatio: Double
            let files: [Entry]
        }

        let baseIn = inputBase.resolvingSymlinksInPath().path
        let baseOut = outputBase.resolvingSymlinksInPath().path
        let entries: [Entry] = results.map { (in_, r) in
            let inP = in_.resolvingSymlinksInPath().path
            let inRel = inP.hasPrefix(baseIn + "/") ? String(inP.dropFirst(baseIn.count + 1)) : in_.lastPathComponent
            let stem = (inRel as NSString).deletingPathExtension
            let outRel = "\(stem).jxl"
            let outAbs = "\(baseOut)/\(outRel)"
            let ratio = r.bytesOut > 0 ? Double(r.bytesIn) / Double(r.bytesOut) : 0
            let status = r.ok ? "ok" : (r.skipped ? "skipped" : "failed")
            return Entry(
                input: inRel, output: outRel.replacingOccurrences(of: outAbs, with: outRel),
                bytesIn: r.bytesIn, bytesOut: r.bytesOut, ratio: ratio,
                width: r.width, height: r.height, channels: r.channels,
                frames: r.frameCount, bitDepth: r.bitDepth,
                encodeTimeS: r.encodingTime, status: status
            )
        }
        let okEntries = entries.filter { $0.status == "ok" }
        let avg = okEntries.isEmpty ? 0.0
            : okEntries.reduce(0.0) { $0 + $1.ratio } / Double(okEntries.count)
        let totalIn = entries.reduce(0) { $0 + $1.bytesIn }
        let totalOut = entries.reduce(0) { $0 + $1.bytesOut }
        let m = Manifest(
            mode: modeDescription(mode),
            effort: effort.rawValue,
            parallel: parallel,
            wallTimeS: wallClock,
            totalBytesIn: totalIn, totalBytesOut: totalOut,
            avgRatio: avg, files: entries
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(m)
        try data.write(to: URL(fileURLWithPath: path))
    }

    // MARK: - File discovery

    private func findInputs(in dir: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if recursive {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            for case let u as URL in en where Self.supportedExtensions.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        } else if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for u in entries where Self.supportedExtensions.contains(u.pathExtension.lowercased()) {
                out.append(u)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: - Concurrent encode

    private struct EncodeResult: Sendable {
        let bytesIn: Int
        let bytesOut: Int
        var width: Int = 0
        var height: Int = 0
        var channels: Int = 0
        var frameCount: Int = 0
        var bitDepth: Int = 0
        var encodingTime: TimeInterval = 0
        let ok: Bool
        let skipped: Bool
    }
    private struct Summary: Sendable {
        var encoded: Int = 0
        var skipped: Int = 0
        var failed:  Int = 0
        var bytesIn: Int = 0
        var bytesOut: Int = 0
        var perFile: [(URL, EncodeResult)] = []
    }

    private func runConcurrently(
        inputs: [URL], inputBase: URL, outputBase: URL,
        options: EncodingOptions, parallel: Int, overwrite: Bool, quiet: Bool
    ) async -> Summary {
        let total = inputs.count
        // Throttle to `parallel` in-flight encodes by pairing TaskGroup
        // submissions with completion drains.
        var summary = Summary()
        var idx = 0
        var done = 0

        await withTaskGroup(of: (URL, EncodeResult).self) { group in
            // Seed.
            while idx < min(parallel, total) {
                let url = inputs[idx]
                idx += 1
                group.addTask { (url, await Self.encodeOne(input: url, inputBase: inputBase, outputBase: outputBase, options: options, overwrite: overwrite)) }
            }
            for await (inputURL, result) in group {
                done += 1
                if result.ok {
                    summary.encoded += 1
                } else if result.skipped {
                    summary.skipped += 1
                } else {
                    summary.failed += 1
                }
                summary.bytesIn += result.bytesIn
                summary.bytesOut += result.bytesOut
                summary.perFile.append((inputURL, result))

                if !quiet {
                    let resolvedIn = inputURL.resolvingSymlinksInPath().path
                    let resolvedBase = inputBase.resolvingSymlinksInPath().path
                    let rel = resolvedIn.hasPrefix(resolvedBase + "/")
                        ? String(resolvedIn.dropFirst(resolvedBase.count + 1))
                        : inputURL.lastPathComponent
                    let ratio = result.bytesOut > 0 ? Double(result.bytesIn) / Double(result.bytesOut) : 0
                    let tag = result.ok ? String(format: "%.2f×", ratio) : (result.skipped ? "skip" : "FAIL")
                    print(String(format: "[%4d/%4d] %@ → %@", done, total, rel, tag))
                }

                if idx < total {
                    let next = inputs[idx]; idx += 1
                    group.addTask { (next, await Self.encodeOne(input: next, inputBase: inputBase, outputBase: outputBase, options: options, overwrite: overwrite)) }
                }
            }
        }
        return summary
    }

    private static func encodeOne(
        input: URL, inputBase: URL, outputBase: URL, options: EncodingOptions, overwrite: Bool
    ) async -> EncodeResult {
        let fm = FileManager.default
        let resolvedIn = input.resolvingSymlinksInPath().path
        let resolvedBase = inputBase.path
        let relStem: String = {
            if resolvedIn.hasPrefix(resolvedBase + "/") {
                let rel = String(resolvedIn.dropFirst(resolvedBase.count + 1))
                return (rel as NSString).deletingPathExtension
            }
            return (input.lastPathComponent as NSString).deletingPathExtension
        }()
        let outputURL = outputBase.appendingPathComponent(relStem + ".jxl")

        let outputDir = outputURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: outputDir.path) {
            try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let bytesIn = (try? fm.attributesOfItem(atPath: input.path)[.size] as? Int) ?? 0
        if !overwrite, fm.fileExists(atPath: outputURL.path) {
            let bytesOut = (try? fm.attributesOfItem(atPath: outputURL.path)[.size] as? Int) ?? 0
            return EncodeResult(bytesIn: bytesIn, bytesOut: bytesOut, ok: false, skipped: true)
        }

        let frames: [ImageFrame]
        switch input.pathExtension.lowercased() {
        case "dcm":
            // Fast path: native Swift DICOM reader, preserves bit depth.
            // Falls through to the magick PGM fallback for transfer
            // syntaxes the native reader doesn't handle (compressed DICOM:
            // JPEG / JPEG-LS / JPEG 2000 / RLE).
            if let dcm = try? DICOMReader.read(input) { frames = [dcm] }
            else if let magicked = loadDICOMViaMagick(input) { frames = [magicked] }
            else { return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false) }
        default:
            guard let im = loadImageFrame(from: input) else {
                return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
            }
            frames = [im]
        }

        do {
            let encoded = (frames.count == 1)
                ? try JXLEncoder(options: options).encode(frames[0])
                : try JXLEncoder(options: options).encode(frames)
            try encoded.data.write(to: outputURL)
            let f0 = frames[0]
            let bitDepth = f0.pixelType.bitsPerSample
            return EncodeResult(
                bytesIn: bytesIn, bytesOut: encoded.data.count,
                width: f0.width, height: f0.height,
                channels: f0.channels, frameCount: frames.count,
                bitDepth: bitDepth, encodingTime: encoded.stats.encodingTime,
                ok: true, skipped: false
            )
        } catch {
            return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
        }
    }

    private func modeDescription(_ m: CompressionMode) -> String {
        switch m {
        case .lossless:           return "lossless"
        case .lossy(let q):       return "lossy quality=\(q)"
        case .distance(let d):    return "lossy distance=\(d)"
        }
    }
}
