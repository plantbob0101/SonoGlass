#!/bin/zsh
# Builds SonoGlass.app from the Swift package (no Xcode required).
#   scripts/make_app.sh            — release build, sandboxed, ad-hoc signed
#   SANDBOX=0 scripts/make_app.sh  — build without the App Sandbox entitlements
#   CONFIG=debug scripts/make_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SANDBOX="${SANDBOX:-1}"

# Pin to the macOS 26-series SDK: the 27 beta SDK macro-izes SwiftUI property
# wrappers via plugins that only ship with full Xcode, not Command Line Tools.
SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
# Build with CLT even if xcode-select points at an (unlicensed) Xcode install.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

swift build -c "$CONFIG" --sdk "$SDK"

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
