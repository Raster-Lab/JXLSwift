// `Brotli/BrotliEncoder.swift` — minimal Brotli *encoder*.
//
// We don't (yet) implement a full entropy-coding Brotli encoder. The
// forward `jbrd` builder only needs to *store* the marker / tail
// payload in a valid Brotli stream so a decoder (ours or libjxl's
// `djxl`) can recover it byte-for-byte. RFC 7932 §9.2's **uncompressed
// meta-block** does exactly that: raw bytes, no entropy coding. The
// output is larger than a real Brotli encoder's, but it is fully
// spec-compliant and round-trips through every conforming decoder.
//
// A real (entropy-coding) Brotli encoder is a future file-size bite;
// correctness does not depend on it.

import Foundation

/// Minimal Brotli encoder — uncompressed meta-blocks only.
public enum BrotliEncoder {

    /// Encode `data` as a valid Brotli stream consisting of a single
    /// uncompressed meta-block (RFC 7932 §9.2) followed by the
    /// empty last meta-block terminator. Decodes back to `data`
    /// byte-for-byte.
    ///
    /// `data` must be ≤ 2^24 bytes (one meta-block's `MLEN` ceiling);
    /// jbrd payloads are capped well below that (≈ 4 MB), so a single
    /// block always suffices.
    public static func encodeUncompressed(_ data: Data) -> Data {
        var w = BitWriter()
        // Stream header: WBITS = 16 (a single 0 bit).
        w.writeBit(false)

        let n = data.count
        precondition(n <= (1 << 24),
            "BrotliEncoder.encodeUncompressed: \(n) bytes exceeds the "
            + "single-meta-block 2^24 ceiling")
        if n > 0 {
            // One uncompressed meta-block (ISLAST = 0).
            w.writeBit(false)                       // ISLAST = 0
            let mlen = UInt32(n - 1)                // MLEN = length − 1
            // Minimal MNIBBLES (4/5/6) that represents MLEN. For
            // MNIBBLES > 4 the top nibble of MLEN must be non-zero —
            // which holds by construction (we only step up once MLEN
            // overflows the smaller width).
            let mnibbles: Int
            if mlen < (1 << 16) { mnibbles = 4 }
            else if mlen < (1 << 20) { mnibbles = 5 }
            else { mnibbles = 6 }
            w.write(bits: 2, value: UInt32(mnibbles - 4))  // MNIBBLES
            w.write(bits: mnibbles * 4, value: mlen)       // MLEN
            w.writeBit(true)                               // ISUNCOMPRESSED
            // Raw bytes are byte-aligned (RFC 7932 §9.2).
            w.alignToByte()
            w.appendBytes(data)
        }
        // Empty last meta-block: ISLAST = 1, ISLAST_EMPTY = 1.
        w.writeBit(true)
        w.writeBit(true)
        w.alignToByte()
        return w.finishToData()
    }
}
