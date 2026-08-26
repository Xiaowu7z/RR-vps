#!/usr/bin/env python3
"""RR subscription file server with dynamic per-device usage headers."""

from __future__ import annotations

import argparse
import base64
import io
import json
import re
import sqlite3
import urllib.parse
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


TOKEN_FILE_RE = re.compile(
    r"^([A-Za-z0-9_-]{20,64}?)(?:-clash-verge\.yaml|-mihomo\.yaml|-flclash\.yaml|"
    r"-v2rayng\.txt|-v2rayn\.txt|-nekobox\.txt|-vl\.json|-sr\.txt|\.json|\.yaml|\.txt)$"
)


def expiry_epoch(value: str | None) -> int:
    try:
        parsed = datetime.strptime(value or "", "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return 0
    end = datetime.combine(parsed + timedelta(days=1), datetime.min.time(), tzinfo=timezone.utc)
    return int(end.timestamp()) - 1


PERSONAL_BASE64_SUFFIXES = (
    "-v2rayn.txt",
    "-v2rayng.txt",
    "-sr.txt",
    "-nekobox.txt",
)
PERSONAL_PROXY_TYPES = {
    "vmess",
    "vless",
    "hysteria2",
    "tuic",
    "anytls",
    "naive",
    "trojan",
    "shadowsocks",
}


def _subscription_value(device: Any, key: str, default: Any = None) -> Any:
    try:
        value = device[key]
    except (KeyError, IndexError, TypeError):
        return default
    return default if value is None else value


def _compact_bytes(value: int) -> str:
    amount = max(0, int(value or 0))
    for unit, divisor in (("TiB", 1024**4), ("GiB", 1024**3), ("MiB", 1024**2)):
        if amount >= divisor:
            number = amount / divisor
            rendered = f"{number:.2f}".rstrip("0").rstrip(".")
            return f"{rendered}{unit}"
    return f"{amount / 1024:.1f}KiB" if amount >= 1024 else f"{amount}B"


def subscription_usage_name(device: Any) -> str:
    used = max(0, int(_subscription_value(device, "used_bytes", 0) or 0))
    quota = max(0, int(_subscription_value(device, "quota_bytes", 0) or 0))
    remaining = _compact_bytes(max(0, quota - used)) if quota else "不限"
    expiry = str(_subscription_value(device, "expires_at", "") or "长期有效")
    return f"流量信息(勿选)｜已用{_compact_bytes(used)}｜剩余{remaining}｜到期{expiry}"


def subscription_transfer_values(device: Any, traffic_mode: str = "both") -> tuple[int, int]:
    """Return header counters whose sum always matches RR's quota counter."""
    used = max(0, int(_subscription_value(device, "used_bytes", 0) or 0))
    uploaded = max(0, int(_subscription_value(device, "uploaded_bytes", 0) or 0))
    downloaded = max(0, int(_subscription_value(device, "downloaded_bytes", 0) or 0))
    if traffic_mode == "upload":
        return used, 0
    if uploaded + downloaded == used:
        return uploaded, downloaded
    normalized_upload = min(uploaded, used)
    return normalized_upload, used - normalized_upload


def subscription_userinfo(device: Any, traffic_mode: str = "both") -> str:
    uploaded, downloaded = subscription_transfer_values(device, traffic_mode)
    return "upload={}; download={}; total={}; expire={}".format(
        uploaded,
        downloaded,
        max(0, int(_subscription_value(device, "quota_bytes", 0) or 0)),
        expiry_epoch(str(_subscription_value(device, "expires_at", "") or "")),
    )


def _uri_information_marker(name: str) -> str:
    """Build an importable marker that survives NekoBox address/port deduplication.

    URI subscription formats have no non-selectable information-row primitive.  A
    loopback VMess marker is therefore used: it is safe (cannot send traffic to a
    remote host), imports in URI/Base64 clients, and cannot collide with a real RR
    node's public address and port.
    """
    marker = {
        "v": "2",
        "ps": name,
        "add": "127.0.0.1",
        "port": "9",
        "id": "00000000-0000-4000-8000-000000000000",
        "aid": "0",
        "scy": "auto",
        "net": "tcp",
        "type": "none",
        "host": "",
        "path": "",
        "tls": "",
    }
    encoded = base64.b64encode(
        json.dumps(marker, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).decode("ascii").rstrip("=")
    return "vmess://" + encoded


def _clone_uri_with_name(uri: str, name: str) -> str | None:
    value = uri.strip()
    if value.startswith("vmess://"):
        try:
            payload = value.removeprefix("vmess://")
            decoded = base64.b64decode(payload + "=" * (-len(payload) % 4), altchars=b"-_")
            item = json.loads(decoded.decode("utf-8"))
            if not isinstance(item, dict):
                return None
            item["ps"] = name
            encoded = base64.b64encode(
                json.dumps(item, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            ).decode("ascii").rstrip("=")
            return "vmess://" + encoded
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
            return None
    try:
        parsed = urllib.parse.urlsplit(value)
    except ValueError:
        return None
    if parsed.scheme not in {
        "vless", "hysteria2", "hy2", "tuic", "anytls", "naive+https", "trojan", "ss"
    } or not parsed.netloc:
        return None
    return urllib.parse.urlunsplit(parsed._replace(fragment=urllib.parse.quote(name, safe="")))


def _enrich_uri_subscription(raw: bytes, name: str) -> bytes:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    for line in lines:
        if _clone_uri_with_name(line, name):
            marker = _uri_information_marker(name)
            return (marker + "\n" + "\n".join(lines) + "\n").encode("utf-8")
    return raw


def _enrich_base64_subscription(raw: bytes, name: str) -> bytes:
    try:
        payload = b"".join(raw.split())
        decoded = base64.b64decode(payload + b"=" * (-len(payload) % 4), altchars=b"-_")
    except (ValueError, TypeError):
        return raw
    enriched = _enrich_uri_subscription(decoded, name)
    if enriched == decoded:
        return raw
    return base64.b64encode(enriched)


def _enrich_singbox_subscription(raw: bytes, name: str) -> bytes:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return raw
    outbounds = payload.get("outbounds") if isinstance(payload, dict) else None
    if not isinstance(outbounds, list):
        return raw
    source = next(
        (
            item for item in outbounds
            if isinstance(item, dict) and str(item.get("type", "")) in PERSONAL_PROXY_TYPES
        ),
        None,
    )
    if source is None:
        return raw
    info = json.loads(json.dumps(source, ensure_ascii=False))
    info["tag"] = name
    outbounds.insert(0, info)
    for item in outbounds:
        if not isinstance(item, dict) or item.get("type") != "selector" or item.get("tag") != "proxy":
            continue
        choices = item.get("outbounds")
        if isinstance(choices, list) and name not in choices:
            choices.insert(0, name)
    return (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _enrich_clash_subscription(raw: bytes, name: str) -> bytes:
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw
    header = re.search(r"(?m)^proxies:\s*$", text)
    if not header:
        return raw
    first = re.search(
        r"(?ms)^  - name:.*?(?=^  - name:|^proxy-groups:)",
        text[header.end():],
    )
    if not first:
        return raw
    start = header.end() + first.start()
    end = header.end() + first.end()
    quoted = json.dumps(name, ensure_ascii=False)
    clone = re.sub(r"(?m)^  - name:.*$", f"  - name: {quoted}", text[start:end], count=1)
    enriched = text[:start] + clone + text[start:]
    group = re.search(r"(?ms)^(proxy-groups:\n.*?^    proxies:\n)", enriched)
    if group:
        enriched = enriched[:group.end()] + f"      - {quoted}\n" + enriched[group.end():]
    return enriched.encode("utf-8")


def enrich_subscription_content(raw: bytes, filename: str, device: Any) -> bytes:
    """Add a live first information entry without modifying stored artifacts."""
    lower = filename.lower()
    name = subscription_usage_name(device)
    if lower.endswith(PERSONAL_BASE64_SUFFIXES):
        return _enrich_base64_subscription(raw, name)
    if lower.endswith(".json"):
        return _enrich_singbox_subscription(raw, name)
    if lower.endswith(".yaml") or lower.endswith(".yml"):
        return _enrich_clash_subscription(raw, name)
    if lower.endswith(".txt"):
        return _enrich_uri_subscription(raw, name)
    return raw


def load_database_path(config_path: Path) -> Path | None:
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        database = Path(str(payload.get("database", "")))
        return database if database.is_file() else None
    except (OSError, ValueError, json.JSONDecodeError):
        return None


def load_traffic_mode(config_path: Path) -> str:
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        mode = str(payload.get("traffic_mode", "both") or "both")
        return mode if mode in {"both", "upload"} else "both"
    except (OSError, ValueError, json.JSONDecodeError):
        return "both"


class SubscriptionHandler(SimpleHTTPRequestHandler):
    server_version = "RR-Subscription"
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def device_for_request(self) -> sqlite3.Row | None:
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path)
        if not path.startswith("/nexus/") or "/" in path.removeprefix("/nexus/"):
            return None
        matched = TOKEN_FILE_RE.fullmatch(Path(path).name)
        if not matched:
            return None
        database = load_database_path(self.server.config_path)  # type: ignore[attr-defined]
        if database is None:
            return None
        try:
            connection = sqlite3.connect(database, timeout=5)
            connection.row_factory = sqlite3.Row
            try:
                return connection.execute(
                    "SELECT id,subscription_token,enabled,quota_bytes,used_bytes,"
                    "uploaded_bytes,downloaded_bytes,expires_at FROM devices "
                    "WHERE subscription_token=?",
                    (matched.group(1),),
                ).fetchone()
            finally:
                connection.close()
        except sqlite3.Error:
            return None

    def subscription_headers(self, device: sqlite3.Row) -> dict[str, str]:
        alias = "RR-{}".format(str(device["id"]).removeprefix("dev_")[:8].upper())
        traffic_mode = load_traffic_mode(self.server.config_path)  # type: ignore[attr-defined]
        return {
            "Subscription-Userinfo": subscription_userinfo(device, traffic_mode),
            "Profile-Update-Interval": "1",
            "Profile-Title": alias,
            "Access-Control-Expose-Headers": (
                "Subscription-Userinfo, Profile-Update-Interval, Profile-Title"
            ),
            "Cache-Control": "no-store",
        }

    def send_head(self):  # type: ignore[no-untyped-def]
        parsed = urllib.parse.urlsplit(self.path)
        candidate = urllib.parse.unquote(parsed.path)
        is_personal = candidate.startswith("/nexus/") and TOKEN_FILE_RE.fullmatch(Path(candidate).name)
        database = load_database_path(self.server.config_path)  # type: ignore[attr-defined]
        device = self.device_for_request() if is_personal and database is not None else None
        if is_personal and database is not None and device is None:
            self.send_error(HTTPStatus.NOT_FOUND, "subscription not found")
            return None
        if device is None:
            return super().send_head()

        headers = self.subscription_headers(device)
        today = datetime.now(timezone.utc).date().isoformat()
        expired = bool(device["expires_at"] and device["expires_at"] < today)
        quota_exhausted = bool(
            int(device["quota_bytes"] or 0) > 0
            and int(device["used_bytes"] or 0) >= int(device["quota_bytes"] or 0)
        )
        inactive = not bool(device["enabled"]) or expired or quota_exhausted
        if inactive:
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return io.BytesIO(b"")

        file_path = Path(self.translate_path(self.path))
        try:
            raw = file_path.read_bytes()
        except OSError:
            self.send_error(HTTPStatus.NOT_FOUND, "subscription not found")
            return None
        body = enrich_subscription_content(raw, file_path.name, device)
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", self.guess_type(str(file_path)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        return io.BytesIO(body)

    def end_headers(self) -> None:
        for key, value in getattr(self, "_subscription_headers", {}).items():
            self.send_header(key, value)
        self._subscription_headers = {}
        super().end_headers()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=int)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--directory", default=".")
    parser.add_argument("--config", default="/etc/rr-nexus/nexus.json")
    args = parser.parse_args()
    handler = lambda *hargs, **kwargs: SubscriptionHandler(  # noqa: E731
        *hargs, directory=args.directory, **kwargs
    )
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    server.config_path = Path(args.config)  # type: ignore[attr-defined]
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
