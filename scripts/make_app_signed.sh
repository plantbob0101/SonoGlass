#!/bin/zsh
# Team-signed build via Xcode — required for MusicKit (Apple Music favorites).
#   scripts/make_app_signed.sh            — uses DEVELOPMENT_TEAM from env or auto
#   TEAM=ABCDE12345 scripts/make_app_signed.sh
# Prereqs: signed into Xcode (Settings → Accounts); App ID com.sonoglass.app
# with the MusicKit service enabled at developer.apple.com.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen

ARGS=(-project SonoGlass.xcodeproj -scheme SonoGlass -configuration Release
      -derivedDataPath .build/xcode
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build)
if [[ -n "${TEAM:-}" ]]; then
  ARGS+=("DEVELOPMENT_TEAM=$TEAM")
fi
LOG=$(mktemp)
if ! xcodebuild "${ARGS[@]}" > "$LOG" 2>&1; then
  grep -E "error" "$LOG" | head -10
  echo "BUILD FAILED"
  exit 1
fi
grep -E "Signing Identity|BUILD" "$LOG" | head -3

APP=".build/xcode/Build/Products/Release/SonoGlass.app"
[[ -d "$APP" ]] || { echo "build failed"; exit 1; }
rm -rf dist/SonoGlass.app
mkdir -p dist
ditto "$APP" dist/SonoGlass.app
echo "Built dist/SonoGlass.app (team-signed)"
codesign -dv dist/SonoGlass.app 2>&1 | grep -E "Authority|TeamIdentifier" | head -3 || true
