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
// **Bit layout (this implementation):**
//
//     lz77_enabled        u(1)
//     if lz77_enabled == 1:
//         min_symbol      u(16)        // placeholder — see caveat
//         min_length      u(16)        // placeholder — see caveat
//         distance_config HybridUintConfig (sized to logAlpha)
//
// **Caveat:** the actual JXL spec encodes `min_symbol` and `min_length`
// as `U32()` values with specific (constant, extra_bits) distributions
// I'm not 100% sure of without spec text in hand. We use raw u(16)
// here as a placeholder — round-trip tests prove encoder/decoder
// agreement, but this layout is **not byte-for-byte spec compliant**
// for LZ77-enabled JXL codestreams. Replacing the u(16) fields with
// the correct U32 distributions is the next subtask under E6 and
// benefits from libjxl byte cross-check.
//
// When `lz77_enabled == 0`, only the 1-bit flag is emitted and the
// layout above degenerates trivially — that path *is* spec-correct.

import Foundation

public enum LZ77ConfigError: Error, Sendable, Equatable {
    case minSymbolOutOfRange(UInt32)
    case minLengthOutOfRange(UInt32)
    case bitstream(BitstreamError)
    case hybridConfig(HybridUintConfigError)
}

public struct LZ77Config: Sendable, Equatable {
    public let enabled: Bool
    public let minSymbol: UInt32
    public let minLength: UInt32
    public let distanceConfig: HybridUintConfig

    public init(enabled: Bool,
                minSymbol: UInt32 = 224,
                minLength: UInt32 = 3,
                distanceConfig: HybridUintConfig = .defaultConfig) {
        self.enabled = enabled
        self.minSymbol = minSymbol
        self.minLength = minLength
        self.distanceConfig = distanceConfig
    }

    /// Default disabled configuration. Emit just the 1-bit flag.
    public static let disabled = LZ77Config(enabled: false)
}

extension LZ77Config {

    /// Serialise this config. `logAlpha` is the surrounding context's
    /// log-alphabet-size — needed to size the embedded
    /// `distanceConfig` field (only emitted when `enabled`).
    public func write(to w: inout BitWriter, logAlpha: Int) throws {
        w.writeBit(enabled)
        if !enabled { return }
        guard minSymbol <= 0xFFFF else {
            throw LZ77ConfigError.minSymbolOutOfRange(minSymbol)
        }
        guard minLength <= 0xFFFF else {
            throw LZ77ConfigError.minLengthOutOfRange(minLength)
        }
        w.write(bits: 16, value: minSymbol)
        w.write(bits: 16, value: minLength)
        do { try distanceConfig.write(to: &w, logAlpha: logAlpha) }
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
            minSymbol = try r.read(bits: 16)
            minLength = try r.read(bits: 16)
        } catch let e as BitstreamError {
            throw LZ77ConfigError.bitstream(e)
        }
        let distConfig: HybridUintConfig
        do { distConfig = try HybridUintConfig.read(from: &r, logAlpha: logAlpha) }
        catch let e as HybridUintConfigError {
            throw LZ77ConfigError.hybridConfig(e)
        }
        return LZ77Config(
            enabled: true,
            minSymbol: minSymbol,
            minLength: minLength,
            distanceConfig: distConfig
        )
    }
}
