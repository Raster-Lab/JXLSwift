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
public enum BrotliBitReader {

    /// RFC 7932 §10 — "variable length codes": encode a value `N` as
    ///
    ///     value = 1, 0–4 extra bits ⇒ `N = 1 + extra`
    ///
    /// followed by `1 << (1 + nbits)` to `(1 << (2 + nbits)) - 1`
    /// blocks. Used heavily for `NSYM` / `NBLTYPES` / `NTREES` / etc.
    ///
    /// The exact decoding table (RFC 7932 §10):
    /// ```
    /// prefix  extra  value range
    /// 0       —      1
    /// 1 0xx   3      2..9     ⇒ 2 + xxx
    /// 1 1xx   3      9..16    ⇒ 9 + xxx
    /// ```
    /// Actually the RFC's encoding is simpler — see
    /// `readVarLenU8` for the §9.2 MNIBBLES-style 4-symbol case.
    ///
    /// **Not yet implemented**. Surface as `notImplemented` until
    /// the meta-block reader needs this.
    public static func readNSYM(
        from r: inout BitReader
    ) throws -> UInt32 {
        throw BrotliError.notImplemented("readNSYM (RFC 7932 §10)")
    }

    /// RFC 7932 §9.2 — `MNIBBLES = 4 + read(2)` except the reserved
    /// value 11 (binary), which signals an empty meta-block followed
    /// by a 1-byte uncompressed payload (the "MSKIPLEN" branch).
    ///
    /// Returns the *decoded* MNIBBLES value (4, 5, or 6), or throws
    /// `reservedMNibbles` for the 11-binary reserved value.
    public static func readMNibbles(
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
    public static func read(
        bits n: Int, from r: inout BitReader
    ) throws -> UInt32 {
        do { return try r.read(bits: n) }
        catch let e as BitstreamError { throw BrotliError.bitstream(e) }
    }

    /// Read one bit, returning as Bool.
    public static func readBit(
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
