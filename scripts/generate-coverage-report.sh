#!/bin/bash
# Generate code coverage report for JXLSwift
#
# This script runs tests with coverage enabled and generates a human-readable
# coverage report. It can be run locally or in CI.
#
# Requirements:
# - Swift 6.2+
# - llvm-cov (available on macOS via Xcode command line tools)
#
# Usage:
#   ./scripts/generate-coverage-report.sh [--html] [--threshold N]
#
# Options:
#   --html          Generate HTML report (in addition to text summary)
#   --threshold N   Fail if coverage is below N% (default: 95)
#   --help          Show this help message

set -e

# Default configuration
THRESHOLD=95
GENERATE_HTML=0
BUILD_DIR=".build/debug"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --html)
            GENERATE_HTML=1
            shift
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --help)
            head -n 20 "$0" | grep '^#' | sed 's/^# //;s/^#//'
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "========================================"
echo "JXLSwift Code Coverage Report Generator"
echo "========================================"
echo ""

# Step 1: Clean previous coverage data
echo "[1/4] Cleaning previous coverage data..."
rm -rf "$BUILD_DIR/codecov" coverage.lcov coverage.json coverage_report/ 2>/dev/null || true

# Step 2: Run tests with coverage enabled
echo "[2/4] Running tests with coverage enabled..."
echo "  (Skipping Performance, Benchmark, and MetalComputeTests for speed)"
swift test --enable-code-coverage \
    --skip Performance \
    --skip Benchmark \
    --skip MetalComputeTests \
    --parallel || {
    echo "❌ Tests failed. Cannot generate coverage report."
    exit 1
}

echo ""
echo "✅ Tests passed successfully"
echo ""

# Step 3: Find the test binary and coverage data
echo "[3/4] Locating coverage data..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    TEST_BINARY=$(find "$BUILD_DIR" -name "JXLSwiftPackageTests.xctest" -type d | head -1)
    if [ -z "$TEST_BINARY" ]; then
        echo "❌ Could not find test binary"
        exit 1
    fi
    TEST_BINARY="$TEST_BINARY/Contents/MacOS/JXLSwiftPackageTests"
    PROFDATA="$BUILD_DIR/codecov/default.profdata"
else
    # Linux
    TEST_BINARY=$(find "$BUILD_DIR" -name "JXLSwiftPackageTests.xctest" -type f | head -1)
    if [ -z "$TEST_BINARY" ]; then
        echo "❌ Could not find test binary"
        exit 1
    fi
    PROFDATA="$BUILD_DIR/codecov/default.profdata"
fi

if [ ! -f "$PROFDATA" ]; then
    echo "❌ Could not find coverage profdata at: $PROFDATA"
    exit 1
fi

echo "  Test binary: $TEST_BINARY"
echo "  Profile data: $PROFDATA"
echo ""

# Step 4: Generate coverage reports
echo "[4/4] Generating coverage reports..."

# Try to find llvm-cov
LLVM_COV=""
if command -v xcrun &> /dev/null && xcrun --find llvm-cov &> /dev/null; then
    LLVM_COV="xcrun llvm-cov"
elif command -v llvm-cov &> /dev/null; then
    LLVM_COV="llvm-cov"
else
    echo "❌ llvm-cov not found. Install Xcode command line tools on macOS or llvm on Linux."
    exit 1
fi

# Export coverage in JSON format for parsing
$LLVM_COV export \
    -format=lcov \
    -instr-profile="$PROFDATA" \
    "$TEST_BINARY" \
    > coverage.lcov 2>/dev/null || {
    echo "❌ Failed to export coverage data"
    exit 1
}

# Generate text report
$LLVM_COV report \
    -instr-profile="$PROFDATA" \
    "$TEST_BINARY" \
    > coverage_report.txt 2>/dev/null || {
    echo "⚠️  Failed to generate text report (non-fatal)"
}

# Generate HTML report if requested
if [ $GENERATE_HTML -eq 1 ]; then
    echo "  Generating HTML report..."
    $LLVM_COV show \
        -format=html \
        -instr-profile="$PROFDATA" \
        -output-dir=coverage_report \
        "$TEST_BINARY" \
        2>/dev/null || {
        echo "⚠️  Failed to generate HTML report (non-fatal)"
    }
    
    if [ -d "coverage_report" ]; then
        echo "  📊 HTML report generated: coverage_report/index.html"
    fi
fi

echo ""
echo "========================================"
echo "Coverage Summary"
echo "========================================"
echo ""

# Extract coverage percentage from the report
if [ -f coverage_report.txt ]; then
    # Display the summary
    tail -n 5 coverage_report.txt
    echo ""
    
    # Extract total coverage percentage
    COVERAGE=$(tail -n 1 coverage_report.txt | grep -oE '[0-9]+\.[0-9]+%' | head -1 | sed 's/%//')
    
    if [ -z "$COVERAGE" ]; then
        echo "⚠️  Could not parse coverage percentage"
        exit 0
    fi
    
    echo "Total Coverage: ${COVERAGE}%"
    echo "Threshold: ${THRESHOLD}%"
    echo ""
    
    # Compare with threshold
    if (( $(echo "$COVERAGE >= $THRESHOLD" | bc -l) )); then
        echo "✅ Coverage meets threshold (${COVERAGE}% >= ${THRESHOLD}%)"
        echo ""
        echo "Coverage data saved:"
        echo "  - coverage.lcov (LCOV format)"
        echo "  - coverage_report.txt (text summary)"
        [ $GENERATE_HTML -eq 1 ] && echo "  - coverage_report/ (HTML report)"
        exit 0
    else
        echo "❌ Coverage below threshold (${COVERAGE}% < ${THRESHOLD}%)"
        echo ""
        echo "To see detailed coverage breakdown:"
        if [ $GENERATE_HTML -eq 1 ]; then
            echo "  open coverage_report/index.html"
        else
            echo "  cat coverage_report.txt"
            echo "  or run with --html flag for detailed HTML report"
        fi
        exit 1
    fi
else
    echo "⚠️  Coverage report not generated, but LCOV data is available"
    echo ""
    echo "Coverage data saved:"
    echo "  - coverage.lcov (LCOV format)"
    exit 0
fi
