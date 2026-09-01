#!/usr/bin/env python3
"""Snapshot and restore RR-owned external state for transactional updates.

This helper deliberately knows only a small, fixed namespace.  It must never
copy an entire Nginx tree or restore a complete firewall table because those
objects can contain unrelated administrator-owned state.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


VERSION = "rr-update-external-state-v2"
ALLOW_COMMENT = "argo-rr-managed"
BLOCK_COMMENT = "argo-rr-managed-block"
NGINX_PATHS = (
    "/etc/nginx/sites-available/rr-nexus.conf",
    "/etc/nginx/sites-available/rr-nexus.conf.port",
    "/etc/nginx/sites-available/rr-nexus-ip.conf",
    "/etc/nginx/sites-enabled/rr-nexus.conf",
    "/etc/nginx/sites-enabled/rr-nexus-port.conf",
    "/etc/nginx/sites-enabled/rr-nexus-ip.conf",
    "/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf",
    "/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf",
)
CERT_HOOK_PATHS = (
    "/etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh",
    "/etc/letsencrypt/renewal-hooks/deploy/rr-certificates.sh",
)
OTHER_PATHS = (
    "/etc/rr-cloudflared/token",
    "/etc/systemd/system/cloudflared.service",
)
NEXUS_IP_CERT_GATE_PATHS = (
    "/usr/local/lib/rr-vps/nexus-ip-cert-gate",
    "/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf",
)
NEXUS_IP_ACME_RUNTIME_PATHS = (
    "/etc/systemd/system/rr-nexus-ip-acme.service",
    "/etc/systemd/system/rr-nexus-ip-acme.timer",
    "/etc/rr-nexus/certs/ip.crt",
    "/etc/rr-nexus/certs/ip.key",
    "/etc/rr-nexus/certs/.ip-cert-pending",
    "/usr/local/lib/rr-vps/lego",
    "/usr/local/lib/rr-vps/lego.install",
)
MANAGED_PATHS = (
    NGINX_PATHS
    + CERT_HOOK_PATHS
    + OTHER_PATHS
    + NEXUS_IP_CERT_GATE_PATHS
    + NEXUS_IP_ACME_RUNTIME_PATHS
)
SERVICES = ("nginx", "cloudflared")
TABLE_CHAINS = (("filter", "INPUT"), ("nat", "PREROUTING"))
DEFAULT_MANAGED_FILE_LIMIT = 16 * 1024 * 1024
# lego 5.4.0 is roughly 65 MiB after extraction on amd64.  Keep a tight,
# explicit exception for this one pinned executable while retaining the
# smaller ceiling for every other rollback file.
LEGO_MANAGED_FILE_LIMIT = 72 * 1024 * 1024


class StateError(RuntimeError):
    pass


def managed_file_limit(path: str) -> int:
    if path == "/usr/local/lib/rr-vps/lego":
        return LEGO_MANAGED_FILE_LIMIT
    return DEFAULT_MANAGED_FILE_LIMIT


def external_root() -> Path:
    root = os.environ.get("RR_EXTERNAL_ROOT", "/")
    if not os.path.isabs(root):
        raise StateError("RR_EXTERNAL_ROOT must be absolute")
    root_real = os.path.realpath(root)
    if root_real != os.path.abspath(root):
        raise StateError("RR_EXTERNAL_ROOT must not contain symlinks")
    return Path(root_real)


def root_path(path: str) -> Path:
    return external_root() / path.lstrip("/")


def fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def require_secure_dir(path: Path) -> None:
    try:
        info = os.lstat(path)
    except OSError as exc:
        raise StateError(f"cannot inspect {path}: {exc}") from exc
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise StateError(f"not a real directory: {path}")
    if info.st_uid != 0:
        raise StateError(f"directory is not root-owned: {path}")
    if stat.S_IMODE(info.st_mode) & 0o022:
        raise StateError(f"directory is group/world-writable: {path}")


def validate_backup_dir(raw: str, tx_root_raw: str) -> Path:
    if os.geteuid() != 0:
        raise StateError("must run as root")
    if not os.path.isabs(raw) or not os.path.isabs(tx_root_raw):
        raise StateError("transaction paths must be absolute")
    backup = Path(os.path.abspath(raw))
    tx_root = Path(os.path.abspath(tx_root_raw))
    expected_parent = tx_root / "transactions"
    try:
        relative = backup.relative_to(expected_parent)
    except ValueError as exc:
        raise StateError("backup directory is outside RR_TX_ROOT") from exc
    if len(relative.parts) != 2 or relative.parts[1] != "backup" or relative.parts[0] in {"", ".", ".."}:
        raise StateError("backup directory must be transactions/<id>/backup")
    for candidate in (tx_root, expected_parent, expected_parent / relative.parts[0], backup):
        require_secure_dir(candidate)
        if os.path.realpath(candidate) != str(candidate):
            raise StateError(f"directory contains a symlink: {candidate}")
    return backup


def require_safe_parent(path: Path, *, may_be_missing: bool) -> None:
    trust_root = external_root()
    normalized = Path(os.path.abspath(path))
    if normalized != path or os.path.realpath(path) != str(path):
        raise StateError(f"managed path parent contains a symlink: {path}")
    try:
        relative = path.relative_to(trust_root)
    except ValueError as exc:
        raise StateError("managed path escaped RR_EXTERNAL_ROOT") from exc
    current = trust_root
    require_secure_dir(current)
    if os.path.realpath(current) != str(current):
        raise StateError(f"managed path parent contains a symlink: {current}")
    for component in relative.parts:
        current = current / component
        try:
            os.lstat(current)
        except FileNotFoundError:
            if may_be_missing:
                return
            raise StateError(f"managed path parent is missing: {path}")
        except OSError as exc:
            raise StateError(f"cannot inspect managed path parent {current}: {exc}") from exc
        require_secure_dir(current)
        if os.path.realpath(current) != str(current):
            raise StateError(f"managed path parent contains a symlink: {current}")


def run(argv: list[str], *, allowed: tuple[int, ...] = (0,), text: bool = True) -> subprocess.CompletedProcess[str]:
    command_env = os.environ.copy()
    # UFW status text is part of the authenticated transaction invariant.
    # Force one locale so a user-started update and systemd boot recovery do
    # not hash different translations of unchanged rules.
    command_env.update(LC_ALL="C", LANG="C")
    result = subprocess.run(
        argv, capture_output=True, text=text, check=False, timeout=20, env=command_env
    )
    if result.returncode not in allowed:
        detail = (result.stderr or result.stdout or "command failed").strip()
        raise StateError(f"{argv[0]} failed ({result.returncode}): {detail[:300]}")
    return result


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise StateError("short write")
        view = view[written:]


def command(name: str, env_name: str | None = None) -> str | None:
    override = os.environ.get(env_name or f"RR_EXTERNAL_{name.upper().replace('-', '_')}")
    if override:
        if not os.path.isabs(override):
            raise StateError(f"{env_name or name} override must be absolute")
        return override
    return shutil.which(name)


def service_state(name: str) -> dict[str, bool]:
    systemctl = command("systemctl")
    if systemctl is None:
        raise StateError("systemctl is unavailable")
    enabled = run([systemctl, "is-enabled", "--quiet", name], allowed=(0, 1, 3, 4)).returncode == 0
    active = run([systemctl, "is-active", "--quiet", name], allowed=(0, 1, 3, 4)).returncode == 0
    return {"enabled": enabled, "active": active}


def source_entry(path: str, item_dir: Path, index: int) -> dict[str, Any]:
    source = root_path(path)
    require_safe_parent(source.parent, may_be_missing=True)
    try:
        info = os.lstat(source)
    except FileNotFoundError:
        return {"path": path, "kind": "missing"}
    except OSError as exc:
        raise StateError(f"cannot inspect managed path {path}: {exc}") from exc
    if info.st_uid != 0:
        raise StateError(f"managed path is not root-owned: {path}")
    common: dict[str, Any] = {
        "path": path,
        "uid": info.st_uid,
        "gid": info.st_gid,
        "mode": stat.S_IMODE(info.st_mode),
    }
    if stat.S_ISLNK(info.st_mode):
        common.update(kind="symlink", target=os.readlink(source))
        return common
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise StateError(f"managed path is not a single regular file or symlink: {path}")
    target = item_dir / str(index)
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    digest = hashlib.sha256()
    total = 0
    try:
        opened = os.fstat(source_fd)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino) or opened.st_nlink != 1:
            raise StateError(f"managed path changed while snapshotting: {path}")
        target_fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        try:
            while True:
                block = os.read(source_fd, 1024 * 1024)
                if not block:
                    break
                total += len(block)
                limit = managed_file_limit(path)
                if total > limit:
                    raise StateError(f"managed file exceeds snapshot limit: {path}")
                digest.update(block)
                write_all(target_fd, block)
            os.fsync(target_fd)
        finally:
            os.close(target_fd)
    finally:
        os.close(source_fd)
    common.update(kind="file", item=str(index), sha256=digest.hexdigest(), size=total)
    return common


def ufw_view() -> dict[str, Any]:
    ufw = command("ufw")
    if ufw is None:
        return {"state": "absent", "status_sha256": None, "rules_sha256": None}
    status = run([ufw, "status", "verbose"], allowed=(0,)).stdout
    rules = run([ufw, "status", "numbered"], allowed=(0,)).stdout
    first = next((line.strip().lower() for line in status.splitlines() if line.strip()), "")
    if first == "status: active":
        state = "active"
    elif first == "status: inactive":
        state = "inactive"
    else:
        raise StateError("cannot determine UFW state safely")
    return {
        "state": state,
        "status_sha256": hashlib.sha256(status.encode()).hexdigest(),
        "rules_sha256": hashlib.sha256(rules.encode()).hexdigest(),
    }


def consume_pair(tokens: list[str], names: tuple[str, ...]) -> str | None:
    positions = [index for index, token in enumerate(tokens) if token in names]
    if not positions:
        return None
    if len(positions) != 1 or positions[0] + 1 >= len(tokens):
        raise StateError("duplicated or incomplete firewall option")
    position = positions[0]
    value = tokens[position + 1]
    del tokens[position : position + 2]
    return value


def valid_port(value: str | None) -> bool:
    return bool(value and value.isdigit() and 1 <= int(value) <= 65535)


def valid_hop_spec(value: str | None) -> bool:
    if value is None or not re.fullmatch(r"[0-9]+(?::[0-9]+)?", value):
        return False
    ports = [int(part) for part in value.split(":")]
    return all(1 <= port <= 65535 for port in ports) and (len(ports) == 1 or ports[0] <= ports[1])


def is_strict_rr_rule(tokens: list[str], table: str, chain: str) -> bool:
    if tokens[:2] != ["-A", chain]:
        return False
    options = tokens[2:].copy()
    protocol = consume_pair(options, ("-p", "--protocol"))
    dport = consume_pair(options, ("--dport",))
    comment = consume_pair(options, ("--comment",))
    target = consume_pair(options, ("-j", "--jump"))
    modules: list[str] = []
    while "-m" in options or "--match" in options:
        positions = [index for index, token in enumerate(options) if token in {"-m", "--match"}]
        position = positions[0]
        if position + 1 >= len(options):
            raise StateError("incomplete firewall match option")
        modules.append(options[position + 1])
        del options[position : position + 2]
    if table == "filter":
        managed = (
            chain == "INPUT"
            and protocol in {"tcp", "udp"}
            and valid_port(dport)
            and ((comment == ALLOW_COMMENT and target == "ACCEPT") or
                 (comment == BLOCK_COMMENT and target == "DROP"))
            and set(modules).issubset({protocol, "comment"})
        )
        return managed and not options
    if table != "nat" or chain != "PREROUTING":
        return False
    destination = consume_pair(options, ("--to-destination",))
    redirect = consume_pair(options, ("--to-ports",))
    managed = (
        protocol == "udp"
        and valid_hop_spec(dport)
        and comment in {"argo-rr-HY2", "argo-rr-TU5"}
        and set(modules).issubset({"udp", "comment"})
        and (
            (target == "REDIRECT" and valid_port(redirect) and destination is None)
            or (
                target == "DNAT"
                and redirect is None
                and isinstance(destination, str)
                and destination.startswith(":")
                and valid_port(destination[1:])
            )
        )
    )
    return managed and not options


def parse_rule(raw: str, table: str, chain: str) -> tuple[list[str], bool]:
    try:
        tokens = shlex.split(raw)
    except ValueError as exc:
        raise StateError(f"invalid {table} rule syntax") from exc
    if len(tokens) < 3 or tokens[0] != "-A" or tokens[1] != chain:
        raise StateError(f"unexpected {table}/{chain} rule output")
    return tokens, is_strict_rr_rule(tokens, table, chain)


def firewall_chain(backend: str, table: str, chain: str) -> dict[str, Any]:
    binary = command(backend)
    if binary is None:
        return {"present": False, "rules": [], "nonmanaged": []}
    output = run([binary, "-w", "5", "-t", table, "-S", chain]).stdout
    managed: list[dict[str, Any]] = []
    nonmanaged: list[str] = []
    rule_index = 0
    for raw in output.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("-P "):
            continue
        rule_index += 1
        _tokens, is_managed = parse_rule(line, table, chain)
        if is_managed:
            managed.append({"index": rule_index, "line": line})
        else:
            nonmanaged.append(line)
    return {"present": True, "rules": managed, "nonmanaged": nonmanaged}


def firewall_state() -> dict[str, Any]:
    # UFW owns and rebuilds several netfilter chains.  Capture its user-facing
    # state on both sides of the raw rule reads so a concurrent UFW operation
    # cannot produce a mixed snapshot.
    ufw_before = ufw_view()
    result: dict[str, Any] = {"ufw": ufw_before, "backends": {}}
    for backend in ("iptables", "ip6tables"):
        result["backends"][backend] = {}
        for table, chain in TABLE_CHAINS:
            result["backends"][backend][f"{table}/{chain}"] = firewall_chain(backend, table, chain)
    if ufw_view() != ufw_before:
        raise StateError("UFW state changed while capturing firewall snapshot")
    return result


def write_json(path: Path, value: Any) -> None:
    data = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    try:
        write_all(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def snapshot(backup: Path) -> None:
    target = backup / "external-state"
    if target.exists() or target.is_symlink():
        raise StateError("external state snapshot already exists")
    temporary = Path(tempfile.mkdtemp(prefix=".external-state.", dir=backup))
    os.chmod(temporary, 0o700)
    try:
        item_dir = temporary / "items"
        item_dir.mkdir(mode=0o700)
        state_value = {
            "version": VERSION,
            "paths": [source_entry(path, item_dir, index) for index, path in enumerate(MANAGED_PATHS)],
            "services": {name: service_state(name) for name in SERVICES},
            "firewall": firewall_state(),
        }
        state_path = temporary / "state.json"
        write_json(state_path, state_value)
        state_hash = hashlib.sha256(state_path.read_bytes()).hexdigest()
        marker_path = temporary / "complete"
        marker_fd = os.open(marker_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
        try:
            write_all(marker_fd, f"{VERSION} {state_hash}\n".encode())
            os.fsync(marker_fd)
        finally:
            os.close(marker_fd)
        fsync_dir(item_dir)
        fsync_dir(temporary)
        os.rename(temporary, target)
        fsync_dir(backup)
    except BaseException:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def secure_snapshot_file(
    path: Path, limit: int = DEFAULT_MANAGED_FILE_LIMIT
) -> bytes:
    if not isinstance(limit, int) or limit < 1 or limit > LEGO_MANAGED_FILE_LIMIT:
        raise StateError("invalid snapshot file limit")
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1:
        raise StateError(f"unsafe snapshot file: {path}")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
            raise StateError(f"snapshot file changed: {path}")
        chunks: list[bytes] = []
        total = 0
        while True:
            block = os.read(fd, 1024 * 1024)
            if not block:
                break
            total += len(block)
            if total > limit:
                raise StateError("snapshot file exceeds limit")
            chunks.append(block)
        return b"".join(chunks)
    finally:
        os.close(fd)


def load_snapshot(backup: Path) -> tuple[Path, dict[str, Any]]:
    directory = backup / "external-state"
    require_secure_dir(directory)
    require_secure_dir(directory / "items")
    marker = secure_snapshot_file(directory / "complete").decode("ascii").strip().split()
    if len(marker) != 2 or marker[0] != VERSION or len(marker[1]) != 64:
        raise StateError("invalid external snapshot complete marker")
    raw = secure_snapshot_file(directory / "state.json")
    if hashlib.sha256(raw).hexdigest() != marker[1]:
        raise StateError("external snapshot state hash mismatch")
    try:
        value = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise StateError("invalid external snapshot JSON") from exc
    if value.get("version") != VERSION:
        raise StateError("unsupported external snapshot version")
    paths = value.get("paths")
    if not isinstance(paths, list) or [entry.get("path") for entry in paths] != list(MANAGED_PATHS):
        raise StateError("external snapshot path namespace mismatch")
    if set(value.get("services", {})) != set(SERVICES):
        raise StateError("external snapshot service namespace mismatch")
    return directory, value


def remove_managed_path(path: Path) -> None:
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return
    if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
        raise StateError(f"refusing to replace non-file managed path: {path}")
    path.unlink()


def restore_entry(directory: Path, entry: dict[str, Any]) -> None:
    path_name = entry.get("path")
    if path_name not in MANAGED_PATHS:
        raise StateError("snapshot contains an unmanaged path")
    destination = root_path(path_name)
    kind = entry.get("kind")
    if kind == "missing":
        # A candidate must not be able to replace an absent RR parent with a
        # symlink and make rollback unlink a file outside the fixed namespace.
        require_safe_parent(destination.parent, may_be_missing=True)
        remove_managed_path(destination)
        return
    require_safe_parent(destination.parent, may_be_missing=False)
    try:
        current = os.lstat(destination)
        if not (stat.S_ISREG(current.st_mode) or stat.S_ISLNK(current.st_mode)):
            raise StateError(f"refusing to replace non-file managed path: {destination}")
    except FileNotFoundError:
        pass
    if kind == "symlink":
        target = entry.get("target")
        if not isinstance(target, str) or "\0" in target:
            raise StateError("invalid saved symlink")
        temporary = destination.parent / (
            f".{destination.name}.rr-restore-{secrets.token_hex(8)}"
        )
        os.symlink(target, temporary)
        os.lchown(temporary, int(entry["uid"]), int(entry["gid"]))
        os.replace(temporary, destination)
        fsync_dir(destination.parent)
        return
    if kind != "file":
        raise StateError("invalid saved path type")
    item_name = entry.get("item")
    if not isinstance(item_name, str) or not item_name.isdigit():
        raise StateError("invalid saved item name")
    data = secure_snapshot_file(
        directory / "items" / item_name, managed_file_limit(path_name)
    )
    if len(data) != entry.get("size") or hashlib.sha256(data).hexdigest() != entry.get("sha256"):
        raise StateError("saved item integrity mismatch")
    fd, temporary_raw = tempfile.mkstemp(prefix=f".{destination.name}.rr-restore-", dir=destination.parent)
    temporary = Path(temporary_raw)
    try:
        os.fchmod(fd, int(entry["mode"]))
        os.fchown(fd, int(entry["uid"]), int(entry["gid"]))
        write_all(fd, data)
        os.fsync(fd)
        os.close(fd)
        fd = -1
        os.replace(temporary, destination)
        fsync_dir(destination.parent)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def chain_current(binary: str, table: str, chain: str) -> tuple[list[tuple[str, list[str], bool]], list[str]]:
    output = run([binary, "-w", "5", "-t", table, "-S", chain]).stdout
    all_rules: list[tuple[str, list[str], bool]] = []
    nonmanaged: list[str] = []
    for raw in output.splitlines():
        line = raw.strip()
        if not line or line.startswith("-P "):
            continue
        tokens, managed = parse_rule(line, table, chain)
        all_rules.append((line, tokens, managed))
        if not managed:
            nonmanaged.append(line)
    return all_rules, nonmanaged


def restore_firewall(saved: dict[str, Any]) -> None:
    saved_ufw = saved.get("ufw")
    if not isinstance(saved_ufw, dict) or saved_ufw.get("state") not in {"absent", "inactive", "active"}:
        raise StateError("invalid saved UFW state")
    current = firewall_state()
    current_ufw = current.get("ufw")
    if saved_ufw.get("state") == "active":
        # Active UFW remains the sole firewall owner.  The update transaction
        # is forbidden from reconstructing or persisting its raw rules; exact
        # equality is a read-only rollback invariant instead.
        if current != saved:
            raise StateError("active UFW firewall state changed during transaction")
        return
    if current_ufw != saved_ufw:
        raise StateError("UFW state changed during transaction")
    backends = saved.get("backends")
    if not isinstance(backends, dict) or set(backends) != {"iptables", "ip6tables"}:
        raise StateError("invalid saved firewall backends")
    # Preflight every chain before mutating any firewall rule.  A concurrent
    # administrator change fails closed instead of being overwritten.
    prepared: list[tuple[str, str, str, dict[str, Any], list[tuple[str, list[str], bool]]]] = []
    for backend in ("iptables", "ip6tables"):
        binary = command(backend)
        for table, chain in TABLE_CHAINS:
            snapshot_chain = backends[backend].get(f"{table}/{chain}")
            if not isinstance(snapshot_chain, dict):
                raise StateError("invalid saved firewall chain")
            if not snapshot_chain.get("present"):
                if binary is not None:
                    # Backend presence is itself external state.  Even an
                    # empty newly-installed backend cannot be made absent by
                    # this helper, so reject it during the all-read-only
                    # preflight.  Deferring the mismatch to the final verify
                    # would restore Nginx files and service state first and
                    # leave a needlessly partial rollback.
                    raise StateError(f"{backend} appeared during transaction")
                continue
            if binary is None:
                raise StateError(f"saved firewall backend disappeared: {backend}")
            rules, current_nonmanaged = chain_current(binary, table, chain)
            if current_nonmanaged != snapshot_chain.get("nonmanaged"):
                raise StateError(f"non-RR {backend} {table}/{chain} rules changed")
            prepared.append((binary, table, chain, snapshot_chain, rules))

    for binary, table, chain, snapshot_chain, current_rules in prepared:
        for _line, tokens, managed in reversed(current_rules):
            if managed:
                run([binary, "-w", "5", "-t", table, "-D", chain, *tokens[2:]])
        for item in snapshot_chain.get("rules", []):
            if not isinstance(item, dict) or not isinstance(item.get("index"), int):
                raise StateError("invalid saved managed firewall rule")
            tokens, managed = parse_rule(item.get("line", ""), table, chain)
            if not managed or item["index"] < 1:
                raise StateError("saved firewall rule escaped RR namespace")
            run([binary, "-w", "5", "-t", table, "-I", chain, str(item["index"]), *tokens[2:]])

    persistent = command("netfilter-persistent", "RR_EXTERNAL_NETFILTER_PERSISTENT")
    if persistent is not None and prepared:
        run([persistent, "save"])


def set_service_state(name: str, saved: dict[str, Any]) -> None:
    if set(saved) != {"enabled", "active"} or not all(isinstance(value, bool) for value in saved.values()):
        raise StateError("invalid saved service state")
    systemctl = command("systemctl")
    if systemctl is None:
        raise StateError("systemctl is unavailable")
    if saved["enabled"]:
        run([systemctl, "enable", name])
    else:
        run([systemctl, "disable", name], allowed=(0, 1, 3, 4, 5))
    if name == "nginx" and saved["active"]:
        nginx = command("nginx")
        if nginx is None:
            raise StateError("nginx binary disappeared")
        run([nginx, "-t"])
        active_now = service_state("nginx")["active"]
        run([systemctl, "reload" if active_now else "start", "nginx"])
    else:
        if saved["active"]:
            run([systemctl, "start", name])
        else:
            run([systemctl, "stop", name], allowed=(0, 1, 3, 4, 5))


def compare_paths(directory: Path, entries: list[dict[str, Any]]) -> None:
    for entry in entries:
        path = root_path(entry["path"])
        kind = entry["kind"]
        try:
            info = os.lstat(path)
        except FileNotFoundError:
            if kind == "missing":
                continue
            raise StateError(f"managed path is missing after restore: {entry['path']}")
        if kind == "missing":
            raise StateError(f"managed path unexpectedly exists: {entry['path']}")
        if info.st_uid != entry["uid"] or info.st_gid != entry["gid"] or stat.S_IMODE(info.st_mode) != entry["mode"]:
            raise StateError(f"managed path metadata mismatch: {entry['path']}")
        if kind == "symlink":
            if not stat.S_ISLNK(info.st_mode) or os.readlink(path) != entry["target"]:
                raise StateError(f"managed symlink mismatch: {entry['path']}")
        elif kind == "file":
            if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or info.st_nlink != 1:
                raise StateError(f"managed file type mismatch: {entry['path']}")
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
            try:
                opened = os.fstat(fd)
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino) or opened.st_nlink != 1:
                    raise StateError(f"managed file changed during verification: {entry['path']}")
                chunks: list[bytes] = []
                total = 0
                while True:
                    block = os.read(fd, 1024 * 1024)
                    if not block:
                        break
                    total += len(block)
                    limit = managed_file_limit(entry["path"])
                    if total > limit:
                        raise StateError(f"managed file exceeds verification limit: {entry['path']}")
                    chunks.append(block)
                data = b"".join(chunks)
            finally:
                os.close(fd)
            if len(data) != entry["size"] or hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise StateError(f"managed file content mismatch: {entry['path']}")
        else:
            raise StateError("invalid managed path kind")


def verify_firewall(saved: dict[str, Any]) -> None:
    current = firewall_state()
    if current != saved:
        raise StateError("firewall state does not match snapshot")


def verify(backup: Path) -> None:
    directory, saved = load_snapshot(backup)
    compare_paths(directory, saved["paths"])
    for name in SERVICES:
        if service_state(name) != saved["services"][name]:
            raise StateError(f"service state mismatch: {name}")
    verify_firewall(saved["firewall"])


def restore(backup: Path) -> None:
    directory, saved = load_snapshot(backup)
    # Firewall preflight happens before filesystem mutation so an unsupported
    # active UFW installation or changed user rule set leaves everything alone.
    restore_firewall(saved["firewall"])
    for entry in saved["paths"]:
        restore_entry(directory, entry)
    systemctl = command("systemctl")
    if systemctl is None:
        raise StateError("systemctl is unavailable")
    run([systemctl, "daemon-reload"])
    for name in SERVICES:
        set_service_state(name, saved["services"][name])
    verify(backup)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("snapshot", "restore", "verify"))
    parser.add_argument("backup_dir")
    parser.add_argument("--tx-root", default=os.environ.get("RR_TX_ROOT", "/var/lib/rr-update"))
    args = parser.parse_args()
    try:
        backup = validate_backup_dir(args.backup_dir, args.tx_root)
        if args.operation == "snapshot":
            snapshot(backup)
        elif args.operation == "restore":
            restore(backup)
        else:
            verify(backup)
    except (OSError, StateError, KeyError, TypeError, ValueError) as exc:
        print(f"[RR-vps external state] {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
