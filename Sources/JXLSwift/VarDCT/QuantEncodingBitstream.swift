// `DequantMatrices` per-slot quant-encoding bitstream writers —
// the encoder side of `QuantEncoding.read` (`QuantEncoding.swift`).
// Ports of libjxl `enc_quant_weights.cc::EncodeQuant` per
// `QuantEncoding::Mode`.
//
// The full `DequantMatrices` payload write needs all 17 slots
// (one per AC strategy kind). This file ships the two slot
// writers the JPEG → JXL coefficient bridge needs:
//
//   1. `writeLibraryEncoding(predefined:to:)` — mode 0
//      (`kQuantModeLibrary`). Used for the 16 slots the bridge
//      keeps at their library defaults.
//   2. `writeRAWEncoding(payload:size:to:)` — mode 7
//      (`kQuantModeRAW`). Used for the DCT8×8 slot (the only one
//      the bridge overrides) to inject the JPEG quant table via
//      the v0.12.0r `ModularSubImage` encoder.
//
// Mode bit width: 3 (`kLog2NumQuantModes = 3` in libjxl
// `quant_weights.h:29`).
//
// **Status (v0.12.0s — step 3.6 write dep 2 starter):** these
// are the per-slot writers; the surrounding `DequantMatrices`
// envelope (1-bit all_default + 17 slots) is the next bite. With
// dep 1 (ModularSubImage) shipped v0.12.0r and these per-slot
// writers here, the bridge encoder's quant-matrix bitstream
// piece is one wrapper call away.

import Foundation

/// `kLog2NumQuantModes` per libjxl. Width of the mode selector
/// at the start of each quant-encoding slot.
private let kQuantModeBits = 3

// (The libjxl `QuantEncoding::Mode` enum values are mirrored by
//  the existing `QuantMode` in QuantEncoding.swift — `raw=7`,
//  `library=0`, etc. v0.12.0t corrected those rawValues to match
//  libjxl. Don't introduce a parallel enum; use `QuantMode`.)

public enum QuantEncodingBitstream {

    /// Write a slot encoded as `kQuantModeLibrary` selecting
    /// `predefined` (typically 0 for the only currently-defined
    /// library table). Bit layout:
    ///
    ///     u(3) mode = 0 (kQuantModeLibrary)
    ///     u(kCeilLog2NumPredefinedTables) predefined
    ///
    /// libjxl ships exactly one predefined table per slot
    /// (`kNumPredefinedTables = 1`), so
    /// `kCeilLog2NumPredefinedTables == 0` and the
    /// `predefined` field collapses to zero bits. Asserts
    /// `predefined == 0` to catch callers that haven't realised
    /// this — extending to multiple predefined tables is a
    /// theoretical libjxl future, not in 0.11.2.
    public static func writeLibraryEncoding(
        predefined: UInt32 = 0,
        to w: inout BitWriter
    ) {
        precondition(predefined == 0,
            "kQuantModeLibrary predefined > 0 is not used in "
            + "libjxl 0.11.2 (kNumPredefinedTables == 1)")
        w.write(bits: kQuantModeBits,
                value: UInt32(QuantMode.library.rawValue))
        // predefined field is zero bits in 0.11.2 — no write.
    }

    /// Write a slot encoded as `kQuantModeRAW` — JPEG quant
    /// table injection. Bit layout:
    ///
    ///     u(3) mode = 7 (kQuantModeRAW)
    ///     F16  qtable_den    (16 bits)
    ///     ModularSubImage    (channels = 3, bitsPerSample = 8,
    ///                         width = size.x, height = size.y)
    ///
    /// `payload.qtable` must hold `3 × size.x × size.y` Int32
    /// values in channel-major order.
    public static func writeRAWEncoding(
        payload: JXLBridgeRAWQuantPayload,
        size: (x: Int, y: Int),
        to w: inout BitWriter
    ) throws {
        let need = 3 * size.x * size.y
        guard payload.qtable.count == need else {
            throw QuantWeightsError.misshapedBands(
                "RAW qtable count \(payload.qtable.count) "
                + "≠ 3 × \(size.x) × \(size.y) = \(need)")
        }
        w.write(bits: kQuantModeBits,
                value: UInt32(QuantMode.raw.rawValue))
        let half = floatToHalf(payload.qtableDen)
        w.write(bits: 16, value: UInt32(half))
        // Slice qtable into 3 per-channel buffers for the
        // ModularSubImage writer (which takes [[Int32]]).
        let per = size.x * size.y
        var channels: [[Int32]] = []
        channels.reserveCapacity(3)
        for c in 0..<3 {
            channels.append(
                Array(payload.qtable[c * per ..< (c + 1) * per]))
        }
        try ModularSubImage.write(
            channels: channels,
            width: size.x, height: size.y,
            bitsPerSample: 8, to: &w)
    }
}
