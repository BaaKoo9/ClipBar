#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="ClipBar"
PRODUCT_NAME="ClipBar"

cd "$ROOT"

# 图标不存在时先生成
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "生成 App 图标…"
    swift Tools/GenerateIcon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c "$CONFIG" --product "$PRODUCT_NAME"

APP_DIR="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT/.build/$CONFIG/$PRODUCT_NAME" "$APP_DIR/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"

"$ROOT/scripts/sign-app.sh" "$APP_DIR"

echo "构建完成: $APP_DIR"
