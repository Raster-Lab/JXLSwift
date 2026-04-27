// SimpleEntropyStream — single-context end-to-end value coder.
//
// This is the integration milestone for the entropy primitives layer:
// it wires `HybridUintConfig` (§C.5) + `ANSDistribution` (§C.6.3) +
// `ANSDistributionFormat` (§C.6.3.2) + `HybridUintConfig` serialisation
// (§C.5.1) into a single "encode this UInt32 stream into bytes; decode
// bytes back into UInt32 stream" round-trip path.
//
// **Single-context only.** The full JXL codestream uses *many* rANS
// contexts (one per Modular tree leaf, etc.), with histogram clustering
// (§C.6.4) deciding which context applies to each token. That layer
// isn't built yet. SimpleEntropyStream covers the simpler case where
// every token in the stream uses the same distribution and the same
// HybridUintConfig — useful as a building block and as a sanity check
// that all the primitives compose.
//
// **Bitstream layout (this implementation)** — *not* a JXL-codestream-
// level spec layout. The codestream-level layout (with multi-context
// dispatch and LZ77) is built on top of these primitives in later
// phases.
//
//     alphabet_size       u(15)            // tokens up to 32 767
//     HybridUintConfig                     // §C.5.1, sized to ceilLog2(alphabet_size)
//     ANSDistribution                      // §C.6.3.2 simple/flat shortcut
//     num_values          u(32)
//     extra_bits_length   u(32)            // byte length of the extra-bits stream
//     align to byte
//     extra_bits stream   variable         // u(extra_nbits) per value, in order
//     align to byte
//     rANS bytes          variable         // §C.6.3 byte stream; consumes tail
//
// The extra-bits length lets the decoder split the tail cleanly into
// (extra_bits_bytes ‖ rANS_bytes); the rANS section consumes whatever
// bytes remain after the extra-bits region.

import Foundation

public enum SimpleEntropyStreamError: Error, Sendable {
    case alphabetTooLarge(Int)
    case truncated
    case anscode(ANSError)
    case ansdist(ANSDistributionFormatError)
    case hybridConfig(HybridUintConfigError)
    case bitstream(BitstreamError)
}

/// One rANS context: the alphabet, the HybridUintConfig used to
/// translate values↔tokens, and the ANSDistribution used to entropy-
/// code those tokens.
public struct SimpleEntropyContext: Sendable {
    public let alphabetSize: Int
    public let hybridConfig: HybridUintConfig
    public let distribution: ANSDistribution

    public init(alphabetSize: Int,
                hybridConfig: HybridUintConfig,
                distribution: ANSDistribution) {
        self.alphabetSize = alphabetSize
        self.hybridConfig = hybridConfig
        self.distribution = distribution
    }

    /// log2(alphabet_size), ceiling. Used to size the HybridUintConfig
    /// fields when serialising.
    public var logAlpha: Int { Int(ceilLog2(UInt32(alphabetSize))) }
}

/// Distribution-shape selector for SimpleEntropyStream.encode. The
/// caller picks one of the §C.6.3.2 shortcut shapes.
public enum SimpleEntropyDistributionShape: Sendable {
    /// Flat / uniform distribution over the alphabet.
    case flat
    /// Simple distribution: 1–4 named symbols receive the predefined
    /// frequency splits (`[tab]`, `[tab/2]×2`, `[tab/4, tab/4, tab/2]`,
    /// `[tab/4]×4`). The associated `ANSDistribution` must match that
    /// shape — the distribution stored in the buffer is the simple
    /// header, not arbitrary frequencies.
    case simple(symbols: [Int])
}

public struct SimpleEntropyStream {

    /// Encode a stream of values into a self-describing byte buffer.
    /// The caller supplies the rANS distribution and HybridUintConfig
    /// to use; this function packs them into the output along with the
    /// rANS-coded tokens and the extra-bits stream.
    public static func encode(
        values: [UInt32],
        context: SimpleEntropyContext,
        shape: SimpleEntropyDistributionShape = .flat
    ) throws -> Data {
        guard context.alphabetSize > 0 && context.alphabetSize < (1 << 15) else {
            throw SimpleEntropyStreamError.alphabetTooLarge(context.alphabetSize)
        }

        // First pass: split each value into (token, extra_bits, extra_nbits).
        // We'll need the tokens for rANS (later) and the extra bits for
        // the forward stream (also later, once we know its byte length).
        var tokens: [UInt32] = []
        tokens.reserveCapacity(values.count)
        var extras: [(bits: UInt32, n: Int)] = []
        extras.reserveCapacity(values.count)
        for v in values {
            let t = context.hybridConfig.encode(v)
            tokens.append(t.token)
            if t.extraNBits > 0 {
                extras.append((bits: t.extraBits, n: t.extraNBits))
            }
        }

        // Build the extra-bits stream and finalise it so we know its
        // byte length (needed for the header).
        var ew = BitWriter()
        for e in extras {
            ew.write(bits: e.n, value: e.bits)
        }
        let extraData = ew.finishToData()

        // rANS-encode the token sequence and finalise to bytes.
        var ansEnc = ANSEncoder(distribution: context.distribution)
        for tok in tokens {
            do { try ansEnc.write(Int(tok)) }
            catch let e as ANSError { throw SimpleEntropyStreamError.anscode(e) }
        }
        let ransData = ansEnc.finish()

        // Now build the header.
        var w = BitWriter()
        w.write(bits: 15, value: UInt32(context.alphabetSize))
        do { try context.hybridConfig.write(to: &w, logAlpha: context.logAlpha) }
        catch let e as HybridUintConfigError {
            throw SimpleEntropyStreamError.hybridConfig(e)
        }
        do {
            switch shape {
            case .flat:
                try ANSDistributionFormat.encodeFlat(
                    alphabetSize: context.alphabetSize, to: &w
                )
            case .simple(let syms):
                try ANSDistributionFormat.encodeSimple(
                    symbols: syms, alphabetSize: context.alphabetSize, to: &w
                )
            }
        } catch let e as ANSDistributionFormatError {
            throw SimpleEntropyStreamError.ansdist(e)
        }
        w.write(bits: 32, value: UInt32(values.count))
        w.write(bits: 32, value: UInt32(extraData.count))
        w.alignToByte()

        var out = w.finishToData()
        out.append(extraData)
        out.append(ransData)
        return out
    }

    /// Decode the byte buffer back to a stream of values.
    public static func decode(_ data: Data) throws -> [UInt32] {
        var r = BitReader(data)

        // Header.
        let alphabetSize: Int
        do { alphabetSize = Int(try r.read(bits: 15)) }
        catch let e as BitstreamError { throw SimpleEntropyStreamError.bitstream(e) }
        guard alphabetSize > 0 && alphabetSize < (1 << 15) else {
            throw SimpleEntropyStreamError.alphabetTooLarge(alphabetSize)
        }
        let logAlpha = Int(ceilLog2(UInt32(alphabetSize)))
        let hybridConfig: HybridUintConfig
        do { hybridConfig = try HybridUintConfig.read(from: &r, logAlpha: logAlpha) }
        catch let e as HybridUintConfigError { throw SimpleEntropyStreamError.hybridConfig(e) }
        let distribution: ANSDistribution
        do {
            distribution = try ANSDistributionFormat.decode(
                alphabetSize: alphabetSize, from: &r
            )
        } catch let e as ANSDistributionFormatError {
            throw SimpleEntropyStreamError.ansdist(e)
        }
        let numValues: Int
        let extraByteLen: Int
        do {
            numValues = Int(try r.read(bits: 32))
            extraByteLen = Int(try r.read(bits: 32))
        } catch let e as BitstreamError {
            throw SimpleEntropyStreamError.bitstream(e)
        }
        do { try r.alignToByte() }
        catch let e as BitstreamError { throw SimpleEntropyStreamError.bitstream(e) }

        // Slice out (extra-bits bytes ‖ rANS bytes). After alignToByte
        // the reader's bit position is on a byte boundary, so dividing
        // by 8 gives the byte-level cursor.
        let bytePosition = r.position / 8
        guard data.count >= bytePosition + extraByteLen else {
            throw SimpleEntropyStreamError.truncated
        }
        let extraSlice = data.subdata(
            in: (data.startIndex + bytePosition)
              ..< (data.startIndex + bytePosition + extraByteLen)
        )
        let ransSlice = data.subdata(
            in: (data.startIndex + bytePosition + extraByteLen)
              ..< data.endIndex
        )

        var extraReader = BitReader(extraSlice)
        var ansDec: ANSDecoder
        do {
            ansDec = try ANSDecoder(data: ransSlice, distribution: distribution)
        } catch let e as ANSError { throw SimpleEntropyStreamError.anscode(e) }

        // Decode in lockstep: pull each token from rANS, recover its
        // value via the HybridUintConfig (which reads extra_nbits from
        // the extra-bits stream as needed).
        var values: [UInt32] = []
        values.reserveCapacity(numValues)
        for _ in 0..<numValues {
            let tok: Int
            do { tok = try ansDec.read() }
            catch let e as ANSError { throw SimpleEntropyStreamError.anscode(e) }
            let v: UInt32
            do { v = try hybridConfig.decode(token: UInt32(tok), from: &extraReader) }
            catch let e as BitstreamError { throw SimpleEntropyStreamError.bitstream(e) }
            values.append(v)
        }
        return values
    }
}
