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
// **Bit layout (matches libjxl `LZ77Params::VisitFields` +
// `DecodeHistograms` exactly):**
//
//     lz77_enabled        u(1)
//     if lz77_enabled == 1:
//         min_symbol      U32(224, 512, 4096, 8+u(15))
//         min_length      U32(3,   4,   5+u(2), 9+u(8))
//         length_uint_config HybridUintConfig (log_alpha_size = 8 fixed)
//
// libjxl reads `length_uint_config` with `log_alpha_size = 8`
// hardcoded inside `DecodeHistograms`, regardless of the surrounding
// stream's actual log-alphabet size — the LZ77 length token uses an
// 8-bit alphabet by convention. The "distance config" hinted at by
// the field name in earlier drafts of this file doesn't exist as a
// separate header field — back-references inherit their distance
// distribution from the cluster pointed to by `context_map.back()`,
// and the `length_uint_config` embedded here applies only to LZ77
// length tokens (entropy symbols >= `min_symbol`).
//
// When `lz77_enabled == 0`, only the 1-bit flag is emitted.

import Foundation

package enum LZ77ConfigError: Error, Sendable, Equatable {
    case bitstream(BitstreamError)
    case hybridConfig(HybridUintConfigError)
}

package struct LZ77Config: Sendable, Equatable {
    package let enabled: Bool
    package let minSymbol: UInt32
    package let minLength: UInt32
    /// HybridUintConfig used for LZ77 length tokens (entropy symbols
    /// `>= minSymbol`). The decoder applies this config when it sees a
    /// symbol in the LZ77 range; ordinary symbols use the per-context
    /// HybridUintConfig from the surrounding ANS code.
    package let lengthUintConfig: HybridUintConfig

    package init(enabled: Bool,
                minSymbol: UInt32 = 224,
                minLength: UInt32 = 3,
                lengthUintConfig: HybridUintConfig = .defaultConfig) {
        self.enabled = enabled
        self.minSymbol = minSymbol
        self.minLength = minLength
        self.lengthUintConfig = lengthUintConfig
    }

    /// Default disabled configuration. Emit just the 1-bit flag.
    package static let disabled = LZ77Config(enabled: false)
}

extension LZ77Config {

    /// log_alpha_size used to (de)serialise `length_uint_config` —
    /// libjxl hardcodes this to 8 in `DecodeHistograms`.
    package static let lengthUintConfigLogAlpha: Int = 8

    /// Serialise this config. Has no `logAlpha` argument — the LZ77
    /// length token alphabet is always 2^8 by spec convention.
    package func write(to w: inout BitWriter) throws {
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
        do { try lengthUintConfig.write(to: &w, logAlpha: Self.lengthUintConfigLogAlpha) }
        catch let e as HybridUintConfigError {
            throw LZ77ConfigError.hybridConfig(e)
        }
    }

    /// Deserialise.
    package static func read(from r: inout BitReader) throws -> LZ77Config {
        let trace = ProcessInfo.processInfo.environment["JXL_TRACE"] != nil
        let pStart = r.position
        let enabled: Bool
        do { enabled = try r.readBit() }
        catch let e as BitstreamError { throw LZ77ConfigError.bitstream(e) }
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE LZ77 enabled=\(enabled) at pos=\(pStart)\n".utf8))
        }
        if !enabled {
            return LZ77Config.disabled
        }
        let pSym = r.position
        let minSymbol: UInt32
        let minLength: UInt32
        do {
            minSymbol = try r.readU32((
                .literal(224), .literal(512), .literal(4096),
                .offset(constant: 8, extraBits: 15)
            ))
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE LZ77 min_symbol=\(minSymbol) bits=\(r.position-pSym) at pos=\(pSym)\n".utf8))
            }
            let pLen = r.position
            minLength = try r.readU32((
                .literal(3), .literal(4),
                .offset(constant: 5, extraBits: 2),
                .offset(constant: 9, extraBits: 8)
            ))
            if trace {
                FileHandle.standardError.write(Data(
                    "TRACE LZ77 min_length=\(minLength) bits=\(r.position-pLen) at pos=\(pLen)\n".utf8))
            }
        } catch let e as BitstreamError {
            throw LZ77ConfigError.bitstream(e)
        }
        let pCfg = r.position
        let lengthCfg: HybridUintConfig
        do { lengthCfg = try HybridUintConfig.read(from: &r, logAlpha: lengthUintConfigLogAlpha) }
        catch let e as HybridUintConfigError {
            throw LZ77ConfigError.hybridConfig(e)
        }
        if trace {
            FileHandle.standardError.write(Data(
                "TRACE LZ77 length_uint_config bits=\(r.position-pCfg) at pos=\(pCfg)\n".utf8))
        }
        return LZ77Config(
            enabled: true,
            minSymbol: minSymbol,
            minLength: minLength,
            lengthUintConfig: lengthCfg
        )
    }
}
