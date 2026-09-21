#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/build-common.sh"
ARCH="$(clipbar_arch "${1:-native}")"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")
NAME="ClipBar-$VERSION-$ARCH.dmg"
cd "$ROOT"
clipbar_prepare_app "$ARCH"
STAGE="$(mktemp -d "$ROOT/dist/.dmg-$ARCH.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/dist/$ARCH/ClipBar.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# 无需驱动 Finder 或固定挂载点，两种架构各自产出独立镜像。
hdiutil create -volname "ClipBar $ARCH" -srcfolder "$STAGE" -ov -fs HFS+ \
    -format UDZO "$ROOT/dist/$NAME" >/dev/null
hdiutil verify "$ROOT/dist/$NAME" >/dev/null
(cd "$ROOT/dist" && shasum -a 256 "$NAME" > "$NAME.sha256")
if [[ "${CLIPBAR_KEEP_APP:-0}" != "1" ]]; then
    rm -rf "$ROOT/dist/$ARCH/ClipBar.app"
fi
echo "DMG: $ROOT/dist/$NAME"
