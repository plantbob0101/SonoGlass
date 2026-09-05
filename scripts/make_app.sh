#!/bin/zsh
# Local build: macOS 26+, Xcode or Command Line Tools, no developer account.
#   scripts/make_app.sh              — release, ad-hoc signed, no App Sandbox
#   SANDBOX=1 scripts/make_app.sh    — opt into App Sandbox
#   CONFIG=debug scripts/make_app.sh
#   BUILD_DIR=/tmp/sonoglass-build DIST_DIR=/tmp/sonoglass-dist scripts/make_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SANDBOX="${SANDBOX:-0}"
BUILD_DIR="${BUILD_DIR:-.build}"
DIST_DIR="${DIST_DIR:-dist}"
[[ "$CONFIG" == release || "$CONFIG" == debug ]] || { print -u2 'ERROR: CONFIG must be release or debug.'; exit 1; }
[[ "$SANDBOX" == 0 || "$SANDBOX" == 1 ]] || { print -u2 'ERROR: SANDBOX must be 0 or 1.'; exit 1; }
source scripts/toolchain.sh

BUILD_ARGS=(-c "$CONFIG" --sdk "$SDK" --scratch-path "$BUILD_DIR" --product SonoGlass)
"$SWIFT" build "${BUILD_ARGS[@]}"
BIN_DIR=$("$SWIFT" build "${BUILD_ARGS[@]}" --show-bin-path)

mkdir -p "$DIST_DIR"
STAGING=$(mktemp -d "$DIST_DIR/.sonoglass-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/SonoGlass.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SonoGlass" "$APP/Contents/MacOS/SonoGlass"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/SonoGlass.icns "$APP/Contents/Resources/SonoGlass.icns"
# Include dependency resources (currently CryptoSwift's privacy manifest).
for RESOURCE_BUNDLE in "$BIN_DIR"/*.bundle(N); do
  ditto "$RESOURCE_BUNDLE" "$APP/Contents/Resources/${RESOURCE_BUNDLE:t}"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGN_ARGS=(--force --sign -)
if [[ "$CONFIG" == release ]]; then
  SIGN_ARGS+=(--options runtime)
fi
if [[ "$SANDBOX" == 1 ]]; then
  SIGN_ARGS+=(--entitlements Resources/SonoGlass.entitlements)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"

if [[ "$CONFIG" == release ]]; then
  SIGNATURE_DETAILS=$(codesign -dv --verbose=4 "$APP" 2>&1)
  if [[ "$SIGNATURE_DETAILS" != *"runtime"* ]]; then
    print -u2 'ERROR: release artifact is missing hardened runtime.'
    exit 1
  fi
fi
# Publish only a complete, verified bundle. Installed copies are never touched.
rm -rf "$DIST_DIR/SonoGlass.app"
mv "$APP" "$DIST_DIR/SonoGlass.app"
print "Built $DIST_DIR/SonoGlass.app (ad-hoc signed, App Sandbox=$SANDBOX)"
