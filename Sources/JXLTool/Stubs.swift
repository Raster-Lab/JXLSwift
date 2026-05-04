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

/// Compare two images pixel-by-pixel (PSNR / SSIM / etc.).
/// Mirrors `j2k compare`. Stub for Phase A — the comparison
/// metrics will be wired in a follow-on bite.
struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare two images (stub — pending PSNR/SSIM impl)."
    )

    @Argument(help: "Reference image path")
    var reference: String

    @Argument(help: "Test image path")
    var test: String

    func run() throws {
        FileHandle.standardError.write(Data((
            "compare: not yet implemented — pending PSNR / SSIM / " +
            "byte-equality metric port from J2KSwift's compare " +
            "subcommand. Inputs: \(reference), \(test)\n"
        ).utf8))
        throw JXLExitCode.notImplemented
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
