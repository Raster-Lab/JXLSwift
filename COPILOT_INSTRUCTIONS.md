# Copilot Instructions — JXLSwift

> Practical and strict guidelines for all contributors and AI assistants working on this codebase.

---

## Goal

Implement a JPEG XL encode/decode library in Swift. Maintain two backends:

| Backend | Role | Status |
|---------|------|--------|
| **LibJXL** | Reference C++ implementation (via C shim) | Planned |
| **Native** | Pure Swift implementation (in-progress) | Active |

The **public API must be backend-agnostic**. Consumers should never need to know which backend is in use.

---

## Scope of Work

> **You must only work on tasks that are explicitly defined in [`MILESTONES.md`](MILESTONES.md).**

- **Do not** implement features, fix bugs, refactor code, add tests, or make any other changes that are not part of a milestone listed in `MILESTONES.md`.
- **Do not** add new milestones, deliverables, or acceptance criteria without explicit instruction from the project maintainer.
- Before starting any task, verify that it maps to an active (⬜ Not Started or 🔶 In Progress) milestone in `MILESTONES.md`.
- If a requested task falls outside the defined milestones, **stop and ask the maintainer** rather than proceeding.

---

## Architecture Rules

### No UI Frameworks in Core Targets

Never import `UIKit`, `AppKit`, `SwiftUI`, or any UI framework into the `JXLSwift` core library target. Use **optional adapter targets** (e.g., `JXLSwiftUIKit`, `JXLSwiftAppKit`) for platform-specific image type conversions.

### Memory-Bounded Operations

All decode/encode functions must be **memory-bounded**:

- **Avoid full-image copies** unless absolutely necessary.
- **Prefer tiling**: process image data in tiles (e.g., 256×256 or configurable).
- **Prefer in-place operations**: use `inout` parameters and mutating methods.
- Use `PixelBuffer` for zero-copy access to pixel data where possible.
- Document peak memory usage for each pipeline stage.

### Backend-Agnostic Public API

```swift
// ✅ Good — backend-agnostic
let encoder = JXLEncoder(options: options)
let result = try encoder.encode(frame)

// ❌ Bad — leaks backend details
let encoder = LibJXLEncoder(handle: cHandle)
```

All public types (`JXLEncoder`, `JXLDecoder`, `PixelBuffer`, `EncodingOptions`) must work identically regardless of backend selection.

---

## Testing Requirements

### Compare Against LibJXL Output Buffers

Add tests for every new native encoding/decoding stage that compare output against the LibJXL reference backend:

- Use **deterministic seeds** and **fixed input vectors** (no random data in tests).
- Store expected output as byte arrays or test fixtures.
- Tolerance: exact match for lossless, documented epsilon for lossy (typically `1e-5` for float, `±1` for uint8).

### Test Every New Stage

```swift
func testNativeDCT_MatchesReference() throws {
    let input: [Float] = [/* fixed 8×8 block */]
    let expected: [Float] = [/* known-good DCT output */]
    let result = NativeDCT.forward(input, size: 8)

    for i in 0..<result.count {
        XCTAssertEqual(result[i], expected[i], accuracy: 1e-5,
                       "DCT coefficient \(i) mismatch")
    }
}
```

---

## Optimization Workflow

When adding optimizations, follow this strict order:

### 1. Scalar Reference Implementation First

Provide a correct, readable, platform-independent scalar implementation. This is the source of truth.

### 2. Then Add Hardware-Accelerated Paths

Add NEON (arm64) and SSE2/AVX2 (x86_64) behind capability dispatch:

```swift
func applyDCT(block: PixelBuffer.Tile) -> [Float] {
    switch DispatchBackend.current {
    case .neon:
        return applyDCT_NEON(block)
    case .sse2, .avx2:
        return applyDCT_SSE(block)
    case .accelerate:
        return applyDCT_Accelerate(block)
    case .scalar:
        return applyDCT_Scalar(block)
    }
}
```

### 3. Keep Identical Numerics

- Hardware-accelerated paths must produce results identical to the scalar reference (within documented tolerance).
- If numerics differ, document the tolerated epsilon and the reason (e.g., FMA vs separate multiply-add).
- Tests must verify numeric equivalence.

---

## Metal Kernel Rules

All Metal compute shaders must:

1. **Batch work in tiles** — process data in tile-sized chunks, not one pixel at a time.
2. **Minimize CPU↔GPU transfers** — upload once, process multiple stages on GPU, download once.
3. **Have a CPU fallback path** — every Metal kernel must have an equivalent CPU implementation that produces identical output.
4. **Manage memory explicitly** — release GPU buffers promptly; document peak GPU memory usage.

---

## Benchmark Requirements

Add benchmarks for every encoding/decoding stage and record:

| Metric | Description |
|--------|-------------|
| **MP/s** | Megapixels per second throughput |
| **Allocations** | Number and total size of heap allocations |
| **Peak RSS** | Peak resident set size during operation |

```swift
func benchmarkDCT_8x8() {
    let block = PixelBuffer.Tile(originX: 0, originY: 0, width: 8, height: 8)
    measure {
        for _ in 0..<10_000 {
            _ = applyDCT(block: block)
        }
    }
    // Record: MP/s, allocations, peak RSS
}
```

---

## Backend Dispatch Layer

Use `DispatchBackend` to select the optimal implementation at runtime without `#if` spaghetti:

```swift
public enum DispatchBackend: Sendable {
    case scalar      // Always available — reference implementation
    case neon        // ARM64 NEON SIMD
    case sse2        // x86_64 SSE2
    case avx2        // x86_64 AVX2
    case accelerate  // Apple Accelerate framework
    case metal       // Metal GPU compute

    /// Auto-detect the best available backend for the current platform.
    public static var current: DispatchBackend { /* ... */ }
}
```

All architecture-specific code is routed through this dispatcher. The `#if arch()` guards live only inside the dispatcher, not scattered throughout the codebase.

---

## PixelBuffer

`PixelBuffer` is the canonical type for passing pixel data through the pipeline:

- **Tiled access**: supports iteration over tiles for memory-bounded processing.
- **Zero-copy**: wraps existing memory where possible (e.g., `CVPixelBuffer`, `vImage_Buffer`).
- **Backend-agnostic**: works with both LibJXL and Native backends.
- **Type-safe**: parameterized by pixel type (`UInt8`, `UInt16`, `Float`).

---

## Code Quality

- All public APIs must have `///` documentation comments.
- No force unwraps (`!`) or force casts (`as!`) in production code.
- `Sendable` conformance for types crossing concurrency boundaries.
- Build with `StrictConcurrency` enabled (already configured).
- See `.github/copilot-instructions.md` for detailed Swift coding guidelines.

---

## Documentation Updates on Feature Changes

Every feature addition, modification, or removal **must** include updates to:

### README.md
- **Features** list — add/update entries for new capabilities.
- **Usage** section — add or revise code examples.
- **Architecture** tree — reflect new modules or files.
- **Roadmap** checklist — mark items as completed (`- [x]`) or add new planned items.
- **Requirements** / **Performance** sections — update if affected.

### MILESTONES.md
- **Milestone Overview table** — update status (⬜ → 🔶 → ✅).
- **Deliverable checklists** — check off completed items (`- [x]`).
- **Test checklists** — check off tests that now pass.
- Add new deliverables or tests if the feature introduces previously unlisted work.

Documentation updates must ship in the **same commit or pull request** as the code change. Do not defer them to a follow-up task. Keep the README roadmap in sync with the MILESTONES.md overview table.
