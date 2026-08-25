#!/usr/bin/env python3
"""Build and verify the RR-vps release manifest and deterministic bundle.

Usage:
  python3 scripts/rebuild-bundle.py [VERSION]
  python3 scripts/rebuild-bundle.py --check

Without VERSION the RR version is read from the first line of ``version``.
``--check`` is read-only and fails when any generated release artifact is stale.
"""

from __future__ import annotations

import gzip
import hashlib
import io
import re
import sys
import tarfile
from pathlib import Path


BASE = Path(__file__).resolve().parent.parent
VERSION_FILE = BASE / "version"
RUNTIME_FILE = BASE / "modules/00-runtime.sh"
INSTALL_SH = BASE / "install.sh"
MANIFEST = BASE / "manifest.sha256"
BUNDLE = BASE / "rr-bundle.tar.gz"

MANIFEST_FILES = (
    ["rr"]
    + [
        f"modules/{path.name}"
        for path in sorted((BASE / "modules").glob("*.sh"), key=lambda item: item.name)
    ]
    + [
        "nexus/rr_nexus.py",
        "nexus/static/index.html",
        "nexus/static/app.js",
        "nexus/static/app.css",
        "nexus/static/optimizer.js",
        "nexus/static/optimizer.css",
    ]
)
# The bundle is an install payload, not a source snapshot. Keeping install.sh
# inside it made the archive self-referential because install.sh pins the bundle
# digest. Test scripts also do not belong in /usr/local/lib/rr.
BUNDLE_MEMBERS = MANIFEST_FILES + ["manifest.sha256"]
EXEC_MEMBERS = {"rr"}
BUNDLE_HASH_PATTERN = re.compile(r'\[ "\$actual" = "([0-9a-f]{64})" \]')
VERSION_PATTERN = re.compile(r"^(\d+\.\d+\.\d+)$")


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def read_version() -> str:
    lines = VERSION_FILE.read_text(encoding="utf-8").splitlines()
    if not lines:
        raise ValueError("version 文件为空")
    match = re.fullmatch(r"RR-vps (\d+\.\d+\.\d+)", lines[0])
    if not match:
        raise ValueError("version 文件第一行格式应为 RR-vps X.Y.Z")
    return match.group(1)


def sync_version(version: str) -> None:
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError(f"版本号格式无效：{version}")

    lines = VERSION_FILE.read_text(encoding="utf-8").splitlines()
    VERSION_FILE.write_text(
        "\n".join([f"RR-vps {version}", *lines[1:]]) + "\n",
        encoding="utf-8",
    )

    runtime = RUNTIME_FILE.read_text(encoding="utf-8")
    updated, count = re.subn(
        r'SCRIPT_VERSION="[0-9.]+"',
        f'SCRIPT_VERSION="{version}"',
        runtime,
        count=1,
    )
    if count != 1:
        raise ValueError("modules/00-runtime.sh 中 SCRIPT_VERSION 不唯一或不存在")
    RUNTIME_FILE.write_text(updated, encoding="utf-8")


def expected_manifest() -> bytes:
    lines: list[str] = []
    for relative in MANIFEST_FILES:
        path = BASE / relative
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"发布文件缺失或为空：{relative}")
        lines.append(f"{sha256(path.read_bytes())}  {relative}")
    return ("\n".join(lines) + "\n").encode()


def expected_bundle(manifest_raw: bytes) -> bytes:
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.PAX_FORMAT) as archive:
        for relative in BUNDLE_MEMBERS:
            raw = manifest_raw if relative == "manifest.sha256" else (BASE / relative).read_bytes()
            info = tarfile.TarInfo(name=f"rr-bundle/{relative}")
            info.size = len(raw)
            info.mtime = 0
            info.mode = 0o755 if relative in EXEC_MEMBERS else 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            archive.addfile(info, io.BytesIO(raw))

    gzip_buffer = io.BytesIO()
    with gzip.GzipFile(
        filename="",
        mode="wb",
        fileobj=gzip_buffer,
        compresslevel=9,
        mtime=0,
    ) as compressed:
        compressed.write(tar_buffer.getvalue())
    return gzip_buffer.getvalue()


def verify_bundle_structure(bundle_raw: bytes, manifest_raw: bytes) -> None:
    expected_names = [f"rr-bundle/{item}" for item in BUNDLE_MEMBERS]
    with tarfile.open(fileobj=io.BytesIO(bundle_raw), mode="r:gz") as archive:
        members = archive.getmembers()
        names = [member.name for member in members]
        if names != expected_names:
            raise ValueError("bundle 成员、顺序或覆盖范围不正确")
        for member in members:
            if not member.isfile() or member.size <= 0:
                raise ValueError(f"bundle 含非普通文件或空文件：{member.name}")
            expected_mode = 0o755 if member.name == "rr-bundle/rr" else 0o644
            if member.mode != expected_mode:
                raise ValueError(f"bundle 权限错误：{member.name} {oct(member.mode)}")
        packed_manifest = archive.extractfile("rr-bundle/manifest.sha256")
        if packed_manifest is None or packed_manifest.read() != manifest_raw:
            raise ValueError("bundle 内 manifest.sha256 与仓库不一致")


def pinned_bundle_hash() -> str:
    install = INSTALL_SH.read_text(encoding="utf-8")
    matches = BUNDLE_HASH_PATTERN.findall(install)
    if len(matches) != 1:
        raise ValueError("install.sh 中 bundle SHA256 固定值不唯一或不存在")
    return matches[0]


def update_pinned_bundle_hash(digest: str) -> None:
    install = INSTALL_SH.read_text(encoding="utf-8")
    updated, count = BUNDLE_HASH_PATTERN.subn(
        f'[ "$actual" = "{digest}" ]', install, count=1
    )
    if count != 1:
        raise ValueError("install.sh 中 bundle SHA256 固定值不唯一或不存在")
    INSTALL_SH.write_text(updated, encoding="utf-8")


def check() -> int:
    version = read_version()
    runtime_versions = re.findall(
        r'SCRIPT_VERSION="([0-9.]+)"', RUNTIME_FILE.read_text(encoding="utf-8")
    )
    if runtime_versions != [version]:
        raise ValueError(
            f"版本不同步：version={version}, SCRIPT_VERSION={runtime_versions or '缺失'}"
        )

    manifest_raw = expected_manifest()
    if not MANIFEST.is_file() or MANIFEST.read_bytes() != manifest_raw:
        raise ValueError("manifest.sha256 已过期；请运行 scripts/rebuild-bundle.py")

    bundle_raw = expected_bundle(manifest_raw)
    if not BUNDLE.is_file() or BUNDLE.read_bytes() != bundle_raw:
        raise ValueError("rr-bundle.tar.gz 不可复现或已过期；请重新构建")
    verify_bundle_structure(bundle_raw, manifest_raw)

    digest = sha256(bundle_raw)
    if pinned_bundle_hash() != digest:
        raise ValueError("install.sh 固定的 bundle SHA256 与发布包不一致")
    print(
        f"release check passed: RR-vps {version}, "
        f"{len(BUNDLE_MEMBERS)} members, sha256={digest}"
    )
    return 0


def build(version: str) -> int:
    print(f"[1/4] 同步 RR-vps 版本：{version}")
    sync_version(version)

    print("[2/4] 重算 manifest.sha256")
    manifest_raw = expected_manifest()
    MANIFEST.write_bytes(manifest_raw)

    print("[3/4] 生成确定性 rr-bundle.tar.gz")
    bundle_raw = expected_bundle(manifest_raw)
    BUNDLE.write_bytes(bundle_raw)

    print("[4/4] 更新 install.sh 固定的 bundle SHA256")
    digest = sha256(bundle_raw)
    update_pinned_bundle_hash(digest)
    verify_bundle_structure(bundle_raw, manifest_raw)
    print(f"完成：{len(BUNDLE_MEMBERS)} 个成员，bundle sha256={digest}")
    print("下一步：python3 scripts/rebuild-bundle.py --check && bash scripts/pre-push-test.sh")
    return 0


def main() -> int:
    try:
        if len(sys.argv) == 2 and sys.argv[1] == "--check":
            return check()
        if len(sys.argv) > 2:
            print(__doc__, file=sys.stderr)
            return 2
        version = sys.argv[1] if len(sys.argv) == 2 else read_version()
        return build(version)
    except (OSError, ValueError, tarfile.TarError) as exc:
        print(f"release build failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
