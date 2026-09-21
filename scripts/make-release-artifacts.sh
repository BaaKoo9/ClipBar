#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
for architecture in arm64 x86_64; do
    ./scripts/build-app.sh release "$architecture"
    CLIPBAR_REUSE_BUILD=1 CLIPBAR_KEEP_APP=1 ./scripts/make-pkg.sh "$architecture"
    CLIPBAR_REUSE_BUILD=1 ./scripts/make-dmg.sh "$architecture"
done
# 旧版没有架构筛选，精确旧名必须始终指向 ARM，避免它任意挑中 Intel 包。
for extension in pkg dmg; do
    cp "$ROOT/dist/ClipBar-$VERSION-arm64.$extension" "$ROOT/dist/ClipBar-$VERSION.$extension"
    (cd "$ROOT/dist" && shasum -a 256 "ClipBar-$VERSION.$extension" > "ClipBar-$VERSION.$extension.sha256")
done
for checksum in "$ROOT/dist/ClipBar-$VERSION"*.sha256; do
    (cd "$ROOT/dist" && shasum -a 256 -c "$checksum")
done
python3 "$ROOT/scripts/verify-release-artifacts.py"
echo "双架构制品及旧版 ARM 兼容别名已生成。发布本版本的全部 12 个文件。"
