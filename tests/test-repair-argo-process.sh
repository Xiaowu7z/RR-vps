#!/usr/bin/env bash
set -euo pipefail
[ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'ERROR: root required' >&2; exit 1; }
command -v cc >/dev/null || { echo 'ERROR: C compiler required for process fixture' >&2; exit 1; }
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixture=$(mktemp -d /root/rr-test-argo-process.XXXXXX)
trap 'rm -rf -- "$fixture"' EXIT
umask 077

# A tiny local stand-in accepts the production argv but opens no network socket.
# The production validator uses real /proc metadata, process start time, binary
# inode and pidfd signal delivery. Only binary location and cgroup attribution
# are adjusted for this container fixture; no host services are controlled.
cat >"$fixture/cloudflared.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    char line[256];
    long proc_pid = 0;
    FILE *status = fopen("/proc/self/status", "r");
    if (!status) return 2;
    while (fgets(line, sizeof(line), status)) {
        if (!strncmp(line, "Pid:", 4)) {
            proc_pid = strtol(line + 4, NULL, 10);
            break;
        }
    }
    fclose(status);
    if (proc_pid <= 0) return 3;
    if (getenv("RR_TEST_IGNORE_TERM")) signal(SIGTERM, SIG_IGN);
    printf("READY %ld\n", proc_pid);
    fflush(stdout);
    for (;;) pause();
}
C
cc -O2 -Wall -Wextra -Werror "$fixture/cloudflared.c" -o "$fixture/cloudflared"
chmod 755 "$fixture/cloudflared"

python3 - "$repo/scripts/repair-v723-naive-first-install.sh" "$fixture" <<'PY'
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys

source = Path(sys.argv[1]).read_text()
root = Path(sys.argv[2])
start = source.index('repair_argo_process() {')
begin = source.index("<<'PY'\n", start) + len("<<'PY'\n")
end = source.index('\nPY\n', begin)
program = source[begin:end]
assert "BINARY = Path('/usr/bin/cloudflared')" in program
program = program.replace("BINARY = Path('/usr/bin/cloudflared')",
                          f'BINARY = Path({str(root / "cloudflared")!r})')
# Some command sandboxes expose translated getpid()/pidfd APIs with an outer
# /proc view. Map only this fixture's own children to their self-reported /proc
# PID in that environment. Their live status, argv, start time and exe inode
# remain real; signal delivery still uses the genuine child pidfd.
self_proc_pid = int(next(line.split()[1] for line in
                        Path('/proc/self/status').read_text().splitlines()
                        if line.startswith('Pid:')))
translated_proc = self_proc_pid != os.getpid()
proc_map = root / 'proc'
if translated_proc:
    proc_map.mkdir(mode=0o700)
    assert "PROC_ROOT = Path('/proc')" in program
    program = program.replace("PROC_ROOT = Path('/proc')",
                              f'PROC_ROOT = Path({str(proc_map)!r})')
# This test runner is not itself an SSH login. Preserve process fingerprinting
# and pidfd operations while making just the cgroup membership policy explicit.
program, count = re.subn(r'(?ms)^def cgroup_owned\(data\):\n.*?(?=^def |\Z)',
                        'def cgroup_owned(data):\n    return True\n\n', program)
assert count == 1
runner = root / 'process-check.py'
runner.write_text(program)
os.chmod(runner, 0o600)
binary = root / 'cloudflared'
snapshot = root / 'argo-process-before.json'
pidfile = root / 'argo.pid'
logfile = root / 'argo.log'
linked_target = root / 'linked-target'
log_sentinel = 'RR_PRIVATE_LOG_CONTENT_MUST_NOT_APPEAR_IN_DIAGNOSTICS'
port = '30677'
processes = []
cases = 0

def launch(origin=port, ignore_term=False):
    env = dict(os.environ)
    if ignore_term:
        env['RR_TEST_IGNORE_TERM'] = '1'
    else:
        env.pop('RR_TEST_IGNORE_TERM', None)
    process = subprocess.Popen(
        ['cloudflared', 'tunnel', '--url', f'http://127.0.0.1:{origin}',
         '--edge-ip-version', 'auto', '--protocol', 'http2'],
        executable=str(binary), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        env=env)
    processes.append(process)
    ready = process.stdout.readline().split()
    assert len(ready) == 2 and ready[0] == b'READY'
    if translated_proc:
        mapping = proc_map / str(process.pid)
        mapping.unlink(missing_ok=True)
        mapping.symlink_to(Path('/proc') / ready[1].decode())
    return process

def cleanup():
    for process in processes:
        if process.poll() is None:
            # Fixture teardown only. Production stop is checked separately and
            # must leave a TERM-ignoring process alive after its bounded wait.
            process.kill()
        process.wait(timeout=3)
        if process.stdout:
            process.stdout.close()
    processes.clear()
    for path in (snapshot, pidfile, logfile, linked_target):
        path.unlink(missing_ok=True)

def check(action, pids, success):
    result = subprocess.run([sys.executable, str(runner), action, str(snapshot),
                             port, str(pidfile), str(logfile),
                             '\n'.join(str(x) for x in pids)],
                            capture_output=True, text=True, timeout=9)
    if (result.returncode == 0) != success:
        raise AssertionError(f'{action} expected success={success}: '
                             f'rc={result.returncode} {result.stdout} {result.stderr}')
    assert log_sentinel not in result.stdout + result.stderr
    return result

def runtime_files(process, pid_mode=0o600, log_mode=0o600):
    pidfile.write_text(str(process.pid) + '\n')
    logfile.write_text(log_sentinel + '\n')
    os.chmod(pidfile, pid_mode)
    os.chmod(logfile, log_mode)

def file_state(path):
    metadata = path.lstat()
    # Reads may change atime. All ownership, permission, identity and write
    # timestamps must remain unchanged; no repair-time chmod is permitted.
    return (path.read_bytes(), metadata.st_uid, metadata.st_gid,
            stat.S_IMODE(metadata.st_mode), metadata.st_dev, metadata.st_ino,
            metadata.st_nlink, metadata.st_size,
            metadata.st_mtime_ns, metadata.st_ctime_ns)

def metadata_rejection(result, path):
    actual = path.lstat()
    reports = [json.loads(line) for line in result.stdout.splitlines()]
    matches = [row for row in reports if row.get('path') == str(path)]
    assert matches, result.stdout
    assert any(row.get('mode') == oct(stat.S_IMODE(actual.st_mode)) and
               row.get('uid') == actual.st_uid and
               row.get('gid') == actual.st_gid and
               row.get('links') == actual.st_nlink for row in matches), result.stdout

def passed(name):
    global cases
    cases += 1
    print(f'ARGO_PROCESS_CASE name={name} result=PASS')
    cleanup()

try:
    check('inspect', [], True)
    check('stop', [], True)
    passed('no_candidate')

    pidfile.write_text('12345\n')
    os.chmod(pidfile, 0o600)
    before = pidfile.read_bytes()
    check('inspect', [], True)
    assert json.loads(snapshot.read_text())['pid'] is None
    check('stop', [], True)
    assert pidfile.read_bytes() == before
    passed('stale_pid_file_without_candidate_is_preserved')

    process = launch()
    check('inspect', [process.pid], True)
    check('stop', [process.pid], True)
    assert process.wait(timeout=2) == -signal.SIGTERM
    passed('exact_origin_real_pidfd_sigterm')

    process = launch()
    runtime_files(process, 0o644, 0o644)
    before = {path: file_state(path) for path in (pidfile, logfile)}
    check('inspect', [process.pid], True)
    check('stop', [process.pid], True)
    assert process.wait(timeout=2) == -signal.SIGTERM
    assert before == {path: file_state(path) for path in before}
    passed('legacy_644_pid_log_real_pidfd_preserves_files')

    process = launch()
    runtime_files(process, 0o640, 0o440)
    before = {path: file_state(path) for path in (pidfile, logfile)}
    check('inspect', [process.pid], True)
    check('stop', [process.pid], True)
    assert process.wait(timeout=2) == -signal.SIGTERM
    assert before == {path: file_state(path) for path in before}
    passed('readable_640_pid_440_log_preserves_files')

    for unsafe, mode in ((pidfile, 0o620), (logfile, 0o602)):
        process = launch()
        runtime_files(process)
        os.chmod(unsafe, mode)
        before = {path: file_state(path) for path in (pidfile, logfile)}
        result = check('inspect', [process.pid], False)
        metadata_rejection(result, unsafe)
        assert process.poll() is None
        assert before == {path: file_state(path) for path in before}
        role = 'pid_file' if unsafe == pidfile else 'log_file'
        passed(f'writable_{role}_rejected_without_signal')

    for link_kind in ('symlink', 'hardlink'):
        for unsafe in (pidfile, logfile):
            process = launch()
            runtime_files(process)
            unsafe.rename(linked_target)
            if link_kind == 'symlink':
                unsafe.symlink_to(linked_target)
            else:
                os.link(linked_target, unsafe)
            before = file_state(linked_target)
            result = check('inspect', [process.pid], False)
            metadata_rejection(result, unsafe)
            assert process.poll() is None
            assert file_state(linked_target) == before
            cleanup()
        passed(f'{link_kind}_pid_and_log_rejected_without_signal')

    process = launch()
    runtime_files(process)
    check('inspect', [process.pid], True)
    os.chmod(snapshot, 0o644)
    before = {path: file_state(path) for path in (snapshot, pidfile, logfile)}
    result = check('stop', [process.pid], False)
    metadata_rejection(result, snapshot)
    assert process.poll() is None
    assert before == {path: file_state(path) for path in before}
    passed('fingerprint_record_644_still_rejected_without_signal')

    process = launch(origin=port + '1')
    check('inspect', [process.pid], False)
    assert process.poll() is None
    passed('origin_port_prefix_rejected_without_signal')

    first, second = launch(), launch()
    check('inspect', [first.pid, second.pid], False)
    assert first.poll() is None and second.poll() is None
    passed('multiple_candidates_rejected_without_signal')

    process = launch()
    pidfile.write_text(str(process.pid + 1) + '\n')
    os.chmod(pidfile, 0o600)
    check('inspect', [process.pid], False)
    assert process.poll() is None
    passed('wrong_pid_file_rejected_without_signal')

    process = launch()
    check('inspect', [process.pid], True)
    saved = json.loads(snapshot.read_text())
    assert 'starttime' in saved['fingerprint']
    saved['fingerprint']['starttime'] += 1
    snapshot.write_text(json.dumps(saved))
    os.chmod(snapshot, 0o600)
    check('stop', [process.pid], False)
    assert process.poll() is None
    passed('changed_start_time_simulates_reused_pid_without_signal')

    process = launch()
    pidfile.write_text(str(process.pid) + '\n')
    os.chmod(pidfile, 0o600)
    check('inspect', [process.pid], True)
    pidfile.write_text(str(process.pid + 1) + '\n')
    check('stop', [process.pid], False)
    assert process.poll() is None
    passed('pid_file_changed_before_stop_rejected_without_signal')

    process = launch()
    check('inspect', [process.pid], True)
    process.terminate()
    process.wait(timeout=2)
    check('stop', [], True)
    passed('already_exited_process')

    process = launch(ignore_term=True)
    check('inspect', [process.pid], True)
    check('stop', [process.pid], False)
    assert process.poll() is None
    passed('term_timeout_without_kill_escalation')
finally:
    cleanup()

print(f'REPAIR_ARGO_PROCESS_PASS cases={cases} proc=real uid=real '
      'start_time=real binary_inode=real pidfd=real '
      'binary=fixture cgroup_policy=fixture '
      f'proc_namespace_map={str(translated_proc).lower()} '
      'cloudflared_service=false network_access=false')
PY
