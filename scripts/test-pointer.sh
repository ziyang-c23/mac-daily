#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$ROOT/tmp/pointer-tests"
mkdir -p "$TASK_TMP/clang"
export TMPDIR="$TASK_TMP" TMP="$TASK_TMP" TEMP="$TASK_TMP" CLANG_MODULE_CACHE_PATH="$TASK_TMP/clang"
clang -fblocks -Werror -Wall -Wextra -Wno-unused-parameter -I "$ROOT/Sources/PointerBridge/include" "$ROOT/Tests/PointerBridgeTests/PolicyTests.m" -framework CoreFoundation -framework CoreGraphics -framework IOKit -o "$TASK_TMP/PolicyTests"
"$TASK_TMP/PolicyTests"
