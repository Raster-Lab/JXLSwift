// QuantEncoding — per-AC-strategy quantisation parameters.
//
// Each of libjxl's 17 quant tables (one per AC strategy size class)
// is encoded with one of 8 quant modes:
//
//   0 Library  — predefined table at index `predefined`
//   1 ID       — Identity, 3×3 F16 weights per channel
//   2 DCT2     — DCT2x2, 3×6 F16 weights per channel
//   3 DCT4     — DCT4x4, DctParams + 3×2 F16 multipliers
//   4 DCT4X8   — 3 F16 multipliers + DctParams
//   5 DCT      — generic DCT (any block size), just DctParams
//   6 RAW      — raw 8-bit table, modular sub-image
//   7 AFV      — 3×9 F16 weights + 2 DctParams
//
// Spec: ISO/IEC 18181-1 §K.7.4. libjxl: `lib/jxl/quant_weights.cc`
// `Decode(memory_manager, br, encoding, ...)`.
//
// **Status**: parsers for modes 0 (Library) and 5 (DCT) — the
// dominant modes at typical cjxl effort settings. Modes 1-4, 6, 7
// throw `notImplemented` so the bitstream cursor stays consistent
// once the next session adds them.

import Foundation

public let kLog2NumQuantModes: Int = 3
public let kNumPredefinedTables: Int = 1
public let kCeilLog2NumPredefinedTables: Int = 0
public let kLog2MaxDistanceBands: Int = 4
public let kMaxDistanceBands: Int = 1 + (1 << kLog2MaxDistanceBands)  // 17
public let kNumQuantTables: Int = 17

/// libjxl's `required_size_x`/`required_size_y` per quant table.
/// Pre-multiplied by 8 inside `getQuantWeights`; we store the
/// raw cell-grid size so the test/spec layout maps directly.
public let kRequiredSizeX: [Int] =
    [1, 1, 1, 1, 2, 4, 1, 1, 2, 1, 1, 8, 4, 16, 8, 32, 16]
public let kRequiredSizeY: [Int] =
    [1, 1, 1, 1, 2, 4, 2, 4, 4, 1, 1, 8, 8, 16, 16, 32, 32]

/// One of libjxl's 8 quant modes. Stored alongside the per-mode
/// payload below. Raw values match libjxl's
/// `QuantEncoding::Mode` enum order
/// (`lib/jxl/quant_weights.h:58`):
///
///   `kQuantModeLibrary=0, kQuantModeID=1, kQuantModeDCT2=2,
///    kQuantModeDCT4=3, kQuantModeDCT4X8=4, kQuantModeAFV=5,
///    kQuantModeDCT=6, kQuantModeRAW=7`.
///
/// **v0.12.0t fix.** Earlier versions had `dct=5, raw=6, afv=7`
/// — wrong vs libjxl's order. The bug was dormant because the
/// only call site (`JXLDecoder.swift` ~line 791) throws
/// `.notImplemented` on non-default DequantMatrices and never
/// reaches the `QuantMode(rawValue:)` dispatch. With the
/// v0.12.0s+ bridge encoder writing actual non-default mode
/// bits, the latent inconsistency would surface; fix is a
/// pre-emptive correction.
public enum QuantMode: UInt8, Sendable, Equatable {
    case library  = 0
    case id       = 1
    case dct2     = 2
    case dct4     = 3
    case dct4x8   = 4
    case afv      = 5
    case dct      = 6
    case raw      = 7
}

/// libjxl's `DctQuantWeightParams` — distance bands shared by the
/// `DCT`, `DCT4`, `DCT4X8`, and `AFV` quant modes. `numDistanceBands`
/// in `[1, kMaxDistanceBands]`; per channel there are
/// `numDistanceBands` F16 floats with the seed (index 0)
/// post-multiplied by 64 to match libjxl `DecodeDctParams`.
public struct DctParams: Sendable {
    public var distanceBands: [[Float]]   // [3][numDistanceBands]

    public static func read(from r: inout BitReader) throws -> DctParams {
        let nMinus1: UInt32
        do {
            nMinus1 = try r.read(bits: kLog2MaxDistanceBands)
        } catch let e as BitstreamError {
            throw QuantEncodingError.bitstream(e)
        }
        let n = Int(nMinus1) + 1
        var bands = [[Float]](repeating: [], count: 3)
        for c in 0..<3 {
            var arr = [Float]()
            arr.reserveCapacity(n)
            for i in 0..<n {
                let bits16: UInt32
                do { bits16 = try r.read(bits: 16) }
                catch let e as BitstreamError {
                    throw QuantEncodingError.bitstream(e)
                }
                var f = halfToFloat(UInt16(bits16))
                if i == 0 {
                    if f < 1e-8 {
                        throw QuantEncodingError.invalidBand(c, i, f)
                    }
                    f *= 64.0
                }
                arr.append(f)
            }
            bands[c] = arr
        }
        return DctParams(distanceBands: bands)
    }
}

/// Decoded `QuantEncoding` for one AC strategy.
public struct QuantEncoding: Sendable {
    public let mode: QuantMode
    /// Library mode: predefined table index (always 0 today —
    /// libjxl's `kNumPredefinedTables == 1`).
    public let predefined: UInt32?
    /// ID mode: 3 channels × 3 F16 weights, each ×64.
    public let idWeights: [[Float]]?
    /// DCT2 mode: 3 channels × 6 F16 weights, each ×64.
    public let dct2Weights: [[Float]]?
    /// DCT4 mode: 3 channels × 2 F16 multipliers.
    public let dct4Multipliers: [[Float]]?
    /// DCT4X8 mode: 3 F16 multipliers (one per channel).
    public let dct4x8Multipliers: [Float]?
    /// AFV mode: 3 channels × 9 F16 weights (first 6 × 64).
    public let afvWeights: [[Float]]?
    /// DCT/DCT4/DCT4X8/AFV mode: distance bands.
    public let dctParams: DctParams?
    /// AFV mode: a second set of distance bands for the inner
    /// 4×4 sub-block.
    public let dctParamsAfv4x4: DctParams?
    /// RAW mode: the raw integer quant-table values, laid out
    /// channel-major in JXL transposed coordinates — `qtable[c * 64
    /// + (x * 8 + y)]` reads the value for channel `c` at position
    /// (x, y). Captured by the RAW decode so downstream CFL inverse
    /// math can recover the per-position scaling. Non-RAW modes
    /// leave this `nil`.
    public let rawQtable: [Int32]?
    /// RAW mode: the F16-decoded `qtable_den` denominator. libjxl's
    /// JPEG-transcode RAW slot uses `1 / (8 × 255) ≈ 0.000490`;
    /// other RAW slots may use different denominators. We retain
    /// it so a JPEG-bridge consumer can pin-down "this is the
    /// JPEG-compatible RAW slot" via the value comparison libjxl
    /// uses (`abs(qtable_den - 1 / (8 × 255)) < 1e-8`). Non-RAW
    /// modes leave this `nil`.
    public let rawQtableDen: Float?

    /// Memberwise init that defaults the RAW-only fields to `nil`,
    /// so non-RAW call sites don't need to spell them out.
    public init(
        mode: QuantMode,
        predefined: UInt32?,
        idWeights: [[Float]]?,
        dct2Weights: [[Float]]?,
        dct4Multipliers: [[Float]]?,
        dct4x8Multipliers: [Float]?,
        afvWeights: [[Float]]?,
        dctParams: DctParams?,
        dctParamsAfv4x4: DctParams?,
        rawQtable: [Int32]? = nil,
        rawQtableDen: Float? = nil
    ) {
        self.mode = mode
        self.predefined = predefined
        self.idWeights = idWeights
        self.dct2Weights = dct2Weights
        self.dct4Multipliers = dct4Multipliers
        self.dct4x8Multipliers = dct4x8Multipliers
        self.afvWeights = afvWeights
        self.dctParams = dctParams
        self.dctParamsAfv4x4 = dctParamsAfv4x4
        self.rawQtable = rawQtable
        self.rawQtableDen = rawQtableDen
    }
}

public enum QuantEncodingError: Error, Sendable {
    case bitstream(BitstreamError)
    case invalidMode(UInt32)
    case invalidPredefined(UInt32)
    case invalidBand(Int, Int, Float)   // channel, band index, value
    case unsupportedMode(QuantMode)
    case sizeMismatch(String)
    /// RAW mode tried to decode the modular sub-image but failed.
    /// The wrapped string is the underlying error's description so
    /// the caller can see whether it was a tree mismatch, a
    /// `decodeAllChannels` token failure, or something else.
    case rawDecodeFailed(String)
}

extension QuantEncoding {
    /// Parse one `QuantEncoding` blob. `requiredSize` is the
    /// (cells_x × cells_y) coverage from libjxl's tables — used
    /// only to validate that single-cell modes like ID / DCT2 /
    /// DCT4 / DCT4X8 / AFV are at the correct table index.
    ///
    /// `globalTree`/`globalPostHeader`/`globalPostCodebook` are the
    /// frame-level modular tree + entropy section bundled in the
    /// modular global info; passing them in unlocks RAW-mode
    /// parsing (the modular sub-image quant table). For the other
    /// modes they're unused.
    public static func read(
        from r: inout BitReader,
        requiredSizeX: Int, requiredSizeY: Int,
        globalTree: ModularTree? = nil,
        globalPostHeader: EntropySectionHeader? = nil,
        globalPostCodebook: MultiClusterCodebook? = nil,
        slotIndex: Int = 0,
        numDcGroups: Int = 0
    ) throws -> QuantEncoding {
        let modeRaw: UInt32
        do { modeRaw = try r.read(bits: kLog2NumQuantModes) }
        catch let e as BitstreamError {
            throw QuantEncodingError.bitstream(e)
        }
        guard let mode = QuantMode(rawValue: UInt8(modeRaw)) else {
            throw QuantEncodingError.invalidMode(modeRaw)
        }
        let requiredSize = requiredSizeX * requiredSizeY

        switch mode {
        case .library:
            // `kCeilLog2NumPredefinedTables == 0` → no bits read,
            // index always 0.
            let predef: UInt32
            if kCeilLog2NumPredefinedTables == 0 {
                predef = 0
            } else {
                do {
                    predef = try r.read(bits: kCeilLog2NumPredefinedTables)
                } catch let e as BitstreamError {
                    throw QuantEncodingError.bitstream(e)
                }
            }
            guard predef < UInt32(kNumPredefinedTables) else {
                throw QuantEncodingError.invalidPredefined(predef)
            }
            return QuantEncoding(
                mode: .library, predefined: predef,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: nil, dctParamsAfv4x4: nil
            )

        case .id:
            try requireSingleCell(mode, requiredSize,
                                  requiredSizeX, requiredSizeY)
            let w = try readF16Matrix(
                from: &r, channels: 3, perChannel: 3, scale: 64.0,
                rejectSubAlmostZero: true
            )
            return QuantEncoding(
                mode: .id, predefined: nil,
                idWeights: w, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: nil, dctParamsAfv4x4: nil
            )

        case .dct2:
            try requireSingleCell(mode, requiredSize,
                                  requiredSizeX, requiredSizeY)
            let w = try readF16Matrix(
                from: &r, channels: 3, perChannel: 6, scale: 64.0,
                rejectSubAlmostZero: true
            )
            return QuantEncoding(
                mode: .dct2, predefined: nil,
                idWeights: nil, dct2Weights: w,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: nil, dctParamsAfv4x4: nil
            )

        case .dct4:
            try requireSingleCell(mode, requiredSize,
                                  requiredSizeX, requiredSizeY)
            // libjxl reads the DctParams FIRST, then 3×2 F16
            // multipliers. Order matters for cursor agreement.
            let params = try DctParams.read(from: &r)
            let muls = try readF16Matrix(
                from: &r, channels: 3, perChannel: 2, scale: 1.0,
                rejectSubAlmostZero: true
            )
            return QuantEncoding(
                mode: .dct4, predefined: nil,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: muls, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: params, dctParamsAfv4x4: nil
            )

        case .dct4x8:
            try requireSingleCell(mode, requiredSize,
                                  requiredSizeX, requiredSizeY)
            // libjxl: 1 F16 multiplier per channel, then DctParams.
            var muls = [Float](repeating: 0, count: 3)
            for c in 0..<3 {
                let bits16: UInt32
                do { bits16 = try r.read(bits: 16) }
                catch let e as BitstreamError {
                    throw QuantEncodingError.bitstream(e)
                }
                let f = halfToFloat(UInt16(bits16))
                guard abs(f) >= 1e-8 else {
                    throw QuantEncodingError.invalidBand(c, 0, f)
                }
                muls[c] = f
            }
            let params = try DctParams.read(from: &r)
            return QuantEncoding(
                mode: .dct4x8, predefined: nil,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: muls,
                afvWeights: nil,
                dctParams: params, dctParamsAfv4x4: nil
            )

        case .afv:
            try requireSingleCell(mode, requiredSize,
                                  requiredSizeX, requiredSizeY)
            // libjxl: 3×9 F16 weights — first 6 entries × 64.
            var afv = [[Float]](repeating: [], count: 3)
            for c in 0..<3 {
                var arr = [Float](repeating: 0, count: 9)
                for i in 0..<9 {
                    let bits16: UInt32
                    do { bits16 = try r.read(bits: 16) }
                    catch let e as BitstreamError {
                        throw QuantEncodingError.bitstream(e)
                    }
                    var f = halfToFloat(UInt16(bits16))
                    if i < 6 { f *= 64.0 }
                    arr[i] = f
                }
                afv[c] = arr
            }
            let params = try DctParams.read(from: &r)
            let params4x4 = try DctParams.read(from: &r)
            return QuantEncoding(
                mode: .afv, predefined: nil,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: afv,
                dctParams: params, dctParamsAfv4x4: params4x4
            )

        case .dct:
            // Generic distance-bands form, any block size.
            let params = try DctParams.read(from: &r)
            return QuantEncoding(
                mode: .dct, predefined: nil,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: params, dctParamsAfv4x4: nil
            )

        case .raw:
            // libjxl `ModularFrameDecoder::DecodeQuantTable`:
            //   1. F16 `qtable_den` (× nothing — kept as-is, must
            //      be > kAlmostZero).
            //   2. ModularGenericDecompress of a small image
            //      (required_size_x × required_size_y, 3 channels,
            //      8-bit) using the frame's global tree / ANS code.
            //   3. Validate every sample > 0.
            let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
            // qtable_den.
            let cursorBefore = r.position
            let denBits: UInt32
            do { denBits = try r.read(bits: 16) }
            catch let e as BitstreamError {
                throw QuantEncodingError.bitstream(e)
            }
            let qtableDen = halfToFloat(UInt16(denBits))
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE RAW cursor=\(cursorBefore) denBits=0x\(String(denBits, radix: 16)) qtableDen=\(qtableDen)\n".utf8
                ))
            }
            guard qtableDen >= 1e-8 else {
                throw QuantEncodingError.invalidBand(0, 0, qtableDen)
            }
            // Per-RAW GroupHeader.
            let gh: GroupHeader
            do { gh = try GroupHeader.read(from: &r) }
            catch {
                throw QuantEncodingError.rawDecodeFailed(
                    "GroupHeader read: \(error)"
                )
            }
            // v0.12.0gt: per-RAW local tree (useGlobalTree=false)
            // path is exercised below — our forward bridge emits
            // its JPEG quant matrix this way. The existing
            // if-else handles both global and local; the previous
            // defensive guard against local was no longer needed
            // (the local-tree decode path was already implemented).
            guard gh.transforms.isEmpty else {
                throw QuantEncodingError.rawDecodeFailed(
                    "RAW GroupHeader carries "
                    + "\(gh.transforms.count) transform(s); not "
                    + "yet supported in the simplified RAW path"
                )
            }
            // Pick the tree + codebook to use:
            //   • useGlobalTree=true + global available → use it.
            //   • useGlobalTree=false → read local tree+codebook
            //     inline (libjxl's "no modular_frame_decoder" path).
            let tree: ModularTree
            let postHeader: EntropySectionHeader
            let postCodebook: MultiClusterCodebook
            if gh.useGlobalTree {
                guard let gTree = globalTree,
                      let gPostH = globalPostHeader,
                      let gPostCB = globalPostCodebook else {
                    throw QuantEncodingError.rawDecodeFailed(
                        "RAW GroupHeader.useGlobalTree=true but "
                        + "frame has no global tree (has_tree=0)"
                    )
                }
                tree = gTree
                postHeader = gPostH
                postCodebook = gPostCB
            } else {
                // Inline local tree + post-tree codebook.
                let treeHdr: EntropySectionHeader
                let treeCB: MultiClusterCodebook
                let localTree: ModularTree
                let localPostHdr: EntropySectionHeader
                let localPostCB: MultiClusterCodebook
                do {
                    treeHdr = try EntropySectionHeader.read(
                        from: &r, numContexts: 6
                    )
                    treeCB = try MultiClusterCodebook.read(
                        from: &r, header: treeHdr
                    )
                    var treeStream = TokenStreamReader(
                        header: treeHdr, codebook: treeCB
                    )
                    localTree = try ModularTree.decode(
                        from: &r, stream: &treeStream
                    )
                    localPostHdr = try EntropySectionHeader.read(
                        from: &r, numContexts: localTree.leafCount
                    )
                    localPostCB = try MultiClusterCodebook.read(
                        from: &r, header: localPostHdr
                    )
                } catch {
                    throw QuantEncodingError.rawDecodeFailed(
                        "RAW local tree+codebook read: \(error)"
                    )
                }
                tree = localTree
                postHeader = localPostHdr
                postCodebook = localPostCB
            }
            // Decode the 3 quant-table channels.
            let channels = (0..<3).map { _ in
                ModularChannelGeometry(
                    width: requiredSizeX, height: requiredSizeY
                )
            }
            // libjxl `modular/encoding/encoding.cc::DecodeModular`:
            // `distance_multiplier` is the **widest** channel width
            // across all non-empty channels — for the RAW quant
            // table that's `requiredSizeX` (all 3 channels share the
            // same width). Threading this through unlocks the libjxl
            // `SpecialDistance` LUT for short-range LZ77 references.
            var stream = TokenStreamReader(
                header: postHeader, codebook: postCodebook,
                distanceMultiplier: requiredSizeX
            )
            // libjxl `ModularStreamId::QuantTable(idx).ID(frame_dim)`
            // returns `1 + 3 * num_dc_groups + idx` (see
            // `lib/jxl/dec_modular.h`). The modular tree's static
            // property 1 (= stream_id) is exposed to per-node split
            // tests; cjxl's quant-table tree typically branches on
            // `prop1 > 2` / `> 3` to route channel/slot-specific
            // contexts. Passing the wrong value sends every token
            // through one tree leaf — desyncing the ANS state and
            // exhausting the bitstream long before the 192-token
            // 8×8×3 sub-image is decoded.
            let groupId: Int32 = Int32(1 + 3 * numDcGroups + slotIndex)
            let perChannel: [[Int32]]
            do {
                perChannel = try decodeAllChannels(
                    channels: channels, groupId: groupId,
                    tree: tree, stream: &stream, from: &r,
                    wpHeader: gh.wpHeader
                )
            } catch {
                throw QuantEncodingError.rawDecodeFailed(
                    "decodeAllChannels: \(error)"
                )
            }
            // Flatten the 3 channels' row-major buffers into a
            // single channel-major Int32 array `[c * 64 + i]`.
            // libjxl `dec_modular.cc::DecodeQuantTable` uses the
            // same channel-major layout when copying into the
            // `qtable` vector. Indexing is "raw" — natural JXL
            // (already-transposed-vs-JPEG) order within each
            // 8×8. The CFL-inverse consumer below indexes via
            // `c * 64 + (x * 8 + y)`.
            var rawQtable = [Int32](
                repeating: 0,
                count: 3 * requiredSizeX * requiredSizeY)
            for c in 0..<3 {
                let count = requiredSizeX * requiredSizeY
                for i in 0..<count {
                    rawQtable[c * count + i] = perChannel[c][i]
                }
            }
            return QuantEncoding(
                mode: .raw, predefined: nil,
                idWeights: nil, dct2Weights: nil,
                dct4Multipliers: nil, dct4x8Multipliers: nil,
                afvWeights: nil,
                dctParams: nil, dctParamsAfv4x4: nil,
                rawQtable: rawQtable,
                rawQtableDen: qtableDen
            )
        }
    }
}

/// Helper: enforce libjxl's "single-cell tables only" precondition
/// for the small-block modes (ID/DCT2/DCT4/DCT4X8/AFV).
@inline(__always)
private func requireSingleCell(
    _ mode: QuantMode, _ requiredSize: Int,
    _ rsx: Int, _ rsy: Int
) throws {
    if requiredSize != 1 {
        throw QuantEncodingError.sizeMismatch(
            "mode \(mode) requires single-cell table; "
            + "got \(rsx)×\(rsy)"
        )
    }
}

/// Helper: read a 3-channel matrix of F16 floats. Each entry is
/// optionally scaled and optionally rejected if its magnitude is
/// below `kAlmostZero` (libjxl's invariant for quant weights).
private func readF16Matrix(
    from r: inout BitReader,
    channels: Int, perChannel n: Int,
    scale: Float, rejectSubAlmostZero: Bool
) throws -> [[Float]] {
    var out = [[Float]](repeating: [], count: channels)
    for c in 0..<channels {
        var arr = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let bits16: UInt32
            do { bits16 = try r.read(bits: 16) }
            catch let e as BitstreamError {
                throw QuantEncodingError.bitstream(e)
            }
            var f = halfToFloat(UInt16(bits16))
            if rejectSubAlmostZero && abs(f) < 1e-8 {
                throw QuantEncodingError.invalidBand(c, i, f)
            }
            f *= scale
            arr[i] = f
        }
        out[c] = arr
    }
    return out
}
