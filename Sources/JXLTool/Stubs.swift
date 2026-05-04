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
/// Inputs are PNM / PGM / PPM / PAM files. JXL-decoded bitstreams
/// are accepted via the existing `decode` subcommand pipeline:
/// pre-decode the JXL to a PNM and feed both PNMs to `compare`.
/// Direct JXL inputs would require routing through the
/// JXLDecoder — left as a follow-on once the decoder is robust
/// enough to ship as the canonical reader.
///
/// Usage:
///
///     jxl compare reference.ppm test.ppm
///     jxl compare reference.ppm test.ppm --json
///
/// PSNR formula (per channel):
///
///     MSE   = mean((reference[i] - test[i])²) over all pixels
///     PSNR  = 10 · log10(maxVal² / MSE)  dB
///     where maxVal = (1 << bitsPerSample) - 1.
struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two images (PSNR / MSE / MAE / max error)."
    )

    @Argument(help: "Reference (original) image path — PGM / PPM / PAM.")
    var reference: String

    @Argument(help: "Test (reconstructed) image path — PGM / PPM / PAM.")
    var test: String

    @Flag(help: "Emit JSON instead of human-readable text.")
    var json: Bool = false

    @Flag(help: "Suppress per-component table; report overall metrics only.")
    var quiet: Bool = false

    func run() throws {
        let refData = try Data(contentsOf: URL(fileURLWithPath: reference))
        let testData = try Data(contentsOf: URL(fileURLWithPath: test))
        let refImg = try PNM.read(refData)
        let testImg = try PNM.read(testData)

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
/// Stub — full conformance validation requires a test-vector harness
/// (see ROADMAP.md Phase C).
struct Validate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a JPEG XL file against ISO/IEC 18181 (stub)."
    )

    @Argument(help: "JPEG XL file to validate")
    var input: String

    func run() throws {
        FileHandle.standardError.write(Data((
            "validate: not yet implemented — pending conformance " +
            "test-vector harness (jxl-conformance repo). Input: " +
            "\(input)\n"
        ).utf8))
        throw JXLExitCode.notImplemented
    }
}
