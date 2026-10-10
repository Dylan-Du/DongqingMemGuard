#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="东青MemGuard"
EXEC_NAME="MemGlass"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> 编译 release"
swift build -c release --package-path "$ROOT"

echo "==> 组装 $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Packaging/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f "$ROOT/Packaging/AppIcon.icns" ]; then
  cp "$ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> ad-hoc 签名"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "==> 完成: $APP"
du -sh "$APP"