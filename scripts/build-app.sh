#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="Clipboard Manager"

cd "$ROOT"
swift build -c "$CONFIG"

APP_DIR="$ROOT/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT/.build/$CONFIG/ClipboardManager" "$APP_DIR/Contents/MacOS/"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR"

echo "构建完成: $APP_DIR"
