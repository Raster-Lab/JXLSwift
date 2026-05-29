// `jxl-tool convert` — image-format conversion front-end.
//
// The family-parity counterpart to J2KSwift's `convert` (see
// Documentation/FAMILY-API-PARITY.md). Reads any supported input format and
// writes any supported output format, inferring both from the file
// extensions:
//
//   • input  : `.jxl` → JXLDecoder; `.jpg`/`.jpeg` (or JPEG magic) →
//              JPEGDecoder; otherwise a netpbm PNM (`.pgm`/`.ppm`/`.pam`).
//   • output : `.jxl` → JXLEncoder (lossless Modular by default — the
//              lossless-first focus; pass `--no-lossless --quality N` for the
//              preview lossy VarDCT path); otherwise a PNM.
//
// It composes only existing public API (PNM ↔ ImageFrame ↔ JXL), so it adds no
// new codec surface — just the convenience verb the family CLI expects.

import ArgumentParser
import Foundation
import JXLSwift

struct Convert: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Convert between image formats (PNM ↔ JPEG XL, JPEG → "
            + "PNM/JXL); formats are inferred from the file extensions."
    )

    @Option(name: .shortAndLong, help: "Input image path (.jxl / .jpg / .pgm / .ppm / .pam)")
    var input: String

    @Option(name: .shortAndLong, help: "Output image path (.jxl / .pgm / .ppm / .pam)")
    var output: String

    @Flag(name: .shortAndLong, inversion: .prefixedNo,
          help: "When encoding to .jxl, use lossless Modular. Default: on.")
    var lossless: Bool = true

    @Option(name: .shortAndLong, help: "Quality 0–100 when encoding lossy to .jxl (with --no-lossless).")
    var quality: Float = 90

    @Option(name: .shortAndLong, help: "Effort 1–9 when encoding to .jxl.")
    var effort: Int = 7

    func run() throws {
        let inURL = URL(fileURLWithPath: input)
        let outURL = URL(fileURLWithPath: output)

        let inData: Data
        do { inData = try Data(contentsOf: inURL) }
        catch {
            print("error reading \(input): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        // 1. Decode the input to an ImageFrame.
        let frame = try readFrame(inData, ext: inURL.pathExtension.lowercased())

        // 2. Encode the frame to the requested output format.
        let outExt = outURL.pathExtension.lowercased()
        let outData: Data
        let summary: String
        if outExt == "jxl" {
            let mode: CompressionMode = lossless
                ? .lossless
                : .lossy(quality: max(0, min(quality, 100)))
            let effortLevel = EncodingEffort(rawValue: max(1, min(effort, 9))) ?? .squirrel
            do {
                let result = try JXLEncoder(options: EncodingOptions(
                    mode: mode, effort: effortLevel)).encode(frame)
                outData = result.data
            } catch {
                print("encode error: \(error)", to: &standardError)
                throw JXLExitCode.generalError
            }
            summary = lossless ? "lossless JXL" : "lossy JXL q=\(Int(quality))"
        } else {
            // Any non-.jxl extension → PNM (PNM.write picks PGM/PPM/PAM).
            do { outData = try PNM.write(frame) }
            catch let e as PNMError {
                print("PNM write error: \(e)", to: &standardError)
                throw JXLExitCode.generalError
            }
            summary = "PNM"
        }

        do { try outData.write(to: outURL) }
        catch {
            print("error writing \(output): \(error)", to: &standardError)
            throw JXLExitCode.generalError
        }

        print(
            "converted \(frame.width)×\(frame.height) "
            + "\(channelDescription(frame.channels)) "
            + "\(frame.pixelType.bitsPerSample)-bit → \(summary): "
            + "\(formatBytes(inData.count)) → \(formatBytes(outData.count))"
        )
    }

    private func readFrame(_ data: Data, ext: String) throws -> ImageFrame {
        if ext == "jxl" {
            do { return try JXLDecoder().decode(data) }
            catch {
                print("decode error: \(error)", to: &standardError)
                throw JXLExitCode.generalError
            }
        }
        if ext == "jpg" || ext == "jpeg" || JPEGSegmentReader.looksLikeJPEG(data) {
            do { return try JPEGDecoder.decode(data) }
            catch {
                print("JPEG decode error: \(error)", to: &standardError)
                throw JXLExitCode.generalError
            }
        }
        do { return try PNM.read(data) }
        catch let e as PNMError {
            print("PNM read error: \(e)", to: &standardError)
            throw JXLExitCode.generalError
        }
    }
}
