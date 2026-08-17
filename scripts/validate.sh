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

echo "[1/11] Bash and Python syntax"
bash -n install.sh rr modules/*.sh
python3 -c 'compile(open("nexus/rr_nexus.py", encoding="utf-8").read(), "nexus/rr_nexus.py", "exec")'
if command -v node >/dev/null 2>&1; then node --check nexus/static/app.js; fi

echo "[2/11] Combined module loading"
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

echo "[3/11] Fresh-install port selection regression"
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

echo "[4/11] Fresh-install snapshot regression"
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
    systemctl() { return 1; }

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
    systemctl() { return 0; }

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
    systemctl() { return 1; }

    if rr_snapshot_runtime; then
        echo "Snapshot unexpectedly ignored a real backup failure." >&2
        exit 1
    fi
    rm -rf "$BACKUP_DIR"
)

echo "[5/11] Fresh-install crypto material regression"
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
    check_supported_os() { return 0; }
    migrate_config_schema() { return 0; }
    load_config_with_defaults() { INSTALL_COMPLETE=false; return 0; }
    any_node_protocol_enabled() {
        echo "Incomplete install reached runtime migration." >&2
        return 0
    }
    post_update_migrate
)

echo "[6/11] Subscription URL control-character regression"
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
)

echo "[7/11] Ubuntu 22.04 Python and Argon2 compatibility"
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
PY
rm -rf "$argon2_stub"

echo "[8/11] RR Nexus per-device traffic helpers"
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
    rm -rf "$nexus_tmp"
)

echo "[9/11] Release manifest coverage"
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

echo "[10/11] Release hashes"
sha256sum -c manifest.sha256

echo "[11/11] RR Nexus static asset contract"
grep -Eq 'id="login-form"' nexus/static/index.html
grep -Eq 'id="device-grid"' nexus/static/index.html
grep -Eq 'id="traffic-chart"' nexus/static/index.html
grep -Eq 'id="ssh-command"' nexus/static/index.html
grep -Eq '/api/devices' nexus/static/app.js
grep -Eq '/api/traffic' nexus/static/app.js
grep -Fq 'UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -N -L' nexus/static/app.js
grep -Fq 'UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -N -L' modules/85-nexus.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/40-subscription.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/85-nexus.sh
grep -Eq 'hysteria2://.*insecure=1.*pinSHA256=' modules/90-auto-update.sh
# D4：/nexus/ 目录枚举防护——发布目录必须生成空白 index.html
grep -Fq 'nexus/index.html' modules/85-nexus.sh
# D9：面板设备订阅文案必须标注全协议（曾误写「仅 VMess」）
grep -Fq 'v2rayN（Windows）· 全协议' nexus/rr_nexus.py
grep -Fq 'v2rayNG（安卓）· 全协议' nexus/rr_nexus.py
# D10：cron worker 必须用绝对路径调 rr，且 cron 条目必须补齐 PATH
grep -Fq '"/usr/local/bin/rr", "--sync-devices"' modules/90-auto-update.sh
grep -Fq 'PATH=/usr/local/bin:/usr/bin:/bin' modules/90-auto-update.sh
# D10：孤儿清理必须覆盖按客户端拆分的订阅文件（-vl/-v2rayn/-v2rayng/-sr/-nekobox）
grep -Fq -- '${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-v2rayng.txt"' modules/85-nexus.sh
grep -Fq -- '${pub_token}-v2rayn.txt" "${SUB_ROOT}/nexus/${pub_token}-v2rayng.txt"' modules/85-nexus.sh
if grep -Eq 'hysteria2://.*insecure=0' modules/40-subscription.sh modules/85-nexus.sh modules/90-auto-update.sh; then
    echo "Hysteria2 self-signed URI still disables insecure mode." >&2
    exit 1
fi

echo "RR-vps validation passed."
