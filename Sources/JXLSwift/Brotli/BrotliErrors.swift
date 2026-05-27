// `Brotli/BrotliErrors.swift` — error taxonomy for the Brotli decoder
// (RFC 7932). Distinct from `BitstreamError` because Brotli has its
// own structural error categories that callers may want to surface
// separately.
//
// Phase J step 5 (reverse direction). v0.12.0fz scaffold.

import Foundation

/// Errors raised by the Brotli decoder while parsing or executing
/// a compressed stream. Mirrors libjxl's `BrotliDecoderErrorCode`
/// at the categorical level — we don't reproduce the full enum
/// because most of libjxl's codes describe runtime conditions
/// (out-of-memory, transformer state) that don't apply to a pure
/// Swift implementation.
public enum BrotliError: Error, Sendable, Equatable {
    /// Underlying bit-reader error (EOF, too many bits, etc.).
    case bitstream(BitstreamError)
    /// A reserved bit had a non-zero value (RFC 7932 §9.1).
    case reservedBitNonZero
    /// Window size `WBITS` is outside the supported range
    /// (10..24 per RFC 7932 §9.1).
    case invalidWindowSize(UInt32)
    /// `MNIBBLES` field has reserved value 0 (RFC 7932 §9.2).
    case reservedMNibbles
    /// Meta-block length `MLEN` is invalid (e.g. 0 outside the
    /// last-empty case, or doesn't match `MNIBBLES` size).
    case invalidMetaBlockLength(String)
    /// Prefix code is malformed — leaf-count mismatch, too-long
    /// code, etc. (RFC 7932 §3.4/§3.5).
    case malformedPrefixCode(String)
    /// Context map decoding produced an invalid value
    /// (RFC 7932 §7.3).
    case malformedContextMap(String)
    /// Distance reference points before the start of the output
    /// buffer (RFC 7932 §4 — invalid back-reference).
    case invalidBackReference(distance: Int, outputSize: Int)
    /// Static dictionary lookup index out of range (RFC 7932 §8).
    case invalidDictionaryIndex(UInt32)
    /// Output buffer overrun — caller-supplied destination too
    /// small to hold the decoded payload.
    case outputBufferOverflow(needed: Int, capacity: Int)
    /// Decoder reached end-of-stream prematurely (e.g. trailing
    /// data in the input buffer past the final meta-block).
    case excessInput(remainingBytes: Int)
    /// A feature in the spec we haven't implemented yet — surface
    /// the missing layer for incremental development. Distinct
    /// from `malformedPrefixCode` etc. so tests can pin down which
    /// implementation gaps are open.
    case notImplemented(String)
}
