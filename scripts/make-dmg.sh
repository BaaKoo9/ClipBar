#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Clipboard Manager"

cd "$ROOT"
./scripts/build-app.sh release

STAGE="$ROOT/dist/dmg-stage"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/$APP_NAME.app" "$STAGE/"

DMG_PATH="$ROOT/dist/Clipboard-Manager.dmg"
hdiutil create -volname "Clipboard Manager" \
    -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG_PATH" >/dev/null

echo "DMG 已生成: $DMG_PATH"
