// `jxl batch` — batch-process every file in an input directory.
//
// Mirrors `j2k batch`'s shape: two sub-subcommands (`encode`,
// `decode`), `-i <dir> -o <dir>` flags, optional `--recursive`
// traversal, `--filter <glob>` to narrow the file set, and a
// `--continue-on-error` switch so one bad file doesn't abort a
// large batch. Output is either a human-readable per-file log
// (default) or a single JSON summary (`--json`).
//
// `jxl batch encode -i pnm/ -o out/` walks `pnm/` for any
// `.pgm` / `.ppm` / `.pam` / `.pnm` file and encodes each one to
// `out/<basename>.jxl`. `jxl batch decode -i jxl/ -o out/` does the
// reverse on `.jxl` files, picking the PNM variant per channel
// count (`.pgm` for 1-ch, `.ppm` for 3-ch, `.pam` for 4-ch).
//
// Transcode is intentionally not exposed yet — JXL↔JPEG transcoding
// is Phase J on ROADMAP.md and will land its own subcommand
// (`jxl transcode`) when the underlying reversible-transcode path
// is built.
//
// Threading: single-threaded for now. The whole batch shares one
// encoder/decoder instance per file (created lazily), so memory
// is bounded by the largest single file. Parallelism is a
// follow-on once the encoder/decoder is fully `Sendable` enough
// to be invoked from multiple Tasks without contention on shared
// caches.

import ArgumentParser
import Foundation
import JXLSwift

struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "batch",
        abstract: "Batch-process every file in a directory (encode or decode).",
        subcommands: [BatchEncode.self, BatchDecode.self]
    )
}

/// Source-image extensions the encode-side batch scans for. PNM
/// family + JPEG (decoded transparently via `JPEGDecoder`).
private let pnmExtensions: Set<String> = [
    "pgm", "ppm", "pam", "pnm",
    "jpg", "jpeg",
]

/// JXL extensions the decode-side batch scans for. `.jxl` is the
/// canonical one; `.jxc` shows up occasionally for codestream-only
/// files.
private let jxlExtensions: Set<String> = ["jxl", "jxc"]

// MARK: - jxl batch encode

struct BatchEncode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "encode",
        abstract: "Encode every PNM in <input> dir to JXL in <output> dir."
    )

    @Option(name: .shortAndLong,
            help: "Input directory containing PNM files.")
    var input: String

    @Option(name: .shortAndLong,
            help: "Output directory for `.jxl` files. Created if missing.")
    var output: String

    @Flag(help: "Recurse into subdirectories. Output mirrors the input tree.")
    var recursive: Bool = false

    @Option(help: "Shell-glob filter applied to file names (e.g. `frame_*.ppm`). Default: any PNM/PGM/PPM/PAM file.")
    var filter: String?

    @Flag(name: .customLong("continue-on-error"),
          help: "Skip files that fail to encode instead of aborting.")
    var continueOnError: Bool = false

    @Flag(name: .shortAndLong,
          help: "Lossless Modular compression (default is lossy VarDCT).")
    var lossless: Bool = false

    @Option(name: .shortAndLong,
            help: "Quality 0–100 (lossy only). Default 90.")
    var quality: Float = 90

    @Flag(help: "Suppress per-file progress lines (final summary still prints).")
    var quiet: Bool = false

    @Flag(help: "Emit a JSON summary instead of text.")
    var json: Bool = false

    func run() throws {
        let files = try gatherFiles(
            root: input, extensions: pnmExtensions,
            recursive: recursive, filter: filter)
        try ensureDirectory(output)

        let mode: CompressionMode = lossless
            ? .lossless
            : .lossy(quality: max(0, min(quality, 100)))
        let encoder = JXLEncoder(options: EncodingOptions(mode: mode))

        var summary = BatchSummary(operation: "encode")
        let started = clock_gettime_ms()

        for src in files {
            let dst = mappedOutputPath(
                src: src, inputRoot: input, outputRoot: output,
                newExtension: "jxl")
            do {
                try ensureDirectory(parent(of: dst))
                let pnmData = try Data(contentsOf:
                    URL(fileURLWithPath: src))
                // Auto-detect JPEG (SOI magic) vs PNM by content
                // — the extension is the scan filter, content is
                // the source of truth so `foo.ppm` that's actually
                // a stuffed JPEG fails cleanly inside PNM.read.
                let frame: ImageFrame
                if JPEGSegmentReader.looksLikeJPEG(pnmData) {
                    frame = try JPEGDecoder.decode(pnmData)
                } else {
                    frame = try PNM.read(pnmData)
                }
                let encoded = try encoder.encode(frame)
                try encoded.data.write(to: URL(fileURLWithPath: dst))
                summary.recordOk(
                    src: src, dst: dst,
                    inBytes: pnmData.count,
                    outBytes: encoded.data.count)
                if !quiet && !json {
                    let pct = Double(encoded.data.count) * 100
                        / Double(max(1, pnmData.count))
                    print("  \(src) → \(dst)  "
                        + "\(formatBytes(pnmData.count)) → "
                        + "\(formatBytes(encoded.data.count)) "
                        + "(\(String(format: "%.1f", pct))%)")
                }
            } catch {
                summary.recordFail(src: src, reason: "\(error)")
                if !quiet && !json {
                    print("  \(src) FAILED: \(error)",
                          to: &standardError)
                }
                if !continueOnError {
                    throw JXLExitCode.generalError
                }
            }
        }
        summary.elapsedMs = clock_gettime_ms() - started
        try summary.print(json: json, quiet: quiet)
        if summary.failed > 0 && !continueOnError {
            throw JXLExitCode.generalError
        }
    }
}

// MARK: - jxl batch decode

struct BatchDecode: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode",
        abstract: "Decode every JXL in <input> dir to PNM in <output> dir."
    )

    @Option(name: .shortAndLong,
            help: "Input directory containing `.jxl` files.")
    var input: String

    @Option(name: .shortAndLong,
            help: "Output directory for decoded PNM files. Created if missing.")
    var output: String

    @Flag(help: "Recurse into subdirectories. Output mirrors the input tree.")
    var recursive: Bool = false

    @Option(help: "Shell-glob filter applied to file names (default: `*.jxl`).")
    var filter: String?

    @Flag(name: .customLong("continue-on-error"),
          help: "Skip files that fail to decode instead of aborting.")
    var continueOnError: Bool = false

    @Flag(help: "Suppress per-file progress lines (final summary still prints).")
    var quiet: Bool = false

    @Flag(help: "Emit a JSON summary instead of text.")
    var json: Bool = false

    func run() throws {
        let files = try gatherFiles(
            root: input, extensions: jxlExtensions,
            recursive: recursive, filter: filter)
        try ensureDirectory(output)

        let decoder = JXLDecoder()
        var summary = BatchSummary(operation: "decode")
        let started = clock_gettime_ms()

        for src in files {
            do {
                try ensureDirectory(parent(of: mappedOutputPath(
                    src: src, inputRoot: input, outputRoot: output,
                    newExtension: "pnm")))
                let jxlData = try Data(contentsOf:
                    URL(fileURLWithPath: src))
                let frame = try decoder.decode(jxlData)
                let ext = pnmExtension(for: frame.channels,
                                       bitsPerSample: frame.pixelType.bitsPerSample)
                let dst = mappedOutputPath(
                    src: src, inputRoot: input, outputRoot: output,
                    newExtension: ext)
                let pnm = try PNM.write(frame)
                try pnm.write(to: URL(fileURLWithPath: dst))
                summary.recordOk(
                    src: src, dst: dst,
                    inBytes: jxlData.count,
                    outBytes: pnm.count)
                if !quiet && !json {
                    print("  \(src) → \(dst)  "
                        + "\(formatBytes(jxlData.count)) → "
                        + "\(formatBytes(pnm.count))  "
                        + "(\(frame.width)×\(frame.height) "
                        + "\(channelDescription(frame.channels)) "
                        + "\(frame.pixelType.bitsPerSample)-bit)")
                }
            } catch {
                summary.recordFail(src: src, reason: "\(error)")
                if !quiet && !json {
                    print("  \(src) FAILED: \(error)",
                          to: &standardError)
                }
                if !continueOnError {
                    throw JXLExitCode.generalError
                }
            }
        }
        summary.elapsedMs = clock_gettime_ms() - started
        try summary.print(json: json, quiet: quiet)
        if summary.failed > 0 && !continueOnError {
            throw JXLExitCode.generalError
        }
    }
}

// MARK: - shared helpers

/// Walk `root`, returning paths with extensions in `extensions`.
/// `filter` is a shell-style glob (matched against basename only)
/// applied on top of the extension check.
private func gatherFiles(
    root: String, extensions: Set<String>,
    recursive: Bool, filter: String?
) throws -> [String] {
    let rootURL = URL(fileURLWithPath: root)
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: root, isDirectory: &isDir),
          isDir.boolValue else {
        print("error: input '\(root)' is not a directory",
              to: &standardError)
        throw JXLExitCode.invalidArguments
    }

    var out: [String] = []
    if recursive {
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []) else {
            return []
        }
        for case let url as URL in enumerator {
            let vals = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            if matches(url: url, extensions: extensions,
                       glob: filter) {
                out.append(url.path)
            }
        }
    } else {
        let entries = try fm.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        for url in entries {
            let vals = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard vals.isRegularFile == true else { continue }
            if matches(url: url, extensions: extensions,
                       glob: filter) {
                out.append(url.path)
            }
        }
    }
    return out.sorted()
}

private func matches(url: URL, extensions: Set<String>,
                     glob: String?) -> Bool {
    let ext = url.pathExtension.lowercased()
    guard extensions.contains(ext) else { return false }
    if let g = glob, !fnmatch(pattern: g,
                              name: url.lastPathComponent) {
        return false
    }
    return true
}

/// Tiny `fnmatch`-style glob — `*` matches any run of characters,
/// `?` matches one. Case-sensitive (Darwin file systems are
/// case-insensitive by default; we keep this simple and let the
/// directory listing reflect what the FS does).
private func fnmatch(pattern p: String, name n: String) -> Bool {
    // Recursive char-by-char match. Strings are tiny (a basename
    // and a glob) so the simple algorithm wins on clarity.
    let pat = Array(p)
    let str = Array(n)
    func go(_ i: Int, _ j: Int) -> Bool {
        if i == pat.count { return j == str.count }
        switch pat[i] {
        case "*":
            if i + 1 == pat.count { return true }
            var k = j
            while k <= str.count {
                if go(i + 1, k) { return true }
                k += 1
            }
            return false
        case "?":
            return j < str.count && go(i + 1, j + 1)
        default:
            return j < str.count && pat[i] == str[j]
                && go(i + 1, j + 1)
        }
    }
    return go(0, 0)
}

/// Translate `<inputRoot>/.../foo.ppm` to
/// `<outputRoot>/.../foo.<newExtension>`. Preserves subdirectory
/// structure under `inputRoot` for the recursive path.
private func mappedOutputPath(
    src: String, inputRoot: String, outputRoot: String,
    newExtension: String
) -> String {
    let inRoot = URL(fileURLWithPath: inputRoot)
        .standardizedFileURL.path
    let srcStd = URL(fileURLWithPath: src)
        .standardizedFileURL.path
    let rel: String
    if srcStd.hasPrefix(inRoot + "/") {
        rel = String(srcStd.dropFirst(inRoot.count + 1))
    } else {
        rel = URL(fileURLWithPath: src).lastPathComponent
    }
    let stem: String
    if let dotIdx = rel.lastIndex(of: ".") {
        stem = String(rel[..<dotIdx])
    } else {
        stem = rel
    }
    return URL(fileURLWithPath: outputRoot)
        .appendingPathComponent("\(stem).\(newExtension)").path
}

private func parent(of path: String) -> String {
    URL(fileURLWithPath: path).deletingLastPathComponent().path
}

private func ensureDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(
        atPath: path, withIntermediateDirectories: true)
}

private func pnmExtension(for channels: Int,
                          bitsPerSample: Int) -> String {
    switch channels {
    case 1: return "pgm"
    case 3: return "ppm"
    case 2, 4: return "pam"
    default: return "pam"
    }
}

private func clock_gettime_ms() -> Double {
    var ts = timespec()
    #if os(Darwin)
    clock_gettime(CLOCK_UPTIME_RAW, &ts)
    #else
    clock_gettime(CLOCK_MONOTONIC, &ts)
    #endif
    return Double(ts.tv_sec) * 1_000.0
        + Double(ts.tv_nsec) / 1_000_000.0
}

// MARK: - summary

/// Accumulates per-file results and prints either a multi-line
/// text summary or a one-line JSON object on completion.
private struct BatchSummary {
    let operation: String
    var processed: Int = 0
    var failed: Int = 0
    var inBytesTotal: Int = 0
    var outBytesTotal: Int = 0
    var elapsedMs: Double = 0
    var failures: [(src: String, reason: String)] = []

    mutating func recordOk(src: String, dst: String,
                           inBytes: Int, outBytes: Int) {
        processed += 1
        inBytesTotal += inBytes
        outBytesTotal += outBytes
    }

    mutating func recordFail(src: String, reason: String) {
        failed += 1
        failures.append((src, reason))
    }

    func print(json: Bool, quiet: Bool) throws {
        if json {
            Swift.print(jsonText())
        } else if !quiet {
            Swift.print("")
            Swift.print("batch \(operation): \(processed) ok, "
                + "\(failed) failed in "
                + "\(String(format: "%.1f", elapsedMs)) ms")
            if inBytesTotal > 0 {
                let pct = Double(outBytesTotal) * 100
                    / Double(inBytesTotal)
                Swift.print("  total: "
                    + "\(formatBytes(inBytesTotal)) → "
                    + "\(formatBytes(outBytesTotal)) "
                    + "(\(String(format: "%.1f", pct))%)")
            }
            if !failures.isEmpty {
                Swift.print("  failures:")
                for f in failures {
                    Swift.print("    \(f.src): \(f.reason)")
                }
            }
        }
    }

    private func jsonText() -> String {
        var s = "{"
        s += "\"operation\": \"\(operation)\", "
        s += "\"processed\": \(processed), "
        s += "\"failed\": \(failed), "
        s += "\"inBytes\": \(inBytesTotal), "
        s += "\"outBytes\": \(outBytesTotal), "
        s += "\"elapsedMs\": "
            + "\(String(format: "%.1f", elapsedMs)), "
        let failJSON = failures.map { f in
            let reason = f.reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"src\": \"\(f.src)\", "
                + "\"reason\": \"\(reason)\"}"
        }.joined(separator: ", ")
        s += "\"failures\": [\(failJSON)]"
        s += "}"
        return s
    }
}
