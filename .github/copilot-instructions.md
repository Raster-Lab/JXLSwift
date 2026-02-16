# Copilot Instructions for JXLSwift

## Project Overview

JXLSwift is a native Swift implementation of the JPEG XL (ISO/IEC 18181) compression codec, optimized for Apple Silicon. The library provides both lossless (Modular) and lossy (VarDCT) compression modes with zero C/C++ dependencies.

**Platforms:** macOS 13+, iOS 16+, tvOS 16+, watchOS 9+, visionOS 1+
**Swift version:** 6.0+ with strict concurrency enabled

---

## Unit Test Coverage

### Coverage Target: 95% and Above

- Every public and internal API **must** have associated unit tests.
- Every new function, method, or type **must** include tests covering:
  - Normal/expected inputs (happy path).
  - Edge cases (empty data, zero dimensions, boundary values, maximum values).
  - Error conditions (invalid inputs, thrown errors, failure paths).
- Use `XCTAssertThrowsError` to verify that functions throw the correct error types and messages.
- Use `XCTAssertNoThrow` to confirm functions succeed for valid inputs.
- Use `XCTAssertEqual` with `accuracy:` for floating-point comparisons.
- Test all branches in `switch` statements and `if/else` chains.
- Test all `enum` cases, including associated values.

### Test Organization

- Group tests using `// MARK: -` sections that mirror the source file structure.
- Name tests descriptively: `test<Unit>_<Scenario>_<ExpectedResult>` (e.g., `testEncoder_InvalidDimensions_ThrowsError`).
- Place tests in `Tests/JXLSwiftTests/` following the existing `XCTest` conventions.
- Create separate test files per source module to keep files focused and readable:
  - `BitstreamTests.swift` for `Core/Bitstream.swift`
  - `ImageFrameTests.swift` for `Core/ImageFrame.swift`
  - `EncoderTests.swift` for `Encoding/Encoder.swift`
  - `ModularEncoderTests.swift` for `Encoding/ModularEncoder.swift`
  - `VarDCTEncoderTests.swift` for `Encoding/VarDCTEncoder.swift`

### What to Test

- **Core types:** `ImageFrame`, `BitstreamWriter`, `BitstreamReader`, `EncodingOptions`, `CompressionMode`, `EncodingEffort`, `PixelType`, `ColorSpace`, `ColorPrimaries`, `TransferFunction`.
- **Encoding pipeline:** `JXLEncoder.encode(_:)`, lossless and lossy paths, validation logic, quality-to-distance conversion.
- **Bitstream operations:** Bit writing/reading, byte alignment, varint encoding, signature writing, image header writing.
- **Pixel operations:** `getPixel`/`setPixel` for all `PixelType` variants (`uint8`, `uint16`, `float32`), boundary pixels, planar format indexing.
- **Hardware detection:** `CPUArchitecture.current`, `HardwareCapabilities.detect()`, all capability flags.
- **Accelerate operations:** Vector math, DCT transforms, matrix operations, type conversions (when `Accelerate` is available).
- **Error handling:** Every `EncoderError` case, invalid frame dimensions, unsupported channel counts.
- **Statistics:** `CompressionStats.compressionRatio`, edge case with zero original size.

---

## Performance

### Performance as a Core Value

- **Measure before optimizing.** Use `measure {}` blocks in `XCTestCase` for performance-critical paths.
- **Avoid unnecessary allocations.** Prefer `inout` parameters and mutating methods over creating new collections.
- **Use value types** (`struct`, `enum`) over reference types (`class`) unless shared mutable state is required.
- **Prefer contiguous memory.** Use `[UInt8]`, `Data`, and `UnsafeBufferPointer` for pixel data instead of nested arrays.
- **Leverage Accelerate framework** for vector/matrix operations via `vDSP` instead of manual loops.
- **Use lazy sequences** (`lazy.map`, `lazy.filter`) when processing large collections where not all results are needed.
- **Minimize copies.** Use `copy-on-write` semantics properly; avoid unnecessary `let` copies of large arrays.
- **Profile encoding pipelines.** DCT transforms, quantization, and entropy encoding are hot paths — always benchmark changes to these.
- **Include performance tests** for:
  - Encoding small images (8×8, 16×16).
  - Encoding medium images (256×256).
  - Bitstream throughput (writing millions of bits).
  - Pixel access patterns (sequential vs. random).

### Performance Test Guidelines

```swift
func testEncodingPerformance_SmallImage() throws {
    let encoder = JXLEncoder(options: .fast)
    var frame = ImageFrame(width: 64, height: 64, channels: 3)
    // Fill frame with test data...
    measure {
        _ = try? encoder.encode(frame)
    }
}
```

- Set baseline metrics in Xcode for regression detection.
- Performance tests must not regress by more than 10% in median execution time. Document the reason for any accepted regression in the PR description and obtain reviewer approval.

---

## Swift Best Practices

### API Design

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Name methods and properties using clear, descriptive English phrases.
- Use argument labels that read naturally at the call site: `encoder.encode(frame)`, not `encoder.encode(f:)`.
- Prefer method names that describe the effect or return value: `convertToYCbCr(frame:)`, `applyDCT(block:)`.
- Document all `public` APIs with `///` doc comments including `- Parameters:`, `- Returns:`, and `- Throws:` sections.

### Type Safety

- Use strong types over primitives: prefer `PixelType` enum over raw `Int`, `ColorSpace` over `String`.
- Use `Int` for sizes and counts; use `UInt8`, `UInt16`, `UInt32` only for binary data and bitstream operations.
- Avoid force unwrapping (`!`). Use `guard let`, `if let`, or `nil` coalescing (`??`) with sensible defaults.
- Avoid force casting (`as!`). Use `as?` with proper error handling.

### Error Handling

- Use typed errors conforming to `Error` and `LocalizedError`.
- Throw descriptive errors: prefer `EncoderError.invalidImageDimensions` over generic `NSError`.
- Handle errors at the appropriate level — don't swallow errors silently.
- Use `Result<Success, Failure>` for asynchronous operations if not using `async/await`.

### Concurrency and Thread Safety

- Conform shared types to `Sendable` (e.g., `EncodingOptions`, `HardwareCapabilities`, `CompressionStats`).
- Use `@Sendable` closures when crossing concurrency boundaries.
- Avoid mutable global state. Use dependency injection for `HardwareCapabilities`.
- Mark types that are not meant to be shared across threads as non-`Sendable` explicitly when needed.
- Build with `StrictConcurrency` enabled (already configured in `Package.swift`).

### Memory Management

- Use value types (`struct`) for data containers like `ImageFrame`, `BitstreamWriter`, `EncodingOptions`.
- Use `class` only when identity semantics or inheritance is required (e.g., `JXLEncoder`).
- Avoid retain cycles in closures: use `[weak self]` or `[unowned self]` where appropriate.
- For large buffers, consider `Data` or `UnsafeMutableBufferPointer` to reduce overhead.

### Code Organization

- One primary type per file. Supporting types may coexist if tightly coupled.
- Use `// MARK: -` sections to organize methods within a file.
- Use extensions to separate protocol conformances and logically distinct functionality.
- Keep functions short and focused — extract helper methods for complex logic.
- Place `private` and `internal` helpers below `public` API methods.

### Conditional Compilation

- Use `#if arch(arm64)` / `#elseif arch(x86_64)` for architecture-specific code.
- Use `#if canImport(Accelerate)` for optional framework dependencies.
- Always provide a fallback/scalar implementation for every hardware-optimized path.
- Keep platform-specific code isolated in the `Hardware/` module.

### Swift 6 Compatibility

- Enable and respect strict concurrency checking.
- Avoid using deprecated APIs.
- Use structured concurrency (`async/await`, `TaskGroup`) for parallel operations where applicable.
- Ensure all public types that cross concurrency domains conform to `Sendable`.

---

## Code Review Checklist

When reviewing or generating code, verify:

- [ ] All public APIs have `///` documentation comments.
- [ ] Unit tests cover the new code with ≥ 95% branch coverage.
- [ ] Performance-sensitive code includes `measure {}` benchmarks.
- [ ] Error cases are tested with `XCTAssertThrowsError`.
- [ ] Edge cases (empty input, zero dimensions, max values) are tested.
- [ ] No force unwraps (`!`) or force casts (`as!`) in production code.
- [ ] `Sendable` conformance is correct for types crossing concurrency boundaries.
- [ ] Architecture-specific code has `#if` guards and scalar fallbacks.
- [ ] New dependencies are justified and minimal (prefer zero-dependency approach).
- [ ] Functions are focused, short, and descriptively named.
