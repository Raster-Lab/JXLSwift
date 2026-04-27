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

    @Option(name: .long, help: "Maximum number of files in flight (default: 4). Acts as an upper bound; actual parallelism may be lower if --max-memory is reached.")
    var parallel: Int = 4

    @Option(name: .long, help: "Per-encode worker threads (0 = libjxl default)")
    var threads: Int = 1

    @Option(name: .long, help: "Memory budget in MB for concurrent encodes (default: 25% of physical RAM). Caps in-flight memory regardless of --parallel.")
    var maxMemoryMB: Int?

    @Option(name: .long, help: "Per-pixel-byte working-set multiplier used for admission control (default 4). libjxl typically uses 3-5× the input pixel buffer.")
    var memoryOverhead: Double = 4.0

    @Flag(name: .long, help: "Group DICOM slices that share a SeriesInstanceUID into a single multi-frame .jxl. The output is named after the series UID, ordered by InstanceNumber / SliceLocation.")
    var volumeAware: Bool = false

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

        var inputs = findInputs(in: inputURL, recursive: recursive)
        guard !inputs.isEmpty else {
            if !quiet { print("No supported images found in \(inputDirectory)") }
            return
        }

        // Volume-aware grouping (Phase 3b): merge DICOM slices that share a
        // SeriesInstanceUID into one multi-frame .jxl. Non-DICOM inputs are
        // passed through to the per-file path. Slice order: instanceNumber
        // ascending, then sliceLocation ascending.
        var volumeGroups: [(seriesUID: String, slices: [URL])] = []
        if volumeAware {
            var byUID: [String: [(URL, DICOMMetadata)]] = [:]
            var nonDICOM: [URL] = []
            for url in inputs {
                guard url.pathExtension.lowercased() == "dcm" else {
                    nonDICOM.append(url); continue
                }
                guard let (_, meta) = try? DICOMReader.readWithMetadata(url),
                      let uid = meta.seriesInstanceUID, !uid.isEmpty else {
                    nonDICOM.append(url); continue
                }
                byUID[uid, default: []].append((url, meta))
            }
            for (uid, slices) in byUID {
                let sorted = slices.sorted { a, b in
                    let inA = a.1.instanceNumber ?? Int.max
                    let inB = b.1.instanceNumber ?? Int.max
                    if inA != inB { return inA < inB }
                    let slA = a.1.sliceLocation.isFinite ? a.1.sliceLocation : .infinity
                    let slB = b.1.sliceLocation.isFinite ? b.1.sliceLocation : .infinity
                    return slA < slB
                }
                volumeGroups.append((uid, sorted.map { $0.0 }))
            }
            // The flat `inputs` list now drives the non-DICOM path only;
            // volumeGroups handles the DICOM side.
            inputs = nonDICOM
            if !quiet, !volumeGroups.isEmpty {
                print("Volume-aware: \(volumeGroups.count) series, "
                    + "\(volumeGroups.reduce(0) { $0 + $1.slices.count }) slices grouped")
            }
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

        let budgetBytes: Int = (maxMemoryMB.map { $0 * 1024 * 1024 })
            ?? Self.defaultMemoryBudgetBytes()
        let budget = MemoryBudget(totalBytes: budgetBytes)

        // Phase A2: graceful SIGINT handling. Tasks already running when
        // Ctrl-C arrives finish their current file; new work is skipped.
        Self.cancelled = false
        Self.installSIGINTHandler(quiet)

        if !quiet {
            print("=== JXLSwift Batch ===")
            print("Input:        \(inputURL.path)")
            print("Output:       \(outputURL.path)")
            print("Files:        \(inputs.count)")
            print("Mode:         \(modeDescription(mode))")
            print("Effort:       \(effortLevel) (\(effort))")
            print("Parallelism:  up to \(parallel) files × \(threads) threads/file")
            print("Mem budget:   \(formatBytes(budgetBytes))  (overhead × \(memoryOverhead))")
            print()
        }

        let start = Date()
        var summary = await runConcurrently(
            inputs: inputs, inputBase: inputURL, outputBase: outputURL,
            options: opts, parallel: max(1, parallel), overwrite: overwrite, quiet: quiet,
            budget: budget, overhead: memoryOverhead
        )
        if !volumeGroups.isEmpty {
            let volumeSummary = await runVolumeGroups(
                volumeGroups, outputBase: outputURL, options: opts,
                overwrite: overwrite, quiet: quiet,
                budget: budget, overhead: memoryOverhead
            )
            summary.encoded += volumeSummary.encoded
            summary.skipped += volumeSummary.skipped
            summary.failed += volumeSummary.failed
            summary.bytesIn += volumeSummary.bytesIn
            summary.bytesOut += volumeSummary.bytesOut
            summary.perFile.append(contentsOf: volumeSummary.perFile)
        }
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

    /// Process-wide flag set by SIGINT handler so in-flight tasks know
    /// to stop scheduling new work. We use a `nonisolated(unsafe)` Bool
    /// rather than a true atomic: the race is benign — at worst we
    /// schedule one extra task before noticing the flag, and we never
    /// observe undefined behaviour because Bool stores are atomic on
    /// every platform we ship to.
    nonisolated(unsafe) static var cancelled: Bool = false
    nonisolated(unsafe) private static var signalSource: DispatchSourceSignal?

    /// Install a SIGINT handler that flips `cancelled` and prints a hint.
    /// We use a libdispatch source so the handler runs on a queue, not
    /// the signal-delivery thread (signal-safety in Swift is brittle).
    private static func installSIGINTHandler(_ quiet: Bool) {
        guard signalSource == nil else { return }
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        src.setEventHandler {
            Self.cancelled = true
            if !quiet {
                FileHandle.standardError.write(Data("\nReceived SIGINT — finishing in-flight encodes, then exiting.\n".utf8))
            }
        }
        // Ignore the default SIGINT action while our source is active.
        signal(SIGINT, SIG_IGN)
        src.activate()
        signalSource = src
    }

    /// Async semaphore that gates encode-task dispatch on a byte budget.
    /// Each task must `acquire(bytes:)` before holding any pixel data and
    /// `release(bytes:)` once that data is no longer live. The acquire
    /// blocks until enough budget is free; if a single task's request
    /// exceeds the total budget it is admitted regardless (otherwise the
    /// run would deadlock — better to admit one over-budget request than
    /// wedge the pipeline).
    actor MemoryBudget {
        private let total: Int
        private var used: Int = 0
        private var waiters: [(bytes: Int, cont: CheckedContinuation<Void, Never>)] = []

        init(totalBytes: Int) { self.total = max(1, totalBytes) }

        var capacity: Int { total }

        func acquire(bytes: Int) async {
            if used + bytes <= total || used == 0 {
                used += bytes
                return
            }
            await withCheckedContinuation { cont in
                waiters.append((bytes, cont))
            }
            used += bytes
        }

        func release(bytes: Int) {
            used = max(0, used - bytes)
            // Wake any waiters that now fit, in FIFO order.
            while let head = waiters.first, used + head.bytes <= total || used == 0 {
                waiters.removeFirst()
                head.cont.resume()
            }
        }
    }

    /// Default memory budget = 25% of physical RAM.
    private static func defaultMemoryBudgetBytes() -> Int {
        let ramBytes = Int(ProcessInfo.processInfo.physicalMemory)
        return ramBytes / 4
    }

    /// Estimate the memory cost of encoding a single file. We don't read
    /// the pixels yet at this point, so this is sized off the file size
    /// — accurate for raw 8-bit imagery, 2× too large for 16-bit DICOM
    /// (DICOM file = pixel bytes + small header), conservative for PNG
    /// (where the file is already compressed). The libjxl working-set
    /// multiplier handles the rest.
    private func estimateEncodeBytes(forFile size: Int) -> Int {
        Int(Double(size) * memoryOverhead)
    }

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
        options: EncodingOptions, parallel: Int, overwrite: Bool, quiet: Bool,
        budget: MemoryBudget, overhead: Double
    ) async -> Summary {
        let total = inputs.count
        var summary = Summary()
        var idx = 0
        var done = 0

        await withTaskGroup(of: (URL, EncodeResult).self) { group in
            // Pre-compute file sizes so we can quote the budget request.
            // Seed up to `parallel` tasks, each gated by the memory budget
            // before it touches pixel data.
            while idx < min(parallel, total) {
                let url = inputs[idx]
                idx += 1
                let bytesEstimate = Self.estimateForFile(url, overhead: overhead)
                group.addTask { [budget] in
                    await budget.acquire(bytes: bytesEstimate)
                    let r = await Self.encodeOne(input: url, inputBase: inputBase,
                                                 outputBase: outputBase,
                                                 options: options, overwrite: overwrite)
                    await budget.release(bytes: bytesEstimate)
                    return (url, r)
                }
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

                if idx < total, !Self.cancelled {
                    let next = inputs[idx]; idx += 1
                    let bytesEstimate = Self.estimateForFile(next, overhead: overhead)
                    group.addTask { [budget] in
                        await budget.acquire(bytes: bytesEstimate)
                        let r = await Self.encodeOne(input: next, inputBase: inputBase,
                                                     outputBase: outputBase,
                                                     options: options, overwrite: overwrite)
                        await budget.release(bytes: bytesEstimate)
                        return (next, r)
                    }
                }
            }
        }
        return summary
    }

    /// Encode each (seriesUID, [slice URL]) group as a single multi-frame
    /// .jxl file written under outputBase. Output names are
    /// `<series-uid-suffix>_<count>.jxl` derived from the trailing UID
    /// component (DICOM UIDs are typically dotted, with the slice/series
    /// part at the end).
    private func runVolumeGroups(
        _ groups: [(seriesUID: String, slices: [URL])],
        outputBase: URL, options: EncodingOptions,
        overwrite: Bool, quiet: Bool,
        budget: MemoryBudget, overhead: Double
    ) async -> Summary {
        var summary = Summary()
        await withTaskGroup(of: (URL, EncodeResult).self) { group in
            // Series are big jobs; we deliberately serialize them for now
            // (parallelism inside libjxl is enough). This also keeps memory
            // predictable since one volume already uses N×slice memory.
            for (uid, slices) in groups {
                let firstSlice = slices.first!
                // Estimate volume memory: sum of slice file sizes × overhead.
                let bytesEstimate = slices.reduce(0) { acc, u in
                    let sz = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                    return acc + Int(Double(sz) * overhead)
                }
                let outName = Self.shortUIDName(uid) + "_x\(slices.count).jxl"
                let outURL = outputBase.appendingPathComponent(outName)

                if !overwrite, FileManager.default.fileExists(atPath: outURL.path) {
                    let szIn = slices.reduce(0) { acc, u in
                        let s = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
                        return acc + s
                    }
                    let szOut = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? 0
                    let result = EncodeResult(
                        bytesIn: szIn, bytesOut: szOut, ok: false, skipped: true
                    )
                    summary.encoded += 0; summary.skipped += 1
                    summary.bytesIn += szIn; summary.bytesOut += szOut
                    summary.perFile.append((firstSlice, result))
                    if !quiet { print("[skip] \(outName) (already exists; --overwrite to redo)") }
                    continue
                }

                group.addTask { [budget] in
                    await budget.acquire(bytes: bytesEstimate)
                    let r = await Self.encodeVolume(slices: slices, outputURL: outURL, options: options)
                    await budget.release(bytes: bytesEstimate)
                    return (firstSlice, r)
                }
            }
            for await (firstSlice, result) in group {
                if result.ok {
                    summary.encoded += 1
                } else if result.skipped {
                    summary.skipped += 1
                } else {
                    summary.failed += 1
                }
                summary.bytesIn += result.bytesIn
                summary.bytesOut += result.bytesOut
                summary.perFile.append((firstSlice, result))
                if !quiet {
                    let ratio = result.bytesOut > 0 ? Double(result.bytesIn) / Double(result.bytesOut) : 0
                    let tag = result.ok ? String(format: "%.2f×", ratio) : "FAIL"
                    print("[volume] \(result.frameCount) slices → \(tag)")
                }
            }
        }
        return summary
    }

    /// Compose a short, filesystem-friendly name from a DICOM UID. Falls
    /// back to a hex hash if the UID is empty.
    private static func shortUIDName(_ uid: String) -> String {
        let parts = uid.split(separator: ".")
        let tail = parts.suffix(3).joined(separator: ".")
        return tail.isEmpty ? "series_\(abs(uid.hashValue))" : "series_\(tail)"
    }

    /// Read N DICOM slices, encode them as a single multi-frame JXL.
    private static func encodeVolume(slices: [URL], outputURL: URL, options: EncodingOptions) async -> EncodeResult {
        var frames: [ImageFrame] = []
        var bytesIn = 0
        for url in slices {
            bytesIn += (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            if let dcm = try? DICOMReader.read(url) {
                frames.append(dcm)
            } else if let m = loadDICOMViaMagick(url) {
                frames.append(m)
            } else {
                return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
            }
        }
        // Verify dimensions match.
        guard let first = frames.first else {
            return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
        }
        for f in frames.dropFirst() {
            guard f.width == first.width, f.height == first.height,
                  f.channels == first.channels, f.pixelType == first.pixelType else {
                return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
            }
        }
        do {
            try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoded = try JXLEncoder(options: options).encode(frames)
            try encoded.data.write(to: outputURL)
            return EncodeResult(
                bytesIn: bytesIn, bytesOut: encoded.data.count,
                width: first.width, height: first.height,
                channels: first.channels, frameCount: frames.count,
                bitDepth: first.pixelType.bitsPerSample,
                encodingTime: encoded.stats.encodingTime,
                ok: true, skipped: false
            )
        } catch {
            return EncodeResult(bytesIn: bytesIn, bytesOut: 0, ok: false, skipped: false)
        }
    }

    private static func estimateForFile(_ url: URL, overhead: Double) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Int(Double(size) * overhead)
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
