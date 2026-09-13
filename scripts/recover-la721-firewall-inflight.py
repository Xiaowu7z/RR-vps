#!/usr/bin/env python3
"""Abort the byte-identified, unchanged LA 7.2.1 orphan firewall transaction.

This is an explicit incident recovery, not a general firewall repair tool.
It takes real writer locks, verifies the existing policy without changing it,
backs up the stopped installation, installs one pinned health-check patch,
and restores the service states recorded before the interrupted operation.

With --repair-loopback, it additionally permits one declared IPv4 loopback
exception for the local subscription port and its matching saved-file line.
Original sealed evidence, all other rules and all credentials remain intact.
"""

import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time


HOST = "DMIT-4AcBKDwTCc"
ROOT = Path("/usr/local/lib/rr")
MARKER = Path("/var/lib/rr-vps/firewall-quarantine")
EVIDENCE = Path("/var/lib/rr-vps/firewall-evidence")
TX = "/var/lib/rr-update/transactions/20260907T145836Z-2327431"
MANIFEST_SHA = "cf604eddf29d8d2ae069214844b3e9f96c3b2c80eb72359e2428d1368925b894"
MARKER_SHA = "d948a3998b0a28896c204c912b5360a8b5216b74b4e71bf8635a4cfbb9da967a"
DESIRED_SHA = "8e3c86fd1fd4b6553a044f43004d550543654a2b7da0f242605915d5b8277362"
GUARD_NAMES = ("rr-firewall-quarantine-guard.path", "rr-firewall-quarantine-guard.timer",
               "rr-firewall-quarantine-guard.service")
CONFIG_PINS = {
    "/etc/argo_vmess.conf": "266ea219cb37839906b8148bafa38332f82de39e2fb7f372569413da042f39ab",
    "/etc/sing-box/config.json": "0b54cc72ddb453d26dee68096a101922d96da5c318e4a44392f26efeb951e43c",
    "/etc/rr-nexus/nexus.json": "002448303ca0841c0bf5943be1e92f42006ce28e7856cc9fc2153c10f2a697f1",
}
RAW_PINS = {
    "iptables.filter": "ce282d5c68468a06280009ab245a6906dd9e67aeaec5a50adf94333334d05793",
    "iptables.nat": "aca8510b3123678f52b3d40f260ea5adc62b4399e083da657198c8651c7d1237",
    "ip6tables.filter": "9f6c748670a44aace2aa104b46cd85806e3cf15e82b3bac3e255fd792def16e4",
    "ip6tables.nat": "337275994730e6db7afd5842af2be191857f9d99af0aa0dfda6e05ba2026345c",
}
FILE_PINS = {
    "/usr/local/sbin/rr-firewall-quarantine-guard": "6ec3a5b65991b2d527ff6124365fe94f1d203d38669a7826d32989bb8dc407c0",
    "/etc/systemd/system/rr-firewall-quarantine-guard.service": "f412aaf13175533fe99e45c16ae4dc22da0c4c21fe257da2e4633df3a2c98d5c",
    "/etc/systemd/system/rr-firewall-quarantine-guard.path": "e724f4c1f992fb08e1321704f7136e779e987b5aab55bc68c180c5c018110111",
    "/etc/systemd/system/rr-firewall-quarantine-guard.timer": "4e0d09d68a0cd94f3a89c9ef91c0cec592a6d7abbd8c9b1013fc170655763c96",
    "/usr/local/lib/rr/modules/61-update-guard.sh": "2bbfdd8d80773cb48c19f11f91bbeb7ebd156f9419c30c5d81b3565aa346e64c",
    "/usr/local/sbin/rr-update-recover": "fddc027041ca4ce79c649f53b830c46f9d5736712c0cc9ac60fc4ccf2a8a80a9",
}
PERSISTENCE_PINS = {
    "/etc/iptables/rules.v4": "f82832186dda13eba77f5b88c22db711f9a1fd4a5f7a6d15a52d8c1906174d72",
    "/etc/iptables/rules.v6": "c84c2e0ca0c133398d9daf2747bd906df2334811b9b0b68427e1b23af958f09c",
}
EXPECTED_MARKER = (
    "firewall-inflight-v1\n"
    "unit\tsing-box.service\tloaded\tactive\tenabled\n"
    "unit\trr-nexus.service\tloaded\tactive\tenabled\n"
    "unit\trr-subscription.service\tnot-found\tinactive\tnot-found\n"
    "unit\targo-rr-health.service\tloaded\tinactive\tstatic\n"
    "unit\targo-rr-health.timer\tloaded\tinactive\tdisabled\n"
    "runtime\tsingbox\ttrue\nruntime\tsubscription\ttrue\n"
    "evidence\tfirewall-evidence-v1\n"
).encode()
ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
       "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8", "SYSTEMD_PAGER": "cat",
       "SYSTEMD_COLORS": "0", "PYTHONDONTWRITEBYTECODE": "1"}


SOURCE_SHA256 = "7c7da6ec8a5be181de680d7f76092b37f49f70774443e28b7d0b0531460ed69d"
PATCHED_SHA256 = "ecc1eeaf5e7ae73e2e337d94b2abcd4acf59b4bcca9eb70b1edeef92cd6e30c7"

OLD_OPERATION = '''        hop_repair_status=0
        install_hop_rules "$hop_label" "$hop_port" "$hop_specs" \\
            >/dev/null 2>&1 || hop_repair_status=$?
        case "$hop_repair_status" in
            0) ;;
            1)
                rr_health_log \\
                    "${hop_label} 端口跳跃修复失败，但已证明 live 防火墙保持原态；本轮健康检查失败"
                return 1
                ;;
            2)
                rr_health_log \\
                    "${hop_label} 端口跳跃修复后的防火墙状态不确定；Sing-box 已停止并验证 inactive"
                return 1
                ;;
            3|*)
                rr_health_log \\
                    "紧急：${hop_label} 端口跳跃修复状态不确定，且无法验证 Sing-box 已停止"
                return 1
                ;;
        esac
'''.encode("utf-8")

NEW_OPERATION = '''        # An ordinary health pass must not arm an in-flight transaction merely
        # to observe configured hops: that transaction deliberately stops ingress.
        # The validator also checks effective first-match ordering. Contain the
        # auto-address resolver's shell variables in this observation subprocess.
        if ! declare -F rr_validate_hop_rules >/dev/null 2>&1 || \\
           ! ( rr_validate_hop_rules "$hop_label" "$hop_port" "$hop_specs" ) \\
                >/dev/null 2>&1; then
            rr_health_log \\
                "${hop_label} 端口跳跃只读校验未通过；未自动改写防火墙或停止节点，请人工检查规则与后端状态"
            return 1
        fi
'''.encode("utf-8")


def transform_bytes(source: bytes) -> bytes:
    """Return exactly the pinned candidate, or refuse unknown input bytes."""
    if not isinstance(source, bytes):
        raise TypeError("source must be bytes")
    if hashlib.sha256(source).hexdigest() != SOURCE_SHA256:
        raise ValueError("unsupported original module SHA256")
    declaration = b"    local hop_repair_status=0\n"
    if source.count(declaration) != 1 or source.count(OLD_OPERATION) != 1:
        raise ValueError("health hop operation does not match pinned source")
    candidate = source.replace(declaration, b"", 1).replace(
        OLD_OPERATION, NEW_OPERATION, 1
    )
    if hashlib.sha256(candidate).hexdigest() != PATCHED_SHA256:
        raise ValueError("candidate SHA256 differs from pinned patch")
    return candidate




class Refused(RuntimeError):
    pass


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, reason):
    if not condition:
        raise Refused(reason)


def safe_directory(path, exact_mode=None):
    path = Path(path)
    for item in reversed((path, *path.parents)):
        info = item.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and
                not (info.st_mode & 0o022), "unsafe_directory:" + str(item))
    if exact_mode is not None:
        require(stat.S_IMODE(path.stat().st_mode) == exact_mode,
                "directory_mode:" + str(path))


def read_regular(path, limit=16 * 1024 * 1024):
    path = Path(path)
    safe_directory(path.parent)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(source.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == 0 and
                info.st_nlink == 1 and not info.st_mode & 0o022 and info.st_size <= limit,
                "unsafe_file:" + str(path))
        data = source.read(limit + 1)
        after = os.fstat(source.fileno())
        require(len(data) <= limit and (info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns),
                "file_changed:" + str(path))
    return data


def pinned(path, expected):
    data = read_regular(path)
    require(sha(data) == expected, "digest_mismatch:" + str(path))
    return data


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, data, mode):
    path = Path(path)
    safe_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix=".rr-la721-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as target:
            os.fchmod(target.fileno(), mode)
            target.write(data)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.lexists(temporary):
            os.unlink(temporary)


def prove_redundant_legacy_allow(program):
    """Canonicalize one semantically redundant rule in a private proof copy.

    For TCP/22049 the sole matching INPUT rule accepts, and removing it also
    accepts by the chain policy. For every other packet it cannot match.
    Reject any broader match, custom chain, alternative policy, or second
    overlapping rule: an arbitrary extra tagged rule is never exempted.
    The caller additionally binds all four original programs to incident SHAs.
    """
    lines = program.splitlines(keepends=True)
    policies = [b"-P INPUT ACCEPT\n", b"-P FORWARD ACCEPT\n", b"-P OUTPUT ACCEPT\n"]
    require(lines[:3] == policies, "legacy_allow_requires_accept_policies")
    legacy = (b"-A INPUT -p tcp -m tcp --dport 22049 -m comment "
              b"--comment argo-rr-managed -j ACCEPT\n")
    require(lines.count(legacy) == 1, "legacy_allow_requires_exact_single_rule")
    grammar = re.compile(rb"-A INPUT -p (tcp|udp) -m \1 --dport ([1-9][0-9]{0,4})"
                         rb"(?: -m comment --comment [A-Za-z0-9_-]+)? -j (?:ACCEPT|DROP)\n")
    for line in lines[3:]:
        if line == legacy:
            continue
        match = grammar.fullmatch(line)
        require(match is not None and int(match[2]) <= 65535,
                "legacy_allow_unproven_other_rule")
        require(match[1] != b"tcp" or match[2] != b"22049",
                "legacy_allow_overlapping_rule")
    return b"".join(line for line in lines if line != legacy)


LOOPBACK_RULE = (b"-A INPUT -s 127.0.0.1/32 -d 127.0.0.1/32 -i lo -p tcp -m tcp "
                 b"--dport 20382 -m comment --comment rr-la721-loopback -j ACCEPT\n")
SUBSCRIPTION_DROP = (b"-A INPUT -p tcp -m tcp --dport 20382 -m comment "
                     b"--comment argo-rr-managed-block -j DROP\n")


def rule_tokens(data):
    return [shlex.split(line.decode("ascii")) for line in data.splitlines() if line.strip()]


def loopback_raw_candidate(raw):
    require(sha(raw) == RAW_PINS["iptables.filter"], "loopback_original_filter_pin")
    require(raw.splitlines(keepends=True).count(SUBSCRIPTION_DROP) == 1,
            "loopback_original_drop")
    return raw.replace(SUBSCRIPTION_DROP, LOOPBACK_RULE + SUBSCRIPTION_DROP, 1)


def loopback_persistence_candidate(saved, raw):
    """Preserve every saved byte except one insertion in a proven filter table."""
    loopback_raw_candidate(raw)
    lines = saved.splitlines(keepends=True)
    table = None
    tables = set()
    projected = []
    insertion = None
    for index, line in enumerate(lines):
        require(line.endswith(b"\n"), "saved_firewall_missing_newline")
        stripped = line.strip()
        if not stripped or stripped.startswith(b"#"):
            continue
        if stripped.startswith(b"*"):
            require(table is None and re.fullmatch(rb"\*[a-z]+", stripped),
                    "saved_firewall_table_syntax")
            table = stripped[1:]
            require(table not in tables, "saved_firewall_duplicate_table")
            tables.add(table)
            continue
        if stripped == b"COMMIT":
            require(table is not None, "saved_firewall_unmatched_commit")
            table = None
            continue
        require(table is not None, "saved_firewall_outside_table")
        if table != b"filter":
            continue
        chain = re.fullmatch(rb":([A-Z0-9_-]+) (ACCEPT|DROP|-) \[[0-9]+:[0-9]+\]", stripped)
        if chain:
            require(chain[2] != b"-", "saved_firewall_custom_chain")
            projected.append(b"-P " + chain[1] + b" " + chain[2] + b"\n")
            continue
        rule = re.sub(rb"^\[[0-9]+:[0-9]+\] ", b"", stripped) + b"\n"
        require(rule.startswith(b"-A "), "saved_firewall_filter_syntax")
        projected.append(rule)
        if rule_tokens(rule) == rule_tokens(SUBSCRIPTION_DROP):
            require(insertion is None, "saved_firewall_duplicate_drop")
            insertion = index
    require(table is None and b"filter" in tables and insertion is not None,
            "saved_firewall_incomplete_filter")
    require(rule_tokens(b"".join(projected)) == rule_tokens(raw),
            "saved_filter_differs_from_incident")
    lines.insert(insertion, LOOPBACK_RULE)
    return b"".join(lines)


class Recovery:
    def __init__(self, repair_loopback=False):
        self.stage = None
        self.phase = "host"
        self.fds = []
        self.modules = {}
        self.original_identity = None
        self.original_subscription = None
        self.guard_stopped = False
        self.marker_removed = False
        self.patch_installed = False
        self.success = False
        self.repair_loopback = repair_loopback
        self.loopback_touched = False
        self.loopback_original_saved = None
        self.loopback_saved_candidate = None
        self.loopback_live_state = None

    def note(self, event, **values):
        line = json.dumps({"event": event, "phase": self.phase, **values}, ensure_ascii=True)
        try:
            print(line, flush=True)
        except BrokenPipeError:
            pass
        if self.stage is not None:
            with (self.stage / "recovery.log").open("a", encoding="utf-8") as log:
                log.write(line + "\n")

    def step(self, name, callback):
        self.phase = name
        self.note("RECOVERY_STEP")
        result = callback()
        self.note("RECOVERY_CHECK", result="PASS")
        return result

    def command(self, args, *, input_data=None, timeout=30):
        executable = shutil.which(args[0], path=ENV["PATH"])
        require(executable is not None, "missing_command:" + args[0])
        result = subprocess.run([executable, *args[1:]], input=input_data,
                                stdin=subprocess.DEVNULL if input_data is None else None,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=ENV, close_fds=True, timeout=timeout, check=False)
        label = " ".join(args) if args[0] == "systemctl" else args[0]
        if self.stage is not None and (result.stdout or result.stderr or args[0] == "systemctl"):
            with (self.stage / "commands.log").open("ab") as log:
                log.write(("\nPHASE " + self.phase + " COMMAND " + label + "\n").encode())
                log.write(result.stdout + result.stderr)
        require(result.returncode == 0, "command_failed:" + label + ":rc=" + str(result.returncode))
        return result.stdout

    def unit(self, name):
        props = "Id,LoadState,ActiveState,SubState,UnitFileState,FragmentPath,DropInPaths,MainPID,Result"
        output = self.command(["systemctl", "show", name, "--property=" + props, "--no-pager"])
        result = dict(line.split("=", 1) for line in output.decode().splitlines() if "=" in line)
        require(result.get("Id") == name, "unit_identity:" + name)
        if result.get("LoadState") == "not-found" and not result.get("UnitFileState"):
            result["UnitFileState"] = "not-found"
        return result

    def reset_failed_if_needed(self, name):
        # ResetFailedUnit intentionally does not load units in systemd. An
        # inactive, disabled timer may be garbage-collected after stop; a
        # batch reset then fails despite that timer having no failed state.
        # Reset only actual failures, individually, and prove the result.
        require(name in {*GUARD_NAMES, "sing-box.service", "rr-nexus.service"},
                "unsupported_failure_reset_unit")
        value = self.unit(name)
        require(value.get("LoadState") == "loaded" and
                value.get("ActiveState") in {"inactive", "failed"},
                "unexpected_reset_state:" + name)
        limits = {"start-limit-hit", "unit-start-limit-hit"}
        if value.get("ActiveState") != "failed" and value.get("Result") not in limits:
            self.note("UNIT_FAILURE_RESET", unit=name, action="not_needed", state="inactive")
            return
        self.command(["systemctl", "reset-failed", name])
        value = self.unit(name)
        require(value.get("LoadState") == "loaded" and
                value.get("ActiveState") == "inactive" and value.get("Result") not in limits,
                "unit_failure_not_cleared:" + name)
        self.note("UNIT_FAILURE_RESET", unit=name, action="cleared", state="inactive")

    def verify_host(self):
        require(os.geteuid() == 0 and os.uname().nodename == HOST, "host_or_uid")
        require(sha(EXPECTED_MARKER) == MARKER_SHA, "internal_marker_pin")
        os.umask(0o077)
        self.note("RECOVERY_SCOPE", host=HOST,
                  mode="abort_orphan_with_scoped_loopback_v2" if self.repair_loopback else "abort_unchanged_orphan_v1",
                  firewall_writes=self.repair_loopback, configuration_replacement=False,
                  firewall_exception="ipv4_lo_127_to_127_tcp_20382" if self.repair_loopback else None)

    def acquire_locks(self):
        paths = ("/run/rr-vps/locks/update.lock", "/run/lock/rr-update.lock",
                 "/run/rr-vps/locks/firewall.lock")
        for path in paths:
            if path == paths[1] and not os.path.lexists(path):
                continue
            original = read_regular(path, 4096)
            require(not original, "nonempty_lock:" + path)
            require(stat.S_IMODE(os.stat(path).st_mode) == 0o600, "lock_mode:" + path)
            fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC)
            self.fds.append((fd, path))
            deadline = time.monotonic() + 20
            self.note("RECOVERY_WAIT", lock=path, max_wait_seconds=20)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    require(time.monotonic() < deadline, "writer_busy:" + path)
                    time.sleep(0.1)
            current, opened = os.stat(path, follow_symlinks=False), os.fstat(fd)
            require((current.st_dev, current.st_ino) == (opened.st_dev, opened.st_ino),
                    "lock_replaced:" + path)

    def verify_runtime(self):
        manifest = pinned(ROOT / "manifest.sha256", MANIFEST_SHA)
        names = set()
        for line in manifest.decode("ascii").splitlines():
            match = re.fullmatch(r"([a-f0-9]{64})  ([A-Za-z0-9_./-]+)", line)
            require(match is not None, "manifest_format")
            expected, name = match.groups()
            require(not name.startswith("/") and ".." not in Path(name).parts and name not in names,
                    "manifest_path")
            names.add(name)
            path = Path("/usr/local/bin/rr") if name == "rr" else ROOT / name
            data = read_regular(path)
            allowed = {expected}
            if name == "modules/60-update.sh":
                require(expected == SOURCE_SHA256, "health_original_manifest_pin")
                allowed.add(PATCHED_SHA256)
            require(sha(data) in allowed, "installed_file_changed:" + name)
            if name.startswith("modules/"):
                self.modules[Path(name).name] = data
        require(len(names) == 35, "manifest_count")
        for path, expected in FILE_PINS.items():
            data = pinned(path, expected)
            if path.endswith("/modules/61-update-guard.sh"):
                self.modules["61-update-guard.sh"] = data
        require({path.name for path in (ROOT / "modules").glob("*.sh")} == set(self.modules),
                "unexpected_module")
        require(b'SCRIPT_VERSION="7.2.1"' in self.modules["00-runtime.sh"], "installed_version")

    def verify_transactions(self):
        absent = ("/var/lib/rr-backup/active", "/run/rr-vps/restore-live",
                  "/run/rr-vps/restore-watch-request", "/run/rr-vps/update-maintenance",
                  "/etc/sing-box/.pair-pending", "/etc/rr-naive/.pair-pending")
        for path in absent:
            require(not os.path.lexists(path), "pending_state:" + path)
        require(read_regular("/var/lib/rr-update/active", 4096).decode().strip() == TX,
                "unexpected_update_transaction")
        require(read_regular(Path(TX) / "phase", 256).strip() == b"committed", "update_not_committed")
        require(read_regular(Path(TX) / "firewall-finalize-complete", 4096).strip() ==
                b"local-subscription-firewall-v1 20382", "update_firewall_not_finalized")

    def verify_files_and_firewall(self, require_marker=True):
        for pins in (CONFIG_PINS, PERSISTENCE_PINS):
            for path, expected in pins.items():
                if self.repair_loopback and path == "/etc/iptables/rules.v4":
                    saved = read_regular(path)
                    original = saved
                    if sha(saved) != expected:
                        require(saved.splitlines(keepends=True).count(LOOPBACK_RULE) == 1,
                                "saved_loopback_not_exact")
                        original = saved.replace(LOOPBACK_RULE, b"", 1)
                    require(sha(original) == expected, "saved_loopback_original_pin")
                    raw = pinned(EVIDENCE / "firewall/iptables.filter.raw", RAW_PINS["iptables.filter"])
                    candidate = loopback_persistence_candidate(original, raw)
                    require(saved in (original, candidate), "saved_loopback_state")
                    self.loopback_original_saved = original
                    self.loopback_saved_candidate = candidate
                    continue
                pinned(path, expected)
        if require_marker:
            require(pinned(MARKER, MARKER_SHA) == EXPECTED_MARKER, "marker_profile")
        safe_directory(EVIDENCE, 0o700)
        count = 0
        for directory, dirs, files in os.walk(EVIDENCE, followlinks=False):
            safe_directory(directory, 0o700)
            for name in dirs:
                safe_directory(Path(directory) / name, 0o700)
            for name in files:
                path = Path(directory) / name
                read_regular(path)
                require(stat.S_IMODE(path.stat().st_mode) == 0o600, "evidence_file_mode:" + name)
                count += 1
                require(count <= 128, "evidence_tree_too_large")
        require(read_regular(EVIDENCE / "evidence.complete", 128) == b"firewall-evidence-v1\n",
                "evidence_incomplete")
        require(read_regular(EVIDENCE / "firewall/complete", 128) == b"firewall-snapshot-v2\n",
                "snapshot_incomplete")
        require(read_regular(EVIDENCE / "config.sha256", 128).strip().decode() ==
                CONFIG_PINS["/etc/argo_vmess.conf"], "config_evidence_binding")
        pinned(EVIDENCE / "desired.namespace", DESIRED_SHA)
        for name, expected in RAW_PINS.items():
            sealed = pinned(EVIDENCE / "firewall" / (name + ".raw"), expected)
            backend, table = name.split(".")
            live = self.command([backend, "-w", "3", "-t", table, "-S"], timeout=8)
            if self.repair_loopback and name == "iptables.filter":
                candidate = loopback_raw_candidate(sealed)
                if live == sealed:
                    self.loopback_live_state = "original"
                else:
                    require(rule_tokens(live) == rule_tokens(candidate), "live_loopback_not_exact")
                    self.loopback_live_state = "repaired"
                self.note("FIREWALL_SCOPED_CHECK", backend=backend, table=table,
                          state=self.loopback_live_state, external_policy="unchanged")
                continue
            require(live == sealed, "live_firewall_changed:" + name)
            self.note("FIREWALL_UNCHANGED", backend=backend, table=table, sha256=expected)

    def verify_stopped_units(self):
        wanted = {"sing-box.service": ("loaded", "disabled"),
                  "rr-nexus.service": ("loaded", "disabled"),
                  "rr-subscription.service": ("not-found", "not-found"),
                  "argo-rr-health.service": ("loaded", "static"),
                  "argo-rr-health.timer": ("loaded", "disabled")}
        for name, (load, enabled) in wanted.items():
            value = self.unit(name)
            require(value.get("LoadState") == load and value.get("UnitFileState") == enabled and
                    value.get("ActiveState") in {"inactive", "failed"}, "unexpected_service_state:" + name)
        for name in GUARD_NAMES:
            value = self.unit(name)
            require(value.get("LoadState") == "loaded" and not value.get("DropInPaths") and
                    value.get("FragmentPath") == "/etc/systemd/system/" + name,
                    "guard_unit_identity:" + name)

    def identities(self):
        database = Path("/var/lib/rr-nexus/nexus.db")
        safe_directory(database.parent)
        fd = os.open(database, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_gid == 0 and
                    info.st_nlink == 1 and not info.st_mode & 0o022, "nexus_database_file_identity")
        finally:
            os.close(fd)
        with sqlite3.connect("file:/var/lib/rr-nexus/nexus.db?mode=ro", uri=True, timeout=5) as db:
            require(db.execute("PRAGMA quick_check").fetchone() == ("ok",), "nexus_database_integrity")
            admins = db.execute("SELECT username,password_hash FROM admins ORDER BY username").fetchall()
            devices = db.execute("SELECT id,name,credential,subscription_token,enabled,quota_bytes FROM devices ORDER BY id").fetchall()
        return {"admins": admins, "devices": devices}

    def subscription_tree(self):
        root = Path("/tmp/sub_server")
        info = root.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and info.st_gid == 0 and
                stat.S_IMODE(info.st_mode) == 0o700, "subscription_root_identity")
        result = []
        for directory, dirs, files in os.walk(root, followlinks=False):
            for name in sorted(dirs + files):
                path = Path(directory) / name
                info = path.lstat()
                require(info.st_uid == 0 and (stat.S_ISLNK(info.st_mode) or not info.st_mode & 0o022),
                        "subscription_path_owner")
                relative = str(path.relative_to(root))
                if stat.S_ISLNK(info.st_mode):
                    result.append((relative, "link", os.readlink(path)))
                elif stat.S_ISDIR(info.st_mode):
                    result.append((relative, "directory", stat.S_IMODE(info.st_mode)))
                elif stat.S_ISREG(info.st_mode):
                    require(info.st_size <= 16 * 1024 * 1024, "subscription_file_size")
                    result.append((relative, "file", sha(path.read_bytes())))
                else:
                    raise Refused("subscription_special_file")
                require(len(result) <= 10000, "subscription_tree_size")
        require(any(item[0].endswith("/jhsub.txt") for item in result) and
                any(item[0].endswith("/client.json") for item in result), "subscription_outputs_missing")
        return sorted(result)

    def backup(self):
        self.original_identity = self.identities()
        self.original_subscription = self.subscription_tree()
        safe_directory("/root")
        self.stage = Path(tempfile.mkdtemp(prefix="rr-recover-la721.", dir="/root"))
        self.note("RECOVERY_BACKUP", directory=str(self.stage))
        modules = self.stage / "modules"
        modules.mkdir(mode=0o700)
        for name, data in self.modules.items():
            atomic_write(modules / name, data, 0o600)
        paths = [str(MARKER), str(EVIDENCE), *CONFIG_PINS, *PERSISTENCE_PINS, *FILE_PINS,
                 str(ROOT / "manifest.sha256"), str(ROOT / "modules/60-update.sh"),
                 "/etc/systemd/system/sing-box.service", "/etc/systemd/system/sing-box.service.d",
                 "/etc/systemd/system/rr-nexus.service", "/etc/systemd/system/rr-nexus.service.d",
                 "/etc/systemd/system/argo-rr-health.service", "/etc/systemd/system/argo-rr-health.timer",
                 "/run/rr-vps-subscription.pid", "/run/rr-vps-subscription.bind", "/tmp/sub_server"]
        with tarfile.open(self.stage / "files.tar.gz", "w:gz", dereference=False) as archive:
            for path in dict.fromkeys(paths):
                if os.path.lexists(path):
                    archive.add(path, arcname=path.lstrip("/"), recursive=True)
        with sqlite3.connect("file:/var/lib/rr-nexus/nexus.db?mode=ro", uri=True, timeout=5) as source:
            with sqlite3.connect(self.stage / "nexus.db") as target:
                source.backup(target)
                require(target.execute("PRAGMA quick_check").fetchone() == ("ok",), "backup_database_integrity")
        atomic_write(self.stage / "identities.json", json.dumps(self.original_identity).encode(), 0o600)
        atomic_write(self.stage / "original-marker", EXPECTED_MARKER, 0o600)
        for path in (self.stage / "files.tar.gz", self.stage / "nexus.db"):
            with path.open("rb") as source:
                os.fsync(source.fileno())
        sync_directory(self.stage)

    def prepare_policy_projection(self):
        require(self.stage is not None, "policy_projection_requires_backup")
        desired = pinned(EVIDENCE / "desired.namespace", DESIRED_SHA)
        require(not any(line.startswith((b"protocol|open|22049|", b"protocol|closed|22049|"))
                        for line in desired.splitlines()), "legacy_port_is_desired")
        root = self.stage / "policy-projection"
        root.mkdir(mode=0o700)
        (root / "firewall").mkdir(mode=0o700)
        receipt = {}
        for name, expected in RAW_PINS.items():
            raw = pinned(EVIDENCE / "firewall" / (name + ".raw"), expected)
            projected = prove_redundant_legacy_allow(raw) if name.endswith(".filter") else raw
            atomic_write(root / "firewall" / (name + ".raw"), projected, 0o600)
            receipt[name] = {"original_sha256": expected, "projection_sha256": sha(projected)}
        atomic_write(root / "proof.json", json.dumps({
            "proof": "redundant_tcp_22049_accept_under_disjoint_accept_policy",
            "scope": "private_validation_copy_only", "live_rules_modified": False,
            "sealed_evidence_modified": False, "programs": receipt,
        }).encode(), 0o600)
        self.note("LEGACY_RULE_EQUIVALENCE", port=22049, protocol="tcp",
                  families=["IPv4", "IPv6"], live_rules_modified=False)

    def helper(self, operation):
        require(self.stage is not None, "helper_requires_backup")
        bodies = {
            "verify": r'''
check() { local rr_la_check_name="$1"; shift; "$@" >/dev/null 2>&1; local rr_la_check_rc=$?; printf 'READONLY_CHECK name=%s rc=%s\n' "$rr_la_check_name" "$rr_la_check_rc"; [ "$rr_la_check_rc" = 0 ]; }
runtime_idle() { "$@"; local rr_la_probe_rc=$?; [ "$rr_la_probe_rc" = 1 ]; }
check config load_config_with_defaults || exit 1
[ "$SUB_ACCESS_MODE" = local ] && [ "$SUB_PORT" = 20382 ] && [ "$SUB_ROOT" = /tmp/sub_server ] || exit 1
check marker rr_firewall_load_inflight_marker || exit 1
check raw_evidence rr_restore_verify_firewall_pre_mutation_snapshot /var/lib/rr-vps/firewall-evidence || exit 1
rr_la_failed=0
# Only the namespace syntax pass reads the private, equivalence-proven copy.
# Every per-port and first-match check in this function still reads real live
# backends. The original config, sealed evidence and rule programs stay intact.
check desired_policy rr_firewall_verify_desired_namespace "$2" /var/lib/rr-vps/firewall-evidence/desired.namespace || rr_la_failed=1
check supervisor rr_firewall_quarantine_supervisor_effective || rr_la_failed=1
check singbox_unit rr_singbox_service_guards_are_effective || rr_la_failed=1
check singbox_certificate rr_singbox_certificate_start_gate || rr_la_failed=1
check singbox_config "$SINGBOX_BIN" check -c /etc/sing-box/config.json || rr_la_failed=1
check nexus_unit nexus_service_effective_identity_is_exact || rr_la_failed=1
check nexus_guards nexus_service_effective_guards_are_exact || rr_la_failed=1
check singbox_idle runtime_idle managed_singbox_running || rr_la_failed=1
check subscription_idle runtime_idle subscription_server_running || rr_la_failed=1
exit "$rr_la_failed"
''',
            "start_subscription": r'''
load_config_with_defaults || exit 1
[ "$SUB_ACCESS_MODE" = local ] && [ "$SUB_PORT" = 20382 ] && [ "$SUB_ROOT" = /tmp/sub_server ] || exit 1
start_subscription_server || exit 1
subscription_server_running || exit 1
rr_local_subscription_loopback_ready || exit 1
''',
            "stop_subscription": "load_config_with_defaults && stop_subscription_servers\n",
            "verify_subscription": "load_config_with_defaults && subscription_server_running && rr_local_subscription_loopback_ready\n",
        }
        require(operation in bodies, "unsupported_helper")
        if self.repair_loopback and operation == "verify":
            # Python checks all sealed hashes, every live rule and saved file,
            # allowing only the explicitly declared loopback delta. The old
            # byte-equality predicate cannot represent that authorized repair.
            self.verify_files_and_firewall()
            bodies[operation] = bodies[operation].replace(
                "check raw_evidence rr_restore_verify_firewall_pre_mutation_snapshot /var/lib/rr-vps/firewall-evidence || exit 1",
                "printf 'READONLY_CHECK name=scoped_firewall_evidence rc=0\\n'")
        source = ('set -o pipefail\nfor module in "$1"/*.sh; do source "$module" || exit 1; done\n' + bodies[operation]).encode()
        try:
            output = self.command(["bash", "--noprofile", "--norc", "-s", "--", str(self.stage / "modules"),
                                   str(self.stage / "policy-projection")],
                                  input_data=source, timeout=180)
        except Refused:
            # Print only labels emitted by this script, never arbitrary module
            # output or a configuration/credential-bearing subprocess error.
            data = (self.stage / "commands.log").read_text(errors="replace")[-16000:]
            checks = re.findall(r"(?m)^READONLY_CHECK name=([a-z_]+) rc=([0-9]+)$", data)
            for name, rc in checks:
                self.note("RECOVERY_PREDICATE", name=name, rc=int(rc))
            raise
        for line in output.decode(errors="replace").splitlines():
            match = re.fullmatch(r"READONLY_CHECK name=([a-z_]+) rc=([0-9]+)", line)
            if match:
                self.note("RECOVERY_PREDICATE", name=match[1], rc=int(match[2]))

    def stop_guard(self):
        self.guard_stopped = True
        self.command(["systemctl", "stop", GUARD_NAMES[0]])
        self.command(["systemctl", "stop", *GUARD_NAMES[1:]])
        for name in GUARD_NAMES:
            require(self.unit(name).get("ActiveState") in {"inactive", "failed"}, "guard_not_stopped:" + name)

    def patch_health(self):
        path = ROOT / "modules/60-update.sh"
        source = read_regular(path)
        candidate = source if sha(source) == PATCHED_SHA256 else transform_bytes(source)
        require(sha(candidate) == PATCHED_SHA256, "health_patch_digest")
        self.command(["bash", "-n"], input_data=candidate)
        if source != candidate:
            atomic_write(path, candidate, 0o644)
        self.patch_installed = True
        pinned(path, PATCHED_SHA256)
        pinned(ROOT / "manifest.sha256", MANIFEST_SHA)
        atomic_write(self.stage / "health-patch.json", json.dumps({
            "official_version": "7.2.1", "local_hotfix": "readonly-health-hop",
            "source_sha256": SOURCE_SHA256, "installed_sha256": PATCHED_SHA256,
            "manifest_changed": False, "future_release_must_include_fix": True,
        }).encode(), 0o600)

    def repair_local_subscription_route(self):
        require(self.repair_loopback and self.stage is not None, "loopback_repair_scope")
        self.verify_files_and_firewall()
        require(self.loopback_original_saved is not None, "loopback_saved_preflight")
        atomic_write(self.stage / "loopback-original-rules.v4", self.loopback_original_saved, 0o600)
        atomic_write(self.stage / "loopback-candidate-rules.v4", self.loopback_saved_candidate, 0o600)
        self.loopback_touched = True
        raw = pinned(EVIDENCE / "firewall/iptables.filter.raw", RAW_PINS["iptables.filter"])
        if self.loopback_live_state == "original":
            input_rules = [line for line in raw.splitlines(keepends=True) if line.startswith(b"-A INPUT ")]
            position = input_rules.index(SUBSCRIPTION_DROP) + 1
            self.command(["iptables", "-w", "5", "-t", "filter", "-I", "INPUT", str(position),
                          *shlex.split(LOOPBACK_RULE.decode())[2:]], timeout=10)
        self.verify_files_and_firewall()
        require(self.loopback_live_state == "repaired", "loopback_insert_not_verified")
        saved_path = Path("/etc/iptables/rules.v4")
        current = read_regular(saved_path)
        require(current in (self.loopback_original_saved, self.loopback_saved_candidate),
                "loopback_saved_changed_before_write")
        if current != self.loopback_saved_candidate:
            atomic_write(saved_path, self.loopback_saved_candidate, stat.S_IMODE(saved_path.stat().st_mode))
        self.verify_files_and_firewall()
        self.note("LOOPBACK_REPAIRED", interface="lo", source="127.0.0.1/32", destination="127.0.0.1/32",
                  protocol="tcp", port=20382, external_drop="preserved", persistence="updated")

    def rollback_loopback(self):
        if not self.loopback_touched:
            return
        # Services have already been stopped by protect_failure. Never replace
        # unknown files/rules; each removal is limited to this exact exception.
        errors = []
        try:
            path = Path("/etc/iptables/rules.v4")
            current = read_regular(path)
            require(current in (self.loopback_original_saved, self.loopback_saved_candidate),
                    "loopback_rollback_saved_changed")
            if current != self.loopback_original_saved:
                atomic_write(path, self.loopback_original_saved, stat.S_IMODE(path.stat().st_mode))
        except Exception as error:
            errors.append(type(error).__name__)
        try:
            raw = pinned(EVIDENCE / "firewall/iptables.filter.raw", RAW_PINS["iptables.filter"])
            live = self.command(["iptables", "-w", "3", "-t", "filter", "-S"], timeout=8)
            if live != raw:
                require(rule_tokens(live) == rule_tokens(loopback_raw_candidate(raw)),
                        "loopback_rollback_live_changed")
                self.command(["iptables", "-w", "5", "-t", "filter", "-D", "INPUT",
                              *shlex.split(LOOPBACK_RULE.decode())[2:]], timeout=10)
            require(self.command(["iptables", "-w", "3", "-t", "filter", "-S"], timeout=8) == raw,
                    "loopback_rollback_not_verified")
        except Exception as error:
            errors.append(type(error).__name__)
        require(not errors, "loopback_rollback_uncertain:" + ",".join(errors))
        self.note("LOOPBACK_ROLLBACK", live="original", persistence="original")

    def finish_orphan(self):
        # The original writer identity is deliberately not fabricated. Both
        # real locks and unchanged-policy evidence authorize this explicit
        # abort of the abandoned operation, not a continuation under its PID.
        self.verify_files_and_firewall()
        for name in GUARD_NAMES:
            require(self.unit(name).get("ActiveState") in {"inactive", "failed"}, "guard_reactivated")
        self.command(["systemctl", "enable", "sing-box.service", "rr-nexus.service"])
        for name in ("sing-box.service", "rr-nexus.service"):
            value = self.unit(name)
            require(value.get("UnitFileState") == "enabled" and value.get("ActiveState") in {"inactive", "failed"},
                    "enablement_not_restored:" + name)
        pinned(MARKER, MARKER_SHA)
        archive = MARKER.parent / (".firewall-inflight-aborted-" + self.stage.name)
        require(not os.path.lexists(archive), "archive_already_exists")
        os.rename(MARKER, archive)
        self.marker_removed = True
        sync_directory(MARKER.parent)
        self.note("ORPHAN_ABORTED", marker_archive=str(archive), firewall_unchanged=not self.repair_loopback,
                  external_policy="unchanged")
        for name in GUARD_NAMES:
            self.reset_failed_if_needed(name)
        self.command(["systemctl", "start", "rr-firewall-quarantine-guard.path"])
        require(self.unit("rr-firewall-quarantine-guard.path").get("ActiveState") == "active", "idle_guard_not_active")

    def start_services(self):
        for name in ("sing-box.service", "rr-nexus.service"):
            self.reset_failed_if_needed(name)
        self.command(["systemctl", "start", "sing-box.service"], timeout=60)
        self.helper("start_subscription")
        self.command(["systemctl", "start", "rr-nexus.service"], timeout=60)
        nexus = json.loads(read_regular("/etc/rr-nexus/nexus.json"))
        nexus_host = nexus.get("listen", "127.0.0.1")
        nexus_host = {"0.0.0.0": "127.0.0.1", "::": "::1"}.get(nexus_host, nexus_host)
        nexus_port = nexus.get("port", 7900)
        require(nexus_host in {"127.0.0.1", "::1", "localhost"} and
                isinstance(nexus_port, int) and 1 <= nexus_port <= 65535, "nexus_local_listener_profile")
        deadline = time.monotonic() + 20
        endpoint_states = {}
        while True:
            values = [self.unit(name) for name in ("sing-box.service", "rr-nexus.service")]
            if all(value.get("ActiveState") == "active" and value.get("SubState") == "running" and
                   int(value.get("MainPID", "0")) > 1 for value in values):
                endpoint_states = {}
                for endpoint in (("127.0.0.1", 20382), (nexus_host, nexus_port)):
                    try:
                        with socket.create_connection(endpoint, timeout=1):
                            pass
                        endpoint_states[str(endpoint)] = "connected"
                    except OSError as error:
                        endpoint_states[str(endpoint)] = type(error).__name__ + ":" + str(error.errno)
                if all(state == "connected" for state in endpoint_states.values()):
                    break
            if time.monotonic() >= deadline:
                for name, value in zip(("sing-box.service", "rr-nexus.service"), values):
                    self.note("SERVICE_READINESS_FAILED", unit=name,
                              state={key: value.get(key) for key in ("ActiveState", "SubState", "MainPID", "Result")})
                self.note("ENDPOINT_READINESS_FAILED", endpoints=endpoint_states)
            require(time.monotonic() < deadline, "services_not_running")
            time.sleep(0.25)

    def postverify(self):
        require(not os.path.lexists(MARKER), "marker_reappeared")
        self.verify_files_and_firewall(require_marker=False)
        if self.repair_loopback:
            require(self.loopback_live_state == "repaired" and
                    read_regular("/etc/iptables/rules.v4") == self.loopback_saved_candidate,
                    "loopback_postverify")
        pinned(ROOT / "modules/60-update.sh", PATCHED_SHA256)
        pinned(ROOT / "manifest.sha256", MANIFEST_SHA)
        require(self.identities() == self.original_identity, "user_identity_changed")
        require(self.subscription_tree() == self.original_subscription, "subscription_content_changed")
        self.helper("verify_subscription")
        for name in ("sing-box.service", "rr-nexus.service"):
            value = self.unit(name)
            require(value.get("ActiveState") == "active" and value.get("UnitFileState") == "enabled",
                    "restored_service_state:" + name)
        for name, enabled in (("argo-rr-health.timer", "disabled"), ("argo-rr-health.service", "static"),
                              ("rr-subscription.service", "not-found")):
            value = self.unit(name)
            require(value.get("ActiveState") == "inactive" and value.get("UnitFileState") == enabled,
                    "original_idle_state_changed:" + name)
        path = self.unit("rr-firewall-quarantine-guard.path")
        require(path.get("ActiveState") == "active" and path.get("UnitFileState") == "enabled", "guard_path_state")
        timer = self.unit("rr-firewall-quarantine-guard.timer")
        require(timer.get("ActiveState") == "inactive" and timer.get("UnitFileState") == "disabled", "guard_timer_state")
        atomic_write(self.stage / "complete.json", json.dumps({
            "result": "LA721_RECOVERY_COMPLETE", "host": HOST,
            "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "marker_sha256": MARKER_SHA, "identities": "preserved",
            "configuration": "unchanged", "firewall": "ipv4_loopback_20382_repaired" if self.repair_loopback else "unchanged",
            "external_policy": "unchanged",
            "persistence": "matching_loopback_repair" if self.repair_loopback else "unchanged",
            "health_hotfix_sha256": PATCHED_SHA256,
        }).encode(), 0o600)
        self.success = True
        self.note("LA721_RECOVERY_COMPLETE", backup=str(self.stage), identities="preserved",
                  firewall="ipv4_loopback_20382_repaired" if self.repair_loopback else "unchanged",
                  persistence="matching_loopback_repair" if self.repair_loopback else "unchanged", health_timer="disabled",
                  local_hotfix="readonly-health-hop")

    def protect_failure(self):
        if not self.guard_stopped:
            return
        original_phase = self.phase
        self.phase = "failure_protection"
        uncertain = False
        actions = []
        # Keep exactly the original evidence; no new snapshot is allowed to
        # overwrite its previously running service states. Every stop is
        # attempted even if restoring the marker or another stop fails.
        if self.marker_removed and not os.path.lexists(MARKER):
            actions.append(lambda: atomic_write(MARKER, EXPECTED_MARKER, 0o600))
        actions += [
            lambda: self.command(["systemctl", "stop", GUARD_NAMES[0]]),
            lambda: self.command(["systemctl", "stop", *GUARD_NAMES[1:]]),
            lambda: self.command(["systemctl", "disable", "--now", "sing-box.service", "rr-nexus.service"]),
            lambda: self.helper("stop_subscription"),
        ]
        for action in actions:
            try:
                action()
            except (Exception, KeyboardInterrupt):
                uncertain = True
        for name in ("sing-box.service", "rr-nexus.service"):
            try:
                require(self.unit(name).get("ActiveState") in {"inactive", "failed"}, "failure_stop_unproven")
            except (Exception, KeyboardInterrupt):
                uncertain = True
        try:
            self.rollback_loopback()
        except (Exception, KeyboardInterrupt):
            uncertain = True
        self.note("RECOVERY_PROTECTION", original_phase=original_phase, cleanup_uncertain=uncertain,
                  marker_retained=os.path.lexists(MARKER), health_hotfix_retained=self.patch_installed)

    def run(self):
        try:
            self.step("host", self.verify_host)
            self.step("writer_locks", self.acquire_locks)
            self.step("installed_identity", self.verify_runtime)
            self.step("transaction_state", self.verify_transactions)
            self.step("unchanged_firewall_evidence", self.verify_files_and_firewall)
            self.step("stopped_service_state", self.verify_stopped_units)
            self.step("backup", self.backup)
            self.step("prove_legacy_rule_equivalence", self.prepare_policy_projection)
            self.step("read_only_policy_and_service_preflight", lambda: self.helper("verify"))
            self.step("stop_quarantine_guard", self.stop_guard)
            self.step("health_observation_hotfix", self.patch_health)
            if self.repair_loopback:
                self.step("repair_subscription_loopback", self.repair_local_subscription_route)
            self.step("abort_unchanged_orphan", self.finish_orphan)
            self.step("restore_recorded_services", self.start_services)
            self.step("postverify", self.postverify)
            return 0
        except (Exception, KeyboardInterrupt) as error:
            failed_phase = self.phase
            self.protect_failure()
            self.phase = failed_phase
            self.note("RECOVERY_STOP", reason=str(error) if isinstance(error, Refused) else type(error).__name__,
                      backup=str(self.stage) if self.stage else None)
            return 1
        finally:
            for fd, _path in reversed(self.fds):
                os.close(fd)


def main():
    if sys.argv[1:] not in ([], ["--repair-loopback"]):
        print("Usage: python3 recover-la721-firewall-inflight.py [--repair-loopback]", file=sys.stderr)
        return 2
    def interrupted(signum, _frame):
        raise InterruptedError("signal_" + str(signum))
    signal.signal(signal.SIGHUP, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    return Recovery(repair_loopback=sys.argv[1:] == ["--repair-loopback"]).run()


if __name__ == "__main__":
    raise SystemExit(main())
