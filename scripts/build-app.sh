#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="ClipBar"
PRODUCT_NAME="ClipBar"
source "$ROOT/scripts/build-common.sh"
ARCH="$(clipbar_arch "${2:-native}")"
BUILD_ARGS=(-c "$CONFIG" --arch "$ARCH" --scratch-path "$ROOT/.build/$ARCH")

cd "$ROOT"

# 图标不存在时先生成
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "生成 App 图标…"
    swift Tools/GenerateIcon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build "${BUILD_ARGS[@]}" --product "$PRODUCT_NAME"
swift build "${BUILD_ARGS[@]}" --product "ClipBarUpdater"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP_DIR="$ROOT/dist/$ARCH/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/$PRODUCT_NAME" "$APP_DIR/Contents/MacOS/"
cp "$BIN_DIR/ClipBarUpdater" "$APP_DIR/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"

for executable in ClipBar ClipBarUpdater; do
    actual="$(lipo -archs "$APP_DIR/Contents/MacOS/$executable")"
    [[ "$actual" == "$ARCH" ]] || { echo "架构错误: $executable ($actual != $ARCH)" >&2; exit 1; }
done
"$ROOT/scripts/sign-app.sh" "$APP_DIR"

echo "构建完成: $APP_DIR"
