#!/usr/bin/env python3
"""Read-only RR firewall incident snapshot; never authorizes a recovery.

Uses Python 3.10+ standard library and read-only systemctl/iptables queries.
Does not source RR modules, run health checks, acquire locks, create backups,
change services, or print configuration contents, process arguments or env.
"""

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time


LIMIT = 8 * 1024 * 1024
ROOT = Path("/usr/local/lib/rr")
EVIDENCE = Path("/var/lib/rr-vps/firewall-evidence")
MARKER = Path("/var/lib/rr-vps/firewall-quarantine")
ENV = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
       "LC_ALL": "C", "SYSTEMD_PAGER": "cat", "SYSTEMD_COLORS": "0"}


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=True,
                     separators=(",", ":")), flush=True)


def digest(data):
    return hashlib.sha256(data).hexdigest() if data is not None else None


def metadata(path):
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return {"exists": False}
    except OSError as error:
        return {"exists": None, "error": type(error).__name__}
    kind = ("file" if stat.S_ISREG(info.st_mode) else
            "directory" if stat.S_ISDIR(info.st_mode) else
            "symlink" if stat.S_ISLNK(info.st_mode) else "other")
    return {"exists": True, "kind": kind, "uid": info.st_uid,
            "gid": info.st_gid, "mode": oct(stat.S_IMODE(info.st_mode)),
            "links": info.st_nlink, "size": info.st_size,
            "inode": info.st_ino, "device": info.st_dev,
            "mtime_ns": info.st_mtime_ns}


def read_file(path, limit=LIMIT):
    """Reject final symlinks/devices and detect a changing opened file."""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_size > limit:
            return None, "not_regular_or_too_large"
        with os.fdopen(descriptor, "rb") as source:
            descriptor = None
            data = source.read(limit + 1)
            after = os.fstat(source.fileno())
        if len(data) > limit:
            return None, "too_large"
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            return None, "changed_during_read"
        return data, None
    except OSError as error:
        return None, type(error).__name__
    finally:
        if descriptor is not None:
            os.close(descriptor)


def file_report(path, event="file"):
    info = metadata(path)
    data = None
    error = None
    if info.get("kind") == "file":
        data, error = read_file(path)
    emit(event, path=str(path), **info, sha256=digest(data), read_error=error)
    return data


def command(arguments):
    executable = shutil.which(arguments[0], path=ENV["PATH"])
    if executable is None:
        return None, None, "command_not_found"
    try:
        result = subprocess.run([executable, *arguments[1:]], env=ENV,
                                stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                timeout=8, check=False)
        if len(result.stdout) > LIMIT:
            return result.returncode, None, "output_too_large"
        return result.returncode, result.stdout, None
    except subprocess.TimeoutExpired:
        return None, None, "timeout"
    except OSError as error:
        return None, None, type(error).__name__


def marker_report():
    data = file_report(MARKER, "marker_file")
    if data is None or len(data) > 4096:
        return
    try:
        lines = data.decode("ascii").splitlines()
        versions = {"firewall-inflight-v1", "firewall-quarantine-v2"}
        units = ["sing-box.service", "rr-nexus.service", "rr-subscription.service",
                 "argo-rr-health.service", "argo-rr-health.timer"]
        if len(lines) != 9 or lines[0] not in versions:
            raise ValueError
        entries = []
        for expected, line in zip(units, lines[1:6]):
            fields = line.split("\t")
            if len(fields) != 5 or fields[:2] != ["unit", expected]:
                raise ValueError
            if any(not re.fullmatch(r"[a-z-]{1,24}", field) for field in fields[2:]):
                raise ValueError
            entries.append(dict(unit=expected, load=fields[2],
                                active=fields[3], enabled=fields[4]))
        runtimes = {}
        for expected, line in zip(("singbox", "subscription"), lines[6:8]):
            fields = line.split("\t")
            if len(fields) != 3 or fields[:2] != ["runtime", expected] or fields[2] not in {"true", "false"}:
                raise ValueError
            runtimes[expected] = fields[2] == "true"
        if lines[8] not in {"evidence\tfirewall-evidence-v1", "evidence\tunavailable"}:
            raise ValueError
        emit("marker", version=lines[0], units=entries, runtimes=runtimes,
             evidence=lines[8].split("\t")[1])
    except (UnicodeError, ValueError):
        emit("marker", parse="unsupported_or_malformed")


def evidence_report():
    emit("evidence_directory", path=str(EVIDENCE), **metadata(EVIDENCE))
    if metadata(EVIDENCE).get("kind") != "directory":
        return
    count = 0
    truncated = False
    for directory, dirs, files in os.walk(EVIDENCE, followlinks=False):
        depth = len(Path(directory).relative_to(EVIDENCE).parts)
        for name in sorted(dirs + files):
            if count >= 96:
                truncated = True
                break
            file_report(Path(directory) / name, "evidence_file")
            count += 1
        if truncated:
            break
        dirs[:] = sorted(name for name in dirs if depth < 2 and
                         metadata(Path(directory) / name).get("kind") == "directory")
    config, _ = read_file("/etc/argo_vmess.conf")
    sealed, _ = read_file(EVIDENCE / "config.sha256", 256)
    valid = sealed is not None and re.fullmatch(rb"[a-f0-9]{64}\n?", sealed) is not None
    emit("config_binding", current_sha256=digest(config),
         sealed_sha256=sealed.strip().decode("ascii") if valid else None,
         equal=digest(config) == sealed.strip().decode("ascii") if valid and config is not None else None,
         evidence_entries=count, truncated=truncated)


def firewall_report():
    for backend in ("iptables", "ip6tables"):
        for table in ("filter", "nat"):
            sealed, error = read_file(EVIDENCE / "firewall" / f"{backend}.{table}.raw")
            rc, live, query_error = command([backend, "-w", "3", "-t", table, "-S"])
            emit("firewall_program", backend=backend, table=table, command_rc=rc,
                 command_error=query_error, sealed_read_error=error,
                 live_sha256=digest(live), sealed_sha256=digest(sealed),
                 live_bytes=len(live) if live is not None else None,
                 equals_sealed=live == sealed if rc == 0 and live is not None and sealed is not None else None)
    for path in ("/etc/iptables/rules.v4", "/etc/iptables/rules.v6",
                 "/etc/sysconfig/iptables", "/etc/sysconfig/ip6tables"):
        file_report(path, "persistence_file")
    emit("persistence_note", comparison="not_performed",
         reason="firewall-snapshot-v2_records_live_S_programs_not_saved_file_copies")


def systemd_report():
    units = ["sing-box.service", "rr-nexus.service", "rr-subscription.service",
             "argo-rr-health.service", "argo-rr-health.timer",
             "rr-firewall-quarantine-guard.service", "rr-firewall-quarantine-guard.path",
             "rr-firewall-quarantine-guard.timer", "netfilter-persistent.service"]
    properties = ["Id", "LoadState", "ActiveState", "SubState", "UnitFileState",
                  "Result", "ExecMainStatus", "FragmentPath", "DropInPaths",
                  "ControlGroup", "MainPID", "ControlPID"]
    rc, data, error = command(["systemctl", "show", *units,
                               "--property=" + ",".join(properties), "--no-pager"])
    emit("systemd_query", command_rc=rc, error=error)
    if rc != 0 or data is None:
        return
    seen_paths = set()
    for block in data.decode("utf-8", "replace").split("\n\n"):
        values = {}
        for line in block.splitlines():
            key, sep, value = line.partition("=")
            if sep and key in properties:
                values[key] = value[:2048]
        if not values:
            continue
        emit("unit", **values)
        if values.get("Id", "").startswith("rr-firewall-quarantine-guard."):
            for path in [values.get("FragmentPath", ""), *values.get("DropInPaths", "").split()]:
                if path.startswith("/") and path not in seen_paths:
                    file_report(path, "guard_unit_file")
                    seen_paths.add(path)


def process_info(pid):
    base = Path("/proc") / str(pid)
    status, _ = read_file(base / "status", 65536)
    comm, _ = read_file(base / "comm", 256)
    wchan, _ = read_file(base / "wchan", 256)
    ppid = None
    if status:
        match = re.search(rb"(?m)^PPid:\s+([0-9]+)$", status)
        ppid = int(match[1]) if match else None
    try:
        executable = os.readlink(base / "exe")[:512]
    except OSError:
        executable = None
    return dict(pid=pid, ppid=ppid, comm=comm.decode("utf-8", "replace").strip() if comm else None,
                executable=executable, wchan=wchan.decode("ascii", "replace").strip() if wchan else None)


def lock_report():
    targets = {}
    for path in ("/run/rr-vps/locks/update.lock", "/run/rr-vps/locks/firewall.lock", "/run/lock/rr-update.lock"):
        info = metadata(path)
        emit("lock_file", path=path, **info)
        if info.get("kind") == "file":
            targets[(info["device"], info["inode"])] = path
    locks, read_error = read_file("/proc/locks", LIMIT)
    emit("kernel_locks_query", read_error=read_error)
    if locks is not None:
        for line in locks.decode("ascii", "replace").splitlines():
            fields = line.split()
            for index, field in enumerate(fields):
                match = re.fullmatch(r"([a-fA-F0-9]+):([a-fA-F0-9]+):([0-9]+)", field)
                if not match:
                    continue
                key = (os.makedev(int(match[1], 16), int(match[2], 16)), int(match[3]))
                if key in targets:
                    emit("kernel_lock", path=targets[key], record=" ".join(fields[:12]))
    deadline = time.monotonic() + 8
    checked = matched = 0
    truncated = False
    if targets:
        try:
            pids = sorted(int(name) for name in os.listdir("/proc") if name.isdecimal())
        except OSError:
            pids = []
            truncated = True
        for pid in pids:
            if time.monotonic() > deadline or checked >= 32768 or matched >= 64:
                truncated = True
                break
            try:
                with os.scandir(f"/proc/{pid}/fd") as descriptors:
                    for entry in descriptors:
                        if time.monotonic() > deadline or checked >= 32768 or matched >= 64:
                            truncated = True
                            break
                        checked += 1
                        try:
                            info = entry.stat(follow_symlinks=True)
                        except OSError:
                            continue
                        key = (info.st_dev, info.st_ino)
                        if key in targets:
                            emit("lock_descriptor", path=targets[key], fd=entry.name, **process_info(pid))
                            matched += 1
            except OSError:
                continue
    emit("lock_scan", descriptors_checked=checked, matches=matched, truncated=truncated,
         note="Open_descriptors_are_not_proof_of_lock_ownership;_snapshot_does_not_authorize_recovery")


def temporary_report():
    count = scanned = 0
    truncated = False
    deadline = time.monotonic() + 2
    try:
        with os.scandir("/tmp") as entries:
            for entry in entries:
                scanned += 1
                if scanned > 10000 or count >= 30 or time.monotonic() > deadline:
                    truncated = True
                    break
                if re.fullmatch(r"rr-firewall-batch\.[A-Za-z0-9]+", entry.name):
                    emit("firewall_batch_path", path=entry.path, **metadata(entry.path))
                    count += 1
    except OSError as error:
        emit("temporary_scan_error", error=type(error).__name__)
    emit("temporary_scan", matches=count, truncated=truncated)


def main():
    if len(sys.argv) != 1 or os.geteuid() != 0:
        emit("refused", reason="run_as_root_without_arguments")
        return 1
    emit("host", hostname=os.uname().nodename,
         utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
         diagnostic="read_only", recovery_authorized_by_output=False)
    version, _ = read_file(ROOT / "modules/00-runtime.sh")
    match = re.search(rb'(?m)^SCRIPT_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$', version or b"")
    emit("installed_version", version=match[1].decode("ascii") if match else None,
         source="module_text_only")
    files = [ROOT / "manifest.sha256", Path("/usr/local/bin/rr"),
             Path("/usr/local/sbin/rr-firewall-quarantine-guard"),
             Path("/usr/local/sbin/rr-update-recover")]
    files += [ROOT / "modules" / (name + ".sh") for name in
              ("00-runtime", "09-systemd", "10-system", "30-singbox", "55-resilience",
               "60-update", "61-update-guard", "70-protocols", "99-menus")]
    files += [Path(name) for name in ("/etc/argo_vmess.conf", "/etc/sing-box/config.json",
                                    "/etc/rr-nexus/nexus.json")]
    for path in files:
        file_report(path)
    marker_report()
    evidence_report()
    firewall_report()
    systemd_report()
    lock_report()
    temporary_report()
    emit("complete", changes_performed=False, locks_acquired=False,
         note="Live_observations_can_race;_this_is_not_a_recovery_preflight_or_safety_certificate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
