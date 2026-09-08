#!/usr/bin/env python3
"""Reversible private-CA TLS fixture for three disposable RR audit hosts.

This is an explicit lab fixture, not an ACME installation or renewal test.
The runner supplies only roles.json, ca.crt, leaf.crt, and leaf.key.  CA private
keys must remain on the runner.  No TLS or public-address validation is patched.
Prepare and restore print only fixed, non-secret status records.  Detailed
failure output and a SQLite recovery copy remain in a root-only backup folder.
The live database is never replaced: the API driver owns its object cleanup.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import re
import shutil
import socket
import sqlite3
import ssl
import stat
import subprocess
import sys
import tempfile
import time


EXPECTED = {"A": ("debian", "12"), "B": ("ubuntu", "22.04"),
            "C": ("ubuntu", "24.04")}
PRIMARY_HOSTS = {"DMIT-4AcBKDwTCc", "DMIT-8J8LiVPoNa"}
PRIMARY_IPS = {"154.17.22.91", "191.223.212.73"}
CONFIG = Path("/etc/rr-nexus/nexus.json")
RR_ROOT = Path("/usr/local/lib/rr")
HOSTS = Path("/etc/hosts")
UNITS = ("rr-nexus.service", "nginx.service", "sing-box.service",
         "argo-rr-health.timer")
PORT = 18443


class AuditError(RuntimeError):
    pass


def need(condition: bool, code: str) -> None:
    if not condition:
        raise AuditError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def regular(path: Path, private: bool = False) -> os.stat_result:
    info = path.lstat()
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == 0,
         "unsafe_file")
    need(info.st_mode & 0o022 == 0, "writable_file")
    if private:
        need(info.st_mode & 0o077 == 0, "nonprivate_file")
    return info


def owned_dir(path: Path, private: bool = False) -> None:
    info = path.lstat()
    need(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and
         info.st_mode & (0o077 if private else 0o022) == 0, "unsafe_directory")


def atomic(path: Path, data: bytes, mode: int = 0o600) -> None:
    owned_dir(path.parent)
    if path.exists() or path.is_symlink():
        regular(path)
    fd, name = tempfile.mkstemp(prefix=".rr-cross-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as output:
            os.fchmod(output.fileno(), mode)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, path)
        directory = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=True, sort_keys=True, indent=2) + "\n").encode()


class Fixture:
    def __init__(self, args: argparse.Namespace):
        self.role = args.role
        self.run_id = args.run_id
        need(re.fullmatch(r"[a-z0-9][a-z0-9-]{7,63}", self.run_id) is not None,
             "invalid_run_id")
        self.hostname = "rr-cross-{}.test".format(self.role.lower())
        self.backup = Path("/root/rr-cross-backup-{}-{}".format(self.run_id, self.role))
        self.state_path = self.backup / "state.json"
        self.tls_dir = Path("/etc/nginx/rr-cross-{}-{}".format(self.run_id, self.role))
        self.site = Path("/etc/nginx/conf.d/rr-cross-{}-{}.conf".format(self.run_id, self.role))
        self.ca = Path("/usr/local/share/ca-certificates/rr-cross-{}.crt".format(self.run_id))
        self.lab_lineage = Path("/etc/letsencrypt/live") / self.hostname
        self.driver_stage = Path("/root/rr-cross-stage-{}".format(self.run_id)) / self.role
        self.marker = "rr-cross-{}-{}".format(self.run_id, self.role)
        self.restore_unit = "rr-cross-restore-{}-{}".format(self.run_id, self.role.lower())
        self.state: dict = {}
        self.phase = "guard"
        self.fixture_dir = Path(args.fixture_dir) if getattr(args, "fixture_dir", None) else None

    def emit(self, phase: str, result: str, **details: object) -> None:
        payload = {"role": self.role, "run_id": self.run_id, "phase": phase,
                   "result": result, **details}
        print("CROSS_HOST " + json.dumps(payload, sort_keys=True), flush=True)

    def run(self, argv: list[str], *, check: bool = True,
            timeout: int = 30, env: dict | None = None) -> subprocess.CompletedProcess:
        clean_env = dict(os.environ)
        clean_env.update({"LC_ALL": "C", "SYSTEMD_PAGER": "cat",
                          "PYTHONDONTWRITEBYTECODE": "1"})
        if env:
            clean_env.update(env)
        completed = subprocess.run(argv, capture_output=True, timeout=timeout,
                                   env=clean_env, check=False)
        if completed.returncode and check:
            if self.backup.is_dir():
                log = self.backup / "failure.log"
                if log.exists():
                    regular(log, private=True)
                with log.open("ab") as output:
                    os.chmod(log, 0o600)
                    output.write((self.phase + " " + argv[0] + "\n").encode())
                    output.write(completed.stdout + completed.stderr + b"\n")
            raise AuditError("command_failed")
        return completed

    def guard(self) -> None:
        need(os.geteuid() == 0, "root_required")
        need(platform.node() not in PRIMARY_HOSTS, "primary_host_refused")
        release = {}
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                release[key] = value.strip('"')
        need((release.get("ID"), release.get("VERSION_ID")) == EXPECTED[self.role],
             "role_os_mismatch")
        for directory in (Path("/root"), CONFIG.parent, RR_ROOT):
            owned_dir(directory)
        local_addresses = json.loads(self.run(["ip", "-j", "-4", "address", "show"]).stdout)
        found = {entry.get("local") for interface in local_addresses
                 for entry in interface.get("addr_info", [])}
        need(not (found & PRIMARY_IPS), "primary_address_refused")

    def save(self) -> None:
        atomic(self.state_path, json_bytes(self.state))

    def service_states(self) -> dict:
        result = {}
        for unit in UNITS:
            raw = self.run(["systemctl", "show", unit, "--no-pager", "-p", "LoadState",
                            "-p", "ActiveState", "-p", "SubState", "-p", "UnitFileState"])
            result[unit] = dict(line.split("=", 1) for line in raw.stdout.decode().splitlines()
                                if "=" in line)
            need(result[unit].get("LoadState") == "loaded", "service_not_loaded")
            need(result[unit].get("ActiveState") in {"active", "inactive"},
                 "service_unstable")
        return result

    def manifest(self) -> str:
        path = RR_ROOT / "manifest.sha256"
        regular(path)
        raw = path.read_bytes()
        seen = set()
        for line in raw.decode().splitlines():
            match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./-]+)", line)
            need(match is not None, "manifest_format")
            expected, name = match.groups()
            need(name not in seen and not name.startswith("/") and
                 ".." not in Path(name).parts, "manifest_path")
            seen.add(name)
            # Installed rr is the stable launcher; the bundle's rr is the
            # standalone bootstrap.  Existing product audits make this same
            # documented distinction.
            if name == "rr":
                continue
            target = RR_ROOT / name
            regular(target)
            need(digest(target.read_bytes()) == expected, "runtime_manifest_mismatch")
        need("nexus/rr_nexus.py" in seen and "modules/85-nexus.sh" in seen,
             "manifest_incomplete")
        return digest(raw)

    def nginx_inventory(self) -> dict:
        result = {}
        for root in (Path("/etc/nginx/nginx.conf"), Path("/etc/nginx/conf.d"),
                     Path("/etc/nginx/sites-available"), Path("/etc/nginx/sites-enabled")):
            if not root.exists():
                continue
            entries = [root] if root.is_file() else sorted(root.rglob("*"))
            for entry in entries:
                if entry == self.site:
                    continue
                info = entry.lstat()
                if stat.S_ISLNK(info.st_mode):
                    result[str(entry)] = {"symlink": os.readlink(entry)}
                elif stat.S_ISREG(info.st_mode):
                    result[str(entry)] = {"sha256": digest(entry.read_bytes()),
                                          "mode": stat.S_IMODE(info.st_mode)}
        return result

    def health(self) -> None:
        self.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "10",
                  "http://127.0.0.1:7900/healthz"])

    def validate_candidate(self, path: Path) -> None:
        code = ("import sys; sys.path.insert(0, '/usr/local/lib/rr/nexus'); "
                "from rr_nexus import NexusConfig; NexusConfig.load()")
        self.run(["/usr/bin/python3", "-B", "-c", code],
                 env={"RR_NEXUS_CONFIG": str(path)})

    def publish_config(self, content: bytes) -> None:
        fd, name = tempfile.mkstemp(prefix=".rr-cross-config-", dir=str(CONFIG.parent))
        candidate = Path(name)
        try:
            with os.fdopen(fd, "wb") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            self.validate_candidate(candidate)
            code = ('for module in /usr/local/lib/rr/modules/*.sh; do source "$module" || exit; done\n'
                    'cross_publish() { nexus_publish_config_candidate "$1" /etc/rr-nexus/nexus.json; }\n'
                    'rr_menu_run_writer cross_publish "$1"\n')
            self.run(["bash", "-c", code, "rr-cross-config", str(candidate)], timeout=60)
            need(CONFIG.read_bytes() == content, "config_publish_mismatch")
        finally:
            candidate.unlink(missing_ok=True)

    def firewall_rules(self) -> list[list[str]]:
        return [["-p", "tcp", "-s", ip + "/32", "--dport", str(PORT),
                 "-m", "comment", "--comment", self.marker, "-j", "ACCEPT"]
                for ip in sorted(set(self.state["roles"].values()))]

    def check_fixture(self) -> tuple[dict, bytes, bytes, bytes]:
        need(self.fixture_dir is not None, "fixture_required")
        owned_dir(self.fixture_dir, private=True)
        need({p.name for p in self.fixture_dir.iterdir()} ==
             {"roles.json", "ca.crt", "leaf.crt", "leaf.key"}, "fixture_files_mismatch")
        for filename in ("roles.json", "ca.crt", "leaf.crt", "leaf.key"):
            regular(self.fixture_dir / filename, private=filename == "leaf.key")
        roles = json.loads((self.fixture_dir / "roles.json").read_bytes())
        need(isinstance(roles, dict) and set(roles) == set(EXPECTED), "roles_mismatch")
        for value in roles.values():
            address = ipaddress.ip_address(value)
            need(address.version == 4 and address.is_global and str(address) == value
                 and value not in PRIMARY_IPS, "role_address_refused")
        need(len(set(roles.values())) == 3, "duplicate_role_address")
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        ca_bytes = (self.fixture_dir / "ca.crt").read_bytes()
        leaf_bytes = (self.fixture_dir / "leaf.crt").read_bytes()
        key_bytes = (self.fixture_dir / "leaf.key").read_bytes()
        ca = x509.load_pem_x509_certificate(ca_bytes)
        leaf = x509.load_pem_x509_certificate(leaf_bytes)
        need(ca.extensions.get_extension_for_class(x509.BasicConstraints).value.ca,
             "ca_not_certificate_authority")
        need(not leaf.extensions.get_extension_for_class(x509.BasicConstraints).value.ca,
             "leaf_is_ca")
        names = leaf.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        need(list(names) == [x509.DNSName(self.hostname)], "leaf_san_mismatch")
        key = serialization.load_pem_private_key(key_bytes, password=None)
        public_options = (serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
        need(key.public_key().public_bytes(*public_options) ==
             leaf.public_key().public_bytes(*public_options), "leaf_key_mismatch")
        need(key.public_key().public_bytes(*public_options) !=
             ca.public_key().public_bytes(*public_options), "ca_private_key_refused")
        # Positive chain, purpose, hostname and validity checks, with no
        # unverified context and no CA installation until all checks pass.
        self.run(["openssl", "verify", "-CAfile", str(self.fixture_dir / "ca.crt"),
                  "-purpose", "sslserver", "-verify_hostname", self.hostname,
                  str(self.fixture_dir / "leaf.crt")])
        for filename in ("ca.crt", "leaf.crt"):
            self.run(["openssl", "x509", "-in", str(self.fixture_dir / filename),
                      "-noout", "-checkend", "86400"])
        return roles, ca_bytes, leaf_bytes, key_bytes

    def prepare(self) -> None:
        self.guard()
        self.phase = "preflight"
        need(not self.backup.exists() and not self.backup.is_symlink(), "backup_exists")
        for path in (self.site, self.tls_dir, self.ca, self.lab_lineage):
            need(not path.exists() and not path.is_symlink(), "fixture_path_exists")
        certificate_parents = [Path("/etc/letsencrypt"), Path("/etc/letsencrypt/live")]
        created_certificate_parents = []
        for directory in certificate_parents:
            if directory.exists() or directory.is_symlink():
                owned_dir(directory)
            else:
                created_certificate_parents.append(str(directory))
        for command in ("nginx", "openssl", "iptables", "update-ca-certificates", "curl", "systemd-run"):
            need(shutil.which(command) is not None, "missing_dependency")
        for directory in (self.site.parent, self.ca.parent):
            owned_dir(directory)
        listeners = self.run(["ss", "-H", "-lnt", "sport = :{}".format(PORT)])
        need(not listeners.stdout.strip(), "lab_port_in_use")
        cfg_info = regular(CONFIG, private=True)
        need(stat.S_IMODE(cfg_info.st_mode) == 0o600 and cfg_info.st_gid == 0,
             "config_metadata_mismatch")
        original = CONFIG.read_bytes()
        cfg = json.loads(original)
        need(cfg.get("mode") == "local" and cfg.get("listen") == "127.0.0.1"
             and cfg.get("port") == 7900, "unexpected_panel_baseline")
        roles, ca_bytes, leaf_bytes, key_bytes = self.check_fixture()
        for name in ("rr-cross-a.test", "rr-cross-b.test", "rr-cross-c.test"):
            need(not re.search(r"(?<![A-Za-z0-9_.-])" + re.escape(name) +
                               r"(?![A-Za-z0-9_.-])", HOSTS.read_text()), "host_mapping_exists")
        hosts_info = regular(HOSTS)
        self.run(["nginx", "-t"])
        self.health()
        baseline_manifest = self.manifest()
        units = self.service_states()
        need(units["rr-nexus.service"]["ActiveState"] == "active" and
             units["sing-box.service"]["ActiveState"] == "active", "baseline_service_inactive")
        self.backup.mkdir(mode=0o700)
        owned_dir(self.backup, private=True)
        atomic(self.backup / "nexus.json", original)
        atomic(self.backup / "hosts", HOSTS.read_bytes())
        atomic(self.backup / "manifest.sha256", (RR_ROOT / "manifest.sha256").read_bytes())
        self.state = {"schema": 1, "role": self.role, "run_id": self.run_id,
                      "hostname": platform.node(), "roles": roles, "services": units,
                      "original_config": json.loads(original), "manifest_sha256": baseline_manifest,
                      "hosts_mode": stat.S_IMODE(hosts_info.st_mode),
                      "hosts_uid": hosts_info.st_uid, "hosts_gid": hosts_info.st_gid,
                      "nginx_inventory": self.nginx_inventory(),
                      "trust_bundle_sha256": digest(Path("/etc/ssl/certs/ca-certificates.crt").read_bytes()),
                      "ca_sha256": digest(ca_bytes), "leaf_sha256": digest(leaf_bytes),
                      "key_sha256": digest(key_bytes), "phase": "backup", "restored": False,
                      "created_certificate_parents": created_certificate_parents}
        self.save()
        database = Path(cfg.get("database", "/var/lib/rr-nexus/nexus.db"))
        need(database == Path("/var/lib/rr-nexus/nexus.db"), "unexpected_database")
        regular(database, private=True)
        with sqlite3.connect("file:{}?mode=ro".format(database), uri=True, timeout=30) as source:
            with sqlite3.connect(str(self.backup / "nexus.db")) as destination:
                source.backup(destination)
                need(destination.execute("PRAGMA integrity_check").fetchone()[0] == "ok",
                     "backup_database_integrity")
        os.chmod(self.backup / "nexus.db", 0o600)
        self.emit("backup", "pass")

        # Arm recovery before the first host mutation, so cancellation or a
        # lost SSH connection cannot leave the lab endpoint/trust indefinitely.
        # Preserve this exact recovery implementation in the private backup.
        own_source = Path(__file__).resolve()
        regular(own_source)
        atomic(self.backup / "restore.py", own_source.read_bytes())
        self.run(["systemd-run", "--quiet", "--unit=" + self.restore_unit,
                  "--on-active=40min", "--timer-property=AccuracySec=1s",
                  "--property=Type=oneshot", "--property=TimeoutStartSec=900",
                  "/usr/bin/python3", str(self.backup / "restore.py"), "restore",
                  "--role", self.role, "--run-id", self.run_id])
        self.state["recovery_timer_armed"] = True
        self.save()
        self.emit("recovery_timer", "pass", deadline_minutes=40)

        self.phase = "prepare"
        self.state["phase"] = "mutating"
        self.save()
        self.run(["systemctl", "stop", "argo-rr-health.timer"], timeout=60)
        self.tls_dir.mkdir(mode=0o700)
        atomic(self.tls_dir / "leaf.crt", leaf_bytes)
        atomic(self.tls_dir / "leaf.key", key_bytes)
        # Product remote_cert_check reads DNS identity files from this fixed
        # location.  These are explicit lab validation inputs, with no Certbot
        # renewal/archive configuration and no claim of public ACME issuance.
        for name in created_certificate_parents:
            Path(name).mkdir(mode=0o700)
        self.lab_lineage.mkdir(mode=0o700)
        ownership = json_bytes({"fixture": "private_ca_lab_only", "run_id": self.run_id,
                                "role": self.role, "domain": self.hostname})
        self.state["lineage_marker_sha256"] = digest(ownership)
        self.save()
        atomic(self.lab_lineage / "RR-CROSS-LAB.json", ownership)
        atomic(self.lab_lineage / "fullchain.pem", leaf_bytes)
        atomic(self.lab_lineage / "privkey.pem", key_bytes)
        atomic(self.ca, ca_bytes, 0o644)
        self.run(["update-ca-certificates"], timeout=120)
        original_hosts = (self.backup / "hosts").read_bytes()
        block = ("\n# BEGIN " + self.marker + "\n" + "".join(
            "{} rr-cross-{}.test\n".format(roles[role], role.lower()) for role in "ABC")
            + "# END " + self.marker + "\n").encode()
        self.state["hosts_block"] = block.decode()
        self.save()
        atomic(HOSTS, original_hosts + block, self.state["hosts_mode"])
        os.chown(HOSTS, self.state["hosts_uid"], self.state["hosts_gid"])
        cfg.update({"mode": "public", "domain": self.hostname, "public_port": PORT})
        self.state["prepared_config"] = cfg
        self.save()
        self.publish_config(json_bytes(cfg))
        nginx = ("# Explicit temporary RR cross-OS lab TLS fixture; no ACME claim.\n"
                 "server {\n    listen 0.0.0.0:18443 ssl;\n"
                 "    server_name " + self.hostname + ";\n"
                 "    ssl_certificate " + str(self.tls_dir / "leaf.crt") + ";\n"
                 "    ssl_certificate_key " + str(self.tls_dir / "leaf.key") + ";\n"
                 "    ssl_protocols TLSv1.2 TLSv1.3;\n"
                 "    client_max_body_size 32k;\n    access_log off;\n"
                 "    error_log /dev/null crit;\n    allow 127.0.0.1;\n" +
                 "".join("    allow " + value + ";\n" for value in sorted(roles.values())) +
                 "    deny all;\n    location / {\n"
                 "        proxy_pass http://127.0.0.1:7900;\n"
                 "        proxy_http_version 1.1;\n"
                 "        proxy_set_header Host $host;\n"
                 "        proxy_set_header X-Real-IP $remote_addr;\n"
                 "        proxy_set_header X-Forwarded-For $remote_addr;\n"
                 "        proxy_set_header X-Forwarded-Proto https;\n"
                 "        proxy_connect_timeout 5s;\n        proxy_read_timeout 65s;\n"
                 "    }\n}\n").encode()
        self.state["site_sha256"] = digest(nginx)
        self.save()
        atomic(self.site, nginx, 0o644)
        self.run(["nginx", "-t"])
        for rule in self.firewall_rules():
            existing = self.run(["iptables", "-w", "5", "-C", "INPUT", *rule], check=False)
            need(existing.returncode == 1, "firewall_rule_conflict")
            self.run(["iptables", "-w", "5", "-I", "INPUT", "1", *rule])
        self.run(["systemctl", "restart", "rr-nexus.service"], timeout=60)
        if units["nginx.service"]["ActiveState"] == "active":
            self.run(["systemctl", "reload", "nginx.service"], timeout=60)
        else:
            self.run(["systemctl", "start", "nginx.service"], timeout=60)
        self.wait_health()
        self.run(["curl", "--noproxy", "*", "-fsS", "--max-time", "15", "--resolve",
                  "{}:{}:127.0.0.1".format(self.hostname, PORT),
                  "https://{}:{}/healthz".format(self.hostname, PORT)])
        # Check system trust in Python too: this is the trust implementation
        # used by the product's unmodified remote HTTPS transport.
        context = ssl.create_default_context()
        with socket.create_connection(("127.0.0.1", PORT), timeout=10) as raw:
            with context.wrap_socket(raw, server_hostname=self.hostname) as secured:
                need(bool(secured.getpeercert()), "python_tls_no_peer")
        self.run(["/usr/bin/python3", "-B", "-c",
                  "import sys; sys.path.insert(0, '/usr/local/lib/rr/nexus'); "
                  "from rr_nexus import NexusConfig, remote_cert_check; "
                  "ok, reason = remote_cert_check(NexusConfig.load()); "
                  "raise SystemExit(0 if ok else 1)"], timeout=30)
        self.emit("remote_certificate_gate", "pass")
        for role, expected_ip in roles.items():
            found = {record[4][0] for record in socket.getaddrinfo(
                "rr-cross-{}.test".format(role.lower()), PORT, type=socket.SOCK_STREAM)}
            need(found == {expected_ip}, "role_resolution_mismatch")
        need(self.manifest() == baseline_manifest, "prepare_changed_runtime")
        self.state["phase"] = "prepared"
        self.save()
        self.emit("prepare", "pass", port=PORT, tls_verified=True,
                  database_replaced=False, certificate_fixture="private_ca")

    def wait_health(self) -> None:
        for _ in range(20):
            try:
                self.health()
                return
            except AuditError:
                time.sleep(0.5)
        raise AuditError("health_not_ready")

    def restore(self) -> None:
        self.guard()
        self.phase = "restore"
        owned_dir(self.backup, private=True)
        regular(self.state_path, private=True)
        self.state = json.loads(self.state_path.read_bytes())
        need(self.state.get("schema") == 1 and self.state.get("role") == self.role
             and self.state.get("run_id") == self.run_id
             and self.state.get("hostname") == platform.node(), "backup_identity_mismatch")
        failures = []

        def step(name, operation):
            try:
                operation()
            except Exception as exc:
                code = str(exc) if isinstance(exc, AuditError) else type(exc).__name__
                failures.append(name + ":" + code)
                self.emit("restore_" + name, "fail", code=code)

        def remove_firewall():
            for rule in self.firewall_rules():
                checked = self.run(["iptables", "-w", "5", "-C", "INPUT", *rule], check=False)
                if checked.returncode == 0:
                    self.run(["iptables", "-w", "5", "-D", "INPUT", *rule])
                else:
                    need(checked.returncode == 1, "firewall_check_failed")
                checked = self.run(["iptables", "-w", "5", "-C", "INPUT", *rule], check=False)
                need(checked.returncode == 1, "firewall_rule_remains")

        def cleanup_driver_objects():
            if self.state.get("driver_objects_cleaned"):
                return
            stage = self.driver_stage
            required = (stage / "audit-cross-management.py", stage / "peers.json",
                        stage / "baseline.json")
            if not (stage / "baseline.json").exists():
                # issue() captures its baseline before its first API write.
                # A fixture whose driver never reached issue has no objects.
                return
            owned_dir(stage.parent)
            owned_dir(stage, private=True)
            for path in required:
                regular(path, private=path.name != "audit-cross-management.py")
            peers = json.loads((stage / "peers.json").read_bytes())
            need(peers.get("run") == self.run_id, "driver_run_mismatch")
            self.run(["/usr/bin/python3", str(required[0]), "cleanup", self.role, str(stage)],
                     timeout=240)
            self.state["driver_objects_cleaned"] = True
            self.save()

        def remove_site():
            if self.site.exists() or self.site.is_symlink():
                regular(self.site)
                need(digest(self.site.read_bytes()) == self.state.get("site_sha256"),
                     "site_changed_externally")
                self.site.unlink()
            self.run(["nginx", "-t"])
            if self.run(["systemctl", "is-active", "--quiet", "nginx.service"], check=False).returncode == 0:
                self.run(["systemctl", "reload", "nginx.service"], timeout=60)

        def restore_config():
            original = (self.backup / "nexus.json").read_bytes()
            current = json.loads(CONFIG.read_bytes())
            need(current in (self.state["original_config"], self.state.get("prepared_config")),
                 "config_changed_externally")
            if CONFIG.read_bytes() != original:
                self.publish_config(original)
                self.run(["systemctl", "restart", "rr-nexus.service"], timeout=60)
            need(CONFIG.read_bytes() == original, "config_not_restored")

        def restore_hosts():
            original = (self.backup / "hosts").read_bytes()
            current = HOSTS.read_bytes()
            block = self.state.get("hosts_block", "").encode()
            if current != original:
                need(bool(block) and current.count(block) == 1, "hosts_marker_changed")
                clean = current.replace(block, b"", 1)
                atomic(HOSTS, clean, self.state["hosts_mode"])
                os.chown(HOSTS, self.state["hosts_uid"], self.state["hosts_gid"])
            need(HOSTS.read_bytes() == original, "hosts_other_changes_preserved")

        def remove_trust():
            if self.ca.exists() or self.ca.is_symlink():
                regular(self.ca)
                need(digest(self.ca.read_bytes()) == self.state["ca_sha256"], "ca_changed_externally")
                self.ca.unlink()
                self.run(["update-ca-certificates"], timeout=120)
            need(digest(Path("/etc/ssl/certs/ca-certificates.crt").read_bytes()) ==
                 self.state["trust_bundle_sha256"], "trust_bundle_not_restored")

        def remove_tls():
            if self.tls_dir.exists() or self.tls_dir.is_symlink():
                owned_dir(self.tls_dir, private=True)
                need({p.name for p in self.tls_dir.iterdir()} <= {"leaf.crt", "leaf.key"},
                     "tls_directory_changed")
                for filename, field in (("leaf.crt", "leaf_sha256"), ("leaf.key", "key_sha256")):
                    path = self.tls_dir / filename
                    if path.exists() or path.is_symlink():
                        regular(path, private=True)
                        need(digest(path.read_bytes()) == self.state[field], "tls_file_changed")
                        path.unlink()
                self.tls_dir.rmdir()

        def remove_lab_lineage():
            if self.lab_lineage.exists() or self.lab_lineage.is_symlink():
                owned_dir(self.lab_lineage, private=True)
                expected = {"fullchain.pem": self.state["leaf_sha256"],
                            "privkey.pem": self.state["key_sha256"],
                            "RR-CROSS-LAB.json": self.state.get("lineage_marker_sha256")}
                need({p.name for p in self.lab_lineage.iterdir()} <= set(expected),
                     "lab_lineage_changed")
                for name, expected_digest in expected.items():
                    path = self.lab_lineage / name
                    if path.exists() or path.is_symlink():
                        regular(path, private=True)
                        need(digest(path.read_bytes()) == expected_digest,
                             "lab_lineage_file_changed")
                        path.unlink()
                self.lab_lineage.rmdir()
            for name in reversed(self.state.get("created_certificate_parents", [])):
                directory = Path(name)
                need(directory in (Path("/etc/letsencrypt"), Path("/etc/letsencrypt/live")),
                     "invalid_lab_parent")
                if directory.exists() or directory.is_symlink():
                    owned_dir(directory, private=True)
                    need(not list(directory.iterdir()), "lab_parent_other_changes_preserved")
                    directory.rmdir()

        def restore_services():
            for unit, original in self.state["services"].items():
                current = self.service_states()[unit]
                need(current["UnitFileState"] == original["UnitFileState"],
                     "service_enable_state_changed")
                if current["ActiveState"] != original["ActiveState"]:
                    action = "start" if original["ActiveState"] == "active" else "stop"
                    self.run(["systemctl", action, unit], timeout=60)
            now = self.service_states()
            for unit, original in self.state["services"].items():
                need(now[unit]["ActiveState"] == original["ActiveState"] and
                     now[unit]["UnitFileState"] == original["UnitFileState"],
                     "service_state_not_restored")

        def sync_original_subscriptions():
            need(CONFIG.read_bytes() == (self.backup / "nexus.json").read_bytes(),
                 "subscription_sync_requires_restored_config")
            for attempt in range(3):
                completed = self.run(["/usr/local/bin/rr", "--sync-devices"],
                                     timeout=330, check=False,
                                     env={"RR_NEXUS_SYNC_LOCK_WAIT_SECONDS": "5"})
                if completed.returncode == 0:
                    break
                need(completed.returncode == 75 and attempt < 2, "subscription_sync_failed")
                time.sleep(1)
            for root in (Path("/var/lib/rr-nexus/subscriptions"), Path("/tmp/sub_server/nexus")):
                if root.exists():
                    for path in root.rglob("*"):
                        if path.is_file():
                            need(not re.search(rb"rr-cross-[abc]\.test", path.read_bytes()),
                                 "lab_subscription_reference_remains")
            need(CONFIG.read_bytes() == (self.backup / "nexus.json").read_bytes(),
                 "config_changed_during_subscription_sync")

        # Keep TLS/config/hosts live while the product API revokes this run's
        # keys and deletes only its own objects, including watchdog recovery.
        step("driver_objects", cleanup_driver_objects)
        step("firewall", remove_firewall)
        step("site", remove_site)
        step("config", restore_config)
        step("hosts", restore_hosts)
        step("trust", remove_trust)
        step("tls", remove_tls)
        step("lab_lineage", remove_lab_lineage)
        step("subscriptions", sync_original_subscriptions)
        step("services", restore_services)
        step("nginx_inventory", lambda: need(self.nginx_inventory() == self.state["nginx_inventory"],
                                             "nginx_other_changes_detected"))
        step("health", self.wait_health)
        current_manifest = ""
        try:
            current_manifest = self.manifest()
        except Exception as exc:
            failures.append("manifest:" + (str(exc) if isinstance(exc, AuditError) else type(exc).__name__))
        self.state["restore_failures"] = failures
        self.state["restored"] = not failures
        self.state["phase"] = "restored" if not failures else "restore_failed"
        self.save()
        need(not failures, "restore_incomplete")
        # Stopping only our timer is safe even when its service is currently
        # running this restore.  Never stop the executing restore service.
        if self.state.get("recovery_timer_armed"):
            loaded = self.run(["systemctl", "show", self.restore_unit + ".timer",
                               "-p", "LoadState", "--value"], check=False)
            if loaded.stdout.strip() == b"loaded":
                self.run(["systemctl", "stop", self.restore_unit + ".timer"], timeout=30)
        self.emit("restore", "pass", configuration_restored=True,
                  services_restored=True, tls_fixture_removed=True,
                  database_replaced=False, runtime_manifest_verified=True,
                  runtime_changed=current_manifest != self.state["manifest_sha256"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "restore"))
    parser.add_argument("--role", required=True, choices=tuple(EXPECTED))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--fixture-dir")
    args = parser.parse_args()
    os.umask(0o077)
    fixture = None
    try:
        fixture = Fixture(args)
        need(os.geteuid() == 0, "root_required")
        lock_path = Path("/run/rr-cross-host.lock")
        if not lock_path.exists() and not lock_path.is_symlink():
            fd = os.open(str(lock_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            os.close(fd)
        regular(lock_path, private=True)
        with lock_path.open("r+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if args.action == "prepare":
                fixture.prepare()
            else:
                fixture.restore()
        return 0
    except Exception as exc:
        code = str(exc) if isinstance(exc, AuditError) else type(exc).__name__
        if fixture is None:
            print("CROSS_HOST " + json.dumps({"phase": "arguments", "result": "fail", "code": code}))
        else:
            fixture.emit(fixture.phase, "fail", code=code)
            # Restore is intentionally an explicit runner always() operation.
            # Do not discard the live database or conceal the original failure.
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
