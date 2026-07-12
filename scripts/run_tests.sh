#!/bin/zsh
# Runs the unit tests with Command Line Tools only (no Xcode).
# CLT keeps Testing.framework and its macro plugin outside the default search
# paths, so point the native build system at them explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="${SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
CLT=/Library/Developer/CommandLineTools
# Build with CLT even if xcode-select points at an (unlicensed) Xcode install.
export DEVELOPER_DIR="${DEVELOPER_DIR:-$CLT}"

swift test --build-system native --sdk "$SDK" \
  -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
  -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" \
  -Xlinker -rpath -Xlinker "$CLT/Library/Developer/usr/lib" \
  "$@"
