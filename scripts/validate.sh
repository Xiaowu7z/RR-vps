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
    test_uuid="e219c8c7-b669-4c75-b33b-a9e5227a8a24"
    url=$(build_subscription_url "45.192.205.71" 39291 "$test_uuid" jhsub_encoded.txt)
    [ "$url" = "http://45.192.205.71:39291/${test_uuid}/jhsub_encoded.txt" ]
    encoded_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" encoded)
    raw_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" raw)
    client_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" client)
    clash_short_url=$(build_short_subscription_url "45.192.205.71" 39291 "$test_uuid" clash)
    [[ "$encoded_short_url" =~ ^http://45\.192\.205\.71:39291/s/[A-Za-z0-9_-]{12}$ ]]
    [[ "$raw_short_url" =~ ^http://45\.192\.205\.71:39291/r/[A-Za-z0-9_-]{12}$ ]]
    [[ "$client_short_url" =~ ^http://45\.192\.205\.71:39291/c/[A-Za-z0-9_-]{12}$ ]]
    [[ "$clash_short_url" =~ ^http://45\.192\.205\.71:39291/m/[A-Za-z0-9_-]{12}$ ]]
    [ "${#encoded_short_url}" -lt "${#url}" ]
    SUB_ROOT=$(mktemp -d)
    UUID="$test_uuid"
    mkdir -p "$SUB_ROOT/$UUID"
    printf '%s' 'dGVzdA==' > "$SUB_ROOT/$UUID/jhsub_encoded.txt"
    printf '%s\n' 'vless://test' > "$SUB_ROOT/$UUID/jhsub.txt"
    printf '%s\n' '{}' > "$SUB_ROOT/$UUID/client.json"
    printf '%s\n' 'proxies: []' > "$SUB_ROOT/$UUID/clash_meta.yaml"
    create_short_subscription_alias
    short_token=$(subscription_short_token "$UUID")
    [ "$(readlink "$SUB_ROOT/s/$short_token")" = "../${UUID}/jhsub_encoded.txt" ]
    [ "$(readlink "$SUB_ROOT/r/$short_token")" = "../${UUID}/jhsub.txt" ]
    [ "$(readlink "$SUB_ROOT/c/$short_token")" = "../${UUID}/client.json" ]
    [ "$(readlink "$SUB_ROOT/m/$short_token")" = "../${UUID}/clash_meta.yaml" ]
    [ -f "$SUB_ROOT/index.html" ]
    for route in s r c m; do
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
import importlib.util
import json
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    assert connection.execute("SELECT COUNT(*) FROM admins").fetchone()[0] == 1
    columns = {row[1] for row in connection.execute("PRAGMA table_info(devices)")}
    assert {"uploaded_bytes", "downloaded_bytes", "traffic_updated_at"} <= columns

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
}
handler = object.__new__(module.Handler)
artifact_root = config_path.parent / "subscriptions"
artifact_root.mkdir(parents=True, exist_ok=True)
published_root = config_path.parent / "published" / "nexus"
published_root.mkdir(parents=True, exist_ok=True)
artifact_suffixes = ["-vl.json", ".yaml", "-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt", ".txt", ".json"]
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
assert len(local_urls) == 8
assert all(item["url"].startswith("http://[2001:db8::99]:39291/nexus/") for item in local_urls)
# 不存在的格式不能继续显示一个注定 404 的二维码。
(published_root / f"{device['subscription_token']}-vl.json").unlink()
assert all(item["format"] != "Sing-box 官方" for item in handler._device_subscription_urls(device)[1])
(published_root / f"{device['subscription_token']}-vl.json").write_text("test", encoding="utf-8")

write_config(mode="public", domain="45.192.205.71", ssh_host="45.192.205.71")
ip_primary, ip_urls = handler._device_subscription_urls(device)
assert ip_primary == "http://45.192.205.71:39291/nexus/test_subscription_token_123456.txt"
assert all(":9443/sub/" not in item["url"] for item in ip_urls)

# 公网 IP/本地模式的地址必须能被真实的静态订阅服务逐一下载，且内容
# 与刚发布的文件完全一致（覆盖 NekoBox 的 Base64 地址）。
import functools
import http.server
import threading
import urllib.request

quiet_handler = type(
    "QuietSubscriptionHandler",
    (http.server.SimpleHTTPRequestHandler,),
    {"log_message": lambda self, *args: None},
)
static_handler = functools.partial(quiet_handler, directory=str(published_root.parent))
static_server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), static_handler)
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
finally:
    static_server.shutdown()
    static_server.server_close()
    static_thread.join(timeout=2)

write_config(mode="public", domain="panel.example.com", ssh_host="45.192.205.71", public_port=443)
domain_primary, domain_urls = handler._device_subscription_urls(device)
assert domain_primary == "https://panel.example.com/sub/dev_012345abcdef/test_subscription_token_123456/txt"
assert len(domain_urls) == 8

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
    "v2rayn": "-v2rayn.txt",
    "v2rayng": "-v2rayng.txt",
    "sr": "-sr.txt",
    "nekobox": "-nekobox.txt",
}
sent = []
handler.send_bytes = lambda status, body, content_type: sent.append((status, body, content_type))
handler.send_json = lambda status, body: sent.append((status, body, "json"))
for route, suffix in route_suffixes.items():
    expected = ("payload:" + route).encode()
    artifact = artifact_root / f"{device['id']}{suffix}"
    artifact.write_bytes(expected)
    sent.clear()
    handler.handle_public_subscription(device["id"], device["subscription_token"], route)
    assert sent == [(module.HTTPStatus.OK, expected, "text/plain; charset=utf-8")]

missing = artifact_root / f"{device['id']}-v2rayng.txt"
missing.unlink()
sent.clear()
handler.handle_public_subscription(device["id"], device["subscription_token"], "v2rayng")
assert sent and sent[0][0] == module.HTTPStatus.NOT_FOUND
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
    HB_ENABLED=false
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
        "$NEXUS_SUB_ROOT/${device_id}-vl.json" >/dev/null
    grep -Fq 'obfs: salamander' "$NEXUS_SUB_ROOT/${device_id}.yaml"
    grep -Fq 'obfs-password: "e219c8c7-b669-4c75-b33b-a9e5227a8a24"' "$NEXUS_SUB_ROOT/${device_id}.yaml"

    python3 - "$raw_file" "$neko_file" "$device_credential" "$UUID" <<'PY'
import base64
import json
import sys
import urllib.parse

raw_path, encoded_path, credential, server_password = sys.argv[1:]
raw = open(raw_path, encoding="utf-8").read()
encoded = open(encoded_path, encoding="utf-8").read()
assert base64.b64decode(encoded).decode() == raw
links = {line.split(":", 1)[0]: line for line in raw.splitlines()}
assert set(links) == {"vmess", "vless", "hysteria2", "tuic", "anytls", "naive+https"}

vmess = json.loads(base64.b64decode(links["vmess"].removeprefix("vmess://")))
assert vmess["id"] == credential and vmess["allowInsecure"] == "1"

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
PY

    for suffix in .txt .json .yaml -vl.json -v2rayn.txt -v2rayng.txt -sr.txt -nekobox.txt; do
        cmp -s "$NEXUS_SUB_ROOT/${device_id}${suffix}" "$SUB_ROOT/nexus/${sub_token}${suffix}"
    done

    # NekoBox/Base64 订阅不能依赖 Sing-box/Clash 格式是否生成成功；失败的
    # 格式应从源目录与发布目录同步移除，不能继续暴露旧文件二维码。
    generate_client_json() { return 1; }
    generate_clash_yaml() { return 1; }
    generate_nexus_device_subscriptions
    [ -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" ]
    cmp -s "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" "$SUB_ROOT/nexus/${sub_token}-nekobox.txt"
    for suffix in .json .yaml -vl.json; do
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
grep -Fq 'UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -N -L' nexus/static/app.js
grep -Fq 'UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -N -L' modules/85-nexus.sh
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
