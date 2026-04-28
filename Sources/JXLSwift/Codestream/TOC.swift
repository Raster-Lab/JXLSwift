// TOC — frame Table of Contents.
//
// ISO/IEC 18181-1 §C.8.1.5 (and libjxl `lib/jxl/toc.cc`). After the
// frame header, every JXL frame carries a TOC: per-group byte sizes,
// optionally preceded by a permutation that reorders groups for
// random-access optimisation. The TOC lets a decoder seek directly
// to a specific group without scanning everything before it.
//
// **Bit layout (matches libjxl `ReadToc`):**
//
//     has_permutation  u(1)
//     if has_permutation:
//         permutation (entropy-coded — NOT YET IMPLEMENTED)
//     align to byte
//     for i in 0..<num_entries:
//         entry_size : U32(Bits(10), 1024+u(14), 17408+u(22),
//                          4211712+u(30))
//     align to byte
//
// `num_entries` is computed from the FrameHeader by the caller per
// libjxl's `NumTocEntries`:
//
//     if num_groups == 1 && num_passes == 1: 1 entry (whole frame)
//     else: 2 + num_dc_groups + num_passes × num_groups
//
// The TOC entries are byte sizes. Byte offsets into the
// post-TOC group section are the prefix sums; if a permutation is
// present, offsets are reshuffled by it.
//
// The permutation entropy-coding path uses `DecodePermutation` from
// libjxl coeff_order.cc — it shares the ANS infrastructure with
// histogram clustering. We currently throw `.permutationNotImplemented`
// when the permutation flag is 1; for simple single-group lossless
// frames cjxl emits no permutation, so the common case round-trips
// fine.

import Foundation

public enum TOCError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case permutationNotImplemented
    case tooManyEntries(Int)
    case overflow
}

public struct TOC: Sendable, Equatable {
    /// True if the frame's groups are emitted in a permuted order.
    /// We don't yet decode the permutation entropy stream, so reading
    /// a TOC with this flag set throws.
    public let hasPermutation: Bool
    /// Per-entry byte size, in the order they appear in the
    /// codestream (NOT reordered by permutation — callers apply that
    /// themselves once we support it).
    public let entrySizes: [UInt32]
    /// Cumulative byte offsets into the post-TOC group section.
    /// `offsets[i] = sum(entrySizes[0..<i])`. The final element is
    /// the total compressed size of all groups.
    public let offsets: [UInt64]

    public init(hasPermutation: Bool, entrySizes: [UInt32], offsets: [UInt64]) {
        self.hasPermutation = hasPermutation
        self.entrySizes = entrySizes
        self.offsets = offsets
    }

    /// libjxl's per-entry U32 distribution — `(Bits(10), 1024+u(14),
    /// 17408+u(22), 4211712+u(30))` — sized so encoders can patch
    /// TOC after the rest of the frame is encoded.
    public static let entryDistribution: (UInt32Distribution,
                                          UInt32Distribution,
                                          UInt32Distribution,
                                          UInt32Distribution) = (
        .bits(10),
        .offset(constant: 1024, extraBits: 14),
        .offset(constant: 17408, extraBits: 22),
        .offset(constant: 4211712, extraBits: 30)
    )

    /// Compute `num_toc_entries` per libjxl `NumTocEntries`. For a
    /// single-group single-pass frame this is 1; otherwise the count
    /// includes a permutation entry per pass per group plus DC.
    public static func numEntries(
        numGroups: Int, numDcGroups: Int, numPasses: Int
    ) -> Int {
        if numGroups == 1 && numPasses == 1 { return 1 }
        // libjxl AcGroupIndex(0, 0, numGroups, numDcGroups) =
        //   2 + numDcGroups + 0 * numGroups + 0 = 2 + numDcGroups
        let acStart = 2 + numDcGroups
        return acStart + numPasses * numGroups
    }

    /// Read a TOC with `numEntries` entries.
    public static func read(
        from r: inout BitReader, numEntries: Int
    ) throws -> TOC {
        guard numEntries > 0 else {
            return TOC(hasPermutation: false, entrySizes: [], offsets: [0])
        }
        guard numEntries <= 65536 else {
            throw TOCError.tooManyEntries(numEntries)
        }
        let hasPermutation: Bool
        do { hasPermutation = try r.readBit() }
        catch let e as BitstreamError { throw TOCError.bitstream(e) }
        if hasPermutation {
            // Decoding the permutation requires the ANS / context-map
            // infrastructure (see libjxl DecodePermutation in
            // coeff_order.cc). Out of scope until the entropy section
            // wrapper lands.
            throw TOCError.permutationNotImplemented
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw TOCError.bitstream(e) }
        var sizes = [UInt32]()
        sizes.reserveCapacity(numEntries)
        for _ in 0..<numEntries {
            let s: UInt32
            do { s = try r.readU32(entryDistribution) }
            catch let e as BitstreamError { throw TOCError.bitstream(e) }
            sizes.append(s)
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw TOCError.bitstream(e) }
        // Compute prefix-sum offsets.
        var offsets = [UInt64](); offsets.reserveCapacity(numEntries + 1)
        var acc: UInt64 = 0
        offsets.append(0)
        for s in sizes {
            let next = acc &+ UInt64(s)
            if next < acc { throw TOCError.overflow }
            offsets.append(next)
            acc = next
        }
        return TOC(hasPermutation: false, entrySizes: sizes, offsets: offsets)
    }

    /// Write a TOC. Caller is responsible for ensuring
    /// `entrySizes.count == numEntries`. We don't yet emit
    /// permutations.
    public func write(to w: inout BitWriter) throws {
        if hasPermutation {
            throw TOCError.permutationNotImplemented
        }
        w.writeBit(false)
        w.alignToByte()
        for s in entrySizes {
            do { try w.writeU32(s, distributions: TOC.entryDistribution) }
            catch let e as BitstreamError { throw TOCError.bitstream(e) }
        }
        w.alignToByte()
    }
}
