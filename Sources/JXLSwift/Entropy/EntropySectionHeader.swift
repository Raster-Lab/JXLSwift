// EntropySectionHeader — the prefix of a JXL ANS / prefix-code section.
//
// ISO/IEC 18181-1 §C.6 (and libjxl `lib/jxl/dec_ans.cc::DecodeHistograms`).
// Every entropy-coded part of the codestream — the Modular sub-bitstream,
// VarDCT coefficient streams, ContextMap permutations, etc. — starts
// with the same structural prefix:
//
//   1. LZ77 config (`LZ77Config`).
//   2. If LZ77 is enabled, an extra context for the LZ77 distance —
//      `length_uint_config` is read with `log_alpha_size = 8`.
//   3. Context map of size `num_contexts` (only emitted when
//      num_contexts > 1).
//   4. `use_prefix_code` flag (u(1)). Picks Huffman vs rANS for the
//      per-histogram codes.
//   5. `log_alpha_size`: `PREFIX_MAX_BITS` (=15) if prefix, else
//      `5 + u(2)`.
//   6. `uint_configs[num_histograms]`: one `HybridUintConfig` per
//      cluster (i.e. per distinct histogram).
//
// What this file ships: parsing of fields 1–6 and a reader-side
// `EntropySectionHeader` value carrying the parsed state. **The actual
// histograms** (per-cluster prefix-code tables or per-cluster
// rANS distributions) follow steps 1–6 and are NOT yet parsed here —
// they're the next milestone in the entropy chain. Callers that need
// just the structural prefix (e.g. to skip an entropy section, or
// gather sizes) can read this header and stop.
//
// `num_contexts` is supplied by the caller (the surrounding
// codestream knows how many contexts the consumer requires — e.g.
// 1 for a per-channel Modular stream, more for VarDCT or
// ContextMap permutations).

import Foundation

public enum EntropySectionHeaderError: Error, Sendable {
    case bitstream(BitstreamError)
    case lz77(LZ77ConfigError)
    case contextMap(ContextMapError)
    case hybridConfig(HybridUintConfigError)
}

public struct EntropySectionHeader: Sendable {
    /// LZ77 configuration. When `enabled`, `lengthUintConfig` is set
    /// from the wire; otherwise it's the disabled placeholder.
    public let lz77: LZ77Config
    /// Context map. When `numContexts <= 1` this is the trivial map
    /// `[0]` (no bits emitted). Otherwise it routes contexts to
    /// clusters via `ContextMap.read`.
    public let contextMap: ContextMap
    /// True if per-histogram codes are Huffman / prefix codes; false
    /// if they're rANS distributions.
    public let usePrefixCode: Bool
    /// Log of the per-histogram alphabet size. `PREFIX_MAX_BITS` (=15)
    /// when `usePrefixCode`, otherwise `5..8` (5 + u(2)).
    public let logAlphaSize: Int
    /// One `HybridUintConfig` per cluster, in cluster order.
    public let uintConfigs: [HybridUintConfig]
    /// libjxl `kPrefixMaxBits`.
    public static let prefixMaxBits: Int = 15

    public init(
        lz77: LZ77Config,
        contextMap: ContextMap,
        usePrefixCode: Bool,
        logAlphaSize: Int,
        uintConfigs: [HybridUintConfig]
    ) {
        self.lz77 = lz77
        self.contextMap = contextMap
        self.usePrefixCode = usePrefixCode
        self.logAlphaSize = logAlphaSize
        self.uintConfigs = uintConfigs
    }

    /// Number of distinct clusters referenced by the context map —
    /// equivalently, the number of histograms that follow this header
    /// in the codestream.
    public var numHistograms: Int { contextMap.numClusters }

    /// Read fields 1–6 of an entropy section. `numContexts` is the
    /// total number of context indices the surrounding consumer
    /// expects (LZ77 adds one extra implicit context for the
    /// distance — the caller doesn't need to compensate for that).
    public static func read(
        from r: inout BitReader,
        numContexts: Int
    ) throws -> EntropySectionHeader {
        // 1. LZ77.
        let lz77: LZ77Config
        do { lz77 = try LZ77Config.read(from: &r) }
        catch let e as LZ77ConfigError {
            throw EntropySectionHeaderError.lz77(e)
        }

        // 2. LZ77 adds an implicit extra context for the distance
        //    distribution.
        var effectiveContexts = numContexts
        if lz77.enabled {
            effectiveContexts &+= 1
            // length_uint_config is *part of* lz77 already (read at
            // log_alpha_size=8 inside LZ77Config.read). Nothing to do
            // here.
        }

        // 3. Context map.
        let contextMap: ContextMap
        if effectiveContexts <= 1 {
            contextMap = ContextMap.trivial(numContexts: max(0, effectiveContexts))
        } else {
            do {
                contextMap = try ContextMap.read(
                    numContexts: effectiveContexts, from: &r
                )
            } catch let e as ContextMapError {
                throw EntropySectionHeaderError.contextMap(e)
            }
        }

        // 4. use_prefix_code.
        let usePrefix: Bool
        do { usePrefix = try r.readBit() }
        catch let e as BitstreamError {
            throw EntropySectionHeaderError.bitstream(e)
        }

        // 5. log_alpha_size.
        let logAlpha: Int
        if usePrefix {
            logAlpha = prefixMaxBits
        } else {
            do {
                logAlpha = 5 + Int(try r.read(bits: 2))
            } catch let e as BitstreamError {
                throw EntropySectionHeaderError.bitstream(e)
            }
        }

        // 6. uint_configs[num_histograms].
        let n = contextMap.numClusters
        var configs = [HybridUintConfig]()
        configs.reserveCapacity(n)
        for _ in 0..<n {
            do {
                configs.append(try HybridUintConfig.read(
                    from: &r, logAlpha: logAlpha
                ))
            } catch let e as HybridUintConfigError {
                throw EntropySectionHeaderError.hybridConfig(e)
            }
        }

        return EntropySectionHeader(
            lz77: lz77, contextMap: contextMap,
            usePrefixCode: usePrefix, logAlphaSize: logAlpha,
            uintConfigs: configs
        )
    }

    /// Write fields 1–6 of an entropy section. `numContexts` matches
    /// what the reader will pass.
    public func write(to w: inout BitWriter, numContexts: Int) throws {
        do { try lz77.write(to: &w) }
        catch let e as LZ77ConfigError {
            throw EntropySectionHeaderError.lz77(e)
        }
        var effective = numContexts
        if lz77.enabled { effective &+= 1 }
        if effective > 1 {
            do { try contextMap.write(to: &w) }
            catch let e as ContextMapError {
                throw EntropySectionHeaderError.contextMap(e)
            }
        }
        w.writeBit(usePrefixCode)
        if !usePrefixCode {
            // log_alpha_size = 5 + u(2). Encode (logAlphaSize - 5).
            let extra = max(0, logAlphaSize - 5)
            w.write(bits: 2, value: UInt32(extra))
        }
        for cfg in uintConfigs {
            do { try cfg.write(to: &w, logAlpha: logAlphaSize) }
            catch let e as HybridUintConfigError {
                throw EntropySectionHeaderError.hybridConfig(e)
            }
        }
    }
}
