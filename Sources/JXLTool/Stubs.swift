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

    func run() throws {
        let refImg = try loadComparableImage(path: reference)
        let testImg = try loadComparableImage(path: test)

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
}

/// Decode `path` to an `ImageFrame`. Detects file type from the
/// leading magic bytes:
///   - `P5` / `P6` / `P7` → PNM (PGM / PPM / PAM)
///   - `0xFF 0x0A` → naked JXL codestream
///   - `0x00 0x00 0x00 0x0C 'J' 'X' 'L' ' '` → JXL ISOBMFF box
/// Falls back to the file extension if the magic check is ambiguous.
private func loadComparableImage(path: String) throws -> ImageFrame {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do { data = try Data(contentsOf: url) }
    catch {
        print("compare: cannot read \(path): \(error)",
              to: &standardError)
        throw JXLExitCode.generalError
    }
    if isJXL(data: data, path: path) {
        do { return try JXLDecoder().decode(data) }
        catch let e as DecoderError {
            print("compare: JXL decode failed for \(path): "
                + "\(e.localizedDescription)", to: &standardError)
            throw JXLExitCode.generalError
        }
    }
    do { return try PNM.read(data) }
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

        // 2. Functional validation via decode() (unless --no-decode).
        if !noDecode, report.structural.isPass {
            do {
                let frame = try decoder.decode(data)
                report.functional = .passFunctional(
                    frameCount: 1,
                    firstFrameWidth: frame.width,
                    firstFrameHeight: frame.height,
                    firstFrameChannels: frame.channels)
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
