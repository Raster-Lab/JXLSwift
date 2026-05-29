#!/usr/bin/env bash
# medical-dicom-validate.sh — medical-grade lossless validation of JXLSwift
# against a DICOM corpus (see medical-dicom-validate.py for the methodology).
#
# JXLSwift is NOT DICOM-aware (CLAUDE.md constraint 5): this harness uses an
# external extractor (pydicom) to pull raw pixel buffers from DICOM and feeds
# them to the codec, verifying byte-exact reconstruction through BOTH the
# pure-Swift decoder and the libjxl reference decoder `djxl`. PHI-safe — reports
# only aggregate counts + technical configs, nothing is uploaded or committed.
#
# Usage:  scripts/medical-dicom-validate.sh <DICOM_DIR> [effort] [big_target]
#
# Sets up a throwaway venv with pydicom + numpy (+ JPEG/JPEG-LS handlers for
# compressed transfer syntaxes) if one isn't already at $DCM_VENV.
set -euo pipefail

DICOM_DIR="${1:?usage: medical-dicom-validate.sh <DICOM_DIR> [effort] [big_target]}"
EFFORT="${2:-1}"
BIG_TARGET="${3:-1000}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENV="${DCM_VENV:-/tmp/dcmvenv}"
export JXL_TOOL="${JXL_TOOL:-$ROOT/.build/release/jxl-tool}"
export DJXL="${DJXL:-/opt/homebrew/bin/djxl}"

if [ ! -x "$JXL_TOOL" ]; then
  echo "building release jxl-tool…"; (cd "$ROOT" && swift build -c release >/dev/null)
fi
if [ ! -x "$VENV/bin/python" ]; then
  echo "creating venv at $VENV…"
  python3 -m venv "$VENV"
  "$VENV/bin/python" -m pip install --quiet --upgrade pip
  "$VENV/bin/python" -m pip install --quiet pydicom numpy \
    pylibjpeg pylibjpeg-libjpeg pylibjpeg-openjpeg pyjpegls || \
    "$VENV/bin/python" -m pip install --quiet pydicom numpy
fi

exec "$VENV/bin/python" "$ROOT/scripts/medical-dicom-validate.py" \
  "$DICOM_DIR" "$EFFORT" "$BIG_TARGET"
