// `Brotli/BrotliBitReader.swift` — Brotli-specific helpers layered
// on top of the shared `BitReader`. Brotli and JXL both pack bits
// LSB-first within each byte (RFC 7932 §1.1 vs JXL §2.4), so the
// underlying bit primitive is the same; this file adds the integer-
// encoding helpers Brotli leans on heavily.
//
// Phase J step 5 (reverse direction). v0.12.0fz scaffold.

import Foundation

/// Brotli read helpers. Wraps `BitReader` so the call sites read
/// like the RFC instead of like bit-twiddling. Each helper cites
/// the RFC section that defines the encoding.
package enum BrotliBitReader {

    /// RFC 7932 §9.2 — variable-length unsigned integer for fields
    /// like NBLTYPESL / NBLTYPESI / NBLTYPESD. The encoded value `N`
    /// is in `[1, 256]`.
    ///
    /// Encoding:
    /// ```
    /// 0           → 1
    /// 1 nnn xxxxxxx  → where nnn ∈ {0..7}, xxxxxxx ∈ {0..(2^nnn-1)},
    ///                  value = 2^nnn + 1 + xxxxxxx
    /// ```
    ///
    /// Concretely:
    /// ```
    /// 1 000        → 2          (no extra bits)
    /// 1 001 x      → 3..4
    /// 1 010 xx     → 5..8
    /// 1 011 xxx    → 9..16
    /// 1 100 xxxx   → 17..32
    /// 1 101 xxxxx  → 33..64
    /// 1 110 xxxxxx → 65..128
    /// 1 111 xxxxxxx → 129..256
    /// ```
    ///
    /// Returns the decoded value (1..256).
    package static func readVarLenU8(
        from r: inout BitReader
    ) throws -> UInt32 {
        let firstBit: UInt32
        do { firstBit = try r.read(bits: 1) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        if firstBit == 0 {
            return 1
        }
        let nnn: UInt32
        do { nnn = try r.read(bits: 3) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        let extra: UInt32
        if nnn == 0 {
            extra = 0
        } else {
            do { extra = try r.read(bits: Int(nnn)) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
        }
        return (UInt32(1) << nnn) + 1 + extra
    }

    /// RFC 7932 §9.2 — `MNIBBLES = 4 + read(2)` except the reserved
    /// value 11 (binary), which signals an empty meta-block followed
    /// by a 1-byte uncompressed payload (the "MSKIPLEN" branch).
    ///
    /// Returns the *decoded* MNIBBLES value (4, 5, or 6), or throws
    /// `reservedMNibbles` for the 11-binary reserved value.
    package static func readMNibbles(
        from r: inout BitReader
    ) throws -> Int {
        let v: UInt32
        do { v = try r.read(bits: 2) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
        switch v {
        case 0: return 4
        case 1: return 5
        case 2: return 6
        case 3: throw BrotliError.reservedMNibbles
        default: throw BrotliError.malformedValue
        }
    }

    /// Read a Brotli variable-length integer encoded as `nbits` of
    /// raw bits, returning a UInt32. Convenience wrapper that
    /// converts the underlying `BitstreamError` to `BrotliError`.
    package static func read(
        bits n: Int, from r: inout BitReader
    ) throws -> UInt32 {
        do { return try r.read(bits: n) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
    }

    /// Read one bit, returning as Bool.
    package static func readBit(
        from r: inout BitReader
    ) throws -> Bool {
        do { return try r.readBit() }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
    }
}

/// Internal helper — extends `BrotliError` with a dummy variant for
/// the impossible-but-compiler-needs-it switch case above.
extension BrotliError {
    fileprivate static var malformedValue: BrotliError {
        .invalidMetaBlockLength("internal: switch exhaustive guard")
    }
}
