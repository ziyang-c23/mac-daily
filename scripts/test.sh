#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$ROOT/tmp/tests"
mkdir -p "$TASK_TMP/fixtures" "$TASK_TMP/clang" "$TASK_TMP/swift"
export TMPDIR="$TASK_TMP" TMP="$TASK_TMP" TEMP="$TASK_TMP"
export MACDAILY_TEST_TMP="$TASK_TMP/fixtures"
export MACDAILY_LANGUAGE="${MACDAILY_LANGUAGE:-zh-Hans}"
export CLANG_MODULE_CACHE_PATH="$TASK_TMP/clang" SWIFTPM_MODULECACHE_OVERRIDE="$TASK_TMP/swift"
FRAMEWORK_FLAGS=()
DEVELOPER_PATH="$(xcode-select -p)"
if [[ "$DEVELOPER_PATH" == *CommandLineTools ]]; then
    FRAMEWORK_DIR="$DEVELOPER_PATH/Library/Developer/Frameworks"
    FRAMEWORK_FLAGS=(-Xswiftc -F -Xswiftc "$FRAMEWORK_DIR" -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR")
fi
swift test --build-system native --disable-xctest --package-path "$ROOT" --scratch-path "$TASK_TMP/products" --cache-path "$TASK_TMP/cache" --config-path "$TASK_TMP/config" --security-path "$TASK_TMP/security" --disable-sandbox -Xswiftc -module-cache-path -Xswiftc "$TASK_TMP/swift" "${FRAMEWORK_FLAGS[@]}" "$@"

"$ROOT/scripts/test-pointer.sh"
