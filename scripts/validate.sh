#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$REPO_ROOT"

load_modules_for_tests() {
    local runtime_constants=""
    local module_file=""
    # Load the production constants without executing the root-only runtime
    # gate.  GitHub Actions deliberately runs validation as an unprivileged
    # user; the real rr/install entrypoints still source the complete file.
    runtime_constants=$(awk '/^if \[ "\$\{EUID/ { exit } { print }' modules/00-runtime.sh)
    eval "$runtime_constants"
    for module_file in modules/*.sh; do
        [ "$module_file" = "modules/00-runtime.sh" ] && continue
        # shellcheck disable=SC1090
        source "$module_file"
    done
}

echo "[1/13] Bash and Python syntax"
bash -n install.sh rr modules/*.sh
python3 -c 'compile(open("nexus/rr_nexus.py", encoding="utf-8").read(), "nexus/rr_nexus.py", "exec")'
python3 -c 'compile(open("nexus/sub_server.py", encoding="utf-8").read(), "nexus/sub_server.py", "exec")'
if command -v node >/dev/null 2>&1; then node --check nexus/static/app.js; fi

echo "[2/13] Combined module loading"
bash -c '
    for module_file in modules/*.sh; do
        [ "$module_file" = "modules/00-runtime.sh" ] && continue
        source "$module_file"
    done
    for required_function in \
        main_menu install_main do_update post_update_migrate \
        ensure_runtime_health generate_node_and_sub protocol_menu uninstall_all \
        nexus_menu sync_nexus_devices nexus_protocol_users; do
        declare -F "$required_function" >/dev/null || {
            echo "Missing function: $required_function" >&2
            exit 1
        }
    done
'

echo "[3/13] Fresh-install port selection regression"
(
    load_modules_for_tests
    PORT=0
    SUB_PORT=0
    VL_PORT=0
    AN_PORT=0
    HY2_PORT=0
    TU5_PORT=0

    tcp_port_in_use() { return 1; }
    udp_port_in_use() { return 1; }
    initial_port_available 23456 tcp
    initial_port_available 23457 udp

    PORT=23456
    if initial_port_available 23456 tcp; then
        echo "Already allocated TCP port was accepted." >&2
        exit 1
    fi
    PORT=0
    tcp_port_in_use() { return 0; }
    if initial_port_available 23458 tcp; then
        echo "Occupied TCP port was accepted." >&2
        exit 1
    fi

    tcp_port_in_use() { return 1; }
    selected_port=""
    prompt_initial_port selected_port "回归测试" tcp <<< ""
    is_valid_port "$selected_port"
)

echo "[4/13] Fresh-install snapshot regression"
version_function=$(awk '
    /^rr_version_ge\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' install.sh)
(
    eval "$version_function"
    rr_version_ge 7.0.2 7.0.2
    rr_version_ge 7.0.3 7.0.2
    if rr_version_ge 7.0.1 7.0.2; then
        echo "Bootstrap downgrade comparison accepted an older version." >&2
        exit 1
    fi
)
snapshot_function=$(awk '
    /^rr_snapshot_runtime\(\) \{/ { capture = 1 }
    capture { print }
    capture && /^}$/ { exit }
' install.sh)
(
    eval "$snapshot_function"
    BACKUP_DIR=""
    RR_LAUNCHER="/nonexistent/rr"
    rr_backup_file() { return 0; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    systemctl() { return 1; }
    pgrep() { return 1; }

    rr_snapshot_runtime
    [ -d "$BACKUP_DIR" ]
    [ ! -e "$BACKUP_DIR/singbox_was_running" ]
    [ ! -e "$BACKUP_DIR/nexus_was_running" ]
    [ ! -e "$BACKUP_DIR/health_timer_was_enabled" ]
    rm -rf "$BACKUP_DIR"
)
(
    eval "$snapshot_function"
    BACKUP_DIR=""
    RR_LAUNCHER="/nonexistent/rr"
    rr_backup_file() { return 0; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    systemctl() { return 0; }
    pgrep() { return 0; }

    rr_snapshot_runtime
    [ -e "$BACKUP_DIR/singbox_was_running" ]
    [ -e "$BACKUP_DIR/nexus_was_running" ]
    [ -e "$BACKUP_DIR/health_timer_was_enabled" ]
    rm -rf "$BACKUP_DIR"
)
(
    eval "$snapshot_function"
    BACKUP_DIR=""
    RR_LAUNCHER="/nonexistent/rr"
    rr_backup_file() { return 1; }
    rr_backup_dir() { return 0; }
    rr_backup_sqlite() { return 0; }
    systemctl() { return 1; }
    pgrep() { return 1; }

    if rr_snapshot_runtime; then
        echo "Snapshot unexpectedly ignored a real backup failure." >&2
        exit 1
    fi
    rm -rf "$BACKUP_DIR"
)

echo "[5/13] Fresh-install crypto material regression"
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-config"
    rm -f "$CONFIG_FILE"
    VL_ENABLED=true
    HY2_ENABLED=false
    PUBLIC_KEY=""
    SHORT_ID=""
    if validate_subscription_crypto_material >/dev/null 2>&1; then
        echo "Empty Reality material was accepted." >&2
        exit 1
    fi
    PUBLIC_KEY=$(printf 'a%.0s' {1..43})
    SHORT_ID=0123abcd
    validate_subscription_crypto_material

    # T10/A10：HY2 证书 pin 缺失必须降级（停用 HY2 并继续），不得整体判拒回滚。
    VL_ENABLED=false
    HY2_ENABLED=true
    CERT_SHA256=""
    if ! validate_subscription_crypto_material >/dev/null 2>&1; then
        echo "Missing Hysteria2 pin must degrade, not reject." >&2
        exit 1
    fi
    [ "$HY2_ENABLED" = "false" ] || {
        echo "Hysteria2 was not disabled on missing pin." >&2
        exit 1
    }
    CERT_SHA256=$(printf 'b%.0s' {1..64})
    HY2_ENABLED=true
    validate_subscription_crypto_material
    [ "$HY2_ENABLED" = "true" ] || {
        echo "Valid Hysteria2 pin was degraded unexpectedly." >&2
        exit 1
    }
    rm -f "$CONFIG_FILE"
)

# T10/A10：无 schema 旧配置不得默认视为已安装活节点（INSTALL_COMPLETE 保守为 false）。
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-noschema.conf"
    cat > "$CONFIG_FILE" <<'EOF'
PORT=443
UUID=0fe4575e-644a-4b16-877d-0ddf493bc1d1
HY2_ENABLED=true
HY2_PORT=8444
EOF
    load_config_with_defaults
    [ "$INSTALL_COMPLETE" = "false" ] || {
        echo "No-schema config must not default to INSTALL_COMPLETE=true." >&2
        exit 1
    }
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=6
PORT=443
UUID=0fe4575e-644a-4b16-877d-0ddf493bc1d1
EOF
    load_config_with_defaults
    [ "$INSTALL_COMPLETE" = "true" ] || {
        echo "Schema config must keep INSTALL_COMPLETE=true default." >&2
        exit 1
    }
    rm -f "$CONFIG_FILE"
)

# T10/B1：掩码凭据回归——旧版单文件 rr 会把掩码（首6+...+尾4，如 3b6007...2114）
# 写进 /etc/argo_vmess.conf；掩码必须被识别、重生成真值并回写，永不进入配置。
(
    load_modules_for_tests
    CONFIG_FILE="/tmp/rr-validate-mask.conf"
    cat > "$CONFIG_FILE" <<'EOF'
CONFIG_VERSION=7
PORT=443
UUID=3b6007...2114
NAIVE_ENABLED=true
NAIVE_USER=abc123...a1b2
NAIVE_PASS=987654...wxyz
EOF
    load_config_with_defaults
    is_masked_credential "$UUID" || { echo "Masked UUID not detected." >&2; exit 1; }
    is_masked_credential "$NAIVE_USER" || { echo "Masked NAIVE_USER not detected." >&2; exit 1; }
    is_masked_credential "$NAIVE_PASS" || { echo "Masked NAIVE_PASS not detected." >&2; exit 1; }
    is_masked_credential "3b6007...2114" || { echo "Strict mask pattern not detected." >&2; exit 1; }
    if is_masked_credential "0fe4575e-644a-4b16-877d-0ddf493bc1d1"; then
        echo "Real UUID flagged as masked." >&2
        exit 1
    fi
    if is_masked_credential ""; then
        echo "Empty value flagged as masked." >&2
        exit 1
    fi
    ensure_credential_integrity
    is_valid_uuid "$UUID" || { echo "UUID was not regenerated to a real value." >&2; exit 1; }
    if is_masked_credential "$NAIVE_USER"; then
        echo "NAIVE_USER still masked." >&2
        exit 1
    fi
    if is_masked_credential "$NAIVE_PASS"; then
        echo "NAIVE_PASS still masked." >&2
        exit 1
    fi
    [ "$(grep '^UUID=' "$CONFIG_FILE" | cut -d= -f2)" = "$UUID" ] || {
        echo "Regenerated UUID was not written back to the config file." >&2
        exit 1
    }
    if grep -q '\.\.\.' "$CONFIG_FILE"; then
        echo "Mask still present in config file." >&2
        exit 1
    fi
    rm -f "$CONFIG_FILE"
)

post_update_function=$(awk '
    /^post_update_migrate\(\) \{/ { capture = 1; depth = 0 }
    capture {
        print
        depth += gsub(/\{/, "{")
        depth -= gsub(/\}/, "}")
        if (depth == 0) exit
    }
' modules/60-update.sh)
(
    eval "$post_update_function"
    CONFIG_FILE="/tmp/rr-incomplete-config"
    : > "$CONFIG_FILE"
    check_supported_os() { return 0; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() { INSTALL_COMPLETE=false; return 0; }
    any_node_protocol_enabled() { return 1; }
    systemctl() { return 0; }
    pkill() { return 0; }
    sleep() { :; }
    post_update_migrate
    rm -f "$CONFIG_FILE"
)
(
    eval "$post_update_function"
    CONFIG_FILE="/tmp/rr-missing-config"
    rm -f "$CONFIG_FILE"
    check_supported_os() { return 0; }
    systemctl() {
        echo "Missing RR config triggered a service operation." >&2
        return 1
    }
    post_update_migrate
)

echo "[6/13] Subscription URL control-character regression"
(
    load_modules_for_tests
    # 常驻订阅进程必须在 sub_server.py 内容变化时重启。旧实现只比较
    # 端口和监听地址，导致热更新文件已替换但进程仍执行旧代码。
    rr_restart_tmp=$(mktemp -d)
    RR_LIB_DIR="$rr_restart_tmp/lib"
    SUB_ROOT="$rr_restart_tmp/root"
    SUB_PID_FILE="$rr_restart_tmp/sub.pid"
    SUB_BIND_STATE_FILE="$rr_restart_tmp/sub.bind"
    SUB_PORT=39291
    SUB_BIND_ADDRESS=127.0.0.1
    mkdir -p "$RR_LIB_DIR/nexus" "$SUB_ROOT"
    printf '%s\n' 'print("old")' > "$RR_LIB_DIR/nexus/sub_server.py"
    rr_old_signature=$(sha256sum "$RR_LIB_DIR/nexus/sub_server.py" | awk '{print $1}')
    printf '%s\n' 4242 > "$SUB_PID_FILE"
    printf '%s\n' "${SUB_PORT}|${SUB_BIND_ADDRESS}|${rr_old_signature}" > "$SUB_BIND_STATE_FILE"
    printf '%s\n' 'print("new")' > "$RR_LIB_DIR/nexus/sub_server.py"
    kill() { printf '%s\n' "$1" > "$rr_restart_tmp/killed"; }
    sleep() { :; }
    is_subscription_pid() { return 0; }
    nohup() { : > "$rr_restart_tmp/launched"; }
    start_subscription_server
    rr_new_signature=$(sha256sum "$RR_LIB_DIR/nexus/sub_server.py" | awk '{print $1}')
    [ "$(cat "$rr_restart_tmp/killed")" = 4242 ]
    [ -f "$rr_restart_tmp/launched" ]
    [ "$(cat "$SUB_BIND_STATE_FILE")" = "${SUB_PORT}|${SUB_BIND_ADDRESS}|${rr_new_signature}" ]
    rm -rf "$rr_restart_tmp"

    test_uuid="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
    url=$(build_subscription_url "45.192.205.71" 39291 "$test_uuid" jhsub_encoded.txt)
    [ "$url" = "http://45.192.205.71:39291/${test_uuid}/jhsub_encoded.txt" ]
    encoded_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" encoded)
    raw_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" raw)
    client_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" client)
    clash_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" clash)
    mihomo_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" mihomo)
    verge_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" clash-verge)
    flclash_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" flclash)
    [[ "$encoded_short_url" =~ ^http://45\.192\.205\.71:39291/s/[A-Za-z0-9_-]{12}$ ]]
    [[ "$raw_short_url" =~ ^http://45\.192\.205\.71:39291/r/[A-Za-z0-9_-]{12}$ ]]
    [[ "$client_short_url" =~ ^http://45\.192\.205\.71:39291/c/[A-Za-z0-9_-]{12}$ ]]
    [[ "$clash_short_url" =~ ^http://45\.192\.205\.71:39291/m/[A-Za-z0-9_-]{12}$ ]]
    [[ "$mihomo_short_url" =~ ^http://45\.192\.205\.71:39291/mm/[A-Za-z0-9_-]{12}$ ]]
    [[ "$verge_short_url" =~ ^http://45\.192\.205\.71:39291/vg/[A-Za-z0-9_-]{12}$ ]]
    [[ "$flclash_short_url" =~ ^http://45\.192\.205\.71:39291/fc/[A-Za-z0-9_-]{12}$ ]]
    [ "${#encoded_short_url}" -lt "${#url}" ]
    SUB_ROOT=$(mktemp -d)
    UUID="$test_uuid"
    mkdir -p "$SUB_ROOT/$UUID"
    printf '%s' 'dGVzdA==' > "$SUB_ROOT/$UUID/jhsub_encoded.txt"
    printf '%s\n' 'vless://test' > "$SUB_ROOT/$UUID/jhsub.txt"
    printf '%s\n' '{}' > "$SUB_ROOT/$UUID/client.json"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/clash_meta.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-mihomo.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-clash-verge.yaml"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/client-flclash.yaml"
    create_short_subscription_alias
    short_token=$(subscription_short_token "$UUID")
    [ "$(readlink "$SUB_ROOT/s/$short_token")" = "../${UUID}/jhsub_encoded.txt" ]
    [ "$(readlink "$SUB_ROOT/r/$short_token")" = "../${UUID}/jhsub.txt" ]
    [ "$(readlink "$SUB_ROOT/c/$short_token")" = "../${UUID}/client.json" ]
    [ "$(readlink "$SUB_ROOT/m/$short_token")" = "../${UUID}/clash_meta.yaml" ]
    [ "$(readlink "$SUB_ROOT/mm/$short_token")" = "../${UUID}/client-mihomo.yaml" ]
    [ "$(readlink "$SUB_ROOT/vg/$short_token")" = "../${UUID}/client-clash-verge.yaml" ]
    [ "$(readlink "$SUB_ROOT/fc/$short_token")" = "../${UUID}/client-flclash.yaml" ]
    [ -f "$SUB_ROOT/index.html" ]
    for route in s r c m mm vg fc; do
        [ -f "$SUB_ROOT/$route/index.html" ]
    done
    rm -f "$SUB_ROOT/$UUID/clash_meta.yaml"
    create_short_subscription_alias
    [ ! -e "$SUB_ROOT/m/$short_token" ]
    rm -rf "$SUB_ROOT"
    if build_subscription_url $'45.192.\n205.71' 39291 "$test_uuid" jhsub.txt >/dev/null 2>&1; then
        echo "Control character in subscription host was accepted." >&2
        exit 1
    fi
    qr_payload='vless://test@example.com:443?security=reality#RR-test'
    qrencode() {
        [ "$#" -eq 8 ] && [ "$1" = "-t" ] && [ "$2" = "ANSIUTF8" ] && \
            [ "$3" = "-l" ] && [ "$4" = "M" ] && [ "$5" = "-m" ] && \
            [ "$6" = "4" ] && [ "$7" = "--" ] && [ "$8" = "$qr_payload" ]
    }
    # shellcheck disable=SC2317
    render_terminal_qr "$qr_payload" "VLESS Reality 节点" >/dev/null
)

echo "[7/13] Ubuntu 22.04 Python and Argon2 compatibility"
if grep -En 'from datetime import.*\bUTC\b|datetime\.now\(UTC\)' nexus/rr_nexus.py; then
    echo "Python 3.11-only datetime.UTC usage was found." >&2
    exit 1
fi
argon2_stub=$(mktemp -d)
mkdir -p "$argon2_stub/argon2"
cat > "$argon2_stub/argon2/__init__.py" <<'PY'
class PasswordHasher:
    def __init__(self, *args, **kwargs):
        pass

    def hash(self, password):
        return "$argon2id$test"

    def verify(self, password_hash, password):
        return True

    def check_needs_rehash(self, password_hash):
        return False
PY
cat > "$argon2_stub/argon2/exceptions.py" <<'PY'
class InvalidHash(Exception):
    pass

class VerifyMismatchError(Exception):
    pass
PY
PYTHONPATH="$argon2_stub" python3 nexus/rr_nexus.py --help >/dev/null
argon2_config="$argon2_stub/nexus.json"
argon2_db="$argon2_stub/nexus.db"
jq -n --arg database "$argon2_db" --arg subscriptions "$argon2_stub/subscriptions" \
    '{mode:"local",listen:"127.0.0.1",port:7900,domain:"",database:$database,subscription_root:$subscriptions}' \
    > "$argon2_config"
init_output=$(printf '%s\n' 'StrongPassword123!' | \
    PYTHONPATH="$argon2_stub" RR_NEXUS_CONFIG="$argon2_config" \
    python3 nexus/rr_nexus.py --init-admin tester)
[[ "$init_output" == RR_NEXUS_RECOVERY_CODES=* ]]
PYTHONPATH="$argon2_stub" RR_NEXUS_CONFIG="$argon2_config" python3 - "$argon2_db" <<'PY'
import base64
import importlib.util
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    assert connection.execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 1
    columns = {row[1] for row in connection.execute("PRAGMA table_info(devices)")}
    assert {
        "uploaded_bytes", "downloaded_bytes", "traffic_updated_at", "next_reset_at",
        "reset_anchor_day", "reset_max", "reset_count",
    } <= columns
    assert connection.execute("SELECT COUNT(*) FROM server_traffic_policy WHERE id=1").fetchone()[0] == 1

spec = importlib.util.spec_from_file_location("rr_nexus", "nexus/rr_nexus.py")
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)

def field(number, wire, value):
    return module.encode_varint((number << 3) | wire) + value

def stat(name, value):
    encoded_name = name.encode()
    message = field(1, 2, module.encode_varint(len(encoded_name)) + encoded_name)
    message += field(2, 0, module.encode_varint(value))
    return field(1, 2, module.encode_varint(len(message)) + message)

payload = stat("user>>>dev_012345abcdef>>>traffic>>>uplink", 123)
payload += stat("user>>>dev_012345abcdef>>>traffic>>>downlink", 456)
payload += stat("inbound>>>ignored>>>traffic>>>uplink", 999)
counters = module.parse_query_stats_response(payload)
assert counters["user>>>dev_012345abcdef>>>traffic>>>uplink"] == 123
assert counters["user>>>dev_012345abcdef>>>traffic>>>downlink"] == 456
assert counters["inbound>>>ignored>>>traffic>>>uplink"] == 999

class FakeChannel:
    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def unary_unary(self, method, **kwargs):
        assert method == module.V2RAY_QUERY_METHOD
        assert kwargs["request_serializer"](b"x") == b"x"
        return self.call

    def call(self, request, timeout):
        assert request == b"\x10\x01\x1a\x07user>>>"
        assert timeout == 2.5
        return payload

class FakeGrpc:
    @staticmethod
    def insecure_channel(address):
        assert address == "127.0.0.1:39091"
        return FakeChannel()

module.grpc = FakeGrpc()
assert module.query_v2ray_stats("127.0.0.1:39091") == counters

config = module.NexusConfig.load()
assert config.port == 7900 and config.stats_port == 39091
assert config.ssh_host == "服务器IP"

# 二维码回归：域名模式必须走真证书 HTTPS；公网 IP/本地模式必须走主
# 订阅 HTTP 服务及其 NAT 公网端口；IPv6 URL 必须带方括号。
from pathlib import Path
from types import SimpleNamespace

config_path = Path(module.CONFIG_PATH)
base_config = {
    "listen": "127.0.0.1",
    "port": 7900,
    "database": sys.argv[1],
    "subscription_root": str(config_path.parent / "subscriptions"),
    "published_subscription_root": str(config_path.parent / "published" / "nexus"),
    "stats_port": 39091,
    "public_port": 9443,
    "sub_port": 39291,
}
device = {
    "id": "dev_012345abcdef",
    "subscription_token": "test_subscription_token_123456",
    "enabled": 1,
    "expires_at": None,
    "quota_bytes": 0,
    "used_bytes": 0,
    "uploaded_bytes": 123,
    "downloaded_bytes": 456,
}
handler = object.__new__(module.Handler)
artifact_root = config_path.parent / "subscriptions"
artifact_root.mkdir(parents=True, exist_ok=True)
published_root = config_path.parent / "published" / "nexus"
published_root.mkdir(parents=True, exist_ok=True)
artifact_suffixes = [
    "-vl.json", ".yaml", "-mihomo.yaml", "-clash-verge.yaml", "-flclash.yaml",
    "-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt", ".txt", ".json",
]
for suffix in artifact_suffixes:
    (artifact_root / f"{device['id']}{suffix}").write_text("test", encoding="utf-8")
    (published_root / f"{device['subscription_token']}{suffix}").write_text("test", encoding="utf-8")

def write_config(**values):
    payload = dict(base_config)
    payload.update(values)
    config_path.write_text(json.dumps(payload), encoding="utf-8")
    module.STATE = SimpleNamespace(config=module.NexusConfig.load())

write_config(mode="local", domain="", ssh_host="2001:db8::99")
local_primary, local_urls = handler._device_subscription_urls(device)
assert local_primary == "http://[2001:db8::99]:39291/nexus/test_subscription_token_123456.txt"
assert len(local_urls) == 9
assert [item["format"] for item in local_urls] == [
    "Sing-box 官方", "mihomo", "Clash Verge", "FlClash", "v2rayN",
    "v2rayNG", "Shadowrocket", "NekoBox", "通用链接",
]
assert all(item["url"].startswith("http://[2001:db8::99]:39291/nexus/") for item in local_urls)
# 不存在的格式不能继续显示一个注定 404 的二维码。
(published_root / f"{device['subscription_token']}.json").unlink()
assert all(item["format"] != "Sing-box 官方" for item in handler._device_subscription_urls(device)[1])
(published_root / f"{device['subscription_token']}.json").write_text("test", encoding="utf-8")

write_config(mode="public", domain="45.192.205.71", ssh_host="45.192.205.71")
ip_primary, ip_urls = handler._device_subscription_urls(device)
assert ip_primary == "http://45.192.205.71:39291/nexus/test_subscription_token_123456.txt"
assert all(":9443/sub/" not in item["url"] for item in ip_urls)

# 公网 IP/本地模式的地址必须能被真实的静态订阅服务逐一下载，且内容
# 与刚发布的文件完全一致（覆盖 NekoBox 的 Base64 地址）。
import functools
import threading
import urllib.request

sub_spec = importlib.util.spec_from_file_location("rr_sub_server", "nexus/sub_server.py")
sub_module = importlib.util.module_from_spec(sub_spec)
sys.modules[sub_spec.name] = sub_module
sub_spec.loader.exec_module(sub_module)
with sqlite3.connect(sys.argv[1]) as connection:
    now = module.utc_now()
    connection.execute(
        "INSERT OR REPLACE INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,?,?,?, ?,?,?,?)",
        (
            device["id"], "订阅头测试", "sub-header-credential", device["subscription_token"],
            1000, 579, device["uploaded_bytes"], device["downloaded_bytes"], "2030-01-31", now, now,
        ),
    )
static_handler = functools.partial(sub_module.SubscriptionHandler, directory=str(published_root.parent))
static_server = sub_module.ThreadingHTTPServer(("127.0.0.1", 0), static_handler)
static_server.config_path = config_path
static_thread = threading.Thread(target=static_server.serve_forever, daemon=True)
static_thread.start()
try:
    write_config(
        mode="public",
        domain="127.0.0.1",
        ssh_host="127.0.0.1",
        sub_port=static_server.server_port,
    )
    live_ip_primary, live_ip_urls = handler._device_subscription_urls(device)
    assert live_ip_primary.startswith(f"http://127.0.0.1:{static_server.server_port}/nexus/")
    for item in live_ip_urls:
        with urllib.request.urlopen(item["url"], timeout=2) as response:
            assert response.status == 200 and response.read() == b"test"
            assert response.headers["Subscription-Userinfo"] == (
                "upload=123; download=456; total=1000; expire=1896134399"
            )
            assert response.headers["Profile-Update-Interval"] == "1"

    # 有效订阅应在响应时动态插入首位信息项，源文件保持不变。URI/Base64
    # 使用 127.0.0.1:9 的 VMess 标记，确保 NekoBox 开启按“地址+端口+类型”
    # 去重后仍保留；Sing-box 与 mihomo 使用可连接的真实节点副本。
    info_raw = b"vless://id@example.com:443?security=reality#REAL\n"
    info_json = json.dumps({
        "outbounds": [
            {"type": "vless", "tag": "REAL", "server": "example.com", "server_port": 443, "uuid": "id"},
            {"type": "selector", "tag": "proxy", "default": "REAL", "outbounds": ["REAL"]},
        ]
    }).encode()
    info_yaml = b'''proxies:\n  - name: "REAL"\n    type: vless\n    server: example.com\n    port: 443\n\nproxy-groups:\n  - name: select\n    type: select\n    proxies:\n      - "REAL"\n'''
    (published_root / f"{device['subscription_token']}.txt").write_bytes(info_raw)
    for suffix in ("-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt"):
        (published_root / f"{device['subscription_token']}{suffix}").write_bytes(base64.b64encode(info_raw))
    (published_root / f"{device['subscription_token']}.json").write_bytes(info_json)
    (published_root / f"{device['subscription_token']}-mihomo.yaml").write_bytes(info_yaml)
    url_by_format = {item["format"]: item["url"] for item in live_ip_urls}

    def decode_info_marker(line):
        assert line.startswith("vmess://")
        encoded = line.removeprefix("vmess://")
        return json.loads(base64.b64decode(encoded + "=" * (-len(encoded) % 4)))

    with urllib.request.urlopen(url_by_format["通用链接"], timeout=2) as response:
        info_text = response.read().decode()
        info_lines = info_text.splitlines()
        assert info_lines[1].startswith("vless://") and len(info_lines) == 2
        marker = decode_info_marker(info_lines[0])
        assert marker["ps"].startswith("流量信息(勿选)｜已用")
        assert marker["add"] == "127.0.0.1" and marker["port"] == "9"
    for client_name in ("v2rayN", "v2rayNG", "Shadowrocket", "NekoBox"):
        with urllib.request.urlopen(url_by_format[client_name], timeout=2) as response:
            client_lines = base64.b64decode(response.read()).decode().splitlines()
            assert client_lines[1].startswith("vless://") and len(client_lines) == 2
            marker = decode_info_marker(client_lines[0])
            assert marker["ps"].startswith("流量信息(勿选)｜已用")
            # NekoBox 的去重键是协议类型+地址+端口；该组合必须与真实节点不同。
            assert (marker["add"], marker["port"]) == ("127.0.0.1", "9")
    with urllib.request.urlopen(url_by_format["Sing-box 官方"], timeout=2) as response:
        singbox_info = json.loads(response.read())
        assert singbox_info["outbounds"][0]["tag"].startswith("流量信息(勿选)｜已用")
        assert singbox_info["outbounds"][0]["server"] == "example.com"
        assert singbox_info["outbounds"][2]["outbounds"][0].startswith("流量信息(勿选)｜已用")
    with urllib.request.urlopen(url_by_format["mihomo"], timeout=2) as response:
        clash_info = response.read().decode()
        assert clash_info.index("流量信息(勿选)｜已用") < clash_info.index("REAL")
        assert clash_info.count("server: example.com") == 2
    assert (published_root / f"{device['subscription_token']}.txt").read_bytes() == info_raw

    # 公网域名路由由 rr_nexus 自身提供，必须和独立 sub_server 产生完全
    # 相同的标记，不能只修本地/公网 IP 模式。
    rr_body = module.enrich_subscription_content(
        base64.b64encode(info_raw), "device-nekobox.txt",
        {"used_bytes": 579, "quota_bytes": 1000, "expires_at": "2030-01-31"},
    )
    rr_lines = base64.b64decode(rr_body).decode().splitlines()
    assert decode_info_marker(rr_lines[0])["add"] == "127.0.0.1"

    # 单向计费时响应头也必须以 used_bytes 为准，否则客户端卡片会把真实
    # 下行量再次相加，和信息节点/面板额度出现不同数字。
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute(
            "UPDATE devices SET used_bytes=123,uploaded_bytes=123,downloaded_bytes=456 WHERE id=?",
            (device["id"],),
        )
    write_config(
        mode="public", domain="127.0.0.1", ssh_host="127.0.0.1",
        sub_port=static_server.server_port, traffic_mode="upload",
    )
    with urllib.request.urlopen(url_by_format["NekoBox"], timeout=2) as response:
        assert response.headers["Subscription-Userinfo"] == (
            "upload=123; download=0; total=1000; expire=1896134399"
        )
        marker = decode_info_marker(base64.b64decode(response.read()).decode().splitlines()[0])
        assert "已用123B" in marker["ps"]
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute(
            "UPDATE devices SET used_bytes=579,uploaded_bytes=123,downloaded_bytes=456 WHERE id=?",
            (device["id"],),
        )
    write_config(
        mode="public", domain="127.0.0.1", ssh_host="127.0.0.1",
        sub_port=static_server.server_port, traffic_mode="both",
    )

    # 额度用尽后仍返回空订阅和用量头，让客户端更新剩余流量，同时节点已被撤销。
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute("UPDATE devices SET used_bytes=quota_bytes WHERE id=?", (device["id"],))
    with urllib.request.urlopen(live_ip_primary, timeout=2) as response:
        assert response.status == 200 and response.read() == b""
        assert "total=1000" in response.headers["Subscription-Userinfo"]
    with sqlite3.connect(sys.argv[1]) as connection:
        connection.execute("UPDATE devices SET used_bytes=579 WHERE id=?", (device["id"],))
finally:
    static_server.shutdown()
    static_server.server_close()
    static_thread.join(timeout=2)

write_config(mode="public", domain="panel.example.com", ssh_host="45.192.205.71", public_port=443)
domain_primary, domain_urls = handler._device_subscription_urls(device)
assert domain_primary == "https://panel.example.com/sub/dev_012345abcdef/test_subscription_token_123456/txt"
assert len(domain_urls) == 9
assert [item["url"].rsplit("/", 1)[-1] for item in domain_urls] == [
    "json", "mihomo", "clash-verge", "flclash", "v2rayn",
    "v2rayng", "sr", "nekobox", "txt",
]

# 后端必须把每个节点/订阅的原文完整交给 qrencode，并使用 M 级纠错与
# 4 模块静区；无效订阅 URL、负索引和 qrencode 超时必须受控失败。
links = [
    "vmess://dGVzdA==",
    "vless://test@example.com:443?security=reality#VL",
    "hysteria2://test@example.com:8443?insecure=1#HY2",
    "tuic://test:test@example.com:8444#TUIC",
    "anytls://test@example.com:8445#AnyTLS",
    "naive+https://test:password@example.com:443#Naive",
]
links_path = artifact_root / "dev_012345abcdef.txt"
links_path.write_text("\n".join(links) + "\n", encoding="utf-8")
handler.device_record = lambda device_id: device if device_id == device["id"] else None
handler.subscription_file = lambda device_id: links_path
captured = []

def fake_run(argv, **kwargs):
    captured.append((argv, kwargs))
    return SimpleNamespace(returncode=0, stdout=b"\x89PNG\r\n\x1a\nqr")

real_run = module.subprocess.run
module.subprocess.run = fake_run
try:
    for index, expected in enumerate(links):
        status, png = handler._qr_png_bytes(device["id"], {"index": [str(index)]})
        assert status == module.HTTPStatus.OK and png.startswith(b"\x89PNG")
        argv, kwargs = captured[-1]
        assert argv[-2:] == ["--", expected]
        assert argv[argv.index("-l") + 1] == "M"
        assert argv[argv.index("-m") + 1] == "4"
        assert kwargs["timeout"] == 5
    for config_values, mode_urls in (
        ({"mode": "local", "domain": "", "ssh_host": "2001:db8::99"}, local_urls),
        ({"mode": "public", "domain": "45.192.205.71", "ssh_host": "45.192.205.71"}, ip_urls),
        ({"mode": "public", "domain": "panel.example.com", "ssh_host": "45.192.205.71", "public_port": 443}, domain_urls),
    ):
        write_config(**config_values)
        for item in mode_urls:
            status, _ = handler._qr_png_bytes(device["id"], {"raw": [item["url"]]})
            assert status == module.HTTPStatus.OK
            assert captured[-1][0][-1] == item["url"]
    assert handler._qr_png_bytes(device["id"], {"raw": ["https://invalid.example/sub"]})[0] == module.HTTPStatus.BAD_REQUEST
    assert handler._qr_png_bytes(device["id"], {"index": ["-1"]})[0] == module.HTTPStatus.BAD_REQUEST
finally:
    module.subprocess.run = real_run

module.subprocess.run = lambda *args, **kwargs: (_ for _ in ()).throw(module.subprocess.TimeoutExpired("qrencode", 5))
try:
    assert handler._qr_png_bytes(device["id"], {"index": ["0"]})[0] == module.HTTPStatus.INTERNAL_SERVER_ERROR
finally:
    module.subprocess.run = real_run

# 公网订阅路由必须逐格式返回精确文件，文件缺失时返回 404，绝不能回退
# 到通用 URI 原文冒充 JSON/YAML/Base64 订阅。
route_suffixes = {
    "txt": ".txt",
    "json": ".json",
    "yaml": ".yaml",
    "vl": "-vl.json",
    "mihomo": "-mihomo.yaml",
    "clash-verge": "-clash-verge.yaml",
    "flclash": "-flclash.yaml",
    "v2rayn": "-v2rayn.txt",
    "v2rayng": "-v2rayng.txt",
    "sr": "-sr.txt",
    "nekobox": "-nekobox.txt",
}
sent = []
handler.send_bytes = lambda status, body, content_type, **kwargs: sent.append((status, body, content_type, kwargs))
handler.send_json = lambda status, body: sent.append((status, body, "json"))
for route, suffix in route_suffixes.items():
    expected = ("payload:" + route).encode()
    artifact = artifact_root / f"{device['id']}{suffix}"
    artifact.write_bytes(expected)
    sent.clear()
    handler.handle_public_subscription(device["id"], device["subscription_token"], route)
    assert sent[0][:3] == (module.HTTPStatus.OK, expected, "text/plain; charset=utf-8")
    userinfo = sent[0][3]["extra_headers"]["Subscription-Userinfo"]
    assert userinfo == "upload=0; download=0; total=0; expire=0"

missing = artifact_root / f"{device['id']}-v2rayng.txt"
missing.unlink()
sent.clear()
handler.handle_public_subscription(device["id"], device["subscription_token"], "v2rayng")
assert sent and sent[0][0] == module.HTTPStatus.NOT_FOUND

# 纯备注修改必须只写管理数据库：不得触发流量采集、节点重启或订阅刷新。
store = module.Store(Path(sys.argv[1]))
with store.connect() as db:
    now = module.utc_now()
    db.execute(
        "INSERT OR REPLACE INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,0,0,0,0,NULL,?,?)",
        (device["id"], "旧管理备注", "01234567-89ab-4cde-8fab-0123456789ab", device["subscription_token"], now, now),
    )
    db.execute(
        "INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,created_at,updated_at) "
        "VALUES(?,?,?,?,1,0,0,0,0,NULL,?,?)",
        ("dev_deadbeef0000", "已存在备注", "11234567-89ab-4cde-8fab-0123456789ab", "other_subscription_token_123", now, now),
    )

class NoTrafficSync:
    def collect_once(self, **kwargs):
        raise AssertionError("name-only update collected traffic")

module.STATE = SimpleNamespace(config=module.NexusConfig.load(), store=store, traffic=NoTrafficSync())
rename_handler = object.__new__(module.Handler)
rename_handler.client_address = ("127.0.0.1", 12345)
rename_handler.headers = {}
rename_handler.read_json = lambda: {"name": "新管理备注"}
rename_handler._deferred_sync = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError("name-only update synced nodes"))
rename_sent = []
rename_handler.send_json = lambda status, body: rename_sent.append((status, body))
rename_handler.handle_update_device({"username": "tester"}, device["id"])
assert rename_sent[-1][0] == module.HTTPStatus.OK
assert rename_sent[-1][1]["sync"] == "not_required"
with store.connect() as db:
    assert db.execute("SELECT name FROM devices WHERE id=?", (device["id"],)).fetchone()[0] == "新管理备注"

rename_handler.read_json = lambda: {"name": "已存在备注"}
rename_handler.handle_update_device({"username": "tester"}, device["id"])
assert rename_sent[-1][0] == module.HTTPStatus.CONFLICT
assert rename_sent[-1][1]["error"] == "duplicate_name"

# 每月自动重置：额度保持原值、用量归零、自然月日期不漂移，次数用尽后
# 由预先计算的 expires_at 到期。35 天宽限常量也必须锁定。
assert module.QUOTA_AUTO_DELETE_SECONDS == 35 * 86400
assert module.add_calendar_month(module.parse_date("2027-01-31"), 31).isoformat() == "2027-02-28"
assert module.add_calendar_month(module.parse_date("2027-02-28"), 31).isoformat() == "2027-03-31"
future = module.datetime.now(module.timezone.utc).date() + module.timedelta(days=10)
schedule_values, schedule_error = handler.validate_device_payload(
    {"name": "计划测试", "quota_gb": 10, "reset_at": future.isoformat(), "reset_max": 6}
)
assert not schedule_error
assert schedule_values["next_reset_at"] == future.isoformat()
assert schedule_values["reset_max"] == 6 and schedule_values["reset_count"] == 0
assert schedule_values["expires_at"] == module.add_calendar_months(future, 6, future.day).isoformat()
_, invalid_schedule = handler.validate_device_payload(
    {"name": "错误计划", "quota_gb": 10, "reset_at": "2020-01-01", "reset_max": 6}
)
assert invalid_schedule == "invalid_reset_schedule"

due = module.datetime.now(module.timezone.utc).date() - module.timedelta(days=1)
plan_expiry = module.add_calendar_months(due, 2, due.day)
with store.connect() as db:
    now = module.utc_now()
    db.execute(
        "INSERT INTO devices(id,name,credential,subscription_token,enabled,quota_bytes,"
        "used_bytes,uploaded_bytes,downloaded_bytes,expires_at,next_reset_at,reset_anchor_day,"
        "reset_max,reset_count,created_at,updated_at) VALUES(?,?,?,?,1,?,?,?,?,?,?,?,?,?,?,?)",
        (
            "dev_aabbccddeeff", "月度计划", "monthly-credential", "monthly-sub-token",
            1000, 1000, 400, 600, plan_expiry.isoformat(), due.isoformat(), due.day, 2, 0, now, now,
        ),
    )

class ScheduledState:
    def __init__(self):
        self.store = store
        self.config = module.NexusConfig.load()
        self.sync_count = 0

    def sync_devices(self):
        self.sync_count += 1
        return True, "ok"

scheduled_state = ScheduledState()
collector = module.TrafficCollector(scheduled_state)
collector.apply_scheduled_resets(True)
with store.connect() as db:
    scheduled = db.execute(
        "SELECT quota_bytes,used_bytes,uploaded_bytes,downloaded_bytes,reset_count,next_reset_at "
        "FROM devices WHERE id='dev_aabbccddeeff'"
    ).fetchone()
assert scheduled["quota_bytes"] == 1000
assert scheduled["used_bytes"] == scheduled["uploaded_bytes"] == scheduled["downloaded_bytes"] == 0
assert scheduled["reset_count"] == 1
assert scheduled["next_reset_at"] == module.add_calendar_month(due, due.day).isoformat()
assert scheduled_state.sync_count == 1

# 服务器套餐使用宿主机网卡原始计数器；重启后沿用持久化基线，计数器回绕
# 或服务器重启时只重建基线，不能产生巨额假流量。
samples = iter([
    ("eth0", 1000, 2000),
    ("eth0", 1600, 2900),
    ("eth0", 1700, 3100),
    ("eth0", 50, 60),
])
real_counters = module.read_network_counters
real_interfaces = module.network_interfaces
module.read_network_counters = lambda configured="": next(samples)
module.network_interfaces = lambda: ["eth0"]
try:
    collector.collect_server_traffic()
    collector.collect_server_traffic()
    module.TrafficCollector(scheduled_state).collect_server_traffic()
    module.TrafficCollector(scheduled_state).collect_server_traffic()
finally:
    module.read_network_counters = real_counters
    module.network_interfaces = real_interfaces
with store.connect() as db:
    host = db.execute(
        "SELECT received_bytes,transmitted_bytes FROM server_traffic_policy WHERE id=1"
    ).fetchone()
assert host["received_bytes"] == 700 and host["transmitted_bytes"] == 1100

# 管理员可在不重开计费周期的情况下校准当前已用量。校准会清零历史网卡
# 差值并以输入值重立基线，后续采集只累加新流量；本地/远程共用该处理器。
class PolicyTraffic:
    def __init__(self):
        self.calls = 0

    def collect_server_traffic(self):
        self.calls += 1

policy_traffic = PolicyTraffic()
module.STATE = SimpleNamespace(config=module.NexusConfig.load(), store=store, traffic=policy_traffic)
policy_handler = object.__new__(module.Handler)
policy_handler.client_address = ("127.0.0.1", 12345)
policy_handler.headers = {}
policy_handler.read_json = lambda: {
    "quota_gb": 100,
    "current_used_gb": 50,
    "count_mode": "both",
    "interface_name": "eth0",
}
policy_sent = []
policy_handler.send_json = lambda status, body: policy_sent.append((status, body))
module.network_interfaces = lambda: ["eth0"]
try:
    policy_handler.handle_update_server_traffic_policy({"username": "tester"})
finally:
    module.network_interfaces = real_interfaces
assert policy_sent[-1][0] == module.HTTPStatus.OK
assert policy_sent[-1][1]["policy"]["used_bytes"] == 50 * 1024**3
assert policy_sent[-1][1]["policy"]["quota_bytes"] == 100 * 1024**3
assert policy_sent[-1][1]["policy"]["received_bytes"] == 0
assert policy_sent[-1][1]["policy"]["transmitted_bytes"] == 0
assert policy_traffic.calls == 2
PY
rm -rf "$argon2_stub"

echo "[8/13] RR Nexus per-device traffic helpers"
(
    load_modules_for_tests
    nexus_tmp=$(mktemp -d)
    NEXUS_DB_FILE="$nexus_tmp/nexus.db"
    NEXUS_CONFIG_FILE="$nexus_tmp/nexus.json"
    SINGBOX_BIN="$nexus_tmp/sing-box"
    cat > "$SINGBOX_BIN" <<'SH'
#!/bin/sh
echo 'sing-box version test with_v2ray_api'
SH
    chmod +x "$SINGBOX_BIN"
    nexus_core_supports_traffic
    python3 - "$NEXUS_DB_FILE" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.executescript("""
        CREATE TABLE devices (
          id TEXT PRIMARY KEY, credential TEXT NOT NULL, enabled INTEGER NOT NULL, expires_at TEXT,
          quota_bytes INTEGER NOT NULL, used_bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL
        );
        INSERT INTO devices VALUES ('dev_012345abcdef','01234567-89ab-4cde-8fab-0123456789ab',1,NULL,0,0,'2026-01-01');
        INSERT INTO devices VALUES ('dev_deadbeef0000','11234567-89ab-4cde-8fab-0123456789ab',0,NULL,0,0,'2026-01-02');
        INSERT INTO devices VALUES ('dev_deadbeef0001','21234567-89ab-4cde-8fab-0123456789ab',1,NULL,100,100,'2026-01-03');
    """)
PY
    [ "$(nexus_traffic_user_names)" = '["dev_012345abcdef"]' ]
    jq -n --arg database "$NEXUS_DB_FILE" --arg subscriptions "$nexus_tmp/subscriptions" \
        '{mode:"local",listen:"127.0.0.1",port:7900,domain:"",database:$database,subscription_root:$subscriptions}' \
        > "$NEXUS_CONFIG_FILE"
    for protocol in vmess vless hysteria2 tuic anytls; do
        nexus_protocol_users "$protocol" 'e219c8c7-b669-4c75-b33b-a9e5227a8a24' | \
            jq -e '.[1].name == "dev_012345abcdef"' >/dev/null
    done
    select_entry_ip() { ENTRY_IP_RAW="45.192.205.71"; return 0; }
    tcp_port_in_use() { return 1; }
    nexus_migrate_runtime_config
    [ "$(jq -r '.stats_port' "$NEXUS_CONFIG_FILE")" = "39091" ]
    [ "$(jq -r '.ssh_host' "$NEXUS_CONFIG_FILE")" = "45.192.205.71" ]
    [ "$(jq -r '.published_subscription_root' "$NEXUS_CONFIG_FILE")" = "/tmp/sub_server/nexus" ]
    rm -rf "$nexus_tmp"
)

echo "[9/13] RR Nexus personal subscription compatibility"
(
    load_modules_for_tests
    sub_tmp=$(mktemp -d)
    trap 'rm -rf "$sub_tmp"' EXIT
    NEXUS_DB_FILE="$sub_tmp/nexus.db"
    NEXUS_CONFIG_FILE="$sub_tmp/nexus.json"
    NEXUS_DATA_DIR="$sub_tmp/nexus-data"
    NEXUS_SUB_ROOT="$NEXUS_DATA_DIR/subscriptions"
    SUB_ROOT="$sub_tmp/published"
    mkdir -p "$SUB_ROOT"

    UUID="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
    device_credential="01234567-89ab-4cde-8fab-0123456789ab"
    device_id="dev_012345abcdef"
    sub_token="test_subscription_token_123456"
    PORT=20443
    VL_PORT=20444
    HY2_PORT=20445
    TU5_PORT=20446
    AN_PORT=20447
    NAIVE_PORT=20448
    VM_ENABLED=true
    VM_TLS_ENABLED=true
    VL_ENABLED=true
    HY2_ENABLED=true
    TU5_ENABLED=true
    AN_ENABLED=true
    NAIVE_ENABLED=true
    NAIVE_USER=rr-naive
    NAIVE_PASS=server-naive-password
    NAIVE_DOMAIN=naive.example.com
    PUBLIC_KEY=test-reality-public-key
    SHORT_ID=0123456789abcdef
    CERT_SHA256=$(printf 'a%.0s' {1..64})
    HY2_HOP_INTERVAL=30s
    HB_ENABLED=true
    HB_INTERVAL=30
    CLASH_ENABLED=true
    CDN_IP=www.bing.com
    ARGO_DOMAIN=argo.example.com
    ARGO_EDGE_PORT=443

    python3 - "$NEXUS_DB_FILE" "$device_id" "$device_credential" "$sub_token" <<'PY'
import sqlite3
import sys

database, device_id, credential, token = sys.argv[1:]
with sqlite3.connect(database) as connection:
    connection.executescript("""
        CREATE TABLE devices (
          id TEXT PRIMARY KEY, credential TEXT NOT NULL, name TEXT NOT NULL,
          subscription_token TEXT NOT NULL, enabled INTEGER NOT NULL,
          expires_at TEXT, quota_bytes INTEGER NOT NULL, used_bytes INTEGER NOT NULL,
          created_at TEXT NOT NULL
        );
    """)
    connection.execute(
        "INSERT INTO devices VALUES (?,?,?,?,1,NULL,0,0,'2026-01-01')",
        (device_id, credential, "NekoBox 测试", token),
    )
PY
    printf '{"mode":"public"}\n' > "$NEXUS_CONFIG_FILE"

    load_config_with_defaults() { return 0; }
    validate_subscription_crypto_material() { return 0; }
    select_entry_ip() {
        ENTRY_IP_RAW="45.192.205.71"
        ENTRY_IP_URI="45.192.205.71"
        SUB_URL_PORT=39291
        return 0
    }
    nexus_sync_subscription_endpoint() { return 0; }
    get_hop_ports() { printf '%s\n' '21000:21010'; }

    generate_nexus_device_subscriptions

    raw_file="$NEXUS_SUB_ROOT/${device_id}.txt"
    neko_file="$NEXUS_SUB_ROOT/${device_id}-nekobox.txt"
    [ -s "$raw_file" ] && [ -s "$neko_file" ]
    base64 -d "$neko_file" > "$sub_tmp/nekobox-decoded.txt"
    cmp -s "$raw_file" "$sub_tmp/nekobox-decoded.txt"
    [ "$(wc -l < "$raw_file")" -eq 6 ]
    grep -Eq '^hysteria2://.*obfs=salamander&obfs-password=e219c8c7-b669-4c75-b33b-a9e5227a8a24' "$raw_file"
    grep -Eq '^tuic://.*insecure=1&allow_insecure=1' "$raw_file"
    jq -e --arg credential "$device_credential" '.outbounds[] | select(.type == "vless") | .uuid == $credential' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    jq -e '.outbounds | map(.type) | index("vmess") != null and index("vless") != null and index("hysteria2") != null and index("tuic") != null and index("anytls") != null and index("naive") != null' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    jq -e '.outbounds[] | select(.type == "selector" and .tag == "proxy") | .outbounds | index("naive-RR-012345AB") != null' \
        "$NEXUS_SUB_ROOT/${device_id}.json" >/dev/null
    grep -Fq 'obfs: salamander' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fq 'obfs-password: "e219c8c7-b669-4c75-b33b-a9e5227a8a24"' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fxq 'keep-alive-idle: 30' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fxq 'keep-alive-interval: 30' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fq 'default-selected: "VMESS-RR-012345AB"' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    if grep -Eq '^    (keep-alive-idle|keep-alive-interval|default):' "$NEXUS_SUB_ROOT/${device_id}.yaml"; then
        echo "mihomo top-level/default fields are nested under a proxy or use the legacy invalid key." >&2
        exit 1
    fi
    for clash_suffix in -mihomo.yaml -clash-verge.yaml -flclash.yaml; do
        cmp -s "$NEXUS_SUB_ROOT/${device_id}.yaml" "$NEXUS_SUB_ROOT/${device_id}${clash_suffix}"
    done
    if command -v ruby >/dev/null 2>&1; then
        ruby -e 'require "yaml"; value=YAML.safe_load(File.read(ARGV[0]), aliases: false); abort unless value.is_a?(Hash) && value["proxies"].is_a?(Array)' \
            "$NEXUS_SUB_ROOT/${device_id}.yaml"
    fi

    python3 - "$raw_file" "$neko_file" "$device_credential" "$UUID" <<'PY'
import base64
import json
import sys
import urllib.parse

raw_path, encoded_path, credential, server_password = sys.argv[1:]
raw = open(raw_path, encoding="utf-8").read()
encoded = open(encoded_path, encoding="utf-8").read()
assert base64.b64decode(encoded).decode() == raw
assert "NekoBox 测试" not in raw
links = {line.split(":", 1)[0]: line for line in raw.splitlines()}
assert set(links) == {"vmess", "vless", "hysteria2", "tuic", "anytls", "naive+https"}

vmess = json.loads(base64.b64decode(links["vmess"].removeprefix("vmess://")))
assert vmess["id"] == credential and vmess["allowInsecure"] == "1"
assert "RR-012345AB" in vmess["ps"]

def parsed(name):
    return urllib.parse.urlsplit(links[name].replace(f"{name}://", "https://", 1))

vless = parsed("vless")
assert vless.username == credential and urllib.parse.parse_qs(vless.query)["security"] == ["reality"]
hy2 = parsed("hysteria2")
hy2_query = urllib.parse.parse_qs(hy2.query)
assert hy2.username == credential
assert hy2_query["insecure"] == ["1"]
assert hy2_query["obfs-password"] == [server_password]
tuic = parsed("tuic")
assert tuic.username == credential and tuic.password == credential
assert urllib.parse.parse_qs(tuic.query)["allow_insecure"] == ["1"]
anytls = parsed("anytls")
assert anytls.username == credential and urllib.parse.parse_qs(anytls.query)["insecure"] == ["1"]
naive = urllib.parse.urlsplit(links["naive+https"].replace("naive+https://", "https://", 1))
assert naive.username.startswith("dev_") and naive.password
for parsed_link in (vless, hy2, tuic, anytls, naive):
    assert "RR-012345AB" in urllib.parse.unquote(parsed_link.fragment)
PY

    for suffix in .txt .json .yaml -vl.json -mihomo.yaml -clash-verge.yaml -flclash.yaml -v2rayn.txt -v2rayng.txt -sr.txt -nekobox.txt; do
        cmp -s "$NEXUS_SUB_ROOT/${device_id}${suffix}" "$SUB_ROOT/nexus/${sub_token}${suffix}"
    done

    # NekoBox/Base64 订阅不能依赖 Sing-box/Clash 格式是否生成成功；失败的
    # 格式应从源目录与发布目录同步移除，不能继续暴露旧文件二维码。
    generate_client_json() { return 1; }
    generate_clash_yaml() { return 1; }
    generate_nexus_device_subscriptions
    [ -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" ]
    cmp -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" "$SUB_ROOT/nexus/${sub_token}-nekobox.txt"
    for suffix in .json .yaml -vl.json -mihomo.yaml -clash-verge.yaml -flclash.yaml; do
        [ ! -e "$NEXUS_SUB_ROOT/${device_id}${suffix}" ]
        [ ! -e "$SUB_ROOT/nexus/${sub_token}${suffix}" ]
    done
)

echo "[10/13] Release manifest coverage"
expected_paths=$(mktemp)
manifest_paths=$(mktemp)
trap 'rm -f "$expected_paths" "$manifest_paths"' EXIT
{
    echo rr
    find modules -maxdepth 1 -type f -name '*.sh' -print
    find nexus -maxdepth 2 -type f \( -name '*.py' -o -name '*.html' -o -name '*.css' -o -name '*.js' \) -print
} | LC_ALL=C sort > "$expected_paths"
awk 'NF == 2 {print $2}' manifest.sha256 | LC_ALL=C sort > "$manifest_paths"
diff -u "$expected_paths" "$manifest_paths"

echo "[11/13] Release hashes"
sha256sum -c manifest.sha256

echo "[12/13] Deterministic release bundle"
python3 scripts/rebuild-bundle.py --check
bundle_paths=$(mktemp)
expected_bundle_paths=$(mktemp)
tar -tzf rr-bundle.tar.gz | LC_ALL=C sort > "$bundle_paths"
{
    sed 's#^#rr-bundle/#' "$manifest_paths"
    echo rr-bundle/manifest.sha256
} | LC_ALL=C sort > "$expected_bundle_paths"
diff -u "$expected_bundle_paths" "$bundle_paths"
rm -f "$bundle_paths" "$expected_bundle_paths"

echo "[13/13] RR Nexus static asset and update contract"
grep -Eq 'id="login-form"' nexus/static/index.html
grep -Eq 'id="device-grid"' nexus/static/index.html
grep -Eq 'id="traffic-chart"' nexus/static/index.html
grep -Eq 'id="ssh-command"' nexus/static/index.html
grep -Fq '面板优选质量不能只看排名' nexus/static/index.html
grep -Fq '适合移动、电信、联通三网优选' nexus/static/index.html
grep -Fq '请把 TOP 20 放进真实客户端逐个测试' nexus/static/index.html
grep -Fq '/optimizer.js?v=10' nexus/static/index.html
grep -Eq '/api/devices' nexus/static/app.js
grep -Eq '/api/traffic' nexus/static/app.js
grep -Fq '/api/server/traffic-policy' nexus/static/app.js
grep -Fq 'Subscription-Userinfo' nexus/rr_nexus.py nexus/sub_server.py
grep -Fq 'QUOTA_AUTO_DELETE_SECONDS = 35 * 86400' nexus/rr_nexus.py
grep -Fq 'id="server-traffic-form"' nexus/static/index.html
grep -Fq 'id="rs-server-traffic-form"' nexus/static/index.html
grep -Fq 'id="server-plan-current"' nexus/static/index.html
grep -Fq 'id="rs-server-plan-current"' nexus/static/index.html
grep -Fq 'current_used_gb' nexus/rr_nexus.py nexus/static/app.js
grep -Fq 'enrich_subscription_content' nexus/rr_nexus.py nexus/sub_server.py
grep -Fq 'name="reset_at"' nexus/static/index.html
grep -Fq 'ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L' nexus/static/app.js
grep -Fq 'ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L' modules/85-nexus.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/40-subscription.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/85-nexus.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/90-auto-update.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/40-subscription.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/85-nexus.sh
grep -Eq 'hysteria2://.*obfs=salamander.*obfs-password=' modules/90-auto-update.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/40-subscription.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/85-nexus.sh
grep -Eq 'tuic://.*allow_insecure=1' modules/90-auto-update.sh
grep -Fq 'generate_nexus_device_subscriptions || return 1' modules/40-subscription.sh
grep -Fq '"client-nekobox.txt"' modules/90-auto-update.sh
# D4：/nexus/ 目录枚举防护——发布目录必须生成空白 index.html
grep -Fq 'nexus/index.html' modules/85-nexus.sh
# D9：面板设备订阅文案必须标注全协议（曾误写「仅 VMess」）
grep -Fq 'v2rayN（Windows）· 全协议' nexus/rr_nexus.py
grep -Fq 'v2rayNG（安卓）· 全协议' nexus/rr_nexus.py
grep -Fq 'SFA / SFI / SFM · VMess、Reality、HY2、TUIC、AnyTLS、Naive' nexus/rr_nexus.py
grep -Fq 'id="rename-dialog"' nexus/static/index.html
grep -Fq '/app.js?v=22' nexus/static/index.html
grep -Fq 'sync": "not_required"' nexus/rr_nexus.py
if grep -Eq 'read[[:space:]].*(-t|--timeout)|(^|[[:space:]])TMOUT=' rr modules/99-menus.sh; then
    echo "RR main menu contains an active input timeout and may drop an idle home page." >&2
    exit 1
fi
# D10：cron worker 必须用绝对路径调 rr，且 cron 条目必须补齐 PATH
grep -Fq '"/usr/local/bin/rr", "--sync-devices"' modules/90-auto-update.sh
grep -Fq 'PATH=/usr/local/bin:/usr/bin:/bin' modules/90-auto-update.sh
# 更新链路必须在 GitHub Raw 不可达时回退到官方 Contents API 和 CDN；
# bundle 高速更新也必须复用同一下载函数，不能另写仅支持 Raw 的 curl。
grep -Fq 'RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"' modules/00-runtime.sh install.sh
grep -Fq 'RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@${RR_BRANCH}"' modules/00-runtime.sh install.sh
grep -Fq 'Accept: application/vnd.github.raw+json' modules/60-update.sh install.sh
grep -Fq 'rr_download_file "$bundle_url" "$bundle_tmp" 10' modules/60-update.sh
grep -Fq 'UPDATE_CHECK_ERROR="远程 manifest.sha256 格式无效"' modules/60-update.sh
grep -Fq 'rr_bundle_tree_is_valid "$bundle_stage/rr-bundle"' modules/60-update.sh
grep -Fq 'RR_BUNDLE_FILE="$bundle_tmp" bash "$bootstrap_tmp" --upgrade' modules/60-update.sh
grep -Fq 'rr_bundle_tree_is_valid "$PAYLOAD_DIR"' install.sh
grep -Fxq 'rr_check_system || exit 1' install.sh
grep -Fq 'rr_backup_sqlite /var/lib/rr-nexus/nexus.db nexus.db' install.sh
grep -Fq 'rr_restore_sqlite nexus.db /var/lib/rr-nexus/nexus.db' install.sh
grep -Fq 'ROLLBACK_FAILED=true' install.sh
grep -Fq 'rr_version_ge "$release_version" "$installed_version"' install.sh
grep -Fq 'command -v timeout >/dev/null 2>&1' modules/60-update.sh
grep -Fq 'declare -F sync_nexus_devices >/dev/null 2>&1' modules/60-update.sh
grep -Fq 'nexus_download_traffic_core "$rr_core_dir"' modules/30-singbox.sh
grep -Fq 'archive_name="rr-sing-box-${version}-linux-${SYS_ARCH}.tar.gz"' modules/85-nexus.sh
grep -Fq '/usr/local/bin/rr --update-now' nexus/rr_nexus.py
grep -Fq 'MAX_JSON_BODY_BYTES = 1024 * 1024' nexus/rr_nexus.py
if grep -Eq 'fuser[[:space:]]+-k|gh release delete[[:space:]]+rr-nexus-core|#skip[[:space:]]*\|\|' \
    modules/85-nexus.sh .github/workflows/build-nexus-core.yml install.sh; then
    echo "A destructive port/release action or skipped installer gate remains." >&2
    exit 1
fi
if grep -Fq 'post_update_migrate >/dev/null 2>&1 || true' modules/60-update.sh; then
    echo "Update migration failure is still being ignored." >&2
    exit 1
fi
# 新安装必须按 manifest 复制全部 Nexus 静态资源，不能只固定复制 app 三件套。
grep -Fq 'nexus/static/*.html|nexus/static/*.css|nexus/static/*.js)' install.sh
grep -Fq '"$NEW_RUNTIME/$relative_path" || return 1' install.sh
# D10：孤儿清理必须覆盖按客户端拆分的订阅文件（-vl/-v2rayn/-v2rayng/-sr/-nekobox）
grep -Fq -- '${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-v2rayng.txt"' modules/85-nexus.sh
grep -Fq -- '${pub_token}-v2rayn.txt" "${SUB_ROOT}/nexus/${pub_token}-v2rayng.txt"' modules/85-nexus.sh
if grep -Eq 'hysteria2://.*insecure=0' modules/40-subscription.sh modules/85-nexus.sh modules/90-auto-update.sh; then
    echo "Hysteria2 self-signed URI still disables insecure mode." >&2
    exit 1
fi

echo "RR-vps validation passed."
