#!/bin/zsh
# Builds SonoGlass.app from the Swift package (no Xcode required).
#   scripts/make_app.sh            — release build, sandboxed, ad-hoc signed
#   SANDBOX=0 scripts/make_app.sh  — build without the App Sandbox entitlements
#   CONFIG=debug scripts/make_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SANDBOX="${SANDBOX:-1}"

swift build -c "$CONFIG"

BIN=".build/$CONFIG/SonoGlass"
APP="dist/SonoGlass.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SonoGlass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$SANDBOX" == "1" ]]; then
  codesign --force --sign - --entitlements Resources/SonoGlass.entitlements "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
codesign -d --entitlements - "$APP" 2>/dev/null | tail -5 || true
