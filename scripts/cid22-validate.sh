#!/usr/bin/env bash
# cid22-validate.sh — non-DICOM (natural photographic) lossless validation of
# JXLSwift against the Cloudinary Image Dataset '22 (or any directory of
# images). Complements the medical DICOM validation: the codec must be just as
# byte-exact on ordinary RGB photos as on radiology data.
#
# For each image: extract pixels with ImageMagick to a netpbm PNM (PGM for
# grayscale, PPM for RGB, PAM for alpha), losslessly encode with `jxl-tool`,
# then decode with BOTH the pure-Swift decoder AND the libjxl reference decoder
# `djxl`, asserting the reconstruction is byte-identical to the source pixels.
#
# Usage:  scripts/cid22-validate.sh <IMAGE_DIR> [effort]
# Requires: ImageMagick (`magick`), djxl on PATH.
set -uo pipefail

DIR="${1:?usage: cid22-validate.sh <IMAGE_DIR> [effort]}"
EFFORT="${2:-7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${JXL_TOOL:-$ROOT/.build/release/jxl-tool}"
DJXL="${DJXL:-/opt/homebrew/bin/djxl}"
MAGICK="$(command -v magick || command -v convert)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

if [ ! -x "$BIN" ]; then echo "building…"; (cd "$ROOT" && swift build -c release >/dev/null); fi
[ -n "$MAGICK" ] || { echo "ImageMagick (magick/convert) required" >&2; exit 2; }

pass=0; fail=0; total_src=0; total_jxl=0
echo "=== CID22 / natural-image lossless validation (effort $EFFORT, our decoder + djxl) ==="
while IFS= read -r img; do
  base="$(basename "$img")"
  # channel-driven PNM extension (gray→pgm, rgb→ppm, alpha→pam)
  ch="$("$MAGICK" identify -format "%[channels]" "$img" 2>/dev/null)"
  case "$ch" in
    *graya*|*rgba*|*srgba*) ext=pam ;;
    *gray*)                 ext=pgm ;;
    *)                      ext=ppm ;;
  esac
  inP="$SCRATCH/in.$ext"; jxlP="$SCRATCH/o.jxl"; ourP="$SCRATCH/our.$ext"; djP="$SCRATCH/dj.$ext"
  if ! "$MAGICK" "$img" "$inP" 2>/dev/null; then echo "  SKIP $base (magick)"; continue; fi
  if ! "$BIN" encode --lossless --effort "$EFFORT" -i "$inP" -o "$jxlP" >/dev/null 2>&1; then
    echo "  FAIL $base (encode)"; fail=$((fail+1)); continue; fi
  if ! "$BIN" decode -i "$jxlP" -o "$ourP" >/dev/null 2>&1 || ! cmp -s "$inP" "$ourP"; then
    echo "  FAIL $base (our decode not byte-exact)"; fail=$((fail+1)); continue; fi
  if [ -x "$DJXL" ]; then
    if ! "$DJXL" "$jxlP" "$djP" >/dev/null 2>&1 || ! cmp -s "$inP" "$djP"; then
      echo "  FAIL $base (djxl not byte-exact)"; fail=$((fail+1)); continue; fi
  fi
  s=$(wc -c < "$inP"); j=$(wc -c < "$jxlP"); total_src=$((total_src+s)); total_jxl=$((total_jxl+j))
  pass=$((pass+1))
done < <(find "$DIR" -type f \( -iname '*.png' -o -iname '*.ppm' -o -iname '*.pgm' -o -iname '*.bmp' -o -iname '*.tif' -o -iname '*.tiff' -o -iname '*.jpg' -o -iname '*.jpeg' \) | sort)

echo "---"
echo "PASS=$pass  FAIL=$fail"
if [ "$total_src" -gt 0 ]; then
  awk -v s="$total_src" -v j="$total_jxl" 'BEGIN{printf "aggregate lossless ratio: %.1f%% of source (%d -> %d bytes)\n", j*100/s, s, j}'
fi
[ "$fail" -eq 0 ]
