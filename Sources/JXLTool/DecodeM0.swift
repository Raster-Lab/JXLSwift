// `jxl-tool decode-m0` — pure-Swift decoder front-end for the M0
// project-internal placeholder format. See `EncodeM0.swift` for the
// caveat about M0 not being a real JXL file.

import ArgumentParser
import Foundation
import JXLSwift

struct DecodeM0: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "decode-m0",
        abstract: "Decode a project-internal M0 placeholder file back to PNM."
    )

    @Option(name: .shortAndLong, help: "Input .m0 path")
    var input: String

    @Option(name: .shortAndLong, help: "Output image path (PGM or PPM)")
    var output: String

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)

        let m0Data: Data
        do { m0Data = try Data(contentsOf: inputURL) }
        catch { print("error reading \(input): \(error)", to: &standardError)
                throw JXLExitCode.generalError }

        let frame: ImageFrame
        do { frame = try MinimalLosslessCodec.decode(m0Data) }
        catch {
            print("M0 decode error: \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        let pnm: Data
        do { pnm = try PNM.write(frame) }
        catch let e as PNMError {
            print("PNM write error: \(e)", to: &standardError)
            throw JXLExitCode.generalError
        }

        do { try pnm.write(to: outputURL) }
        catch { print("error writing \(output): \(error)", to: &standardError)
                throw JXLExitCode.generalError }

        print(
            "decoded \(frame.width)×\(frame.height) " +
            "\(channelDescription(frame.channels))" +
            " \(frame.pixelType.bitsPerSample)-bit"
        )
    }
}
