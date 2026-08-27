"""Notification delivery and deduplication for RR Nexus."""

from __future__ import annotations

import hashlib
import hmac
import json
import re
import sqlite3
from datetime import datetime, timezone
from typing import Any

from rr_nexus_lib.http_security import UnsafeTargetError, https_post, public_https_target


HTTPS_URL_RE = re.compile(r"^https://[^\s\x00-\x1f]{3,2048}$")


class NotificationManager:
    def __init__(self, store: Any):
        self.store = store

    def settings(self, masked: bool = False) -> dict[str, Any]:
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM notification_settings WHERE id=1").fetchone()
        item = dict(row) if row else {}
        item["enabled"] = bool(item.get("enabled", 0))
        item["events"] = json.loads(item.pop("events_json", "[]") or "[]")
        item["telegram_configured"] = bool(item.get("telegram_token") and item.get("telegram_chat_id"))
        item["webhook_configured"] = bool(item.get("webhook_url"))
        if masked:
            item["telegram_token"] = "********" if item.get("telegram_token") else ""
            item["webhook_url"] = self._mask_url(str(item.get("webhook_url", "")))
            item["webhook_secret"] = "********" if item.get("webhook_secret") else ""
        return item

    @staticmethod
    def _mask_url(value: str) -> str:
        if not value:
            return ""
        try:
            from urllib.parse import urlsplit

            parsed = urlsplit(value)
            return f"{parsed.scheme}://{parsed.hostname or ''}/••••"
        except ValueError:
            return "••••"

    def update(self, payload: dict[str, Any]) -> dict[str, Any]:
        current = self.settings(masked=False)
        webhook_supplied = "webhook_url" in payload and not str(
            payload.get("webhook_url", "") or ""
        ).endswith("/••••")
        enabled = bool(payload.get("enabled", current.get("enabled", False)))
        token = str(payload.get("telegram_token", "") or "").strip()
        chat_id = str(payload.get("telegram_chat_id", current.get("telegram_chat_id", "")) or "").strip()
        webhook = str(payload.get("webhook_url", "") or "").strip()
        secret = str(payload.get("webhook_secret", "") or "").strip()
        if token == "********" or (not token and "telegram_token" not in payload):
            token = str(current.get("telegram_token", ""))
        if secret == "********" or (not secret and "webhook_secret" not in payload):
            secret = str(current.get("webhook_secret", ""))
        if webhook.endswith("/••••") or (not webhook and "webhook_url" not in payload):
            webhook = str(current.get("webhook_url", ""))
        if token and not re.fullmatch(r"\d{5,20}:[A-Za-z0-9_-]{20,128}", token):
            raise ValueError("invalid_telegram_token")
        if chat_id and not re.fullmatch(r"-?\d{3,32}", chat_id):
            raise ValueError("invalid_telegram_chat_id")
        if webhook and not HTTPS_URL_RE.fullmatch(webhook):
            raise ValueError("invalid_webhook_url")
        if webhook and webhook_supplied:
            try:
                public_https_target(webhook)
            except UnsafeTargetError as exc:
                raise ValueError("invalid_webhook_url") from exc
        events = payload.get("events", current.get("events", []))
        allowed = {
            "service_down", "disk_high", "traffic_threshold", "certificate_expiry",
            "device_quota", "update_failed", "backup_failed", "security_lockout",
            "argo_domain_changed",
        }
        if not isinstance(events, list):
            raise ValueError("invalid_notification_events")
        events = sorted({str(item) for item in events} & allowed)
        disk_threshold = int(payload.get("disk_threshold", current.get("disk_threshold", 90)) or 90)
        traffic_threshold = int(payload.get("traffic_threshold", current.get("traffic_threshold", 90)) or 90)
        if not 50 <= disk_threshold <= 99 or not 50 <= traffic_threshold <= 100:
            raise ValueError("invalid_notification_threshold")
        now = datetime.now(timezone.utc).replace(microsecond=0).isoformat()
        with self.store.connect() as db:
            db.execute(
                "UPDATE notification_settings SET enabled=?,telegram_token=?,telegram_chat_id=?,"
                "webhook_url=?,webhook_secret=?,events_json=?,disk_threshold=?,traffic_threshold=?,"
                "updated_at=? WHERE id=1",
                (int(enabled), token, chat_id, webhook, secret, json.dumps(events), disk_threshold,
                 traffic_threshold, now),
            )
        return self.settings(masked=True)

    def emit(
        self,
        event: str,
        severity: str,
        title: str,
        message: str,
        dedupe_key: str,
        minimum_interval: int = 3600,
        force: bool = False,
    ) -> tuple[bool, str]:
        cfg = self.settings(masked=False)
        if not force and (not cfg.get("enabled") or event not in cfg.get("events", [])):
            return True, "disabled"
        now_epoch = int(datetime.now(timezone.utc).timestamp())
        with self.store.connect() as db:
            row = db.execute(
                "SELECT sent_at FROM notification_dedup WHERE event_key=?", (dedupe_key[:160],)
            ).fetchone()
            if not force and row and now_epoch - int(row["sent_at"]) < minimum_interval:
                return True, "deduplicated"
        payload = {
            "source": "RR-vps",
            "event": event,
            "severity": severity,
            "title": title[:160],
            "message": message[:2000],
            "timestamp": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        }
        deliveries: list[str] = []
        errors: list[str] = []
        token, chat_id = cfg.get("telegram_token", ""), cfg.get("telegram_chat_id", "")
        if token and chat_id:
            ok, detail = self._telegram(token, chat_id, payload)
            (deliveries if ok else errors).append("telegram" if ok else detail)
        if cfg.get("webhook_url"):
            ok, detail = self._webhook(cfg["webhook_url"], cfg.get("webhook_secret", ""), payload)
            (deliveries if ok else errors).append("webhook" if ok else detail)
        ok = bool(deliveries) and not errors
        detail = ",".join(deliveries + errors) or "no_channel"
        with self.store.connect() as db:
            db.execute(
                "INSERT INTO notification_log(created_at,event,severity,title,detail,delivered) "
                "VALUES(?,?,?,?,?,?)",
                (payload["timestamp"], event[:64], severity[:16], title[:160], detail[:512], int(ok)),
            )
            if ok:
                db.execute(
                    "INSERT INTO notification_dedup(event_key,sent_at) VALUES(?,?) "
                    "ON CONFLICT(event_key) DO UPDATE SET sent_at=excluded.sent_at",
                    (dedupe_key[:160], now_epoch),
                )
        self.store.prune_history()
        return ok, detail

    @staticmethod
    def _telegram(token: str, chat_id: str, payload: dict[str, Any]) -> tuple[bool, str]:
        icons = {"critical": "🚨", "warning": "⚠️", "info": "ℹ️"}
        text = "{} RR-vps · {}\n{}\n{}".format(
            icons.get(payload["severity"], "🔔"), payload["title"], payload["message"], payload["timestamp"]
        )
        url = f"https://api.telegram.org/bot{token}/sendMessage"
        body = json.dumps({"chat_id": chat_id, "text": text}, ensure_ascii=False).encode()
        return NotificationManager._request(url, body, {"Content-Type": "application/json"})

    @staticmethod
    def _webhook(url: str, secret: str, payload: dict[str, Any]) -> tuple[bool, str]:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        headers = {"Content-Type": "application/json", "User-Agent": "RR-vps/7.1"}
        if secret:
            headers["X-RR-Signature"] = "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
        return NotificationManager._request(url, body, headers)

    @staticmethod
    def _request(url: str, body: bytes, headers: dict[str, str]) -> tuple[bool, str]:
        try:
            status, _ = https_post(url, body, headers, timeout=10)
            if 200 <= status < 300:
                return True, "ok"
            return False, f"http_{status}"
        except UnsafeTargetError:
            return False, "unsafe_target"
        except TimeoutError:
            return False, "network_timeout"
        except OSError as exc:
            return False, f"network_{type(exc).__name__}"
