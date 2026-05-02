// `jxl-tool decode` — pure-Swift JPEG XL decoder front-end.
//
// Routes through `JXLDecoder.decode(_:)`, which dispatches into
// the Modular pixel pipeline for spec-compliant Modular frames.
// Output is a binary PNM (PGM/PPM/PAM) chosen by the input's
// channel count and bit depth.
//
// VarDCT (lossy) input still throws `.notImplemented` until that
// codec lands.

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file to PNM (lossless Modular frames only)."
    )

    @Option(name: .shortAndLong, help: "Input .jxl path")
    var input: String

    @Option(name: .shortAndLong, help: "Output PNM path (.pgm / .ppm / .pam)")
    var output: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let jxlData: Data
        do { jxlData = try Data(contentsOf: inputURL) }
        catch {
            print("error reading \(input): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let frame: ImageFrame
        do { frame = try JXLDecoder().decode(jxlData) }
        catch let e as DecoderError {
            print("decode error: \(e.localizedDescription)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let pnm: Data
        do { pnm = try PNM.write(frame) }
        catch let e as PNMError {
            print("PNM write error: \(e)", to: &standardError)
            throw JXLExitCode.generalError
        }

        do { try pnm.write(to: outputURL) }
        catch {
            print("error writing \(output): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        print(
            "decoded \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels))"
            + " \(frame.pixelType.bitsPerSample)-bit: "
            + "\(formatBytes(jxlData.count)) → \(formatBytes(pnm.count))"
        )
    }
}
