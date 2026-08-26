#!/usr/bin/env python3
"""RR subscription file server with dynamic per-device usage headers."""

from __future__ import annotations

import argparse
import io
import json
import re
import sqlite3
import urllib.parse
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


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


def load_database_path(config_path: Path) -> Path | None:
    try:
        payload = json.loads(config_path.read_text(encoding="utf-8"))
        database = Path(str(payload.get("database", "")))
        return database if database.is_file() else None
    except (OSError, ValueError, json.JSONDecodeError):
        return None


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
        return {
            "Subscription-Userinfo": "upload={}; download={}; total={}; expire={}".format(
                max(0, int(device["uploaded_bytes"] or 0)),
                max(0, int(device["downloaded_bytes"] or 0)),
                max(0, int(device["quota_bytes"] or 0)),
                expiry_epoch(device["expires_at"]),
            ),
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

        self._subscription_headers = headers
        return super().send_head()

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
