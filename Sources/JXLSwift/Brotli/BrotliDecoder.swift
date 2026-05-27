// `Brotli/BrotliDecoder.swift` — top-level Brotli decoder shell.
//
// Orchestrates the stream:
//   read WBITS → loop reading meta-block headers → dispatch
//   per-meta-block body (uncompressed copy / empty / compressed
//   entropy decode + LZ77) → accumulate output.
//
// Status (v0.12.0ga):
//   ✅ WBITS + meta-block header (v0.12.0fz)
//   ✅ Uncompressed meta-block body (this commit)
//   ✅ Empty meta-block / skip-length pass-through
//   ⏳ Compressed meta-block body — pending NBLTYPES + NPOSTFIX +
//      NDIRECT + context maps + literal/insert+copy/distance
//      alphabets + static dictionary + LZ77 reconstruction.

import Foundation

/// Top-level decoder API.
public enum BrotliDecoder {

    /// Decode a complete Brotli stream into uncompressed bytes.
    ///
    /// - Parameter input: the raw Brotli-compressed bytes.
    /// - Parameter expectedOutputSize: optional capacity hint for
    ///   the output buffer; ignored if nil. Useful when the caller
    ///   knows the size from a containing format (e.g. `jbrd` box
    ///   payload sizing).
    /// - Returns: the fully decompressed output bytes.
    /// - Throws: a `BrotliError` describing the failure (bitstream
    ///   wrap, malformed code, not-implemented path, etc.).
    public static func decode(
        _ input: Data, expectedOutputSize: Int? = nil
    ) throws -> Data {
        var r = BitReader(input)
        return try decode(reader: &r,
            expectedOutputSize: expectedOutputSize)
    }

    /// Decode from a `BitReader` (caller-supplied). Used by the
    /// jbrd-driven reverse bridge to consume the trailing Brotli
    /// payload from the same reader the Bundle was read from.
    /// The bit reader must be byte-aligned at the start of the
    /// Brotli stream.
    public static func decode(
        reader r: inout BitReader,
        expectedOutputSize: Int? = nil
    ) throws -> Data {
        var output = Data()
        if let n = expectedOutputSize {
            output.reserveCapacity(n)
        }
        // 1. Stream header — WBITS.
        let header = try BrotliMetaBlockReader.readStreamHeader(
            from: &r)
        _ = header   // window size doesn't affect correctness for
                     // the small-payload case we handle here

        // 2. Meta-block loop.
        var isFirst = true
        while true {
            let mh = try BrotliMetaBlockReader.readMetaBlockHeader(
                from: &r)
            if mh.isLastEmpty {
                // Empty terminator meta-block.
                if !mh.isLast {
                    throw BrotliError.invalidMetaBlockLength(
                        "ISLAST_EMPTY without ISLAST set")
                }
                break
            }
            if mh.isUncompressed && mnibblesIsSkipBranch(&r,
                isFirst: isFirst, lastMNIBBLES: mh)
            {
                // The MNIBBLES=3 branch — read mskipLen bytes
                // verbatim into output. The header reader already
                // surfaced `payloadSize = mskipLen + 1`.
                try align(&r)
                try copyBytes(
                    count: mh.payloadSize, from: &r, to: &output)
                if mh.isLast { break }
                continue
            }
            if mh.isUncompressed {
                // Normal uncompressed meta-block.
                // Byte-align before reading payload.
                try align(&r)
                try copyBytes(
                    count: mh.payloadSize, from: &r, to: &output)
                if mh.isLast { break }
            } else {
                // Compressed meta-block.
                throw BrotliError.notImplemented(
                    "compressed meta-block body — NBLTYPES + "
                    + "NPOSTFIX + NDIRECT + context maps + L/I/D "
                    + "alphabets + LZ77 (RFC 7932 §9.2 / §7 / §8) "
                    + "is the next bite")
            }
            isFirst = false
        }
        return output
    }

    /// Heuristic: the MNIBBLES=3 (binary 11) branch in the header
    /// reader sets `isUncompressed=true` and `payloadSize=mskipLen+1`.
    /// We can't actually distinguish that here from a normal
    /// uncompressed meta-block without re-walking the bit stream —
    /// for our use case the distinction doesn't matter (both paths
    /// produce a byte-aligned uncompressed run). Stub returns false
    /// for now; this dispatch is here to document the structural
    /// branch for future maintainers.
    @inline(__always)
    private static func mnibblesIsSkipBranch(
        _ r: inout BitReader, isFirst: Bool, lastMNIBBLES mh: Any
    ) -> Bool {
        return false
    }

    /// Align the bit reader to the next byte boundary by discarding
    /// up to 7 padding bits. Brotli requires these bits to be zero
    /// per RFC 7932 §9.2; we don't enforce that here (lenient).
    @inline(__always)
    private static func align(_ r: inout BitReader) throws {
        let bitsToSkip = (8 - (r.position & 7)) & 7
        if bitsToSkip > 0 {
            do { _ = try r.read(bits: bitsToSkip) }
            catch let e as BitstreamError {
                throw BrotliError.bitstream(e)
            }
        }
    }

    /// Copy `count` bytes from a byte-aligned `BitReader` to
    /// `output`. The reader must be byte-aligned at entry.
    private static func copyBytes(
        count: Int, from r: inout BitReader, to output: inout Data
    ) throws {
        guard count >= 0 else {
            throw BrotliError.invalidMetaBlockLength(
                "negative byte count")
        }
        guard r.position & 7 == 0 else {
            throw BrotliError.invalidMetaBlockLength(
                "copyBytes called with unaligned reader "
                + "(pos=\(r.position))")
        }
        let bytesAvailable = r.data.count - (r.position / 8)
        guard count <= bytesAvailable else {
            throw BrotliError.bitstream(
                .outOfBounds(needed: count * 8,
                    remaining: bytesAvailable * 8))
        }
        let startByte = r.data.startIndex + (r.position / 8)
        output.append(r.data[
            startByte..<(startByte + count)])
        // Advance the bit reader.
        do {
            try r.skip(bits: count * 8)
        } catch let e as BitstreamError {
            throw BrotliError.bitstream(e)
        }
    }
}
