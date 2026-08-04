#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Clipboard Manager"

cd "$ROOT"

# 图标不存在时先生成
if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "生成 App 图标…"
    swift Tools/GenerateIcon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi

swift build -c "$CONFIG" --product ClipboardManager

APP_DIR="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT/.build/$CONFIG/ClipboardManager" "$APP_DIR/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"

security unlock-keychain -p "" "$HOME/Library/Keychains/clipboard-dev.keychain-db" 2>/dev/null || true
if security find-identity -p codesigning 2>/dev/null | grep -q "Clipboard Manager Dev"; then
    codesign --force --deep --sign "Clipboard Manager Dev" "$APP_DIR"
else
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "构建完成: $APP_DIR"
