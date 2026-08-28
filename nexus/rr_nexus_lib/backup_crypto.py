"""Authenticated RR backup encryption using scrypt and AES-256-GCM."""

from __future__ import annotations

import argparse
import getpass
import os
import secrets
import shutil
import stat
import sys
from pathlib import Path

from .backup_archive import FREE_SPACE_RESERVE_BYTES, MAX_ARCHIVE_BYTES


MAGIC = b"RRBAK1\x00"
SALT_BYTES = 16
NONCE_BYTES = 12
TAG_BYTES = 16
CHUNK_BYTES = 1024 * 1024


def _crypto() -> tuple[object, object, object, object]:
    try:
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        from cryptography.hazmat.primitives.kdf.scrypt import Scrypt
    except ImportError as exc:
        raise RuntimeError("python3-cryptography is required for encrypted backups") from exc
    return Cipher, algorithms, modes, Scrypt


def _password(confirm: bool = False) -> bytes:
    # Remove the secret from the environment as soon as it has been read, but
    # remember its origin: non-interactive backups must never block waiting for
    # a second prompt.
    from_environment = "RR_BACKUP_PASSPHRASE" in os.environ
    value = os.environ.pop("RR_BACKUP_PASSPHRASE", "")
    if not value:
        value = getpass.getpass("备份口令：")
    if len(value) < 10:
        raise ValueError("备份口令至少 10 个字符")
    if confirm and not from_environment:
        again = getpass.getpass("再次输入：")
        if value != again:
            raise ValueError("两次口令不一致")
    return value.encode("utf-8")


def _key(password: bytes, salt: bytes) -> bytes:
    _cipher, _algorithms, _modes, scrypt_cls = _crypto()
    return scrypt_cls(salt=salt, length=32, n=2**15, r=8, p=1).derive(password)


def _exclusive_output(target: Path):
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    return os.fdopen(fd, "wb")


def _temporary_output(target: Path) -> Path:
    return target.with_name(
        f".{target.name}.rrtmp-{os.getpid()}-{secrets.token_hex(8)}"
    )


def _open_regular_input(source: Path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    # Avoid blocking if an attacker swaps a named pipe into place immediately
    # before open(); O_NONBLOCK has no effect on normal regular-file reads.
    flags |= getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(source, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("backup input is not a regular file")
        return os.fdopen(descriptor, "rb", closefd=True), info
    except Exception:
        os.close(descriptor)
        raise


def _same_inode(info: os.stat_result, path_info: os.stat_result) -> bool:
    return (info.st_dev, info.st_ino) == (path_info.st_dev, path_info.st_ino)


def _published_output_is_safe(
    descriptor_info: os.stat_result,
    path_info: os.stat_result,
    *,
    links: int,
) -> bool:
    return (
        stat.S_ISREG(descriptor_info.st_mode)
        and stat.S_ISREG(path_info.st_mode)
        and _same_inode(descriptor_info, path_info)
        and descriptor_info.st_uid == os.geteuid()
        and path_info.st_uid == os.geteuid()
        and stat.S_IMODE(descriptor_info.st_mode) == 0o600
        and stat.S_IMODE(path_info.st_mode) == 0o600
        and descriptor_info.st_nlink == links
        and path_info.st_nlink == links
    )


def _unlink_if_same(path: Path, expected: os.stat_result) -> None:
    """Remove only our own publication, never an entry swapped in by a racer."""
    try:
        current = path.lstat()
    except FileNotFoundError:
        return
    if _same_inode(expected, current) and stat.S_ISREG(current.st_mode):
        path.unlink()


def _publish_output(
    descriptor: int,
    temporary: Path,
    target: Path,
) -> None:
    # Set permissions through the still-open descriptor.  Performing chmod on
    # the target path after publication would let a writer of target.parent
    # replace it with a symlink and make root chmod an unrelated file.
    before = os.fstat(descriptor)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
    ):
        raise ValueError("backup temporary output is unsafe")
    os.fchmod(descriptor, 0o600)
    os.fsync(descriptor)
    before = os.fstat(descriptor)
    try:
        temporary_info = temporary.lstat()
    except FileNotFoundError as exc:
        raise ValueError("backup temporary output disappeared") from exc
    if not _published_output_is_safe(before, temporary_info, links=1):
        raise ValueError("backup temporary output changed before publication")

    # link() is an atomic, no-overwrite publication on the same filesystem.
    # Keep the descriptor open until the target has been bound to, and verified
    # against, the exact inode containing the authenticated output.
    linked = False
    try:
        os.link(temporary, target, follow_symlinks=False)
        linked = True
        after_link = os.fstat(descriptor)
        target_info = target.lstat()
        if not _published_output_is_safe(after_link, target_info, links=2):
            raise ValueError("backup target changed during publication")
        temporary.unlink()
        final_info = os.fstat(descriptor)
        final_target_info = target.lstat()
        if not _published_output_is_safe(final_info, final_target_info, links=1):
            raise ValueError("backup target changed after publication")
    except Exception:
        if linked:
            _unlink_if_same(target, os.fstat(descriptor))
        raise
    try:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        directory_fd = os.open(target.parent, flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    except OSError:
        # Directory fsync is unavailable on Windows and a few filesystems. The
        # file itself has already been fsynced and atomically published.
        pass


def encrypt(source: Path, target: Path, password: bytes) -> None:
    input_file, source_info = _open_regular_input(source)
    with input_file:
        source_size = source_info.st_size
        if source_size <= 0 or source_size > MAX_ARCHIVE_BYTES:
            raise ValueError("backup archive exceeds the encrypted-backup size limit")
        if source_size + FREE_SPACE_RESERVE_BYTES > shutil.disk_usage(target.parent).free:
            raise ValueError("insufficient free space for encrypted backup output")
        cipher_cls, algorithms, modes, _scrypt = _crypto()
        salt, nonce = secrets.token_bytes(SALT_BYTES), secrets.token_bytes(NONCE_BYTES)
        encryptor = cipher_cls(algorithms.AES(_key(password, salt)), modes.GCM(nonce)).encryptor()
        encryptor.authenticate_additional_data(MAGIC)
        temporary = _temporary_output(target)
        processed = 0
        try:
            with _exclusive_output(temporary) as output:
                output.write(MAGIC + salt + nonce)
                while processed < source_size:
                    chunk = input_file.read(min(CHUNK_BYTES, source_size - processed))
                    if not chunk:
                        raise ValueError("backup archive changed while being encrypted")
                    processed += len(chunk)
                    output.write(encryptor.update(chunk))
                if input_file.read(1):
                    raise ValueError("backup archive grew while being encrypted")
                output.write(encryptor.finalize())
                output.write(encryptor.tag)
                output.flush()
                os.fsync(output.fileno())
                _publish_output(output.fileno(), temporary, target)
        except Exception:
            try:
                temporary.unlink()
            except OSError:
                pass
            raise


def decrypt(source: Path, target: Path, password: bytes) -> None:
    prefix = len(MAGIC) + SALT_BYTES + NONCE_BYTES
    input_file, source_info = _open_regular_input(source)
    with input_file:
        size = source_info.st_size
        if size <= prefix + TAG_BYTES:
            raise ValueError("不是有效的 RR 加密备份")
        if size > MAX_ARCHIVE_BYTES + prefix + TAG_BYTES:
            raise ValueError("encrypted backup exceeds the restore size limit")
        plaintext_size = size - prefix - TAG_BYTES
        if plaintext_size + FREE_SPACE_RESERVE_BYTES > shutil.disk_usage(target.parent).free:
            raise ValueError("insufficient free space to decrypt backup safely")
        cipher_cls, algorithms, modes, _scrypt = _crypto()
        header = input_file.read(prefix)
        if header[: len(MAGIC)] != MAGIC:
            raise ValueError("不是有效的 RR 加密备份")
        salt = header[len(MAGIC) : len(MAGIC) + SALT_BYTES]
        nonce = header[len(MAGIC) + SALT_BYTES : prefix]
        input_file.seek(size - TAG_BYTES)
        tag = input_file.read(TAG_BYTES)
        input_file.seek(prefix)
        remaining = plaintext_size
        decryptor = cipher_cls(algorithms.AES(_key(password, salt)), modes.GCM(nonce, tag)).decryptor()
        decryptor.authenticate_additional_data(MAGIC)
        temporary = _temporary_output(target)
        try:
            written = 0
            with _exclusive_output(temporary) as output:
                while remaining:
                    chunk = input_file.read(min(CHUNK_BYTES, remaining))
                    if not chunk:
                        raise ValueError("加密备份被截断")
                    remaining -= len(chunk)
                    written += len(chunk)
                    output.write(decryptor.update(chunk))
                output.write(decryptor.finalize())
                if written != plaintext_size:
                    raise ValueError("decrypted backup length is invalid")
                output.flush()
                os.fsync(output.fileno())
                _publish_output(output.fileno(), temporary, target)
        except Exception:
            try:
                temporary.unlink()
            except OSError:
                pass
            raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("encrypt", "decrypt"))
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    args = parser.parse_args()
    try:
        password = _password(confirm=args.mode == "encrypt")
        if args.mode == "encrypt":
            encrypt(args.source, args.target, password)
        else:
            decrypt(args.source, args.target, password)
        return 0
    except Exception as exc:
        print(f"RR backup crypto failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
