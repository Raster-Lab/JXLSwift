#!/usr/bin/env bash
# check-spelling.sh — Spelling consistency checker for JXLSwift
#
# Ensures that British English is used consistently in source-code comments,
# documentation, error messages, and CLI help text.
#
# Usage:
#   ./scripts/check-spelling.sh [--fix] [path ...]
#
# Options:
#   --fix    Automatically rewrite American spellings to British equivalents
#            in supported file types (.swift, .md, .txt).
#            WARNING: review changes with `git diff` before committing.
#
# Exit codes:
#   0  No issues found (or all issues fixed with --fix).
#   1  One or more spelling inconsistencies detected.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Directories/files to scan (relative to repo root)
SCAN_PATHS=("Sources" "Tests" "Documentation" "README.md" "CONTRIBUTING.md" "MILESTONES.md" "CHANGELOG.md")

# File extensions to check
INCLUDE_EXTS=("*.swift" "*.md" "*.txt")

# American → British spelling map
# Each entry is "american:british"
declare -a SPELLING_MAP=(
    "color:colour"
    "Color:Colour"
    "optimize:optimise"
    "Optimize:Optimise"
    "organization:organisation"
    "Organization:Organisation"
    "serialization:serialisation"
    "Serialization:Serialisation"
    "initialize:initialise"
    "Initialize:Initialise"
    "initialization:initialisation"
    "Initialization:Initialisation"
    "synchronize:synchronise"
    "Synchronize:Synchronise"
    "recognize:recognise"
    "Recognize:Recognise"
    "behavior:behaviour"
    "Behavior:Behaviour"
    "neighbor:neighbour"
    "Neighbor:Neighbour"
    "center:centre"
    "Center:Centre"
)

# Words that are intentionally American English and must NOT be flagged.
# This covers Swift standard library names, third-party API surface, and
# deliberate dual-spelling public aliases.
declare -a ALLOWLIST=(
    # Swift / Apple framework identifiers
    "ColorSpace"
    "ColorPrimaries"
    "colorSpace"
    "colorSpaceIndicator"
    "useXYBColorSpace"
    "URLComponents"
    "NSColorSpace"
    "CGColor"
    "CGColorSpace"
    "UIColor"
    "NSColor"
    "SwiftUI"
    "AccentColor"
    "BackgroundColor"
    # ArgumentParser / test framework identifiers
    "XCTestCase"
    # Encoder/decoder options that intentionally keep American spelling in code
    "EncodingOptions"
    "CompressionMode"
    # Proper nouns / acronyms
    "JPEG"
    "DICOM"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX_MODE=false
PATHS_OVERRIDE=()

for arg in "$@"; do
    case "$arg" in
        --fix) FIX_MODE=true ;;
        *)     PATHS_OVERRIDE+=("$arg") ;;
    esac
done

if [ ${#PATHS_OVERRIDE[@]} -gt 0 ]; then
    SCAN_PATHS=("${PATHS_OVERRIDE[@]}")
fi

# Build the ripgrep include flags
RG_INCLUDE=()
for ext in "${INCLUDE_EXTS[@]}"; do
    RG_INCLUDE+=("--glob" "$ext")
done

# Resolve absolute scan paths
ABS_SCAN_PATHS=()
for p in "${SCAN_PATHS[@]}"; do
    full="$REPO_ROOT/$p"
    if [ -e "$full" ]; then
        ABS_SCAN_PATHS+=("$full")
    fi
done

if [ ${#ABS_SCAN_PATHS[@]} -eq 0 ]; then
    echo "No valid scan paths found. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build allowlist grep pattern
# ---------------------------------------------------------------------------
ALLOWLIST_PATTERN=$(printf '%s|' "${ALLOWLIST[@]}")
ALLOWLIST_PATTERN="${ALLOWLIST_PATTERN%|}"  # trim trailing |

# ---------------------------------------------------------------------------
# Scan
# ---------------------------------------------------------------------------

TOTAL_ISSUES=0

echo "=== JXLSwift Spelling Checker ==="
echo "Scanning: ${ABS_SCAN_PATHS[*]}"
echo ""

for entry in "${SPELLING_MAP[@]}"; do
    american="${entry%%:*}"
    british="${entry##*:}"

    # Search for American spelling in comments and string literals.
    # We pipe through grep -v to strip lines that only hit the allowlist.
    MATCHES=$(rg --no-heading -n "${american}" \
        "${RG_INCLUDE[@]}" \
        "${ABS_SCAN_PATHS[@]}" 2>/dev/null \
        | grep -v -E "(${ALLOWLIST_PATTERN})" \
        | grep -v "check-spelling.sh" \
        | grep -v "BritishSpelling.swift" \
        || true)

    if [ -n "$MATCHES" ]; then
        COUNT=$(echo "$MATCHES" | wc -l | tr -d ' ')
        echo "❌  American '$american' found ($COUNT occurrence(s)) — prefer '$british':"
        echo "$MATCHES" | head -10
        if [ "$COUNT" -gt 10 ]; then
            echo "    ... and $((COUNT - 10)) more."
        fi
        echo ""
        TOTAL_ISSUES=$((TOTAL_ISSUES + COUNT))

        if $FIX_MODE; then
            # Perform in-place replacement (macOS sed compatible)
            rg --files-with-matches "${american}" \
                "${RG_INCLUDE[@]}" \
                "${ABS_SCAN_PATHS[@]}" 2>/dev/null \
                | grep -v "check-spelling.sh" \
                | grep -v "BritishSpelling.swift" \
                | while IFS= read -r file; do
                    sed -i "" "s/${american}/${british}/g" "$file" 2>/dev/null \
                        || sed -i "s/${american}/${british}/g" "$file"
                done
            echo "    ✅  Auto-fixed '$american' → '$british'."
        fi
    fi
done

echo "=================================="
if [ "$TOTAL_ISSUES" -eq 0 ]; then
    echo "✅  No spelling issues found."
    exit 0
else
    if $FIX_MODE; then
        echo "✅  Fixed $TOTAL_ISSUES spelling issue(s). Review changes with 'git diff'."
        exit 0
    else
        echo "❌  $TOTAL_ISSUES spelling issue(s) found."
        echo "    Run with --fix to auto-correct, or update the ALLOWLIST in this script"
        echo "    for identifiers that should keep American spelling."
        exit 1
    fi
fi
