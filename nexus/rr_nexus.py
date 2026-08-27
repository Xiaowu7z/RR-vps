#!/usr/bin/env python3
"""RR Nexus: a small, dependency-light management API for RR-vps."""

from __future__ import annotations

import argparse
import base64
import calendar
import hashlib
import hmac
import ipaddress
import json
import math
import mimetypes
import os
import re
import secrets
import shutil
import sqlite3
import platform
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator

from rr_nexus_lib.notifications import NotificationManager
from rr_nexus_lib.http_security import UnsafeTargetError, https_post
from rr_nexus_lib.security import (
    b64url_decode,
    b64url_encode,
    generate_totp_secret,
    parse_registration,
    totp_uri,
    verify_authentication,
    verify_totp,
    webauthn_available,
)

try:
    from argon2 import PasswordHasher
    # Ubuntu 22.04 ships argon2-cffi 21.1.0.  InvalidHashError was only
    # introduced in 23.1.0; InvalidHash is the compatible name on both the
    # Ubuntu 22.04 and Debian 12 package versions (and remains an alias later).
    from argon2.exceptions import InvalidHash, VerifyMismatchError
except ImportError as exc:  # pragma: no cover - checked by installer
    raise SystemExit("python3-argon2 is required") from exc

try:
    import grpc
except ImportError:  # pragma: no cover - installer checks and reports this
    grpc = None


APP_ROOT = Path(__file__).resolve().parent
STATIC_ROOT = APP_ROOT / "static"
CONFIG_PATH = Path(os.environ.get("RR_NEXUS_CONFIG", "/etc/rr-nexus/nexus.json"))
MAX_BODY = 32 * 1024
SESSION_HOURS = 12
LOGIN_WINDOW = 30 * 60
LOGIN_LIMIT = 5
# 顶级防爆破：IP+账号双维、持久化、指数退避、渐进延迟
LOGIN_ACCOUNT_WINDOW = 60 * 60          # 账号级失败窗口 1 小时
LOGIN_ACCOUNT_LIMIT = 10                # 账号 10 次失败锁账号
LOGIN_FAIL_DELAY = 0.35                 # 基础失败延迟（秒）
LOGIN_FAIL_DELAY_STEP = 0.4             # 每次失败递增延迟
LOGIN_FAIL_DELAY_MAX = 5.0              # 延迟上限
MAX_DEVICES = 500
DEVICE_NAME_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,64}$")
DEVICE_ID_RE = re.compile(r"^dev_[a-f0-9]{12}$")
USERNAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.-]{2,31}$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
TRAFFIC_COUNTER_RE = re.compile(
    r"^user>>>(dev_[a-f0-9]{12})>>>traffic>>>(uplink|downlink)$"
)
TRAFFIC_POLL_SECONDS = 5
# 额度用尽后留给管理员手动重置的宽限期。超过 35 天仍未处理才删除设备。
QUOTA_AUTO_DELETE_SECONDS = 35 * 86400
TRAFFIC_BUCKET_SECONDS = 5 * 60
TRAFFIC_RETENTION_SECONDS = 30 * 24 * 3600
SYSTEM_SAMPLE_SECONDS = 60
SYSTEM_RETENTION_SECONDS = 30 * 24 * 3600
AUDIT_RETENTION_SECONDS = 180 * 24 * 3600
NOTIFICATION_RETENTION_SECONDS = 90 * 24 * 3600
MAX_AUDIT_ROWS = 100_000
MAX_NOTIFICATION_ROWS = 20_000
MAX_AUTO_RESET_COUNT = 120
MAX_SERVER_TRAFFIC_GB = 1024 * 1024
SERVER_TRAFFIC_MODES = {"both", "tx", "rx"}
MAX_JSON_BODY_BYTES = 1024 * 1024
MIN_ADMIN_PASSWORD_LENGTH = 12
V2RAY_QUERY_METHOD = "/v2ray.core.app.stats.command.StatsService/QueryStats"

# ---- 多服务器远程管理（6.6.0）----
REMOTE_KEY_PATH = Path("/var/lib/rr-nexus/remote.key")
REMOTE_CRED_PREFIX = "rrmgr1"
REMOTE_FAIL_WINDOW = 30 * 60          # 远程钥匙验证失败窗口（秒）
REMOTE_FAIL_LIMIT = 10                # 同 IP 窗口内失败次数上限
REMOTE_FAIL_DELAY = 0.5               # 验证失败基础延迟
REMOTE_HTTP_TIMEOUT = 15              # 主面板调副面板超时（秒）
REMOTE_MAX_SERVERS = 500              # 主面板可管理的服务器上限（无上限语义）
REMOTE_CRED_NAME_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,64}$")


class RequestBodyTooLarge(ValueError):
    """Stop request dispatch after enforcing the endpoint body limit."""

# 远程升级任务（副面板侧，6.6.3）：任务状态文件 + 异步执行升级。
# 统一调用 rr --update-now：复用模块内 GitHub Raw/API/CDN 回退、bundle 双层校验、
# 安装器事务替换与 post_update_migrate。避免面板另维护一套只有 Raw 的下载逻辑。
# 关键：必须用 systemd-run 隔离——install.sh --upgrade 中途会 stop rr-nexus，
# 若升级进程在面板 cgroup 内会连同面板一起被杀，死在 stop/restart 之间。
UPDATE_JOB_PATH = Path("/var/lib/rr-nexus/update-job.json")
UPDATE_LOG_PATH = Path("/var/lib/rr-nexus/update.log")
UPDATE_LOCK_PATH = Path("/var/lib/rr-nexus/update.lock")
UPDATE_LOCK_STALE_AGE = 30  # 秒：残留锁判死需锁龄超阈值，防误删刚认领（systemd unit 尚未注册）的新锁
_UPDATE_CLAIM_LOCK = threading.Lock()  # 进程内认领互斥：本地/远程通道同进程，串行化认领全序列
UPDATE_LOCAL_MANIFEST = Path("/usr/local/lib/rr/manifest.sha256")
UPDATE_CHANNEL_PATH = Path("/etc/rr-update/channel")
UPDATE_CMD = [
    "systemd-run", "--unit=rr-remote-upgrade", "--collect", "--wait",
    "/bin/bash", "-c",
    'exec > /var/lib/rr-nexus/update.log 2>&1; '
    'echo "[1/2] 启动统一更新事务..."; '
    '/usr/local/bin/rr --update-now; '
    'rc=$?; '
    'echo "[2/2] 完成（退出码 $rc）"; exit $rc',
]


def update_channel(value: str | None = None) -> str:
    """Read or atomically update the stable/beta channel selection."""
    if value is not None:
        normalized = str(value).strip().lower()
        if normalized not in {"stable", "beta"}:
            raise ValueError("invalid_update_channel")
        UPDATE_CHANNEL_PATH.parent.mkdir(parents=True, exist_ok=True)
        temporary = UPDATE_CHANNEL_PATH.with_name(
            f".channel.{os.getpid()}.{secrets.token_hex(6)}.tmp"
        )
        try:
            with temporary.open("x", encoding="ascii") as output:
                output.write(normalized + "\n")
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o600)
            os.replace(temporary, UPDATE_CHANNEL_PATH)
        except Exception:
            temporary.unlink(missing_ok=True)
            raise
        return normalized
    try:
        normalized = UPDATE_CHANNEL_PATH.read_text(encoding="ascii").strip().lower()
    except OSError:
        normalized = "stable"
    return normalized if normalized in {"stable", "beta"} else "stable"


def update_manifest_url() -> str:
    branch = "main" if update_channel() == "stable" else "beta"
    return f"https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/{branch}/manifest.sha256"


def remote_key_load_or_create() -> bytes:
    """副面板签发密钥：256 位随机，仅本机可读（600）。轮换即吊销全部旧钥匙。"""
    REMOTE_KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
    try:
        raw = REMOTE_KEY_PATH.read_bytes()
        if len(raw) == 32:
            return raw
    except FileNotFoundError:
        pass
    key = secrets.token_bytes(32)
    fd = os.open(REMOTE_KEY_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(key)
    return key


def remote_cert_check(cfg: "NexusConfig") -> tuple[bool, str]:
    """签发前提：公网证书模式（域名 + Let's Encrypt 真证书）。"""
    if cfg.mode != "public":
        return False, "仅公网证书（域名 + Let's Encrypt）面板可签发远程钥匙"
    domain = (cfg.domain or "").strip()
    if not domain or domain == "ip" or re.fullmatch(r"[0-9.]+|[\da-fA-F:]+", domain):
        return False, "面板域名无效，需要公网证书域名"
    cert = Path("/etc/letsencrypt/live/{}/fullchain.pem".format(domain))
    if not cert.exists():
        return False, "未检测到 Let's Encrypt 证书（{}）".format(cert)
    return True, ""


def remote_cred_issue(name: str, cfg: "NexusConfig") -> tuple[str | None, str]:
    """签发一行接入钥匙：rrmgr1.<b64url(payload)>.<b64url(HMAC-SHA256 签名)>。"""
    ok, reason = remote_cert_check(cfg)
    if not ok:
        return None, reason
    name = (name or "").strip()[:64]
    if not REMOTE_CRED_NAME_RE.fullmatch(name):
        return None, "名称无效（1-64 字符）"
    addr = (cfg.domain or "").strip()
    port = cfg.public_port or 443
    key = remote_key_load_or_create()
    payload = {
        "v": 1,
        "a": addr,
        "p": int(port),
        "t": secrets.token_hex(32),
        "n": name,
        "i": epoch_now(),
    }
    payload_b64 = base64.urlsafe_b64encode(json_compact(payload)).rstrip(b"=").decode("ascii")
    body = REMOTE_CRED_PREFIX + "." + payload_b64
    sig = hmac.new(key, body.encode("ascii"), hashlib.sha256).digest()
    sig_b64 = base64.urlsafe_b64encode(sig).rstrip(b"=").decode("ascii")
    payload["fp"] = sha256_text(key.hex() + addr + payload["t"])[:12]
    return body + "." + sig_b64, ""


def remote_cred_parse(cred: str) -> dict | None:
    """只解析 payload（供主面板读地址/端口），不验证签名。"""
    if not isinstance(cred, str) or len(cred) > 4096:
        return None
    parts = cred.split(".")
    if len(parts) != 3 or parts[0] != REMOTE_CRED_PREFIX:
        return None
    try:
        padded = parts[1] + "=" * (-len(parts[1]) % 4)
        raw = base64.urlsafe_b64decode(padded)
        payload = json.loads(raw)
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    addr = payload.get("a")
    token = payload.get("t")
    try:
        port_text = str(payload.get("p", ""))
        if len(port_text) > 5 or not port_text.isdigit():
            return None
        port = int(port_text)
    except (TypeError, ValueError):
        return None
    if (
        payload.get("v") != 1
        or not isinstance(addr, str)
        or not 1 <= len(addr) <= 253
        or any(ord(char) < 33 or ord(char) == 127 for char in addr)
        or any(char in addr for char in "/@?#[]:")
        or not 1 <= port <= 65535
        or not isinstance(token, str)
        or not re.fullmatch(r"[0-9a-f]{64}", token)
    ):
        return None
    payload["p"] = port
    return payload


def remote_cred_verify(cred: str) -> dict | None:
    """副面板验证：HMAC 比对（密钥仅本机持有）+ payload 结构校验。"""
    if not isinstance(cred, str) or len(cred) > 4096:
        return None
    parts = cred.split(".")
    if len(parts) != 3 or parts[0] != REMOTE_CRED_PREFIX:
        return None
    try:
        padded = parts[2] + "=" * (-len(parts[2]) % 4)
        given = base64.urlsafe_b64decode(padded)
    except Exception:
        return None
    key = remote_key_load_or_create()
    expect = hmac.new(key, (parts[0] + "." + parts[1]).encode("ascii"), hashlib.sha256).digest()
    if not hmac.compare_digest(given, expect):
        return None
    return remote_cred_parse(cred)


def remote_cred_fingerprint(payload: dict) -> str:
    return payload.get("fp") or sha256_text(str(payload.get("t", "")))[:12]



def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def epoch_now() -> int:
    return int(time.time())


def bounded_remote_number(value: Any, maximum: float, *, integer: bool = False) -> int | float:
    """Parse an untrusted remote metric without expensive huge-number conversion."""
    if isinstance(value, bool):
        number = float(int(value))
    elif isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str) and len(value) <= 32 and re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", value):
        number = float(value)
    else:
        return 0
    if not math.isfinite(number):
        return 0
    number = max(0.0, min(float(maximum), number))
    return int(number) if integer else number


def parse_date(value: str) -> date | None:
    try:
        return datetime.strptime(value, "%Y-%m-%d").date()
    except (TypeError, ValueError):
        return None


def add_calendar_month(value: date, anchor_day: int) -> date:
    """Advance one calendar month while preserving the configured day when possible."""
    year = value.year + (1 if value.month == 12 else 0)
    month = 1 if value.month == 12 else value.month + 1
    day = min(max(1, anchor_day), calendar.monthrange(year, month)[1])
    return value.replace(year=year, month=month, day=day)


def add_calendar_months(value: date, months: int, anchor_day: int | None = None) -> date:
    result = value
    anchor = anchor_day or value.day
    for _ in range(max(0, months)):
        result = add_calendar_month(result, anchor)
    return result


def expiry_epoch(value: str | None) -> int:
    """Return the final valid second of the configured UTC expiry date."""
    parsed = parse_date(value or "")
    if parsed is None:
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
    """Compact live quota text used as the first, still-connectable proxy alias."""
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
    """Build a safe importable marker that survives address/port deduplication."""
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
        "vless", "hysteria2", "hy2", "tuic", "anytls", "naive+https", "naive+quic", "trojan", "ss"
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
    """Add a live first information entry without modifying stored subscription files."""
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


def json_compact(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def safe_compare(left: str, right: str) -> bool:
    try:
        return hmac.compare_digest(left.encode("ascii"), right.encode("ascii"))
    except UnicodeEncodeError:
        return False


def encode_varint(value: int) -> bytes:
    output = bytearray()
    while value > 0x7F:
        output.append((value & 0x7F) | 0x80)
        value >>= 7
    output.append(value)
    return bytes(output)


def decode_varint(payload: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(payload) and shift < 70:
        current = payload[offset]
        offset += 1
        value |= (current & 0x7F) << shift
        if not current & 0x80:
            return value, offset
        shift += 7
    raise ValueError("invalid protobuf varint")


def protobuf_fields(payload: bytes) -> list[tuple[int, int, Any]]:
    fields: list[tuple[int, int, Any]] = []
    offset = 0
    while offset < len(payload):
        key, offset = decode_varint(payload, offset)
        field_number = key >> 3
        wire_type = key & 7
        if field_number == 0:
            raise ValueError("invalid protobuf field")
        if wire_type == 0:
            value, offset = decode_varint(payload, offset)
        elif wire_type == 1:
            if offset + 8 > len(payload):
                raise ValueError("truncated protobuf fixed64")
            value = payload[offset:offset + 8]
            offset += 8
        elif wire_type == 2:
            length, offset = decode_varint(payload, offset)
            if length < 0 or offset + length > len(payload):
                raise ValueError("truncated protobuf bytes")
            value = payload[offset:offset + length]
            offset += length
        elif wire_type == 5:
            if offset + 4 > len(payload):
                raise ValueError("truncated protobuf fixed32")
            value = payload[offset:offset + 4]
            offset += 4
        else:
            raise ValueError("unsupported protobuf wire type")
        fields.append((field_number, wire_type, value))
    return fields


def parse_query_stats_response(payload: bytes) -> dict[str, int]:
    counters: dict[str, int] = {}
    for field_number, wire_type, value in protobuf_fields(payload):
        if field_number != 1 or wire_type != 2:
            continue
        name = ""
        counter_value = 0
        for stat_field, stat_wire, stat_value in protobuf_fields(value):
            if stat_field == 1 and stat_wire == 2:
                name = stat_value.decode("utf-8")
            elif stat_field == 2 and stat_wire == 0:
                counter_value = int(stat_value)
        if name and counter_value >= 0:
            counters[name] = counters.get(name, 0) + counter_value
    return counters


def query_v2ray_stats(address: str) -> dict[str, int]:
    if grpc is None:
        raise RuntimeError("python3-grpcio is not installed")
    pattern = b"user>>>"
    # QueryStatsRequest.patterns is field 3; field 1 is the deprecated
    # single-pattern field and current sing-box intentionally ignores it.
    request = b"\x10\x01\x1a" + encode_varint(len(pattern)) + pattern
    with grpc.insecure_channel(address) as channel:
        call = channel.unary_unary(
            V2RAY_QUERY_METHOD,
            request_serializer=lambda value: value,
            response_deserializer=lambda value: value,
        )
        response = call(request, timeout=2.5)
    return parse_query_stats_response(response)


@dataclass(frozen=True)
class NexusConfig:
    mode: str
    listen: str
    port: int
    domain: str
    database: Path
    subscription_root: Path
    published_subscription_root: Path
    stats_port: int

    @property
    def access_url(self) -> str:
        if self.mode == "local":
            return "http://127.0.0.1:{}".format(self.public_port or self.port)
        elif not self.domain or self.domain == "ip":
            return "https://{}:{}".format(self.ssh_host, self.public_port or self.port)
        else:
            return "https://{}:{}".format(self.domain, self.public_port or self.port)
    ssh_host: str
    secure_cookie: bool
    traffic_mode: str = "both"
    public_port: int = 7900
    sub_port: int = 0

    @classmethod
    def load(cls) -> "NexusConfig":
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        mode = str(raw.get("mode", "local"))
        listen = str(raw.get("listen", "127.0.0.1"))
        port = int(raw.get("port", 7900))
        domain = str(raw.get("domain", ""))
        database = Path(str(raw.get("database", "/var/lib/rr-nexus/nexus.db")))
        subscription_root = Path(str(raw.get("subscription_root", "/var/lib/rr-nexus/subscriptions")))
        published_subscription_root = Path(
            str(raw.get("published_subscription_root", "/tmp/sub_server/nexus"))
        )
        public_port = int(raw.get("public_port", 7900))
        stats_port = int(raw.get("stats_port", 39091))
        ssh_host = str(raw.get("ssh_host", "服务器IP")).strip()
        sub_port = int(raw.get("sub_port", 0))
        traffic_mode = str(raw.get("traffic_mode", "both") or "both")
        if (
            mode not in {"local", "public"}
            or listen != "127.0.0.1"
            or not 1 <= port <= 65535
            or not 1 <= public_port <= 65535
            or not 0 <= sub_port <= 65535
            or not 1 <= stats_port <= 65535
            or stats_port == port
            or not ssh_host
            or len(ssh_host) > 255
            or any(ord(char) < 33 or ord(char) == 127 for char in ssh_host)
            or traffic_mode not in {"both", "upload"}
            or (
                CONFIG_PATH == Path("/etc/rr-nexus/nexus.json")
                and (
                    database != Path("/var/lib/rr-nexus/nexus.db")
                    or subscription_root != Path("/var/lib/rr-nexus/subscriptions")
                    or published_subscription_root != Path("/tmp/sub_server/nexus")
                )
            )
        ):
            raise ValueError("invalid RR Nexus config")
        return cls(
            mode=mode,
            listen=listen,
            port=port,
            domain=domain,
            database=database,
            subscription_root=subscription_root,
            published_subscription_root=published_subscription_root,
            stats_port=stats_port,
            ssh_host=ssh_host,
            secure_cookie=mode == "public",
            traffic_mode=traffic_mode,
            public_port=public_port,
            sub_port=sub_port,
        )

    @property
    def stats_address(self) -> str:
        return f"127.0.0.1:{self.stats_port}"


class StoreCorruptionError(RuntimeError):
    """nexus.db 完整性校验失败：拒绝启动，防止数据进一步损坏（数据安全优先）。"""


class Store:
    def __init__(self, path: Path):
        self.path = path
        self._history_cleanup_lock = threading.Lock()
        self._last_history_cleanup = 0
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.verify_integrity()
        self.initialize()
        self.prune_history(force=True)

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        connection = sqlite3.connect(self.path, timeout=30)
        try:
            connection.row_factory = sqlite3.Row
            # busy_timeout 必须先于 journal_mode 设置：WAL 切换需要独占锁，否则并发轮询抢锁
            connection.execute("PRAGMA busy_timeout = 15000")
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA foreign_keys = ON")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def verify_integrity(self) -> None:
        # T4：启动时快速完整性检查（PRAGMA quick_check）。损坏的库（写坏半截、
        # 非 sqlite 文件等）会在 connect/首次执行时抛 sqlite3.DatabaseError；
        # 统一转成 StoreCorruptionError，由 main() 打印恢复路径并以专用退出码
        # 3 拒绝启动——systemd 单元配 RestartPreventExitStatus=3，杜绝
        # Restart=on-failure 的无限崩溃循环。绝不自动重建（数据安全优先）。
        if not self.path.exists():
            return
        if self.path.stat().st_size == 0:
            raise StoreCorruptionError(
                f"{self.path} 是零字节文件（可能写入中途被中断）。"
                "未自动重建。恢复路径：从备份恢复该文件；若确认放弃数据，"
                "将其移走（mv nexus.db nexus.db.corrupt）后执行 --init-admin 重新初始化。"
            )
        try:
            with self.connect() as db:
                row = db.execute("PRAGMA quick_check").fetchone()
        except sqlite3.DatabaseError as exc:
            raise StoreCorruptionError(
                f"{self.path} 损坏（{exc}）。未自动重建。恢复路径：从备份恢复该文件；"
                "若确认放弃数据，将其移走（mv nexus.db nexus.db.corrupt）后执行 --init-admin 重新初始化。"
            ) from exc
        if row is None or str(row[0]).lower() != "ok":
            raise StoreCorruptionError(
                f"{self.path} 完整性校验未通过（quick_check={row[0] if row else '无结果'}）。"
                "未自动重建。恢复路径：从备份恢复该文件；若确认放弃数据，"
                "将其移走（mv nexus.db nexus.db.corrupt）后执行 --init-admin 重新初始化。"
            )

    def initialize(self) -> None:
        with self.connect() as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS admins (
                    id INTEGER PRIMARY KEY,
                    username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL,
                    totp_secret TEXT NOT NULL DEFAULT '',
                    totp_pending_secret TEXT NOT NULL DEFAULT '',
                    totp_enabled INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS recovery_codes (
                    code_hash TEXT PRIMARY KEY,
                    admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
                    used_at TEXT
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
                    csrf_token TEXT NOT NULL,
                    remote_ip TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS login_failures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL,
                    remote_ip TEXT NOT NULL,
                    failed_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_login_failures_ip ON login_failures(remote_ip, failed_at);
                CREATE INDEX IF NOT EXISTS idx_login_failures_user ON login_failures(username, failed_at);
                CREATE TABLE IF NOT EXISTS device_groups (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    color TEXT NOT NULL DEFAULT '#4f8cff',
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS device_templates (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    quota_bytes INTEGER NOT NULL DEFAULT 0,
                    expiry_days INTEGER NOT NULL DEFAULT 0,
                    reset_max INTEGER NOT NULL DEFAULT 0,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS devices (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    credential TEXT NOT NULL UNIQUE,
                    subscription_token TEXT NOT NULL UNIQUE,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    quota_bytes INTEGER NOT NULL DEFAULT 0,
                    used_bytes INTEGER NOT NULL DEFAULT 0,
                    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                    downloaded_bytes INTEGER NOT NULL DEFAULT 0,
                    traffic_updated_at TEXT,
                    group_id INTEGER REFERENCES device_groups(id) ON DELETE SET NULL,
                    expires_at TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS audit_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    actor TEXT NOT NULL,
                    action TEXT NOT NULL,
                    target TEXT NOT NULL,
                    remote_ip TEXT NOT NULL,
                    detail TEXT NOT NULL DEFAULT ''
                );
                CREATE TABLE IF NOT EXISTS traffic_samples (
                    bucket INTEGER PRIMARY KEY,
                    uploaded_bytes INTEGER NOT NULL DEFAULT 0,
                    downloaded_bytes INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS system_samples (
                    bucket INTEGER PRIMARY KEY,
                    cpu_percent REAL NOT NULL DEFAULT 0,
                    memory_percent REAL NOT NULL DEFAULT 0,
                    disk_percent REAL NOT NULL DEFAULT 0,
                    load1 REAL NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS server_traffic_policy (
                    id INTEGER PRIMARY KEY CHECK(id=1),
                    quota_bytes INTEGER NOT NULL DEFAULT 0,
                    count_mode TEXT NOT NULL DEFAULT 'both',
                    interface_name TEXT NOT NULL DEFAULT '',
                    last_interface TEXT NOT NULL DEFAULT '',
                    received_bytes INTEGER NOT NULL DEFAULT 0,
                    transmitted_bytes INTEGER NOT NULL DEFAULT 0,
                    initial_used_bytes INTEGER NOT NULL DEFAULT 0,
                    last_rx_counter INTEGER,
                    last_tx_counter INTEGER,
                    cycle_started_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS remote_failures (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    remote_ip TEXT NOT NULL,
                    failed_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_remote_failures_ip ON remote_failures(remote_ip, failed_at);
                CREATE TABLE IF NOT EXISTS remote_servers (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    cred TEXT NOT NULL,
                    addr TEXT NOT NULL,
                    port INTEGER NOT NULL,
                    last_seen TEXT,
                    last_status TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS notification_settings (
                    id INTEGER PRIMARY KEY CHECK(id=1),
                    enabled INTEGER NOT NULL DEFAULT 0,
                    telegram_token TEXT NOT NULL DEFAULT '',
                    telegram_chat_id TEXT NOT NULL DEFAULT '',
                    webhook_url TEXT NOT NULL DEFAULT '',
                    webhook_secret TEXT NOT NULL DEFAULT '',
                    events_json TEXT NOT NULL DEFAULT '["service_down","disk_high","traffic_threshold","certificate_expiry","device_quota","update_failed","backup_failed","security_lockout","argo_domain_changed"]',
                    disk_threshold INTEGER NOT NULL DEFAULT 90,
                    traffic_threshold INTEGER NOT NULL DEFAULT 90,
                    updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS notification_log (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at TEXT NOT NULL,
                    event TEXT NOT NULL,
                    severity TEXT NOT NULL,
                    title TEXT NOT NULL,
                    detail TEXT NOT NULL DEFAULT '',
                    delivered INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS notification_dedup (
                    event_key TEXT PRIMARY KEY,
                    sent_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS webauthn_credentials (
                    credential_id TEXT PRIMARY KEY,
                    admin_id INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    public_key_pem BLOB NOT NULL,
                    algorithm INTEGER NOT NULL,
                    sign_count INTEGER NOT NULL DEFAULT 0,
                    transports TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    last_used_at TEXT
                );
                CREATE TABLE IF NOT EXISTS webauthn_challenges (
                    id TEXT PRIMARY KEY,
                    challenge TEXT NOT NULL,
                    ceremony TEXT NOT NULL,
                    admin_id INTEGER REFERENCES admins(id) ON DELETE CASCADE,
                    remote_ip TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    version INTEGER PRIMARY KEY,
                    applied_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS sessions_expiry_idx ON sessions(expires_at);
                CREATE INDEX IF NOT EXISTS audit_created_idx ON audit_log(created_at);
                CREATE INDEX IF NOT EXISTS system_samples_bucket_idx ON system_samples(bucket);
                CREATE INDEX IF NOT EXISTS notification_log_created_idx ON notification_log(created_at);
                """
            )
            now = utc_now()
            db.execute(
                "INSERT OR IGNORE INTO server_traffic_policy("
                "id,cycle_started_at,updated_at) VALUES(1,?,?)",
                (now, now),
            )
            db.execute(
                "INSERT OR IGNORE INTO notification_settings(id,updated_at) VALUES(1,?)",
                (now,),
            )
            notification_row = db.execute(
                "SELECT events_json FROM notification_settings WHERE id=1"
            ).fetchone()
            try:
                notification_events = json.loads(notification_row["events_json"] if notification_row else "[]")
            except (TypeError, json.JSONDecodeError):
                notification_events = []
            if "argo_domain_changed" not in notification_events:
                notification_events.append("argo_domain_changed")
                db.execute(
                    "UPDATE notification_settings SET events_json=?,updated_at=? WHERE id=1",
                    (json.dumps(notification_events, separators=(",", ":")), now),
                )
            admin_columns = {
                row["name"] for row in db.execute("PRAGMA table_info(admins)").fetchall()
            }
            if "totp_secret" not in admin_columns:
                db.execute("ALTER TABLE admins ADD COLUMN totp_secret TEXT NOT NULL DEFAULT ''")
            if "totp_pending_secret" not in admin_columns:
                db.execute("ALTER TABLE admins ADD COLUMN totp_pending_secret TEXT NOT NULL DEFAULT ''")
            if "totp_enabled" not in admin_columns:
                db.execute("ALTER TABLE admins ADD COLUMN totp_enabled INTEGER NOT NULL DEFAULT 0")
            columns = {
                row["name"] for row in db.execute("PRAGMA table_info(devices)").fetchall()
            }
            added_uploaded = "uploaded_bytes" not in columns
            added_downloaded = "downloaded_bytes" not in columns
            if added_uploaded:
                db.execute(
                    "ALTER TABLE devices ADD COLUMN uploaded_bytes INTEGER NOT NULL DEFAULT 0"
                )
            if added_downloaded:
                db.execute(
                    "ALTER TABLE devices ADD COLUMN downloaded_bytes INTEGER NOT NULL DEFAULT 0"
                )
            if "traffic_updated_at" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN traffic_updated_at TEXT")
            if "quota_reached_at" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN quota_reached_at TEXT")
            # B2/E15：到期日自然越过清扫标记（collector 检测到越过即触发 sync，幂等）
            if "expiry_enforced_at" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN expiry_enforced_at TEXT")
            if "next_reset_at" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN next_reset_at TEXT")
            if "reset_anchor_day" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN reset_anchor_day INTEGER NOT NULL DEFAULT 0")
            if "reset_max" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN reset_max INTEGER NOT NULL DEFAULT 0")
            if "reset_count" not in columns:
                db.execute("ALTER TABLE devices ADD COLUMN reset_count INTEGER NOT NULL DEFAULT 0")
            if "group_id" not in columns:
                db.execute(
                    "ALTER TABLE devices ADD COLUMN group_id INTEGER REFERENCES device_groups(id) ON DELETE SET NULL"
                )
            db.execute("CREATE INDEX IF NOT EXISTS devices_group_idx ON devices(group_id)")
            if added_uploaded or added_downloaded:
                db.execute(
                    "UPDATE devices SET downloaded_bytes=used_bytes "
                    "WHERE used_bytes>0 AND uploaded_bytes=0 AND downloaded_bytes=0"
                )
            db.execute(
                "INSERT OR IGNORE INTO schema_migrations(version,applied_at) VALUES(710,?)",
                (now,),
            )
        os.chmod(self.path, 0o600)

    def audit(self, actor: str, action: str, target: str, remote_ip: str, detail: str = "") -> None:
        with self.connect() as db:
            db.execute(
                "INSERT INTO audit_log(created_at,actor,action,target,remote_ip,detail) VALUES(?,?,?,?,?,?)",
                (utc_now(), actor[:64], action[:64], target[:128], remote_ip[:64], detail[:512]),
            )
        self.prune_history()

    def prune_history(self, *, force: bool = False) -> None:
        """Hourly retention and hard row caps for long-running installations."""
        now = epoch_now()
        if not force and now - self._last_history_cleanup < 3600:
            return
        if not self._history_cleanup_lock.acquire(blocking=False):
            return
        try:
            if not force and now - self._last_history_cleanup < 3600:
                return
            audit_cutoff = datetime.fromtimestamp(
                now - AUDIT_RETENTION_SECONDS, timezone.utc
            ).replace(microsecond=0).isoformat()
            notification_cutoff = datetime.fromtimestamp(
                now - NOTIFICATION_RETENTION_SECONDS, timezone.utc
            ).replace(microsecond=0).isoformat()
            with self.connect() as db:
                db.execute("DELETE FROM audit_log WHERE created_at<?", (audit_cutoff,))
                db.execute(
                    "DELETE FROM audit_log WHERE id NOT IN "
                    "(SELECT id FROM audit_log ORDER BY id DESC LIMIT ?)",
                    (MAX_AUDIT_ROWS,),
                )
                db.execute(
                    "DELETE FROM notification_log WHERE created_at<?",
                    (notification_cutoff,),
                )
                db.execute(
                    "DELETE FROM notification_log WHERE id NOT IN "
                    "(SELECT id FROM notification_log ORDER BY id DESC LIMIT ?)",
                    (MAX_NOTIFICATION_ROWS,),
                )
                db.execute(
                    "DELETE FROM notification_dedup WHERE sent_at<?",
                    (now - NOTIFICATION_RETENTION_SECONDS,),
                )
                db.execute("DELETE FROM sessions WHERE expires_at<=?", (now,))
                db.execute("DELETE FROM webauthn_challenges WHERE expires_at<=?", (now,))
                db.execute(
                    "DELETE FROM remote_failures WHERE failed_at<?",
                    (now - REMOTE_FAIL_WINDOW,),
                )
            self._last_history_cleanup = now
        finally:
            self._history_cleanup_lock.release()


def network_interfaces() -> list[str]:
    try:
        return sorted(
            item.name
            for item in Path("/sys/class/net").iterdir()
            if item.name != "lo" and (item / "statistics/rx_bytes").is_file()
        )
    except OSError:
        return []


def default_network_interface() -> str:
    try:
        lines = Path("/proc/net/route").read_text(encoding="ascii").splitlines()[1:]
        for line in lines:
            fields = line.split()
            if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 0x1:
                return fields[0]
    except (OSError, ValueError):
        pass
    interfaces = network_interfaces()
    return interfaces[0] if interfaces else ""


def read_network_counters(configured_interface: str = "") -> tuple[str, int, int]:
    interface = configured_interface if configured_interface in network_interfaces() else default_network_interface()
    if not interface or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", interface):
        raise OSError("未找到可统计的公网网卡")
    base = Path("/sys/class/net") / interface / "statistics"
    rx = int((base / "rx_bytes").read_text(encoding="ascii").strip())
    tx = int((base / "tx_bytes").read_text(encoding="ascii").strip())
    if rx < 0 or tx < 0:
        raise OSError("网卡计数器无效")
    return interface, rx, tx


def server_traffic_snapshot(store: Store) -> dict[str, Any]:
    with store.connect() as db:
        row = db.execute("SELECT * FROM server_traffic_policy WHERE id=1").fetchone()
    if row is None:
        return {}
    item = dict(row)
    mode = item["count_mode"] if item["count_mode"] in SERVER_TRAFFIC_MODES else "both"
    received = max(0, int(item["received_bytes"] or 0))
    transmitted = max(0, int(item["transmitted_bytes"] or 0))
    initial = max(0, int(item["initial_used_bytes"] or 0))
    counted = transmitted if mode == "tx" else received if mode == "rx" else received + transmitted
    used = initial + counted
    quota = max(0, int(item["quota_bytes"] or 0))
    return {
        "quota_bytes": quota,
        "count_mode": mode,
        "interface_name": item["interface_name"] or "",
        "active_interface": item["last_interface"] or "",
        "received_bytes": received,
        "transmitted_bytes": transmitted,
        "initial_used_bytes": initial,
        "used_bytes": used,
        "remaining_bytes": max(0, quota - used) if quota else None,
        "percent": min(100.0, used / quota * 100.0) if quota else 0.0,
        "exhausted": bool(quota and used >= quota),
        "cycle_started_at": item["cycle_started_at"],
        "updated_at": item["updated_at"],
        "available": bool(item["last_interface"]),
        "interfaces": network_interfaces(),
    }


class TrafficCollector:
    def __init__(self, state: "NexusState"):
        self.state = state
        self.collect_lock = threading.Lock()
        self.status_lock = threading.Lock()
        self.stop_event = threading.Event()
        self.thread: threading.Thread | None = None
        self.available = False
        self.status = "starting"
        self.last_error = ""
        self.last_success = ""
        self.upload_rate = 0.0
        self.download_rate = 0.0
        self.last_poll_monotonic: float | None = None
        self.last_system_sample = 0

    def collect_system_sample(self) -> None:
        now = epoch_now()
        if now - self.last_system_sample < SYSTEM_SAMPLE_SECONDS:
            return
        self.last_system_sample = now
        try:
            sample = SERVER_STATS.refresh()
            disks = sample.get("disks") or []
            disk_percent = max((float(item.get("percent", 0)) for item in disks), default=0.0)
            load = sample.get("loadavg") or [0]
            bucket = now // SYSTEM_SAMPLE_SECONDS * SYSTEM_SAMPLE_SECONDS
            with self.state.store.connect() as db:
                db.execute(
                    "INSERT INTO system_samples(bucket,cpu_percent,memory_percent,disk_percent,load1) "
                    "VALUES(?,?,?,?,?) ON CONFLICT(bucket) DO UPDATE SET "
                    "cpu_percent=excluded.cpu_percent,memory_percent=excluded.memory_percent,"
                    "disk_percent=excluded.disk_percent,load1=excluded.load1",
                    (
                        bucket,
                        float((sample.get("cpu") or {}).get("percent", 0)),
                        float((sample.get("memory") or {}).get("percent", 0)),
                        disk_percent,
                        float(load[0] if load else 0),
                    ),
                )
                db.execute(
                    "DELETE FROM system_samples WHERE bucket < ?",
                    (now - SYSTEM_RETENTION_SECONDS,),
                )
        except (OSError, ValueError, sqlite3.Error):
            return

    def status_snapshot(self) -> dict[str, Any]:
        with self.status_lock:
            return {
                "available": self.available,
                "status": self.status,
                "last_error": self.last_error,
                "last_success": self.last_success,
                "poll_seconds": TRAFFIC_POLL_SECONDS,
                "upload_rate": round(self.upload_rate),
                "download_rate": round(self.download_rate),
            }

    def set_status(self, available: bool, status: str, error: str = "") -> None:
        with self.status_lock:
            self.available = available
            self.status = status
            self.last_error = error[:240]
            if available:
                self.last_success = utc_now()

    def collect_server_traffic(self) -> None:
        """Persist real host-interface RX/TX deltas for carrier-package monitoring."""
        try:
            with self.state.store.connect() as db:
                policy = db.execute(
                    "SELECT interface_name,last_interface,last_rx_counter,last_tx_counter "
                    "FROM server_traffic_policy WHERE id=1"
                ).fetchone()
                if policy is None:
                    return
                interface, rx, tx = read_network_counters(str(policy["interface_name"] or ""))
                last_interface = str(policy["last_interface"] or "")
                last_rx = policy["last_rx_counter"]
                last_tx = policy["last_tx_counter"]
                rx_delta = 0
                tx_delta = 0
                if (
                    interface == last_interface
                    and last_rx is not None
                    and last_tx is not None
                    and rx >= int(last_rx)
                    and tx >= int(last_tx)
                ):
                    rx_delta = rx - int(last_rx)
                    tx_delta = tx - int(last_tx)
                db.execute(
                    "UPDATE server_traffic_policy SET last_interface=?,"
                    "received_bytes=received_bytes+?,transmitted_bytes=transmitted_bytes+?,"
                    "last_rx_counter=?,last_tx_counter=?,updated_at=? WHERE id=1",
                    (interface, rx_delta, tx_delta, rx, tx, utc_now()),
                )
        except (OSError, sqlite3.Error, ValueError):
            # 设备级流量统计不能因为宿主机网卡不可读而中断。
            return

    def apply_scheduled_resets(self, trigger_sync: bool) -> None:
        if not trigger_sync:
            return
        today = datetime.now(timezone.utc).date()
        reset_devices: list[tuple[str, str, int, int]] = []
        try:
            with self.state.store.connect() as db:
                rows = db.execute(
                    "SELECT id,name,next_reset_at,reset_anchor_day,reset_max,reset_count,expires_at "
                    "FROM devices WHERE next_reset_at IS NOT NULL AND next_reset_at<>'' "
                    "AND reset_max>0 AND reset_count<reset_max"
                ).fetchall()
                for row in rows:
                    due = parse_date(row["next_reset_at"] or "")
                    if due is None or due > today:
                        continue
                    expires = parse_date(row["expires_at"] or "")
                    if expires is not None and expires < today:
                        continue
                    anchor = int(row["reset_anchor_day"] or due.day)
                    count = int(row["reset_count"] or 0)
                    old_count = count
                    while due <= today and count < int(row["reset_max"]):
                        count += 1
                        due = add_calendar_month(due, anchor)
                    if count == old_count:
                        continue
                    next_reset = due.isoformat() if count < int(row["reset_max"]) else None
                    db.execute(
                        "UPDATE devices SET used_bytes=0,uploaded_bytes=0,downloaded_bytes=0,"
                        "traffic_updated_at=NULL,quota_reached_at=NULL,next_reset_at=?,"
                        "reset_count=?,updated_at=? WHERE id=?",
                        (next_reset, count, utc_now(), row["id"]),
                    )
                    reset_devices.append((row["id"], row["name"], count - old_count, count))
        except sqlite3.Error:
            return
        if not reset_devices:
            return
        ok, detail = self.state.sync_devices()
        for device_id, name, periods, count in reset_devices:
            self.state.store.audit(
                "system",
                "device_auto_reset" if ok else "device_auto_reset_sync_failed",
                device_id,
                "local",
                f"{name};periods={periods};reset_count={count};{detail}",
            )

    def collect_once(self, trigger_sync: bool = False) -> tuple[bool, str]:
        if not self.collect_lock.acquire(blocking=False):
            return True, "collector_busy"
        quota_crossed: list[str] = []
        try:
            self.collect_server_traffic()
            self.collect_system_sample()
            self.apply_scheduled_resets(trigger_sync)
            if trigger_sync:
                self.state.check_alerts_async()
            raw_counters = query_v2ray_stats(self.state.config.stats_address)
            device_deltas: dict[str, dict[str, int]] = {}
            for name, value in raw_counters.items():
                matched = TRAFFIC_COUNTER_RE.fullmatch(name)
                if not matched or value <= 0:
                    continue
                device_id, direction = matched.groups()
                device_deltas.setdefault(device_id, {"uplink": 0, "downlink": 0})[
                    direction
                ] += value

            now = utc_now()
            poll_now = time.monotonic()
            elapsed = max(0.1, poll_now - self.last_poll_monotonic) if self.last_poll_monotonic else TRAFFIC_POLL_SECONDS
            self.last_poll_monotonic = poll_now
            total_upload = 0
            total_download = 0
            with self.state.store.connect() as db:
                for device_id, delta in device_deltas.items():
                    before = db.execute(
                        "SELECT quota_bytes,used_bytes FROM devices WHERE id=?",
                        (device_id,),
                    ).fetchone()
                    if not before:
                        continue
                    if STATE.config.traffic_mode == "upload":
                        increment = delta["uplink"]
                    else:
                        increment = delta["uplink"] + delta["downlink"]
                    total_upload += delta["uplink"]
                    total_download += delta["downlink"]
                    db.execute(
                        "UPDATE devices SET uploaded_bytes=uploaded_bytes+?, "
                        "downloaded_bytes=downloaded_bytes+?, used_bytes=used_bytes+?, "
                        "traffic_updated_at=? WHERE id=?",
                        (delta["uplink"], delta["downlink"], increment, now, device_id),
                    )
                    if (
                        before["quota_bytes"] > 0
                        and before["used_bytes"] < before["quota_bytes"]
                        and before["used_bytes"] + increment >= before["quota_bytes"]
                    ):
                        quota_crossed.append(device_id)
                        db.execute(
                            "UPDATE devices SET quota_reached_at=? WHERE id=? AND quota_reached_at IS NULL",
                            (now, device_id),
                        )
                if total_upload or total_download:
                    bucket = epoch_now() // TRAFFIC_BUCKET_SECONDS * TRAFFIC_BUCKET_SECONDS
                    db.execute(
                        "INSERT INTO traffic_samples(bucket,uploaded_bytes,downloaded_bytes) "
                        "VALUES(?,?,?) ON CONFLICT(bucket) DO UPDATE SET "
                        "uploaded_bytes=uploaded_bytes+excluded.uploaded_bytes, "
                        "downloaded_bytes=downloaded_bytes+excluded.downloaded_bytes",
                        (bucket, total_upload, total_download),
                    )
                    db.execute(
                        "DELETE FROM traffic_samples WHERE bucket < ?",
                        (epoch_now() - TRAFFIC_RETENTION_SECONDS,),
                    )
            with self.status_lock:
                self.upload_rate = total_upload / elapsed
                self.download_rate = total_download / elapsed
            self.set_status(True, "collecting")
        except Exception as exc:  # gRPC and SQLite errors are reported to the UI
            error = str(exc) or exc.__class__.__name__
            self.set_status(False, "unavailable", error)
            return False, error
        finally:
            self.collect_lock.release()

        # 额度用尽 QUOTA_AUTO_DELETE_SECONDS 未处理 → 自动删除设备（撤销凭据 + 同步 + 审计）
        auto_deleted: list[dict[str, Any]] = []
        try:
            threshold = (
                datetime.now(timezone.utc) - timedelta(seconds=QUOTA_AUTO_DELETE_SECONDS)
            ).replace(microsecond=0).isoformat()
            with self.state.store.connect() as db:
                rows = db.execute(
                    "SELECT id,name FROM devices WHERE quota_bytes>0 "
                    "AND used_bytes>=quota_bytes AND quota_reached_at IS NOT NULL "
                    "AND quota_reached_at<?",
                    (threshold,),
                ).fetchall()
                for row in rows:
                    db.execute("DELETE FROM devices WHERE id=?", (row["id"],))
                    auto_deleted.append({"id": row["id"], "name": row["name"]})
        except sqlite3.Error:
            auto_deleted = []

        if auto_deleted:
            self.state.sync_devices()
            for device in auto_deleted:
                self.state.store.audit(
                    "system",
                    "device_auto_delete",
                    device["id"],
                    "local",
                    f"额度用尽35天未处理: {device['name']}",
                )

        # 到期日自然越过检测（B2/E15）：与 quota_crossed 同路径。
        # 标记 expiry_enforced_at=expires_at 保证幂等（同一次越过只清扫一次；
        # 若到期日被 PATCH 修改，标记与新到期日不一致 → 再次越过时重新清扫）。
        expiry_crossed: list[str] = []
        try:
            today = datetime.now(timezone.utc).date().isoformat()
            with self.state.store.connect() as db:
                rows = db.execute(
                    "SELECT id FROM devices WHERE enabled=1 AND expires_at IS NOT NULL "
                    "AND expires_at<>'' AND expires_at<? "
                    "AND (expiry_enforced_at IS NULL OR expiry_enforced_at<>expires_at)",
                    (today,),
                ).fetchall()
                for row in rows:
                    db.execute(
                        "UPDATE devices SET expiry_enforced_at=expires_at WHERE id=?",
                        (row["id"],),
                    )
                    expiry_crossed.append(row["id"])
        except sqlite3.Error:
            expiry_crossed = []

        if expiry_crossed and trigger_sync:
            ok, detail = self.state.sync_devices()
            for device_id in expiry_crossed:
                self.state.store.audit(
                    "system",
                    "expiry_enforced" if ok else "expiry_sync_failed",
                    device_id,
                    "local",
                    detail,
                )

        if quota_crossed and trigger_sync:
            ok, detail = self.state.sync_devices()
            for device_id in quota_crossed:
                self.state.store.audit(
                    "system",
                    "quota_enforced" if ok else "quota_sync_failed",
                    device_id,
                    "local",
                    detail,
                )
                self.state.notifications.emit(
                    "device_quota",
                    "warning",
                    "设备额度已用尽",
                    f"设备 {device_id} 已达到流量额度，节点权限已自动停用。",
                    f"device_quota:{device_id}",
                    minimum_interval=24 * 3600,
                )
        return True, ""

    def run(self) -> None:
        while not self.stop_event.is_set():
            self.collect_once(trigger_sync=True)
            self.stop_event.wait(TRAFFIC_POLL_SECONDS)

    def start(self) -> None:
        if self.thread and self.thread.is_alive():
            return
        self.thread = threading.Thread(
            target=self.run,
            name="rr-nexus-traffic",
            daemon=True,
        )
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread:
            self.thread.join(timeout=3)


class NexusState:
    def __init__(self, config: NexusConfig):
        self.config = config
        self.store = Store(config.database)
        self.password_hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=2)
        # Keep unknown-user and wrong-password paths at comparable Argon2 cost
        # so login timing does not reveal whether an administrator name exists.
        self.dummy_password_hash = self.password_hasher.hash(secrets.token_urlsafe(32))
        self.login_failures: dict[str, list[int]] = {}
        self.login_lock = threading.Lock()
        self.sync_lock = threading.Lock()
        # P2 O(n) 修复：同步合并窗口。批量设备操作（如批量删除 N 台）会触发
        # N 次 sync_devices，每次都是全量重建（O(设备数)）；合并后只执行
        # 首尾两次，中间请求直接标记 pending 秒回，避免串行重建把面板拖到 504。
        self._sync_state_lock = threading.Lock()
        self._sync_inflight = False
        self._sync_pending = False
        self.traffic = TrafficCollector(self)
        self.notifications = NotificationManager(self.store)
        self._alert_lock = threading.Lock()
        self._last_alert_check = 0

    def check_alerts_async(self) -> None:
        now = epoch_now()
        if now - self._last_alert_check < 60 or not self._alert_lock.acquire(blocking=False):
            return
        self._last_alert_check = now

        def run() -> None:
            try:
                self.evaluate_alerts()
            finally:
                self._alert_lock.release()

        threading.Thread(target=run, name="rr-nexus-alerts", daemon=True).start()

    def evaluate_alerts(self) -> None:
        cfg = self.notifications.settings(masked=False)
        if not cfg.get("enabled"):
            return
        singbox_config = Path("/etc/sing-box/config.json")
        node_expected = False
        if singbox_config.is_file():
            try:
                node_expected = bool(json.loads(singbox_config.read_text(encoding="utf-8")).get("inbounds"))
            except (OSError, ValueError, json.JSONDecodeError):
                node_expected = True
        if node_expected:
            try:
                service = subprocess.run(
                    ["systemctl", "is-active", "sing-box"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                ).stdout.strip()
                if service != "active":
                    self.notifications.emit(
                        "service_down", "critical", "Sing-box 服务异常",
                        f"当前状态：{service or 'unknown'}。建议先运行 rr doctor。",
                        "service_down:sing-box", minimum_interval=900,
                    )
            except (OSError, subprocess.TimeoutExpired):
                pass
        try:
            stats = SERVER_STATS.refresh()
            maximum = max(
                (float(item.get("percent", 0)) for item in stats.get("disks", [])),
                default=0.0,
            )
            if maximum >= int(cfg.get("disk_threshold", 90)):
                self.notifications.emit(
                    "disk_high", "warning", "服务器磁盘空间不足",
                    f"最高磁盘使用率 {maximum:.1f}%。", "disk_high", minimum_interval=3600,
                )
        except (OSError, ValueError):
            pass
        plan = server_traffic_snapshot(self.store)
        quota = int(plan.get("quota_bytes", 0) or 0)
        used = int(plan.get("used_bytes", 0) or 0)
        if quota > 0:
            percent = used * 100 / quota
            if percent >= int(cfg.get("traffic_threshold", 90)):
                self.notifications.emit(
                    "traffic_threshold", "warning", "服务器套餐流量接近上限",
                    f"当前已使用 {percent:.1f}%（{used}/{quota} bytes）。",
                    f"traffic_threshold:{int(percent // 5) * 5}", minimum_interval=6 * 3600,
                )
        domain = (self.config.domain or "").strip()
        certificate_targets: list[tuple[str, Path]] = []
        if self.config.mode == "public" and domain and domain != "ip" and not _is_ip_address(domain):
            certificate_targets.append((domain, Path(f"/etc/letsencrypt/live/{domain}/cert.pem")))
        naive_cert = Path("/etc/rr-naive/fullchain.pem")
        if naive_cert.is_file():
            certificate_targets.append(("NaiveProxy", naive_cert))
        for certificate_name, cert in certificate_targets:
            try:
                result = subprocess.run(
                    ["openssl", "x509", "-enddate", "-noout", "-in", str(cert)],
                    capture_output=True, text=True, timeout=3, check=False,
                )
                if result.returncode == 0 and "=" in result.stdout:
                    expires = datetime.strptime(
                        result.stdout.strip().split("=", 1)[1], "%b %d %H:%M:%S %Y %Z"
                    ).replace(tzinfo=timezone.utc)
                    days = int((expires - datetime.now(timezone.utc)).total_seconds() // 86400)
                    if days <= 14:
                        self.notifications.emit(
                            "certificate_expiry", "critical" if days <= 3 else "warning",
                            "TLS 证书即将到期", f"{certificate_name} 的证书剩余 {days} 天。",
                            f"certificate_expiry:{certificate_name}:{max(days, 0) // 3}", minimum_interval=24 * 3600,
                        )
            except (OSError, ValueError, subprocess.TimeoutExpired):
                pass

    def _lockout_for_count(self, count: int, window: int) -> int:
        # 指数退避：5→30分钟，8→2小时，12→24小时，16+→72小时
        if count < LOGIN_LIMIT:
            return 0
        if count < 8:
            return max(1, window - 0)
        if count < 12:
            return 2 * 3600
        if count < 16:
            return 24 * 3600
        return 72 * 3600

    def client_is_locked(self, remote_ip: str, username: str = "") -> tuple[bool, int]:
        now = epoch_now()
        with self.login_lock:
            with self.store.connect() as db:
                ip_attempts = [
                    row[0] for row in db.execute(
                        "SELECT failed_at FROM login_failures WHERE remote_ip=? AND failed_at>? ORDER BY failed_at",
                        (remote_ip, now - LOGIN_WINDOW),
                    ).fetchall()
                ]
                retry_ip = 0
                if len(ip_attempts) >= LOGIN_LIMIT:
                    retry_ip = self._lockout_for_count(len(ip_attempts), LOGIN_WINDOW) - (now - ip_attempts[0])
                    retry_ip = max(1, min(retry_ip, 72 * 3600))
                account_attempts = []
                if username:
                    account_attempts = [
                        row[0] for row in db.execute(
                            "SELECT failed_at FROM login_failures WHERE username=? AND failed_at>? ORDER BY failed_at",
                            (username, now - LOGIN_ACCOUNT_WINDOW),
                        ).fetchall()
                    ]
                    if len(account_attempts) >= LOGIN_ACCOUNT_LIMIT:
                        retry_acc = LOGIN_ACCOUNT_WINDOW - (now - account_attempts[0])
                        retry_ip = max(retry_ip, max(1, retry_acc))
                # 锁定达成时记一次审计事件（幂等：距上次告警超过窗口才重复记录）
                if retry_ip > 0:
                    last_warn = getattr(self, "_last_lockout_audit", 0)
                    if now - last_warn > LOGIN_WINDOW:
                        self._last_lockout_audit = now
                        try:
                            with self.store.connect() as db2:
                                db2.execute(
                                    "INSERT INTO audit_log(created_at,actor,action,target,remote_ip,detail) VALUES(?,?,?,?,?,?)",
                                    (utc_now(), "system", "bruteforce_locked", username or "-", remote_ip, "login bruteforce lockout"),
                                )
                        except Exception:
                            pass
                        threading.Thread(
                            target=self.notifications.emit,
                            args=(
                                "security_lockout", "critical", "RR Nexus 登录已锁定",
                                f"来源 {remote_ip} 对账号 {username or '-'} 触发了防爆破锁定。",
                                f"security_lockout:{remote_ip}", LOGIN_WINDOW,
                            ),
                            daemon=True,
                            name="rr-security-alert",
                        ).start()
                return (retry_ip > 0), retry_ip

    def record_login_failure(self, remote_ip: str, username: str = "") -> None:
        with self.login_lock:
            with self.store.connect() as db:
                db.execute(
                    "INSERT INTO login_failures(username, remote_ip, failed_at) VALUES(?,?,?)",
                    (username or "-", remote_ip, epoch_now()),
                )
                # 清理过期记录，防表膨胀
                db.execute(
                    "DELETE FROM login_failures WHERE failed_at < ?",
                    (epoch_now() - max(LOGIN_WINDOW, LOGIN_ACCOUNT_WINDOW) - 3600,),
                )

    def clear_login_failures(self, remote_ip: str = "", username: str = "") -> None:
        with self.login_lock:
            with self.store.connect() as db:
                if remote_ip:
                    db.execute("DELETE FROM login_failures WHERE remote_ip=?", (remote_ip,))
                if username:
                    db.execute("DELETE FROM login_failures WHERE username=?", (username,))

    def login_fail_delay(self, remote_ip: str) -> float:
        # 渐进延迟：失败次数越多响应越慢，拖垮在线爆破速度
        try:
            with self.login_lock:
                with self.store.connect() as db:
                    row = db.execute(
                        "SELECT COUNT(*) FROM login_failures WHERE remote_ip=? AND failed_at>?",
                        (remote_ip, epoch_now() - LOGIN_WINDOW),
                    ).fetchone()
            n = row[0] if row else 0
        except Exception:
            n = 0
        return min(LOGIN_FAIL_DELAY + n * LOGIN_FAIL_DELAY_STEP, LOGIN_FAIL_DELAY_MAX)

    def authenticate_with_method(self, username: str, password: str) -> tuple[sqlite3.Row | None, str]:
        with self.store.connect() as db:
            admin = db.execute("SELECT * FROM admins WHERE username = ?", (username,)).fetchone()
            if admin:
                try:
                    if self.password_hasher.verify(admin["password_hash"], password):
                        if self.password_hasher.check_needs_rehash(admin["password_hash"]):
                            db.execute(
                                "UPDATE admins SET password_hash=?, updated_at=? WHERE id=?",
                                (self.password_hasher.hash(password), utc_now(), admin["id"]),
                            )
                        return admin, "password"
                except (VerifyMismatchError, InvalidHash):
                    pass

                recovery_hash = sha256_text(password.strip().upper())
                recovery = db.execute(
                    "UPDATE recovery_codes SET used_at=? WHERE code_hash=? AND admin_id=? AND used_at IS NULL",
                    (utc_now(), recovery_hash, admin["id"]),
                )
                if recovery.rowcount == 1:
                    return admin, "recovery"
            else:
                try:
                    self.password_hasher.verify(self.dummy_password_hash, password)
                except (VerifyMismatchError, InvalidHash):
                    pass
        return None, ""

    def authenticate(self, username: str, password: str) -> sqlite3.Row | None:
        return self.authenticate_with_method(username, password)[0]

    def create_webauthn_challenge(
        self, ceremony: str, remote_ip: str, admin_id: int | None = None
    ) -> tuple[str, str]:
        challenge_id = secrets.token_urlsafe(24)
        challenge = b64url_encode(secrets.token_bytes(32))
        now = epoch_now()
        with self.store.connect() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM webauthn_challenges WHERE expires_at<=?", (now,))
            if ceremony == "login":
                recent = db.execute(
                    "SELECT COUNT(*) FROM webauthn_challenges WHERE ceremony='login' "
                    "AND remote_ip=? AND created_at>?",
                    (remote_ip, now - 60),
                ).fetchone()[0]
                if int(recent) >= 20:
                    raise ValueError("passkey_challenge_rate_limited")
            db.execute(
                "INSERT INTO webauthn_challenges(id,challenge,ceremony,admin_id,remote_ip,created_at,expires_at) "
                "VALUES(?,?,?,?,?,?,?)",
                (challenge_id, challenge, ceremony, admin_id, remote_ip, now, now + 300),
            )
        return challenge_id, challenge

    def consume_webauthn_challenge(
        self, challenge_id: str, ceremony: str, remote_ip: str
    ) -> sqlite3.Row | None:
        now = epoch_now()
        with self.store.connect() as db:
            # Serialize SELECT+DELETE so one WebAuthn ceremony cannot be
            # consumed twice by concurrent requests.
            db.execute("BEGIN IMMEDIATE")
            row = db.execute(
                "SELECT * FROM webauthn_challenges WHERE id=? AND ceremony=? AND remote_ip=? AND expires_at>?",
                (challenge_id, ceremony, remote_ip, now),
            ).fetchone()
            if row:
                db.execute("DELETE FROM webauthn_challenges WHERE id=?", (challenge_id,))
        return row

    def create_session(self, admin_id: int, remote_ip: str) -> tuple[str, str]:
        token = secrets.token_urlsafe(36)
        csrf = secrets.token_urlsafe(24)
        now = epoch_now()
        with self.store.connect() as db:
            db.execute("DELETE FROM sessions WHERE expires_at <= ?", (now,))
            db.execute(
                "INSERT INTO sessions(token_hash,admin_id,csrf_token,remote_ip,created_at,expires_at) VALUES(?,?,?,?,?,?)",
                (sha256_text(token), admin_id, csrf, remote_ip, now, now + SESSION_HOURS * 3600),
            )
        return token, csrf

    def session(self, token: str) -> sqlite3.Row | None:
        if not token:
            return None
        now = epoch_now()
        with self.store.connect() as db:
            row = db.execute(
                "SELECT sessions.*,admins.username FROM sessions JOIN admins ON admins.id=sessions.admin_id WHERE token_hash=? AND expires_at>?",
                (sha256_text(token), now),
            ).fetchone()
        return row

    def sync_devices(self) -> tuple[bool, str]:
        # P2 O(n) 合并窗口：已有同步在执行时，本次请求只标记 pending 秒回，
        # 由正在执行的同步完成后 drain（再跑一轮兜住期间的所有变更）。
        with self._sync_state_lock:
            if self._sync_inflight:
                self._sync_pending = True
                return True, "queued"
            self._sync_inflight = True
        try:
            while True:
                ok, detail = self._do_sync_once()
                if not ok:
                    return False, detail
                with self._sync_state_lock:
                    if not self._sync_pending:
                        break
                    self._sync_pending = False
        finally:
            with self._sync_state_lock:
                self._sync_inflight = False

        return True, ""

    def _do_sync_once(self) -> tuple[bool, str]:
        with self.sync_lock:
            try:
                result = subprocess.run(
                    ["/usr/local/bin/rr", "--sync-devices"],
                    text=True,
                    capture_output=True,
                    timeout=60,
                    check=False,
                    env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
                )
            except (OSError, subprocess.TimeoutExpired) as exc:
                return False, str(exc)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "sync failed").strip().splitlines()[-1]
            return False, detail[:240]
        return True, ""


# ---------- 服务器实时状态（零依赖 /proc 采集） ----------
class ServerStatsSampler:
    """每秒差分采样：CPU/内存/Swap/磁盘/网络/负载/开机时长。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._last_cpu = {}
        self._last_cpu_ts = 0.0
        self._last_net = {}
        self._last_net_ts = 0.0
        self._last_disk_ts = 0.0
        self._last_disk = {}
        self._cpu_cores = 1
        self._cpu_model = ""
        self._mounted = []

    def _read_proc(self, path):
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                return f.read()
        except OSError:
            return ""

    def refresh(self):
        with self._lock:
            return self._sample()

    def _sample(self):
        now = time.monotonic()
        out = {}

        stat_txt = self._read_proc("/proc/stat")
        cpu_total = 0
        cpu_idle = 0
        user = nice = system = iowait = 0
        for line in stat_txt.splitlines():
            parts = line.split()
            if parts and parts[0] == "cpu":
                vals = [int(v) for v in parts[1:9]]
                cpu_total = sum(vals)
                cpu_idle = vals[3] + vals[4]
                user, nice, system, iowait = vals[0], vals[1], vals[2], vals[4]
                break
        cpu_pct = 0.0
        detail_pct = {"user": 0.0, "sys": 0.0, "io": 0.0, "idle": 100.0}
        if self._last_cpu and now - self._last_cpu_ts > 0.2:
            d_total = cpu_total - self._last_cpu["total"]
            if d_total > 0:
                cpu_pct = round(100.0 * (d_total - (cpu_idle - self._last_cpu["idle"])) / d_total, 1)
                detail_pct = {
                    "user": round(100.0 * (user - self._last_cpu["user"]) / d_total, 1),
                    "sys": round(100.0 * (system - self._last_cpu["sys"]) / d_total, 1),
                    "io": round(100.0 * (iowait - self._last_cpu["io"]) / d_total, 1),
                    "idle": round(100.0 * (cpu_idle - self._last_cpu["idle"]) / d_total, 1),
                }
        self._last_cpu = {"total": cpu_total, "idle": cpu_idle, "user": user, "sys": system, "io": iowait}
        self._last_cpu_ts = now

        if not self._cpu_model:
            cpuinfo = self._read_proc("/proc/cpuinfo")
            models = {}
            proc_count = 0
            for line in cpuinfo.splitlines():
                if line.startswith("model name"):
                    name = line.split(":", 1)[1].strip()
                    models[name] = models.get(name, 0) + 1
                elif line.startswith("processor"):
                    proc_count += 1
            if proc_count:
                self._cpu_cores = proc_count
            if models:
                self._cpu_model = max(models, key=models.get)
        out["cpu"] = {"percent": cpu_pct, "detail": detail_pct, "model": self._cpu_model, "cores": self._cpu_cores}

        meminfo = self._read_proc("/proc/meminfo")
        mem = {}
        for line in meminfo.splitlines():
            if ":" in line:
                key, rest = line.split(":", 1)
                tok = rest.strip().split()
                if tok:
                    mem[key.strip()] = int(tok[0]) * 1024
        total = mem.get("MemTotal", 0)
        free = mem.get("MemFree", 0)
        avail = mem.get("MemAvailable", 0)
        cached = mem.get("Cached", 0)
        swap_total = mem.get("SwapTotal", 0)
        swap_free = mem.get("SwapFree", 0)
        out["memory"] = {
            "total": total, "free": free, "available": avail, "cached": cached,
            "used": total - avail,
            "percent": round(100.0 * (total - avail) / total, 1) if total else 0.0,
            "free_pct": round(100.0 * free / total, 1) if total else 0.0,
            "avail_pct": round(100.0 * avail / total, 1) if total else 0.0,
        }
        out["swap"] = {
            "total": swap_total, "used": swap_total - swap_free,
            "percent": round(100.0 * (swap_total - swap_free) / swap_total, 1) if swap_total else 0.0,
            "cached_pct": round(100.0 * cached / total, 1) if total else 0.0,
        }

        uptime_txt = self._read_proc("/proc/uptime")
        up_sec = float(uptime_txt.split()[0]) if uptime_txt.split() else 0.0
        loadavg_txt = self._read_proc("/proc/loadavg")
        load = loadavg_txt.split()[:3] if loadavg_txt.split() else ["0", "0", "0"]
        out["uptime_seconds"] = int(up_sec)
        out["loadavg"] = [round(float(v), 2) for v in load]
        out["hostname"] = socket.gethostname()

        osrel = self._read_proc("/etc/os-release")
        pretty = ""
        for line in osrel.splitlines():
            if line.startswith("PRETTY_NAME="):
                pretty = line.split("=", 1)[1].strip().strip('"')
        out["os"] = pretty or platform.system()

        if not self._mounted:
            mounts_txt = self._read_proc("/proc/mounts")
            seen_devs = set()
            for line in mounts_txt.splitlines():
                parts = line.split()
                if len(parts) >= 2 and parts[0].startswith("/dev/") and not parts[0].startswith("/dev/loop"):
                    if parts[0] in seen_devs:
                        continue
                    seen_devs.add(parts[0])
                    self._mounted.append((parts[0], parts[1]))
        diskstats_txt = self._read_proc("/proc/diskstats")
        disk_io = {}
        for line in diskstats_txt.splitlines():
            parts = line.split()
            if len(parts) >= 10 and parts[2].startswith(("vd", "sd", "nvme")):
                disk_io[parts[2]] = (int(parts[5]) * 512, int(parts[9]) * 512)
        disk_dt = max(0.001, now - self._last_disk_ts)
        disks = []
        for dev_name, mp in self._mounted[:6]:
            try:
                st = os.statvfs(mp)
                total = st.f_blocks * st.f_frsize
                used = (st.f_blocks - st.f_bfree) * st.f_frsize
                base = dev_name.split("/")[-1]
                read_bps = write_bps = 0
                if base in disk_io and self._last_disk and base in self._last_disk:
                    read_bps = int((disk_io[base][0] - self._last_disk[base][0]) / disk_dt)
                    write_bps = int((disk_io[base][1] - self._last_disk[base][1]) / disk_dt)
                disks.append({
                    "device": dev_name, "mount": mp, "total": total, "used": used,
                    "percent": round(100.0 * used / total, 1) if total else 0.0,
                    "read_bps": max(0, read_bps), "write_bps": max(0, write_bps),
                })
            except OSError:
                continue
        self._last_disk = disk_io
        self._last_disk_ts = now
        out["disks"] = disks

        net_txt = self._read_proc("/proc/net/dev")
        net_now = {}
        for line in net_txt.splitlines()[2:]:
            if ":" not in line:
                continue
            iface, rest = line.split(":", 1)
            parts = rest.split()
            if len(parts) >= 9:
                net_now[iface.strip()] = (int(parts[0]), int(parts[8]))
        net_dt = max(0.001, now - self._last_net_ts)
        nets = []
        for iface, (rx, tx) in net_now.items():
            rx_bps = tx_bps = 0
            if self._last_net and iface in self._last_net:
                rx_bps = int((rx - self._last_net[iface][0]) / net_dt)
                tx_bps = int((tx - self._last_net[iface][1]) / net_dt)
            nets.append({"interface": iface, "rx_bytes": rx, "tx_bytes": tx,
                         "rx_bps": max(0, rx_bps), "tx_bps": max(0, tx_bps)})
        self._last_net = net_now
        self._last_net_ts = now
        self._last_disk_ts = now
        out["networks"] = nets
        return out


# ---------- 流媒体解锁检测（服务器出口 IP，零依赖 urllib，结果缓存） ----------
class MediaUnlockChecker:
    """轻量流媒体解锁检测：访问各平台端点判断解锁状态与地区。"""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._cache: dict[str, object] | None = None
        self._cache_ts = 0.0

    @staticmethod
    def _get(url: str, timeout: int = 8, headers: dict | None = None, allow_redirects: bool = False) -> tuple[int, str, str]:
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None

        opener = urllib.request.build_opener(NoRedirect) if not allow_redirects else urllib.request.build_opener()
        req = urllib.request.Request(url, headers={
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9",
            **(headers or {}),
        })
        try:
            with opener.open(req, timeout=timeout) as resp:
                body = resp.read(4000).decode("utf-8", errors="ignore")
                return resp.status, resp.headers.get("Location", ""), body
        except urllib.error.HTTPError as e:
            return e.code, e.headers.get("Location", "") if e.headers else "", ""
        except Exception:
            return -1, "", ""

    @staticmethod
    def _country_from_location(loc: str) -> str:
        m = re.search(r"(?:region|geo_country|country)[=:]([A-Za-z]{2})", loc, re.I)
        return m.group(1).upper() if m else ""

    def _check_one(self, name: str) -> dict:
        tag, status, text = ("unlock", "❌ 封锁", "n/a")
        region = ""
        if name == "Netflix":
            code, _, body = self._get("https://www.netflix.com/title/81280792", allow_redirects=True)
            if code == 200:
                tag, status = ("unlock", "✅ 解锁（可观看）")
            elif code in (403, 404):
                tag, status = ("blocked", "❌ 封锁 / 非原生")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "Disney+":
            code, loc, _ = self._get("https://www.disneyplus.com/")
            region = self._country_from_location(loc)
            if code in (301, 302, 303, 307, 308) and region:
                tag, status = ("unlock", f"✅ 解锁（{region}）")
            elif code == 403:
                tag, status = ("blocked", "❌ 封锁")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "YouTube Premium":
            code, _, body = self._get("https://www.youtube.com/premium")
            if code == 200:
                m = re.search(r"premium is available in[^<]*", body, re.I)
                region = m.group(0).split("in")[-1].strip().rstrip(".").title() if m else ""
                tag, status = ("unlock", f"✅ 可用（{region or '地区未识别'}）")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "ChatGPT":
            # 数据中心 IP 直接访问 chatgpt.com 常被 CF 拦截（403）误判为地区封锁；
            # cdn-cgi/trace 返回出口真实信息：200+loc=US 即 CF 放行且出口在美国（OpenAI 支持区）
            code, _, body = self._get("https://chatgpt.com/cdn-cgi/trace", timeout=8)
            if code == 200:
                m = re.search(r"(?m)^loc=([A-Za-z]{2})", body)
                region = m.group(1).upper() if m else ""
                if region == "US":
                    tag, status = ("unlock", "✅ 可用（美国）")
                elif region:
                    tag, status = ("unlock", f"✅ 可用（{region}）")
                else:
                    tag, status = ("unlock", "✅ 可用")
            elif code == 403:
                tag, status = ("blocked", "❌ 数据中心 IP 受限")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "TikTok":
            code, loc, _ = self._get("https://www.tiktok.com/")
            region = self._country_from_location(loc)
            if code in (301, 302, 307, 308) and region:
                tag, status = ("unlock", f"✅ 可用（{region}）")
            elif code in (200, 403):
                tag, status = ("unlock", "✅ 可用")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "BBC iPlayer":
            code, _, _ = self._get("https://open.live.bbc.co.uk/mediaselector/5/select/version/2.0/mediaset/pc/vpid/b0b1xq2l/atk/undefined/asn/undefined")
            if code == 200:
                tag, status = ("unlock", "✅ 解锁")
            elif code in (403, 404):
                tag, status = ("blocked", "❌ 封锁")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "Prime Video":
            code, loc, _ = self._get("https://www.primevideo.com/")
            region = self._country_from_location(loc)
            if code in (301, 302, 307, 308) and region:
                tag, status = ("unlock", f"✅ 可用（{region}）")
            elif code == 200:
                tag, status = ("unlock", "✅ 可用")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "Max / HBO":
            code, loc, _ = self._get("https://www.max.com/")
            region = self._country_from_location(loc)
            if code in (301, 302, 307, 308) and region:
                tag, status = ("unlock", f"✅ 可用（{region}）")
            elif code == 403:
                tag, status = ("blocked", "❌ 封锁")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "Spotify":
            code, _, body = self._get("https://spclient.wg.spotify.com/signup/public/v1/account")
            if code == 200:
                tag, status = ("unlock", "✅ 可注册")
            elif code == 403:
                m = re.search(r"\"country\":\s*\"([A-Z]{2})\"", body)
                region = m.group(1) if m else ""
                tag, status = ("unlock", f"✅ 可用（{region}）") if region else ("unknown", "⚠ 无法判断")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        elif name == "Steam 商店":
            code, _, body = self._get("https://store.steampowered.com/", allow_redirects=True)
            if code == 200:
                m = re.search(r"countrycode\"?[:=]\s*\"?([A-Z]{2})", body)
                region = m.group(1).upper() if m else ""
                tag, status = ("unlock", f"✅ 可访问（{region or '货币区未识别'}）")
            else:
                tag, status = ("unknown", "⚠ 无法判断")
        return {"name": name, "status": tag, "text": status, "region": region}

    def check(self, refresh: bool = False) -> dict:
        with self._lock:
            now = time.monotonic()
            if self._cache is not None and not refresh and now - self._cache_ts < 600:
                return self._cache
        names = ["Netflix", "Disney+", "YouTube Premium", "ChatGPT", "TikTok", "BBC iPlayer", "Prime Video", "Max / HBO", "Spotify", "Steam 商店"]
        with ThreadPoolExecutor(max_workers=5) as pool:
            results = list(pool.map(self._check_one, names))
        unlock_count = sum(1 for r in results if r["status"] == "unlock")
        payload = {"results": results, "unlock_count": unlock_count, "total": len(names), "checked_at": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")}
        with self._lock:
            self._cache = payload
            self._cache_ts = time.monotonic()
        return payload


MEDIA_UNLOCK = MediaUnlockChecker()

SERVER_STATS = ServerStatsSampler()


STATE: NexusState


def _is_ip_address(value: str) -> bool:
    try:
        ipaddress.ip_address((value or "").strip().strip("[]"))
        return True
    except ValueError:
        return False


def _url_host(value: str) -> str:
    """Return an RFC 3986 host, adding brackets around an IPv6 literal."""
    host = (value or "").strip().strip("[]")
    return "[{}]".format(host) if ":" in host else host


class BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """Threaded HTTP server with finite concurrency and slow-client deadlines."""

    daemon_threads = True
    request_queue_size = 64
    max_active_requests = 64
    request_timeout_seconds = 15

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        self._request_slots = threading.BoundedSemaphore(self.max_active_requests)
        super().__init__(*args, **kwargs)

    def get_request(self):  # type: ignore[no-untyped-def]
        request, address = super().get_request()
        request.settimeout(self.request_timeout_seconds)
        return request, address

    def process_request(self, request, client_address):  # type: ignore[no-untyped-def]
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):  # type: ignore[no-untyped-def]
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class Handler(BaseHTTPRequestHandler):
    server_version = "RR-Nexus"
    sys_version = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        # BaseHTTPRequestHandler 默认记录完整 request line；公开订阅路径含长期
        # token，写进 journal 即构成凭据泄漏。只记录错误状态与来源，不记录 URL。
        try:
            status = int(args[1]) if len(args) >= 2 else 0
        except (TypeError, ValueError):
            status = 0
        if status >= 400:
            sys.stderr.write(
                "{} {} HTTP {}\n".format(
                    self.log_date_time_string(), self.client_address[0], status
                )
            )

    @property
    def remote_ip(self) -> str:
        if STATE.config.mode == "public" and self.client_address[0] in {"127.0.0.1", "::1"}:
            forwarded = self.headers.get("X-Forwarded-For", "").strip()
            # Nginx is configured to replace, not append, this header.  Reject
            # lists and malformed values so an Internet client cannot choose
            # the rate-limit/audit identity by supplying its own XFF value.
            if forwarded and "," not in forwarded and len(forwarded) <= 64:
                try:
                    return str(ipaddress.ip_address(forwarded))
                except ValueError:
                    pass
        return self.client_address[0]

    def security_headers(self, content_type: str) -> None:
        self.send_header("Content-Type", content_type)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self' https:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        self.send_header("Cache-Control", "no-store")
        if STATE.config.mode == "public":
            self.send_header("Strict-Transport-Security", "max-age=31536000; includeSubDomains")

    def read_json_body(self) -> dict:
        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length > MAX_JSON_BODY_BYTES:
                raise RequestBodyTooLarge(MAX_JSON_BODY_BYTES)
            if content_length <= 0:
                return {}
            raw = self.rfile.read(content_length)
            payload = json.loads(raw.decode("utf-8"))
            return payload if isinstance(payload, dict) else {}
        except RequestBodyTooLarge:
            raise
        except (ValueError, UnicodeDecodeError, json.JSONDecodeError, OSError):
            return {}

    def _run_rr_json(self, argv: list[str]) -> dict:
        try:
            result = subprocess.run(
                argv, capture_output=True, text=True, timeout=90, check=False,
                env={"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
            )
            # B1/E12：退出码非零也必须解析 stdout——CLI 拒绝类错误（如
            # ssh_port_protected）以 JSON 输出 + exit 1 表达，丢弃会导致面板误判 200 {}。
            if result.stdout.strip():
                raw = result.stdout.strip()
                try:
                    parsed = json.loads(raw)
                    return parsed if isinstance(parsed, (dict, list)) else {}
                except json.JSONDecodeError:
                    # rr 子命令输出可能带提示文字，取最后一个非空行尝试 JSON 解析
                    for line in reversed([ln for ln in raw.splitlines() if ln.strip()]):
                        try:
                            parsed = json.loads(line)
                            return parsed if isinstance(parsed, (dict, list)) else {}
                        except json.JSONDecodeError:
                            continue
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            pass
        return {}

    def send_json(self, status: int, payload: Any, extra_headers: dict[str, str] | None = None) -> None:
        body = json_compact(payload)
        self.send_response(status)
        self.security_headers("application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def send_bytes(
        self,
        status: int,
        body: bytes,
        content_type: str,
        cache: bool = False,
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        self.send_response(status)
        self.security_headers(content_type)
        if cache:
            self.send_header("Cache-Control", "public, max-age=3600")
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict[str, Any] | None:
        remote_body = getattr(self, "_remote_body", None)
        if remote_body is not None:
            return remote_body
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length > MAX_BODY:
            raise RequestBodyTooLarge(MAX_BODY)
        if length <= 0:
            return None
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    def cookie_token(self) -> str:
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except Exception:
            return ""
        morsel = cookie.get("rr_nexus_session")
        return morsel.value if morsel else ""

    def current_session(self) -> sqlite3.Row | None:
        return STATE.session(self.cookie_token())

    def require_session(self, csrf: bool = False) -> sqlite3.Row | None:
        remote = getattr(self, "_remote_session", None)
        if remote is not None:
            if csrf and not safe_compare(self.headers.get("X-CSRF-Token", ""), remote.get("csrf_token", "")):
                self.send_json(HTTPStatus.FORBIDDEN, {"error": "invalid_csrf_token"})
                return None
            return remote
        session = self.current_session()
        if not session:
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "authentication_required"})
            return None
        if csrf and not safe_compare(self.headers.get("X-CSRF-Token", ""), session["csrf_token"]):
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "invalid_csrf_token"})
            return None
        return session

    def parse_path(self) -> tuple[str, list[str], dict[str, list[str]]]:
        parsed = urllib.parse.urlsplit(self.path)
        segments = [urllib.parse.unquote(value) for value in parsed.path.split("/") if value]
        return parsed.path, segments, urllib.parse.parse_qs(parsed.query)

    def do_GET(self) -> None:  # noqa: N802
        path, segments, query = self.parse_path()
        if path == "/healthz":
            database = None
            try:
                database = sqlite3.connect(f"file:{STATE.config.database}?mode=ro", uri=True, timeout=3)
                row = database.execute("PRAGMA quick_check").fetchone()
                healthy = bool(row and row[0] == "ok")
            except (OSError, sqlite3.Error):
                healthy = False
            finally:
                if database is not None:
                    database.close()
            self.send_json(
                HTTPStatus.OK if healthy else HTTPStatus.SERVICE_UNAVAILABLE,
                {"ok": healthy, "service": "rr-nexus"},
            )
            return
        if path == "/api/session":
            session = self.current_session()
            if not session:
                self.send_json(HTTPStatus.OK, {"authenticated": False, "mode": STATE.config.mode})
            else:
                self.send_json(HTTPStatus.OK, {"authenticated": True, "username": session["username"], "csrf": session["csrf_token"], "mode": STATE.config.mode, "domain": STATE.config.domain, "port": STATE.config.port, "ssh_host": STATE.config.ssh_host})
            return
        if path == "/api/security":
            session = self.require_session()
            if session:
                self.handle_security_status(session)
            return
        if path == "/api/security/totp/qr":
            session = self.require_session()
            if session:
                self.handle_totp_qr(session)
            return
        if path == "/api/notifications":
            session = self.require_session()
            if session:
                self.send_json(HTTPStatus.OK, {"settings": STATE.notifications.settings(masked=True)})
            return
        if path == "/api/overview":
            session = self.require_session()
            if session:
                self.handle_overview()
            return
        if path == "/api/devices":
            session = self.require_session()
            if session:
                self.handle_devices()
            return
        if path == "/api/device-groups":
            session = self.require_session()
            if session:
                self.handle_device_groups()
            return
        if path == "/api/device-templates":
            session = self.require_session()
            if session:
                self.handle_device_templates()
            return
        if path == "/api/server/info":
            session = self.require_session()
            if session:
                info = self._run_rr_json(["/usr/local/bin/rr", "--ver-info"])
                info["firewall_permission"] = {
                    "uid": os.geteuid(),
                    "iptables": bool(shutil.which("iptables")),
                    "rr_tool": os.path.exists("/usr/local/bin/rr"),
                }
                self.send_json(HTTPStatus.OK, info)
            return
        if path == "/api/firewall":
            session = self.require_session()
            if session:
                ports = self._run_rr_json(["/usr/local/bin/rr", "--fw-ports"])
                self.send_json(HTTPStatus.OK, {"ports": ports})
            return
        if path == "/api/media-unlock":
            session = self.require_session()
            if session:
                refresh = any(v == "1" for v in query.get("refresh", []))
                self.send_json(HTTPStatus.OK, MEDIA_UNLOCK.check(refresh=refresh))
            return
        if path == "/api/server/stats":
            session = self.require_session()
            if session:
                self.send_json(HTTPStatus.OK, SERVER_STATS.refresh())
            return
        if path == "/api/traffic":
            session = self.require_session()
            if session:
                self.handle_traffic(query)
            return
        if path == "/api/metrics":
            session = self.require_session()
            if session:
                self.handle_metrics(query)
            return
        if path == "/api/server/traffic-policy":
            session = self.require_session()
            if session:
                self.handle_server_traffic_policy()
            return
        if path == "/api/audit":
            session = self.require_session()
            if session:
                self.handle_audit()
            return
        if path == "/api/remote-servers":
            session = self.require_session()
            if session:
                self.handle_remote_servers_list(session)
            return
        if path == "/api/remote/qr":
            session = self.require_session()
            if session:
                self.handle_remote_qr(query)
            return
        if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "links" and DEVICE_ID_RE.fullmatch(segments[2]):
            session = self.require_session()
            if session:
                self.handle_device_links(segments[2])
            return
        if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "qr" and DEVICE_ID_RE.fullmatch(segments[2]):
            session = self.require_session()
            if session:
                self.handle_device_qr(segments[2], query)
            return
        if len(segments) == 3 and segments[0] == "sub" and DEVICE_ID_RE.fullmatch(segments[1]):
            self.handle_public_subscription(segments[1], segments[2], "txt")
            return
        if len(segments) == 4 and segments[0] == "sub" and DEVICE_ID_RE.fullmatch(segments[1]) and segments[3] in {
            "txt", "json", "yaml", "vl", "mihomo", "clash-verge", "flclash",
            "v2rayn", "v2rayng", "sr", "nekobox",
        }:
            self.handle_public_subscription(segments[1], segments[2], segments[3])
            return
        self.serve_static(path)

    def do_POST(self) -> None:  # noqa: N802
        try:
            self._dispatch_post()
        except RequestBodyTooLarge as exc:
            self.send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": "request_body_too_large", "limit": int(exc.args[0])},
            )

    def _dispatch_post(self) -> None:
        path, segments, _ = self.parse_path()
        if path == "/api/login":
            self.handle_login()
            return
        if path == "/api/passkeys/login/begin":
            self.handle_passkey_login_begin()
            return
        if path == "/api/passkeys/login/finish":
            self.handle_passkey_login_finish()
            return
        if path == "/api/logout":
            session = self.require_session(csrf=True)
            if session:
                with STATE.store.connect() as db:
                    db.execute("DELETE FROM sessions WHERE token_hash=?", (sha256_text(self.cookie_token()),))
                STATE.store.audit(session["username"], "logout", "session", self.remote_ip)
                cookie = "rr_nexus_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
                if STATE.config.secure_cookie:
                    cookie += "; Secure"
                self.send_json(HTTPStatus.OK, {"ok": True}, {"Set-Cookie": cookie})
            return
        if path == "/api/devices":
            session = self.require_session(csrf=True)
            if session:
                self.handle_create_device(session)
            return
        if path == "/api/devices/batch":
            session = self.require_session(csrf=True)
            if session:
                self.handle_devices_batch(session)
            return
        if path == "/api/device-groups":
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_group_create(session)
            return
        if path == "/api/device-templates":
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_template_create(session)
            return
        if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "reset" and DEVICE_ID_RE.fullmatch(segments[2]):
            session = self.require_session(csrf=True)
            if session:
                self.handle_reset_device(session, segments[2])
            return
        if path == "/api/server/traffic-policy/reset":
            session = self.require_session(csrf=True)
            if session:
                self.handle_reset_server_traffic_policy(session)
            return
        if path == "/api/change-password":
            session = self.require_session(csrf=True)
            if session:
                self.handle_change_password(session)
            return
        if path == "/api/security/totp/begin":
            session = self.require_session(csrf=True)
            if session:
                self.handle_totp_begin(session)
            return
        if path == "/api/security/totp/confirm":
            session = self.require_session(csrf=True)
            if session:
                self.handle_totp_confirm(session)
            return
        if path == "/api/security/totp/disable":
            session = self.require_session(csrf=True)
            if session:
                self.handle_totp_disable(session)
            return
        if path == "/api/security/passkeys/register/begin":
            session = self.require_session(csrf=True)
            if session:
                self.handle_passkey_register_begin(session)
            return
        if path == "/api/security/passkeys/register/finish":
            session = self.require_session(csrf=True)
            if session:
                self.handle_passkey_register_finish(session)
            return
        if path == "/api/notifications":
            session = self.require_session(csrf=True)
            if session:
                self.handle_notifications_update(session)
            return
        if path == "/api/notifications/test":
            session = self.require_session(csrf=True)
            if session:
                self.handle_notifications_test(session)
            return
        if path == "/api/firewall/toggle":
            session = self.require_session(csrf=True)
            if session:
                body = self.read_json_body()
                try:
                    port = int(body.get("port", 0))
                    proto = str(body.get("proto", ""))
                    result = self._run_rr_json(["/usr/local/bin/rr", "--fw-toggle", str(port), proto])
                    # B3/E13：防火墙 toggle 补审计行（成功与拒绝均落账）
                    STATE.store.audit(
                        session["username"],
                        "firewall_toggle",
                        f"{port}/{proto}",
                        self.remote_ip,
                        json_compact(result).decode("utf-8")[:240],
                    )
                    if result.get("error") == "ssh_port_protected":
                        self.send_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "ssh_port_protected", "message": "SSH 端口受保护，面板不可关闭（防止锁死管理通道）"})
                    else:
                        self.send_json(HTTPStatus.OK, result)
                except (ValueError, TypeError):
                    self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid_params"})
            return
        if path == "/api/firewall/ip-mode":
            session = self.require_session(csrf=True)
            if session:
                body = self.read_json_body()
                entry = str(body.get("entry", ""))
                outbound = str(body.get("outbound", ""))
                result = self._run_rr_json(["/usr/local/bin/rr", "--fw-ipmode", entry, outbound])
                self.send_json(HTTPStatus.OK, result)
            return
        # ---- 多服务器远程管理（6.6.0）----
        if path == "/api/remote/issue":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_issue(session)
            return
        if path == "/api/remote/revoke":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_revoke(session)
            return
        if path == "/api/remote/status":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_status(session)
            return
        if path == "/api/remote/call":
            self.handle_remote_call()
            return
        if path == "/api/remote-servers":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_servers_add(session)
            return
        if path == "/api/remote-servers/status":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_servers_status(session)
            return
        if path == "/api/remote/proxy":
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_proxy(session)
            return
        # ---- 主面板自身一键升级（本地直调 update 三端点，与远程升级共用任务机制）----
        if path == "/api/update/check":
            session = self.require_session(csrf=True)
            if session:
                self.handle_update_check()
            return
        if path == "/api/update/run":
            session = self.require_session(csrf=True)
            if session:
                STATE.store.audit(session["username"], "update_run", "self", self.remote_ip, "")
                self.handle_update_run()
            return
        if path == "/api/update/status":
            session = self.require_session(csrf=True)
            if session:
                self.handle_update_status()
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_PATCH(self) -> None:  # noqa: N802
        try:
            self._dispatch_patch()
        except RequestBodyTooLarge as exc:
            self.send_json(
                HTTPStatus.REQUEST_ENTITY_TOO_LARGE,
                {"error": "request_body_too_large", "limit": int(exc.args[0])},
            )

    def _dispatch_patch(self) -> None:
        path, segments, _ = self.parse_path()
        if path == "/api/server/traffic-policy":
            session = self.require_session(csrf=True)
            if session:
                self.handle_update_server_traffic_policy(session)
            return
        if len(segments) == 3 and segments[:2] == ["api", "devices"] and DEVICE_ID_RE.fullmatch(segments[2]):
            session = self.require_session(csrf=True)
            if session:
                self.handle_update_device(session, segments[2])
            return
        if len(segments) == 3 and segments[:2] == ["api", "device-groups"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_group_update(session, int(segments[2]))
            return
        if len(segments) == 3 and segments[:2] == ["api", "device-templates"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_template_update(session, int(segments[2]))
            return
        if len(segments) == 3 and segments[:2] == ["api", "remote-servers"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_servers_rename(session, segments[2])
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    def do_DELETE(self) -> None:  # noqa: N802
        _, segments, _ = self.parse_path()
        if len(segments) == 4 and segments[:3] == ["api", "security", "passkeys"]:
            session = self.require_session(csrf=True)
            if session:
                self.handle_passkey_delete(session, segments[3])
            return
        if len(segments) == 3 and segments[:2] == ["api", "device-groups"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_group_delete(session, int(segments[2]))
            return
        if len(segments) == 3 and segments[:2] == ["api", "device-templates"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_device_template_delete(session, int(segments[2]))
            return
        if len(segments) == 3 and segments[:2] == ["api", "devices"] and DEVICE_ID_RE.fullmatch(segments[2]):
            session = self.require_session(csrf=True)
            if session:
                self.handle_delete_device(session, segments[2])
            return
        if len(segments) == 3 and segments[:2] == ["api", "remote-servers"] and segments[2].isdigit():
            session = self.require_session(csrf=True)
            if session:
                self.handle_remote_servers_delete(session, segments[2])
            return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})

    # ---------- 多服务器远程管理（6.6.0）----------

    def remote_failure_state(self) -> tuple[bool, int]:
        cutoff = epoch_now() - REMOTE_FAIL_WINDOW
        with STATE.store.connect() as db:
            db.execute("DELETE FROM remote_failures WHERE failed_at<?", (cutoff,))
            row = db.execute(
                "SELECT COUNT(*) FROM remote_failures WHERE remote_ip=?", (self.remote_ip,)
            ).fetchone()
        count = int(row[0])
        if count >= REMOTE_FAIL_LIMIT:
            latest = cutoff
            with STATE.store.connect() as db:
                recent = db.execute(
                    "SELECT MAX(failed_at) FROM remote_failures WHERE remote_ip=?", (self.remote_ip,)
                ).fetchone()
            if recent and recent[0]:
                latest = int(recent[0])
            return True, max(1, latest + REMOTE_FAIL_WINDOW - epoch_now())
        return False, 0

    def record_remote_failure(self) -> None:
        with STATE.store.connect() as db:
            db.execute(
                "INSERT INTO remote_failures(remote_ip,failed_at) VALUES(?,?)",
                (self.remote_ip, epoch_now()),
            )

    def handle_remote_issue(self, session: sqlite3.Row | dict) -> None:
        body = self.read_json_body()
        name = str((body or {}).get("name", "") or "")
        cred, reason = remote_cred_issue(name, STATE.config)
        if cred is None:
            # B3/E13：remote/issue 被拒路径补审计行（成功签发已有 remote_issue 行）
            STATE.store.audit(session["username"], "remote_issue_denied", "remote-key", self.remote_ip, reason[:240])
            self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "remote_unavailable", "message": reason})
            return
        payload = remote_cred_parse(cred) or {}
        STATE.store.audit(session["username"], "remote_issue", "remote-key", self.remote_ip, "fp={}".format(remote_cred_fingerprint(payload)))
        self.send_json(HTTPStatus.OK, {"ok": True, "cred": cred, "fingerprint": remote_cred_fingerprint(payload)})

    def handle_remote_revoke(self, session: sqlite3.Row | dict) -> None:
        """轮换签发密钥 = 全部旧钥匙立即失效。"""
        cert_ok, cert_reason = remote_cert_check(STATE.config)
        if not cert_ok:
            # O1/F10：与 issue 对称——仅公网证书面板可轮换远程钥匙
            STATE.store.audit(session["username"], "remote_revoke_denied", "remote-key", self.remote_ip, cert_reason[:240])
            self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "remote_unavailable", "message": cert_reason})
            return
        try:
            REMOTE_KEY_PATH.unlink()
        except FileNotFoundError:
            pass
        remote_key_load_or_create()
        STATE.store.audit(session["username"], "remote_revoke", "remote-key", self.remote_ip, "全部旧钥匙已吊销")
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_remote_status(self, session: sqlite3.Row | dict) -> None:
        cert_ok, cert_reason = remote_cert_check(STATE.config)
        key_exists = REMOTE_KEY_PATH.exists()
        self.send_json(HTTPStatus.OK, {"ok": True, "enabled": cert_ok, "reason": cert_reason, "key_exists": key_exists})

    def handle_remote_call(self) -> None:
        """副面板远程入口：凭钥匙执行管理员操作（无需登录会话）。"""
        self._remote_session = None
        self._remote_body = None
        locked, retry_after = self.remote_failure_state()
        if locked:
            self.send_json(HTTPStatus.TOO_MANY_REQUESTS, {"error": "too_many_attempts", "retry_after": retry_after, "message": "远程钥匙验证失败次数过多，已临时锁定"})
            return
        body = self.read_json_body()
        cred = str((body or {}).get("cred", "") or "")
        payload = remote_cred_verify(cred)
        if payload is None:
            self.record_remote_failure()
            time.sleep(min(REMOTE_FAIL_DELAY + REMOTE_FAIL_DELAY * 0.5, 2.0))
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "invalid_remote_cred", "message": "接入钥匙无效（伪造、篡改或已被吊销）"})
            return
        method = str((body or {}).get("method", "") or "GET").upper()
        path = str((body or {}).get("path", "") or "")
        inner = (body or {}).get("body") or {}
        if method not in {"GET", "POST", "PATCH", "DELETE"} or not path.startswith("/api/"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "bad_request"})
            return
        fp = remote_cred_fingerprint(payload)
        csrf_val = secrets.token_hex(16)
        self.headers["X-CSRF-Token"] = csrf_val
        self._remote_session = {
            "username": "remote:{}".format(fp),
            "csrf_token": csrf_val,
            "remote": True,
            "remote_name": payload.get("n", ""),
        }
        self._remote_body = inner
        STATE.store.audit("remote:{}".format(fp), "remote_call", "{} {}".format(method, path), self.remote_ip, "name={}".format(payload.get("n", "")))
        try:
            self.remote_dispatch(method, path, payload, inner)
        except Exception as exc:  # 远程错误不泄露堆栈
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "remote_error", "message": str(exc)[:200]})

    def handle_update_check(self) -> None:
        """检查脚本更新：下载远程 manifest 与本地比对（防 CDN 缓存加 ?t=）。"""
        body = self.read_json() or {}
        requested_channel = body.get("channel")
        if requested_channel is not None:
            try:
                update_channel(str(requested_channel))
            except (ValueError, OSError):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_update_channel"})
                return
        channel = update_channel()
        manifest_url = update_manifest_url()
        local_sha = ""
        if UPDATE_LOCAL_MANIFEST.exists():
            try:
                local_sha = hashlib.sha256(UPDATE_LOCAL_MANIFEST.read_bytes()).hexdigest()
            except OSError:
                local_sha = ""
        remote_sha = ""
        remote_error = ""
        try:
            request = urllib.request.Request("{}?t={}".format(manifest_url, int(time.time())), headers={"User-Agent": "rr-nexus-update/7.1"})
            with urllib.request.urlopen(request, timeout=8) as resp:
                remote_sha = hashlib.sha256(resp.read()).hexdigest()
        except Exception:
            remote_sha = ""
            remote_error = "检查失败：无法连接更新源"
        current = ""
        try:
            result = subprocess.run(["/usr/local/bin/rr", "--version"], capture_output=True, text=True, timeout=10)
            current = result.stdout.strip().split()[-1] if result.returncode == 0 and result.stdout.strip() else ""
        except Exception:
            current = ""
        update_available = bool(remote_sha and local_sha and remote_sha != local_sha)
        preflight: dict[str, Any] = {}
        try:
            result = subprocess.run(
                ["/usr/local/bin/rr", "--update-preflight"], capture_output=True, text=True,
                timeout=30, check=False,
            )
            if result.stdout.strip():
                preflight = json.loads(result.stdout.strip().splitlines()[-1])
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError):
            preflight = {"ok": False, "error": "preflight_unavailable"}
        payload = {
            "current": current,
            "channel": channel,
            "update_available": update_available,
            "manifest_checked": bool(remote_sha),
            "local_sha": local_sha[:12],
            "remote_sha": remote_sha[:12],
            "preflight": preflight,
        }
        if remote_error:
            # manifest 下载失败必须显式报错：前端以此区分"检查失败"与"已是最新"，杜绝误报
            payload["error"] = remote_error
        self.send_json(HTTPStatus.OK, payload)

    def handle_update_run(self) -> None:
        """启动远程升级任务（异步线程执行升级，升级完自动拉起新面板）。
        任务认领双重原子化：进程内互斥锁 + O_EXCL 锁文件——本地/远程双通道并发时
        只有一个请求能认领成功，杜绝重复下发（systemd unit 名冲突）与任务状态互相覆盖。"""
        body = self.read_json() or {}
        if "channel" in body:
            try:
                update_channel(str(body["channel"]))
            except (ValueError, OSError):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_update_channel"})
                return
        try:
            preflight = subprocess.run(
                ["/usr/local/bin/rr", "--update-preflight"], capture_output=True, text=True,
                timeout=30, check=False,
            )
            if preflight.returncode != 0:
                detail = (preflight.stdout or preflight.stderr or "update preflight failed").strip()
                self.send_json(
                    HTTPStatus.CONFLICT,
                    {"ok": False, "started": False, "error": "update_preflight_failed", "message": detail[-1000:]},
                )
                return
        except (OSError, subprocess.TimeoutExpired):
            self.send_json(HTTPStatus.CONFLICT, {"ok": False, "started": False, "error": "update_preflight_failed"})
            return
        with _UPDATE_CLAIM_LOCK:
            job = self.update_job_read()
            # running 超过 90 秒但 systemd unit 已不存在 = 任务实际已死（面板被重启/进程被杀），
            # 直接放行重新下发，不用等超时。
            if job and job.get("state") == "running":
                unit_state = self.update_unit_state()
                if unit_state in {"", "inactive", "failed", "dead"}:
                    job = None
            if job and job.get("state") == "running":
                self.send_json(HTTPStatus.OK, {"ok": True, "started": False, "message": "已有升级任务进行中", "job": job})
                return
            lock_error, lock_token = self.update_lock_acquire()
            if lock_error:
                self.send_json(HTTPStatus.OK, {"ok": True, "started": False, "message": lock_error})
                return
            try:
                UPDATE_LOG_PATH.write_text("", encoding="utf-8")
            except OSError:
                pass
            job = {"state": "running", "started_at": utc_now(), "finished_at": None, "output": ""}
            self.update_job_write(job)
        token = job["started_at"]

        def _worker() -> None:
            out = ""
            final = None  # (state, detail)；未捕获异常时保持 None，不终写
            try:
                try:
                    result = subprocess.run(UPDATE_CMD, capture_output=True, text=True, timeout=480, stdin=subprocess.DEVNULL)
                    out = (result.stdout or "") + (result.stderr or "")
                    state = "done" if result.returncode == 0 else "failed"
                    detail = "升级完成，面板与节点服务已自动切换到新版本" if state == "done" else "升级未完成（返回码 {}），已自动回滚或保持原版本".format(result.returncode)
                    final = (state, detail)
                except subprocess.TimeoutExpired:
                    # systemd-run 被超时杀掉后 transient unit 可能还在跑，显式停掉
                    subprocess.run(["systemctl", "stop", "rr-remote-upgrade"], capture_output=True, timeout=15)
                    final = ("failed", "升级超过 8 分钟无进展，已中止（可重新下发）")
                except Exception as exc:
                    final = ("failed", "升级进程异常：{}".format(str(exc)[:160]))
            finally:
                alert_detail = ""
                # 终写与释锁在同一临界区：新任务的认领只能在本次释锁之后发生，
                # 杜绝"旧任务 finally 误删新锁（inode 复用）"与结果互相覆盖
                with _UPDATE_CLAIM_LOCK:
                    if final is not None:
                        state, detail = final
                        # 终写前重读 job：仅当仍是本次下发（started_at 一致）才覆写
                        current = self.update_job_read()
                        if current and current.get("started_at") == token:
                            self.update_job_write({"state": state, "started_at": token, "finished_at": utc_now(), "output": out[-4000:], "detail": detail})
                            if state == "failed":
                                alert_detail = detail
                    try:
                        # token 归属：锁文件内容与本次认领的 token 一致才释放
                        # （内容比对不受 inode 复用影响，杜绝旧任务误删新锁）
                        if UPDATE_LOCK_PATH.read_text(encoding="utf-8", errors="replace").strip() == lock_token:
                            UPDATE_LOCK_PATH.unlink()
                    except (FileNotFoundError, OSError):
                        pass
                # 网络告警可能等待数秒，不得占用更新认领锁。
                if alert_detail:
                    STATE.notifications.emit(
                        "update_failed", "critical", "RR-vps 更新失败", alert_detail,
                        f"update_failed:{datetime.now(timezone.utc).strftime('%Y%m%d%H')}",
                        minimum_interval=300,
                    )

        threading.Thread(target=_worker, daemon=True).start()
        self.send_json(HTTPStatus.OK, {"ok": True, "started": True, "message": "升级任务已启动，完成后自动拉起新版本面板"})

    def update_lock_acquire(self) -> tuple[str | None, str]:
        """O_EXCL 原子认领升级任务锁，返回 (错误消息或 None, 锁 token)。
        锁文件内容写入唯一 token（uuid4），释锁时比对内容——不受 inode 复用影响。
        锁已存在时按 unit 心跳判死：unit 不在 + cgroup 目录不存在 + 锁龄超阈值 = 面板重启残留锁
        → 删除后重认领一次；unit/cgroup 仍在或锁龄过新 = 真任务进行中 → 拒绝
        （锁龄阈值防误删刚认领、unit 尚未注册的新锁；cgroup 二次确认防 unit 查询单点失效）。"""
        try:
            fd = os.open(UPDATE_LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except FileExistsError:
            fd = None
        except OSError:
            return ("升级任务锁创建失败（{} 不可写）".format(UPDATE_LOCK_PATH.parent), "")
        if fd is None:
            unit_state = self.update_unit_state()
            if unit_state not in {"", "inactive", "failed", "dead"}:
                return ("已有升级任务进行中", "")
            # Critic v2 R3：unit 查询之外再做 cgroup 二次活性确认——dbus/systemctl 单点
            # 失效时进程可能仍活着，cgroup 目录存在即拒绝判死重认领，防双通道重复下发
            if self.update_unit_cgroup_alive():
                return ("已有升级任务进行中", "")
            try:
                if time.time() - UPDATE_LOCK_PATH.stat().st_mtime < UPDATE_LOCK_STALE_AGE:
                    return ("已有升级任务进行中", "")
                UPDATE_LOCK_PATH.unlink()
            except OSError:
                return ("已有升级任务进行中", "")
            try:
                fd = os.open(UPDATE_LOCK_PATH, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            except FileExistsError:
                return ("已有升级任务进行中", "")
            except OSError:
                return ("升级任务锁创建失败（{} 不可写）".format(UPDATE_LOCK_PATH.parent), "")
        token = uuid.uuid4().hex
        try:
            os.write(fd, token.encode("ascii"))
        finally:
            os.close(fd)
        return (None, token)

    def handle_update_status(self) -> None:
        job: dict | None = self.update_job_read()
        if not job:
            job = {"state": "idle", "output": "", "detail": "尚未执行过升级"}
        if job.get("state") == "running":
            # 权威心跳 = systemd transient unit 状态（升级进程与面板 cgroup 隔离，
            # 面板重启不影响 unit；unit 没了 = 任务真死了）
            unit_state = self.update_unit_state()
            log_tail = self.update_log_tail()
            job["unit_state"] = unit_state
            job["log_tail"] = log_tail
            if unit_state in {"", "inactive", "failed", "dead"}:
                # 任务进程已不在但 done 标记没写上（面板曾被重启）：按 manifest 比对判定实际结果
                try:
                    remote_sha = ""
                    request = urllib.request.Request("{}?t={}".format(update_manifest_url(), int(time.time())), headers={"User-Agent": "rr-nexus-update/7.1"})
                    with urllib.request.urlopen(request, timeout=8) as resp:
                        remote_sha = hashlib.sha256(resp.read()).hexdigest()
                    local_sha = hashlib.sha256(UPDATE_LOCAL_MANIFEST.read_bytes()).hexdigest() if UPDATE_LOCAL_MANIFEST.exists() else ""
                    if remote_sha and local_sha and remote_sha == local_sha:
                        job = {"state": "done", "started_at": job.get("started_at"), "finished_at": utc_now(), "output": "", "detail": "升级完成，面板与节点服务已自动切换到新版本"}
                        self.update_job_write(job)
                    else:
                        job = {"state": "failed", "started_at": job.get("started_at"), "finished_at": utc_now(), "output": log_tail, "detail": "升级进程已退出但未完成升级（可能网络中断或校验失败）"}
                        self.update_job_write(job)
                except Exception:
                    job["state"] = "failed"
                    job["detail"] = "无法确认升级结果，请重新下发"
            else:
                # unit 还活着：日志心跳检查——日志 120 秒无更新 = 疑似卡死
                try:
                    age = time.time() - UPDATE_LOG_PATH.stat().st_mtime
                    job["heartbeat_seconds"] = int(age)
                    job["stalled"] = age > 120
                except OSError:
                    job["heartbeat_seconds"] = -1
        self.send_json(HTTPStatus.OK, job)

    @staticmethod
    def update_unit_state() -> str:
        """rr-remote-upgrade transient unit 的 ActiveState；查不到返回空串。"""
        try:
            result = subprocess.run(
                ["systemctl", "show", "rr-remote-upgrade", "-p", "ActiveState", "--value"],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                return (result.stdout or "").strip()
        except Exception:
            pass
        return ""

    @staticmethod
    def update_unit_cgroup_alive() -> bool:
        """判死二次活性确认（Critic v2 R3）：unit 查询是单一信任源，dbus/systemctl 偶发
        失效时可能误报已死；cgroup 目录是内核侧独立证据，目录仍存在 = 升级进程可能仍活着。
        systemd-run 非 TTY 下建 .service、TTY 下建 .scope，两种都查；
        cgroupfs 不可读时返回 False（不阻塞重认领，保持原判死行为）。"""
        for name in ("rr-remote-upgrade.service", "rr-remote-upgrade.scope"):
            try:
                if os.path.isdir("/sys/fs/cgroup/system.slice/" + name):
                    return True
            except OSError:
                continue
        return False

    @staticmethod
    def update_log_tail() -> str:
        try:
            data = UPDATE_LOG_PATH.read_bytes()
            if not data:
                return ""
            text = data.decode("utf-8", errors="replace")
            return text[-800:]
        except OSError:
            return ""

    @staticmethod
    def update_job_read() -> dict | None:
        try:
            raw = UPDATE_JOB_PATH.read_text(encoding="utf-8")
            job = json.loads(raw)
            return job if isinstance(job, dict) else None
        except (OSError, json.JSONDecodeError):
            return None

    @staticmethod
    def update_job_write(job: dict) -> None:
        try:
            UPDATE_JOB_PATH.write_text(json_compact(job).decode("utf-8"), encoding="utf-8")
        except OSError:
            pass

    def remote_dispatch(self, method: str, path: str, payload: dict, inner: dict) -> None:
        """白名单分发：只暴露管理员能力，逐项对应本地 handler。"""
        segments = [urllib.parse.unquote(v) for v in path.split("/") if v]
        if method == "GET":
            if path == "/api/overview":
                self.handle_overview(); return
            if path == "/api/devices":
                self.handle_devices(); return
            if path == "/api/device-groups":
                self.handle_device_groups(); return
            if path == "/api/device-templates":
                self.handle_device_templates(); return
            if path == "/api/metrics":
                self.handle_metrics({}); return
            if path == "/api/traffic":
                self.handle_traffic(); return
            if path == "/api/server/traffic-policy":
                self.handle_server_traffic_policy(); return
            if path == "/api/audit":
                self.handle_audit(); return
            if path == "/api/server/info":
                info = self._run_rr_json(["/usr/local/bin/rr", "--ver-info"])
                self.send_json(HTTPStatus.OK, info); return
            if path == "/api/firewall":
                ports = self._run_rr_json(["/usr/local/bin/rr", "--fw-ports"])
                self.send_json(HTTPStatus.OK, {"ports": ports}); return
            if path == "/api/media-unlock":
                self.send_json(HTTPStatus.OK, MEDIA_UNLOCK.check()); return
            if path == "/api/server/stats":
                self.send_json(HTTPStatus.OK, SERVER_STATS.refresh()); return
            if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "links" and DEVICE_ID_RE.fullmatch(segments[2]):
                self.handle_device_links(segments[2]); return
            if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "qr" and DEVICE_ID_RE.fullmatch(segments[2]):
                # 远程二维码：图片无法走 JSON 代理，转 base64 返回给主面板透传
                qquery = {k: [str(v)] for k, v in (inner or {}).items() if v not in (None, "")}
                status, payload = self._qr_png_bytes(segments[2], qquery)
                if status == HTTPStatus.OK and isinstance(payload, bytes):
                    self.send_json(HTTPStatus.OK, {"png_b64": base64.b64encode(payload).decode("ascii")})
                else:
                    self.send_json(status, payload)
                return
        elif method == "POST":
            if path == "/api/update/check":
                self.handle_update_check(); return
            if path == "/api/update/run":
                self.handle_update_run(); return
            if path == "/api/update/status":
                self.handle_update_status(); return
            if path == "/api/devices":
                self.handle_create_device(self._remote_session); return
            if path == "/api/devices/batch":
                self.handle_devices_batch(self._remote_session); return
            if path == "/api/device-groups":
                self.handle_device_group_create(self._remote_session); return
            if path == "/api/device-templates":
                self.handle_device_template_create(self._remote_session); return
            if len(segments) == 4 and segments[:2] == ["api", "devices"] and segments[3] == "reset" and DEVICE_ID_RE.fullmatch(segments[2]):
                self.handle_reset_device(self._remote_session, segments[2]); return
            if path == "/api/server/traffic-policy/reset":
                self.handle_reset_server_traffic_policy(self._remote_session); return
            if path == "/api/firewall/toggle":
                port = int(inner.get("port", 0) or 0)
                proto = str(inner.get("proto", "") or "")
                result = self._run_rr_json(["/usr/local/bin/rr", "--fw-toggle", str(port), proto])
                if result.get("error") == "ssh_port_protected":
                    self.send_json(HTTPStatus.FORBIDDEN, {"ok": False, "error": "ssh_port_protected", "message": "SSH 端口受保护"})
                else:
                    self.send_json(HTTPStatus.OK, result)
                return
            if path == "/api/firewall/ip-mode":
                result = self._run_rr_json(["/usr/local/bin/rr", "--fw-ipmode", str(inner.get("entry", "") or ""), str(inner.get("outbound", "") or "")])
                self.send_json(HTTPStatus.OK, result); return
        elif method == "PATCH":
            if path == "/api/server/traffic-policy":
                self.handle_update_server_traffic_policy(self._remote_session); return
            if len(segments) == 3 and segments[:2] == ["api", "devices"] and DEVICE_ID_RE.fullmatch(segments[2]):
                self.handle_update_device(self._remote_session, segments[2]); return
            if len(segments) == 3 and segments[:2] == ["api", "device-groups"] and segments[2].isdigit():
                self.handle_device_group_update(self._remote_session, int(segments[2])); return
            if len(segments) == 3 and segments[:2] == ["api", "device-templates"] and segments[2].isdigit():
                self.handle_device_template_update(self._remote_session, int(segments[2])); return
        elif method == "DELETE":
            if len(segments) == 3 and segments[:2] == ["api", "devices"] and DEVICE_ID_RE.fullmatch(segments[2]):
                self.handle_delete_device(self._remote_session, segments[2]); return
            if len(segments) == 3 and segments[:2] == ["api", "device-groups"] and segments[2].isdigit():
                self.handle_device_group_delete(self._remote_session, int(segments[2])); return
            if len(segments) == 3 and segments[:2] == ["api", "device-templates"] and segments[2].isdigit():
                self.handle_device_template_delete(self._remote_session, int(segments[2])); return
        self.send_json(HTTPStatus.NOT_FOUND, {"error": "remote_unsupported"})

    # ---------- 主面板侧：多服务器管理 ----------

    @staticmethod
    def remote_http_call(addr: str, port: int, cred: str, method: str, path: str, body: dict | None, timeout: int = REMOTE_HTTP_TIMEOUT) -> tuple[int, dict]:
        url = "https://{}:{}/api/remote/call".format(_url_host(addr), int(port))
        data = json_compact({"cred": cred, "method": method, "path": path, "body": body or {}})
        try:
            status, raw = https_post(
                url,
                data,
                {"Content-Type": "application/json", "User-Agent": "rr-nexus-remote/7.1"},
                timeout=timeout,
            )
            try:
                payload = json.loads(raw)
            except Exception:
                payload = {"_raw": raw[:200].decode("utf-8", "replace")}
            return status, payload
        except UnsafeTargetError:
            return 0, {"error": "unsafe_remote_target", "message": "远程地址必须解析到公开网络"}
        except Exception as exc:
            return 0, {"error": "unreachable", "message": type(exc).__name__}

    def handle_remote_servers_list(self, session: sqlite3.Row | dict) -> None:
        with STATE.store.connect() as db:
            rows = db.execute("SELECT id,name,addr,port,last_seen,last_status,created_at FROM remote_servers ORDER BY id").fetchall()
        self.send_json(HTTPStatus.OK, {"servers": [dict(r) for r in rows]})

    def handle_remote_servers_add(self, session: sqlite3.Row | dict) -> None:
        body = self.read_json_body()
        name = str((body or {}).get("name", "") or "").strip()
        cred = str((body or {}).get("cred", "") or "").strip()
        payload = remote_cred_parse(cred)
        if not payload:
            self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid_cred_format", "message": "钥匙格式无效（应为 rrmgr1. 开头的一行密文）"})
            return
        if not name:
            name = str(payload.get("n", "") or "远程服务器")
        if not REMOTE_CRED_NAME_RE.fullmatch(name):
            self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "invalid_name", "message": "备注名需为 1-64 个可显示字符"})
            return
        addr = str(payload.get("a", "") or "")
        port = int(payload.get("p", 0) or 0)
        with STATE.store.connect() as db:
            exists = db.execute("SELECT id FROM remote_servers WHERE addr=? AND port=?", (addr, port)).fetchone()
            if exists:
                self.send_json(HTTPStatus.CONFLICT, {"ok": False, "error": "already_exists", "message": "该服务器已添加（{}），请勿重复添加".format(addr), "server_id": exists["id"]})
                return
            count = db.execute("SELECT COUNT(*) FROM remote_servers").fetchone()
            if int(count[0]) >= REMOTE_MAX_SERVERS:
                self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "limit_reached", "message": "已达上限 {} 台".format(REMOTE_MAX_SERVERS)})
                return
        # 立即验证钥匙（副面板签名校验 + 连通性）
        status, result = self.remote_http_call(addr, port, cred, "GET", "/api/overview", None)
        if status != 200 or not isinstance(result, dict) or result.get("error"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"ok": False, "error": "cred_rejected", "message": "副面板拒绝该钥匙：{}".format((result or {}).get("message") or (result or {}).get("error") or "HTTP {}".format(status))})
            return
        with STATE.store.connect() as db:
            db.execute(
                "INSERT INTO remote_servers(name,cred,addr,port,last_seen,created_at) VALUES(?,?,?,?,?,?)",
                (name[:64], cred, addr[:128], port, utc_now(), utc_now()),
            )
        STATE.store.audit(session["username"], "remote_server_add", name[:64], self.remote_ip, addr)
        self.send_json(HTTPStatus.OK, {"ok": True, "verified": True})

    def handle_remote_servers_delete(self, session: sqlite3.Row | dict, server_id: str) -> None:
        with STATE.store.connect() as db:
            row = db.execute("SELECT id,name FROM remote_servers WHERE id=?", (int(server_id),)).fetchone()
            if not row:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"}); return
            db.execute("DELETE FROM remote_servers WHERE id=?", (int(server_id),))
        STATE.store.audit(session["username"], "remote_server_delete", str(row["name"]), self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_remote_servers_rename(self, session: sqlite3.Row | dict, server_id: str) -> None:
        body = self.read_json_body()
        name = str((body or {}).get("name", "") or "").strip()
        if not name or len(name) > 64:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_name", "message": "备注名需为 1-64 个字符"})
            return
        with STATE.store.connect() as db:
            row = db.execute("SELECT id,name FROM remote_servers WHERE id=?", (int(server_id),)).fetchone()
            if not row:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"}); return
            db.execute("UPDATE remote_servers SET name=? WHERE id=?", (name, int(server_id)))
        STATE.store.audit(session["username"], "remote_server_rename", "{} -> {}".format(row["name"], name), self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_remote_servers_status(self, session: sqlite3.Row | dict) -> None:
        """并发聚合全部副服务器状态（无上限，线程池并发）。"""
        with STATE.store.connect() as db:
            rows = db.execute("SELECT id,name,cred,addr,port,last_seen FROM remote_servers ORDER BY id").fetchall()
        servers = [dict(r) for r in rows]

        def probe_one(server: dict) -> dict:
            def count_value(value: Any) -> int:
                return int(bounded_remote_number(value, MAX_DEVICES, integer=True))

            result = {"id": server["id"], "name": server["name"], "addr": server["addr"], "online": False}
            started = time.monotonic()
            status, body = self.remote_http_call(server["addr"], server["port"], server["cred"], "GET", "/api/overview", None)
            ping_ms = int((time.monotonic() - started) * 1000)
            result["ping"] = ping_ms
            if status == 200 and isinstance(body, dict) and not body.get("error"):
                result["online"] = True
                device_summary = body.get("devices")
                if not isinstance(device_summary, dict):
                    device_summary = {}
                result["devices"] = count_value(device_summary.get("total", 0))
                result["enabled"] = count_value(device_summary.get("enabled", 0))
                result["active_devices"] = count_value(device_summary.get("active", 0))
                used = int(bounded_remote_number(
                    device_summary.get("used", 0),
                    MAX_SERVER_TRAFFIC_GB * 1024**3,
                    integer=True,
                ))
                result["used_gb"] = round(used / 1024 ** 3, 2)
                services = body.get("services")
                result["services"] = {
                    "sing-box": "active"
                    if isinstance(services, dict) and services.get("sing-box") == "active"
                    else "inactive"
                }
                # 服务器实时指标（字段适配：cpu 是 dict{percent,...}，memory 是 dict{percent,...}）
                s2, b2 = self.remote_http_call(server["addr"], server["port"], server["cred"], "GET", "/api/server/stats", None)
                if s2 == 200 and isinstance(b2, dict):
                    cpu_val = b2.get("cpu")
                    mem_val = b2.get("memory")
                    result["cpu"] = bounded_remote_number(
                        cpu_val.get("percent", 0) if isinstance(cpu_val, dict) else cpu_val,
                        100,
                    )
                    result["mem"] = bounded_remote_number(
                        mem_val.get("percent", 0) if isinstance(mem_val, dict) else mem_val,
                        100,
                    )
                s3, b3 = self.remote_http_call(server["addr"], server["port"], server["cred"], "GET", "/api/server/info", None)
                if s3 == 200 and isinstance(b3, dict):
                    version = str(b3.get("script_version") or "")
                    result["ver"] = version if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) else ""
                result["state"] = "online"
            else:
                err_code = (body or {}).get("error") if isinstance(body, dict) else ""
                if err_code == "invalid_remote_cred":
                    result["state"] = "revoked"
                elif status == 429 or err_code == "too_many_attempts":
                    result["state"] = "locked"
                else:
                    result["state"] = "offline"
            with STATE.store.connect() as db:
                db.execute("UPDATE remote_servers SET last_seen=?,last_status=? WHERE id=?", (utc_now(), result["state"], server["id"]))
            return result

        if len(servers) <= 1:
            results = [probe_one(s) for s in servers]
        else:
            with ThreadPoolExecutor(max_workers=min(16, len(servers))) as pool:
                results = list(pool.map(probe_one, servers))
        self.send_json(HTTPStatus.OK, {"servers": results})

    def handle_remote_proxy(self, session: sqlite3.Row | dict) -> None:
        """把管理员的请求转发给指定副服务器（主面板代理）。"""
        body = self.read_json_body()
        server_id = (body or {}).get("server_id")
        method = str((body or {}).get("method", "") or "GET").upper()
        path = str((body or {}).get("path", "") or "")
        inner = (body or {}).get("body") or {}
        if method not in {"GET", "POST", "PATCH", "DELETE"} or not path.startswith("/api/"):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "bad_request"})
            return
        with STATE.store.connect() as db:
            row = db.execute("SELECT id,cred,addr,port,name FROM remote_servers WHERE id=?", (int(server_id),)).fetchone() if str(server_id).isdigit() else None
        if not row:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        # 写操作（设备变更会触发 sync 重建配置，60s+）用长超时；读操作用默认 15s
        call_timeout = REMOTE_HTTP_TIMEOUT if method == "GET" else 90
        status, result = self.remote_http_call(row["addr"], row["port"], row["cred"], method, path, inner, timeout=call_timeout)
        STATE.store.audit(session["username"], "remote_proxy", "{} {}".format(method, path), self.remote_ip, "-> {}".format(row["name"]))
        self.send_json(status if status in range(200, 600) else HTTPStatus.BAD_GATEWAY, result)

    def handle_remote_qr(self, query: dict[str, list[str]]) -> None:
        """主面板图片透传：拉取副面板设备的二维码 PNG（副面板经 remote/call 返回 base64）。"""
        server_id = query.get("server_id", [""])[0]
        device_id = query.get("device_id", [""])[0]
        if not str(server_id).isdigit() or not DEVICE_ID_RE.fullmatch(device_id):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "bad_request"})
            return
        with STATE.store.connect() as db:
            row = db.execute("SELECT cred,addr,port FROM remote_servers WHERE id=?", (int(server_id),)).fetchone()
        if not row:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        qr_query = {}
        if query.get("sub", [""])[0]:
            qr_query["sub"] = query["sub"][0]
        if query.get("raw", [""])[0]:
            qr_query["raw"] = query["raw"][0]
        if query.get("index", [""])[0]:
            qr_query["index"] = query["index"][0]
        status, result = self.remote_http_call(
            row["addr"], row["port"], row["cred"], "GET",
            "/api/devices/{}/qr".format(device_id), qr_query,
        )
        png_b64 = (result or {}).get("png_b64", "") if isinstance(result, dict) else ""
        if status != 200 or not png_b64:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": "remote_qr_failed", "message": "副面板二维码生成失败（HTTP {}）".format(status)})
            return
        try:
            png = base64.b64decode(png_b64)
        except Exception:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": "remote_qr_failed", "message": "副面板二维码数据无效"})
            return
        self.send_bytes(HTTPStatus.OK, png, "image/png")

    def handle_login(self) -> None:
        locked, retry_after = STATE.client_is_locked(self.remote_ip)
        if locked:
            self.send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {
                    "error": "too_many_attempts",
                    "retry_after": retry_after,
                    "message": "登录失败次数过多，面板已临时锁定。如需立即恢复，可在服务器执行 rr，菜单 14→2 重置面板登录密码。",
                },
                {"Retry-After": str(retry_after)},
            )
            return
        payload = self.read_json()
        if not payload:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
            return
        username = str(payload.get("username", ""))[:64]
        password = str(payload.get("password", ""))[:512]
        locked, retry_after = STATE.client_is_locked(self.remote_ip, username)
        if locked:
            self.send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {
                    "error": "too_many_attempts",
                    "retry_after": retry_after,
                    "message": "该账号或来源登录失败次数过多，已临时锁定。如需立即恢复，可在服务器执行 rr，菜单 14→2 重置面板登录密码。",
                },
                {"Retry-After": str(retry_after)},
            )
            return
        admin, method = STATE.authenticate_with_method(username, password)
        if not admin:
            STATE.record_login_failure(self.remote_ip, username)
            STATE.store.audit(username or "unknown", "login_failed", "session", self.remote_ip)
            time.sleep(STATE.login_fail_delay(self.remote_ip))
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid_credentials"})
            return
        if method == "password" and bool(admin["totp_enabled"]):
            otp = str(payload.get("otp", ""))[:16]
            if not otp:
                self.send_json(
                    HTTPStatus.UNAUTHORIZED,
                    {"error": "two_factor_required", "message": "请输入身份验证器中的 6 位动态码"},
                )
                return
            if not verify_totp(str(admin["totp_secret"]), otp):
                STATE.record_login_failure(self.remote_ip, username)
                STATE.store.audit(username, "totp_failed", "session", self.remote_ip)
                time.sleep(STATE.login_fail_delay(self.remote_ip))
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid_two_factor_code"})
                return
        STATE.clear_login_failures(self.remote_ip, admin["username"])
        self.finish_login(admin, "recovery" if method == "recovery" else "password_totp" if admin["totp_enabled"] else "password")

    def finish_login(self, admin: sqlite3.Row, method: str) -> None:
        token, csrf = STATE.create_session(admin["id"], self.remote_ip)
        STATE.store.audit(admin["username"], "login", "session", self.remote_ip, method)
        cookie = f"rr_nexus_session={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={SESSION_HOURS * 3600}"
        if STATE.config.secure_cookie:
            cookie += "; Secure"
        self.send_json(HTTPStatus.OK, {"ok": True, "username": admin["username"], "csrf": csrf}, {"Set-Cookie": cookie})

    @staticmethod
    def webauthn_context() -> tuple[str, str] | None:
        if not webauthn_available():
            return None
        cfg = STATE.config
        if cfg.mode == "public":
            domain = (cfg.domain or "").strip().strip("[]")
            if not domain or domain == "ip" or _is_ip_address(domain):
                return None
            port = cfg.public_port or 443
            origin = f"https://{domain}" + (f":{port}" if port != 443 else "")
            return origin, domain
        port = cfg.public_port or cfg.port
        return f"http://127.0.0.1:{port}", "127.0.0.1"

    def handle_security_status(self, session: sqlite3.Row) -> None:
        with STATE.store.connect() as db:
            admin = db.execute(
                "SELECT totp_enabled,totp_pending_secret FROM admins WHERE id=?", (session["admin_id"],)
            ).fetchone()
            credentials = db.execute(
                "SELECT credential_id,name,transports,created_at,last_used_at FROM webauthn_credentials "
                "WHERE admin_id=? ORDER BY created_at DESC",
                (session["admin_id"],),
            ).fetchall()
            recovery = db.execute(
                "SELECT COUNT(*) FROM recovery_codes WHERE admin_id=? AND used_at IS NULL",
                (session["admin_id"],),
            ).fetchone()[0]
        self.send_json(
            HTTPStatus.OK,
            {
                "totp_enabled": bool(admin and admin["totp_enabled"]),
                "totp_pending": bool(admin and admin["totp_pending_secret"]),
                "passkey_available": self.webauthn_context() is not None,
                "passkeys": [dict(row) for row in credentials],
                "recovery_codes_remaining": int(recovery),
            },
        )

    def handle_totp_begin(self, session: sqlite3.Row) -> None:
        secret = generate_totp_secret()
        with STATE.store.connect() as db:
            db.execute(
                "UPDATE admins SET totp_pending_secret=?,updated_at=? WHERE id=?",
                (secret, utc_now(), session["admin_id"]),
            )
        uri = totp_uri(secret, session["username"])
        STATE.store.audit(session["username"], "totp_begin", "security", self.remote_ip)
        self.send_json(HTTPStatus.OK, {"secret": secret, "uri": uri})

    def handle_totp_qr(self, session: sqlite3.Row) -> None:
        with STATE.store.connect() as db:
            row = db.execute(
                "SELECT totp_pending_secret FROM admins WHERE id=?", (session["admin_id"],)
            ).fetchone()
        secret = str(row["totp_pending_secret"] if row else "")
        if not secret:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "totp_setup_not_started"})
            return
        uri = totp_uri(secret, session["username"])
        try:
            result = subprocess.run(
                ["qrencode", "-t", "PNG", "-l", "M", "-s", "6", "-m", "4", "-o", "-", "--", uri],
                capture_output=True, timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            result = None
        if not result or result.returncode != 0 or not result.stdout.startswith(b"\x89PNG"):
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "qr_generation_failed"})
            return
        self.send_bytes(HTTPStatus.OK, result.stdout, "image/png")

    def handle_totp_confirm(self, session: sqlite3.Row) -> None:
        payload = self.read_json() or {}
        code = str(payload.get("code", ""))
        with STATE.store.connect() as db:
            admin = db.execute(
                "SELECT totp_pending_secret FROM admins WHERE id=?", (session["admin_id"],)
            ).fetchone()
            secret = str(admin["totp_pending_secret"] if admin else "")
            if not secret or not verify_totp(secret, code):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_two_factor_code"})
                return
            db.execute(
                "UPDATE admins SET totp_secret=?,totp_pending_secret='',totp_enabled=1,updated_at=? WHERE id=?",
                (secret, utc_now(), session["admin_id"]),
            )
            db.execute("DELETE FROM sessions WHERE admin_id=? AND token_hash<>?", (
                session["admin_id"], sha256_text(self.cookie_token()),
            ))
        STATE.store.audit(session["username"], "totp_enabled", "security", self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_totp_disable(self, session: sqlite3.Row) -> None:
        payload = self.read_json() or {}
        password = str(payload.get("password", ""))[:512]
        code = str(payload.get("code", ""))[:16]
        admin, method = STATE.authenticate_with_method(session["username"], password)
        if not admin or method != "password" or not verify_totp(str(admin["totp_secret"]), code):
            self.send_json(HTTPStatus.FORBIDDEN, {"error": "security_verification_failed"})
            return
        with STATE.store.connect() as db:
            db.execute(
                "UPDATE admins SET totp_secret='',totp_pending_secret='',totp_enabled=0,updated_at=? WHERE id=?",
                (utc_now(), session["admin_id"]),
            )
        STATE.store.audit(session["username"], "totp_disabled", "security", self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_passkey_register_begin(self, session: sqlite3.Row) -> None:
        context = self.webauthn_context()
        if context is None:
            self.send_json(HTTPStatus.CONFLICT, {"error": "passkey_unavailable"})
            return
        origin, rp_id = context
        challenge_id, challenge = STATE.create_webauthn_challenge(
            "register", self.remote_ip, int(session["admin_id"])
        )
        with STATE.store.connect() as db:
            existing = [
                {"type": "public-key", "id": row[0]}
                for row in db.execute(
                    "SELECT credential_id FROM webauthn_credentials WHERE admin_id=?",
                    (session["admin_id"],),
                ).fetchall()
            ]
        self.send_json(
            HTTPStatus.OK,
            {
                "challenge_id": challenge_id,
                "publicKey": {
                    "challenge": challenge,
                    "rp": {"id": rp_id, "name": "RR Nexus"},
                    "user": {
                        "id": b64url_encode(int(session["admin_id"]).to_bytes(8, "big")),
                        "name": session["username"],
                        "displayName": session["username"],
                    },
                    "pubKeyCredParams": [
                        {"type": "public-key", "alg": -7},
                        {"type": "public-key", "alg": -257},
                        {"type": "public-key", "alg": -8},
                    ],
                    "timeout": 60000,
                    "attestation": "none",
                    "authenticatorSelection": {
                        "residentKey": "required", "requireResidentKey": True,
                        "userVerification": "required",
                    },
                    "excludeCredentials": existing,
                },
                "origin": origin,
            },
        )

    def handle_passkey_register_finish(self, session: sqlite3.Row) -> None:
        payload = self.read_json() or {}
        context = self.webauthn_context()
        challenge_row = STATE.consume_webauthn_challenge(
            str(payload.get("challenge_id", "")), "register", self.remote_ip
        )
        if context is None or not challenge_row or int(challenge_row["admin_id"] or 0) != int(session["admin_id"]):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_passkey_challenge"})
            return
        try:
            origin, rp_id = context
            credential = parse_registration(
                str(payload.get("client_data", "")),
                str(payload.get("attestation", "")),
                str(challenge_row["challenge"]), origin, rp_id,
                payload.get("transports") if isinstance(payload.get("transports"), list) else [],
            )
            credential_id = b64url_encode(credential.credential_id)
            if payload.get("credential_id") and not safe_compare(
                credential_id, str(payload.get("credential_id"))
            ):
                raise ValueError("credential id mismatch")
            name = str(payload.get("name", "通行密钥")).strip()[:64] or "通行密钥"
            with STATE.store.connect() as db:
                db.execute(
                    "INSERT INTO webauthn_credentials(credential_id,admin_id,name,public_key_pem,"
                    "algorithm,sign_count,transports,created_at) VALUES(?,?,?,?,?,?,?,?)",
                    (credential_id, session["admin_id"], name, credential.public_key_pem,
                     credential.algorithm, credential.sign_count, credential.transports, utc_now()),
                )
        except (ValueError, RuntimeError, sqlite3.IntegrityError) as exc:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "passkey_registration_failed", "message": str(exc)[:160]})
            return
        STATE.store.audit(session["username"], "passkey_added", credential_id, self.remote_ip, name)
        self.send_json(HTTPStatus.CREATED, {"ok": True, "credential_id": credential_id})

    def handle_passkey_login_begin(self) -> None:
        context = self.webauthn_context()
        if context is None:
            self.send_json(HTTPStatus.CONFLICT, {"error": "passkey_unavailable"})
            return
        with STATE.store.connect() as db:
            count = db.execute("SELECT COUNT(*) FROM webauthn_credentials").fetchone()[0]
        if not count:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "no_passkeys"})
            return
        _origin, rp_id = context
        try:
            challenge_id, challenge = STATE.create_webauthn_challenge("login", self.remote_ip)
        except ValueError:
            self.send_json(
                HTTPStatus.TOO_MANY_REQUESTS,
                {"error": "too_many_attempts", "retry_after": 60},
                {"Retry-After": "60"},
            )
            return
        self.send_json(
            HTTPStatus.OK,
            {"challenge_id": challenge_id, "publicKey": {
                "challenge": challenge, "rpId": rp_id, "timeout": 60000,
                "userVerification": "required",
            }},
        )

    def handle_passkey_login_finish(self) -> None:
        payload = self.read_json() or {}
        context = self.webauthn_context()
        challenge_row = STATE.consume_webauthn_challenge(
            str(payload.get("challenge_id", "")), "login", self.remote_ip
        )
        if context is None or not challenge_row:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_passkey_challenge"})
            return
        credential_id = str(payload.get("credential_id", ""))[:2048]
        with STATE.store.connect() as db:
            row = db.execute(
                "SELECT c.*,a.username FROM webauthn_credentials c JOIN admins a ON a.id=c.admin_id "
                "WHERE c.credential_id=?", (credential_id,),
            ).fetchone()
        if not row:
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid_passkey"})
            return
        try:
            origin, rp_id = context
            sign_count = verify_authentication(
                str(payload.get("client_data", "")), str(payload.get("authenticator_data", "")),
                str(payload.get("signature", "")), str(challenge_row["challenge"]), origin, rp_id,
                bytes(row["public_key_pem"]), int(row["algorithm"]), int(row["sign_count"]),
            )
        except Exception as exc:
            STATE.record_login_failure(self.remote_ip, str(row["username"]))
            STATE.store.audit(str(row["username"]), "passkey_failed", credential_id, self.remote_ip, str(exc)[:160])
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "invalid_passkey"})
            return
        with STATE.store.connect() as db:
            db.execute(
                "UPDATE webauthn_credentials SET sign_count=?,last_used_at=? WHERE credential_id=?",
                (sign_count, utc_now(), credential_id),
            )
            admin = db.execute("SELECT * FROM admins WHERE id=?", (row["admin_id"],)).fetchone()
        STATE.clear_login_failures(self.remote_ip, str(row["username"]))
        self.finish_login(admin, "passkey")

    def handle_passkey_delete(self, session: sqlite3.Row, credential_id: str) -> None:
        with STATE.store.connect() as db:
            cursor = db.execute(
                "DELETE FROM webauthn_credentials WHERE credential_id=? AND admin_id=?",
                (credential_id, session["admin_id"]),
            )
        if cursor.rowcount == 0:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "passkey_not_found"})
            return
        STATE.store.audit(session["username"], "passkey_deleted", credential_id, self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_notifications_update(self, session: sqlite3.Row) -> None:
        try:
            settings = STATE.notifications.update(self.read_json() or {})
        except (ValueError, TypeError) as exc:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
            return
        STATE.store.audit(session["username"], "notifications_updated", "alerts", self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True, "settings": settings})

    def handle_notifications_test(self, session: sqlite3.Row) -> None:
        ok, detail = STATE.notifications.emit(
            "test", "info", "RR-vps 告警测试", "如果你收到这条消息，告警通道配置正常。",
            f"test:{epoch_now()}", minimum_interval=0, force=True,
        )
        STATE.store.audit(session["username"], "notifications_test", "alerts", self.remote_ip, detail)
        self.send_json(HTTPStatus.OK if ok else HTTPStatus.BAD_GATEWAY, {"ok": ok, "detail": detail})

    def handle_overview(self) -> None:
        today = datetime.now(timezone.utc).date().isoformat()
        active_cutoff = (datetime.now(timezone.utc) - timedelta(seconds=300)).isoformat(timespec="seconds")
        with STATE.store.connect() as db:
            counts = db.execute(
                "SELECT COUNT(*) total, COALESCE(SUM(CASE WHEN enabled=1 "
                "AND (expires_at IS NULL OR expires_at='' OR expires_at>=?) "
                "AND (quota_bytes=0 OR used_bytes<quota_bytes) THEN 1 ELSE 0 END),0) enabled, "
                "COALESCE(SUM(CASE WHEN enabled=1 AND traffic_updated_at IS NOT NULL "
                "AND traffic_updated_at>=? THEN 1 ELSE 0 END),0) active, "
                "COALESCE(SUM(used_bytes),0) used, "
                "COALESCE(SUM(uploaded_bytes),0) uploaded, "
                "COALESCE(SUM(downloaded_bytes),0) downloaded FROM devices",
                (today, active_cutoff),
            ).fetchone()
        service_states: dict[str, str] = {}
        for service in ("sing-box", "rr-nexus", "cloudflared"):
            result = subprocess.run(["systemctl", "is-active", service], text=True, capture_output=True, timeout=3, check=False)
            state = result.stdout.strip() or "inactive"
            if service == "cloudflared" and state != "active":
                # 快速隧道模式（TUNNEL_MODE=1）无 systemd 服务，进程存活即运行中
                try:
                    pg = subprocess.run(["pgrep", "-x", "cloudflared"], capture_output=True, timeout=3, check=False)
                    if pg.returncode == 0:
                        state = "active"
                except Exception:
                    pass
            service_states[service] = state
        security_info = {"recent_lockouts": 0, "locked_ips": 0}
        try:
            since = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
            with STATE.store.connect() as db2:
                row = db2.execute(
                    "SELECT COUNT(*) FROM audit_log WHERE action='bruteforce_locked' AND created_at>=?",
                    (since,),
                ).fetchone()
                security_info["recent_lockouts"] = row[0] if row else 0
                locked_rows = db2.execute(
                    "SELECT COUNT(DISTINCT remote_ip) FROM login_failures WHERE failed_at>=?",
                    (epoch_now() - LOGIN_WINDOW,),
                ).fetchone()
                security_info["locked_ips"] = locked_rows[0] if locked_rows else 0
        except Exception:
            pass
        self.send_json(
            HTTPStatus.OK,
            {
                "devices": dict(counts),
                "services": service_states,
                "traffic": STATE.traffic.status_snapshot(),
                "server_plan": server_traffic_snapshot(STATE.store),
                "security": security_info,
                "mode": STATE.config.mode,
                "domain": STATE.config.domain,
                "port": STATE.config.port,
                "ssh_host": STATE.config.ssh_host,
                "now": utc_now(),
            },
        )

    def device_rows(self) -> list[dict[str, Any]]:
        with STATE.store.connect() as db:
            rows = db.execute(
                "SELECT d.id,d.name,d.enabled,d.quota_bytes,d.used_bytes,d.uploaded_bytes,"
                "d.downloaded_bytes,d.traffic_updated_at,d.expires_at,d.created_at,d.updated_at,"
                "d.quota_reached_at,d.next_reset_at,d.reset_anchor_day,d.reset_max,d.reset_count,"
                "d.group_id,g.name group_name,g.color group_color "
                "FROM devices d LEFT JOIN device_groups g ON g.id=d.group_id "
                "ORDER BY d.created_at DESC"
            ).fetchall()
        result: list[dict[str, Any]] = []
        today = datetime.now(timezone.utc).date().isoformat()
        for row in rows:
            item = dict(row)
            item["enabled"] = bool(item["enabled"])
            expired = bool(item["expires_at"] and item["expires_at"] < today)
            quota_exhausted = bool(item["quota_bytes"] > 0 and item["used_bytes"] >= item["quota_bytes"])
            item["active"] = bool(item["enabled"] and not expired and not quota_exhausted)
            item["status_reason"] = "expired" if expired else "quota" if quota_exhausted else "paused" if not item["enabled"] else "active"
            item["reset_remaining"] = max(0, int(item["reset_max"] or 0) - int(item["reset_count"] or 0))
            # 自动删除倒计时（仅在额度用尽且有记录时间戳时计算），返回剩余秒数，前端格式化
            item["auto_delete_seconds_left"] = None
            if quota_exhausted and item["quota_reached_at"]:
                try:
                    reached = datetime.fromisoformat(item["quota_reached_at"])
                    if reached.tzinfo is None:
                        reached = reached.replace(tzinfo=timezone.utc)
                    remaining = QUOTA_AUTO_DELETE_SECONDS - (datetime.now(timezone.utc) - reached).total_seconds()
                    item["auto_delete_seconds_left"] = max(0, int(remaining))
                except ValueError:
                    item["auto_delete_seconds_left"] = None
            result.append(item)
        return result

    def handle_devices(self) -> None:
        self.send_json(
            HTTPStatus.OK,
            {
                "devices": self.device_rows(),
                "traffic": STATE.traffic.status_snapshot(),
            },
        )

    def handle_device_groups(self) -> None:
        with STATE.store.connect() as db:
            rows = db.execute(
                "SELECT g.id,g.name,g.color,g.created_at,g.updated_at,COUNT(d.id) device_count "
                "FROM device_groups g LEFT JOIN devices d ON d.group_id=g.id "
                "GROUP BY g.id ORDER BY g.name COLLATE NOCASE"
            ).fetchall()
        self.send_json(HTTPStatus.OK, {"groups": [dict(row) for row in rows]})

    def _group_payload(self) -> tuple[dict[str, str], str]:
        payload = self.read_json() or {}
        name = str(payload.get("name", "")).strip()
        color = str(payload.get("color", "#4f8cff")).strip().lower()
        if not DEVICE_NAME_RE.fullmatch(name):
            return {}, "invalid_group_name"
        if not re.fullmatch(r"#[0-9a-f]{6}", color):
            return {}, "invalid_group_color"
        return {"name": name, "color": color}, ""

    def handle_device_group_create(self, session: sqlite3.Row) -> None:
        values, error = self._group_payload()
        if error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return
        try:
            with STATE.store.connect() as db:
                cursor = db.execute(
                    "INSERT INTO device_groups(name,color,created_at,updated_at) VALUES(?,?,?,?)",
                    (values["name"], values["color"], utc_now(), utc_now()),
                )
                group_id = cursor.lastrowid
        except sqlite3.IntegrityError:
            self.send_json(HTTPStatus.CONFLICT, {"error": "duplicate_group"})
            return
        STATE.store.audit(session["username"], "group_create", str(group_id), self.remote_ip, values["name"])
        self.send_json(HTTPStatus.CREATED, {"ok": True, "id": group_id})

    def handle_device_group_update(self, session: sqlite3.Row, group_id: int) -> None:
        values, error = self._group_payload()
        if error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return
        try:
            with STATE.store.connect() as db:
                cursor = db.execute(
                    "UPDATE device_groups SET name=?,color=?,updated_at=? WHERE id=?",
                    (values["name"], values["color"], utc_now(), group_id),
                )
        except sqlite3.IntegrityError:
            self.send_json(HTTPStatus.CONFLICT, {"error": "duplicate_group"})
            return
        if cursor.rowcount == 0:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "group_not_found"})
            return
        STATE.store.audit(session["username"], "group_update", str(group_id), self.remote_ip, values["name"])
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_device_group_delete(self, session: sqlite3.Row, group_id: int) -> None:
        with STATE.store.connect() as db:
            row = db.execute("SELECT name FROM device_groups WHERE id=?", (group_id,)).fetchone()
            if row:
                db.execute("DELETE FROM device_groups WHERE id=?", (group_id,))
        if not row:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "group_not_found"})
            return
        STATE.store.audit(session["username"], "group_delete", str(group_id), self.remote_ip, row["name"])
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_device_templates(self) -> None:
        with STATE.store.connect() as db:
            rows = db.execute("SELECT * FROM device_templates ORDER BY name COLLATE NOCASE").fetchall()
        self.send_json(HTTPStatus.OK, {"templates": [dict(row) for row in rows]})

    def _template_payload(self, partial: bool = False) -> tuple[dict[str, Any], str]:
        payload = self.read_json() or {}
        values: dict[str, Any] = {}
        if "name" in payload or not partial:
            name = str(payload.get("name", "")).strip()
            if not DEVICE_NAME_RE.fullmatch(name):
                return {}, "invalid_template_name"
            values["name"] = name
        number_fields = {
            "quota_gb": (0, 10240), "expiry_days": (0, 3650), "reset_max": (0, MAX_AUTO_RESET_COUNT)
        }
        for key, (minimum, maximum) in number_fields.items():
            if key not in payload and partial:
                continue
            try:
                value = float(payload.get(key, 0)) if key == "quota_gb" else int(payload.get(key, 0))
            except (TypeError, ValueError):
                return {}, "invalid_template_value"
            if value < minimum or value > maximum:
                return {}, "invalid_template_value"
            values["quota_bytes" if key == "quota_gb" else key] = (
                int(value * 1024**3) if key == "quota_gb" else int(value)
            )
        if "enabled" in payload or not partial:
            if not isinstance(payload.get("enabled", True), bool):
                return {}, "invalid_enabled"
            values["enabled"] = int(payload.get("enabled", True))
        return values, ""

    def handle_device_template_create(self, session: sqlite3.Row) -> None:
        values, error = self._template_payload()
        if error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return
        try:
            with STATE.store.connect() as db:
                cursor = db.execute(
                    "INSERT INTO device_templates(name,quota_bytes,expiry_days,reset_max,enabled,created_at,updated_at) "
                    "VALUES(?,?,?,?,?,?,?)",
                    (values["name"], values["quota_bytes"], values["expiry_days"], values["reset_max"],
                     values["enabled"], utc_now(), utc_now()),
                )
                template_id = cursor.lastrowid
        except sqlite3.IntegrityError:
            self.send_json(HTTPStatus.CONFLICT, {"error": "duplicate_template"})
            return
        STATE.store.audit(session["username"], "template_create", str(template_id), self.remote_ip, values["name"])
        self.send_json(HTTPStatus.CREATED, {"ok": True, "id": template_id})

    def handle_device_template_update(self, session: sqlite3.Row, template_id: int) -> None:
        values, error = self._template_payload(partial=True)
        if error or not values:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error or "empty_update"})
            return
        columns = [f"{key}=?" for key in values]
        try:
            with STATE.store.connect() as db:
                cursor = db.execute(
                    f"UPDATE device_templates SET {','.join(columns)},updated_at=? WHERE id=?",
                    [*values.values(), utc_now(), template_id],
                )
        except sqlite3.IntegrityError:
            self.send_json(HTTPStatus.CONFLICT, {"error": "duplicate_template"})
            return
        if cursor.rowcount == 0:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "template_not_found"})
            return
        STATE.store.audit(session["username"], "template_update", str(template_id), self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_device_template_delete(self, session: sqlite3.Row, template_id: int) -> None:
        with STATE.store.connect() as db:
            cursor = db.execute("DELETE FROM device_templates WHERE id=?", (template_id,))
        if cursor.rowcount == 0:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "template_not_found"})
            return
        STATE.store.audit(session["username"], "template_delete", str(template_id), self.remote_ip)
        self.send_json(HTTPStatus.OK, {"ok": True})

    def handle_devices_batch(self, session: sqlite3.Row) -> None:
        payload = self.read_json() or {}
        raw_ids = payload.get("device_ids")
        if not isinstance(raw_ids, list):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_device_ids"})
            return
        device_ids = list(dict.fromkeys(str(item) for item in raw_ids))
        if not device_ids or len(device_ids) > MAX_DEVICES or any(not DEVICE_ID_RE.fullmatch(item) for item in device_ids):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_device_ids"})
            return
        action = str(payload.get("action", ""))
        placeholders = ",".join("?" for _ in device_ids)
        changed = 0
        sync_required = action not in {"move_group"}
        now = utc_now()
        with STATE.store.connect() as db:
            existing = db.execute(
                f"SELECT id FROM devices WHERE id IN ({placeholders})", device_ids
            ).fetchall()
            existing_ids = [row["id"] for row in existing]
            if not existing_ids:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "device_not_found"})
                return
            actual = ",".join("?" for _ in existing_ids)
            if action in {"enable", "disable"}:
                cursor = db.execute(
                    f"UPDATE devices SET enabled=?,updated_at=? WHERE id IN ({actual})",
                    [1 if action == "enable" else 0, now, *existing_ids],
                )
            elif action == "reset":
                cursor = db.execute(
                    f"UPDATE devices SET used_bytes=0,uploaded_bytes=0,downloaded_bytes=0,"
                    f"traffic_updated_at=NULL,quota_reached_at=NULL,updated_at=? WHERE id IN ({actual})",
                    [now, *existing_ids],
                )
            elif action == "delete":
                cursor = db.execute(f"DELETE FROM devices WHERE id IN ({actual})", existing_ids)
            elif action == "move_group":
                raw_group = payload.get("group_id")
                try:
                    group_id = None if raw_group in (None, "", 0, "0") else int(raw_group)
                except (TypeError, ValueError):
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_group"})
                    return
                if group_id is not None and not db.execute(
                    "SELECT 1 FROM device_groups WHERE id=?", (group_id,)
                ).fetchone():
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_group"})
                    return
                cursor = db.execute(
                    f"UPDATE devices SET group_id=?,updated_at=? WHERE id IN ({actual})",
                    [group_id, now, *existing_ids],
                )
            elif action == "apply_template":
                try:
                    template_id = int(payload.get("template_id", 0))
                except (TypeError, ValueError):
                    template_id = 0
                template = db.execute(
                    "SELECT * FROM device_templates WHERE id=?", (template_id,)
                ).fetchone()
                if not template:
                    self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_template"})
                    return
                expiry = None
                if int(template["expiry_days"] or 0) > 0:
                    expiry = (
                        datetime.now(timezone.utc).date() + timedelta(days=int(template["expiry_days"]))
                    ).isoformat()
                reset_max = int(template["reset_max"] or 0)
                next_reset = None
                reset_anchor = 0
                if reset_max > 0:
                    today = datetime.now(timezone.utc).date()
                    first_reset = add_calendar_month(today, today.day)
                    next_reset = first_reset.isoformat()
                    reset_anchor = first_reset.day
                    expiry = add_calendar_months(first_reset, reset_max, reset_anchor).isoformat()
                cursor = db.execute(
                    f"UPDATE devices SET quota_bytes=?,enabled=?,expires_at=?,next_reset_at=?,"
                    f"reset_anchor_day=?,reset_max=?,reset_count=0,quota_reached_at=NULL,"
                    f"expiry_enforced_at=NULL,updated_at=? WHERE id IN ({actual})",
                    [template["quota_bytes"], template["enabled"], expiry, next_reset,
                     reset_anchor, reset_max, now, *existing_ids],
                )
            else:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_batch_action"})
                return
            changed = cursor.rowcount
        STATE.store.audit(
            session["username"], "device_batch", action, self.remote_ip,
            f"count={changed};ids={','.join(device_ids[:20])}",
        )
        if sync_required:
            self._deferred_sync(session["username"], "device_batch", action, f"count={changed}")
        self.send_json(
            HTTPStatus.OK,
            {"ok": True, "changed": changed, "sync": "deferred" if sync_required else "not_required"},
        )

    @staticmethod
    def metric_window(query: dict[str, list[str]]) -> tuple[str, int, int]:
        name = str(query.get("range", ["24h"])[0]).lower()
        windows = {
            "24h": (24 * 3600, TRAFFIC_BUCKET_SECONDS),
            "7d": (7 * 24 * 3600, 3600),
            "30d": (30 * 24 * 3600, 6 * 3600),
        }
        seconds, step = windows.get(name, windows["24h"])
        return name if name in windows else "24h", seconds, step

    def handle_traffic(self, query: dict[str, list[str]] | None = None) -> None:
        range_name, window_seconds, step = self.metric_window(query or {})
        cutoff = epoch_now() - window_seconds
        with STATE.store.connect() as db:
            samples = db.execute(
                "SELECT (bucket / ?) * ? bucket,SUM(uploaded_bytes) uploaded_bytes,"
                "SUM(downloaded_bytes) downloaded_bytes FROM traffic_samples "
                "WHERE bucket>=? GROUP BY (bucket / ?) ORDER BY bucket",
                (step, step, cutoff, step),
            ).fetchall()
            totals = db.execute(
                "SELECT COALESCE(SUM(uploaded_bytes),0) uploaded, "
                "COALESCE(SUM(downloaded_bytes),0) downloaded, "
                "COALESCE(SUM(used_bytes),0) used FROM devices"
            ).fetchone()
        devices = sorted(
            self.device_rows(),
            key=lambda item: int(item["used_bytes"]),
            reverse=True,
        )
        self.send_json(
            HTTPStatus.OK,
            {
                "totals": dict(totals),
                "samples": [dict(row) for row in samples],
                "devices": devices[:20],
                "status": STATE.traffic.status_snapshot(),
                "bucket_seconds": step,
                "range": range_name,
                "server_plan": server_traffic_snapshot(STATE.store),
            },
        )

    def handle_metrics(self, query: dict[str, list[str]]) -> None:
        range_name, window_seconds, step = self.metric_window(query)
        cutoff = epoch_now() - window_seconds
        with STATE.store.connect() as db:
            rows = db.execute(
                "SELECT (bucket / ?) * ? bucket,AVG(cpu_percent) cpu_percent,"
                "AVG(memory_percent) memory_percent,MAX(disk_percent) disk_percent,"
                "AVG(load1) load1 FROM system_samples WHERE bucket>=? "
                "GROUP BY (bucket / ?) ORDER BY bucket",
                (step, step, cutoff, step),
            ).fetchall()
        self.send_json(
            HTTPStatus.OK,
            {"range": range_name, "bucket_seconds": step, "samples": [dict(row) for row in rows]},
        )

    def handle_server_traffic_policy(self) -> None:
        STATE.traffic.collect_server_traffic()
        self.send_json(HTTPStatus.OK, {"policy": server_traffic_snapshot(STATE.store)})

    def handle_update_server_traffic_policy(self, session: sqlite3.Row | dict) -> None:
        payload = self.read_json() or {}
        try:
            quota_gb = float(payload.get("quota_gb", 0))
        except (TypeError, ValueError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_server_quota"})
            return
        mode = str(payload.get("count_mode", "both") or "both")
        interface = str(payload.get("interface_name", "") or "").strip()
        calibrate_usage = "current_used_gb" in payload
        current_used_gb = 0.0
        if calibrate_usage:
            try:
                current_used_gb = float(payload.get("current_used_gb"))
            except (TypeError, ValueError):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_current_usage"})
                return
        if quota_gb < 0 or quota_gb > MAX_SERVER_TRAFFIC_GB:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_server_quota"})
            return
        if calibrate_usage and (current_used_gb < 0 or current_used_gb > MAX_SERVER_TRAFFIC_GB):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_current_usage"})
            return
        if mode not in SERVER_TRAFFIC_MODES:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_traffic_mode"})
            return
        if interface and interface not in network_interfaces():
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_network_interface"})
            return
        # 先收齐保存前的最后一段网卡差值。若管理员校准当前已用量，随后
        # 会以输入值重新立基线，避免把面板安装前的运营商用量漏掉或重复累加。
        STATE.traffic.collect_server_traffic()
        quota_bytes = int(quota_gb * 1024**3)
        with STATE.store.connect() as db:
            old = db.execute(
                "SELECT interface_name FROM server_traffic_policy WHERE id=1"
            ).fetchone()
            changed_interface = bool(old and str(old["interface_name"] or "") != interface)
            db.execute(
                "UPDATE server_traffic_policy SET quota_bytes=?,count_mode=?,interface_name=?,"
                "last_interface=CASE WHEN ? THEN '' ELSE last_interface END,"
                "last_rx_counter=CASE WHEN ? THEN NULL ELSE last_rx_counter END,"
                "last_tx_counter=CASE WHEN ? THEN NULL ELSE last_tx_counter END,updated_at=? WHERE id=1",
                (
                    quota_bytes, mode, interface,
                    1 if changed_interface else 0,
                    1 if changed_interface else 0,
                    1 if changed_interface else 0,
                    utc_now(),
                ),
            )
            if calibrate_usage:
                db.execute(
                    "UPDATE server_traffic_policy SET received_bytes=0,transmitted_bytes=0,"
                    "initial_used_bytes=?,last_interface='',last_rx_counter=NULL,last_tx_counter=NULL,"
                    "updated_at=? WHERE id=1",
                    (int(current_used_gb * 1024**3), utc_now()),
                )
        STATE.traffic.collect_server_traffic()
        detail = f"quota_gb={quota_gb};mode={mode};interface={interface or 'auto'}"
        if calibrate_usage:
            detail += f";current_used_gb={current_used_gb}"
        STATE.store.audit(session["username"], "server_traffic_policy", "server", self.remote_ip, detail)
        self.send_json(HTTPStatus.OK, {"ok": True, "policy": server_traffic_snapshot(STATE.store)})

    def handle_reset_server_traffic_policy(self, session: sqlite3.Row | dict) -> None:
        payload = self.read_json() or {}
        try:
            initial_gb = float(payload.get("initial_used_gb", 0) or 0)
        except (TypeError, ValueError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_initial_usage"})
            return
        if initial_gb < 0 or initial_gb > MAX_SERVER_TRAFFIC_GB:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_initial_usage"})
            return
        now = utc_now()
        with STATE.store.connect() as db:
            db.execute(
                "UPDATE server_traffic_policy SET received_bytes=0,transmitted_bytes=0,"
                "initial_used_bytes=?,last_interface='',last_rx_counter=NULL,last_tx_counter=NULL,"
                "cycle_started_at=?,updated_at=? WHERE id=1",
                (int(initial_gb * 1024**3), now, now),
            )
        STATE.traffic.collect_server_traffic()
        STATE.store.audit(
            session["username"], "server_traffic_reset", "server", self.remote_ip,
            f"initial_used_gb={initial_gb}",
        )
        self.send_json(HTTPStatus.OK, {"ok": True, "policy": server_traffic_snapshot(STATE.store)})

    def handle_audit(self) -> None:
        with STATE.store.connect() as db:
            rows = db.execute(
                "SELECT created_at,actor,action,target,remote_ip,detail FROM audit_log ORDER BY id DESC LIMIT 30"
            ).fetchall()
        self.send_json(HTTPStatus.OK, {"events": [dict(row) for row in rows]})

    def validate_device_payload(self, payload: dict[str, Any], partial: bool = False) -> tuple[dict[str, Any], str]:
        values: dict[str, Any] = {}
        if "name" in payload or not partial:
            name = str(payload.get("name", "")).strip()
            if not DEVICE_NAME_RE.fullmatch(name):
                return {}, "invalid_name"
            values["name"] = name
        if "quota_gb" in payload or not partial:
            try:
                quota_gb = float(payload.get("quota_gb", 0))
            except (TypeError, ValueError):
                return {}, "invalid_quota"
            if quota_gb < 0 or quota_gb > 10240:
                return {}, "invalid_quota"
            values["quota_bytes"] = int(quota_gb * 1024**3)
        if "expires_at" in payload:
            expires_at = str(payload.get("expires_at") or "")
            if expires_at and (not DATE_RE.fullmatch(expires_at) or parse_date(expires_at) is None):
                return {}, "invalid_expiry"
            values["expires_at"] = expires_at or None
        schedule_requested = "reset_at" in payload or "reset_max" in payload
        if schedule_requested:
            reset_at = str(payload.get("reset_at") or "")
            try:
                reset_max = int(payload.get("reset_max") or 0)
            except (TypeError, ValueError):
                return {}, "invalid_reset_schedule"
            if not reset_at and reset_max == 0:
                values.update(
                    next_reset_at=None,
                    reset_anchor_day=0,
                    reset_max=0,
                    reset_count=0,
                )
            else:
                first_reset = parse_date(reset_at)
                if (
                    first_reset is None
                    or first_reset < datetime.now(timezone.utc).date()
                    or not 1 <= reset_max <= MAX_AUTO_RESET_COUNT
                ):
                    return {}, "invalid_reset_schedule"
                try:
                    plan_expiry = add_calendar_months(first_reset, reset_max, first_reset.day)
                except (OverflowError, ValueError):
                    return {}, "invalid_reset_schedule"
                values.update(
                    next_reset_at=first_reset.isoformat(),
                    reset_anchor_day=first_reset.day,
                    reset_max=reset_max,
                    reset_count=0,
                    expires_at=plan_expiry.isoformat(),
                )
        if "enabled" in payload:
            if not isinstance(payload["enabled"], bool):
                return {}, "invalid_enabled"
            values["enabled"] = 1 if payload["enabled"] else 0
        if "group_id" in payload:
            raw_group = payload.get("group_id")
            if raw_group in (None, "", 0, "0"):
                values["group_id"] = None
            else:
                try:
                    group_id = int(raw_group)
                except (TypeError, ValueError):
                    return {}, "invalid_group"
                with STATE.store.connect() as db:
                    exists = db.execute("SELECT 1 FROM device_groups WHERE id=?", (group_id,)).fetchone()
                if not exists:
                    return {}, "invalid_group"
                values["group_id"] = group_id
        return values, ""

    
    def handle_change_password(self, session: sqlite3.Row | dict) -> None:
        try:
            body = self.read_json()
            if body is None:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
                return
            op = str(body.get("old_password", ""))
            np = str(body.get("new_password", ""))
            if not op or not np:
                return self.send_json(HTTPStatus.BAD_REQUEST, {"error": "密码不能为空"})
            if len(op) > 512 or not MIN_ADMIN_PASSWORD_LENGTH <= len(np) <= 512:
                return self.send_json(
                    HTTPStatus.BAD_REQUEST,
                    {"error": "invalid_new_password", "message": "新密码需为 12–512 个字符"},
                )
            un = session["username"]
            for attempt in range(3):
                try:
                    outcome = None
                    with STATE.store.connect() as db:
                        row = db.execute("SELECT password_hash FROM admins WHERE username=?", (un,)).fetchone()
                        if not row:
                            outcome = "not_found"
                            break
                        try:
                            password_ok = STATE.password_hasher.verify(row["password_hash"], op)
                        except (VerifyMismatchError, InvalidHash):
                            password_ok = False
                        if not password_ok:
                            outcome = "bad_password"
                            break
                        db.execute(
                            "UPDATE admins SET password_hash=?,updated_at=? WHERE username=?",
                            (STATE.password_hasher.hash(np), utc_now(), un),
                        )
                        db.execute(
                            "DELETE FROM sessions WHERE admin_id=? AND token_hash<>?",
                            (session["admin_id"], sha256_text(self.cookie_token())),
                        )
                        outcome = "ok"
                    # 事务已提交，审计用独立连接（避免事务内嵌套连接死锁）
                    if outcome == "ok":
                        STATE.store.audit(un, "change_password", "security", self.remote_ip)
                        self.send_json(HTTPStatus.OK, {"ok": True})
                    elif outcome == "bad_password":
                        STATE.store.audit(un, "change_password_failed", "security", self.remote_ip)
                        self.send_json(HTTPStatus.FORBIDDEN, {"error": "旧密码不正确"})
                    else:
                        self.send_json(HTTPStatus.NOT_FOUND, {"error": "用户不存在"})
                    break
                except sqlite3.OperationalError as e:
                    if "locked" in str(e).lower() and attempt < 2:
                        time.sleep(0.6)
                        continue
                    raise
        except Exception as e:
            self.send_json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": str(e)[:100]})
    def _deferred_sync(self, actor: str, action: str, device_id: str, note: str) -> None:
        """后台线程执行节点同步：HTTP 响应先返回，sing-box 重启引起的瞬时断连
        （管理员若经本节点代理上网会被掐断）不再让前端误判为失败。
        同步结果只落审计（<action>_synced / <action>_sync_failed），不阻塞请求。"""
        def _run() -> None:
            try:
                ok, detail = STATE.sync_devices()
                STATE.store.audit(
                    actor,
                    "{}_synced".format(action) if ok else "{}_sync_failed".format(action),
                    device_id,
                    "local",
                    detail or note,
                )
            except Exception as exc:  # 后台兜底：绝不抛出到线程外
                try:
                    STATE.store.audit(actor, "{}_sync_error".format(action), device_id, "local", str(exc)[:200])
                except Exception:
                    pass
        threading.Thread(target=_run, daemon=True).start()

    def handle_create_device(self, session: sqlite3.Row) -> None:
        payload = self.read_json()
        if payload is None:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
            return
        template_id = payload.get("template_id")
        if template_id not in (None, "", 0, "0"):
            try:
                template_key = int(template_id)
            except (TypeError, ValueError):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_template"})
                return
            with STATE.store.connect() as db:
                template = db.execute("SELECT * FROM device_templates WHERE id=?", (template_key,)).fetchone()
            if not template:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_template"})
                return
            payload = dict(payload)
            # 7.1 前端会先把模板值回填到表单，允许管理员随后微调。
            # 旧前端仍会提交 quota_gb=0 等默认值；没有此标记时以模板为准，
            # 防止浏览器缓存导致“选了模板却创建成不限流量”。
            template_values_applied = payload.get("template_values_applied") is True
            if not template_values_applied:
                payload["quota_gb"] = int(template["quota_bytes"]) / 1024**3
            payload.setdefault("enabled", bool(template["enabled"]))
            expiry_days = int(template["expiry_days"] or 0)
            reset_max = int(template["reset_max"] or 0)
            if expiry_days > 0 and not payload.get("expires_at"):
                payload["expires_at"] = (
                    datetime.now(timezone.utc).date() + timedelta(days=expiry_days)
                ).isoformat()
            if reset_max > 0 and not payload.get("reset_at"):
                first_reset = add_calendar_month(datetime.now(timezone.utc).date(), datetime.now(timezone.utc).day)
                payload["reset_at"] = first_reset.isoformat()
                payload["reset_max"] = reset_max
        values, error = self.validate_device_payload(payload)
        if error:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error})
            return
        device_id = "dev_" + secrets.token_hex(6)
        credential = str(uuid.uuid4())
        subscription_token = secrets.token_urlsafe(24)
        now = utc_now()
        with STATE.store.connect() as db:
            if db.execute("SELECT COUNT(*) FROM devices").fetchone()[0] >= MAX_DEVICES:
                self.send_json(HTTPStatus.CONFLICT, {"error": "device_limit_reached", "message": "设备数量已达到 500 台安全上限"})
                return
            # 设备备注名唯一：避免用户误以为失败而重复提交产生同名设备
            dup = db.execute("SELECT id FROM devices WHERE name=?", (values["name"],)).fetchone()
            if dup:
                self.send_json(
                    HTTPStatus.CONFLICT,
                    {"error": "duplicate_name", "message": "设备备注「{}」已存在（{}），请勿重复添加；若刚才已提交，请直接刷新列表查看".format(values["name"], dup["id"])},
                )
                return
            db.execute(
                "INSERT INTO devices(id,name,credential,subscription_token,enabled,"
                "quota_bytes,used_bytes,uploaded_bytes,downloaded_bytes,traffic_updated_at,"
                "group_id,expires_at,next_reset_at,reset_anchor_day,reset_max,reset_count,created_at,updated_at) "
                "VALUES(?,?,?,?,?, ?,0,0,0,NULL,?,?,?,?,?,0,?,?)",
                (
                    device_id, values["name"], credential, subscription_token,
                    values.get("enabled", 1), values["quota_bytes"], values.get("group_id"),
                    values.get("expires_at"),
                    values.get("next_reset_at"), values.get("reset_anchor_day", 0),
                    values.get("reset_max", 0), now, now,
                ),
            )
        STATE.store.audit(session["username"], "device_create", device_id, self.remote_ip, values["name"])
        self._deferred_sync(session["username"], "device_create", device_id, values["name"])
        self.send_json(
            HTTPStatus.CREATED,
            {"ok": True, "id": device_id, "sync": "deferred",
             "message": "设备已添加，节点配置正在后台同步（几秒后生效，不影响现有用户在线）"},
        )

    def handle_reset_device(self, session: sqlite3.Row, device_id: str) -> None:
        """重置设备流量，并可同时修改额度与每月自动重置计划。

        payload 可包含 quota_gb、reset_at、reset_max、expires_at。
        重置后清除 quota_reached_at（取消 35 天自动删除倒计时）。
        """
        payload = self.read_json() or {}
        new_quota: int | None = None
        if "quota_gb" in payload and payload["quota_gb"] not in (None, ""):
            try:
                quota_gb = float(payload["quota_gb"])
            except (TypeError, ValueError):
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_quota"})
                return
            if quota_gb < 0 or quota_gb > 10240:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_quota"})
                return
            new_quota = int(quota_gb * 1024**3)
        schedule_values: dict[str, Any] = {}
        if "reset_at" in payload or "reset_max" in payload or "expires_at" in payload:
            schedule_values, schedule_error = self.validate_device_payload(
                {key: payload[key] for key in ("reset_at", "reset_max", "expires_at") if key in payload},
                partial=True,
            )
            if schedule_error:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": schedule_error})
                return
        with STATE.store.connect() as db:
            old = db.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
            if not old:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "device_not_found"})
                return
            db.execute(
                "UPDATE devices SET used_bytes=0,uploaded_bytes=0,downloaded_bytes=0,"
                "traffic_updated_at=NULL,quota_reached_at=NULL,updated_at=? WHERE id=?",
                (utc_now(), device_id),
            )
            if new_quota is not None:
                db.execute(
                    "UPDATE devices SET quota_bytes=?,quota_reached_at=NULL WHERE id=?",
                    (new_quota, device_id),
                )
            if schedule_values:
                columns = [f"{key}=?" for key in schedule_values]
                db.execute(
                    f"UPDATE devices SET {','.join(columns)},expiry_enforced_at=NULL WHERE id=?",
                    list(schedule_values.values()) + [device_id],
                )
        detail_parts = [f"quota_gb={payload.get('quota_gb')}" if new_quota is not None else "keep_quota"]
        if schedule_values:
            detail_parts.append(f"reset_max={schedule_values.get('reset_max', 'keep')}")
        detail = ";".join(detail_parts)
        STATE.store.audit(session["username"], "device_reset", device_id, self.remote_ip, detail)
        self._deferred_sync(session["username"], "device_reset", device_id, detail)
        self.send_json(HTTPStatus.OK, {"ok": True, "sync": "deferred",
                                       "message": "流量已重置，节点配置正在后台同步"})

    def handle_update_device(self, session: sqlite3.Row, device_id: str) -> None:
        payload = self.read_json()
        if payload is None:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "invalid_request"})
            return
        values, error = self.validate_device_payload(payload, partial=True)
        if error or not values:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": error or "empty_update"})
            return
        requires_node_sync = any(key != "name" for key in values)
        if requires_node_sync:
            STATE.traffic.collect_once(trigger_sync=False)
        with STATE.store.connect() as db:
            old = db.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
            if not old:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "device_not_found"})
                return
            if "name" in values:
                duplicate = db.execute(
                    "SELECT id FROM devices WHERE name=? AND id<>?",
                    (values["name"], device_id),
                ).fetchone()
                if duplicate:
                    self.send_json(
                        HTTPStatus.CONFLICT,
                        {
                            "error": "duplicate_name",
                            "message": "设备备注「{}」已存在（{}），请换一个备注".format(
                                values["name"], duplicate["id"]
                            ),
                        },
                    )
                    return
            columns = [f"{key}=?" for key in values]
            parameters = list(values.values()) + [utc_now(), device_id]
            db.execute(f"UPDATE devices SET {','.join(columns)},updated_at=? WHERE id=?", parameters)
            # 增加额度（新额度 > 已用流量）时清除"额度用尽"时间戳，取消 35 天自动删除倒计时
            if values.get("quota_bytes", 0) > old["used_bytes"]:
                db.execute("UPDATE devices SET quota_reached_at=NULL WHERE id=?", (device_id,))
        STATE.store.audit(session["username"], "device_update", device_id, self.remote_ip, ",".join(values.keys()))
        if requires_node_sync:
            self._deferred_sync(session["username"], "device_update", device_id, ",".join(values.keys()))
            self.send_json(HTTPStatus.OK, {"ok": True, "sync": "deferred",
                                           "message": "修改已保存，节点配置正在后台同步"})
        else:
            # 纯备注修改只写管理数据库：不重启 sing-box、不刷新订阅，客户端
            # 节点名由随机设备别名生成，永远不会跟随管理员备注变化。
            self.send_json(HTTPStatus.OK, {"ok": True, "sync": "not_required",
                                           "message": "设备备注已保存，不影响订阅与节点名称"})

    def handle_delete_device(self, session: sqlite3.Row, device_id: str) -> None:
        STATE.traffic.collect_once(trigger_sync=False)
        with STATE.store.connect() as db:
            old = db.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()
            if not old:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "device_not_found"})
                return
            db.execute("DELETE FROM devices WHERE id=?", (device_id,))
        STATE.store.audit(session["username"], "device_delete", device_id, self.remote_ip, old["name"])
        self._deferred_sync(session["username"], "device_delete", device_id, old["name"])
        self.send_json(HTTPStatus.OK, {"ok": True, "sync": "deferred",
                                       "message": "设备已删除，节点配置正在后台同步"})

    def device_record(self, device_id: str) -> sqlite3.Row | None:
        with STATE.store.connect() as db:
            return db.execute("SELECT * FROM devices WHERE id=?", (device_id,)).fetchone()

    def subscription_file(self, device_id: str) -> Path:
        return STATE.config.subscription_root / f"{device_id}.txt"


    def _device_subscription_urls(self, device: dict) -> tuple[str, list[dict[str, str]]]:
        """Build every subscription URL shown or encoded by the panel.

        A real certificate domain can serve subscriptions through the panel's HTTPS
        routes.  Local mode and public IP mode use RR's plain HTTP subscription
        service instead: the latter panel is HTTPS-only with a self-signed
        certificate, which subscription clients cannot reliably trust.
        """
        device_id = str(device["id"])
        token = str(device["subscription_token"])
        # Shell-side subscription generation atomically refreshes ssh_host/sub_port
        # after entry-family or NAT mapping changes.  Reload here so QR URLs update
        # immediately without restarting the management panel.
        try:
            config = NexusConfig.load()
        except (OSError, ValueError, json.JSONDecodeError):
            config = STATE.config

        specs = [
            ("Sing-box 官方", "SFA / SFI / SFM · VMess、Reality、HY2、TUIC、AnyTLS、Naive", "json", ".json"),
            ("mihomo", "mihomo 核心 · 专用 YAML", "mihomo", "-mihomo.yaml"),
            ("Clash Verge", "Clash Verge Rev · 专用 YAML", "clash-verge", "-clash-verge.yaml"),
            ("FlClash", "FlClash · 专用 YAML", "flclash", "-flclash.yaml"),
            ("v2rayN", "v2rayN（Windows）· 全协议", "v2rayn", "-v2rayn.txt"),
            ("v2rayNG", "v2rayNG（安卓）· 全协议", "v2rayng", "-v2rayng.txt"),
            ("Shadowrocket", "Shadowrocket（iOS）· 全协议", "sr", "-sr.txt"),
            ("NekoBox", "NekoBox · 全协议", "nekobox", "-nekobox.txt"),
            ("通用链接", "URI 全集（通用，兼容旧客户端）", "txt", ".txt"),
        ]

        def artifact_exists(suffix: str, *, published: bool = False) -> bool:
            if published:
                return (config.published_subscription_root / f"{token}{suffix}").is_file()
            return (config.subscription_root / f"{device_id}{suffix}").is_file()

        if (
            config.mode == "public"
            and config.domain
            and config.domain != "ip"
            and not _is_ip_address(config.domain)
        ):
            port = config.public_port or config.port
            base = "https://{}".format(_url_host(config.domain))
            if port and port != 443:
                base = "{}:{}".format(base, port)
            subscription_url = f"{base}/sub/{device_id}/{token}/txt" if artifact_exists(".txt") else ""
            urls = [
                {"format": fmt, "name": name, "url": f"{base}/sub/{device_id}/{token}/{route}"}
                for fmt, name, route, suffix in specs
                if artifact_exists(suffix)
            ]
            return subscription_url, urls

        # 本地模式与公网 IP 直连模式均从主订阅服务取文件。sub_port 保存
        # 当前入口族对应的公网端口（普通 VPS 与本地监听端口相同；NAT/LXD
        # 则是服务商映射后的公网端口）。
        sub_port = getattr(config, "sub_port", 0)
        host = config.ssh_host or config.domain
        if not sub_port or not host:
            return "", []
        base = "http://{}:{}/nexus/{}".format(_url_host(host), sub_port, token)
        subscription_url = f"{base}.txt" if artifact_exists(".txt", published=True) else ""
        urls = [
            {"format": fmt, "name": name, "url": f"{base}{suffix}"}
            for fmt, name, _route, suffix in specs
            if artifact_exists(suffix, published=True)
        ]
        return subscription_url, urls

    def handle_device_links(self, device_id: str) -> None:
        device = self.device_record(device_id)
        path = self.subscription_file(device_id)
        if not device or not path.is_file():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "links_not_found"})
            return
        links = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
        subscription_url, subscription_urls = self._device_subscription_urls(device)
        # 自动优选状态与 Argo 实时信息（随主脚本实时读取，开/关即时同步到面板）
        # 自动优选状态以 worker 程序存在性为准（主脚本开关即增删 /usr/local/bin/auto_update_sub.py）
        auto_enabled = os.path.exists("/usr/local/bin/auto_update_sub.py")
        argo_domain = ""
        argo_edge_port = ""
        try:
            with open("/etc/argo_vmess.conf", "r", encoding="utf-8") as cf:
                for line in cf:
                    line = line.strip()
                    if line.startswith("ARGO_DOMAIN="):
                        argo_domain = line.split("=", 1)[1]
                    elif line.startswith("ARGO_EDGE_PORT="):
                        argo_edge_port = line.split("=", 1)[1]
        except OSError:
            pass
        self.send_json(HTTPStatus.OK, {
            "id": device_id,
            "links": links,
            "subscription_url": subscription_url,
            "subscription_urls": subscription_urls,
            "auto_update": {"enabled": auto_enabled},
            "argo": {"domain": argo_domain, "edge_port": argo_edge_port},
        })

    def _subscription_txt_url(self, device: dict) -> str:
        return self._device_subscription_urls(device)[0]

    def _qr_png_bytes(self, device_id: str, query: dict[str, list[str]]):
        """生成设备链接二维码 PNG。返回 (status, payload)：成功 payload 为 bytes，
        失败为错误 dict。handle_device_qr（本地）与远程 qr 透传共用。"""
        device = self.device_record(device_id)
        path = self.subscription_file(device_id)
        if not device or not path.is_file():
            return HTTPStatus.NOT_FOUND, {"error": "links_not_found"}
        if query.get("sub", ["0"])[0] == "1":
            link = self._subscription_txt_url(device)
            if not link:
                return HTTPStatus.BAD_REQUEST, {"error": "no_subscription_url"}
        elif query.get("raw", [""])[0]:
            # 只接受本设备实际展示的订阅 URL，防止二维码与面板文案/文件路由漂移。
            link = query["raw"][0]
            valid_urls = {item["url"] for item in self._device_subscription_urls(device)[1]}
            if link not in valid_urls:
                return HTTPStatus.BAD_REQUEST, {"error": "invalid_subscription_url"}
        else:
            links = [line for line in path.read_text(encoding="utf-8").splitlines() if line]
            try:
                index = int(query.get("index", ["0"])[0])
                if index < 0:
                    raise IndexError
                link = links[index]
            except (ValueError, IndexError):
                return HTTPStatus.BAD_REQUEST, {"error": "invalid_link_index"}
        try:
            # 4 模块静区符合 QR 规范；M 级纠错提升手机截图/相册识别率。
            result = subprocess.run(
                ["qrencode", "-t", "PNG", "-l", "M", "-s", "6", "-m", "4", "-o", "-", "--", link],
                capture_output=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "qr_generation_failed"}
        if result.returncode != 0 or not result.stdout.startswith(b"\x89PNG\r\n\x1a\n"):
            return HTTPStatus.INTERNAL_SERVER_ERROR, {"error": "qr_generation_failed"}
        return HTTPStatus.OK, result.stdout

    def handle_device_qr(self, device_id: str, query: dict[str, list[str]]) -> None:
        status, payload = self._qr_png_bytes(device_id, query)
        if status == HTTPStatus.OK and isinstance(payload, bytes):
            self.send_bytes(HTTPStatus.OK, payload, "image/png")
        else:
            self.send_json(status, payload)

    def handle_public_subscription(self, device_id: str, token: str, fmt: str = "txt") -> None:
        if STATE.config.mode != "public":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        device = self.device_record(device_id)
        path = self.subscription_file(device_id)
        suffixes = {
            "json": ".json",
            "yaml": ".yaml",  # 旧版 Clash Meta 地址继续兼容
            "vl": "-vl.json",  # 旧版 sing-box Reality 单节点地址继续兼容
            "mihomo": "-mihomo.yaml",
            "clash-verge": "-clash-verge.yaml",
            "flclash": "-flclash.yaml",
            "v2rayn": "-v2rayn.txt",
            "v2rayng": "-v2rayng.txt",
            "sr": "-sr.txt",
            "nekobox": "-nekobox.txt",
        }
        if fmt in suffixes:
            path = STATE.config.subscription_root / f"{device_id}{suffixes[fmt]}"
        if not device or not safe_compare(token, device["subscription_token"]):
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "subscription_not_found"})
            return
        expired = bool(device and device["expires_at"] and device["expires_at"] < datetime.now(timezone.utc).date().isoformat())
        quota_exhausted = bool(
            device
            and device["quota_bytes"] > 0
            and device["used_bytes"] >= device["quota_bytes"]
        )
        inactive = not device["enabled"] or expired or quota_exhausted
        if not inactive and not path.is_file():
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "subscription_not_found"})
            return
        encoded = (
            b""
            if inactive
            else enrich_subscription_content(path.read_bytes(), path.name, device)
        )
        alias = "RR-{}".format(device_id.removeprefix("dev_")[:8].upper())
        headers = {
            "Subscription-Userinfo": subscription_userinfo(device, STATE.config.traffic_mode),
            "Profile-Update-Interval": "1",
            "Profile-Title": alias,
            "Access-Control-Expose-Headers": "Subscription-Userinfo, Profile-Update-Interval, Profile-Title",
            "Cache-Control": "no-store",
        }
        self.send_bytes(
            HTTPStatus.OK,
            encoded,
            "text/plain; charset=utf-8",
            extra_headers=headers,
        )

    def serve_static(self, path: str) -> None:
        if path in {"", "/"}:
            file_path = STATIC_ROOT / "index.html"
        elif path in {"/app.css", "/app.js", "/admin.js", "/i18n.js", "/optimizer.js", "/optimizer.css"}:
            file_path = STATIC_ROOT / path.removeprefix("/")
        else:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "not_found"})
            return
        try:
            body = file_path.read_bytes()
        except OSError:
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "asset_not_found"})
            return
        content_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
        if content_type.startswith("text/") or content_type == "application/javascript":
            content_type += "; charset=utf-8"
        self.send_bytes(HTTPStatus.OK, body, content_type, cache=file_path.suffix in {".css", ".js"})


def initialize_admin(config: NexusConfig, username: str) -> int:
    username = username.strip()
    if not USERNAME_RE.fullmatch(username):
        print("管理员账号需以字母开头，仅含字母、数字、点、下划线或连字符（3–32 位）。", file=sys.stderr)
        return 2
    password = sys.stdin.readline().rstrip("\n")
    if not MIN_ADMIN_PASSWORD_LENGTH <= len(password) <= 512:
        print("管理员密码需为 12–512 个字符。", file=sys.stderr)
        return 2
    state = NexusState(config)
    password_hash = state.password_hasher.hash(password)
    now = utc_now()
    recovery_codes = [secrets.token_hex(5).upper() for _ in range(8)]
    with state.store.connect() as db:
        db.execute("DELETE FROM sessions")
        db.execute("DELETE FROM recovery_codes")
        db.execute("DELETE FROM admins")
        db.execute("DELETE FROM login_failures")
        cursor = db.execute(
            "INSERT INTO admins(username,password_hash,created_at,updated_at) VALUES(?,?,?,?)",
            (username, password_hash, now, now),
        )
        admin_id = cursor.lastrowid
        db.executemany(
            "INSERT INTO recovery_codes(code_hash,admin_id) VALUES(?,?)",
            [(sha256_text(code), admin_id) for code in recovery_codes],
        )
    state.store.audit(username, "admin_initialized", "admin", "local")
    print("RR_NEXUS_RECOVERY_CODES=" + ",".join(recovery_codes))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--init-admin", metavar="USERNAME")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--collect-traffic", action="store_true")
    args = parser.parse_args()
    config = NexusConfig.load()
    try:
        if args.init_admin:
            return initialize_admin(config, args.init_admin)
        if args.check:
            NexusState(config)
            if grpc is None:
                print("python3-grpcio is required", file=sys.stderr)
                return 2
            print("RR Nexus configuration OK")
            return 0
        global STATE
        STATE = NexusState(config)
    except StoreCorruptionError as exc:
        # T4：数据库损坏时明确拒绝启动（退出码 3；systemd 单元配置
        # RestartPreventExitStatus=3 阻止 Restart=on-failure 无限崩溃循环）。
        print(f"RR Nexus 数据库损坏，拒绝启动：{exc}", file=sys.stderr)
        print("数据安全优先，未自动重建。请从备份恢复 /var/lib/rr-nexus/nexus.db，", file=sys.stderr)
        print("或确认放弃现有数据后执行：", file=sys.stderr)
        print("  mv /var/lib/rr-nexus/nexus.db /var/lib/rr-nexus/nexus.db.corrupt", file=sys.stderr)
        print("再以 --init-admin <管理员名> 重新初始化。", file=sys.stderr)
        return 3
    if args.collect_traffic:
        ok, detail = STATE.traffic.collect_once(trigger_sync=False)
        if not ok:
            print(detail, file=sys.stderr)
            return 1
        return 0
    server = BoundedThreadingHTTPServer((config.listen, config.port), Handler)
    STATE.traffic.start()
    try:
        server.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        STATE.traffic.stop()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
