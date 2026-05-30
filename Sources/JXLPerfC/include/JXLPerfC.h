// JXLPerfC — measured-hot-path C primitives for JXLSwift.
//
// CLAUDE.md constraint 1 (amended 2026-05): C/C++ is permitted ONLY for a
// performance-critical hot path that profiling has shown to matter, behind a
// clean abstraction boundary, with the scalar Swift implementation remaining
// the source of truth. Every function here must be byte-equivalent to a Swift
// scalar reference (verified by tests) and the C path must be deletable
// without disturbing the core.
//
// **Status (scaffolding):** the v0.14.0 perf analysis identified the rANS
// entropy encoder + BitWriter as the irreducible-under-byte-identity floor on
// the Swift side; this target is the boundary across which the hot path can
// be reimplemented in C. The functions below (`jxlperf_c_version`,
// `jxlperf_fnv1a`) are proof-of-life only — they confirm the SwiftPM C target
// compiles + links + the Swift↔C bridge round-trips byte buffers correctly.
// The first real hot path to drop in here is the `BitWriter`
// UInt64-accumulator (see `Documentation/PERFORMANCE-ANALYSIS.md` roadmap).
//
// Byte-identity discipline: every function added here MUST ship with a
// Swift-vs-C equivalence test asserting bit-for-bit equality over a
// reasonable input set, plus the existing 695-test djxl-exact suite + the
// 2 867-image medical DICOM + 49-image CID22 validation as the integration
// gates. If C output ever diverges from scalar Swift, the C path is reverted
// — the scalar reference wins.

#ifndef JXLPERFC_H
#define JXLPERFC_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Build-time version probe of the C target's ABI (currently 1). Used by
/// tests to confirm the SwiftPM C target compiles, links, and is callable
/// from Swift. Bumped whenever the C ABI surface changes incompatibly.
int jxlperf_c_version(void);

/// 64-bit FNV-1a hash of `len` bytes from `buf`. A pure, deterministic
/// utility used by `Tests/JXLSwiftTests/CPerfBridgeTests.swift` to verify
/// that byte buffers cross the C/Swift bridge with full fidelity (length,
/// content, alignment). `buf` may be `NULL` only when `len == 0`.
uint64_t jxlperf_fnv1a(const uint8_t *buf, size_t len);

#ifdef __cplusplus
}
#endif

#endif // JXLPERFC_H
