// AliasTable — Vose's alias method as used by libjxl's rANS.
//
// libjxl `lib/jxl/ans_common.{h,cc}::AliasTable`. For byte-exact rANS
// decoding of cjxl-emitted bitstreams, the decoder MUST use the SAME
// slot → (symbol, freq, offset) mapping the encoder used. libjxl uses
// the alias method (not a cumulative-range lookup) to spread each
// symbol's frequency across `table_size = 1 << log_alpha_size`
// fixed-size entries, each of size `range / table_size`. Within each
// entry:
//
//   • `cutoff` separates the entry's "left" symbol (slots < cutoff)
//     from its "right" symbol (slots ≥ cutoff).
//   • `right_value` names the right symbol.
//   • `offsets1` is the running offset for the right symbol so that
//     state evolution `state' = freq * (state >> kLogRange) + offset`
//     stays consistent.
//
// This file ports `InitAliasTable` and the Lookup operation directly.

import Foundation

package enum AliasTableError: Error, Sendable {
    case tableSizeExceedsRange
    case distributionTooLarge
    case sumNotEqualRange
}

package struct AliasTable: Sendable {
    package struct Entry: Sendable {
        package var cutoff: UInt16
        package var rightValue: UInt16
        package var freq0: UInt16
        package var offsets1: UInt16
        package var freq1: UInt16
    }
    package struct LookupResult: Sendable {
        package let value: Int     // symbol
        package let offset: UInt32
        package let freq: UInt32
    }
    package let entries: [Entry]
    package let logEntrySize: Int
    package let entrySizeMinusOne: Int

    package init(
        distribution: [Int32],
        logRange: Int,
        logAlphaSize: Int
    ) throws {
        let range = 1 << logRange
        let tableSize = 1 << logAlphaSize
        guard tableSize <= range else {
            throw AliasTableError.tableSizeExceedsRange
        }
        // Trim trailing zeros, then ensure non-empty.
        var dist = distribution
        while !dist.isEmpty && dist.last == 0 { dist.removeLast() }
        if dist.isEmpty {
            dist.append(Int32(range))
        }
        guard dist.count <= tableSize else {
            throw AliasTableError.distributionTooLarge
        }
        let entrySize = range >> logAlphaSize  // = range / tableSize
        var entries = Array(repeating: Entry(
            cutoff: 0, rightValue: 0, freq0: 0, offsets1: 0, freq1: 0
        ), count: tableSize)

        // Single-symbol shortcut — preserves state across decodes.
        var singleSymbol: Int = -1
        var sum: Int = 0
        for sym in 0..<dist.count {
            let v = Int(dist[sym])
            sum &+= v
            if v == range {
                singleSymbol = sym
            }
        }
        guard sum == range else {
            throw AliasTableError.sumNotEqualRange
        }
        if singleSymbol >= 0 {
            for i in 0..<tableSize {
                entries[i].rightValue = UInt16(singleSymbol)
                entries[i].cutoff = 0
                entries[i].offsets1 = UInt16(entrySize * i)
                entries[i].freq0 = 0
                entries[i].freq1 = UInt16(range)
            }
            self.entries = entries
            self.logEntrySize = logRange - logAlphaSize
            self.entrySizeMinusOne = entrySize - 1
            return
        }

        // Vose's alias method: pair overfull/underfull entries.
        var cutoffs = [Int](repeating: 0, count: tableSize)
        var underfull: [Int] = []
        var overfull: [Int] = []
        for i in 0..<dist.count {
            cutoffs[i] = Int(dist[i])
            if cutoffs[i] > entrySize {
                overfull.append(i)
            } else if cutoffs[i] < entrySize {
                underfull.append(i)
            }
        }
        for i in dist.count..<tableSize {
            cutoffs[i] = 0
            underfull.append(i)
        }
        while !overfull.isEmpty {
            let oi = overfull.removeLast()
            let ui = underfull.removeLast()
            let underfullBy = entrySize - cutoffs[ui]
            cutoffs[oi] -= underfullBy
            entries[ui].rightValue = UInt16(oi)
            entries[ui].offsets1 = UInt16(cutoffs[oi])
            if cutoffs[oi] < entrySize {
                underfull.append(oi)
            } else if cutoffs[oi] > entrySize {
                overfull.append(oi)
            }
        }
        for i in 0..<tableSize {
            if cutoffs[i] == entrySize {
                entries[i].rightValue = UInt16(i)
                entries[i].offsets1 = 0
                entries[i].cutoff = 0
            } else {
                entries[i].offsets1 = UInt16(Int(entries[i].offsets1) - cutoffs[i])
                entries[i].cutoff = UInt16(cutoffs[i])
            }
            let freq0 = i < dist.count ? Int(dist[i]) : 0
            let i1 = Int(entries[i].rightValue)
            let freq1 = i1 < dist.count ? Int(dist[i1]) : 0
            entries[i].freq0 = UInt16(freq0)
            entries[i].freq1 = UInt16(freq1)
        }
        if ProcessInfo.processInfo.environment["JXL_TRACE"] != nil {
            for (i, e) in entries.enumerated() {
                let msg = "TRACE swift-alias[\(i)]: cutoff=\(e.cutoff) right=\(e.rightValue) offsets1=\(e.offsets1) freq0=\(e.freq0) freq1=\(e.freq1)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
        self.entries = entries
        self.logEntrySize = logRange - logAlphaSize
        self.entrySizeMinusOne = entrySize - 1
    }

    /// Look up `(value, offset, freq)` for a given rANS slot. Mirrors
    /// libjxl `AliasTable::Lookup`.
    @inline(__always)
    package func lookup(slot: UInt32) -> LookupResult {
        let i = Int(slot) >> logEntrySize
        let pos = Int(slot) & entrySizeMinusOne
        let entry = entries[i]
        let cutoff = Int(entry.cutoff)
        let greater = pos >= cutoff
        let value = greater ? Int(entry.rightValue) : i
        let offsetVal = greater
            ? UInt32(Int(entry.offsets1) &+ pos)
            : UInt32(pos)
        let freq = greater ? UInt32(entry.freq1) : UInt32(entry.freq0)
        return LookupResult(value: value, offset: offsetVal, freq: freq)
    }
}
