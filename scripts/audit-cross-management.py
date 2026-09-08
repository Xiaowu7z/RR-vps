#!/usr/bin/env python3
"""Real API cross-management acceptance on three disposable audit hosts only.

No product imports, patches, TLS bypass, SSH, or embedded credentials. The SSH
runner provides a private STAGE/peers.json and the normal panel-login fixture.
All management writes use public panel APIs. SQLite/config reads independently
verify preserved identities and that deferred changes reached the node config.
"""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import socket
import sqlite3
import ssl
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


EXPECTED = {"A": ("debian", "12"), "B": ("ubuntu", "22.04"), "C": ("ubuntu", "24.04")}
PRIMARY_HOSTS = {"DMIT-4AcBKDwTCc", "DMIT-8J8LiVPoNa"}
PRIMARY_IPS = {"154.17.22.91", "191.223.212.73"}
DEVICE_FIELDS = ("id", "name", "enabled", "quota_bytes", "expires_at", "group_id",
                 "next_reset_at", "reset_anchor_day", "reset_max", "reset_count")
INFO_FIELDS = ("script_version", "core_version", "panel_state", "panel_mode",
               "entry_ip_mode", "outbound_ip_mode")
PNG = b"\x89PNG\r\n\x1a\n"


class CheckFailed(Exception):
    """Only a fixed, non-sensitive failure code may escape to stdout."""


def require(condition, code):
    if not condition:
        raise CheckFailed(code)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def save_private(path, value):
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Driver:
    def __init__(self, role, stage, command):
        self.role = role
        self.stage = Path(stage)
        self.command = command
        self.phase = "preflight"
        self.pair = role
        self.cases = 0
        require(role in EXPECTED, "invalid_role")
        require(os.geteuid() == 0, "requires_root_audit_host")
        require(platform.node() not in PRIMARY_HOSTS, "primary_host_refused")
        require(self.stage.is_absolute() and str(self.stage).startswith("/root/"), "unsafe_stage")
        require(self.stage.is_dir() and not self.stage.is_symlink(), "unsafe_stage")
        require(self.stage.resolve() == self.stage, "unsafe_stage")
        stage_stat = self.stage.stat()
        require(stage_stat.st_uid == 0 and stat.S_IMODE(stage_stat.st_mode) == 0o700, "stage_not_private")
        config_path = self.stage / "peers.json"
        require(not config_path.is_symlink(), "unsafe_peer_file")
        require(stat.S_IMODE(config_path.stat().st_mode) == 0o600, "peers_not_private")
        self.config = json.loads(config_path.read_text())
        self.run = self.config.get("run", "")
        require(re.fullmatch(r"[a-z0-9-]{1,24}", self.run), "invalid_run")
        self.prefix = "cross-" + self.run + "-"
        self.peers = self.config.get("peers", {})
        require(set(self.peers) == set(EXPECTED), "invalid_peers")
        osrel = {}
        for line in Path("/etc/os-release").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                osrel[key] = value.strip('"')
        require((osrel.get("ID"), osrel.get("VERSION_ID")) == EXPECTED[role], "wrong_host_os")
        for peer_role, peer in self.peers.items():
            require(peer.get("domain") == "rr-cross-{}.test".format(peer_role.lower()), "unexpected_domain")
            require(peer.get("port") == 18443, "unexpected_tls_port")
            require(peer.get("hostname") not in PRIMARY_HOSTS, "primary_peer_refused")
            # Verify that even an accidentally misconfigured hosts fixture can
            # never route this audit to one of the two primary machines.
            addresses = {item[4][0] for item in socket.getaddrinfo(peer["domain"], 18443)}
            require(addresses and not addresses.intersection(PRIMARY_IPS), "primary_address_refused")
        own = self.peers[role]
        require(not own.get("hostname") or own["hostname"] == platform.node(), "wrong_hostname")
        self.panel_config = json.loads(Path("/etc/rr-nexus/nexus.json").read_text())
        require(self.panel_config.get("port") == 7900, "unexpected_local_port")
        require(self.panel_config.get("domain") == own["domain"], "wrong_panel_domain")
        require(self.panel_config.get("public_port") == 18443, "wrong_panel_tls_port")
        self.db_path = Path(self.panel_config.get("database", "/var/lib/rr-nexus/nexus.db"))
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), NoRedirect(),
            urllib.request.HTTPSHandler(context=ssl.create_default_context()))
        self.token = ""
        self.csrf = ""
        self.password = ""

    def passed(self, phase, count=1):
        self.cases += count
        print("CROSS_CASE role={} pair={} phase={} result=pass".format(self.role, self.pair, phase), flush=True)

    def request(self, url, method="GET", body=None, headers=None, read_only=False, raw=False):
        data = None if body is None else json.dumps(body, separators=(",", ":")).encode()
        request_headers = {"User-Agent": "rr-cross-audit/1", "Accept": "application/json"}
        if data is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        attempts = 3 if read_only else 1
        for attempt in range(attempts):
            request = urllib.request.Request(url, data=data, method=method, headers=request_headers)
            try:
                try:
                    response = self.opener.open(request, timeout=105 if not read_only else 30)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    status = response.code
                    content = response.read(2 * 1024 * 1024 + 1)
                require(len(content) <= 2 * 1024 * 1024, "response_too_large")
                if raw:
                    return status, content
                try:
                    value = json.loads(content)
                except (UnicodeDecodeError, json.JSONDecodeError):
                    raise CheckFailed("non_json_api_response") from None
                require(isinstance(value, dict), "invalid_api_response")
                if read_only and status in (429, 502, 503, 504) and attempt + 1 < attempts:
                    time.sleep(2)
                    continue
                return status, value
            except (urllib.error.URLError, TimeoutError, OSError):
                if not read_only or attempt + 1 == attempts:
                    raise CheckFailed("read_transport_failed" if read_only else "write_transport_unknown") from None
                time.sleep(2)
        raise CheckFailed("request_exhausted")

    def local(self, method, path, body=None, read_only=None, headers=None, raw=False):
        auth = {}
        if self.token:
            auth = {"Authorization": "Bearer " + self.token, "X-CSRF-Token": self.csrf}
        auth.update(headers or {})
        return self.request("http://127.0.0.1:7900" + path, method, body, auth,
                            method == "GET" if read_only is None else read_only, raw)

    def ok(self, result, expected=(200,)):
        status, value = result
        code = value.get("error", "") if isinstance(value, dict) else ""
        if status not in expected or code:
            suffix = code if isinstance(code, str) and re.fullmatch(r"[a-z_]{1,60}", code) else "unexpected"
            raise CheckFailed("http_{}_{}".format(status, suffix))
        return value

    def login(self):
        self.phase = "login"
        credentials = Path("/root/rr-stability-panel-credentials")
        require(not credentials.is_symlink(), "unsafe_login_fixture")
        require(stat.S_IMODE(credentials.stat().st_mode) == 0o600, "login_fixture_not_private")
        lines = credentials.read_text().splitlines()
        require(len(lines) == 2 and all(lines), "invalid_login_fixture")
        self.password = lines[1]
        response = self.ok(self.local("POST", "/api/login", {"username": lines[0], "password": self.password}))
        self.token, self.csrf = response["token"], response["csrf"]

    def step_up(self, purpose):
        value = self.ok(self.local("POST", "/api/auth/step-up", {"purpose": purpose, "password": self.password}))
        require(isinstance(value.get("ticket"), str) and value["ticket"], "missing_step_up_ticket")
        return {"X-Step-Up-Token": value["ticket"]}

    def direct(self, target, method, path, body=None):
        if target == self.role:
            return self.local(method, path, body)
        peer = self.peers[target]
        return self.request("https://{}:{}/api/remote/call".format(peer["domain"], peer["port"]), "POST",
                            {"cred": peer["cred"], "method": method, "path": path, "body": body or {}},
                            read_only=method == "GET")

    def proxy(self, server_id, method, path, body=None):
        return self.local("POST", "/api/remote/proxy",
                          {"server_id": server_id, "method": method, "path": path, "body": body or {}},
                          read_only=method == "GET")

    def get_devices(self, target):
        return self.ok(self.direct(target, "GET", "/api/devices"))["devices"]

    @staticmethod
    def device_identity(row):
        return {key: row.get(key) for key in DEVICE_FIELDS}

    @staticmethod
    def links_identity(value):
        return digest({key: value.get(key) for key in ("id", "links", "subscription_url", "subscription_urls")})

    def db_identities(self):
        with sqlite3.connect("file:{}?mode=ro".format(self.db_path), uri=True, timeout=5) as db:
            db.row_factory = sqlite3.Row
            rows = db.execute("SELECT id,name,credential,subscription_token FROM devices ORDER BY id").fetchall()
        return {row["id"]: {"name": row["name"], "identity_sha256": digest([row["credential"], row["subscription_token"]])}
                for row in rows}

    def remote_identities(self):
        with sqlite3.connect("file:{}?mode=ro".format(self.db_path), uri=True, timeout=5) as db:
            rows = db.execute("SELECT id,name,addr,port,cred FROM remote_servers ORDER BY id").fetchall()
        return {str(row[0]): digest(list(row[1:])) for row in rows}

    def issue(self):
        self.phase = "baseline"
        require(not (self.stage / "baseline.json").exists(), "baseline_already_exists")
        stats = self.ok(self.local("GET", "/api/server/stats"))
        info = self.ok(self.local("GET", "/api/server/info"))
        require(info.get("script_version") == "7.2.2", "unexpected_rr_version")
        require(stats.get("hostname") == platform.node(), "local_stats_wrong_host")
        devices = self.get_devices(self.role)
        groups = self.ok(self.local("GET", "/api/device-groups"))["groups"]
        templates = self.ok(self.local("GET", "/api/device-templates"))["templates"]
        servers = self.ok(self.local("GET", "/api/remote-servers"))["servers"]
        require(not any(str(row.get("name", "")).startswith(self.prefix)
                        for collection in (devices, groups, templates, servers) for row in collection),
                "run_prefix_already_present")
        links = {}
        for device in devices:
            status, value = self.local("GET", "/api/devices/{}/links".format(device["id"]))
            if status == 200:
                links[device["id"]] = self.links_identity(value)
            else:
                require(status == 404 and value.get("error") == "links_not_found", "baseline_links_error")
        with sqlite3.connect("file:{}?mode=ro".format(self.db_path), uri=True, timeout=5) as db:
            audit_after = db.execute("SELECT COALESCE(MAX(id),0) FROM audit_log").fetchone()[0]
        baseline = {"role": self.role, "hostname": platform.node(), "os": stats.get("os"),
                    "info": {key: info.get(key) for key in INFO_FIELDS},
                    "devices": {d["id"]: self.device_identity(d) for d in devices},
                    "links": links, "identities": self.db_identities(),
                    "remote_identities": self.remote_identities(), "audit_after": audit_after,
                    "groups": groups, "templates": templates}
        save_private(self.stage / "baseline.json", baseline)
        self.phase = "issue"
        response = self.ok(self.local("POST", "/api/remote/issue", {"name": self.prefix + self.role},
                                      headers=self.step_up("remote_issue")))
        require(str(response.get("cred", "")).startswith("rrmgr1."), "missing_remote_credential")
        save_private(self.stage / "credential.json", {"role": self.role, "hostname": platform.node(),
                                                       "cred": response["cred"], "fingerprint": response["fingerprint"]})
        self.passed("issue_and_baseline")

    def check_originals(self, target, check_links=True):
        baseline = self.peers[target]["baseline"]
        current = {d["id"]: self.device_identity(d) for d in self.get_devices(target)}
        require(all(current.get(key) == value for key, value in baseline["devices"].items()), "original_device_changed")
        if check_links:
            for key, value in baseline["links"].items():
                result = self.ok(self.direct(target, "GET", "/api/devices/{}/links".format(key)))
                require(self.links_identity(result) == value, "original_subscription_changed")

    def check_isolation(self, target, pair_prefix):
        for peer_role in EXPECTED:
            rows = self.get_devices(peer_role)
            if peer_role != target:
                require(not any(row["name"].startswith(pair_prefix) for row in rows), "cross_host_device_leak")
            self.check_originals(peer_role, check_links=False)

    def wait_links(self, server_id, device_id):
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            status, value = self.proxy(server_id, "GET", "/api/devices/{}/links".format(device_id))
            if status == 200 and value.get("links") and value.get("subscription_url"):
                return value
            require(status == 404 and value.get("error") == "links_not_found" or
                    status == 200 and not value.get("error"), "deferred_links_failed")
            time.sleep(3)
        raise CheckFailed("deferred_links_timeout")

    def subscription(self, target, device_id, url):
        peer = self.peers[target]
        parts = urllib.parse.urlsplit(url)
        require(parts.scheme == "https" and parts.hostname == peer["domain"] and parts.port == peer["port"],
                "subscription_wrong_origin")
        require(not parts.username and not parts.password and not parts.query and not parts.fragment,
                "subscription_unsafe_url")
        require(re.fullmatch(r"/sub/" + re.escape(device_id) + r"/[A-Za-z0-9_-]+/[A-Za-z0-9-]+", parts.path),
                "subscription_wrong_device")
        return self.request(url, read_only=True, raw=True)

    def validate_subscription(self, target, device_id, value):
        urls = value.get("subscription_urls")
        require(isinstance(urls, list) and urls, "missing_subscription_formats")
        require(value.get("id") == device_id, "links_wrong_device")
        status, content = self.subscription(target, device_id, value["subscription_url"])
        require(status == 200 and content, "subscription_empty")
        # Check every advertised format, including real JSON/YAML/URI response
        # bodies. No token or content is written to the audit log.
        for entry in urls:
            status, body = self.subscription(target, device_id, entry["url"])
            require(status == 200 and body, "subscription_format_failed")
            if urllib.parse.urlsplit(entry["url"]).path.endswith("/json"):
                try:
                    parsed = json.loads(body)
                except (ValueError, UnicodeDecodeError):
                    raise CheckFailed("subscription_invalid_json") from None
                require(isinstance(parsed, dict) and parsed.get("outbounds"), "subscription_missing_outbounds")

    def exercise(self):
        for target in EXPECTED:
            if target == self.role:
                continue
            self.exercise_pair(target)
        self.phase = "originals_after_exercise"
        for target in EXPECTED:
            self.check_originals(target)
        self.passed("all_original_identities_preserved")

    def exercise_pair(self, target):
        self.pair = self.role + target
        prefix = self.prefix + self.pair + "-"
        peer = self.peers[target]
        baseline = peer["baseline"]
        self.phase = "remote_add"
        response = self.ok(self.local("POST", "/api/remote-servers", {"name": prefix + "server", "cred": peer["cred"]}))
        require(response.get("verified") is True, "server_not_verified")
        servers = self.ok(self.local("GET", "/api/remote-servers"))["servers"]
        matching = [s for s in servers if s.get("name") == prefix + "server"]
        require(len(matching) == 1, "added_server_missing")
        server_id = matching[0]["id"]
        status, value = self.local("POST", "/api/remote-servers", {"name": prefix + "duplicate", "cred": peer["cred"]})
        require(status == 409 and value.get("error") == "already_exists" and value.get("server_id") == server_id,
                "duplicate_server_not_rejected")
        self.ok(self.local("PATCH", "/api/remote-servers/{}".format(server_id), {"name": prefix + "renamed"}))
        listed = self.ok(self.local("GET", "/api/remote-servers"))["servers"]
        require(any(s["id"] == server_id and s["name"] == prefix + "renamed" for s in listed), "server_rename_failed")
        self.passed("add_duplicate_rename", 3)

        self.phase = "remote_read_routes"
        for path, required in (
            ("/api/overview", ("devices", "services", "domain")),
            ("/api/devices", ("devices", "traffic")),
            ("/api/server/stats", ("hostname", "os", "cpu", "memory")),
            ("/api/server/info", ("script_version", "panel_mode")),
            ("/api/traffic", ("totals", "samples", "status")),
            ("/api/metrics", ("samples", "range", "bucket_seconds")),
            ("/api/server/traffic-policy", ("policy",)),
        ):
            value = self.ok(self.proxy(server_id, "GET", path))
            direct = self.ok(self.direct(target, "GET", path))
            require(all(key in value and key in direct for key in required), "read_schema_mismatch")
            if path == "/api/overview":
                require(value["domain"] == direct["domain"] == peer["domain"], "overview_wrong_target")
                require(value["services"].get("sing-box") == "active", "target_node_inactive")
            if path == "/api/server/stats":
                require(value["hostname"] == direct["hostname"] == baseline["hostname"], "stats_wrong_hostname")
                require(value["os"] == direct["os"] == baseline["os"], "stats_wrong_os")
            if path == "/api/server/info":
                require({key: value.get(key) for key in INFO_FIELDS} == baseline["info"], "info_wrong_target")
            if path == "/api/devices":
                self.check_originals(target)
        summary = self.ok(self.local("POST", "/api/remote-servers/status", {}, read_only=True))["servers"]
        row = next((s for s in summary if s["id"] == server_id), {})
        require(row.get("online") is True and row.get("state") == "online" and row.get("ver") == "7.2.2",
                "server_aggregate_not_online")
        self.passed("read_routes_and_target_identity", 8)

        self.phase = "remote_objects"
        group = self.ok(self.proxy(server_id, "POST", "/api/device-groups", {"name": prefix + "group", "color": "#123abc"}), (201,))
        template = self.ok(self.proxy(server_id, "POST", "/api/device-templates",
                                     {"name": prefix + "template", "quota_gb": 2, "expiry_days": 7, "enabled": True}), (201,))
        group_id, template_id = group["id"], template["id"]
        self.ok(self.proxy(server_id, "PATCH", "/api/device-groups/{}".format(group_id),
                           {"name": prefix + "group-renamed", "color": "#abc123"}))
        self.ok(self.proxy(server_id, "PATCH", "/api/device-templates/{}".format(template_id),
                           {"name": prefix + "template-renamed", "quota_gb": 3}))
        groups = self.ok(self.direct(target, "GET", "/api/device-groups"))["groups"]
        templates = self.ok(self.direct(target, "GET", "/api/device-templates"))["templates"]
        require(any(g["id"] == group_id and g["name"] == prefix + "group-renamed" and g["color"] == "#abc123" for g in groups), "group_rename_failed")
        require(any(t["id"] == template_id and t["name"] == prefix + "template-renamed" and t["quota_bytes"] == 3 * 1024**3 for t in templates), "template_rename_failed")
        first = self.ok(self.proxy(server_id, "POST", "/api/devices",
                                  {"name": prefix + "device1", "template_id": template_id, "group_id": group_id}), (201,))["id"]
        second = self.ok(self.proxy(server_id, "POST", "/api/devices",
                                   {"name": prefix + "device2", "quota_gb": 1}), (201,))["id"]
        require(re.fullmatch(r"dev_[a-f0-9]{12}", first) and re.fullmatch(r"dev_[a-f0-9]{12}", second), "invalid_created_id")
        rows = {d["id"]: d for d in self.get_devices(target)}
        require(rows[first]["quota_bytes"] == 3 * 1024**3 and rows[first]["group_id"] == group_id and rows[first]["enabled"],
                "device_template_not_applied")
        self.passed("group_template_device_create", 6)

        self.phase = "remote_subscriptions"
        original_links = self.wait_links(server_id, first)
        direct_links = self.ok(self.direct(target, "GET", "/api/devices/{}/links".format(first)))
        require(self.links_identity(original_links) == self.links_identity(direct_links), "proxy_links_mismatch")
        self.validate_subscription(target, first, original_links)
        for query in ({"index": "0"}, {"sub": "1"}, {"sub_index": "1"}):
            qr = self.ok(self.proxy(server_id, "GET", "/api/devices/{}/qr".format(first), query))
            try:
                png = base64.b64decode(qr.get("png_b64", ""), validate=True)
            except ValueError:
                raise CheckFailed("invalid_qr_base64") from None
            require(png.startswith(PNG) and len(png) > 100, "invalid_remote_qr")
            suffix = urllib.parse.urlencode({"server_id": server_id, "device_id": first, **query})
            status, forwarded = self.local("GET", "/api/remote/qr?" + suffix, raw=True)
            require(status == 200 and forwarded == png, "qr_proxy_bytes_mismatch")
        self.passed("subscriptions_and_qr", 7)

        self.phase = "remote_device_mutations"
        renamed = self.ok(self.proxy(server_id, "PATCH", "/api/devices/" + first, {"name": prefix + "device1-renamed"}))
        require(renamed.get("sync") == "not_required", "rename_triggered_node_sync")
        after_links = self.ok(self.proxy(server_id, "GET", "/api/devices/{}/links".format(first)))
        require(self.links_identity(after_links) == self.links_identity(original_links), "rename_changed_credentials_or_links")
        for enabled in (False, True):
            self.ok(self.proxy(server_id, "PATCH", "/api/devices/" + first, {"enabled": enabled}))
            row = next(d for d in self.get_devices(target) if d["id"] == first)
            require(row["enabled"] is enabled, "device_enabled_mismatch")
            deadline = time.monotonic() + (180 if enabled else 1)
            while True:
                status, body = self.subscription(target, first, original_links["subscription_url"])
                if status == 200 and bool(body) is enabled:
                    break
                require(enabled and time.monotonic() < deadline and status in (200, 404),
                        "subscription_enable_state_mismatch")
                time.sleep(3)
        for action, extra in (("disable", {}), ("enable", {}), ("move_group", {"group_id": group_id}),
                              ("apply_template", {"template_id": template_id})):
            batch = self.ok(self.proxy(server_id, "POST", "/api/devices/batch",
                                      {"action": action, "device_ids": [first, second], **extra}))
            require(batch.get("changed") == 2, "batch_wrong_changed_count")
            rows = {d["id"]: d for d in self.get_devices(target)}
            if action in ("disable", "enable"):
                require(all(rows[key]["enabled"] == (action == "enable") for key in (first, second)), "batch_enabled_mismatch")
            elif action == "move_group":
                require(all(rows[key]["group_id"] == group_id for key in (first, second)), "batch_group_mismatch")
            else:
                require(all(rows[key]["quota_bytes"] == 3 * 1024**3 and rows[key]["enabled"] for key in (first, second)),
                        "batch_template_mismatch")
        self.check_isolation(target, prefix)
        self.passed("device_rename_toggle_batch_isolation", 8)

        self.phase = "remote_delete"
        third = self.ok(self.proxy(server_id, "POST", "/api/devices",
                                  {"name": prefix + "device3-delete", "quota_gb": 1}), (201,))["id"]
        self.wait_links(server_id, third)
        self.ok(self.proxy(server_id, "DELETE", "/api/devices/" + third, {}))
        require(not any(d["id"] == third for d in self.get_devices(target)), "device_delete_failed")
        self.ok(self.proxy(server_id, "PATCH", "/api/devices/" + second, {"enabled": False}))
        require(next(d for d in self.get_devices(target) if d["id"] == second)["enabled"] is False,
                "final_disabled_device_mismatch")
        # Keep one enabled and one disabled device until all roles independently
        # verify both inclusion and exclusion in the real node configuration.
        self.ok(self.proxy(server_id, "DELETE", "/api/device-groups/{}".format(group_id), {}))
        self.ok(self.proxy(server_id, "DELETE", "/api/device-templates/{}".format(template_id), {}))
        require(not any(g["id"] == group_id for g in self.ok(self.direct(target, "GET", "/api/device-groups"))["groups"]), "group_delete_failed")
        require(not any(t["id"] == template_id for t in self.ok(self.direct(target, "GET", "/api/device-templates"))["templates"]), "template_delete_failed")
        require(next(d for d in self.get_devices(target) if d["id"] == first)["group_id"] is None, "deleted_group_not_detached")
        self.check_isolation(target, prefix)
        self.passed("device_group_template_delete", 5)

    def verify_local(self):
        self.phase = "local_deferred_sync"
        baseline = json.loads((self.stage / "baseline.json").read_text())
        current = self.db_identities()
        require(all(current.get(key) == value for key, value in baseline["identities"].items()), "original_database_identity_changed")
        deadline = time.monotonic() + 180
        stable_since = None
        while time.monotonic() < deadline:
            today = datetime.now(timezone.utc).date().isoformat()
            with sqlite3.connect("file:{}?mode=ro".format(self.db_path), uri=True, timeout=5) as db:
                failed = db.execute("SELECT COUNT(*) FROM audit_log WHERE id>? AND "
                                    "(action LIKE '%_sync_failed' OR action LIKE '%_sync_error')",
                                    (baseline["audit_after"],)).fetchone()[0]
                require(failed == 0, "deferred_sync_failure_recorded")
                active = dict(db.execute("SELECT id,credential FROM devices WHERE enabled=1 "
                                         "AND (expires_at IS NULL OR expires_at='' OR expires_at>=?) "
                                         "AND (quota_bytes=0 OR used_bytes<quota_bytes)", (today,)).fetchall())
            config = json.loads(Path("/etc/sing-box/config.json").read_text())
            inbounds = [i for i in config.get("inbounds", []) if i.get("type") in {"vmess", "vless", "hysteria2", "tuic", "anytls"}]
            require(inbounds, "no_test_node_inbounds")
            synchronized = True
            for inbound in inbounds:
                actual = {u["name"]: u.get("uuid", u.get("password")) for u in inbound.get("users", []) if u.get("name", "").startswith("dev_")}
                synchronized = synchronized and actual == active
            inflight = False
            for proc in Path("/proc").iterdir():
                if not proc.name.isdigit():
                    continue
                try:
                    args = (proc / "cmdline").read_bytes().split(b"\0")
                except (FileNotFoundError, ProcessLookupError):
                    continue
                if b"--sync-devices" in args:
                    inflight = True
                    break
            service = subprocess.run(
                ["systemctl", "is-active", "sing-box.service", "rr-nexus.service"],
                capture_output=True, text=True, timeout=10, check=False)
            services_active = service.returncode == 0 and service.stdout.splitlines() == ["active", "active"]
            settled = synchronized and not inflight and services_active
            if not settled:
                stable_since = None
            elif stable_since is None:
                stable_since = time.monotonic()
            # Read the DB, generated config, failure audit, process table, and
            # service state again after two intervals. Config publication can
            # precede the worker's service restart and final failure audit.
            if settled and time.monotonic() - stable_since >= 6:
                self.passed("real_node_sync_and_original_identities", 2)
                return
            time.sleep(3)
        raise CheckFailed("real_node_sync_timeout")

    def revoke(self):
        self.phase = "revoke"
        require((self.stage / "credential.json").is_file(), "audit_key_not_issued")
        self.ok(self.local("POST", "/api/remote/revoke", {}, headers=self.step_up("remote_revoke")))
        save_private(self.stage / "revoked.json", {"role": self.role, "revoked": True})
        self.passed("revoke")

    def verify_revoked(self):
        self.phase = "verify_revoked"
        servers = self.ok(self.local("GET", "/api/remote-servers"))["servers"]
        own = [s for s in servers if s["name"].startswith(self.prefix + self.role)]
        require(len(own) == 2, "revocation_servers_missing")
        for server in own:
            status, value = self.proxy(server["id"], "GET", "/api/overview")
            require(status == 403 and value.get("error") == "invalid_remote_cred", "revoked_credential_accepted")
        summary = self.ok(self.local("POST", "/api/remote-servers/status", {}, read_only=True))["servers"]
        for server in own:
            value = next((s for s in summary if s["id"] == server["id"]), {})
            require(value.get("state") == "revoked" and value.get("online") is False, "revoked_status_incorrect")
        self.passed("old_keys_rejected_and_status_revoked", 4)

    def cleanup(self):
        self.phase = "cleanup"
        baseline_path = self.stage / "baseline.json"
        require(baseline_path.is_file() and not baseline_path.is_symlink(), "cleanup_baseline_required")
        baseline = json.loads(baseline_path.read_text())
        collections = (("/api/devices", "devices"), ("/api/device-groups", "groups"),
                       ("/api/device-templates", "templates"), ("/api/remote-servers", "servers"))
        protected = {
            "devices": set(baseline["devices"]),
            "groups": {str(row["id"]) for row in baseline["groups"]},
            "templates": {str(row["id"]) for row in baseline["templates"]},
            "servers": set(baseline["remote_identities"]),
        }
        pending = {}
        # Validate every collection before the first destructive request. A
        # baseline identity always wins over the test-name prefix.
        for path, collection in collections:
            rows = self.ok(self.local("GET", path))[collection]
            pending[path] = [row for row in rows if str(row.get("name", "")).startswith(self.prefix)]
            require(not any(str(row["id"]) in protected[collection] for row in pending[path]),
                    "cleanup_baseline_object_collision")
        if (self.stage / "credential.json").exists() and not (self.stage / "revoked.json").exists():
            self.revoke()
            self.phase = "cleanup"
        # Each target cleans its own incoming test objects with a normal local
        # administrator session, including partial writes of interrupted peers.
        for path, collection in collections:
            for row in pending[path]:
                self.ok(self.local("DELETE", path + "/" + str(row["id"]), {}))
            remaining = self.ok(self.local("GET", path))[collection]
            require(not any(str(r.get("name", "")).startswith(self.prefix) for r in remaining), "cleanup_objects_remaining")
        self.verify_local()
        require(self.db_identities() == baseline["identities"], "cleanup_database_identity_mismatch")
        require(self.remote_identities() == baseline["remote_identities"], "cleanup_original_remote_servers_changed")
        require(self.ok(self.local("GET", "/api/device-groups"))["groups"] == baseline["groups"],
                "cleanup_original_groups_changed")
        require(self.ok(self.local("GET", "/api/device-templates"))["templates"] == baseline["templates"],
                "cleanup_original_templates_changed")
        current = {d["id"]: self.device_identity(d) for d in self.get_devices(self.role)}
        require(current == baseline["devices"], "cleanup_original_devices_changed")
        for device_id, expected in baseline["links"].items():
            value = self.ok(self.local("GET", "/api/devices/{}/links".format(device_id)))
            require(self.links_identity(value) == expected, "cleanup_original_links_changed")
        self.phase = "cleanup"
        self.passed("cleanup_and_all_originals_preserved", 4)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("issue", "exercise", "verify-local", "revoke", "verify-revoked", "cleanup"))
    parser.add_argument("role", choices=tuple(EXPECTED))
    parser.add_argument("stage")
    args = parser.parse_args()
    driver = None
    try:
        driver = Driver(args.role, args.stage, args.command)
        driver.login()
        getattr(driver, args.command.replace("-", "_"))()
        print("CROSS_RESULT role={} phase={} cases={} result=pass".format(args.role, args.command, driver.cases), flush=True)
        return 0
    except BaseException as error:
        code = str(error) if isinstance(error, CheckFailed) else "unexpected_" + type(error).__name__
        if not re.fullmatch(r"[A-Za-z0-9_]{1,100}", code):
            code = "redacted_failure"
        print("CROSS_RESULT role={} phase={} pair={} result=fail code={}".format(
            args.role, driver.phase if driver else "preflight", driver.pair if driver else args.role, code), flush=True)
        return 1
    finally:
        if driver is not None and driver.token:
            try:
                driver.local("POST", "/api/logout", {})
            except BaseException:
                pass


if __name__ == "__main__":
    sys.exit(main())
