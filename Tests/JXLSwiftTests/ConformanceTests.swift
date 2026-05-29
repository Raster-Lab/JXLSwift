// ConformanceTests — the lossless conformance gate (Phase C / v1.0 milestone 1).
//
// Wires the official JPEG XL conformance vectors
// (https://github.com/libjxl/conformance) into the test suite. For each
// LOSSLESS vector we decode `input.jxl` with JXLSwift's pure-Swift decoder and
// compare the reconstructed pixels against the libjxl reference decoder `djxl`.
// The repo's correctness invariant is byte-agreement with `djxl` (see
// CLAUDE.md), so `djxl` — not the frozen reference_image.npy, which would pull
// in NumPy + lcms2 — is the pixel oracle here.
//
// **Where the vectors come from.** A tiny lossless subset (lz77_flower,
// alpha_triangles) is committed under `Tests/Fixtures/conformance/` so the
// gate runs green by default (see that directory's CREDITS.md for licensing).
// Point `JXL_CONFORMANCE_DIR` at a local checkout of the full corpus
// (`<name>/input.jxl` sub-dirs; see `scripts/fetch-conformance.sh`) to run the
// gate against everything.
//
// **Two tests:**
//   • `testConformance_LosslessVectors_MatchDjxl` — the GATE: every
//     `.pixelMatch` vector present must decode and match `djxl` exactly.
//   • `testConformance_KnownGaps_DegradeGracefully` — the GAP INVENTORY:
//     vectors that need a not-yet-implemented decode feature (Squeeze,
//     delta-Palette, Float32, Patches, EXIF orientation, …) must degrade
//     gracefully — a clean Swift `throw`, never a trap/crash. Documents the
//     v0.14.0+ decoder work surfaced by the corpus.
//
// Both skip cleanly when `djxl` is absent.

import XCTest
import Foundation
@testable import JXLSwift

final class ConformanceTests: XCTestCase {

    private static let djxlPath = "/opt/homebrew/bin/djxl"

    /// Expected behaviour of our decoder on a given conformance vector.
    private enum Expect {
        /// Lossless: our pixels must equal `djxl`'s exactly.
        case pixelMatch
        /// Needs a decode feature we don't implement yet; must throw cleanly.
        case featureGap(String)
        /// Lossy VarDCT vector — out of lossless-1.0 scope (preview decoder).
        case lossyPreview(String)
    }

    private struct Vector {
        let name: String
        let expect: Expect
    }

    /// Classification derived from a full triage of the lossless / near-lossless
    /// corpus against `djxl` (v0.12.0 + the bit-depth output-clamp fix).
    private static let vectors: [Vector] = [
        .init(name: "lz77_flower", expect: .pixelMatch),       // RGB8 Modular + LZ77
        .init(name: "alpha_triangles", expect: .pixelMatch),   // 9-bit RGBA; needs output clamp to declared depth
        .init(name: "grayscale_public_university", expect: .featureGap("Squeeze transform")),
        .init(name: "bicycles", expect: .featureGap("Squeeze transform")),
        .init(name: "delta_palette", expect: .featureGap("delta Palette")),
        .init(name: "lossless_pfm", expect: .featureGap("Float32 samples")),
        .init(name: "patches_lossless", expect: .featureGap("Patches + VarDCT composite")),
        .init(name: "spot", expect: .featureGap("SpotColor extra channels + VarDCT")),
        .init(name: "cmyk_layers", expect: .featureGap("CMYK + multi-layer blending")),
        .init(name: "sunset_logo", expect: .featureGap("EXIF orientation")),
        .init(name: "upsampling", expect: .featureGap("frame upsampling (VarDCT)")),
        .init(name: "opsin_inverse", expect: .lossyPreview("multi-pass progressive VarDCT")),
    ]

    // MARK: - Vector location

    /// Directory holding `<name>/input.jxl` sub-dirs. `JXL_CONFORMANCE_DIR`
    /// (full corpus) takes precedence; otherwise the committed fixture subset.
    private func vectorRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["JXL_CONFORMANCE_DIR"],
           !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        // <repo>/Tests/JXLSwiftTests/ConformanceTests.swift → <repo>/Tests/Fixtures/conformance
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent()   // JXLSwiftTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
        return repoRoot
            .appendingPathComponent("Tests/Fixtures/conformance", isDirectory: true)
    }

    private func inputURL(_ name: String) -> URL? {
        let u = vectorRoot()
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("input.jxl")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func requireDjxl() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.djxlPath) else {
            throw XCTSkip("djxl not available at \(Self.djxlPath); conformance gate skipped")
        }
    }

    // MARK: - djxl oracle (PAM parsing)

    private struct Raster: Equatable {
        let width: Int
        let height: Int
        let channels: Int
        /// One logical sample value per (pixel × channel), row-major,
        /// channel-interleaved. 8- or up-to-16-bit; stored widened to Int.
        let samples: [Int]
    }

    /// Decode `input.jxl` with `djxl` into a PAM and parse it to a `Raster`.
    private func djxlRaster(_ input: URL) throws -> Raster {
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conf-\(UUID().uuidString).pam")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.djxlPath)
        p.arguments = [input.path, out.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ConfError.djxlFailed(Int(p.terminationStatus))
        }
        let data = try Data(contentsOf: out)
        return try Self.parsePAM(data)
    }

    private enum ConfError: Error { case djxlFailed(Int); case badPAM(String) }

    /// Minimal P7/PAM parser: header lines until `ENDHDR`, then raw samples
    /// (1 byte if MAXVAL ≤ 255, else 2 bytes big-endian, per the netpbm spec).
    private static func parsePAM(_ data: Data) throws -> Raster {
        guard data.count > 3, data[0] == 0x50, data[1] == 0x37 else {  // "P7"
            throw ConfError.badPAM("not a P7/PAM stream")
        }
        let endMarker = Array("ENDHDR\n".utf8)
        var headerEnd = -1
        let bytes = [UInt8](data)
        var i = 0
        while i + endMarker.count <= bytes.count {
            if Array(bytes[i..<(i + endMarker.count)]) == endMarker {
                headerEnd = i + endMarker.count
                break
            }
            i += 1
        }
        guard headerEnd > 0 else { throw ConfError.badPAM("no ENDHDR") }
        let header = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var w = 0, h = 0, depth = 0, maxval = 0
        for line in header.split(separator: "\n") {
            let tok = line.split(separator: " ")
            guard tok.count >= 2 else { continue }
            switch tok[0] {
            case "WIDTH":  w = Int(tok[1]) ?? 0
            case "HEIGHT": h = Int(tok[1]) ?? 0
            case "DEPTH":  depth = Int(tok[1]) ?? 0
            case "MAXVAL": maxval = Int(tok[1]) ?? 0
            default: break
            }
        }
        guard w > 0, h > 0, depth > 0, maxval > 0 else {
            throw ConfError.badPAM("missing WIDTH/HEIGHT/DEPTH/MAXVAL")
        }
        let count = w * h * depth
        var samples = [Int](repeating: 0, count: count)
        let body = headerEnd
        if maxval <= 255 {
            guard bytes.count - body >= count else { throw ConfError.badPAM("short body") }
            for k in 0..<count { samples[k] = Int(bytes[body + k]) }
        } else {
            guard bytes.count - body >= count * 2 else { throw ConfError.badPAM("short body") }
            for k in 0..<count {
                samples[k] = (Int(bytes[body + 2 * k]) << 8) | Int(bytes[body + 2 * k + 1])
            }
        }
        return Raster(width: w, height: h, channels: depth, samples: samples)
    }

    /// Convert a decoded `ImageFrame` to a `Raster` of logical sample values.
    /// (`ImageFrame` stores 16-bit samples little-endian; PAM is big-endian —
    /// we compare the decoded *values*, not the container byte order.)
    private func frameRaster(_ f: ImageFrame) -> Raster {
        let count = f.width * f.height * f.channels
        var samples = [Int](repeating: 0, count: count)
        if f.pixelType.bytesPerSample == 1 {
            for k in 0..<count { samples[k] = Int(f.data[k]) }
        } else {
            for k in 0..<count {
                samples[k] = Int(f.data[2 * k]) | (Int(f.data[2 * k + 1]) << 8)
            }
        }
        return Raster(width: f.width, height: f.height,
                      channels: f.channels, samples: samples)
    }

    // MARK: - The gate

    /// Every `.pixelMatch` vector present must decode and equal `djxl` exactly.
    func testConformance_LosslessVectors_MatchDjxl() throws {
        try requireDjxl()
        var checked = 0
        for v in Self.vectors {
            guard case .pixelMatch = v.expect else { continue }
            guard let input = inputURL(v.name) else { continue }  // not present locally
            let jxlData = try Data(contentsOf: input)
            let frame = try JXLDecoder().decode(jxlData)
            let ours = frameRaster(frame)
            let ref = try djxlRaster(input)
            XCTAssertEqual(ours.width, ref.width, "\(v.name): width")
            XCTAssertEqual(ours.height, ref.height, "\(v.name): height")
            XCTAssertEqual(ours.channels, ref.channels, "\(v.name): channels")
            XCTAssertEqual(ours.samples.count, ref.samples.count, "\(v.name): sample count")
            if ours.samples != ref.samples {
                let diffs = zip(ours.samples, ref.samples).filter { $0 != $1 }.count
                let maxd = zip(ours.samples, ref.samples).map { abs($0 - $1) }.max() ?? 0
                XCTFail("\(v.name): \(diffs)/\(ours.samples.count) samples differ from djxl (maxAbsDiff=\(maxd))")
            } else {
                print("[conformance] \(v.name): ✓ \(ref.width)×\(ref.height)×\(ref.channels) byte-exact to djxl")
            }
            checked += 1
        }
        if checked == 0 {
            throw XCTSkip("no .pixelMatch conformance vectors present (set JXL_CONFORMANCE_DIR or check Tests/Fixtures)")
        }
    }

    /// Vectors that need a not-yet-implemented decode feature must degrade
    /// gracefully: a clean Swift `throw`, never a trap/crash. (Reaching the
    /// post-decode assertion at all proves no trap occurred — a Swift fatal
    /// error / array-OOB would have killed the test process.)
    func testConformance_KnownGaps_DegradeGracefully() throws {
        try requireDjxl()
        var checked = 0
        for v in Self.vectors {
            let gapReason: String
            switch v.expect {
            case .pixelMatch: continue
            case .featureGap(let r): gapReason = "feature-gap: \(r)"
            case .lossyPreview(let r): gapReason = "lossy-preview: \(r)"
            }
            guard let input = inputURL(v.name) else { continue }
            let jxlData = try Data(contentsOf: input)
            do {
                let frame = try JXLDecoder().decode(jxlData)
                // It decoded without throwing. That is acceptable as long as it
                // didn't trap; record whether it happens to match djxl (which
                // would mean the gap has silently closed and should be promoted).
                let ours = frameRaster(frame)
                if let ref = try? djxlRaster(input), ours == ref {
                    print("[conformance] \(v.name): ⚠︎ \(gapReason) — but now MATCHES djxl; promote to .pixelMatch")
                } else {
                    print("[conformance] \(v.name): ○ \(gapReason) — decoded (diverges from djxl, as expected)")
                }
            } catch {
                print("[conformance] \(v.name): ○ \(gapReason) — clean throw: \(error)")
            }
            checked += 1
        }
        if checked == 0 {
            throw XCTSkip("no known-gap conformance vectors present (set JXL_CONFORMANCE_DIR)")
        }
    }
}
