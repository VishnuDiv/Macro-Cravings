#!/bin/bash
# Compiles Models/ + Services/ + main.swift for macOS and runs the logic checks.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
PY="${PYTHON:-python3}"
RES="$PKG/CreamiCravings/Resources"
OUT="${TMPDIR:-/tmp}/creami_logic_checks"
mkdir -p "$OUT"
# Real catalog when bundled, otherwise the small fixture.
CAT="$RES"
if [ ! -f "$RES/ingredients.json" ] || [ ! -f "$RES/base_liquids.json" ]; then
  CAT="$HERE/fixtures"
  echo "(catalog not in Resources yet: using fixtures)"
fi
rm -f "$OUT/checks"
swiftc -swift-version 5 -target arm64-apple-macos15.0 -sdk "$(xcrun --show-sdk-path)" -o "$OUT/checks" \
  $(find "$PKG/CreamiCravings/Models" "$PKG/CreamiCravings/Services" -name '*.swift') "$HERE/main.swift"
# Build the fixture dataset (meals, veg adaptations, guides, paneer model) with the real build script.
rm -rf "$OUT/fixture_res"; mkdir -p "$OUT/fixture_res/Photos"; printf x > "$OUT/fixture_res/Photos/chef-omelette.jpg"
CREAMI_DATA="$HERE/fixtures/data" CREAMI_RES="$OUT/fixture_res" "$PY" -I "$PKG/tools/build_data.py" > "$OUT/fixture_build.log"
"$OUT/checks" "$RES" "$CAT" "$HERE/fixtures" "$PKG/data/catalog" "$OUT/fixture_res"

# build_data.py amount parser unit tests
"$PY" -I "$PKG/tools/test_amounts.py"

# build-time data fix unit tests
"$PY" -I "$PKG/tools/test_data_fixes.py"

# clarity audit gate: fail above 20 flagged steps (13 at the time of writing)
AUDIT="$("$PY" -I "$PKG/tools/clarity_audit.py" 2>&1)" || true
FLAGGED="$(echo "$AUDIT" | grep -E '^Flagged:' | sed -E 's/.*, ([0-9]+) steps.*/\1/')"
echo "clarity audit: ${FLAGGED:-?} flagged steps (limit 20)"
if ! [[ "$FLAGGED" =~ ^[0-9]+$ ]] || [ "$FLAGGED" -gt 20 ]; then echo "FAIL: clarity audit"; exit 1; fi
