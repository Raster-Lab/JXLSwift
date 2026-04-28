// LZ77Config — bitstream header for the LZ77 hybrid entropy mode.
//
// ISO/IEC 18181-1 §C.6.5. LZ77 hybrid extends an entropy-coded value
// stream by reserving a slice of the rANS alphabet for (length,
// distance) back-references. When the decoder pulls a token that is
// ≥ `minSymbol`, it interprets the token as a length token; the
// recovered length is `HybridUintConfig.decode(token - minSymbol) +
// minLength`. The decoder then pulls a distance token (using the
// `distanceConfig` HybridUintConfig) and copies `length` previously-
// decoded values starting at offset `current - distance`.
//
// **This file ships only the *header* for that mode**: the small
// chunk of bits at the start of an entropy-coded section that says
// whether LZ77 is enabled and, if so, carries `minSymbol`,
// `minLength`, and the distance HybridUintConfig. The actual back-
// reference decoding logic is not yet implemented because nothing
// in the codebase consumes it yet — Phase M0 (1×1 grayscale lossless)
// won't enable LZ77, so the back-reference machinery can wait.
//
// **Bit layout (matches libjxl `LZ77Params::VisitFields` exactly):**
//
//     lz77_enabled        u(1)
//     if lz77_enabled == 1:
//         min_symbol      U32(224, 512, 4096, 8+u(15))
//         min_length      U32(3,   4,   5+u(2), 9+u(8))
//         length_uint_config HybridUintConfig (sized to logAlpha)
//
// The "distance config" hinted at by the field name in earlier drafts
// of this file doesn't exist as a separate header field — back-
// references inherit their distance distribution from the cluster
// pointed to by `context_map.back()`, and the `length_uint_config`
// embedded here applies only to LZ77 length tokens (entropy symbols
// >= `min_symbol`).
//
// When `lz77_enabled == 0`, only the 1-bit flag is emitted.

import Foundation

public enum LZ77ConfigError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case hybridConfig(HybridUintConfigError)
}

public struct LZ77Config: Sendable, Equatable {
    public let enabled: Bool
    public let minSymbol: UInt32
    public let minLength: UInt32
    /// HybridUintConfig used for LZ77 length tokens (entropy symbols
    /// `>= minSymbol`). The decoder applies this config when it sees a
    /// symbol in the LZ77 range; ordinary symbols use the per-context
    /// HybridUintConfig from the surrounding ANS code.
    public let lengthUintConfig: HybridUintConfig

    public init(enabled: Bool,
                minSymbol: UInt32 = 224,
                minLength: UInt32 = 3,
                lengthUintConfig: HybridUintConfig = .defaultConfig) {
        self.enabled = enabled
        self.minSymbol = minSymbol
        self.minLength = minLength
        self.lengthUintConfig = lengthUintConfig
    }

    /// Default disabled configuration. Emit just the 1-bit flag.
    public static let disabled = LZ77Config(enabled: false)
}

extension LZ77Config {

    /// Serialise this config. `logAlpha` is the surrounding context's
    /// log-alphabet-size — needed to size the embedded
    /// `lengthUintConfig` field (only emitted when `enabled`).
    public func write(to w: inout BitWriter, logAlpha: Int) throws {
        w.writeBit(enabled)
        if !enabled { return }
        // min_symbol — `U32(Val(224), Val(512), Val(4096),
        // BitsOffset(15, 8))` per libjxl LZ77Params::VisitFields.
        do {
            try w.writeU32(minSymbol, distributions: (
                .literal(224), .literal(512), .literal(4096),
                .offset(constant: 8, extraBits: 15)
            ))
            // min_length — `U32(Val(3), Val(4), BitsOffset(2, 5),
            // BitsOffset(8, 9))`.
            try w.writeU32(minLength, distributions: (
                .literal(3), .literal(4),
                .offset(constant: 5, extraBits: 2),
                .offset(constant: 9, extraBits: 8)
            ))
        } catch let e as BitstreamError {
            throw LZ77ConfigError.bitstream(e)
        }
        do { try lengthUintConfig.write(to: &w, logAlpha: logAlpha) }
        catch let e as HybridUintConfigError {
            throw LZ77ConfigError.hybridConfig(e)
        }
    }

    /// Deserialise. `logAlpha` matches what the encoder used.
    public static func read(from r: inout BitReader, logAlpha: Int) throws -> LZ77Config {
        let enabled: Bool
        do { enabled = try r.readBit() }
        catch let e as BitstreamError { throw LZ77ConfigError.bitstream(e) }
        if !enabled {
            return LZ77Config.disabled
        }
        let minSymbol: UInt32
        let minLength: UInt32
        do {
            minSymbol = try r.readU32((
                .literal(224), .literal(512), .literal(4096),
                .offset(constant: 8, extraBits: 15)
            ))
            minLength = try r.readU32((
                .literal(3), .literal(4),
                .offset(constant: 5, extraBits: 2),
                .offset(constant: 9, extraBits: 8)
            ))
        } catch let e as BitstreamError {
            throw LZ77ConfigError.bitstream(e)
        }
        let lengthCfg: HybridUintConfig
        do { lengthCfg = try HybridUintConfig.read(from: &r, logAlpha: logAlpha) }
        catch let e as HybridUintConfigError {
            throw LZ77ConfigError.hybridConfig(e)
        }
        return LZ77Config(
            enabled: true,
            minSymbol: minSymbol,
            minLength: minLength,
            lengthUintConfig: lengthCfg
        )
    }
}
