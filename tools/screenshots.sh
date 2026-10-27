#!/bin/bash
# Captures the README screenshots from the iOS Simulator using the DEBUG-only screenshot mode (CreamiCravings/App/ScreenshotMode.swift).
# Only the app's own screens and recipes that are Macro Kitchen adaptations / copycats are shown; remote photos are disabled.
#
#   tools/screenshots.sh            # all shots into docs/screenshots/
#   tools/screenshots.sh 03 05      # only shots whose file name starts with these prefixes
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
UDID="230C6BAB-53FB-4056-B8C5-F25145B26142"          # iPhone Duo: the device type that works with the installed runtime
BUNDLE="com.vishnudiv.CreamiCravings"
OUT="$PKG/docs/screenshots"
DD="${TMPDIR:-/tmp}/creami_screenshots_dd"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$OUT"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance light
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3

echo "building (Debug, simulator)..."
xcodebuild -project "$PKG/CreamiCravings.xcodeproj" -scheme CreamiCravings -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" build > "$DD.log" 2>&1 || { tail -20 "$DD.log"; exit 1; }
APP="$DD/Build/Products/Debug-iphonesimulator/CreamiCravings.app"
xcrun simctl install "$UDID" "$APP"

# name | launch arguments (separated by ";" so values may contain spaces)
SHOTS=(
  "01-recipes|-ss;recipes;-ssSection;meal;-ssSearch;Macro Kitchen"
  "02-goal-versions|-ss;recipe;-ssId;web-meal-7th-street-double-impossible-jalapeno-high-protein;-ssVersion;cut;-ssAnchor;versionCard"
  "03-macros|-ss;recipe;-ssId;web-meal-yogurt-tub-parle-g-elaichi-consumer-queen;-ssAnchor;macros"
  "04-filters|-ss;filters;-ssSection;meal"
  "05-paneer-calculator|-ss;guide;-ssGuide;paneer"
  "07-settings|-ss;settings"
  "08-saved|-ss;saved"
)
for shot in "${SHOTS[@]}"; do
  name="${shot%%|*}"; args="${shot#*|}"
  if [ "$#" -gt 0 ]; then match=0; for p in "$@"; do [[ "$name" == "$p"* ]] && match=1; done; [ "$match" = 1 ] || continue; fi
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  IFS=';' read -ra A <<< "$args"
  xcrun simctl launch "$UDID" "$BUNDLE" "${A[@]}" >/dev/null
  sleep 7
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png" >/dev/null 2>&1
  sips -Z 1300 "$OUT/$name.png" >/dev/null
  echo "  $name.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
xcrun simctl status_bar "$UDID" clear
ls -la "$OUT"
