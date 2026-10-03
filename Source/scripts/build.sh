#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
cd "$TASK_ROOT"
TASK_BUILD="${FOLDLIGHT_BUILD_DIR:-$TASK_ROOT/.build}"
swift build -c release --scratch-path "$TASK_BUILD"
TASK_BIN="$(swift build -c release --scratch-path "$TASK_BUILD" --show-bin-path)"
APP_ROOT="$TASK_ROOT/../Foldlight.app"
mkdir -p "$APP_ROOT/Contents/MacOS" "$APP_ROOT/Contents/Resources"
cp "$TASK_BIN/Foldlight" "$APP_ROOT/Contents/MacOS/Foldlight"
cp Info.plist "$APP_ROOT/Contents/Info.plist"
if [[ -f "$TASK_ROOT/../Foldlight.icns" ]]; then
    cp "$TASK_ROOT/../Foldlight.icns" "$APP_ROOT/Contents/Resources/Foldlight.icns"
fi
codesign --force --sign - "$APP_ROOT"
print "Built $APP_ROOT"
