// Stub subcommands for family parity with J2KSwift's `j2k` CLI.
// These accept the same flag conventions but don't implement the
// underlying behaviour yet — they print a brief "not yet
// implemented" message and exit cleanly. Their presence keeps the
// CLI surface aligned with `j2k`'s subcommand list so users can
// type the same commands across the codec family.
//
// See Documentation/FAMILY-API-PARITY.md for the alignment plan.

import ArgumentParser
import Foundation
import JXLSwift

/// Print the version string. Mirrors `j2k version`.
struct Version: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the JXLSwift version."
    )

    func run() throws {
        print("\(JXLToolVersion)")
    }
}

/// Compare two images pixel-by-pixel and report quality metrics.
/// Mirrors `j2k compare` — same metrics (PSNR, MSE, MAE, max
/// error, bit-exact flag) and same output shape (text or JSON).
///
/// Inputs may be either PNM (PGM / PPM / PAM) or JXL — the file
/// type is auto-detected from the leading magic bytes (`P5`/`P6`/
/// `P7` for PNM; `0xFF 0x0A` naked codestream or the JXL ISOBMFF
/// `JXL ` ftyp brand for container form), with `.jxl` extension as
/// a fallback hint. JXL inputs are run through `JXLDecoder.decode`
/// before metric computation, so `jxl compare ref.ppm out.jxl`
/// works without a manual decode step.
///
/// Usage:
///
///     jxl compare reference.ppm test.ppm           # PNM ↔ PNM
///     jxl compare reference.ppm test.jxl           # PNM ↔ JXL
///     jxl compare reference.jxl test.jxl --json    # JXL ↔ JXL
///
/// PSNR formula (per channel):
///
///     MSE   = mean((reference[i] - test[i])²) over all pixels
///     PSNR  = 10 · log10(maxVal² / MSE)  dB
///     where maxVal = (1 << bitsPerSample) - 1.
struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two images — PSNR / MSE / MAE / max error. Accepts PNM or JXL inputs."
    )

    @Argument(help: "Reference (original) image path — PGM / PPM / PAM / JXL.")
    var reference: String

    @Argument(help: "Test (reconstructed) image path — PGM / PPM / PAM / JXL.")
    var test: String

    @Flag(help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    @Flag(help: "Suppress per-component table; report overall metrics only.")
    var quiet: Bool = false

    @Option(name: .customLong("frame"),
            help: "0-based frame index to compare when either input is a JXL animation. Default 0 (first frame). Use `--all-frames` to compare every frame in lockstep.")
    var frame: Int = 0

    @Flag(name: .customLong("all-frames"),
          help: "Compare every frame in lockstep between two JXL animations. Both inputs must hold the same number of frames; per-frame metrics are reported and averaged.")
    var allFrames: Bool = false

    func run() throws {
        if allFrames {
            try runAllFrames()
            return
        }
        let refImg = try loadComparableImage(path: reference,
                                             frameIndex: frame)
        let testImg = try loadComparableImage(path: test,
                                              frameIndex: frame)

        guard refImg.width == testImg.width,
              refImg.height == testImg.height,
              refImg.channels == testImg.channels,
              refImg.pixelType == testImg.pixelType else {
            FileHandle.standardError.write(Data((
                "compare: image shapes differ — " +
                "reference \(refImg.width)×\(refImg.height) " +
                "\(refImg.channels)ch \(refImg.pixelType.bitsPerSample)bpp vs " +
                "test \(testImg.width)×\(testImg.height) " +
                "\(testImg.channels)ch \(testImg.pixelType.bitsPerSample)bpp\n"
            ).utf8))
            throw JXLExitCode.invalidArguments
        }

        let metrics = ImageMetrics.compute(reference: refImg, test: testImg)

        if json {
            print(metrics.jsonOutput(reference: reference, test: test))
        } else {
            metrics.printText(reference: reference, test: test, quiet: quiet)
        }
    }

    /// `--all-frames` path: decode both inputs to frame arrays
    /// (JXL → all frames, PNM → 1-element array), insist on
    /// matching frame counts, compute per-frame metrics, and print
    /// each plus an averaged summary line.
    private func runAllFrames() throws {
        let refFrames = try loadComparableFrames(path: reference)
        let testFrames = try loadComparableFrames(path: test)

        guard refFrames.count == testFrames.count else {
            print("compare --all-frames: frame counts differ — "
                + "reference has \(refFrames.count), test has "
                + "\(testFrames.count)", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        var perFrame: [ImageMetrics] = []
        for (i, pair) in zip(refFrames, testFrames).enumerated() {
            guard pair.0.width == pair.1.width,
                  pair.0.height == pair.1.height,
                  pair.0.channels == pair.1.channels,
                  pair.0.pixelType == pair.1.pixelType else {
                print("compare --all-frames: frame \(i) shape "
                    + "mismatch", to: &standardError)
                throw JXLExitCode.invalidArguments
            }
            perFrame.append(ImageMetrics.compute(
                reference: pair.0, test: pair.1))
        }

        if json {
            print(jsonAllFrames(perFrame: perFrame))
        } else {
            print("All-frames comparison:")
            print("  Reference:  \(reference) "
                + "(\(refFrames.count) frame(s))")
            print("  Test:       \(test) "
                + "(\(testFrames.count) frame(s))")
            print("")
            for (i, m) in perFrame.enumerated() {
                print("  [\(i)] PSNR=\(formatPSNR(m.overallPSNR)) "
                    + "MAE=\(String(format: "%.4f", m.overallMAE)) "
                    + "max=\(m.overallMaxError) "
                    + "bit-exact="
                    + (m.bitExact ? "Y" : "N"))
            }
            print("")
            let meanMAE = perFrame.map { $0.overallMAE }
                .reduce(0, +) / Double(perFrame.count)
            let meanMaxErr = Double(perFrame.map {
                $0.overallMaxError
            }.reduce(0, +)) / Double(perFrame.count)
            let allBitExact = perFrame.allSatisfy {
                $0.bitExact
            }
            let meanPSNR = perFrame.map { $0.overallPSNR }
                .filter { $0.isFinite }
                .reduce(0.0, +)
            let psnrAvg = perFrame.contains { $0.overallPSNR.isInfinite }
                ? "Inf"
                : String(format: "%.4f dB",
                    meanPSNR / Double(perFrame.count))
            print("  Average:    PSNR=\(psnrAvg) "
                + "MAE=\(String(format: "%.4f", meanMAE)) "
                + "max=\(String(format: "%.1f", meanMaxErr))")
            print("  All frames bit-exact: "
                + (allBitExact ? "YES ✓" : "NO ✗"))
        }
    }

    private func formatPSNR(_ psnr: Double) -> String {
        if !psnr.isFinite { return "Inf" }
        return String(format: "%.4f", psnr) + " dB"
    }

    private func jsonAllFrames(perFrame: [ImageMetrics]) -> String {
        var s = "{"
        s += "\"reference\": \"\(reference)\", "
        s += "\"test\": \"\(test)\", "
        s += "\"frameCount\": \(perFrame.count), "
        let inner = perFrame.enumerated().map { (i, m) -> String in
            let psnr = m.overallPSNR.isFinite
                ? String(format: "%.6f", m.overallPSNR)
                : "null"
            return "{\"index\": \(i), \"psnr\": \(psnr), "
                + "\"mae\": \(String(format: "%.6f", m.overallMAE)), "
                + "\"maxError\": \(m.overallMaxError), "
                + "\"bitExact\": \(m.bitExact)}"
        }.joined(separator: ", ")
        s += "\"frames\": [\(inner)], "
        let allExact = perFrame.allSatisfy {
            $0.bitExact
        }
        s += "\"allBitExact\": \(allExact)"
        s += "}"
        return s
    }
}

/// Decode `path` to a single `ImageFrame`. Detects file type from
/// the leading magic bytes:
///   - `P5` / `P6` / `P7` → PNM (PGM / PPM / PAM)
///   - `0xFF 0x0A` → naked JXL codestream
///   - `0x00 0x00 0x00 0x0C 'J' 'X' 'L' ' '` → JXL ISOBMFF box
/// Falls back to the file extension if the magic check is ambiguous.
/// `frameIndex` is honoured only for JXL inputs (PNM is always a
/// single frame).
private func loadComparableImage(
    path: String, frameIndex: Int = 0
) throws -> ImageFrame {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch {
        print("compare: cannot read \(path): \(error)",
              to: &standardError)
        throw JXLExitCode.generalError
    }
    if isJXL(data: data, path: path) {
        do {
            if frameIndex == 0 {
                return try JXLDecoder().decode(data)
            }
            return try JXLDecoder().decodeFrame(
                data, at: frameIndex)
        } catch let e as DecoderError {
            print("compare: JXL decode failed for \(path) "
                + "(frame \(frameIndex)): "
                + "\(e.localizedDescription)", to: &standardError)
            throw JXLExitCode.generalError
        }
    }
    if frameIndex != 0 {
        print("compare: --frame \(frameIndex) ignored for PNM "
            + "input \(path) (PNM is single-frame)",
            to: &standardError)
    }
    do { return try PNM.read(data) }
    catch let e as PNMError {
        print("compare: PNM parse failed for \(path): \(e)",
              to: &standardError)
        throw JXLExitCode.invalidArguments
    }
}

/// Decode `path` to every available frame. For PNM inputs that's a
/// 1-element array; for JXL it's the result of `decodeAll`.
private func loadComparableFrames(
    path: String
) throws -> [ImageFrame] {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch {
        print("compare: cannot read \(path): \(error)",
              to: &standardError)
        throw JXLExitCode.generalError
    }
    if isJXL(data: data, path: path) {
        do { return try JXLDecoder().decodeAll(data) }
        catch let e as DecoderError {
            print("compare: JXL decodeAll failed for \(path): "
                + "\(e.localizedDescription)", to: &standardError)
            throw JXLExitCode.generalError
        }
    }
    do { return [try PNM.read(data)] }
    catch let e as PNMError {
        print("compare: PNM parse failed for \(path): \(e)",
              to: &standardError)
        throw JXLExitCode.invalidArguments
    }
}

private func isJXL(data: Data, path: String) -> Bool {
    // Naked codestream signature: 0xFF 0x0A (per ISO/IEC 18181-1
    // §F.1, the JPEG XL codestream marker).
    if data.count >= 2 && data[0] == 0xFF && data[1] == 0x0A {
        return true
    }
    // ISOBMFF container: starts with a 12-byte JXL signature box
    // 0x00 0x00 0x00 0x0C 'J' 'X' 'L' ' ' 0x0D 0x0A 0x87 0x0A
    // (ISO/IEC 18181-2 §B.1 — "JXL " box plus the standard
    // ISOBMFF preamble).
    if data.count >= 8 {
        let head = Array(data.prefix(8))
        if head == [0x00, 0x00, 0x00, 0x0C,
                    0x4A, 0x58, 0x4C, 0x20] {
            return true
        }
    }
    // Extension fallback for borderline cases (truncated files,
    // etc.). Lower-cased so `Foo.JXL` matches.
    let ext = URL(fileURLWithPath: path)
        .pathExtension.lowercased()
    return ext == "jxl" || ext == "jxc"
}

/// Generate shell completions for `jxl` / `jxl-tool`. Mirrors
/// `j2k completions`. Delegates to swift-argument-parser's
/// `JXLTool.completionScript(for:)` so completions automatically
/// stay in sync with the actual CLI surface — no hand-maintained
/// completion lists.
///
/// Usage:
///
///     jxl completions bash > /etc/bash_completion.d/jxl
///     jxl completions zsh  > ~/.zsh-completions/_jxl
///     jxl completions fish > ~/.config/fish/completions/jxl.fish
struct Completions: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate shell completions for the jxl CLI."
    )

    @Argument(help: "Target shell: bash, zsh, or fish.")
    var shell: ShellChoice

    func run() throws {
        let script = JXLTool.completionScript(for: shell.completionShell)
        print(script)
    }
}

/// Argument-parser-friendly enum for the supported shells.
/// Mirrors `CompletionShell` but as an `ExpressibleByArgument`.
enum ShellChoice: String, ExpressibleByArgument, CaseIterable {
    case bash, zsh, fish

    var completionShell: CompletionShell {
        switch self {
        case .bash: return .bash
        case .zsh:  return .zsh
        case .fish: return .fish
        }
    }
}

/// Validate a JPEG XL file against the spec. Mirrors `j2k validate`.
///
/// Two-tier validation:
///
/// 1. **Structural** — `JXLDecoder.inspect(_:)` walks container,
///    SizeHeader, ImageMetadata, and reports parse errors with
///    spec-section citations. Always runs.
/// 2. **Functional** — attempts a full `JXLDecoder.decode(_:)`.
///    Reports whether all frames decode and any throw points
///    (e.g., "VarDCT frame requires kQuantModeAFV — not yet ported").
///    Skipped with `--no-decode` for fast metadata-only checks.
///
/// A full ISO/IEC 18181 conformance pass against the
/// [jxl-conformance](https://github.com/libjxl/conformance)
/// test-vector repository is a follow-on bite — would require
/// fetching the repo + parsing its manifest. For now, this
/// subcommand validates ANY JPEG XL file the user supplies, which
/// is the more common need.
struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a JPEG XL file against ISO/IEC 18181."
    )

    @Argument(help: "JPEG XL file to validate.")
    var input: String

    @Flag(help: "Skip the decode step; structural validation only.")
    var noDecode: Bool = false

    @Flag(help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    func run() throws {
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data(
                "validate: file not found: \(input)\n".utf8))
            throw JXLExitCode.invalidArguments
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            FileHandle.standardError.write(Data(
                "validate: cannot read \(input): \(error)\n".utf8))
            throw JXLExitCode.generalError
        }

        var report = ValidationReport(input: input, fileSize: data.count)
        let decoder = JXLDecoder()

        // 1. Structural validation via inspect().
        do {
            let inspection = try decoder.inspect(data)
            report.structural = .passStructural(
                form: inspection.form == .naked ? "naked codestream" : "ISOBMFF container",
                width: Int(inspection.xsize),
                height: Int(inspection.ysize),
                boxTypes: inspection.boxTypes,
                hasMetadata: inspection.metadata != nil)
        } catch {
            report.structural = .fail(reason: "\(error)")
        }

        // 2. Functional validation via decodeAll() (unless
        // --no-decode). decodeAll handles both single-frame and
        // animation inputs — for an animation it returns every
        // frame, so an animation passes only if EVERY frame decodes
        // cleanly. For single-frame inputs the result is a 1-element
        // array, equivalent to the old behaviour.
        if !noDecode, report.structural.isPass {
            do {
                let frames = try decoder.decodeAll(data)
                guard let first = frames.first else {
                    report.functional = .fail(
                        reason: "decodeAll returned 0 frames")
                    throw JXLExitCode.generalError
                }
                report.functional = .passFunctional(
                    frameCount: frames.count,
                    firstFrameWidth: first.width,
                    firstFrameHeight: first.height,
                    firstFrameChannels: first.channels)
            } catch JXLExitCode.generalError {
                // Re-raise without overwriting the report message.
            } catch {
                report.functional = .fail(reason: "\(error)")
            }
        }

        // 3. Print report.
        if json {
            print(report.jsonOutput())
        } else {
            report.printText()
        }

        // Exit code: 0 if both passed, 1 if any failed. Use direct
        // exit() instead of throwing so the validation report (which
        // is the user-facing output) isn't cluttered with
        // ArgumentParser's "Error: ..." display.
        if !report.allPassed {
            Foundation.exit(1)
        }
    }
}

/// Internal validation-report container. Sendable for safety.
struct ValidationReport {
    let input: String
    let fileSize: Int
    var structural: Result = .notRun
    var functional: Result = .notRun

    enum Result {
        case notRun
        case passStructural(form: String, width: Int, height: Int,
                            boxTypes: [String], hasMetadata: Bool)
        case passFunctional(frameCount: Int, firstFrameWidth: Int,
                            firstFrameHeight: Int, firstFrameChannels: Int)
        case fail(reason: String)

        var isPass: Bool {
            switch self {
            case .passStructural, .passFunctional: return true
            case .fail, .notRun: return false
            }
        }
    }

    var allPassed: Bool {
        if case .fail = structural { return false }
        if case .fail = functional { return false }
        return true
    }

    func printText() {
        print("Validating: \(input)")
        print("  File size:  \(fileSize) bytes")
        print("")
        print("  Structural validation (headers, container):")
        switch structural {
        case .passStructural(let form, let w, let h, let boxes, let meta):
            print("    ✅ PASS")
            print("       Form:        \(form)")
            print("       Dimensions:  \(w)×\(h)")
            print("       Boxes:       \(boxes.isEmpty ? "(none)" : boxes.joined(separator: ", "))")
            print("       Metadata:    \(meta ? "parsed" : "not present")")
        case .fail(let reason):
            print("    ❌ FAIL: \(reason)")
        case .notRun, .passFunctional:
            print("    ⚠️  NOT RUN")
        }
        print("")
        print("  Functional validation (decode pipeline):")
        switch functional {
        case .passFunctional(let n, let w, let h, let c):
            print("    ✅ PASS")
            print("       Frames decoded: \(n)")
            print("       First frame:    \(w)×\(h), \(c) channel(s)")
        case .fail(let reason):
            print("    ❌ FAIL: \(reason)")
        case .notRun:
            print("    ⚠️  SKIPPED (use without --no-decode to enable)")
        case .passStructural:
            print("    ⚠️  NOT RUN")
        }
        print("")
        if allPassed {
            print("  Overall: ✅ \(input) is a valid JPEG XL file.")
        } else {
            print("  Overall: ❌ Validation failed (see above).")
        }
    }

    func jsonOutput() -> String {
        var s = "{\n"
        s += "  \"input\": \"\(input)\",\n"
        s += "  \"fileSize\": \(fileSize),\n"
        s += "  \"structural\": \(jsonResult(structural)),\n"
        s += "  \"functional\": \(jsonResult(functional)),\n"
        s += "  \"allPassed\": \(allPassed)\n"
        s += "}"
        return s
    }

    private func jsonResult(_ r: Result) -> String {
        switch r {
        case .notRun:
            return "{\"status\": \"notRun\"}"
        case .passStructural(let form, let w, let h, let boxes, let meta):
            let boxStr = boxes.map { "\"\($0)\"" }.joined(separator: ", ")
            return "{\"status\": \"pass\", \"form\": \"\(form)\", " +
                   "\"width\": \(w), \"height\": \(h), " +
                   "\"boxes\": [\(boxStr)], \"hasMetadata\": \(meta)}"
        case .passFunctional(let n, let w, let h, let c):
            return "{\"status\": \"pass\", \"frameCount\": \(n), " +
                   "\"firstFrameWidth\": \(w), " +
                   "\"firstFrameHeight\": \(h), " +
                   "\"firstFrameChannels\": \(c)}"
        case .fail(let reason):
            // Escape backslashes and quotes for JSON string safety.
            let escaped = reason
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"status\": \"fail\", \"reason\": \"\(escaped)\"}"
        }
    }
}
