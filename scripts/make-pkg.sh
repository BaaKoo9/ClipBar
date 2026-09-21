#!/bin/bash
set -euo pipefail

# 生成 .pkg 安装包：双击后由系统安装器自动装到 /Applications 并启动，
# 用户不需要手动拖拽。
#
# App 使用固定的本地自签名身份，升级时保持代码身份稳定。
# 没有 Developer ID Installer 证书，因此 pkg 本身仍未签名；
# 首次安装仍需右键 →「打开」绕过 Gatekeeper。

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ClipBar"
IDENTIFIER="com.huxiaolong.ClipBar"
source "$ROOT/scripts/build-common.sh"
ARCH="$(clipbar_arch "${1:-native}")"

cd "$ROOT"
clipbar_prepare_app "$ARCH"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")

WORK="$(mktemp -d "$ROOT/dist/.pkg-$ARCH.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/pkg-root"
SCRIPTS="$WORK/pkg-scripts"
COMPONENT="$WORK/component.pkg"
PKG_PATH="$ROOT/dist/ClipBar-$VERSION-$ARCH.pkg"
CHECKSUM_PATH="$PKG_PATH.sha256"

rm -rf "$STAGE" "$SCRIPTS" "$COMPONENT"
mkdir -p "$STAGE"
cp -R "$ROOT/dist/$ARCH/$APP_NAME.app" "$STAGE/"

# 复制脚本并确保可执行位（git 可能没保留权限）。
# 包内会多出 ._preinstall / ._postinstall 两个 AppleDouble 条目：
# 内核给新建文件自动打的 com.apple.provenance 属性无法移除（cp -X / xattr -c 都不行），
# pkgbuild 会把它编码进包。安装器按文件名精确执行脚本，这两个条目不会被运行，无影响。
mkdir -p "$SCRIPTS"
cp -X "$ROOT/scripts/pkg-scripts/preinstall" "$ROOT/scripts/pkg-scripts/postinstall" "$SCRIPTS/"
sed -i '' "s/@CLIPBAR_ARCH@/$ARCH/g" "$SCRIPTS/preinstall"
chmod +x "$SCRIPTS"/preinstall "$SCRIPTS"/postinstall

pkgbuild \
    --root "$STAGE" \
    --scripts "$SCRIPTS" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location "/Applications" \
    "$COMPONENT" >/dev/null

# 用 distribution 包一层：设置标题、关闭安装位置选择、限制最低系统版本
DIST="$WORK/distribution.xml"
cat > "$DIST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>ClipBar</title>
    <organization>com.huxiaolong</organization>
    <options customize="never" require-scripts="true" hostArchitectures="$ARCH"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="13.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default"/>
    </choices-outline>
    <choice id="default" title="ClipBar">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML

productbuild \
    --distribution "$DIST" \
    --package-path "$WORK" \
    "$PKG_PATH" >/dev/null

# 旧版 Release 或 DMG 校验缺失时，自动更新仍可用该文件安全回退到 pkg。
# 哈希覆盖安装脚本和 App 载荷，因此签名证书换代不会让更新器误判失败。
(
    cd "$ROOT/dist"
    shasum -a 256 "ClipBar-$VERSION-$ARCH.pkg" > "ClipBar-$VERSION-$ARCH.pkg.sha256"
)

rm -rf "$STAGE" "$SCRIPTS" "$COMPONENT" "$DIST"
if [[ "${CLIPBAR_KEEP_APP:-0}" != "1" && -d "$ROOT/dist/$ARCH/$APP_NAME.app" ]]; then
    find "$ROOT/dist/$ARCH/$APP_NAME.app" -depth -delete
fi

echo "PKG 已生成: $PKG_PATH"
echo "SHA-256: $CHECKSUM_PATH"
