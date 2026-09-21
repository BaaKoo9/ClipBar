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
for architecture in arm64 x86_64; do
    for extension in pkg dmg; do
        (cd "$ROOT/dist" && shasum -a 256 -c "ClipBar-$VERSION-$architecture.$extension.sha256")
    done
done
python3 "$ROOT/scripts/verify-release-artifacts.py"
echo "双架构制品已生成。仅发布带 arm64 / x86_64 后缀的 8 个文件。"
