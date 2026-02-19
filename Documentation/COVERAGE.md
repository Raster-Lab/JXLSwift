# Code Coverage Verification

This document describes the code coverage verification process for JXLSwift, including how to generate coverage reports and interpret the results.

## Overview

JXLSwift maintains a **95%+ code coverage target** for all public and internal APIs. This ensures that the library is thoroughly tested and reliable for production use.

## Quick Start

### Generate Coverage Report

```bash
# Text-based coverage summary
make coverage

# HTML coverage report with line-by-line analysis
make coverage-html
```

### View Coverage Results

After running `make coverage-html`, open the generated HTML report:

```bash
# macOS
open coverage_report/index.html

# Linux
xdg-open coverage_report/index.html
```

## Coverage Script

The coverage generation is handled by `scripts/generate-coverage-report.sh`, which:

1. Cleans previous coverage data
2. Runs tests with `--enable-code-coverage` flag
3. Extracts coverage data using `llvm-cov`
4. Generates text and/or HTML reports
5. Validates coverage against threshold (default: 95%)

### Script Options

```bash
./scripts/generate-coverage-report.sh [OPTIONS]

Options:
  --html          Generate HTML report (in addition to text summary)
  --threshold N   Fail if coverage is below N% (default: 95)
  --help          Show help message
```

### Examples

```bash
# Generate report with 90% threshold
./scripts/generate-coverage-report.sh --threshold 90

# Generate HTML report with custom threshold
./scripts/generate-coverage-report.sh --html --threshold 93
```

## Continuous Integration

Code coverage is automatically generated in CI for every push and pull request. The coverage data is uploaded as an artifact and can be downloaded from the GitHub Actions workflow run.

### CI Coverage Generation

The CI workflow (`.github/workflows/ci.yml`) runs tests with coverage enabled:

```yaml
- name: Test
  run: swift test --enable-code-coverage --skip Performance --skip Benchmark --skip MetalComputeTests

- name: Generate code coverage report
  if: runner.os == 'macOS'
  run: |
    xcrun llvm-cov export -format="lcov" \
      .build/debug/JXLSwiftPackageTests.xctest/Contents/MacOS/JXLSwiftPackageTests \
      -instr-profile .build/debug/codecov/default.profdata \
      > coverage.lcov
```

The generated `coverage.lcov` file is uploaded as an artifact and can be:
- Downloaded and viewed locally
- Integrated with coverage visualization tools (Codecov, Coveralls, etc.)
- Used for historical coverage tracking

## Understanding Coverage Metrics

### Line Coverage

Percentage of executable lines that are executed during tests. This is the primary coverage metric.

```
Total Lines: 10,000
Covered Lines: 9,600
Line Coverage: 96.0%
```

### Function Coverage

Percentage of functions that are called at least once during tests.

```
Total Functions: 500
Covered Functions: 485
Function Coverage: 97.0%
```

### Region Coverage

Percentage of code regions (branches, loops, conditionals) that are executed. This is a more fine-grained metric than line coverage.

```
Total Regions: 15,000
Covered Regions: 14,400
Region Coverage: 96.0%
```

## Coverage Guidelines

### What Should Be Covered

✅ **Must have 95%+ coverage:**
- All public APIs
- All internal APIs used by encoders/decoders
- Core data structures (ImageFrame, Bitstream, EncodingOptions)
- Encoding/decoding pipelines (Modular, VarDCT, ANS)
- Error handling paths
- Platform-specific code paths (#if guards)

✅ **Should be tested with various inputs:**
- Normal/expected inputs (happy path)
- Edge cases (empty data, zero dimensions, boundary values)
- Error conditions (invalid inputs, failure paths)
- All enum cases and switch branches

### What May Have Lower Coverage

⚠️ **Acceptable to have lower coverage:**
- Performance benchmark code (skipped in regular test runs)
- Platform-specific code on unsupported platforms
- Defensive error checks that are impossible to trigger in practice
- Debug/diagnostic code paths

### Improving Coverage

If coverage falls below the 95% threshold:

1. **Identify uncovered code:**
   ```bash
   # Generate HTML report
   make coverage-html
   open coverage_report/index.html
   ```

2. **Review uncovered lines:**
   - Navigate to files with low coverage
   - Look for red-highlighted (uncovered) lines
   - Determine if they are reachable code paths

3. **Add missing tests:**
   - Write focused tests for uncovered paths
   - Follow existing test patterns in `Tests/JXLSwiftTests/`
   - Ensure tests are deterministic and fast

4. **Verify improvement:**
   ```bash
   make coverage
   ```

## Test Organization

Tests are organized by module and functionality:

```
Tests/JXLSwiftTests/
├── JXLSwiftTests.swift          # Core types (ImageFrame, Bitstream, etc.)
├── ModularEncoderTests.swift    # Modular mode encoding
├── VarDCTEncoderTests.swift     # VarDCT mode encoding
├── ANSEncoderTests.swift        # ANS entropy coding
├── DecoderTests.swift           # Decoding pipeline
├── FormatTests.swift            # Container format
├── ThreadSafetyTests.swift      # Concurrency
├── FuzzingTests.swift           # Malformed input handling
├── PerformanceTests.swift       # Performance benchmarks
└── ...
```

Each test file should:
- Mirror the structure of its source file with `// MARK:` sections
- Test all public methods and significant internal logic
- Include edge case and error path tests
- Use descriptive test names: `test<Unit>_<Scenario>_<ExpectedResult>`

## Coverage Best Practices

### 1. Test Behavior, Not Implementation

❌ **Bad:** Testing internal state changes
```swift
func testEncoder_InternalStateUpdate() {
    let encoder = Encoder()
    encoder.internalState = 42  // Testing implementation details
    XCTAssertEqual(encoder.internalState, 42)
}
```

✅ **Good:** Testing observable behavior
```swift
func testEncoder_SmallImage_ProducesValidOutput() throws {
    let encoder = Encoder()
    let frame = ImageFrame(width: 8, height: 8, channels: 3)
    let result = try encoder.encode(frame)
    XCTAssertGreaterThan(result.data.count, 0)
    XCTAssertTrue(result.data.starts(with: [0xFF, 0x0A]))
}
```

### 2. Use Parameterized Tests

❌ **Bad:** Separate tests for similar inputs
```swift
func testEncoder_8x8Image() { /* ... */ }
func testEncoder_16x16Image() { /* ... */ }
func testEncoder_32x32Image() { /* ... */ }
```

✅ **Good:** Loop over test cases
```swift
func testEncoder_VariousSizes_AllSucceed() throws {
    let sizes = [(8, 8), (16, 16), (32, 32), (64, 64)]
    for (width, height) in sizes {
        let frame = ImageFrame(width: width, height: height, channels: 3)
        XCTAssertNoThrow(try encoder.encode(frame))
    }
}
```

### 3. Test Error Paths

```swift
func testEncoder_InvalidDimensions_ThrowsError() {
    let encoder = Encoder()
    var frame = ImageFrame(width: 0, height: 0, channels: 3)
    XCTAssertThrowsError(try encoder.encode(frame)) { error in
        XCTAssertEqual(error as? EncoderError, .invalidImageDimensions)
    }
}
```

### 4. Test All Enum Cases

```swift
func testPixelType_AllCases_CanBeCreated() {
    for pixelType in PixelType.allCases {
        let frame = ImageFrame(width: 8, height: 8, channels: 3, pixelType: pixelType)
        XCTAssertEqual(frame.pixelType, pixelType)
    }
}
```

## Troubleshooting

### Coverage Generation Fails

**Problem:** `llvm-cov not found`

**Solution (macOS):**
```bash
xcode-select --install
```

**Solution (Linux):**
```bash
sudo apt-get install llvm
```

### Coverage Data Not Generated

**Problem:** `Could not find coverage profdata`

**Solution:** Ensure tests ran successfully:
```bash
swift test --enable-code-coverage
ls -la .build/debug/codecov/
```

### Low Coverage on Platform-Specific Code

**Problem:** Coverage is low due to `#if arch()` guards

**Solution:** Run tests on multiple platforms:
- macOS ARM64: `macos-15` runner
- macOS x86-64: `macos-15-intel` runner
- Linux x86-64: `ubuntu-latest` runner

## Integration with External Tools

### Codecov

Upload coverage data to Codecov for visualization and tracking:

```bash
# Install codecov tool
brew install codecov

# Upload coverage
codecov -f coverage.lcov
```

### Coveralls

```bash
# Install coveralls tool
gem install coveralls-lcov

# Upload coverage
coveralls-lcov coverage.lcov
```

### VS Code Extensions

Install the **Coverage Gutters** extension to view coverage inline:

1. Install extension: `ryanluker.vscode-coverage-gutters`
2. Generate LCOV coverage: `make coverage`
3. Press `Cmd+Shift+7` to display coverage in editor

## References

- [Swift Testing Guide](https://swift.org/documentation/articles/testing.html)
- [llvm-cov Documentation](https://llvm.org/docs/CommandGuide/llvm-cov.html)
- [LCOV Format Specification](http://ltp.sourceforge.net/coverage/lcov/geninfo.1.php)
- [XCTest Documentation](https://developer.apple.com/documentation/xctest)

---

**Last Updated:** 2026-02-19
**Coverage Target:** 95%+
**Current Status:** ✅ Coverage verification infrastructure in place
