#!/usr/bin/env python3
"""Orchestrate owner-authorized tests on three pinned disposable VPS hosts."""
import concurrent.futures
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket
import subprocess
import sys
import tempfile

ROLES = ("A", "B", "C")
KEYS = {
    "A": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmpYE2GN+xGyCxDQW1e/NrwzmApHDMz+zLigsrhXhRm",
    "B": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJWJw40hog64SpnWDcp4mvlSJIZ1qspCoOhNrn0L/B5A",
    "C": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPNn4M3kE0+DoV//4xOYwweoLnTrwS+bJmmD6pK4ios3",
}
DENIED = {"154.17.22.91", "191.223.212.73"}
ROOT = Path(__file__).resolve().parents[1]


class AuditFailure(Exception):
    def __init__(self, code, output=b""):
        super().__init__(code)
        self.output = output


def report(phase, role="-", result="pass"):
    print(f"CROSS_AUDIT phase={phase} role={role} result={result}", flush=True)


def command(args, *, timeout=120, env=None, input=None):
    result = subprocess.run(args, input=input, capture_output=True, timeout=timeout, env=env)
    if result.returncode:
        # Remote logs and credential-bearing responses never go into Actions logs.
        raise AuditFailure(f"command_exit_{result.returncode}", result.stdout)
    return result.stdout


def private_json(path, data):
    path.write_text(json.dumps(data))
    path.chmod(0o600)


class Runner:
    def __init__(self):
        run_number = os.environ.get("GITHUB_RUN_ID", "")
        if not re.fullmatch(r"[0-9]{1,16}", run_number):
            raise AuditFailure("invalid_run_id")
        self.run = "cross-" + run_number
        self.local = Path(tempfile.mkdtemp(prefix=self.run + "-", dir=os.environ["RUNNER_TEMP"]))
        self.local.chmod(0o700)
        self.hosts, self.passwords, self.addresses, self.options = {}, {}, {}, {}
        self.prepared = set()
        self.uploaded = set()
        self.driver_ready = set()
        self.nginx_added = set()
        for role in ROLES:
            host = os.environ.get(f"RR_{role}_HOST", "")
            password = os.environ.get(f"RR_{role}_PASS", "")
            if not host or not password or any(c.isspace() for c in host) or host.startswith("-"):
                raise AuditFailure("missing_or_invalid_test_host")
            addresses = {row[4][0] for row in socket.getaddrinfo(host, 22, socket.AF_INET, socket.SOCK_STREAM)}
            if len(addresses) != 1:
                raise AuditFailure("ambiguous_test_host_ipv4")
            address = next(iter(addresses))
            if address in DENIED or not ipaddress.ip_address(address).is_global:
                raise AuditFailure("primary_or_nonpublic_host_refused")
            if address in self.addresses.values():
                raise AuditFailure("duplicate_test_host")
            self.hosts[role], self.passwords[role], self.addresses[role] = host, password, address
            known = self.local / f"known-{role}"
            known.write_text(f"{host} {KEYS[role]}\n")
            known.chmod(0o600)
            self.options[role] = [
                "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", f"UserKnownHostsFile={known}", "-o", "HostKeyAlgorithms=ssh-ed25519",
                "-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no",
                "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=20",
                "-o", "ServerAliveCountMax=6", "-o", "LogLevel=ERROR",
            ]

    def env(self, role):
        result = os.environ.copy()
        result["SSHPASS"] = self.passwords[role]
        return result

    def stage(self, role):
        return f"/root/rr-cross-stage-{self.run}/{role}"

    def fixture(self, role):
        return f"/root/rr-cross-input-{self.run}/{role}"

    def ssh(self, role, args, *, timeout=180, input=None):
        remote = shlex.join(args)
        return command(["sshpass", "-e", "ssh", *self.options[role],
                        f"root@{self.hosts[role]}", remote],
                       timeout=timeout, env=self.env(role), input=input)

    def upload(self, role, paths, target):
        command(["sshpass", "-e", "scp", *self.options[role], "-q",
                 *(str(p) for p in paths), f"root@{self.hosts[role]}:{target}/"],
                timeout=120, env=self.env(role))

    def read_json(self, role, name):
        raw = self.ssh(role, ["cat", f"{self.stage(role)}/{name}"])
        return json.loads(raw)

    def driver(self, role, action):
        error = None
        try:
            output = self.ssh(role, ["python3", f"{self.stage(role)}/audit-cross-management.py",
                                     action, role, self.stage(role)], timeout=1100)
        except AuditFailure as exc:
            error, output = exc, exc.output
        # Only structured audit markers are allowed out of the private transport.
        for line in output.decode("utf-8", "replace").splitlines():
            if re.fullmatch(r"CROSS_[A-Z_]+ [A-Za-z0-9_=.:, /-]{1,400}", line):
                print(line, flush=True)
        if error is not None:
            raise error
        report(action, role)

    def host_action(self, role, action):
        args = ["python3", f"{self.stage(role)}/audit-cross-host.py", action,
                "--role", role, "--run-id", self.run]
        if action == "prepare":
            args += ["--fixture-dir", self.fixture(role)]
        error = None
        try:
            output = self.ssh(role, args, timeout=960 if action == "restore" else 240)
        except AuditFailure as exc:
            error, output = exc, exc.output
        for line in output.decode("utf-8", "replace").splitlines():
            if not line.startswith("CROSS_HOST "):
                continue
            try:
                data = json.loads(line.removeprefix("CROSS_HOST "))
            except ValueError:
                continue
            safe = {key: value for key, value in data.items()
                    if key in {"role", "phase", "result", "code"}
                    and isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,100}", value)}
            print("CROSS_HOST " + json.dumps(safe, sort_keys=True), flush=True)
        if error is not None:
            raise error

    def generate_certificates(self):
        ca = self.local / "ca"
        ca.mkdir(mode=0o700)
        command(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                 "-keyout", str(ca / "ca.key"), "-out", str(ca / "ca.crt"),
                 "-days", "31", "-subj", "/CN=RR cross OS disposable test CA",
                 "-addext", "basicConstraints=critical,CA:TRUE",
                 "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        (ca / "ca.key").chmod(0o600)
        for index, role in enumerate(ROLES, 1):
            fixture = self.local / role
            fixture.mkdir(mode=0o700)
            domain = f"rr-cross-{role.lower()}.test"
            private_json(fixture / "roles.json", self.addresses)
            (fixture / "ca.crt").write_bytes((ca / "ca.crt").read_bytes())
            ext = ca / f"{role}.ext"
            ext.write_text(f"basicConstraints=critical,CA:FALSE\n"
                           f"keyUsage=critical,digitalSignature,keyEncipherment\n"
                           f"extendedKeyUsage=serverAuth\nsubjectAltName=DNS:{domain}\n")
            command(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes",
                     "-keyout", str(fixture / "leaf.key"), "-out", str(ca / f"{role}.csr"),
                     "-subj", f"/CN={domain}"])
            (fixture / "leaf.key").chmod(0o600)
            command(["openssl", "x509", "-req", "-in", str(ca / f"{role}.csr"),
                     "-CA", str(ca / "ca.crt"), "-CAkey", str(ca / "ca.key"),
                     "-set_serial", str(index), "-out", str(fixture / "leaf.crt"),
                     "-days", "30", "-sha256", "-extfile", str(ext)])
            command(["openssl", "verify", "-CAfile", str(fixture / "ca.crt"),
                     "-verify_hostname", domain, "-purpose", "sslserver",
                     str(fixture / "leaf.crt")])
        report("test_ca_generated")

    def prepare(self, role):
        stage = self.stage(role)
        fixture = self.fixture(role)
        # Confirm host identity and OS before any mutation on that host.
        inventory = self.ssh(role, ["python3", "-", role],
                             input=(ROOT / "scripts/audit-cross-inventory.py").read_bytes())
        if not inventory.startswith(b"CROSS_INVENTORY "):
            raise AuditFailure("invalid_inventory")
        state = json.loads(inventory.removeprefix(b"CROSS_INVENTORY "))
        if state["rr"] != "RR-vps 7.2.2" or not state["health"] or not state["credential_fixture"]:
            raise AuditFailure("test_host_not_ready")
        self.ssh(role, ["install", "-d", "-m", "700", stage, fixture])
        self.uploaded.add(role)
        paths = [ROOT / "rr-bundle.tar.gz", ROOT / "scripts/install-core.sh",
                 ROOT / "scripts/update-guard.sh", ROOT / "scripts/audit-cross-host.py",
                 ROOT / "scripts/audit-cross-management.py"]
        checksum = self.local / f"transfer-{role}.sha256"
        checksum.write_text("".join(hashlib.sha256(path.read_bytes()).hexdigest()
                                   + "  " + path.name + "\n" for path in paths))
        self.upload(role, paths + [checksum], stage)
        install_script = (
            "set -euo pipefail\numask 077\ncd " + shlex.quote(stage) + "\n"
            "sha256sum -c " + shlex.quote(checksum.name) + " >/dev/null\n"
            "RR_BUNDLE_FILE=" + shlex.quote(stage + "/rr-bundle.tar.gz") + " "
            "RR_GUARD_FILE=" + shlex.quote(stage + "/update-guard.sh") + " "
            "timeout --kill-after=15 600 bash ./install-core.sh --upgrade </dev/null "
            ">install.log 2>&1\n"
            "(cd /usr/local/lib/rr; awk '$2 != \"rr\"' manifest.sha256 | sha256sum -c - >/dev/null)\n"
        )
        self.ssh(role, ["bash", "-s"], input=install_script.encode(), timeout=660)
        report("candidate_transaction_installed", role)
        if not state["nginx_installed"]:
            self.nginx_added.add(role)
            self.ssh(role, ["bash", "-c",
                           "set -euo pipefail; "
                           "test \"$(systemctl show nginx.service -p LoadState --value)\" = not-found; "
                           "systemctl mask nginx.service >/dev/null 2>&1; "
                           "trap 'systemctl unmask nginx.service >/dev/null 2>&1; "
                           "systemctl disable --now nginx.service >/dev/null 2>&1 || true' EXIT; "
                           "DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; "
                           "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx >/dev/null 2>&1"],
                     timeout=360)
            report("nginx_test_dependency_installed", role)
        self.upload(role, list((self.local / role).iterdir()), fixture)
        # Track before entry: restore also handles a partially prepared fixture.
        self.prepared.add(role)
        self.host_action(role, "prepare")
        report("tls_fixture_prepared", role)

    def parallel(self, action):
        failures = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
            futures = {pool.submit(self.driver, role, action): role for role in ROLES}
            for future in concurrent.futures.as_completed(futures):
                try:
                    future.result()
                except Exception:
                    failures.append(futures[future])
        if failures:
            raise AuditFailure(action + "_failed_roles_" + "".join(sorted(failures)))

    def execute(self):
        self.generate_certificates()
        for role in ROLES:
            self.prepare(role)
        peers = {"run": self.run, "peers": {
            role: {"domain": f"rr-cross-{role.lower()}.test", "port": 18443} for role in ROLES}}
        peers_path = self.local / "peers.json"
        private_json(peers_path, peers)
        for role in ROLES:
            self.upload(role, [peers_path], self.stage(role))
            self.driver_ready.add(role)
        self.parallel("issue")
        for role in ROLES:
            credential = self.read_json(role, "credential.json")
            baseline = self.read_json(role, "baseline.json")
            peers["peers"][role].update({
                "cred": credential["cred"], "baseline": baseline,
                "hostname": credential["hostname"],
            })
        private_json(peers_path, peers)
        for role in ROLES:
            self.upload(role, [peers_path], self.stage(role))
        for role in ROLES:
            self.driver(role, "exercise")
        self.parallel("verify-local")
        self.parallel("revoke")
        self.parallel("verify-revoked")
        report("six_directions_completed")

    def cleanup(self):
        failures = []
        for role in ROLES:
            if role not in self.driver_ready:
                continue
            try:
                # Local cleanup stays usable after remote keys have been revoked.
                self.driver(role, "cleanup")
            except Exception:
                failures.append(role + "_objects")
                report("cleanup", role, "failed_private_stage_retained")
        for role in ROLES:
            if role not in self.prepared:
                continue
            try:
                self.host_action(role, "restore")
                report("fixture_restored", role)
            except Exception:
                failures.append(role + "_restore")
                report("fixture_restored", role, "failed_private_backup_retained")
        # Dependency cleanup also runs when prepare never reached its backup.
        for role in sorted(self.nginx_added):
            try:
                self.ssh(role, ["bash", "-c",
                               "if [ \"$(systemctl show nginx.service -p LoadState --value)\" != not-found ]; "
                               "then systemctl disable --now nginx.service; fi"])
                report("nginx_dependency_deactivated", role)
            except Exception:
                failures.append(role + "_nginx")
        if failures:
            raise AuditFailure("cleanup_failed_" + "_".join(failures))


def main():
    os.umask(0o077)
    runner = Runner()
    def interrupted(signum, frame):
        raise AuditFailure("runner_interrupted")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    failed = False
    try:
        runner.execute()
    except Exception as exc:
        failed = True
        code = str(exc) if isinstance(exc, AuditFailure) else type(exc).__name__
        report("execution", result=re.sub(r"[^A-Za-z0-9_-]", "_", code)[:100])
    finally:
        try:
            runner.cleanup()
        except Exception:
            failed = True
            report("final_cleanup", result="failed")
    report("complete", result="fail" if failed else "pass")
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
