#!/bin/bash
# Recursive FTP fetch of the DICOM WG26 2017 demo dataset.
# Downloads to TestFixtures/WG26Demo2017/ (gitignored).
# Uses curl only (macOS default); skips files that already exist.

set -u

BASE="ftp://medical.nema.org/medical/dicom/DataSets/WG26/WG26Demo2017"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="$SCRIPT_DIR/../TestFixtures/WG26Demo2017"
mkdir -p "$DEST"

urlencode() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/"))' "$1"
}

fetch_dir() {
  local rel="$1"
  local enc_rel
  enc_rel="$(urlencode "$rel")"
  local url="$BASE/$enc_rel/"
  local localdir="$DEST/$rel"
  mkdir -p "$localdir"

  echo "[DIR ] $rel"

  local listing
  listing="$(curl -sS --max-time 120 --retry 3 "$url" || true)"
  [ -z "$listing" ] && { echo "  (empty or failed)"; return; }

  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -z "$line" ] && continue

    # Format: MM-DD-YY  HH:MMAM/PM  <DIR>|SIZE  NAME
    # Use awk to split off first 3 fields and keep the rest (name may contain spaces).
    local kind name
    if [[ "$line" == *"<DIR>"* ]]; then
      kind="DIR"
      name="$(echo "$line" | awk '{$1=""; $2=""; $3=""; sub(/^[ \t]+/, ""); print}')"
    else
      kind="FILE"
      name="$(echo "$line" | awk '{$1=""; $2=""; $3=""; sub(/^[ \t]+/, ""); print}')"
    fi

    [ -z "$name" ] && continue
    [ "$name" = "." ] && continue
    [ "$name" = ".." ] && continue

    if [ "$kind" = "DIR" ]; then
      if [ -z "$rel" ]; then
        fetch_dir "$name"
      else
        fetch_dir "$rel/$name"
      fi
    else
      local target="$localdir/$name"
      if [ -s "$target" ]; then
        echo "[SKIP] $rel/$name"
        continue
      fi
      local enc_name
      enc_name="$(urlencode "$name")"
      local file_url="$url$enc_name"
      echo "[GET ] $rel/$name"
      # Resume partial transfers (-C -); abort if throughput drops below 1KB/s for 120s.
      # No overall --max-time: NEMA's FTP is slow and these files are 1.5GB+.
      # On failure, keep the .part file so a re-run resumes from where we stopped.
      local attempt=1
      local max_attempts=10
      while [ $attempt -le $max_attempts ]; do
        if curl -sS -C - --connect-timeout 60 --speed-time 120 --speed-limit 1024 \
             "$file_url" -o "$target.part"; then
          mv "$target.part" "$target"
          break
        fi
        echo "  attempt $attempt failed, retrying in 10s (partial kept)"
        attempt=$((attempt + 1))
        sleep 10
      done
      if [ ! -s "$target" ]; then
        echo "  FAILED after $max_attempts attempts (partial kept at $target.part)"
      fi
    fi
  done <<< "$listing"
}

echo "Downloading WG26Demo2017 to: $DEST"
fetch_dir ""
echo "Done."
