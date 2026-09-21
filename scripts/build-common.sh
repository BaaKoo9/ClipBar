#!/bin/bash
# native 按硬件识别，避免 Rosetta 把 M 系列误认为 Intel。
clipbar_arch() {
    local target="${1:-native}"
    if [[ "$target" == "native" ]]; then
        target="$(uname -m)"
        if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == "1" ]]; then
            target="arm64"
        fi
    fi
    case "$target" in
        arm64|x86_64) printf '%s\n' "$target" ;;
        *) echo "不支持的架构: $target（仅支持 arm64 / x86_64）" >&2; return 1 ;;
    esac
}

# 发布整套制品时复用刚签名的 App，保证 PKG 与 DMG 载荷逐字节一致。
clipbar_prepare_app() {
    local architecture="$1"
    local app="$ROOT/dist/$architecture/ClipBar.app"
    if [[ "${CLIPBAR_REUSE_BUILD:-0}" != "1" ]]; then
        "$ROOT/scripts/build-app.sh" release "$architecture"
        return
    fi
    local expected_version actual_version executable actual
    expected_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")
    actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
    [[ "$actual_version" == "$expected_version" ]] || { echo "复用 App 版本不符" >&2; return 1; }
    for executable in ClipBar ClipBarUpdater; do
        actual="$(lipo -archs "$app/Contents/MacOS/$executable")"
        [[ "$actual" == "$architecture" ]] || { echo "复用 App 架构不符" >&2; return 1; }
    done
    codesign --verify --deep --strict "$app"
}
