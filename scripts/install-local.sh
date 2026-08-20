#!/bin/bash
set -euo pipefail

# 本地调试安装：仅替换 /Applications/ClipBar.app，不生成 pkg/dmg，不留下多余安装副本。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipBar"
APP_SRC="$ROOT/dist/$APP_NAME.app"
APP_DST="/Applications/$APP_NAME.app"

cd "$ROOT"
./scripts/build-app.sh "${1:-release}"

pkill -x "ClipBar" 2>/dev/null || true
sleep 0.3

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"
codesign --verify --deep --strict --verbose=2 "$APP_DST"

# 本地调试不保留 dist 里的 .app，避免与 /Applications 两份并存误开旧包
rm -rf "$APP_SRC"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_DST}/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_DST}/Contents/Info.plist")
echo "已安装到 ${APP_DST} (${VERSION} build ${BUILD})"
# 直接按安装路径启动，避免覆盖后 LaunchServices 名称索引尚未刷新导致 `open -a` 找不到 App。
open "${APP_DST}"
