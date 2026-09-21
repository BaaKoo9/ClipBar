#!/usr/bin/env python3
"""解包验证当前版本的两套分架构制品，不安装或启动 App。"""
import hashlib
import pathlib
import plistlib
import re
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
with (ROOT / "Resources/Info.plist").open("rb") as source:
    metadata = plistlib.load(source)
    VERSION = metadata["CFBundleShortVersionString"]
    MINIMUM_OS = metadata["LSMinimumSystemVersion"]


def run(*args):
    return subprocess.check_output(args, stderr=subprocess.PIPE)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_app(app, architecture):
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    require(info["CFBundleShortVersionString"] == VERSION, "App 版本错误")
    require(info["CFBundleIdentifier"] == "com.huxiaolong.ClipBar", "App 标识错误")
    require(info["LSMinimumSystemVersion"] == MINIMUM_OS, "App 最低系统错误")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", str(app))
    fingerprints = []
    for executable in ("ClipBar", "ClipBarUpdater"):
        binary = app / "Contents/MacOS" / executable
        actual = run("/usr/bin/lipo", "-archs", str(binary)).decode().strip()
        require(actual == architecture, f"{binary}: {actual} != {architecture}")
        load_commands = run("/usr/bin/vtool", "-show-build", str(binary)).decode()
        minimum = re.search(r"minos\s+(\d+\.\d+(?:\.\d+)?)", load_commands)
        require(minimum is not None and minimum.group(1) == MINIMUM_OS, f"{binary}: 最低系统不符")
        fingerprints.append(digest(binary))
    return fingerprints


for architecture in ("arm64", "x86_64"):
    stem = f"ClipBar-{VERSION}-{architecture}"
    fingerprints = {}
    for extension in ("pkg", "dmg"):
        artifact = DIST / f"{stem}.{extension}"
        checksum = pathlib.Path(str(artifact) + ".sha256").read_text().split()
        require(checksum == [digest(artifact), artifact.name], f"校验文件错误: {artifact.name}")
        if extension == "pkg":
            with tempfile.TemporaryDirectory(prefix="clipbar-verify-") as work:
                expanded = pathlib.Path(work) / "expanded"
                run("/usr/sbin/pkgutil", "--expand-full", str(artifact), str(expanded))
                distribution = (expanded / "Distribution").read_text()
                require(f'hostArchitectures="{architecture}"' in distribution, "PKG hostArchitectures 错误")
                require(f'min="{MINIMUM_OS}"' in distribution, "PKG 最低系统错误")
                preinstall = (expanded / "component.pkg/Scripts/preinstall").read_text()
                require(f'expected="{architecture}"' in preinstall, "PKG 安装脚本架构错误")
                fingerprints[extension] = verify_app(expanded / "component.pkg/Payload/ClipBar.app", architecture)
        else:
            run("/usr/bin/hdiutil", "verify", str(artifact))
            mounted = plistlib.loads(run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(artifact)))
            volume = next(entity["mount-point"] for entity in mounted["system-entities"] if "mount-point" in entity)
            try:
                fingerprints[extension] = verify_app(pathlib.Path(volume) / "ClipBar.app", architecture)
            finally:
                run("/usr/bin/hdiutil", "detach", volume)
        print(f"通过: {artifact.name}（SHA-256、版本、签名、双可执行文件架构）", flush=True)
    require(fingerprints["pkg"] == fingerprints["dmg"], f"{architecture}: PKG/DMG 内容不一致")

for extension in ("pkg", "dmg"):
    legacy = DIST / f"ClipBar-{VERSION}.{extension}"
    require(not legacy.exists() and not pathlib.Path(str(legacy) + ".sha256").exists(),
            "请移除无架构后缀的旧制品及校验文件，发布时仅保留 arm64 / x86_64 两套")
print("两套分架构制品、PKG/DMG 内容一致性及明确命名检查均通过（8 个附件）。")
