// PublicAPILosslessJPEGTests.swift
//
// Pins down that JPEG recompression round-trips through the *public*
// JXLSwift API — `JXLEncoder.encodeLosslessJPEG` (forward) and the new
// `JXLDecoder.decodeLosslessJPEG` (reverse) — via a PLAIN
// `import JXLSwift` (NOT `@testable`). The plain import is the point:
// if either entry point were not `public`, this file would fail to
// compile, so it guards external reachability for downstream consumers
// (e.g. a sibling module like DICOMkit) that link the library product.
//
// The byte-identical reverse algorithm itself is exhaustively covered
// by the `@testable` end-to-end tests in JPEGTests.swift; this file's
// job is the public-surface contract, not the codec internals.

import XCTest
import Foundation
import JXLSwift   // plain import — NOT @testable

final class PublicAPILosslessJPEGTests: XCTestCase {

    /// Forward → reverse JPEG recompression through the public API must
    /// be byte-identical (no generational loss). Mirrors the proven
    /// `@testable` `testEndToEnd_LosslessJPEGContainer_RoundTrip`, but
    /// performs the reverse step with the single public call
    /// `JXLDecoder.decodeLosslessJPEG(_:)`.
    func testPublicAPI_LosslessJPEGRoundTrip_ByteIdentical() throws {
        let cjpeg = "/opt/homebrew/bin/cjpeg"
        guard FileManager.default.isExecutableFile(atPath: cjpeg) else {
            throw XCTSkip("cjpeg required to synthesise a baseline JPEG")
        }

        struct Variant {
            let label: String; let w: Int; let h: Int
            let gray: Bool; let args: [String]
        }
        let variants: [Variant] = [
            .init(label: "24×16 4:4:4", w: 24, h: 16, gray: false,
                  args: ["-sample", "1x1,1x1,1x1"]),
            .init(label: "32×24 4:2:0", w: 32, h: 24, gray: false,
                  args: ["-sample", "2x2,1x1,1x1"]),
            .init(label: "32×32 grayscale", w: 32, h: 32, gray: true,
                  args: []),
        ]

        for v in variants {
            let tmp = NSTemporaryDirectory()
            let srcPath = tmp + "pub-ll-\(UUID().uuidString)."
                + (v.gray ? "pgm" : "ppm")
            let jpgPath = tmp + "pub-ll-\(UUID().uuidString).jpg"
            defer {
                try? FileManager.default.removeItem(atPath: srcPath)
                try? FileManager.default.removeItem(atPath: jpgPath)
            }

            // Synthesise a PNM, convert to a baseline JPEG via cjpeg.
            var ppm = Data(
                "\(v.gray ? "P5" : "P6")\n\(v.w) \(v.h)\n255\n".utf8)
            for i in 0..<(v.w * v.h) {
                if v.gray {
                    ppm.append(UInt8((i * 11 + 3) % 256))
                } else {
                    ppm.append(UInt8((i * 7) % 256))
                    ppm.append(UInt8((i * 5 + 40) % 256))
                    ppm.append(UInt8((i * 3 + 90) % 256))
                }
            }
            try ppm.write(to: URL(fileURLWithPath: srcPath))

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: cjpeg)
            proc.arguments = ["-outfile", jpgPath, "-quality", "80",
                              "-baseline"] + v.args + [srcPath]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try proc.run(); proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw XCTSkip("cjpeg failed for \(v.label)")
            }
            let jpgData = try Data(contentsOf: URL(fileURLWithPath: jpgPath))

            // Forward (public): JPEG → JXL container with a jbrd box.
            let encoded = try JXLEncoder().encodeLosslessJPEG(jpgData)

            // Reverse (public): JXL → JPEG in one call.
            let rebuilt = try JXLDecoder().decodeLosslessJPEG(encoded.data)

            XCTAssertEqual(
                rebuilt, jpgData,
                "\(v.label): public encodeLosslessJPEG → "
                + "decodeLosslessJPEG must be byte-identical")
        }
    }

    /// The public reverse API must FAIL SAFE: a JXL that carries no
    /// `jbrd` reconstruction box (an ordinary lossless image) must
    /// throw a public `DecoderError`, never emit wrong JPEG bytes.
    func testPublicAPI_DecodeLosslessJPEG_NonBridgeInput_Throws() throws {
        var frame = ImageFrame(
            width: 8, height: 8, channels: 3, pixelType: .uint8)
        // A simple gradient so the lossless encode produces a real
        // (non-degenerate) codestream.
        for y in 0..<8 {
            for x in 0..<8 {
                frame.setPixel(x: x, y: y, channel: 0,
                               value: UInt16(x * 16))
                frame.setPixel(x: x, y: y, channel: 1,
                               value: UInt16(y * 16))
                frame.setPixel(x: x, y: y, channel: 2,
                               value: UInt16((x + y) * 8))
            }
        }
        let jxl = try JXLEncoder(options: .lossless).encode(frame)

        XCTAssertThrowsError(
            try JXLDecoder().decodeLosslessJPEG(jxl.data),
            "a JXL with no jbrd box must not reverse-transcode to JPEG"
        ) { error in
            XCTAssertTrue(
                error is DecoderError,
                "should throw a public DecoderError, got \(error)")
        }
    }
}
