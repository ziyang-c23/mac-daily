#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_TMP="$ROOT/tmp/build"
mkdir -p "$TASK_TMP" "$TASK_TMP/clang" "$TASK_TMP/swift" "$ROOT/dist"
export TMPDIR="$TASK_TMP" TMP="$TASK_TMP" TEMP="$TASK_TMP"
export CLANG_MODULE_CACHE_PATH="$TASK_TMP/clang" SWIFTPM_MODULECACHE_OVERRIDE="$TASK_TMP/swift"
CONFIGURATION="${CONFIGURATION:-release}"
swift build --build-system native --package-path "$ROOT" --scratch-path "$TASK_TMP/products" --cache-path "$TASK_TMP/cache" --config-path "$TASK_TMP/config" --security-path "$TASK_TMP/security" --disable-sandbox -c "$CONFIGURATION" -Xswiftc -module-cache-path -Xswiftc "$TASK_TMP/swift"
BIN_DIR="$(swift build --build-system native --package-path "$ROOT" --scratch-path "$TASK_TMP/products" --cache-path "$TASK_TMP/cache" --config-path "$TASK_TMP/config" --security-path "$TASK_TMP/security" --disable-sandbox -c "$CONFIGURATION" --show-bin-path)"
APP="$ROOT/dist/MacDaily.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacDaily" "$APP/Contents/MacOS/MacDaily"
cp "$ROOT/scripts/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/scripts/AppIcon.icns" ]; then cp "$ROOT/scripts/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; fi
ditto "$BIN_DIR/MacDaily_MacDailyCore.bundle" "$APP/Contents/Resources/MacDaily_MacDailyCore.bundle"
for APP_LANGUAGE in en zh-Hans; do
    ditto "$ROOT/Sources/MacDailyCore/Resources/$APP_LANGUAGE.lproj" "$APP/Contents/Resources/$APP_LANGUAGE.lproj"
done
PRACTICE="$APP/Contents/Helpers/MacDailyPractice.app"
mkdir -p "$PRACTICE/Contents/MacOS"
cp "$BIN_DIR/MacDailyPractice" "$PRACTICE/Contents/MacOS/MacDailyPractice"
cp "$ROOT/scripts/Practice-Info.plist" "$PRACTICE/Contents/Info.plist"
mkdir -p "$PRACTICE/Contents/Resources"
ditto "$BIN_DIR/MacDaily_MacDailyCore.bundle" "$PRACTICE/Contents/Resources/MacDaily_MacDailyCore.bundle"
for APP_LANGUAGE in en zh-Hans; do
    mkdir -p "$PRACTICE/Contents/Resources/$APP_LANGUAGE.lproj"
    cp "$ROOT/scripts/PracticeInfo-$APP_LANGUAGE.strings" "$PRACTICE/Contents/Resources/$APP_LANGUAGE.lproj/InfoPlist.strings"
done
codesign --force --sign "${MACDAILY_SIGN_IDENTITY:--}" --identifier org.macdaily.practice "$PRACTICE"
codesign --force --sign "${MACDAILY_SIGN_IDENTITY:--}" --identifier org.macdaily.app "$APP"
codesign --verify --strict "$APP"
printf 'App: %s\n' "$APP"
