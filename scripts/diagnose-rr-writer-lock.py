#!/usr/bin/env python3
"""Read RR lock metadata and open descriptors; never acquire or alter a lock."""
import json
import os
import re
import stat
import sys
from pathlib import Path


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=True))


def inspect_locks(paths):
    targets = {}
    for path in paths:
        try:
            info = path.lstat()
        except FileNotFoundError:
            emit("lock_absent", path=str(path))
            continue
        except OSError as error:
            emit("read_error", path=str(path), errno=error.errno)
            continue
        emit("lock_file", path=str(path), uid=info.st_uid, gid=info.st_gid,
             mode=oct(stat.S_IMODE(info.st_mode)), links=info.st_nlink,
             regular=stat.S_ISREG(info.st_mode), inode=info.st_ino,
             device=f"{os.major(info.st_dev):x}:{os.minor(info.st_dev):x}")
        if stat.S_ISREG(info.st_mode):
            targets[(info.st_dev, info.st_ino)] = str(path)

    try:
        records = Path('/proc/locks').read_text().splitlines()
    except OSError as error:
        emit("read_error", path='/proc/locks', errno=error.errno)
        records = []
    for record in records:
        for word in record.split():
            match = re.fullmatch(r'([0-9a-fA-F]+):([0-9a-fA-F]+):([0-9]+)', word)
            if not match:
                continue
            key = (os.makedev(int(match[1], 16), int(match[2], 16)), int(match[3]))
            if key in targets:
                emit("kernel_lock", path=targets[key], record=record)

    descriptors = 0
    for process in Path('/proc').iterdir():
        if not process.name.isdigit():
            continue
        try:
            fds = list((process / 'fd').iterdir())
        except OSError:
            continue
        for fd in fds:
            try:
                info = fd.stat()
                path = targets.get((info.st_dev, info.st_ino))
                if path is None:
                    continue
                status = dict(line.split(':', 1) for line in
                              (process / 'status').read_text().splitlines() if ':' in line)
                fdinfo = (process / 'fdinfo' / fd.name).read_text().splitlines()
                groups = (process / 'cgroup').read_text().splitlines()
                current = fd.stat()
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
                    continue
                emit("open_descriptor", path=path, pid=int(process.name),
                     ppid=status.get('PPid', '').strip(), name=status.get('Name', '').strip(),
                     state=status.get('State', '').strip(), fd=fd.name,
                     fd_locks=[line for line in fdinfo if line.startswith('lock:')],
                     cgroup=groups)
                descriptors += 1
            except (OSError, ValueError):
                continue  # A process may exit while its descriptors are scanned.
    emit("scan_complete", descriptors=descriptors,
         note="Open descriptors alone do not prove lock ownership; this is a live snapshot.")


def main():
    if len(sys.argv) > 2:
        raise SystemExit('Usage: diagnose-rr-writer-lock.py [repair_log_directory]')
    emit("host", hostname=os.uname().nodename)
    inspect_locks([Path('/run/rr-vps/locks/update.lock'), Path('/run/lock/rr-update.lock')])
    marker = Path('/run/rr-vps/legacy-update-bridge')
    emit("legacy_bridge", present=os.path.lexists(marker), symlink=marker.is_symlink())
    if len(sys.argv) == 2:
        directory = Path(sys.argv[1])
        if not re.fullmatch(r'/root/rr-repair-naive723\.[A-Za-z0-9]+', str(directory)):
            raise SystemExit('Unexpected repair log directory')
        logfile = directory / 'repair.log'
        try:
            for entry in (directory, logfile):
                info = entry.lstat()
                if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
                    raise ValueError('Unsafe repair log path')
            if not logfile.is_file() or logfile.stat().st_size > 1024 * 1024:
                raise ValueError('Unexpected repair log file')
            for line in logfile.read_text(errors='replace').splitlines():
                if line.startswith('flock:') or '[忙碌]' in line or '[安全拒绝]' in line:
                    emit("lock_message", text=line)
        except (OSError, ValueError) as error:
            emit("log_unavailable", reason=type(error).__name__)


if __name__ == '__main__':
    main()
