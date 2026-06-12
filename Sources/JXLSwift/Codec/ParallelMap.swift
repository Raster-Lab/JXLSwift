// parallelMap — the package's deterministic-parallelism primitive.
//
// Run `work(i)` for each `i` in `0..<count` concurrently and collect
// the results into an ORDERED array, so callers' outputs — section
// arrays, batch logs, candidate comparisons — are byte-identical to a
// sequential loop. Promoted from `MinimalLosslessCodec`, where the
// pattern was first proven; shared by the multi-group encoder, the
// candidate ladder, and the `jxl batch` CLI.
//
// Uses GCD `concurrentPerform` (width = active cores, work-stealing)
// under the hood; the closure is `@Sendable` and writes go to disjoint
// indices via `withUnsafeMutableBufferPointer` — a scoped,
// Swift-stdlib-blessed escape hatch, not the prohibited
// `nonisolated(unsafe)` long-lived mutable state pattern
// (CLAUDE.md constraint 2).

import Foundation

/// Run `work(i)` for each `i` in `0..<count` in parallel where
/// possible, collecting the results into an ordered array. Falls
/// through to a sequential loop for `count <= 1` (no dispatch
/// overhead).
@inline(__always)
package func parallelMap<T: Sendable>(
    _ count: Int,
    _ work: @Sendable (Int) -> T
) -> [T] {
    if count <= 1 {
        return (0..<count).map(work)
    }
    var results: [T?] = Array(repeating: nil, count: count)
    results.withUnsafeMutableBufferPointer { buffer in
        // Capture the buffer's base pointer as a Sendable
        // raw-pointer integer — disjoint-index writes are safe.
        let base = UInt(bitPattern: Int(bitPattern: OpaquePointer(buffer.baseAddress!)))
        DispatchQueue.concurrentPerform(iterations: count) { i in
            let p = UnsafeMutablePointer<T?>(
                bitPattern: Int(bitPattern: base)
            )!
            p.advanced(by: i).pointee = work(i)
        }
    }
    return results.map { $0! }
}
