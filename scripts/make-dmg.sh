#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Clipboard Manager"

cd "$ROOT"
./scripts/build-app.sh release

STAGE="$ROOT/dist/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/$APP_NAME.app" "$STAGE/"
# 提供 Applications 快捷方式，打开 DMG 后可直接把 App 拖进去
ln -s /Applications "$STAGE/Applications"

DMG_PATH="$ROOT/dist/Clipboard-Manager.dmg"
hdiutil create -volname "Clipboard Manager" \
    -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_PATH" >/dev/null

if [ -d "$STAGE" ]; then
    find "$STAGE" -depth -delete
fi

# 清理构建产物，dist 只保留 DMG
if [ -d "$ROOT/dist/$APP_NAME.app" ]; then
    find "$ROOT/dist/$APP_NAME.app" -depth -delete
fi
echo "DMG 已生成: $DMG_PATH"
