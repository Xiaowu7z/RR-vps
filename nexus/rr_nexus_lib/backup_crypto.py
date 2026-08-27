"""Authenticated RR backup encryption using scrypt and AES-256-GCM."""

from __future__ import annotations

import argparse
import getpass
import os
import secrets
import sys
from pathlib import Path


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


def _publish_output(temporary: Path, target: Path) -> None:
    # link() is an atomic, no-overwrite publication on the same filesystem.
    # A crash before this point leaves only a hidden temporary file; a crash
    # after it leaves a fully fsynced target (and, at worst, one extra hardlink).
    os.link(temporary, target)
    temporary.unlink()
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
    cipher_cls, algorithms, modes, _scrypt = _crypto()
    salt, nonce = secrets.token_bytes(SALT_BYTES), secrets.token_bytes(NONCE_BYTES)
    encryptor = cipher_cls(algorithms.AES(_key(password, salt)), modes.GCM(nonce)).encryptor()
    encryptor.authenticate_additional_data(MAGIC)
    temporary = _temporary_output(target)
    try:
        with _exclusive_output(temporary) as output, source.open("rb") as input_file:
            output.write(MAGIC + salt + nonce)
            while True:
                chunk = input_file.read(CHUNK_BYTES)
                if not chunk:
                    break
                output.write(encryptor.update(chunk))
            output.write(encryptor.finalize())
            output.write(encryptor.tag)
            output.flush()
            os.fsync(output.fileno())
        _publish_output(temporary, target)
    except Exception:
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def decrypt(source: Path, target: Path, password: bytes) -> None:
    cipher_cls, algorithms, modes, _scrypt = _crypto()
    prefix = len(MAGIC) + SALT_BYTES + NONCE_BYTES
    size = source.stat().st_size
    if size <= prefix + TAG_BYTES:
        raise ValueError("不是有效的 RR 加密备份")
    with source.open("rb") as input_file:
        header = input_file.read(prefix)
        if header[: len(MAGIC)] != MAGIC:
            raise ValueError("不是有效的 RR 加密备份")
        salt = header[len(MAGIC) : len(MAGIC) + SALT_BYTES]
        nonce = header[len(MAGIC) + SALT_BYTES : prefix]
        input_file.seek(size - TAG_BYTES)
        tag = input_file.read(TAG_BYTES)
        input_file.seek(prefix)
        remaining = size - prefix - TAG_BYTES
        decryptor = cipher_cls(algorithms.AES(_key(password, salt)), modes.GCM(nonce, tag)).decryptor()
        decryptor.authenticate_additional_data(MAGIC)
        temporary = _temporary_output(target)
        try:
            with _exclusive_output(temporary) as output:
                while remaining:
                    chunk = input_file.read(min(CHUNK_BYTES, remaining))
                    if not chunk:
                        raise ValueError("加密备份被截断")
                    remaining -= len(chunk)
                    output.write(decryptor.update(chunk))
                output.write(decryptor.finalize())
                output.flush()
                os.fsync(output.fileno())
            _publish_output(temporary, target)
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
