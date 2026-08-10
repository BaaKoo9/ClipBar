#!/bin/bash
set -euo pipefail

# 生成可拖拽安装的 DMG：打开后可见 App 与 Applications 快捷方式。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipBar"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")
VOL_NAME="ClipBar"
DMG_PATH="$ROOT/dist/ClipBar-${VERSION}.dmg"
STAGE="$ROOT/dist/dmg-stage"
RW_DMG="$ROOT/dist/.ClipBar-rw.dmg"
MOUNT="/Volumes/${VOL_NAME}"

cd "$ROOT"
./scripts/build-app.sh release

rm -rf "$STAGE" "$RW_DMG" "$DMG_PATH"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/$APP_NAME.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 可写镜像便于设置 Finder 窗口排版，再压缩为最终 DMG
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGE" -ov -fs HFS+ -format UDRW "$RW_DMG" >/dev/null
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG" | awk '/\/Volumes\//{print $1; exit}')
# 等待挂载点就绪
for _ in $(seq 1 30); do
    [ -d "$MOUNT" ] && break
    sleep 0.1
done

# 设置图标位置与窗口尺寸（失败不阻断）
osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOL_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 720, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "$APP_NAME.app" of container window to {140, 140}
        set position of item "Applications" of container window to {380, 140}
        update without registering applications
        delay 0.5
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null || true
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$STAGE" "$RW_DMG"
if [ -d "$ROOT/dist/$APP_NAME.app" ]; then
    find "$ROOT/dist/$APP_NAME.app" -depth -delete
fi

# 清理旧产物
find "$ROOT/dist" -maxdepth 1 -type f \( -name 'ClipBar-*.dmg' -o -name 'Clipboard-Manager-*.dmg' \) ! -name "ClipBar-${VERSION}.dmg" -delete 2>/dev/null || true

echo "DMG: $DMG_PATH"
