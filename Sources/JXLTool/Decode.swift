// `jxl-tool decode` — pure-Swift JPEG XL decoder front-end.
//
// Routes through `JXLDecoder.decode(_:)` for single-frame inputs
// and `decodeAll(_:)` for multi-frame animations (with the
// `--all-frames` flag). Output is a binary PNM (PGM/PPM/PAM)
// chosen by the input's channel count and bit depth.

import ArgumentParser
import Foundation
import JXLSwift

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Decode a JPEG XL file to PNM. Multi-frame "
            + "animations: pass `--all-frames` and use `output` "
            + "as a `printf`-style template (e.g. `out-%03d.ppm`) "
            + "to write one file per frame."
    )

    @Option(name: .shortAndLong, help: "Input .jxl path")
    var input: String

    @Option(name: .shortAndLong,
            help: "Output PNM path (.pgm / .ppm / .pam). With `--all-frames`, treated as a `printf`-style template; `%d` is replaced with the 0-based frame index.")
    var output: String

    @Flag(name: .customLong("all-frames"),
          help: "Decode every frame of an animation. `output` is treated as a per-frame template.")
    var allFrames: Bool = false

    @Option(name: .customLong("frame"),
            help: "Decode just the frame at this 0-based index from a multi-frame animation. Mutually exclusive with `--all-frames`.")
    var frameIndex: Int?

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)

        let jxlData: Data
        do { jxlData = try Data(contentsOf: inputURL) }
        catch {
            print("error reading \(input): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }

        if allFrames && frameIndex != nil {
            print("error: --all-frames and --frame are mutually "
                + "exclusive", to: &standardError)
            throw JXLExitCode.invalidArguments
        }

        if allFrames {
            try runMultiFrame(jxlData: jxlData)
        } else if let idx = frameIndex {
            try runSingleFrameAt(
                jxlData: jxlData, index: idx,
                outputURL: URL(fileURLWithPath: output))
        } else {
            try runSingleFrame(jxlData: jxlData,
                               outputURL: URL(fileURLWithPath: output))
        }
    }

    private func runSingleFrameAt(
        jxlData: Data, index: Int, outputURL: URL
    ) throws {
        let frame: ImageFrame
        do {
            frame = try JXLDecoder().decodeFrame(
                jxlData, at: index)
        } catch let e as DecoderError {
            print("decode error: \(e.localizedDescription)",
                  to: &standardError)
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
            print("error writing \(output): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        print(
            "decoded frame \(index): \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels))"
            + " \(frame.pixelType.bitsPerSample)-bit: "
            + "\(formatBytes(jxlData.count)) → "
            + "\(formatBytes(pnm.count))"
        )
    }

    private func runSingleFrame(
        jxlData: Data, outputURL: URL
    ) throws {
        let frame: ImageFrame
        do { frame = try JXLDecoder().decode(jxlData) }
        catch let e as DecoderError {
            print("decode error: \(e.localizedDescription)",
                  to: &standardError)
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
            print("error writing \(output): \(error)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }

        print(
            "decoded \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels))"
            + " \(frame.pixelType.bitsPerSample)-bit: "
            + "\(formatBytes(jxlData.count)) → "
            + "\(formatBytes(pnm.count))"
        )
    }

    private func runMultiFrame(jxlData: Data) throws {
        let frames: [ImageFrame]
        do { frames = try JXLDecoder().decodeAll(jxlData) }
        catch let e as DecoderError {
            print("decode error: \(e.localizedDescription)",
                  to: &standardError)
            throw JXLExitCode.generalError
        }
        guard !frames.isEmpty else {
            print("decoded 0 frames", to: &standardError)
            throw JXLExitCode.generalError
        }
        var totalOut = 0
        for (i, frame) in frames.enumerated() {
            let outPath = renderTemplate(output, index: i)
            let pnm: Data
            do { pnm = try PNM.write(frame) }
            catch let e as PNMError {
                print("PNM write error for frame \(i): \(e)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
            do {
                try pnm.write(to: URL(fileURLWithPath: outPath))
            } catch {
                print("error writing \(outPath): \(error)",
                      to: &standardError)
                throw JXLExitCode.generalError
            }
            totalOut += pnm.count
        }
        let f0 = frames[0]
        print(
            "decoded \(frames.count) × \(f0.width)×\(f0.height) "
            + "\(channelDescription(f0.channels))"
            + " \(f0.pixelType.bitsPerSample)-bit frames: "
            + "\(formatBytes(jxlData.count)) → "
            + "\(formatBytes(totalOut)) across "
            + "\(frames.count) PNM file(s)"
        )
    }

    /// Replace the first `%[0]NNd`-style printf spec in `template`
    /// with the index. Falls back to inserting `-NN` before the
    /// file extension if no spec is found — users who forget the
    /// `%d` still get distinct per-frame filenames instead of
    /// every frame overwriting the same path.
    private func renderTemplate(_ template: String, index: Int)
        -> String {
        if let range = template.range(
            of: #"%0*\d*d"#,
            options: .regularExpression) {
            let fmt = String(template[range])
            return template.replacingCharacters(
                in: range,
                with: String(format: fmt, index))
        }
        // No printf spec — insert `-NN` before the extension.
        if let dotIdx = template.lastIndex(of: ".") {
            let prefix = template[..<dotIdx]
            let suffix = template[dotIdx...]
            return "\(prefix)-\(String(format: "%02d", index))"
                + "\(suffix)"
        }
        return "\(template)-\(String(format: "%02d", index))"
    }
}
