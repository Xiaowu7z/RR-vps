#!/usr/bin/env python3
"""RR-vps 发版构建：版本同步 + manifest 重算 + bundle 重建 + install.sh hash 回写。

用法: python3 scripts/rebuild-bundle.py [版本号]
不带参数时使用 version 文件第一行的当前版本（适用于功能改动不升版本时）。
"""
import hashlib
import io
import os
import re
import sys
import tarfile

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_FILE = os.path.join(BASE, "version")
INSTALL_SH = os.path.join(BASE, "install.sh")
MANIFEST = os.path.join(BASE, "manifest.sha256")
BUNDLE = os.path.join(BASE, "rr-bundle.tar.gz")

MANIFEST_FILES = (
    ["rr"]
    + [f"modules/{m}" for m in sorted(os.listdir(os.path.join(BASE, "modules"))) if m.endswith(".sh")]
    + [
        "nexus/rr_nexus.py",
        "nexus/static/index.html",
        "nexus/static/app.js",
        "nexus/static/app.css",
    ]
)
BUNDLE_MEMBERS = MANIFEST_FILES + [
    "install.sh",
    "manifest.sha256",
    "scripts/pre-push-test.sh",
    "scripts/validate.sh",
]
# 可执行位必须保留：cp -a 按 bundle 内 mode 复制，
# launcher 被覆盖成 0644 会直接 Permission denied（2026-08 真机事故）。
EXEC_MEMBERS = {"rr", "install.sh", "scripts/pre-push-test.sh", "scripts/validate.sh"}


def main() -> int:
    ver = sys.argv[1] if len(sys.argv) > 1 else None
    if ver is None:
        first = open(VERSION_FILE, encoding="utf-8").read().strip().splitlines()[0]
        m = re.search(r"(\d+\.\d+\.\d+)", first)
        ver = m.group(1) if m else None
        if not ver:
            print("version 文件第一行无版本号，需显式传参", file=sys.stderr)
            return 1
    print(f"[1/4] 版本号 → {ver}")

    # 同步三处版本号（version / 00-runtime.sh / install.sh ?v=）
    open(VERSION_FILE, "w", encoding="utf-8").write(
        f"RR-vps {ver}\nSing-box v1.13.18\n"
    )
    c = open(os.path.join(BASE, "modules/00-runtime.sh"), encoding="utf-8").read()
    c = re.sub(r'SCRIPT_VERSION="[0-9.]+"', f'SCRIPT_VERSION="{ver}"', c)
    open(os.path.join(BASE, "modules/00-runtime.sh"), "w", encoding="utf-8").write(c)
    c = open(INSTALL_SH, encoding="utf-8").read()
    c = re.sub(r"manifest\.sha256\?v=[0-9.]+", f"manifest.sha256?v={ver}", c)
    open(INSTALL_SH, "w", encoding="utf-8").write(c)
    print("[1/4] 三处版本号同步完成")

    print("[2/4] 重算 manifest.sha256")
    lines = []
    for f in MANIFEST_FILES:
        h = hashlib.sha256(open(os.path.join(BASE, f), "rb").read()).hexdigest()
        lines.append(f"{h}  {f}")
    open(MANIFEST, "w", encoding="utf-8").write("\n".join(lines) + "\n")

    print("[3/4] 重建 rr-bundle.tar.gz")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for f in BUNDLE_MEMBERS:
            raw = open(os.path.join(BASE, f), "rb").read()
            info = tarfile.TarInfo(name=f"rr-bundle/{f}")
            info.size = len(raw)
            info.mtime = 0
            info.mode = 0o755 if f in EXEC_MEMBERS else 0o644
            tar.addfile(info, io.BytesIO(raw))
    open(BUNDLE, "wb").write(buf.getvalue())
    bundle_hash = hashlib.sha256(open(BUNDLE, "rb").read()).hexdigest()

    print("[4/4] 回写 install.sh 的 bundle hash 行")
    c = open(INSTALL_SH, encoding="utf-8").read()
    if not re.search(r'\[ "\$actual" = "[0-9a-f]{64}" \]', c):
        print("错误：install.sh 中未找到 bundle hash 行", file=sys.stderr)
        return 1
    c = re.sub(
        r'\[ "\$actual" = "[0-9a-f]{64}" \]',
        f'[ "$actual" = "{bundle_hash}" ]',
        c,
    )
    open(INSTALL_SH, "w", encoding="utf-8").write(c)

    with tarfile.open(BUNDLE) as t:
        zero = [m.name for m in t.getmembers() if m.size == 0]
    print(f"完成：{len(BUNDLE_MEMBERS)} 成员，bundle {bundle_hash[:16]}…，0字节成员: {zero if zero else '无'}")
    print("下一步：bash scripts/pre-push-test.sh")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
