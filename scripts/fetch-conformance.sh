#!/usr/bin/env bash
# fetch-conformance.sh — populate a local jxl-conformance vector directory for
# JXLSwift's conformance gate (Tests/JXLSwiftTests/ConformanceTests.swift).
#
# The official corpus lives at https://github.com/libjxl/conformance. Each
# testcase is a directory `testcases/<name>/` containing `input.jxl`,
# `test.json` and a reference image. The conformance harness only needs
# `input.jxl` per vector (it uses the libjxl reference decoder `djxl` as the
# pixel oracle), so this script fetches just those, directly over HTTPS — no
# git-lfs or gsutil required.
#
# Usage:
#   scripts/fetch-conformance.sh [DEST_DIR] [vector ...]
#
#   DEST_DIR   where to write <name>/input.jxl  (default: ./.conformance)
#   vector...  testcase names to fetch          (default: the lossless subset)
#
# Then run the gate against the full set:
#   JXL_CONFORMANCE_DIR="$PWD/.conformance" swift test -c release \
#     --filter Conformance
set -euo pipefail

RAW="https://raw.githubusercontent.com/libjxl/conformance/master/testcases"
DEST="${1:-./.conformance}"
shift || true

# Default: the lossless / near-lossless Modular subset relevant to a
# lossless-first 1.0. (Lossy VarDCT vectors decode under the preview path
# only and are intentionally excluded from the lossless gate.)
DEFAULT_VECTORS=(
  lz77_flower
  alpha_triangles
  grayscale_public_university
  bicycles
  delta_palette
  lossless_pfm
  patches_lossless
  sunset_logo
)

VECTORS=("$@")
if [ "${#VECTORS[@]}" -eq 0 ]; then
  VECTORS=("${DEFAULT_VECTORS[@]}")
fi

echo "Fetching ${#VECTORS[@]} conformance vector(s) into: $DEST"
for v in "${VECTORS[@]}"; do
  mkdir -p "$DEST/$v"
  url="$RAW/$v/input.jxl"
  if curl -fsS --max-time 120 -o "$DEST/$v/input.jxl" "$url"; then
    printf '  %-32s %8s bytes\n' "$v" "$(wc -c < "$DEST/$v/input.jxl" | tr -d ' ')"
  else
    echo "  $v  FAILED ($url)" >&2
  fi
done
echo "Done. Run: JXL_CONFORMANCE_DIR=\"$(cd "$DEST" && pwd)\" swift test -c release --filter Conformance"
