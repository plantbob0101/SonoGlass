#!/bin/zsh
# Runs the unit tests with Command Line Tools only (no Xcode).
# CLT ships Testing.framework outside the dyld search path of test bundles,
# so link it (and its interop dylib) into the bundle before running.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
CLT_FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
BUNDLE_FW=".build/out/Products/Debug/SonoGlassTests.xctest/Contents/Frameworks"

swift build --build-tests --sdk "$SDK"
mkdir -p "$BUNDLE_FW"
ln -sfn "$CLT_FRAMEWORKS/Testing.framework" "$BUNDLE_FW/Testing.framework"
ln -sfn "$CLT_LIB/lib_TestingInterop.dylib" "$BUNDLE_FW/lib_TestingInterop.dylib"

swift test --sdk "$SDK"
