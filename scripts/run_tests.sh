#!/bin/zsh
# Run the suite using the selected Xcode or Command Line Tools installation.
# BUILD_DIR=/tmp/sonoglass-tests scripts/run_tests.sh --filter SomeTest
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

TEST_ARGS=(--build-system native --sdk "$SDK" --scratch-path "${BUILD_DIR:-.build}")
# CLT's Testing.framework and macro plugin live outside the default search paths.
if [[ "$DEVELOPER_DIR" == */CommandLineTools ]]; then
  TEST_ARGS+=(
    -Xswiftc -F -Xswiftc "$DEVELOPER_DIR/Library/Developer/Frameworks"
    -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing"
    -Xlinker -rpath -Xlinker "$DEVELOPER_DIR/Library/Developer/Frameworks"
    -Xlinker -rpath -Xlinker "$DEVELOPER_DIR/Library/Developer/usr/lib"
  )
fi
"$SWIFT" test "${TEST_ARGS[@]}" "$@"
