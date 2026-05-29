#!/usr/bin/env bash
# benchmark-lossless.sh — establish the lossless encode/decode performance
# baseline across the effort ladder (milestone 4 / Phase O). Reports JXLSwift's
# OWN throughput only — no comparison against other codecs (that has
# legal-exposure considerations; see CLAUDE.md).
#
# Usage:  scripts/benchmark-lossless.sh <input.pnm> [iterations]
#
# Builds release if needed, then sweeps `jxl-tool benchmark --mode lossless`
# over efforts 1/3/5/7/9 so the speed↔ratio trade-off is visible (effort 7 is
# the default and the slowest; 1 is fastest).
set -euo pipefail

INPUT="${1:?usage: benchmark-lossless.sh <input.pnm> [iterations]}"
ITERS="${2:-5}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/jxl-tool"

if [ ! -x "$BIN" ]; then
  echo "building release jxl-tool…"
  (cd "$ROOT" && swift build -c release >/dev/null)
fi

echo "=== lossless baseline: $INPUT (${ITERS}× iterations/effort) ==="
for e in 1 3 5 7 9; do
  echo "--- effort $e ---"
  "$BIN" benchmark --mode lossless --effort "$e" -i "$INPUT" --iterations "$ITERS" \
    | grep -E "Encoded size|throughput|per pass|Mode" || true
done
echo "Done. (Decode throughput is effort-independent; encode trades speed for ratio.)"
