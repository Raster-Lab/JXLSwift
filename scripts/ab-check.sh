#!/usr/bin/env bash
# ab-check.sh — byte-identity A/B gate for optimisation work.
#
#   scripts/ab-check.sh baseline   # encode corpus with current binary, store hashes
#   scripts/ab-check.sh check      # re-encode, compare encoded bytes + decoded pixels
#
# `baseline` also stores the .jxl files and decoded-pixel hashes (ours + djxl),
# so decode-only changes can be verified against unchanged baseline bitstreams.
# Exit 1 on any divergence. Dev-time tooling only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/release/jxl-tool"
AB=/tmp/jxl-ab
CORPUS=$AB/corpus
BASE=$AB/baseline
EFFORTS="1 4 7 9"

mode="${1:?usage: ab-check.sh baseline|check}"

[ -d "$CORPUS" ] || python3 "$ROOT/scripts/ab-corpus-gen.py" "$CORPUS"
[ -x "$BIN" ] || (cd "$ROOT" && swift build -c release)

hash_file() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ "$mode" = baseline ]; then
  rm -rf "$BASE"; mkdir -p "$BASE/jxl" "$BASE/dec"
  : > "$BASE/encode.sha"; : > "$BASE/decode.sha"; : > "$BASE/djxl.sha"
  for img in "$CORPUS"/*; do
    name=$(basename "$img")
    for e in $EFFORTS; do
      # 2080px at high effort is slow; two efforts cover its paths
      case "$name:$e" in grad16_2080.pgm:4|grad16_2080.pgm:9) continue;; esac
      jxl="$BASE/jxl/$name.e$e.jxl"
      "$BIN" encode --lossless -e "$e" -i "$img" -o "$jxl" >/dev/null
      echo "$name.e$e $(hash_file "$jxl")" >> "$BASE/encode.sha"
      ext=pgm; case "$name" in *.ppm) ext=ppm;; *.pam) ext=pam;; esac
      dec="$BASE/dec/$name.e$e.$ext"
      "$BIN" decode -i "$jxl" -o "$dec" >/dev/null
      echo "$name.e$e $(hash_file "$dec")" >> "$BASE/decode.sha"
      if command -v djxl >/dev/null; then
        djxl "$jxl" "$AB/djxl-tmp.$ext" >/dev/null 2>&1 \
          && echo "$name.e$e $(hash_file "$AB/djxl-tmp.$ext")" >> "$BASE/djxl.sha" \
          || echo "$name.e$e DJXL_FAIL" >> "$BASE/djxl.sha"
      fi
    done
  done
  n_enc=$(wc -l < "$BASE/encode.sha" | tr -d ' ')
  n_djxl_fail=$(grep -c DJXL_FAIL "$BASE/djxl.sha" || true)
  echo "baseline stored: $n_enc encodes ($n_djxl_fail djxl failures)"
  exit 0
fi

# check mode
fail=0
tmp=$AB/check; rm -rf "$tmp"; mkdir -p "$tmp"
while read -r key want; do
  name="${key%.e*}"; e="${key##*.e}"
  jxl="$tmp/$key.jxl"
  "$BIN" encode --lossless -e "$e" -i "$CORPUS/$name" -o "$jxl" >/dev/null
  got=$(hash_file "$jxl")
  if [ "$got" != "$want" ]; then echo "ENCODE DIVERGED: $key"; fail=1; fi
done < "$BASE/encode.sha"
while read -r key want; do
  name="${key%.e*}"
  ext=pgm; case "$name" in *.ppm) ext=ppm;; *.pam) ext=pam;; esac
  dec="$tmp/$key.$ext"
  "$BIN" decode -i "$BASE/jxl/$key.jxl" -o "$dec" >/dev/null
  got=$(hash_file "$dec")
  if [ "$got" != "$want" ]; then echo "DECODE DIVERGED: $key"; fail=1; fi
done < "$BASE/decode.sha"
if [ "$fail" = 0 ]; then echo "ab-check: all encoded bytes + decoded pixels identical"; fi
exit $fail
