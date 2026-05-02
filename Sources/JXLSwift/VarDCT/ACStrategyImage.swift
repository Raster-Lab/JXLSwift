// ACStrategyImage — per-block AC-strategy plane, expanded from
// ACMetadata channel 2.
//
// libjxl: `lib/jxl/ac_strategy.h::AcStrategyImage` +
// `lib/jxl/dec_modular.cc::DecodeAcMetadata`. ACMetadata channel 2 has
// shape `count × 2`: row 0 holds `count` first-block strategy IDs in
// raster scan order, row 1 holds the matching `count` per-block QF
// values. Non-first-block cells (covered by a multi-block transform
// like DCT16×16) are NOT enumerated in the channel — the decoder
// expands them by walking blocks in raster order and tracking which
// cells are already covered.
//
// Output: a `numBlocksX × numBlocksY` plane where every entry is
// either a "first-block" with a valid `ACStrategy` (and per-block QF)
// or a "covered" entry pointing back at its first-block coordinates.
//
// Status: structural assembly only. Per-strategy IDCT shape and
// natural coefficient order land alongside the v0.8.0 IDCT
// implementation work.

import Foundation

public enum ACStrategyImageError: Error, Sendable {
    case invalidStrategyValue(Int32)
    case acsCountMismatch(expected: Int, actual: Int)
    case overflow(blockX: Int, blockY: Int, cellsX: Int, cellsY: Int)
    case invalidNonFirstBlockMarker(value: Int32, blockX: Int, blockY: Int)
}

/// One entry in the AC strategy plane.
public struct ACStrategyEntry: Sendable, Equatable {
    /// True if this cell is the (top-left) "first-block" of its
    /// transform — only first-blocks have AC tokens decoded for them.
    public let isFirstBlock: Bool
    /// The transform's strategy. For non-first-block entries, this
    /// is the same value as the first-block's strategy.
    public let strategy: ACStrategy
    /// Coordinates of the first-block (= self for first-blocks).
    public let firstBlockX: Int
    public let firstBlockY: Int
    /// Per-block QF (1..256). Only meaningful on first-blocks.
    public let qf: Int32
}

public struct ACStrategyImage: Sendable {
    public let width: Int   // in blocks (numBlocksX)
    public let height: Int  // in blocks (numBlocksY)
    public let entries: [ACStrategyEntry]
    /// First-block coordinates in raster scan order — same order the
    /// AC decode loop iterates.
    public let firstBlocks: [(x: Int, y: Int)]

    public func at(x: Int, y: Int) -> ACStrategyEntry {
        precondition(x >= 0 && x < width && y >= 0 && y < height)
        return entries[y * width + x]
    }

    /// Build from ACMeta channel 2's flattened layout
    /// `[ACS_0..ACS_{count-1}, QF_0..QF_{count-1}]`. Per libjxl
    /// `dec_modular.cc::DecodeAcMetadata`:
    ///
    ///     for each block (bx, by) in raster scan order:
    ///         if already covered: skip
    ///         acs = AcStrategy::FromRawStrategy(row_in_1[num])
    ///         qf  = 1 + clamp(row_in_2[num], 0, kQuantMax-1)
    ///         set acs at (bx, by) and mark covered cells
    ///         num++
    ///
    /// Throws if the encoder emitted fewer ACS entries than there are
    /// uncovered first-blocks, or a strategy whose covered area
    /// extends past the block grid.
    public static func build(
        from acmetaChannel2: [Int32],
        count: Int,
        numBlocksX: Int, numBlocksY: Int
    ) throws -> ACStrategyImage {
        precondition(numBlocksX > 0 && numBlocksY > 0)
        precondition(acmetaChannel2.count >= count * 2,
                     "channel-2 must have count*2 entries (ACS + QF)")
        let total = numBlocksX * numBlocksY
        // Sentinel: not-yet-set entries get a placeholder DCT8X8 entry
        // that we'll overwrite. Using `dct8x8` keeps the precondition
        // happy without introducing an Optional.
        var entries = [ACStrategyEntry](
            repeating: ACStrategyEntry(
                isFirstBlock: false,
                strategy: .dct8x8,
                firstBlockX: 0, firstBlockY: 0,
                qf: 0
            ),
            count: total
        )
        var covered = [Bool](repeating: false, count: total)
        var firstBlocks: [(x: Int, y: Int)] = []
        firstBlocks.reserveCapacity(count)
        var num = 0
        for by in 0..<numBlocksY {
            for bx in 0..<numBlocksX {
                if covered[by * numBlocksX + bx] { continue }
                guard num < count else {
                    throw ACStrategyImageError.acsCountMismatch(
                        expected: count, actual: num
                    )
                }
                let acsRaw = acmetaChannel2[num]
                guard acsRaw >= 0, acsRaw <= 26,
                      let acs = ACStrategy(rawValue: UInt8(acsRaw))
                else {
                    throw ACStrategyImageError.invalidStrategyValue(acsRaw)
                }
                let qfRaw = acmetaChannel2[count + num]
                let qf = 1 + max(0, min(qfRaw, 255))
                let cells = acs.blockCells
                guard bx + cells.cellsX <= numBlocksX,
                      by + cells.cellsY <= numBlocksY
                else {
                    throw ACStrategyImageError.overflow(
                        blockX: bx, blockY: by,
                        cellsX: cells.cellsX, cellsY: cells.cellsY
                    )
                }
                // Fill all covered cells with the strategy. The
                // top-left cell is the first-block.
                for iy in 0..<cells.cellsY {
                    for ix in 0..<cells.cellsX {
                        let cx = bx + ix
                        let cy = by + iy
                        let isFirst = (ix == 0 && iy == 0)
                        entries[cy * numBlocksX + cx] = ACStrategyEntry(
                            isFirstBlock: isFirst,
                            strategy: acs,
                            firstBlockX: bx, firstBlockY: by,
                            qf: isFirst ? qf : 0
                        )
                        covered[cy * numBlocksX + cx] = true
                    }
                }
                firstBlocks.append((x: bx, y: by))
                num += 1
            }
        }
        guard num == count else {
            throw ACStrategyImageError.acsCountMismatch(
                expected: count, actual: num
            )
        }
        return ACStrategyImage(
            width: numBlocksX, height: numBlocksY,
            entries: entries, firstBlocks: firstBlocks
        )
    }
}
