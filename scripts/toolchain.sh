#!/bin/zsh
# Shared by the local build and test scripts; source after entering the repo.
# Respect per-command DEVELOPER_DIR and SDK overrides without changing xcode-select.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -u2 'ERROR: SonoGlass requires macOS 26 or later.'
  exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
  DEVELOPER_DIR=$(xcode-select -p 2>/dev/null) || {
    print -u2 'ERROR: Install Xcode 26+ or Command Line Tools 26+ (xcode-select --install).'
    exit 1
  }
fi
export DEVELOPER_DIR

if [[ -z "${SDK:-}" ]]; then
  SDK=$(xcrun --sdk macosx --show-sdk-path) || exit 1
  # Some CLT 27 betas lack the SwiftUI macro plugins required by their SDK.
  # Prefer an installed 26-series SDK in that case; never pin a patch version.
  if [[ "$DEVELOPER_DIR" == */CommandLineTools && -d "$DEVELOPER_DIR/SDKs/MacOSX26.sdk" ]]; then
    SDK="$DEVELOPER_DIR/SDKs/MacOSX26.sdk"
  fi
fi
if [[ ! -d "$SDK" ]]; then
  print -u2 "ERROR: SDK directory does not exist: $SDK"
  exit 1
fi
SDK_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :Version' "$SDK/SDKSettings.plist" 2>/dev/null) || {
  print -u2 "ERROR: Cannot read the macOS SDK version in $SDK. Set SDK to a macOS SDK directory."
  exit 1
}
if (( ${SDK_VERSION%%.*} < 26 )); then
  print -u2 "ERROR: macOS SDK 26+ is required; selected SDK is $SDK_VERSION. Install Xcode/CLT 26+."
  exit 1
fi
SWIFT=$(xcrun --find swift) || exit 1
print -u2 "Using $DEVELOPER_DIR (macOS SDK $SDK_VERSION)"
