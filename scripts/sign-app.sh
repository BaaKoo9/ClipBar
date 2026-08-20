#!/bin/bash
set -euo pipefail

APP_PATH="${1:-}"
IDENTITY="${CLIPBAR_SIGNING_IDENTITY:-ClipBar Local Distribution}"
KEYCHAIN="${CLIPBAR_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/clipboard-dev.keychain-db}"
ALLOW_ADHOC="${CLIPBAR_ALLOW_ADHOC:-0}"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "用法: $0 /path/to/ClipBar.app" >&2
    exit 1
fi

security unlock-keychain -p "" "$KEYCHAIN" 2>/dev/null || true
if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null \
    | grep -Fq "\"$IDENTITY\""; then
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp=none \
        --keychain "$KEYCHAIN" \
        --sign "$IDENTITY" \
        "$APP_PATH"
    echo "已使用固定身份签名: $IDENTITY"
elif [ "$ALLOW_ADHOC" = "1" ]; then
    codesign --force --deep --sign - "$APP_PATH"
    echo "警告：已按 CLIPBAR_ALLOW_ADHOC=1 使用临时 ad-hoc 签名" >&2
else
    echo "错误：缺少固定签名身份 '$IDENTITY'" >&2
    echo "请先运行 ./scripts/create-local-signing-identity.sh" >&2
    echo "仅临时调试可显式设置 CLIPBAR_ALLOW_ADHOC=1" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
