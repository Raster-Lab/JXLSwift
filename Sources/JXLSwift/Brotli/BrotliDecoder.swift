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
                try decodeCompressedBody(
                    targetSize: mh.payloadSize,
                    from: &r, to: &output)
                if mh.isLast { break }
            }
            isFirst = false
        }
        return output
    }

    /// Decode one compressed meta-block body. Reads the body header
    /// (NBLTYPES/NPOSTFIX/NDIRECT/context-modes/NTREES), three prefix
    /// codes (literal/IC/distance), and runs the LZ77 reconstruction
    /// loop until `payloadSize` bytes have been emitted.
    ///
    /// **Restrictions (v0.12.0gn).**
    /// - NBLTYPESL/I/D = 1 (single block type per stream).
    /// - NTREESL = NTREESD = 1 (no context map; same prefix code used
    ///   for every literal / distance regardless of context).
    /// - Static dictionary references (distance > output position +
    ///   max-distance) are not supported — they throw `notImplemented`.
    /// - Multi-block-type streams (NBLTYPES > 1) throw `notImplemented`
    ///   because the block-length walker is not yet integrated.
    private static func decodeCompressedBody(
        targetSize: Int,
        from r: inout BitReader,
        to output: inout Data
    ) throws {
        // 1. Body header.
        let body = try BrotliCompressedMetaBlockHeader.read(
            from: &r)
        if body.literal.nbltypes > 1
            || body.insertCopy.nbltypes > 1
            || body.distance.nbltypes > 1
        {
            throw BrotliError.notImplemented(
                "multi-block-type streams (NBLTYPES > 1) — "
                + "block-length walker pending")
        }
        if body.ntreesl > 1 || body.ntreesd > 1 {
            throw BrotliError.notImplemented(
                "multi-tree streams (NTREES > 1) — context map "
                + "decoder pending")
        }
        // 2. Three prefix codes (literal alphabet 256, IC alphabet
        //    704, distance alphabet derived from NPOSTFIX + NDIRECT).
        let ndirectShifted = body.ndirect << body.npostfix
        let distanceAlphabet = BrotliDistance.alphabetSize(
            npostfix: body.npostfix,
            ndirectShifted: ndirectShifted)
        let literalTree = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: 256)
        let icTree = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: BrotliInsertCopy.alphabetSize)
        let distanceTree = try BrotliPrefixCodeReader.read(
            from: &r, alphabetSize: distanceAlphabet)
        let distanceLut = BrotliDistance.buildLut(
            npostfix: body.npostfix,
            ndirectShifted: ndirectShifted,
            alphabetSizeLimit: distanceAlphabet)
        // 3. LZ77 loop. Track the position within this meta-block's
        //    output so we know when to stop.
        let bodyStart = output.count
        var rb = [16, 15, 11, 4]   // Brotli default distance ring buffer
        var rbIdx = 0
        let trace = ProcessInfo.processInfo.environment[
            "BROTLI_TRACE"] != nil
        while output.count - bodyStart < targetSize {
            // 3a. Read IC command.
            let cmd = try BrotliInsertCopy.decodeCommand(
                from: &r, prefixCode: icTree)
            if trace {
                let line = "TRACE IC ins=\(cmd.insertLength)"
                    + " cpy=\(cmd.copyLength)"
                    + " distFlag=\(cmd.distanceFlag)"
                    + " pos=\(output.count - bodyStart)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            // 3b. Insert `cmd.insertLength` literals.
            for _ in 0..<cmd.insertLength {
                if output.count - bodyStart >= targetSize { break }
                let lit = try literalTree.decodeSymbol(from: &r)
                if trace {
                    FileHandle.standardError.write(Data(
                        "TRACE LIT 0x\(String(lit, radix: 16))\n"
                        .utf8))
                }
                output.append(UInt8(lit & 0xFF))
            }
            // 3c. If we've filled the body, stop (the IC command's
            //     copy phase is sometimes skipped at end of stream).
            if output.count - bodyStart >= targetSize { break }
            // 3d. Read or recall the distance.
            let distance: Int
            if cmd.distanceFlag == 0 {
                // Use most recent distance from the ring buffer
                // (code = 0 short code).
                var rbCopy = rb
                var rbIdxCopy = rbIdx
                distance = BrotliDistance.resolveShortCode(
                    code: 0,
                    ringBuffer: &rbCopy,
                    ringBufferIdx: &rbIdxCopy)
                rb = rbCopy; rbIdx = rbIdxCopy
            } else {
                distance = try BrotliDistance.readDistance(
                    from: &r, prefixCode: distanceTree,
                    lut: distanceLut,
                    ringBuffer: &rb, ringBufferIdx: &rbIdx)
            }
            // 3e. Ring buffer update — only for "real" distances
            //     (not when reusing the most-recent via code 0).
            //     The ring buffer is updated whenever a fresh
            //     distance is consumed.
            if cmd.distanceFlag != 0 {
                rb[rbIdx & 3] = distance
                rbIdx += 1
            }
            // 3f. Copy `cmd.copyLength` bytes from `output[count -
            //     distance]` onward.
            let absPos = output.count
            if distance <= 0 {
                throw BrotliError.invalidBackReference(
                    distance: distance, outputSize: absPos)
            }
            if distance > absPos {
                // Static-dictionary reference — not yet implemented.
                throw BrotliError.notImplemented(
                    "static-dictionary back-reference "
                    + "(distance \(distance) > output size "
                    + "\(absPos)) — RFC 7932 §8 dictionary pending")
            }
            // Naive byte-by-byte copy handles overlapping
            // back-references correctly (LZ77 self-reference).
            for _ in 0..<cmd.copyLength {
                if output.count - bodyStart >= targetSize { break }
                let srcIdx = output.count - distance
                let b = output[output.startIndex + srcIdx]
                output.append(b)
            }
        }
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
