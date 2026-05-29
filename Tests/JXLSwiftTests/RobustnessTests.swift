// RobustnessTests — v1.0 milestone 3 (robustness hardening).
//
// Two kinds of coverage the ad-hoc tests left thin:
//
//  1. A PARAMETERISED lossless sweep — dims × depth × channels × content ×
//     effort — round-tripped through encode → JXLDecoder.decode and asserted
//     pixel-exact, with a high-value subset additionally `djxl`-byte-checked.
//     Targets the cells where off-by-one / degenerate bugs hide: 1×1, 1×N,
//     N×1, group-boundary widths, constant / random / sparse content, and the
//     full effort ladder.
//
//  2. A DECODER FUZZ harness — truncated and byte-mutated codestreams fed to
//     the public decode entry point. The contract is graceful degradation: a
//     clean Swift `throw`, never a trap. (A Swift array-OOB / fatalError would
//     kill the test process, so simply reaching the end of the loop proves no
//     trap occurred — the v0.12.0i17 constant-image crash was exactly this
//     class of bug.)

import XCTest
import Foundation
@testable import JXLSwift

final class RobustnessTests: XCTestCase {

    private static let djxl = "/opt/homebrew/bin/djxl"

    private enum Content: CaseIterable { case constant, gradient, random, sparse }

    /// Deterministic per-(dim, salt) seed so the sweep is reproducible.
    private func seed(_ a: Int, _ b: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: (a &* 73856093) ^ (b &* 19349663) ^ 0x9e37_79b9)
    }

    private func channel8(_ w: Int, _ h: Int, _ content: Content, salt: Int) -> [UInt8] {
        let n = w * h
        var out = [UInt8](repeating: 0, count: n)
        var s = seed(n + salt, salt + 7)
        for i in 0..<n {
            switch content {
            case .constant: out[i] = 128
            case .gradient: out[i] = UInt8(((i % w) + (i / w)) & 0xff)
            case .random:   s = s &* 1103515245 &+ 12345; out[i] = UInt8(truncatingIfNeeded: s >> 16)
            case .sparse:   out[i] = (i % 17 == 0) ? 255 : 0
            }
        }
        return out
    }

    private func channel16(_ w: Int, _ h: Int, _ content: Content, salt: Int, maxVal: Int) -> [UInt16] {
        let n = w * h
        var out = [UInt16](repeating: 0, count: n)
        var s = seed(n + salt, salt + 13)
        let mv = UInt32(maxVal)
        for i in 0..<n {
            switch content {
            case .constant: out[i] = UInt16(maxVal / 2)
            case .gradient: out[i] = UInt16(UInt32((i % w) + (i / w)) % (mv + 1))
            case .random:   s = s &* 1103515245 &+ 12345; out[i] = UInt16(s % (mv + 1))
            case .sparse:   out[i] = (i % 17 == 0) ? UInt16(maxVal) : 0
            }
        }
        return out
    }

    // Expected interleaved containers matching ImageFrame.data layout
    // (channel-interleaved; 16-bit little-endian pairs).
    private func interleaved8(_ chans: [[UInt8]], _ w: Int, _ h: Int) -> [UInt8] {
        let c = chans.count
        var out = [UInt8](repeating: 0, count: w * h * c)
        for i in 0..<(w * h) { for k in 0..<c { out[i * c + k] = chans[k][i] } }
        return out
    }

    private func interleaved16(_ chans: [[UInt16]], _ w: Int, _ h: Int) -> [UInt8] {
        let c = chans.count
        var out = [UInt8](repeating: 0, count: w * h * c * 2)
        for i in 0..<(w * h) {
            for k in 0..<c {
                let v = chans[k][i]
                let o = (i * c + k) * 2
                out[o] = UInt8(v & 0xff)
                out[o + 1] = UInt8((v >> 8) & 0xff)
            }
        }
        return out
    }

    private func roundTrip(_ data: Data, expected: [UInt8],
                           w: Int, h: Int, channels: Int, _ label: String) throws {
        let frame = try JXLDecoder().decode(data)
        XCTAssertEqual(frame.width, w, "\(label): width")
        XCTAssertEqual(frame.height, h, "\(label): height")
        XCTAssertEqual(frame.channels, channels, "\(label): channels")
        if frame.data != expected {
            let n = min(frame.data.count, expected.count)
            var firstDiff = -1
            for i in 0..<n where frame.data[i] != expected[i] { firstDiff = i; break }
            XCTFail("\(label): not lossless (data \(frame.data.count)B vs expected \(expected.count)B, first diff at \(firstDiff))")
        }
    }

    // MARK: - 1. Parameterised lossless sweep (round-trip)

    /// Full matrix through encode → our decoder, asserted pixel-exact.
    /// Includes a 12-bit grayscale/RGB case as a regression guard for the
    /// declared-bit-depth output clamp.
    func testRobustness_LosslessSweep_RoundTrip() throws {
        // Degenerate, small, odd, and group-boundary (512/1024) dimensions.
        let dims = [(1, 1), (1, 5), (5, 1), (2, 2), (3, 3), (16, 16),
                    (63, 65), (129, 127), (256, 256), (513, 127)]
        let effort = 3   // fast path; the effort ladder is swept separately
        var cases = 0
        for (w, h) in dims {
            for content in Content.allCases {
                let g = channel8(w, h, content, salt: 1)
                let a = channel8(w, h, content, salt: 2)
                let r = channel8(w, h, content, salt: 3)
                let gg = channel8(w, h, content, salt: 4)
                let b = channel8(w, h, content, salt: 5)
                let al = channel8(w, h, content, salt: 6)
                let tag = "\(w)x\(h)/\(content)"

                try roundTrip(
                    SpecModularEncoder.encodeGrayscale8(width: w, height: h, pixels: g, effort: effort),
                    expected: interleaved8([g], w, h), w: w, h: h, channels: 1, "gray8 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeGrayscaleAlpha8(width: w, height: h, gray: g, alpha: a, effort: effort),
                    expected: interleaved8([g, a], w, h), w: w, h: h, channels: 2, "graya8 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeRGB8(width: w, height: h, r: r, g: gg, b: b, effort: effort),
                    expected: interleaved8([r, gg, b], w, h), w: w, h: h, channels: 3, "rgb8 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeRGBA8(width: w, height: h, r: r, g: gg, b: b, a: al, effort: effort),
                    expected: interleaved8([r, gg, b, al], w, h), w: w, h: h, channels: 4, "rgba8 \(tag)")

                // 16-bit (full range): grayscale, gray+alpha, RGBA.
                let g16 = channel16(w, h, content, salt: 7, maxVal: 65535)
                let a16 = channel16(w, h, content, salt: 8, maxVal: 65535)
                let r16 = channel16(w, h, content, salt: 9, maxVal: 65535)
                let gg16 = channel16(w, h, content, salt: 10, maxVal: 65535)
                let b16 = channel16(w, h, content, salt: 11, maxVal: 65535)
                let al16 = channel16(w, h, content, salt: 12, maxVal: 65535)
                try roundTrip(
                    SpecModularEncoder.encodeGrayscale16(width: w, height: h, pixels: g16, effort: effort),
                    expected: interleaved16([g16], w, h), w: w, h: h, channels: 1, "gray16 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeGrayscaleAlpha16(width: w, height: h, gray: g16, alpha: a16, effort: effort),
                    expected: interleaved16([g16, a16], w, h), w: w, h: h, channels: 2, "graya16 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeRGBA16(width: w, height: h, r: r16, g: gg16, b: b16, a: al16, effort: effort),
                    expected: interleaved16([r16, gg16, b16, al16], w, h), w: w, h: h, channels: 4, "rgba16 \(tag)")

                // 12-bit grayscale + RGB — exercises the declared-bit-depth clamp
                // (values are in-range, so the clamp must be a no-op).
                let g12 = channel16(w, h, content, salt: 13, maxVal: 4095)
                let r12 = channel16(w, h, content, salt: 14, maxVal: 4095)
                let gc12 = channel16(w, h, content, salt: 15, maxVal: 4095)
                let b12 = channel16(w, h, content, salt: 16, maxVal: 4095)
                try roundTrip(
                    SpecModularEncoder.encodeGrayscale16(width: w, height: h, bitsPerSample: 12, pixels: g12, effort: effort),
                    expected: interleaved16([g12], w, h), w: w, h: h, channels: 1, "gray12 \(tag)")
                try roundTrip(
                    SpecModularEncoder.encodeRGB16(width: w, height: h, bitsPerSample: 12, r: r12, g: gc12, b: b12, effort: effort),
                    expected: interleaved16([r12, gc12, b12], w, h), w: w, h: h, channels: 3, "rgb12 \(tag)")

                cases += 10
            }
        }
        print("[sweep] \(cases) lossless round-trip cases passed across \(dims.count) dims × \(Content.allCases.count) content types")
    }

    /// The full effort ladder (1…9) must stay lossless — efforts 2,3,5,6,8 were
    /// never exercised end-to-end before. Fixed mixed-content 16-bit image.
    func testRobustness_EffortLadder_AllLossless() throws {
        let w = 96, h = 70
        let g = channel16(w, h, .random, salt: 21, maxVal: 65535)
        for effort in 1...9 {
            try roundTrip(
                SpecModularEncoder.encodeGrayscale16(width: w, height: h, pixels: g, effort: effort),
                expected: interleaved16([g], w, h), w: w, h: h, channels: 1, "gray16 effort=\(effort)")
        }
        // RGB effort ladder too (RCT + multi-channel tree at every effort).
        let r = channel8(w, h, .gradient, salt: 22)
        let gc = channel8(w, h, .random, salt: 23)
        let b = channel8(w, h, .sparse, salt: 24)
        for effort in 1...9 {
            try roundTrip(
                SpecModularEncoder.encodeRGB8(width: w, height: h, r: r, g: gc, b: b, effort: effort),
                expected: interleaved8([r, gc, b], w, h), w: w, h: h, channels: 3, "rgb8 effort=\(effort)")
        }
    }

    // MARK: - 1b. djxl byte-exact subset (high-value previously-uncovered cells)

    /// Parse a netpbm PGM/PPM/PAM file into interleaved sample values
    /// (big-endian for 16-bit, per the spec).
    private func parsePNMValues(_ url: URL) throws -> (w: Int, h: Int, ch: Int, vals: [Int]) {
        let data = [UInt8](try Data(contentsOf: url))
        guard data.count > 2, data[0] == 0x50 else { throw Err.badPNM }   // 'P'
        let magic = data[1]
        var w = 0, h = 0, depth = 0, maxval = 0, body = 0
        if magic == 0x37 {                                                // P7 / PAM
            let end = Array("ENDHDR\n".utf8)
            var i = 0
            while i + end.count <= data.count {
                if Array(data[i..<(i + end.count)]) == end { body = i + end.count; break }
                i += 1
            }
            let hdr = String(decoding: data[0..<body], as: UTF8.self)
            for line in hdr.split(separator: "\n") {
                let t = line.split(separator: " ")
                guard t.count >= 2 else { continue }
                switch t[0] {
                case "WIDTH":  w = Int(t[1]) ?? 0
                case "HEIGHT": h = Int(t[1]) ?? 0
                case "DEPTH":  depth = Int(t[1]) ?? 0
                case "MAXVAL": maxval = Int(t[1]) ?? 0
                default: break
                }
            }
        } else {                                                          // P5 (gray) / P6 (rgb)
            depth = (magic == 0x36) ? 3 : 1
            var idx = 2, toks: [Int] = []
            while toks.count < 3 {
                while idx < data.count, data[idx] == 0x20 || data[idx] == 0x0a || data[idx] == 0x09 || data[idx] == 0x0d { idx += 1 }
                var s = idx
                while idx < data.count, !(data[idx] == 0x20 || data[idx] == 0x0a || data[idx] == 0x09 || data[idx] == 0x0d) { idx += 1 }
                toks.append(Int(String(decoding: data[s..<idx], as: UTF8.self)) ?? 0)
                _ = s
            }
            w = toks[0]; h = toks[1]; maxval = toks[2]; body = idx + 1
        }
        guard w > 0, h > 0, depth > 0, maxval > 0 else { throw Err.badPNM }
        let count = w * h * depth
        var vals = [Int](repeating: 0, count: count)
        if maxval <= 255 {
            for k in 0..<count { vals[k] = Int(data[body + k]) }
        } else {
            for k in 0..<count { vals[k] = (Int(data[body + 2 * k]) << 8) | Int(data[body + 2 * k + 1]) }
        }
        return (w, h, depth, vals)
    }

    private enum Err: Error { case badPNM, djxlFailed }

    private func djxlMatches(_ encoded: Data, expectedVals: [Int],
                             w: Int, h: Int, channels: Int, ext: String, _ label: String) throws {
        let tmp = NSTemporaryDirectory()
        let inP = tmp + "rob_\(UUID().uuidString).jxl"
        let outP = tmp + "rob_\(UUID().uuidString).\(ext)"
        defer { try? FileManager.default.removeItem(atPath: inP)
                try? FileManager.default.removeItem(atPath: outP) }
        try encoded.write(to: URL(fileURLWithPath: inP))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.djxl)
        p.arguments = [inP, outP]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "\(label): djxl rejected the stream")
        guard p.terminationStatus == 0 else { return }
        let r = try parsePNMValues(URL(fileURLWithPath: outP))
        XCTAssertEqual(r.w, w, "\(label): djxl width")
        XCTAssertEqual(r.h, h, "\(label): djxl height")
        XCTAssertEqual(r.ch, channels, "\(label): djxl channels")
        XCTAssertEqual(r.vals, expectedVals, "\(label): djxl pixel values differ")
    }

    private func vals8(_ chans: [[UInt8]], _ w: Int, _ h: Int) -> [Int] {
        let c = chans.count
        var out = [Int](repeating: 0, count: w * h * c)
        for i in 0..<(w * h) { for k in 0..<c { out[i * c + k] = Int(chans[k][i]) } }
        return out
    }
    private func vals16(_ chans: [[UInt16]], _ w: Int, _ h: Int) -> [Int] {
        let c = chans.count
        var out = [Int](repeating: 0, count: w * h * c)
        for i in 0..<(w * h) { for k in 0..<c { out[i * c + k] = Int(chans[k][i]) } }
        return out
    }

    /// `djxl`-byte-exact on cells the prior suite never covered: tiny/degenerate
    /// gray+alpha, constant RGBA8 at a group boundary, random gray16 crossing
    /// the 512px boundary, and random RGBA16.
    func testRobustness_DjxlSubset_PreviouslyUncovered() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.djxl) else {
            throw XCTSkip("djxl not available; djxl subset skipped")
        }
        // (a) gray+alpha8 degenerate 1×7  → PAM (2 channels)
        do {
            let (w, h) = (1, 7)
            let g = channel8(w, h, .random, salt: 31), a = channel8(w, h, .gradient, salt: 32)
            try djxlMatches(
                SpecModularEncoder.encodeGrayscaleAlpha8(width: w, height: h, gray: g, alpha: a),
                expectedVals: vals8([g, a], w, h), w: w, h: h, channels: 2, ext: "pam", "graya8 1x7")
        }
        // (b) constant RGBA8 at the 513px group boundary → PAM (4 channels)
        do {
            let (w, h) = (513, 3)
            let r = channel8(w, h, .constant, salt: 33), g = channel8(w, h, .constant, salt: 34)
            let b = channel8(w, h, .constant, salt: 35), a = channel8(w, h, .constant, salt: 36)
            try djxlMatches(
                SpecModularEncoder.encodeRGBA8(width: w, height: h, r: r, g: g, b: b, a: a),
                expectedVals: vals8([r, g, b, a], w, h), w: w, h: h, channels: 4, ext: "pam", "rgba8 const 513x3")
        }
        // (c) random gray16 crossing the 512px boundary → PGM 16-bit
        do {
            let (w, h) = (520, 5)
            let g = channel16(w, h, .random, salt: 37, maxVal: 65535)
            try djxlMatches(
                SpecModularEncoder.encodeGrayscale16(width: w, height: h, pixels: g),
                expectedVals: vals16([g], w, h), w: w, h: h, channels: 1, ext: "pgm", "gray16 rand 520x5")
        }
        // (d) random RGBA16 32×32 → PAM 16-bit (worst-case histogram + RCT + alpha)
        do {
            let (w, h) = (32, 32)
            let r = channel16(w, h, .random, salt: 38, maxVal: 65535)
            let g = channel16(w, h, .random, salt: 39, maxVal: 65535)
            let b = channel16(w, h, .random, salt: 40, maxVal: 65535)
            let a = channel16(w, h, .random, salt: 41, maxVal: 65535)
            try djxlMatches(
                SpecModularEncoder.encodeRGBA16(width: w, height: h, r: r, g: g, b: b, a: a),
                expectedVals: vals16([r, g, b, a], w, h), w: w, h: h, channels: 4, ext: "pam", "rgba16 rand 32x32")
        }
    }

    // MARK: - 2. Decoder fuzz (graceful degradation: throw, never trap)

    /// Feed truncated and byte-mutated codestreams to the decoder; the only
    /// contract is that it never traps. Reaching the assertion at the end is
    /// itself the proof (a Swift trap would have killed the process).
    private func fuzzSeed(_ valid: Data, label: String) {
        let bytes = [UInt8](valid)
        guard bytes.count > 8 else { XCTFail("\(label): seed too small"); return }
        let dec = JXLDecoder()
        var threw = 0, ok = 0

        // (1) Truncation at ~100 evenly-spaced lengths.
        var L = 1
        let step = max(1, bytes.count / 100)
        while L < bytes.count {
            do { _ = try dec.decode(Data(bytes[0..<L])); ok += 1 }
            catch { threw += 1 }
            L += step
        }
        // (2) Single-byte replacement at ~500 deterministic positions/values.
        var rs: UInt32 = seed(bytes.count, 0x5eed)
        for _ in 0..<500 {
            rs = rs &* 1103515245 &+ 12345
            let pos = Int(rs % UInt32(bytes.count))
            rs = rs &* 1103515245 &+ 12345
            var m = bytes
            m[pos] = UInt8(truncatingIfNeeded: rs >> 9)
            do { _ = try dec.decode(Data(m)); ok += 1 }
            catch { threw += 1 }
        }
        XCTAssertGreaterThan(threw, 0, "\(label): expected some malformed inputs to be rejected")
        print("[fuzz] \(label): \(threw) rejected, \(ok) decoded — no traps across \(threw + ok) mutations")
    }

    func testRobustness_DecoderFuzz_NoTrap() throws {
        let w = 28, h = 22
        // Three seed codestreams exercising distinct decode paths.
        let g8 = channel8(w, h, .random, salt: 51)
        try fuzzSeedThrowing(SpecModularEncoder.encodeGrayscale8(width: w, height: h, pixels: g8, effort: 5), "gray8")

        let r = channel8(w, h, .random, salt: 52), gg = channel8(w, h, .gradient, salt: 53)
        let b = channel8(w, h, .sparse, salt: 54), a = channel8(w, h, .random, salt: 55)
        try fuzzSeedThrowing(SpecModularEncoder.encodeRGBA8(width: w, height: h, r: r, g: gg, b: b, a: a, effort: 5), "rgba8")

        let g16 = channel16(w, h, .random, salt: 56, maxVal: 65535)
        try fuzzSeedThrowing(SpecModularEncoder.encodeGrayscale16(width: w, height: h, pixels: g16, effort: 5), "gray16")
    }

    private func fuzzSeedThrowing(_ valid: @autoclosure () throws -> Data, _ label: String) throws {
        fuzzSeed(try valid(), label: label)
    }
}
