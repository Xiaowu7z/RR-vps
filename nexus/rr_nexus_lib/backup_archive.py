"""Bounded validation and extraction for RR portable backup payloads."""

from __future__ import annotations

import argparse
import os
import pathlib
import shutil
import stat
import sys
import tarfile
from dataclasses import dataclass


MAX_MEMBERS = 10_000
MAX_EXPANDED_BYTES = 2 * 1024**3
MAX_ARCHIVE_BYTES = MAX_EXPANDED_BYTES + 16 * 1024**2
FREE_SPACE_RESERVE_BYTES = 256 * 1024**2
MAX_PATH_BYTES = 4096
MAX_PATH_COMPONENT_BYTES = 255
MAX_EXTENDED_HEADER_BYTES = 64 * 1024
MAX_EXTENDED_HEADERS = 64
MAX_TOTAL_EXTENDED_HEADER_BYTES = 1024 * 1024
MAX_METADATA_BYTES = 64 * 1024
MAX_CRONTAB_BYTES = 4 * 1024
MAX_MANIFEST_BYTES = 50 * 1024**2


class BackupArchiveError(ValueError):
    """The archive cannot be handled within RR's portable-backup contract."""


class BoundedTarInfo(tarfile.TarInfo):
    """Stop oversized metadata before tarfile allocates its declared body."""

    def _charge_extended_header(self, archive: tarfile.TarFile) -> None:
        count = int(getattr(archive, "_rr_extended_header_count", 0)) + 1
        total = int(getattr(archive, "_rr_extended_header_bytes", 0)) + self.size
        if count > MAX_EXTENDED_HEADERS or total > MAX_TOTAL_EXTENDED_HEADER_BYTES:
            raise BackupArchiveError("archive has excessive extended metadata")
        archive._rr_extended_header_count = count  # type: ignore[attr-defined]
        archive._rr_extended_header_bytes = total  # type: ignore[attr-defined]

    def _proc_pax(self, archive: tarfile.TarFile):  # type: ignore[no-untyped-def]
        if self.size > MAX_EXTENDED_HEADER_BYTES:
            raise BackupArchiveError("oversized PAX header")
        self._charge_extended_header(archive)
        return super()._proc_pax(archive)

    def _proc_gnulong(self, archive: tarfile.TarFile):  # type: ignore[no-untyped-def]
        if self.size > MAX_PATH_BYTES + tarfile.BLOCKSIZE:
            raise BackupArchiveError("oversized GNU long-name header")
        self._charge_extended_header(archive)
        return super()._proc_gnulong(archive)

    def _proc_sparse(self, archive: tarfile.TarFile):  # type: ignore[no-untyped-def]
        raise BackupArchiveError("sparse archive members are unsupported")


@dataclass(frozen=True)
class ArchiveSummary:
    members: int
    expanded_bytes: int


def _path_parts(name: str, *, directory: bool) -> tuple[str, ...]:
    try:
        encoded = name.encode("utf-8", "strict")
    except UnicodeError as exc:
        raise BackupArchiveError("non-UTF-8 archive path") from exc
    if not encoded or len(encoded) > MAX_PATH_BYTES:
        raise BackupArchiveError("archive path length is invalid")
    if any(byte < 32 or byte == 127 for byte in encoded):
        raise BackupArchiveError("archive path contains a control character")
    path = pathlib.PurePosixPath(name)
    canonical = path.as_posix()
    expected = name.rstrip("/") if directory else name
    if path.is_absolute() or ".." in path.parts or canonical != expected:
        raise BackupArchiveError("archive path is not canonical")
    if not path.parts or path.parts[0] != "payload" or len(path.parts) > 64:
        raise BackupArchiveError("archive path is outside payload")
    if any(
        not part or len(part.encode("utf-8", "strict")) > MAX_PATH_COMPONENT_BYTES
        for part in path.parts
    ):
        raise BackupArchiveError("archive path component is invalid")
    return path.parts


def _member_file_limit(canonical: str) -> int:
    if canonical == "payload/metadata.json":
        return MAX_METADATA_BYTES
    if canonical == "payload/crontab.txt":
        return MAX_CRONTAB_BYTES
    if canonical == "payload/manifest.sha256":
        return MAX_MANIFEST_BYTES
    if canonical == "payload/rootfs/etc/argo_vmess.conf":
        return 1024 * 1024
    if canonical == "payload/rootfs/etc/rr-nexus/nexus.json":
        return 1024 * 1024
    if canonical == "payload/rootfs/var/lib/rr-nexus/remote.key":
        return 64 * 1024
    if canonical.startswith("payload/rootfs/etc/"):
        return 8 * 1024**2
    if canonical.startswith("payload/rootfs/usr/local/bin/"):
        return 64 * 1024**2
    return MAX_EXPANDED_BYTES


def _validate_member(member: tarfile.TarInfo) -> tuple[str, int]:
    if not (member.isdir() or member.isfile()) or member.issparse():
        raise BackupArchiveError("archive contains a link or special member")
    parts = _path_parts(member.name, directory=member.isdir())
    canonical = "/".join(parts)
    if member.isdir():
        allowed = canonical in {"payload", "payload/rootfs"} or canonical.startswith(
            "payload/rootfs/"
        )
        size = 0
    else:
        allowed = canonical in {
            "payload/metadata.json",
            "payload/manifest.sha256",
            "payload/crontab.txt",
        } or canonical.startswith("payload/rootfs/")
        size = member.size
        if size < 0 or size > _member_file_limit(canonical):
            raise BackupArchiveError("archive member exceeds its size limit")
    if not allowed:
        raise BackupArchiveError("unexpected archive member")
    return canonical, size


def inspect_archive(archive: pathlib.Path) -> ArchiveSummary:
    if not archive.is_file() or archive.is_symlink():
        raise BackupArchiveError("backup payload is not a regular archive")
    archive_size = archive.stat().st_size
    if archive_size <= 0 or archive_size > MAX_ARCHIVE_BYTES:
        raise BackupArchiveError("compressed backup exceeds its size limit")
    count = 0
    total_size = 0
    seen: set[str] = set()
    try:
        with tarfile.open(archive, "r|gz", tarinfo=BoundedTarInfo) as handle:
            while True:
                member = handle.next()
                if member is None:
                    break
                count += 1
                if count > MAX_MEMBERS:
                    raise BackupArchiveError("backup has too many members")
                canonical, size = _validate_member(member)
                if canonical in seen:
                    raise BackupArchiveError("backup contains a duplicate member")
                seen.add(canonical)
                total_size += size
                if total_size > MAX_EXPANDED_BYTES:
                    raise BackupArchiveError("backup expands beyond its size limit")
                # TarFile retains every TarInfo even in streaming mode unless
                # callers clear this cache.  The allow-list state above is the
                # only bounded metadata that must survive to the next header.
                handle.members.clear()
    except (OSError, tarfile.TarError) as exc:
        raise BackupArchiveError("invalid compressed backup") from exc
    if not count:
        raise BackupArchiveError("backup archive is empty")
    return ArchiveSummary(count, total_size)


def _safe_destination(root: pathlib.Path, parts: tuple[str, ...]) -> pathlib.Path:
    destination = root.joinpath(*parts)
    current = root
    for part in parts[:-1]:
        current = current / part
        if current.exists():
            info = current.lstat()
            if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                raise BackupArchiveError("archive path collides with a non-directory")
        else:
            current.mkdir(mode=0o700)
    return destination


def _extract_regular(
    handle: tarfile.TarFile,
    member: tarfile.TarInfo,
    destination: pathlib.Path,
) -> None:
    source = handle.extractfile(member)
    if source is None:
        raise BackupArchiveError("regular archive member has no data")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(destination, flags, 0o600)
    written = 0
    try:
        with source, os.fdopen(descriptor, "wb", closefd=True) as output:
            descriptor = -1
            remaining = member.size
            while remaining:
                block = source.read(min(1024 * 1024, remaining))
                if not block:
                    raise BackupArchiveError("archive member is truncated")
                output.write(block)
                written += len(block)
                remaining -= len(block)
            output.flush()
            os.fsync(output.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if written != member.size:
        raise BackupArchiveError("archive member length changed during extraction")


def extract_archive(
    archive: pathlib.Path,
    target: pathlib.Path,
    *,
    extra_reserve_bytes: int = 0,
) -> ArchiveSummary:
    summary = inspect_archive(archive)
    if not target.is_dir() or target.is_symlink():
        raise BackupArchiveError("restore staging directory is unsafe")
    target_info = target.stat()
    if target_info.st_uid != 0 or stat.S_IMODE(target_info.st_mode) != 0o700:
        raise BackupArchiveError("restore staging directory ownership or mode is unsafe")
    if extra_reserve_bytes < 0 or extra_reserve_bytes > MAX_EXPANDED_BYTES:
        raise BackupArchiveError("restore rollback reserve is invalid")
    required = summary.expanded_bytes + FREE_SPACE_RESERVE_BYTES + extra_reserve_bytes
    if required > shutil.disk_usage(target).free:
        raise BackupArchiveError("insufficient free space for safe backup extraction")

    count = 0
    total_size = 0
    seen: set[str] = set()
    try:
        with tarfile.open(archive, "r|gz", tarinfo=BoundedTarInfo) as handle:
            while True:
                member = handle.next()
                if member is None:
                    break
                count += 1
                if count > MAX_MEMBERS:
                    raise BackupArchiveError("backup has too many members")
                canonical, size = _validate_member(member)
                if canonical in seen:
                    raise BackupArchiveError("backup contains a duplicate member")
                seen.add(canonical)
                total_size += size
                if total_size > MAX_EXPANDED_BYTES:
                    raise BackupArchiveError("backup expands beyond its size limit")
                parts = tuple(canonical.split("/"))
                destination = _safe_destination(target, parts)
                if member.isdir():
                    destination.mkdir(mode=0o700, exist_ok=True)
                    info = destination.lstat()
                    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
                        raise BackupArchiveError("archive directory extraction is unsafe")
                    os.chmod(destination, 0o700)
                else:
                    _extract_regular(handle, member, destination)
                handle.members.clear()
    except (OSError, tarfile.TarError) as exc:
        raise BackupArchiveError("backup extraction failed") from exc
    if (count, total_size) != (summary.members, summary.expanded_bytes):
        raise BackupArchiveError("backup changed between validation and extraction")
    return summary


def validate_payload(payload: pathlib.Path) -> ArchiveSummary:
    if not payload.is_dir() or payload.is_symlink() or payload.name != "payload":
        raise BackupArchiveError("backup payload staging root is unsafe")
    count = 1
    total_size = 0
    stack = [payload]
    while stack:
        directory = stack.pop()
        with os.scandir(directory) as entries:
            for entry in entries:
                count += 1
                if count > MAX_MEMBERS:
                    raise BackupArchiveError("backup payload has too many members")
                info = entry.stat(follow_symlinks=False)
                relative = pathlib.Path(entry.path).relative_to(payload.parent).as_posix()
                parts = _path_parts(relative, directory=stat.S_ISDIR(info.st_mode))
                canonical = "/".join(parts)
                if stat.S_ISDIR(info.st_mode):
                    stack.append(pathlib.Path(entry.path))
                elif stat.S_ISREG(info.st_mode):
                    if info.st_size > _member_file_limit(canonical):
                        raise BackupArchiveError("backup payload member exceeds its size limit")
                    total_size += info.st_size
                    if total_size > MAX_EXPANDED_BYTES:
                        raise BackupArchiveError("backup payload exceeds its size limit")
                else:
                    raise BackupArchiveError("backup payload contains a link or special file")
    if total_size + FREE_SPACE_RESERVE_BYTES > shutil.disk_usage(payload).free:
        raise BackupArchiveError("insufficient free space to create backup archive")
    return ArchiveSummary(count, total_size)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("validate-payload", "inspect", "extract"))
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("target", type=pathlib.Path, nargs="?")
    parser.add_argument("--extra-reserve-bytes", type=int, default=0)
    args = parser.parse_args()
    try:
        if args.mode == "validate-payload":
            validate_payload(args.source)
        elif args.mode == "inspect":
            inspect_archive(args.source)
        else:
            if args.target is None:
                parser.error("extract requires a target directory")
            extract_archive(
                args.source,
                args.target,
                extra_reserve_bytes=args.extra_reserve_bytes,
            )
        return 0
    except (BackupArchiveError, OSError) as exc:
        print(f"RR backup archive validation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
