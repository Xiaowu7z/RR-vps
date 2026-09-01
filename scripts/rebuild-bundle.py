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
import stat
import sys
import tarfile
from pathlib import Path


BASE = Path(__file__).resolve().parent.parent
VERSION_FILE = BASE / "version"
RUNTIME_FILE = BASE / "modules/00-runtime.sh"
INSTALL_SH = BASE / "install.sh"
INSTALL_CORE = BASE / "scripts/install-core.sh"
UPDATE_GUARD = BASE / "scripts/update-guard.sh"
MANIFEST = BASE / "manifest.sha256"
BUNDLE = BASE / "rr-bundle.tar.gz"

RELEASE_MEMBER_PATTERN = re.compile(
    r"^(?:rr|"
    r"scripts/(?:naive-cert-hook|update-recover)\.sh|"
    r"scripts/update-external-state\.py|"
    r"modules/[0-9][0-9A-Za-z_-]*\.sh|"
    r"nexus/(?:rr_nexus|sub_server)\.py|"
    r"nexus/rr_nexus_lib/[A-Za-z0-9._-]+\.py|"
    r"nexus/static/[A-Za-z0-9._-]+\.(?:html|css|js)|"
    r"manifest\.sha256)$"
)
NEXUS_SOURCE_SUFFIXES = {".py", ".html", ".css", ".js"}
USTAR_NAME_BYTES = 100


def validate_release_member(relative: str, path: Path | None = None) -> None:
    """Apply the installer's fixed payload schema before manifesting a file.

    The bootstrap and runtime validators intentionally accept only three
    fixed Nexus levels.  Refusing deeper source paths here keeps the generated
    manifest and the raw-tar allow-list identical.  Archive names are also
    kept in the fixed USTAR name field: this prevents an implicit PAX/GNU
    extension from ever becoming part of a supposedly deterministic bundle.
    """

    if not RELEASE_MEMBER_PATTERN.fullmatch(relative):
        raise ValueError(f"发布路径超出安装器固定层级：{relative}")
    try:
        archive_name = f"rr-bundle/{relative}".encode("ascii")
    except UnicodeEncodeError as exc:
        raise ValueError(f"发布路径必须是 ASCII：{relative}") from exc
    if len(archive_name) > USTAR_NAME_BYTES:
        raise ValueError(f"发布成员名超过 USTAR 100 字节限制：{relative}")
    if path is None:
        return
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        raise ValueError(f"无法读取发布文件类型：{relative}") from exc
    if not stat.S_ISREG(mode):
        raise ValueError(f"发布成员必须是普通文件：{relative}")

def release_files() -> list[str]:
    """Return the complete runtime payload in a deterministic order.

    Nexus discovery is recursive only so schema drift is detected rather than
    silently omitted.  The accepted files deliberately match the installer's
    fixed copy contract: two root entry points, one flat library package and
    one flat static directory.
    """

    members = [
        "rr",
        "scripts/naive-cert-hook.sh",
        "scripts/update-recover.sh",
        "scripts/update-external-state.py",
    ]
    members.extend(
        f"modules/{path.name}"
        for path in sorted((BASE / "modules").glob("*.sh"), key=lambda item: item.name)
    )
    nexus_root = BASE / "nexus"
    for path in sorted(nexus_root.rglob("*"), key=lambda item: item.as_posix()):
        if "__pycache__" in path.parts or path.suffix not in NEXUS_SOURCE_SUFFIXES:
            continue
        relative = path.relative_to(BASE).as_posix()
        validate_release_member(relative, path)
        members.append(relative)
    for relative in members:
        validate_release_member(relative, BASE / relative)
    return members


MANIFEST_FILES = release_files()
# The bundle is an install payload, not a source snapshot. Keeping install.sh
# inside it made the archive self-referential because install.sh pins the bundle
# digest. Test scripts also do not belong in /usr/local/lib/rr.
BUNDLE_MEMBERS = MANIFEST_FILES + ["manifest.sha256"]
EXEC_MEMBERS = {
    "rr",
    "scripts/naive-cert-hook.sh",
    "scripts/update-recover.sh",
    "scripts/update-external-state.py",
    *[item for item in MANIFEST_FILES if item.endswith(".py")],
}
BUNDLE_HASH_PATTERN = re.compile(r'\[ "\$actual" = "([0-9a-f]{64})" \]')
CORE_PIN_PATTERN = re.compile(r'^RR_CORE_SHA256="([0-9a-f]{64})"$', re.MULTILINE)
GUARD_PIN_PATTERN = re.compile(r'^RR_GUARD_SHA256="([0-9a-f]{64})"$', re.MULTILINE)
RELEASE_TAG_PATTERN = re.compile(
    r'^RR_RELEASE_TAG="v([0-9]+\.[0-9]+\.[0-9]+)"$', re.MULTILINE
)
VERSION_PATTERN = re.compile(r"^(\d+\.\d+\.\d+)$")


def write_text_lf(path: Path, value: str) -> None:
    """Write deterministic UTF-8/LF text even on a Windows release host."""
    path.write_bytes(value.replace("\r\n", "\n").replace("\r", "\n").encode("utf-8"))


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
    write_text_lf(VERSION_FILE, "\n".join([f"RR-vps {version}", *lines[1:]]) + "\n")

    runtime = RUNTIME_FILE.read_text(encoding="utf-8")
    updated, count = re.subn(
        r'SCRIPT_VERSION="[0-9.]+"',
        f'SCRIPT_VERSION="{version}"',
        runtime,
        count=1,
    )
    if count != 1:
        raise ValueError("modules/00-runtime.sh 中 SCRIPT_VERSION 不唯一或不存在")
    write_text_lf(RUNTIME_FILE, updated)

    for path in (INSTALL_SH, INSTALL_CORE):
        source = path.read_text(encoding="utf-8")
        source, tag_count = RELEASE_TAG_PATTERN.subn(
            f'RR_RELEASE_TAG="v{version}"', source, count=1
        )
        if tag_count != 1:
            raise ValueError(f"{path.name} 中 RR_RELEASE_TAG 不唯一或不存在")
        write_text_lf(path, source)


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
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        for relative in BUNDLE_MEMBERS:
            validate_release_member(
                relative, None if relative == "manifest.sha256" else BASE / relative
            )
            raw = manifest_raw if relative == "manifest.sha256" else (BASE / relative).read_bytes()
            info = tarfile.TarInfo(name=f"rr-bundle/{relative}")
            info.size = len(raw)
            info.mtime = 0
            info.mode = 0o755 if relative in EXEC_MEMBERS else 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.type = tarfile.REGTYPE
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
            if not member.isfile() or member.type != tarfile.REGTYPE or member.pax_headers or member.size <= 0:
                raise ValueError(f"bundle 含非普通文件或空文件：{member.name}")
            relative = member.name.removeprefix("rr-bundle/")
            expected_mode = 0o755 if relative in EXEC_MEMBERS else 0o644
            if member.mode != expected_mode:
                raise ValueError(f"bundle 权限错误：{member.name} {oct(member.mode)}")
        packed_manifest = archive.extractfile("rr-bundle/manifest.sha256")
        if packed_manifest is None or packed_manifest.read() != manifest_raw:
            raise ValueError("bundle 内 manifest.sha256 与仓库不一致")


def pinned_bundle_hash() -> str:
    core = INSTALL_CORE.read_text(encoding="utf-8")
    matches = BUNDLE_HASH_PATTERN.findall(core)
    if len(matches) != 1:
        raise ValueError("install.sh 中 bundle SHA256 固定值不唯一或不存在")
    return matches[0]


def update_pinned_bundle_hash(digest: str) -> None:
    core = INSTALL_CORE.read_text(encoding="utf-8")
    updated, count = BUNDLE_HASH_PATTERN.subn(
        f'[ "$actual" = "{digest}" ]', core, count=1
    )
    if count != 1:
        raise ValueError("install.sh 中 bundle SHA256 固定值不唯一或不存在")
    write_text_lf(INSTALL_CORE, updated)
    # Keep the historical validation anchor synchronized for 7.0 clients and
    # repository regression tests; the executable comparison lives in core.
    install = INSTALL_SH.read_text(encoding="utf-8")
    install, anchor_count = BUNDLE_HASH_PATTERN.subn(
        f'[ "$actual" = "{digest}" ]', install, count=1
    )
    if anchor_count != 1:
        raise ValueError("install.sh 中 bundle SHA256 兼容锚点不唯一或不存在")
    write_text_lf(INSTALL_SH, install)


def update_bootstrap_pins() -> None:
    install = INSTALL_SH.read_text(encoding="utf-8")
    core_digest = sha256(INSTALL_CORE.read_bytes())
    guard_digest = sha256(UPDATE_GUARD.read_bytes())
    install, core_count = CORE_PIN_PATTERN.subn(
        f'RR_CORE_SHA256="{core_digest}"', install, count=1
    )
    install, guard_count = GUARD_PIN_PATTERN.subn(
        f'RR_GUARD_SHA256="{guard_digest}"', install, count=1
    )
    if core_count != 1 or guard_count != 1:
        raise ValueError("install.sh 引导器 SHA256 锚点缺失")
    write_text_lf(INSTALL_SH, install)


def verify_bootstrap_pins() -> None:
    install = INSTALL_SH.read_text(encoding="utf-8")
    core = CORE_PIN_PATTERN.findall(install)
    guard = GUARD_PIN_PATTERN.findall(install)
    if core != [sha256(INSTALL_CORE.read_bytes())]:
        raise ValueError("核心安装器 SHA256 锚点过期")
    if guard != [sha256(UPDATE_GUARD.read_bytes())]:
        raise ValueError("热更新保险模块 SHA256 锚点过期")


def check() -> int:
    version = read_version()
    runtime_versions = re.findall(
        r'SCRIPT_VERSION="([0-9.]+)"', RUNTIME_FILE.read_text(encoding="utf-8")
    )
    if runtime_versions != [version]:
        raise ValueError(
            f"版本不同步：version={version}, SCRIPT_VERSION={runtime_versions or '缺失'}"
        )
    for path in (INSTALL_SH, INSTALL_CORE):
        tags = RELEASE_TAG_PATTERN.findall(path.read_text(encoding="utf-8"))
        if tags != [version]:
            raise ValueError(
                f"发布 Tag 不同步：{path.name}={tags or '缺失'}, version={version}"
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
    verify_bootstrap_pins()
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

    print("[4/4] 更新 bundle 与引导器 SHA256 锚点")
    digest = sha256(bundle_raw)
    update_pinned_bundle_hash(digest)
    update_bootstrap_pins()
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
