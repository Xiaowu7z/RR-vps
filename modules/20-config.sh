# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# IPv4 / IPv6 模式与兼容性辅助函数
# ==========================================
read_config_whitelist() {
    [ -r "$CONFIG_FILE" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 1

    local parsed_file=""
    local config_key=""
    local config_value=""
    parsed_file=$(mktemp /tmp/rr-config-read.XXXXXX) || return 1
    if ! python3 - "$CONFIG_FILE" > "$parsed_file" <<'PY'; then
import re
import shlex
import sys

allowed_keys = {
    "PORT", "ARGO_EDGE_PORT", "SUB_PORT", "UUID", "CDN_IP", "ARGO_DOMAIN", "TUNNEL_MODE",
    "ENTRY_IP_MODE", "OUTBOUND_IP_MODE", "SUB_PUBLIC_PORT", "SUB_PUBLIC_PORT_IPV4",
    "SUB_PUBLIC_PORT_IPV6", "ENTRY_IPV4_ADDRESS", "ENTRY_IPV6_ADDRESS", "VM_TLS_ENABLED",
    "SUB_ACCESS_MODE", "SUB_DOMAIN", "SUB_TOKEN",
    "VM_PREVIOUS_PORT", "VM_ENABLED", "VL_ENABLED", "VL_PORT", "HY2_ENABLED", "HY2_PORT",
    "HY2_HOP_PORTS", "HY2_HOP_INTERVAL", "TU5_ENABLED", "TU5_PORT", "TU5_HOP_PORTS",
    "AN_ENABLED", "AN_PORT", "NAIVE_ENABLED", "NAIVE_PORT", "NAIVE_USER", "NAIVE_PASS", "NAIVE_DOMAIN", "NAIVE_MODE", "NAIVE_QUIC_CC", "CLASH_ENABLED", "SINGBOX_AUTO_RESTART", "CONFIG_VERSION",
    "PRIVATE_KEY", "PUBLIC_KEY", "SHORT_ID", "CERT_SHA256", "INSTALL_COMPLETE",
    "HB_ENABLED", "HB_INTERVAL", "LE_EMAIL",
}
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as config_file:
    for line_number, raw_line in enumerate(config_file, 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, raw_value = line.split("=", 1)
        if key not in allowed_keys:
            continue
        values = shlex.split(raw_value, posix=True)
        if len(values) > 1:
            raise ValueError(f"invalid config value on line {line_number}")
        value = values[0] if values else ""
        sys.stdout.buffer.write(key.encode("utf-8") + b"\0" + value.encode("utf-8") + b"\0")
PY
        rm -f "$parsed_file"
        return 1
    fi

    while IFS= read -r -d '' config_key && IFS= read -r -d '' config_value; do
        case "$config_key" in
            PORT|ARGO_EDGE_PORT|SUB_PORT|UUID|CDN_IP|ARGO_DOMAIN|TUNNEL_MODE|\
            ENTRY_IP_MODE|OUTBOUND_IP_MODE|SUB_PUBLIC_PORT|SUB_PUBLIC_PORT_IPV4|\
            SUB_PUBLIC_PORT_IPV6|ENTRY_IPV4_ADDRESS|ENTRY_IPV6_ADDRESS|\
            SUB_ACCESS_MODE|SUB_DOMAIN|SUB_TOKEN|\
            VM_TLS_ENABLED|VM_PREVIOUS_PORT|VM_ENABLED|VL_ENABLED|VL_PORT|\
            HY2_ENABLED|HY2_PORT|HY2_HOP_PORTS|HY2_HOP_INTERVAL|\
            TU5_ENABLED|TU5_PORT|TU5_HOP_PORTS|AN_ENABLED|AN_PORT|\
            NAIVE_ENABLED|NAIVE_PORT|NAIVE_USER|NAIVE_PASS|NAIVE_DOMAIN|NAIVE_MODE|NAIVE_QUIC_CC|\
            CLASH_ENABLED|SINGBOX_AUTO_RESTART|CONFIG_VERSION|PRIVATE_KEY|\
            PUBLIC_KEY|SHORT_ID|CERT_SHA256|INSTALL_COMPLETE|HB_ENABLED|HB_INTERVAL|LE_EMAIL)
                printf -v "$config_key" '%s' "$config_value"
                ;;
        esac
    done < "$parsed_file"
    rm -f "$parsed_file"
}

load_config_with_defaults() {
    local config_read_ok=true
    # 防止同一次 rr 会话中，上一轮选择残留在 shell 变量里影响旧配置。
    PORT=""
    ARGO_EDGE_PORT=""
    SUB_PORT=""
    UUID=""
    CDN_IP=""
    ARGO_DOMAIN=""
    TUNNEL_MODE=""
    ENTRY_IP_MODE=""
    OUTBOUND_IP_MODE=""
    SUB_PUBLIC_PORT=""
    SUB_PUBLIC_PORT_IPV4=""
    SUB_PUBLIC_PORT_IPV6=""
    SUB_ACCESS_MODE=""
    SUB_DOMAIN=""
    SUB_TOKEN=""
    ENTRY_IPV4_ADDRESS=""
    ENTRY_IPV6_ADDRESS=""
    VM_TLS_ENABLED=""
    VM_PREVIOUS_PORT=""
    VM_ENABLED=""
    VL_ENABLED=""
    VL_PORT=""
    HY2_ENABLED=""
    HY2_PORT=""
    HY2_HOP_PORTS=""
    HY2_HOP_INTERVAL=""
    TU5_ENABLED=""
    TU5_PORT=""
    TU5_HOP_PORTS=""
    AN_ENABLED=""
    AN_PORT=""
    # NAIVE-SUPPORT
    NAIVE_ENABLED=""
    NAIVE_PORT=""
    NAIVE_USER=""
    NAIVE_PASS=""
    NAIVE_DOMAIN=""
    NAIVE_MODE=""
    NAIVE_QUIC_CC=""
    CLASH_ENABLED=""
    SINGBOX_AUTO_RESTART=""
    CONFIG_VERSION=""
    INSTALL_COMPLETE=""
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    SHORT_ID=""
    CERT_SHA256=""
    HB_ENABLED=""
    HB_INTERVAL=""
    LE_EMAIL=""
    if [ -f "$CONFIG_FILE" ]; then
        if ! read_config_whitelist; then
            echo -e "${RED}[错误] 配置文件包含无法安全解析的内容：${CONFIG_FILE}${RESET}" >&2
            config_read_ok=false
        fi
    fi

    # 老版本配置没有以下两项时，保持原脚本行为：入口自动、出口自动。
    PORT="${PORT:-443}"
    ARGO_EDGE_PORT="${ARGO_EDGE_PORT:-443}"
    SUB_PORT="${SUB_PORT:-18080}"
    CDN_IP="${CDN_IP:-cloudflare-ech.com}"
    ARGO_DOMAIN="${ARGO_DOMAIN:-}"
    TUNNEL_MODE="${TUNNEL_MODE:-1}"
    ENTRY_IP_MODE="${ENTRY_IP_MODE:-auto}"
    OUTBOUND_IP_MODE="${OUTBOUND_IP_MODE:-auto}"
    ENTRY_IPV4_ADDRESS="${ENTRY_IPV4_ADDRESS:-}"
    ENTRY_IPV6_ADDRESS="${ENTRY_IPV6_ADDRESS:-}"
    # 兼容旧配置：IPv4/IPv6 公网订阅端口缺失时，与本地 HTTP 监听端口保持一致。
    # SUB_PUBLIC_PORT 是早期测试版字段，仅作为 IPv4 NAT 端口的兼容回退读取。
    SUB_PUBLIC_PORT_IPV4="${SUB_PUBLIC_PORT_IPV4:-${SUB_PUBLIC_PORT:-${SUB_PORT:-}}}"
    SUB_PUBLIC_PORT_IPV6="${SUB_PUBLIC_PORT_IPV6:-${SUB_PORT:-}}"
    SUB_ACCESS_MODE="${SUB_ACCESS_MODE:-local}"
    SUB_DOMAIN="${SUB_DOMAIN:-}"
    SUB_TOKEN="${SUB_TOKEN:-}"
    VM_TLS_ENABLED="${VM_TLS_ENABLED:-false}"
    VM_PREVIOUS_PORT="${VM_PREVIOUS_PORT:-}"
    VM_ENABLED="${VM_ENABLED:-true}"
    VL_ENABLED="${VL_ENABLED:-false}"
    VL_PORT="${VL_PORT:-0}"
    HY2_ENABLED="${HY2_ENABLED:-false}"
    HY2_PORT="${HY2_PORT:-0}"
    HY2_HOP_PORTS="${HY2_HOP_PORTS:-}"
    HY2_HOP_INTERVAL="${HY2_HOP_INTERVAL:-30s}"
    TU5_ENABLED="${TU5_ENABLED:-false}"
    TU5_PORT="${TU5_PORT:-0}"
    TU5_HOP_PORTS="${TU5_HOP_PORTS:-}"
    AN_ENABLED="${AN_ENABLED:-false}"
    AN_PORT="${AN_PORT:-0}"
    # NAIVE-SUPPORT：HTTP/2(TCP) + HTTP/3(QUIC) 双栈，需真证书。
    NAIVE_ENABLED="${NAIVE_ENABLED:-false}"
    NAIVE_PORT="${NAIVE_PORT:-443}"
    NAIVE_USER="${NAIVE_USER:-}"
    NAIVE_PASS="${NAIVE_PASS:-}"
    NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
    # 旧用户缺少此字段时保持 7.0 的 H2/TCP 行为；新开启向导默认双栈。
    NAIVE_MODE="${NAIVE_MODE:-h2}"
    NAIVE_QUIC_CC="${NAIVE_QUIC_CC:-bbr}"
    CLASH_ENABLED="${CLASH_ENABLED:-true}"
    SINGBOX_AUTO_RESTART="${SINGBOX_AUTO_RESTART:-true}"
    CONFIG_VERSION="${CONFIG_VERSION:-1}"
    # 主动心跳：默认关闭；间隔默认 30 秒，非法值回退 30，范围钳制 1-3600。
    HB_ENABLED="${HB_ENABLED:-false}"
    HB_INTERVAL="${HB_INTERVAL:-30}"
    case "$HB_INTERVAL" in
        *[!0-9]*) HB_INTERVAL=30 ;;
    esac
    [ -n "$HB_INTERVAL" ] && [ "$HB_INTERVAL" -ge 1 ] 2>/dev/null || HB_INTERVAL=30
    [ "$HB_INTERVAL" -le 3600 ] 2>/dev/null || HB_INTERVAL=3600
    # 区分“有旧版 schema 的真实旧配置”与“完全没有 schema 的旧/陌生配置”：
    # 只有能被解析出 CONFIG_VERSION 的配置才按旧版正式安装对待（视为已完成），
    # 迁移路径才会接管并可能重启服务。无 schema 的配置（单文件 rr 时代产物或
    # 来源不明的文件）无法确认其安装状态，保守视为未完成安装，走全新安装路径
    # （生成新配置前由 install_main 备份旧文件），绝不当作活节点迁移，
    # 绝不触碰用户手动运行的 sing-box 进程。
    local config_has_schema=false
    if [ -f "$CONFIG_FILE" ] && grep -q '^CONFIG_VERSION=' "$CONFIG_FILE" 2>/dev/null; then
        config_has_schema=true
    fi
    if [ "$config_has_schema" = true ]; then
        # 所有带 schema 的旧版正式安装均视为已完成；仅新版首次安装会显式写入 false。
        INSTALL_COMPLETE="${INSTALL_COMPLETE:-true}"
    else
        INSTALL_COMPLETE="${INSTALL_COMPLETE:-false}"
    fi

    case "$ENTRY_IP_MODE" in
        auto|ipv4|ipv6) ;;
        *) ENTRY_IP_MODE="auto" ;;
    esac
    case "$OUTBOUND_IP_MODE" in
        auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;;
        *) OUTBOUND_IP_MODE="auto" ;;
    esac
    if ! is_valid_port "$SUB_PUBLIC_PORT_IPV4"; then
        SUB_PUBLIC_PORT_IPV4="$SUB_PORT"
    fi
    if ! is_valid_port "$SUB_PUBLIC_PORT_IPV6"; then
        SUB_PUBLIC_PORT_IPV6="$SUB_PORT"
    fi
    case "$SUB_ACCESS_MODE" in
        local) SUB_DOMAIN="" ;;
        https)
            is_valid_domain "$SUB_DOMAIN" || {
                SUB_ACCESS_MODE=local
                SUB_DOMAIN=""
            }
            ;;
        *) SUB_ACCESS_MODE=local; SUB_DOMAIN="" ;;
    esac
    if [ "$VM_ENABLED" = "false" ] && [ "$PORT" = "0" ]; then
        : # 新安装可不启用 VMess；0 仅表示未分配端口，不会创建监听。
    else
        is_valid_port "$PORT" || PORT=443
    fi
    if ! is_valid_port "$VM_PREVIOUS_PORT" || [ "$VM_PREVIOUS_PORT" = "$PORT" ]; then
        VM_PREVIOUS_PORT=""
    fi
    is_cloudflare_tls_port "$ARGO_EDGE_PORT" || ARGO_EDGE_PORT=443
    is_valid_hop_spec "$HY2_HOP_PORTS" || HY2_HOP_PORTS=""
    is_valid_hop_spec "$TU5_HOP_PORTS" || TU5_HOP_PORTS=""
    is_valid_hop_interval "$HY2_HOP_INTERVAL" || HY2_HOP_INTERVAL="30s"
    case "$SINGBOX_AUTO_RESTART" in true|false) ;; *) SINGBOX_AUTO_RESTART=true ;; esac
    case "$NAIVE_MODE" in h2|h3|both) ;; *) NAIVE_MODE=both ;; esac
    case "$NAIVE_QUIC_CC" in
        new_reno) NAIVE_QUIC_CC=reno ;; # 7.1 RC 兼容：sing-box 官方字段名是 reno
        cubic|reno|bbr) ;;
        *) NAIVE_QUIC_CC=bbr ;;
    esac
    case "$HB_ENABLED" in true|false) ;; *) HB_ENABLED=false ;; esac
    case "$INSTALL_COMPLETE" in true|false) ;; *) INSTALL_COMPLETE=false ;; esac
    [ "$config_read_ok" = true ]
}

any_node_protocol_enabled() {
    [ "${VM_ENABLED:-false}" != "false" ] || \
    [ "${VL_ENABLED:-false}" = "true" ] || \
    [ "${HY2_ENABLED:-false}" = "true" ] || \
    [ "${TU5_ENABLED:-false}" = "true" ] || \
    [ "${AN_ENABLED:-false}" = "true" ] || \
    [ "${NAIVE_ENABLED:-false}" = "true" ]
}

migrate_config_schema() {
    [ -f "$CONFIG_FILE" ] || return 0
    load_config_with_defaults || return 1

    # 首次升级时接管旧版仅保存在 iptables 中的跳跃规则，避免更新后订阅丢失。
    if ! grep -q '^HY2_HOP_PORTS=' "$CONFIG_FILE" 2>/dev/null && [ "$HY2_PORT" != "0" ]; then
        HY2_HOP_PORTS=$(get_hop_ports_from_firewall "$HY2_PORT")
    fi
    if ! grep -q '^TU5_HOP_PORTS=' "$CONFIG_FILE" 2>/dev/null && [ "$TU5_PORT" != "0" ]; then
        TU5_HOP_PORTS=$(get_hop_ports_from_firewall "$TU5_PORT")
    fi

    local key=""
    local value=""
    while IFS='|' read -r key value; do
        if ! grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
            safe_sed "$key" "$value" || return 1
        fi
    done <<EOF
ARGO_EDGE_PORT|$ARGO_EDGE_PORT
SUB_PUBLIC_PORT_IPV4|$SUB_PUBLIC_PORT_IPV4
SUB_PUBLIC_PORT_IPV6|$SUB_PUBLIC_PORT_IPV6
SUB_ACCESS_MODE|$SUB_ACCESS_MODE
SUB_DOMAIN|$SUB_DOMAIN
SUB_TOKEN|$SUB_TOKEN
ENTRY_IP_MODE|$ENTRY_IP_MODE
OUTBOUND_IP_MODE|$OUTBOUND_IP_MODE
ENTRY_IPV4_ADDRESS|$ENTRY_IPV4_ADDRESS
ENTRY_IPV6_ADDRESS|$ENTRY_IPV6_ADDRESS
VM_TLS_ENABLED|$VM_TLS_ENABLED
VM_PREVIOUS_PORT|$VM_PREVIOUS_PORT
VM_ENABLED|$VM_ENABLED
VL_ENABLED|$VL_ENABLED
VL_PORT|$VL_PORT
HY2_ENABLED|$HY2_ENABLED
HY2_PORT|$HY2_PORT
HY2_HOP_PORTS|$HY2_HOP_PORTS
HY2_HOP_INTERVAL|$HY2_HOP_INTERVAL
TU5_ENABLED|$TU5_ENABLED
TU5_PORT|$TU5_PORT
TU5_HOP_PORTS|$TU5_HOP_PORTS
AN_ENABLED|$AN_ENABLED
AN_PORT|$AN_PORT
NAIVE_ENABLED|$NAIVE_ENABLED
NAIVE_PORT|$NAIVE_PORT
NAIVE_USER|$NAIVE_USER
NAIVE_PASS|$NAIVE_PASS
NAIVE_DOMAIN|$NAIVE_DOMAIN
NAIVE_MODE|$NAIVE_MODE
NAIVE_QUIC_CC|$NAIVE_QUIC_CC
CLASH_ENABLED|$CLASH_ENABLED
SINGBOX_AUTO_RESTART|$SINGBOX_AUTO_RESTART
INSTALL_COMPLETE|$INSTALL_COMPLETE
HB_ENABLED|$HB_ENABLED
HB_INTERVAL|$HB_INTERVAL
EOF
    safe_sed "CONFIG_VERSION" "$CONFIG_SCHEMA_VERSION" || return 1
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
    load_config_with_defaults || return 1
    # B1 P0：迁移旧配置时掩码凭据（如 UUID=3b6007...2114）必须立即重生成真值，
    # 防止掩码进入后续任何 sing-box 配置 / 订阅生成流程。
    ensure_credential_integrity || return 1
}

get_singbox_version() {
    local binary="${1:-$SINGBOX_BIN}"
    [ -n "$binary" ] && [ -x "$binary" ] || return 1
    "$binary" version 2>/dev/null | awk '
        NR == 1 {
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$/) {
                    sub(/^v/, "", $i)
                    print $i
                    exit
                }
            }
        }'
}

is_managed_singbox_pid() {
    local pid="${1:-}"
    local cmdline=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    [ -r "/proc/${pid}/cmdline" ] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
    [[ "$cmdline" == *"sing-box run"* && "$cmdline" == *"/etc/sing-box/config.json"* ]]
}

managed_singbox_pids() {
    local pid=""
    while IFS= read -r pid; do
        is_managed_singbox_pid "$pid" && printf '%s\n' "$pid"
    done < <(pgrep -x sing-box 2>/dev/null || true)
}

managed_singbox_running() {
    managed_singbox_pids | grep -q .
}

singbox_orphan_pids() {
    # H6：受管 sing-box 进程中不在 systemd unit cgroup 内的 PID。
    # 仅当 sing-box.service 存在且 active 时才有"脱离"语义；单元未运行时
    # 全部进程都视为独立运行（旧版 nohup 模式），不输出。
    local pid=""
    if [ ! -f /etc/systemd/system/sing-box.service ] || ! systemctl is-active --quiet sing-box; then
        return 0
    fi
    while IFS= read -r pid; do
        if ! grep -q 'sing-box\.service' "/proc/${pid}/cgroup" 2>/dev/null; then
            printf '%s\n' "$pid"
        fi
    done < <(managed_singbox_pids)
}

version_ge() {
    local current="$1"
    local required="$2"
    [ -n "$current" ] && [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1)" = "$required" ]
}

is_ip_version() {
    local address="$1"
    local expected_version="$2"
    python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).version == int(sys.argv[2]) else 1)' \
        "$address" "$expected_version" >/dev/null 2>&1
}

is_global_ip_version() {
    local address="$1"
    local expected_version="$2"
    python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == int(sys.argv[2]) and ip.is_global else 1)' \
        "$address" "$expected_version" >/dev/null 2>&1
}

is_ula_ipv6() {
    local address="$1"
    python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); sys.exit(0 if ip.version == 6 and ip in ipaddress.ip_network("fc00::/7") else 1)' \
        "$address" >/dev/null 2>&1
}

is_valid_host_or_ip() {
    local value="${1:-}"
    [ -n "$value" ] || return 1
    python3 - "$value" <<'PY' >/dev/null 2>&1
import ipaddress
import re
import sys

value = sys.argv[1].strip().rstrip(".")
try:
    ipaddress.ip_address(value.strip("[]"))
    raise SystemExit(0)
except ValueError:
    pass
if len(value) > 253 or not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", value):
    raise SystemExit(1)
raise SystemExit(0)
PY
}

is_valid_domain() {
    local value="${1:-}"
    local label=""
    local -a labels=()
    [ -n "$value" ] && [ "${#value}" -le 253 ] || return 1
    [[ "$value" != .* && "$value" != *. && "$value" == *.* ]] || return 1
    IFS=. read -r -a labels <<< "$value"
    [ "${#labels[@]}" -ge 2 ] || return 1
    for label in "${labels[@]}"; do
        [ -n "$label" ] && [ "${#label}" -le 63 ] || return 1
        [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
    label="${labels[${#labels[@]}-1]}"
    [[ "$label" =~ ^[A-Za-z]{2,63}$ || "$label" =~ ^xn--[A-Za-z0-9-]{2,59}$ ]]
}

is_valid_uuid() {
    python3 -c 'import sys,uuid; uuid.UUID(sys.argv[1]); sys.exit(0)' "${1:-}" >/dev/null 2>&1
}

# ==========================================
# 掩码凭据检测与真值回写（B1 P0 修复）
# 旧版单文件 rr 会把真实凭据以掩码形式（首6+...+尾4，如 3b6007...2114）
# 写入 /etc/argo_vmess.conf；迁移后若原样使用，掩码值会进入 sing-box
# 配置/订阅，导致节点凭据全部失效（且曾引发 JSON 结构异常）。
# 约定：任何含 "..." 或匹配掩码正则的值一律视为掩码，不得进入配置。
# ==========================================
is_masked_credential() {
    local value="${1:-}"
    [ -n "$value" ] || return 1
    [[ "$value" == *"..."* ]] || [[ "$value" =~ ^[0-9a-fA-F]{6}\.{3}[0-9a-fA-F]{4}$ ]]
}

rr_credential_config_values_match() (
    local config="$1" key="" expected="" count=""
    local CONFIG_FILE="$config"
    shift
    [ $(( $# % 2 )) -eq 0 ] || return 1
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
    local -a pairs=("$@")
    local index=0
    while [ "$index" -lt "${#pairs[@]}" ]; do
        key="${pairs[$index]}"
        case "$key" in
            UUID|SUB_TOKEN|NAIVE_USER|NAIVE_PASS|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|CERT_SHA256) ;;
            *) return 1 ;;
        esac
        unset "$key"
        index=$((index + 2))
    done
    read_config_whitelist || return 1
    index=0
    while [ "$index" -lt "${#pairs[@]}" ]; do
        key="${pairs[$index]}"
        expected="${pairs[$((index + 1))]}"
        declare -p "$key" >/dev/null 2>&1 || return 1
        [ "${!key}" = "$expected" ] || return 1
        count=$(grep -c "^${key}=" "$CONFIG_FILE" 2>/dev/null || true)
        [ "$count" -eq 1 ] || return 1
        index=$((index + 2))
    done
)

rr_credential_globals_match() {
    local key="" expected=""
    [ $(( $# % 2 )) -eq 0 ] || return 1
    while [ "$#" -gt 0 ]; do
        key="$1"
        expected="$2"
        shift 2
        declare -p "$key" >/dev/null 2>&1 || return 1
        [ "${!key}" = "$expected" ] || return 1
    done
}

# Publish all repaired credential fields as one generation.  `safe_sed` is
# deliberately confined to a same-directory working copy: a failed writer can
# never leave the live configuration with only a prefix of the new values.
RR_CREDENTIAL_CONFIG_COMMITTED=0
rr_publish_credential_config_updates() {
    local target="${CONFIG_FILE:-}" directory="" base="" temporary=""
    local original_metadata="" temporary_metadata="" key="" value=""
    RR_CREDENTIAL_CONFIG_COMMITTED=0
    [ -n "$target" ] && [ $(( $# % 2 )) -eq 0 ] && [ "$#" -gt 0 ] || return 1
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    original_metadata=$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null) || return 1
    [[ "$original_metadata" == *:1 ]] || return 1
    directory=$(dirname -- "$target") || return 1
    base=$(basename -- "$target") || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    temporary=$(mktemp "$directory/.${base}.credentials.XXXXXX") || return 1
    if ! cp -p -- "$target" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    local CONFIG_FILE="$temporary"
    while [ "$#" -gt 0 ]; do
        key="$1"
        value="$2"
        shift 2
        case "$key" in
            UUID|SUB_TOKEN|NAIVE_USER|NAIVE_PASS|PRIVATE_KEY|PUBLIC_KEY|SHORT_ID|CERT_SHA256) ;;
            *) rm -f -- "$temporary"; return 1 ;;
        esac
        safe_sed "$key" "$value" || { rm -f -- "$temporary"; return 1; }
    done
    temporary_metadata=$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null) || {
        rm -f -- "$temporary"
        return 1
    }
    [ "$temporary_metadata" = "$original_metadata" ] || {
        rm -f -- "$temporary"
        return 1
    }
    sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CREDENTIAL_FAIL_BEFORE_COMMIT:-0}" = 1 ]; then
        rm -f -- "$temporary"
        return 1
    fi
    mv -f -- "$temporary" "$target" || { rm -f -- "$temporary"; return 1; }
    RR_CREDENTIAL_CONFIG_COMMITTED=1
    sync -f "$directory" || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = \
        "$original_metadata" ] || return 1
}

rr_apply_credential_updates() {
    [ $(( $# % 2 )) -eq 0 ] && [ "$#" -gt 0 ] || return 1
    local -a pairs=("$@")
    local key="" value=""
    if [ -e "$CONFIG_FILE" ] || [ -L "$CONFIG_FILE" ]; then
        if ! rr_publish_credential_config_updates "${pairs[@]}"; then
            # A directory-fsync fault can be reported after rename.  Reload in
            # that case so the process never continues with the prior in-memory
            # generation while disk already contains the new one.
            if [ "${RR_CREDENTIAL_CONFIG_COMMITTED:-0}" = 1 ]; then
                load_config_with_defaults >/dev/null 2>&1 || true
            fi
            return 1
        fi
        if ! rr_credential_config_values_match "$CONFIG_FILE" "${pairs[@]}"; then
            load_config_with_defaults >/dev/null 2>&1 || true
            return 1
        fi
        load_config_with_defaults || return 1
        rr_credential_globals_match "${pairs[@]}"
        return $?
    fi
    while [ "$#" -gt 0 ]; do
        key="$1"
        value="$2"
        shift 2
        printf -v "$key" '%s' "$value"
    done
    rr_credential_globals_match "${pairs[@]}"
}

# 凭据完整性保障：检测到掩码/空值/非法格式时重新生成真实凭据并回写配置，
# 保证掩码永不进入 sing-box 配置或订阅。仅在检测到问题时写入，幂等。
# Reality 密钥的重新生成由 30-singbox.sh 的 rotate_reality_keypair 承担
# （需要 sing-box 二进制），此处按需调用。
ensure_credential_integrity() {
    local changed=false reality_rotated=false reality_cleared=false
    local desired_uuid="${UUID:-}" desired_sub_token="${SUB_TOKEN:-}"
    local desired_naive_user="${NAIVE_USER:-}" desired_naive_pass="${NAIVE_PASS:-}"
    local desired_cert_sha256="${CERT_SHA256:-}"
    local new_uuid="" new_sub_token=""
    local -a updates=()

    # UUID：主凭据（vmess/vless/hy2/tuic/anytls 共用）
    if [ -z "${UUID:-}" ] || is_masked_credential "$UUID" || ! is_valid_uuid "$UUID"; then
        new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        is_valid_uuid "$new_uuid" || return 1
        desired_uuid="$new_uuid"
        updates+=(UUID "$desired_uuid")
        changed=true
    fi
    if [[ ! "${SUB_TOKEN:-}" =~ ^[A-Za-z0-9_-]{32}$ ]]; then
        new_sub_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))' 2>/dev/null || true)
        if [[ "$new_sub_token" =~ ^[A-Za-z0-9_-]{32}$ ]]; then
            desired_sub_token="$new_sub_token"
            updates+=(SUB_TOKEN "$desired_sub_token")
            changed=true
        else
            return 1
        fi
    fi
    # NaiveProxy 凭据（用户名/密码，仅 NAIVE_ENABLED 时参与配置生成）
    if [ "${NAIVE_ENABLED:-false}" = "true" ]; then
        if [ -z "${NAIVE_USER:-}" ] || is_masked_credential "$NAIVE_USER"; then
            desired_naive_user="np_$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 8)"
            [[ "$desired_naive_user" =~ ^np_[0-9a-f]{8}$ ]] || return 1
            updates+=(NAIVE_USER "$desired_naive_user")
            changed=true
        fi
        if [ -z "${NAIVE_PASS:-}" ] || is_masked_credential "$NAIVE_PASS"; then
            desired_naive_pass="$(head -c 24 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n/+= ' | head -c 20)"
            [[ "$desired_naive_pass" =~ ^[A-Za-z0-9]{20}$ ]] || return 1
            updates+=(NAIVE_PASS "$desired_naive_pass")
            changed=true
        fi
    else
        # 未启用 NaiveProxy：清空遗留掩码凭据（不生成真值），保持配置文件终态干净
        if is_masked_credential "${NAIVE_USER:-}"; then
            desired_naive_user=""
            updates+=(NAIVE_USER "")
            changed=true
        fi
        if is_masked_credential "${NAIVE_PASS:-}"; then
            desired_naive_pass=""
            updates+=(NAIVE_PASS "")
            changed=true
        fi
    fi
    # Reality 密钥材料：掩码一律强制重生成（现有客户端不可能持有掩码密钥）
    if is_masked_credential "${PRIVATE_KEY:-}" || is_masked_credential "${PUBLIC_KEY:-}" || \
       is_masked_credential "${SHORT_ID:-}"; then
        if declare -F rotate_reality_keypair >/dev/null 2>&1; then
            if rotate_reality_keypair; then
                reality_rotated=true
                changed=true
            else
                # 降级（R1）：迁移路径不允许因密钥轮换失败（内核缺失/损坏）卡死整体更新
                # rotate 可能在目录 fsync 时失败，但原子 rename 已经发生；先
                # 重读当前代，确保后续清空写入若失败，内存仍与磁盘一致。
                if [ -f "$CONFIG_FILE" ]; then
                    load_config_with_defaults || return 1
                fi
                updates+=(PRIVATE_KEY "" PUBLIC_KEY "" SHORT_ID "")
                reality_cleared=true
                changed=true
            fi
        fi
    fi
    # 证书 pin 是派生数据（由证书重新计算），掩码时清空即可，后续流程会自动重算/降级。
    if is_masked_credential "${CERT_SHA256:-}"; then
        desired_cert_sha256=""
        updates+=(CERT_SHA256 "")
        changed=true
    fi

    if [ "${#updates[@]}" -gt 0 ]; then
        rr_apply_credential_updates "${updates[@]}" || return 1
    elif [ "$reality_rotated" = true ] && [ -f "$CONFIG_FILE" ]; then
        rr_credential_config_values_match "$CONFIG_FILE" \
            PRIVATE_KEY "$PRIVATE_KEY" PUBLIC_KEY "$PUBLIC_KEY" SHORT_ID "$SHORT_ID" || \
            return 1
    fi
    if [ "$reality_cleared" = true ]; then
        echo -e "${YELLOW}[警告] Reality 密钥轮换失败（内核不可用？），已清空密钥材料；VLESS-Reality 暂不可用，稍后可通过菜单重新生成。${RESET}" >&2
    fi

    if [ "$changed" = true ]; then
        echo -e "${YELLOW}[提示] 检测到配置中的掩码/无效凭据，已重新生成真实凭据并回写 ${CONFIG_FILE}。${RESET}" >&2
    fi
    return 0
}

detect_local_addresses() {
    LOCAL_IPV4=""
    LOCAL_IPV6_GLOBAL=""
    LOCAL_IPV6_ULA=""
    command -v ip >/dev/null 2>&1 || return 0

    local candidate=""
    while IFS= read -r candidate; do
        candidate="${candidate%%/*}"
        if is_global_ip_version "$candidate" 4; then
            LOCAL_IPV4="$candidate"
            break
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}')

    # 优先采用系统路由实际选中的原生公网 IPv6 源地址。
    candidate=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
    if is_global_ip_version "$candidate" 6; then
        LOCAL_IPV6_GLOBAL="$candidate"
    fi

    while IFS= read -r candidate; do
        candidate="${candidate%%/*}"
        if [ -z "$LOCAL_IPV6_GLOBAL" ] && is_global_ip_version "$candidate" 6; then
            LOCAL_IPV6_GLOBAL="$candidate"
        fi
        if [ -z "$LOCAL_IPV6_ULA" ] && is_ula_ipv6 "$candidate"; then
            LOCAL_IPV6_ULA="$candidate"
        fi
    done < <(ip -o -6 addr show scope global 2>/dev/null | awk '{print $4}')
}

detect_public_ips() {
    PUBLIC_IPV4=""
    PUBLIC_IPV6=""
    EGRESS_IPV4=""
    EGRESS_IPV6=""
    IPV4_ENTRY_SOURCE="未检测到"
    IPV6_ENTRY_SOURCE="未检测到"
    IPV6_NAT66_DETECTED=false

    detect_local_addresses

    local candidate=""
    candidate=$(curl -4 -fsS --connect-timeout 4 --max-time 6 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    if ! is_ip_version "$candidate" 4; then
        candidate=$(curl -4 -fsS --connect-timeout 4 --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    fi
    is_global_ip_version "$candidate" 4 && EGRESS_IPV4="$candidate"

    candidate=$(curl -6 -fsS --connect-timeout 4 --max-time 6 https://api6.ipify.org 2>/dev/null | tr -d '[:space:]')
    if ! is_ip_version "$candidate" 6; then
        candidate=$(curl -6 -fsS --connect-timeout 4 --max-time 6 https://icanhazip.com 2>/dev/null | tr -d '[:space:]')
    fi
    is_global_ip_version "$candidate" 6 && EGRESS_IPV6="$candidate"

    if [ -n "${ENTRY_IPV4_ADDRESS:-}" ]; then
        if is_global_ip_version "$ENTRY_IPV4_ADDRESS" 4; then
            PUBLIC_IPV4="$ENTRY_IPV4_ADDRESS"
            IPV4_ENTRY_SOURCE="手动指定"
        else
            IPV4_ENTRY_SOURCE="手动地址无效"
        fi
    elif [ -n "$EGRESS_IPV4" ]; then
        # IPv4 NAT 的出口公网地址通常就是服务商面板关联的公网地址。
        PUBLIC_IPV4="$EGRESS_IPV4"
        IPV4_ENTRY_SOURCE="外部检测"
    elif [ -n "$LOCAL_IPV4" ]; then
        PUBLIC_IPV4="$LOCAL_IPV4"
        IPV4_ENTRY_SOURCE="本机网卡"
    fi

    if [ -n "${ENTRY_IPV6_ADDRESS:-}" ]; then
        if is_global_ip_version "$ENTRY_IPV6_ADDRESS" 6; then
            PUBLIC_IPV6="$ENTRY_IPV6_ADDRESS"
            IPV6_ENTRY_SOURCE="手动指定（LXD/NAT66）"
        else
            IPV6_ENTRY_SOURCE="手动地址无效"
        fi
    elif [ -n "$LOCAL_IPV6_GLOBAL" ]; then
        PUBLIC_IPV6="$LOCAL_IPV6_GLOBAL"
        IPV6_ENTRY_SOURCE="本机原生公网 IPv6"
    elif [ -n "$LOCAL_IPV6_ULA" ]; then
        # LXD/NAT66：curl 看到的是宿主机出口地址，不能作为容器的入站公网地址。
        IPV6_NAT66_DETECTED=true
        IPV6_ENTRY_SOURCE="检测到 LXD/NAT66，必须手动填写"
    elif [ -n "$EGRESS_IPV6" ]; then
        # 没有发现任何本机 IPv6 时保留传统兼容路径，并明确标注来源。
        PUBLIC_IPV6="$EGRESS_IPV6"
        IPV6_ENTRY_SOURCE="外部检测（未发现本机地址）"
    fi
}

select_entry_ip() {
    load_config_with_defaults || return 1
    detect_public_ips

    case "$ENTRY_IP_MODE" in
        ipv4)
            if [ -z "$PUBLIC_IPV4" ]; then
                echo -e "${RED}[错误] 未检测到可用公网 IPv4，不能生成 IPv4 入口配置。${RESET}" >&2
                return 1
            fi
            ENTRY_IP_RAW="$PUBLIC_IPV4"
            ENTRY_LISTEN_ADDRESS="0.0.0.0"
            SUB_BIND_ADDRESS="0.0.0.0"
            ;;
        ipv6)
            if [ -z "$PUBLIC_IPV6" ]; then
                if [ "$IPV6_NAT66_DETECTED" = true ]; then
                    echo -e "${RED}[错误] 检测到 LXD/NAT66：外部检测到的 ${EGRESS_IPV6:-未知} 是出口地址，不能写入节点。${RESET}" >&2
                    echo -e "${YELLOW}请在菜单 12 → 6 手动填写服务商面板绑定的公网 IPv6。${RESET}" >&2
                else
                    echo -e "${RED}[错误] 未检测到可用公网 IPv6，不能生成 IPv6 入口配置。${RESET}" >&2
                fi
                return 1
            fi
            ENTRY_IP_RAW="$PUBLIC_IPV6"
            ENTRY_LISTEN_ADDRESS="::"
            SUB_BIND_ADDRESS="::"
            ;;
        *)
            if [ -n "$PUBLIC_IPV4" ]; then
                ENTRY_IP_RAW="$PUBLIC_IPV4"
                SUB_BIND_ADDRESS="0.0.0.0"
            elif [ -n "$PUBLIC_IPV6" ]; then
                ENTRY_IP_RAW="$PUBLIC_IPV6"
                SUB_BIND_ADDRESS="::"
            else
                echo -e "${RED}[错误] 未检测到公网 IPv4 或 IPv6。${RESET}" >&2
                return 1
            fi
            # 保留原脚本的双栈监听方式。
            ENTRY_LISTEN_ADDRESS="::"
            ;;
    esac

    if is_ip_version "$ENTRY_IP_RAW" 6; then
        ENTRY_IP_URI="[$ENTRY_IP_RAW]"
        SUB_URL_PORT="$SUB_PUBLIC_PORT_IPV6"
        ENTRY_IP_SOURCE="$IPV6_ENTRY_SOURCE"
    else
        ENTRY_IP_URI="$ENTRY_IP_RAW"
        SUB_URL_PORT="$SUB_PUBLIC_PORT_IPV4"
        ENTRY_IP_SOURCE="$IPV4_ENTRY_SOURCE"
    fi
    if [ "${SUB_ACCESS_MODE:-local}" = local ]; then
        SUB_BIND_ADDRESS="127.0.0.1"
        SUB_URL_PORT="$SUB_PORT"
    fi
}

entry_mode_label() {
    case "${1:-auto}" in
        ipv4) echo "仅 IPv4 入口" ;;
        ipv6) echo "仅 IPv6 入口" ;;
        *) echo "自动入口（优先 IPv4）" ;;
    esac
}

outbound_mode_label() {
    case "${1:-auto}" in
        prefer_ipv4) echo "IPv4 优先，失败回退 IPv6" ;;
        prefer_ipv6) echo "IPv6 优先，失败回退 IPv4" ;;
        ipv4_only) echo "仅 IPv4 出口" ;;
        ipv6_only) echo "仅 IPv6 出口" ;;
        *) echo "系统自动出口" ;;
    esac
}

certificate_identity_matches() {
    local certificate="$1" identity="$2"
    [ -s "$certificate" ] && [ -n "$identity" ] || return 1
    python3 - "$certificate" "$identity" >/dev/null 2>&1 <<'PY'
import ssl
import sys
import ipaddress

decoded = ssl._ssl._test_decode_cert(sys.argv[1])
identity = sys.argv[2].strip()
try:
    expected_ip = ipaddress.ip_address(identity.strip("[]"))
except ValueError:
    expected_ip = None
matched = False
for kind, value in decoded.get("subjectAltName", ()):
    if expected_ip is None and kind == "DNS" and value.lower() == identity.lower():
        matched = True
    elif expected_ip is not None and kind == "IP Address":
        try:
            matched = ipaddress.ip_address(value) == expected_ip
        except ValueError:
            matched = False
    if matched:
        break
raise SystemExit(0 if matched else 1)
PY
}

certificate_private_key_matches() {
    local certificate="$1" private_key="$2" cert_public="" key_public=""
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    openssl pkey -in "$private_key" -check -noout -passin pass: \
        >/dev/null 2>&1 || return 1
    cert_public=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    key_public=$(openssl pkey -in "$private_key" -pubout 2>/dev/null | sha256sum | awk '{print $1}') || return 1
    [[ "$cert_public" =~ ^[0-9a-f]{64}$ ]] && [ "$cert_public" = "$key_public" ]
}

certificate_chain_is_trusted() {
    local certificate="$1"
    local ca_bundle="${RR_CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"
    [ -s "$certificate" ] && [ -s "$ca_bundle" ] || return 1
    # fullchain.pem contains the leaf followed by its intermediates.  Supply it
    # as both the target and untrusted chain while anchoring validation in the
    # operating system CA bundle; this also checks notBefore/notAfter and the
    # TLS-server purpose instead of accepting a matching self-signed leaf.
    openssl verify -purpose sslserver -CAfile "$ca_bundle" \
        -untrusted "$certificate" "$certificate" >/dev/null 2>&1
}

subscription_certificate_pair_valid() {
    local certificate="$1" private_key="$2" domain="$3"
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    is_valid_domain "$domain" || return 1
    certificate_identity_matches "$certificate" "$domain" || return 1
    openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    certificate_private_key_matches "$certificate" "$private_key" || return 1
    certificate_chain_is_trusted "$certificate"
}

rr_certbot_webroot_lineage_is_renewable() {
    # A valid leaf/key pair is not proof that Certbot can renew it.  Portable
    # restore and update paths must therefore prove the complete, production
    # Webroot lineage without invoking Certbot or changing any global state.
    local domain="${1:-}"
    local config_root="${RR_LE_CONFIG_ROOT:-/etc/letsencrypt}"
    local live_root="${RR_LE_LIVE_ROOT:-${config_root}/live}"
    local archive_root="${RR_LE_ARCHIVE_ROOT:-${config_root}/archive}"
    local renewal_root="${RR_LE_RENEWAL_ROOT:-${config_root}/renewal}"
    local accounts_root="${RR_LE_ACCOUNTS_ROOT:-${config_root}/accounts}"
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"

    is_valid_domain "$domain" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    python3 - "$domain" "$config_root" "$live_root" "$archive_root" \
        "$renewal_root" "$accounts_root" "$webroot" >/dev/null 2>&1 <<'PY'
import base64
import binascii
import datetime
import hashlib
import json
import math
import os
import pathlib
import re
import stat
import subprocess
import sys
import urllib.parse

(
    domain,
    config_root_raw,
    live_root_raw,
    archive_root_raw,
    renewal_root_raw,
    accounts_root_raw,
    webroot_raw,
) = sys.argv[1:]

PRODUCTION_SERVER = "https://acme-v02.api.letsencrypt.org/directory"
PRODUCTION_HOST = "acme-v02.api.letsencrypt.org"
LEGACY_PRODUCTION_HOST = "acme-v01.api.letsencrypt.org"
MAX_RENEWAL_BYTES = 128 * 1024
MAX_JSON_BYTES = 1024 * 1024
MAX_PEM_BYTES = 4 * 1024 * 1024
MAX_CERTIFICATES = 16


class InvalidLineage(Exception):
    pass


def exact_absolute_path(raw):
    if not raw or "\x00" in raw:
        raise InvalidLineage("empty path")
    path = pathlib.Path(raw)
    if not path.is_absolute() or str(path) != raw or ".." in path.parts:
        raise InvalidLineage("non-canonical configured path")
    return path


config_root = exact_absolute_path(config_root_raw)
live_root = exact_absolute_path(live_root_raw)
archive_root = exact_absolute_path(archive_root_raw)
renewal_root = exact_absolute_path(renewal_root_raw)
accounts_root = exact_absolute_path(accounts_root_raw)
webroot = exact_absolute_path(webroot_raw)


def lstat(path):
    try:
        return path.lstat()
    except OSError as error:
        raise InvalidLineage(f"cannot inspect {path}: {error.errno}") from error


def require_secure_directory(path, *, canonical_tmp=False, secret=False):
    info = lstat(path)
    if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise InvalidLineage(f"not a real directory: {path}")
    permissions = stat.S_IMODE(info.st_mode)
    if (info.st_uid, info.st_gid) != (0, 0):
        raise InvalidLineage(f"unsafe directory ownership or mode: {path}")
    if canonical_tmp:
        if path != pathlib.Path("/tmp") or permissions != 0o1777:
            raise InvalidLineage(f"unsafe canonical temporary directory: {path}")
    elif permissions & 0o7022:
        raise InvalidLineage(f"unsafe directory ownership or mode: {path}")
    if secret and permissions & 0o077:
        raise InvalidLineage(f"secret directory is accessible by group/other: {path}")
    try:
        if path.resolve(strict=True) != path:
            raise InvalidLineage(f"directory contains a symlink: {path}")
    except OSError as error:
        raise InvalidLineage(f"cannot resolve directory: {path}") from error


def require_secure_directory_chain(path, *, secret_leaf=False):
    # Validating only the leaf is insufficient: a writable or linked ancestor
    # can replace the proven Webroot/lineage after this read-only check.  Walk
    # from / down to the leaf so every name-resolution boundary is immutable
    # to unprivileged users.  Linux's canonical /tmp is the sole sticky-dir
    # exception, used by the hermetic regression fixture.
    for member in (*reversed(path.parents), path):
        require_secure_directory(
            member,
            canonical_tmp=(member == pathlib.Path("/tmp")),
            secret=(secret_leaf and member == path),
        )


def require_secure_regular(path, maximum, *, nonempty=True, secret=False):
    info = lstat(path)
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise InvalidLineage(f"not a real regular file: {path}")
    permissions = stat.S_IMODE(info.st_mode)
    if (info.st_uid, info.st_gid) != (0, 0) or permissions & 0o022:
        raise InvalidLineage(f"unsafe file ownership or mode: {path}")
    if permissions & 0o111:
        raise InvalidLineage(f"unexpected executable lineage file: {path}")
    if secret and permissions & 0o077:
        raise InvalidLineage(f"secret file is accessible by group/other: {path}")
    if info.st_nlink != 1 or info.st_size > maximum:
        raise InvalidLineage(f"unsafe file links or size: {path}")
    if nonempty and info.st_size == 0:
        raise InvalidLineage(f"empty file: {path}")
    return info


for required_root in (
    config_root,
    live_root,
    archive_root,
    renewal_root,
    accounts_root,
    webroot,
    webroot / ".well-known",
    webroot / ".well-known" / "acme-challenge",
):
    require_secure_directory_chain(required_root)

live_dir = live_root / domain
archive_dir = archive_root / domain
require_secure_directory_chain(live_dir)
require_secure_directory_chain(archive_dir)

renewal_file = renewal_root / f"{domain}.conf"
require_secure_regular(renewal_file, MAX_RENEWAL_BYTES)
try:
    renewal_bytes = renewal_file.read_bytes()
    renewal_text = renewal_bytes.decode("utf-8", errors="strict")
except (OSError, UnicodeError) as error:
    raise InvalidLineage("renewal configuration is unreadable UTF-8") from error
if "\x00" in renewal_text:
    raise InvalidLineage("NUL in renewal configuration")


def parse_renewal(text):
    sections = {"top": {}}
    section_counts = {"top": 1}
    section = "top"
    for number, raw_line in enumerate(text.splitlines(), 1):
        if len(raw_line.encode("utf-8")) > 4096:
            raise InvalidLineage(f"oversized renewal line {number}")
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line in {
            "[renewalparams]",
            "[[webroot_map]]",
            "[acme_renewal_info]",
        }:
            # ConfigObj accepts a double-bracket section only while its
            # single-bracket parent is current.  A map placed before
            # renewalparams, or after an interposed ARI section, is not the
            # Certbot structure it appears to be when flattened.
            if line == "[[webroot_map]]" and section != "renewalparams":
                raise InvalidLineage("webroot_map is not nested under renewalparams")
            section = {
                "[renewalparams]": "renewalparams",
                "[[webroot_map]]": "webroot_map",
                "[acme_renewal_info]": "acme_renewal_info",
            }[line]
            section_counts[section] = section_counts.get(section, 0) + 1
            if section_counts[section] != 1:
                raise InvalidLineage(f"duplicate renewal section: {section}")
            sections[section] = {}
            continue
        if line.startswith("["):
            raise InvalidLineage(f"unknown renewal section on line {number}")
        if "=" not in line:
            raise InvalidLineage(f"invalid renewal line {number}")
        key, value = (part.strip() for part in line.split("=", 1))
        if not key or not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            raise InvalidLineage(f"invalid renewal key on line {number}")
        bucket = sections.setdefault(section, {})
        if key in bucket:
            raise InvalidLineage(f"duplicate renewal key: {key}")
        bucket[key] = value
    if section_counts.get("renewalparams") != 1:
        raise InvalidLineage("renewal configuration lacks one renewalparams section")
    if section_counts.get("webroot_map") != 1:
        raise InvalidLineage("renewal configuration lacks one webroot_map section")
    return sections


renewal = parse_renewal(renewal_text)
top = renewal.get("top", {})
params = renewal.get("renewalparams", {})
webroot_map = renewal.get("webroot_map", {})
renewal_info = renewal.get("acme_renewal_info")
required_top = {
    "archive_dir": str(archive_dir),
    "cert": str(live_dir / "cert.pem"),
    "privkey": str(live_dir / "privkey.pem"),
    "chain": str(live_dir / "chain.pem"),
    "fullchain": str(live_dir / "fullchain.pem"),
}
if any(top.get(key) != expected for key, expected in required_top.items()):
    raise InvalidLineage("renewal paths do not match the configured roots")
if params.get("authenticator") != "webroot":
    raise InvalidLineage("lineage is not Webroot-authenticated")
if params.get("server") != PRODUCTION_SERVER:
    raise InvalidLineage("lineage is not bound to production ACME")
if "autorenew" in params and params["autorenew"].strip().lower() != "true":
    raise InvalidLineage("lineage disables automatic renewal")
if "config_dir" in params and params["config_dir"] != str(config_root):
    raise InvalidLineage("lineage uses a different Certbot config root")
if renewal_info is not None:
    if set(renewal_info) != {"ari_retry_after"}:
        raise InvalidLineage("unsupported ACME renewal information")
    retry_after = renewal_info["ari_retry_after"].strip()
    try:
        parsed_retry_after = datetime.datetime.fromisoformat(retry_after)
    except ValueError as error:
        raise InvalidLineage("invalid ARI retry timestamp") from error
    if (
        parsed_retry_after.tzinfo is not None
        or parsed_retry_after.isoformat(timespec="seconds") != retry_after
    ):
        raise InvalidLineage("non-canonical ARI retry timestamp")

account = params.get("account", "")
if not re.fullmatch(r"[0-9a-f]{32}", account):
    raise InvalidLineage("unsafe Certbot account identifier")


def normalize_webroot_value(value):
    value = value.strip()
    if value.endswith(","):
        value = value[:-1].rstrip()
    if "," in value:
        raise InvalidLineage("multiple fallback Webroot paths")
    return value


mapped = [
    value
    for mapped_domain, value in webroot_map.items()
    if mapped_domain.lower() == domain.lower()
]
if len(mapped) > 1:
    raise InvalidLineage("duplicate domain Webroot mapping")
if mapped:
    selected_webroot = normalize_webroot_value(mapped[0])
else:
    selected_webroot = normalize_webroot_value(params.get("webroot_path", ""))
if selected_webroot != str(webroot):
    raise InvalidLineage("lineage Webroot does not match RR's challenge root")

def lexical_link_target(link, raw_target):
    target = pathlib.Path(raw_target)
    if not target.is_absolute():
        target = link.parent / target
    return pathlib.Path(os.path.normpath(str(target)))


generation = None
archive_entries = {}
for stem in ("cert", "privkey", "chain", "fullchain"):
    live_file = live_dir / f"{stem}.pem"
    info = lstat(live_file)
    if (
        not stat.S_ISLNK(info.st_mode)
        or (info.st_uid, info.st_gid) != (0, 0)
        or info.st_nlink != 1
    ):
        raise InvalidLineage(f"live member is not a root-owned symlink: {live_file}")
    try:
        raw_target = os.readlink(live_file)
    except OSError as error:
        raise InvalidLineage(f"cannot read live symlink: {live_file}") from error
    target = lexical_link_target(live_file, raw_target)
    match = re.fullmatch(rf"{re.escape(stem)}([1-9][0-9]*)\.pem", target.name)
    if (
        target.parent != archive_dir
        or match is None
        or raw_target != os.path.relpath(target, live_file.parent)
    ):
        raise InvalidLineage(f"live member escapes its exact archive mapping: {live_file}")
    member_generation = int(match.group(1))
    if generation is None:
        generation = member_generation
    elif generation != member_generation:
        raise InvalidLineage("live members reference mixed archive generations")
    archive_entries[stem] = target

archive_files = {}
for stem, archive_entry in archive_entries.items():
    entry_info = lstat(archive_entry)
    material = archive_entry
    if stat.S_ISLNK(entry_info.st_mode):
        # Certbot --reuse-key represents only a successor privkey archive
        # member as a one-hop link to an older privkey generation.  Take N
        # from the live link above, then resolve exactly this bounded form.
        if (
            stem != "privkey"
            or (entry_info.st_uid, entry_info.st_gid) != (0, 0)
            or entry_info.st_nlink != 1
        ):
            raise InvalidLineage(f"unexpected archive symlink: {archive_entry}")
        try:
            archive_raw_target = os.readlink(archive_entry)
            material = lexical_link_target(archive_entry, archive_raw_target)
        except OSError as error:
            raise InvalidLineage(f"cannot read archive key symlink: {archive_entry}") from error
        reuse_match = re.fullmatch(r"privkey([1-9][0-9]*)\.pem", material.name)
        if (
            material.parent != archive_dir
            or reuse_match is None
            or material == archive_entry
            or int(reuse_match.group(1)) >= generation
            or archive_raw_target != os.path.relpath(material, archive_entry.parent)
        ):
            raise InvalidLineage("reused private key escapes its lineage archive")
    require_secure_regular(material, MAX_PEM_BYTES, secret=(stem == "privkey"))
    archive_files[stem] = material


def run_openssl(arguments, *, input_bytes=None, pass_fds=()):
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            ["openssl", *arguments],
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=environment,
            check=False,
            timeout=10,
            pass_fds=pass_fds,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise InvalidLineage("OpenSSL could not validate lineage material") from error
    if result.returncode != 0:
        raise InvalidLineage("OpenSSL rejected lineage material")
    return result.stdout


def parse_certificate_pem(data, label):
    begin = b"-----BEGIN CERTIFICATE-----"
    end = b"-----END CERTIFICATE-----"
    certificates = []
    offset = 0
    while offset < len(data):
        if not data.startswith(begin, offset):
            raise InvalidLineage(f"non-certificate data in {label}")
        payload_start = offset + len(begin)
        if data.startswith(b"\r\n", payload_start):
            payload_start += 2
        elif data.startswith(b"\n", payload_start):
            payload_start += 1
        else:
            raise InvalidLineage(f"invalid PEM header in {label}")
        payload_end = data.find(end, payload_start)
        if payload_end < 0:
            raise InvalidLineage(f"unterminated certificate in {label}")
        payload = data[payload_start:payload_end].replace(b"\r", b"").replace(b"\n", b"")
        if not payload or re.fullmatch(rb"[A-Za-z0-9+/]+={0,2}", payload) is None:
            raise InvalidLineage(f"invalid certificate encoding in {label}")
        try:
            certificate = base64.b64decode(payload, validate=True)
        except (ValueError, binascii.Error) as error:
            raise InvalidLineage(f"invalid certificate base64 in {label}") from error
        if base64.b64encode(certificate) != payload:
            raise InvalidLineage(f"non-canonical certificate encoding in {label}")
        run_openssl(["x509", "-inform", "DER", "-noout"], input_bytes=certificate)
        certificates.append(certificate)
        if len(certificates) > MAX_CERTIFICATES:
            raise InvalidLineage(f"too many certificates in {label}")
        offset = payload_end + len(end)
        if data.startswith(b"\r\n", offset):
            offset += 2
        elif data.startswith(b"\n", offset):
            offset += 1
        elif offset != len(data):
            raise InvalidLineage(f"invalid PEM separator in {label}")
    if not certificates:
        raise InvalidLineage(f"empty certificate set in {label}")
    return certificates


try:
    cert_bytes = archive_files["cert"].read_bytes()
    chain_bytes = archive_files["chain"].read_bytes()
    fullchain_bytes = archive_files["fullchain"].read_bytes()
    privkey_bytes = archive_files["privkey"].read_bytes()
except OSError as error:
    raise InvalidLineage("cannot read archive lineage material") from error

leaf_certificates = parse_certificate_pem(cert_bytes, "cert.pem")
chain_certificates = parse_certificate_pem(chain_bytes, "chain.pem")
fullchain_certificates = parse_certificate_pem(fullchain_bytes, "fullchain.pem")
if len(leaf_certificates) != 1:
    raise InvalidLineage("cert.pem does not contain exactly one leaf")
if fullchain_bytes != cert_bytes + chain_bytes:
    raise InvalidLineage("fullchain.pem is not the exact cert.pem plus chain.pem")
if fullchain_certificates != leaf_certificates + chain_certificates:
    raise InvalidLineage("fullchain certificate sequence is inconsistent")
if len(set(fullchain_certificates)) != len(fullchain_certificates):
    raise InvalidLineage("fullchain contains a duplicate certificate")


def certificate_pem(certificate):
    encoded = base64.b64encode(certificate)
    return (
        b"-----BEGIN CERTIFICATE-----\n"
        + b"\n".join(
            encoded[offset:offset + 64]
            for offset in range(0, len(encoded), 64)
        )
        + b"\n-----END CERTIFICATE-----\n"
    )


def write_memfd(label, payload):
    try:
        descriptor = os.memfd_create(label, flags=0)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("short memfd write")
            view = view[written:]
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor
    except (AttributeError, OSError) as error:
        try:
            os.close(descriptor)
        except (NameError, OSError):
            pass
        raise InvalidLineage("cannot stage an in-memory chain proof") from error


def verify_direct_issuer(child, issuer, *, server_leaf=False):
    child_fd = None
    issuer_fd = None
    try:
        child_fd = write_memfd("rr-cert-child", certificate_pem(child))
        issuer_fd = write_memfd("rr-cert-issuer", certificate_pem(issuer))
        arguments = [
            "verify",
            "-no-CAfile",
            "-no-CApath",
            "-partial_chain",
        ]
        if server_leaf:
            arguments.extend(("-purpose", "sslserver"))
        arguments.extend((
            "-trusted",
            f"/proc/self/fd/{issuer_fd}",
            f"/proc/self/fd/{child_fd}",
        ))
        run_openssl(arguments, pass_fds=(child_fd, issuer_fd))
    finally:
        for descriptor in (child_fd, issuer_fd):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


certificate_sequence = leaf_certificates + chain_certificates
for index in range(len(certificate_sequence) - 1):
    verify_direct_issuer(
        certificate_sequence[index],
        certificate_sequence[index + 1],
        server_leaf=(index == 0),
    )

leaf_certificate = leaf_certificates[0]
run_openssl(
    ["x509", "-inform", "DER", "-checkend", "604800", "-noout"],
    input_bytes=leaf_certificate,
)
san_text = run_openssl(
    ["x509", "-inform", "DER", "-noout", "-ext", "subjectAltName"],
    input_bytes=leaf_certificate,
).decode("ascii", errors="strict")
san_lines = san_text.splitlines()
if len(san_lines) < 2 or not san_lines[0].startswith("X509v3 Subject Alternative Name:"):
    raise InvalidLineage("leaf certificate lacks a usable SAN")
san_entries = [
    entry.strip()
    for entry in " ".join(san_lines[1:]).split(",")
    if entry.strip()
]
if len(san_entries) != 1 or not san_entries[0].startswith("DNS:"):
    raise InvalidLineage("leaf certificate SAN policy is not exact")
if san_entries[0][4:].lower() != domain.lower():
    raise InvalidLineage("leaf certificate SAN does not equal the lineage domain")

private_key_pattern = re.compile(
    rb"(?:"
    rb"-----BEGIN PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+"
    rb"-----END PRIVATE KEY-----"
    rb"|"
    rb"-----BEGIN RSA PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+"
    rb"-----END RSA PRIVATE KEY-----"
    rb"|"
    rb"-----BEGIN EC PRIVATE KEY-----\r?\n[A-Za-z0-9+/=\r\n]+"
    rb"-----END EC PRIVATE KEY-----"
    rb")\r?\n?\Z"
)
if private_key_pattern.fullmatch(privkey_bytes) is None:
    raise InvalidLineage("privkey.pem is not one unencrypted private key")
run_openssl(
    ["pkey", "-check", "-noout", "-passin", "pass:"],
    input_bytes=privkey_bytes,
)
certificate_public_key = run_openssl(
    ["x509", "-inform", "DER", "-pubkey", "-noout"],
    input_bytes=leaf_certificate,
)
private_public_key = run_openssl(
    ["pkey", "-pubout", "-passin", "pass:"], input_bytes=privkey_bytes
)
if certificate_public_key != private_public_key:
    raise InvalidLineage("privkey.pem does not match cert.pem")
server_dir = accounts_root / PRODUCTION_HOST
directory_dir = server_dir / "directory"
require_secure_directory_chain(server_dir)
account_base = directory_dir
directory_info = lstat(directory_dir)
if stat.S_ISLNK(directory_info.st_mode):
    # Certbot's official LE_REUSE_SERVERS migration reuses the historical v1
    # account store through exactly this one relative directory link.  Accept
    # no other account alias, absolute target, chain or writable ancestor.
    if (
        (directory_info.st_uid, directory_info.st_gid, directory_info.st_nlink)
        != (0, 0, 1)
    ):
        raise InvalidLineage("unsafe production account directory alias")
    try:
        directory_raw_target = os.readlink(directory_dir)
    except OSError as error:
        raise InvalidLineage("cannot read production account directory alias") from error
    legacy_directory = accounts_root / LEGACY_PRODUCTION_HOST / "directory"
    expected_relative = os.path.relpath(legacy_directory, directory_dir.parent)
    if (
        directory_raw_target != expected_relative
        or lexical_link_target(directory_dir, directory_raw_target) != legacy_directory
    ):
        raise InvalidLineage("production account directory alias is not Certbot's v1 reuse link")
    require_secure_directory_chain(legacy_directory)
    account_base = legacy_directory
else:
    require_secure_directory_chain(directory_dir)
account_dir = account_base / account
require_secure_directory_chain(account_dir, secret_leaf=True)


def read_json(name, *, secret=False):
    path = account_dir / name
    require_secure_regular(path, MAX_JSON_BYTES, secret=secret)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InvalidLineage(f"invalid account JSON: {name}") from error
    if not isinstance(value, dict):
        raise InvalidLineage(f"account JSON is not an object: {name}")
    return value


private_key = read_json("private_key.json", secret=True)
registration = read_json("regr.json")
metadata = read_json("meta.json")


def jwk_integer(name):
    encoded = private_key.get(name)
    if not isinstance(encoded, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", encoded):
        raise InvalidLineage(f"account JWK has an invalid {name}")
    try:
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
    except (ValueError, binascii.Error) as error:
        raise InvalidLineage(f"account JWK has invalid base64url in {name}") from error
    if not raw or raw[0] == 0 or base64.urlsafe_b64encode(raw).rstrip(b"=").decode() != encoded:
        raise InvalidLineage(f"account JWK has a non-canonical {name}")
    return int.from_bytes(raw, "big")


if private_key.get("kty") != "RSA":
    raise InvalidLineage("Certbot account JWK is not an RSA private key")
n, e, d, p, q, dp, dq, qi = (
    jwk_integer(name) for name in ("n", "e", "d", "p", "q", "dp", "dq", "qi")
)
if (
    not 2048 <= n.bit_length() <= 8192
    or e.bit_length() > 64
    or d.bit_length() > 8192
    or p.bit_length() > 4096
    or q.bit_length() > 4096
    or dp.bit_length() > 4096
    or dq.bit_length() > 4096
    or qi.bit_length() > 4096
    or p <= 2
    or q <= 2
    or p == q
    or p * q != n
):
    raise InvalidLineage("account RSA key has invalid factors or strength")
lcm = math.lcm(p - 1, q - 1)
if e < 3 or e % 2 == 0 or math.gcd(e, lcm) != 1 or (e * d) % lcm != 1:
    raise InvalidLineage("account RSA key has invalid exponents")
if dp != d % (p - 1) or dq != d % (q - 1) or (q * qi) % p != 1:
    raise InvalidLineage("account RSA key has invalid CRT parameters")


def der_length(length):
    if length < 128:
        return bytes((length,))
    encoded = length.to_bytes((length.bit_length() + 7) // 8, "big")
    return bytes((0x80 | len(encoded),)) + encoded


def der_value(tag, payload):
    return bytes((tag,)) + der_length(len(payload)) + payload


def der_integer(value):
    encoded = value.to_bytes(max(1, (value.bit_length() + 7) // 8), "big")
    if encoded[0] & 0x80:
        encoded = b"\x00" + encoded
    return der_value(0x02, encoded)


rsa_private_key = der_value(
    0x30,
    b"".join(
        der_integer(value)
        for value in (0, n, e, d, p, q, dp, dq, qi)
    ),
)
# Algebraic congruences alone do not prove p and q are prime.  Delegate the
# full RSA private-key consistency check to OpenSSL's maintained backend.
run_openssl(
    ["pkey", "-inform", "DER", "-check", "-noout"],
    input_bytes=rsa_private_key,
)

rsa_public_key = der_value(0x30, der_integer(n) + der_integer(e))
rsa_algorithm_identifier = bytes.fromhex("300d06092a864886f70d0101010500")
subject_public_key_info = der_value(
    0x30,
    rsa_algorithm_identifier + der_value(0x03, b"\x00" + rsa_public_key),
)
public_key_base64 = base64.b64encode(subject_public_key_info)
public_key_pem = (
    b"-----BEGIN PUBLIC KEY-----\n"
    + b"\n".join(
        public_key_base64[offset:offset + 64]
        for offset in range(0, len(public_key_base64), 64)
    )
    + b"\n-----END PUBLIC KEY-----\n"
)
# Certbot's on-disk account id is an MD5 filename key over this canonical
# public SPKI PEM.  MD5 is reproduced only for format compatibility, never as
# an authenticity primitive; all RSA private parameters were checked above.
try:
    account_digest = hashlib.md5(public_key_pem, usedforsecurity=False).hexdigest()
except TypeError:
    # Python before usedforsecurity support is retained only for non-FIPS
    # legacy hosts; modern FIPS builds take the explicit non-security path.
    account_digest = hashlib.md5(public_key_pem).hexdigest()
if account != account_digest:
    raise InvalidLineage("renewal account id does not match the account JWK")

registration_body = registration.get("body")
if not isinstance(registration_body, dict):
    raise InvalidLineage("account registration body is not an object")
if "status" in registration_body and registration_body["status"] != "valid":
    raise InvalidLineage("account registration status is not valid")
contacts = registration_body.get("contact", [])
if not isinstance(contacts, list) or any(
    not isinstance(contact, str)
    or len(contact) > 2048
    or not urllib.parse.urlsplit(contact).scheme
    or any(character.isspace() for character in contact)
    for contact in contacts
):
    raise InvalidLineage("account registration contacts are invalid")
if "termsOfServiceAgreed" in registration_body and \
   registration_body["termsOfServiceAgreed"] is not True:
    raise InvalidLineage("account registration has not agreed to the terms")
registration_uri = registration.get("uri")
if not isinstance(registration_uri, str):
    raise InvalidLineage("account registration lacks URI")
try:
    parsed_uri = urllib.parse.urlsplit(registration_uri)
    parsed_port = parsed_uri.port
except ValueError as error:
    raise InvalidLineage("invalid account registration URI") from error
if (
    parsed_uri.scheme != "https"
    or parsed_uri.hostname != PRODUCTION_HOST
    or parsed_port is not None
    or parsed_uri.username is not None
    or parsed_uri.password is not None
    or parsed_uri.query
    or parsed_uri.fragment
    or not re.fullmatch(r"/acme/acct/[1-9][0-9]*", parsed_uri.path)
):
    raise InvalidLineage("account registration is not bound to production ACME")

creation_host = metadata.get("creation_host")
creation_dt = metadata.get("creation_dt")
if not isinstance(creation_host, str) or not re.fullmatch(
    r"[A-Za-z0-9._-]{1,253}", creation_host
):
    raise InvalidLineage("account metadata has an invalid creation host")
if not isinstance(creation_dt, str):
    raise InvalidLineage("account metadata lacks a creation timestamp")
if re.fullmatch(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}"
    r"(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})",
    creation_dt,
) is None:
    raise InvalidLineage("account metadata timestamp is not RFC3339")
try:
    parsed_creation_dt = datetime.datetime.fromisoformat(
        creation_dt[:-1] + "+00:00" if creation_dt.endswith("Z") else creation_dt
    )
except ValueError as error:
    raise InvalidLineage("account metadata has an invalid creation timestamp") from error
if parsed_creation_dt.tzinfo is None:
    raise InvalidLineage("account creation timestamp lacks a timezone")
if "register_to_eff" in metadata and metadata["register_to_eff"] is not None:
    eff_email = metadata["register_to_eff"]
    if (
        not isinstance(eff_email, str)
        or not 1 <= len(eff_email) <= 254
        or eff_email.count("@") != 1
        or any(character.isspace() or ord(character) < 0x20 or ord(character) == 0x7f
               for character in eff_email)
    ):
        raise InvalidLineage("account metadata has an invalid EFF registration email")
    eff_local, eff_domain = eff_email.rsplit("@", 1)
    if not eff_local or not eff_domain or len(eff_local) > 64 or len(eff_domain) > 253:
        raise InvalidLineage("account metadata has an invalid EFF registration email")
PY
}

rr_certbot_acme_effective_route_probe() (
    local domain="${1:-}" webroot="${2:-}" curl_path=""
    is_valid_domain "$domain" || return 1
    case "$webroot" in /*) ;; *) return 1 ;; esac
    curl_path=$(command -v curl 2>/dev/null) || return 1
    [ -f "$curl_path" ] && [ ! -L "$curl_path" ] && [ -x "$curl_path" ] || return 1
    python3 - "$domain" "$webroot" "$curl_path" <<'PY'
import errno
import os
import pathlib
import re
import secrets
import signal
import stat
import subprocess
import sys

domain, webroot_raw, curl_path = sys.argv[1:]
DOMAIN = re.compile(
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
)
PROBE_PREFIX = "rr-route-probe-v1_"
TOKEN = re.compile(r"[A-Za-z0-9_-]{32}")
BODY = re.compile(rb"rr-route-probe-v1:[A-Za-z0-9_-]{43}")
BODY_SIZE = 61
MAX_RESPONSE = 1024


class ProbeFailure(Exception):
    pass


def interrupted(_signum, _frame):
    raise ProbeFailure("interrupted")


for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, interrupted)


def secure_directory(path):
    try:
        info = path.lstat()
    except OSError as error:
        raise ProbeFailure("missing directory") from error
    mode = stat.S_IMODE(info.st_mode)
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or (info.st_uid, info.st_gid) != (0, 0)
    ):
        raise ProbeFailure("unsafe directory")
    if path == pathlib.Path("/tmp"):
        if mode != 0o1777:
            raise ProbeFailure("unsafe temporary directory")
    elif mode & 0o022:
        raise ProbeFailure("writable directory")
    try:
        if path.resolve(strict=True) != path:
            raise ProbeFailure("linked directory")
    except OSError as error:
        raise ProbeFailure("unresolvable directory") from error


def secure_directory_chain(path):
    for member in (*reversed(path.parents), path):
        secure_directory(member)


def read_exact(descriptor, limit):
    data = b""
    while len(data) <= limit:
        chunk = os.read(descriptor, min(65536, limit + 1 - len(data)))
        if not chunk:
            return data
        data += chunk
    raise ProbeFailure("file exceeds bound")


def stat_at(directory_fd, name):
    try:
        return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError as error:
        raise ProbeFailure("cannot stat probe") from error


def validate_probe(directory_fd, name, expected_body=None, expected_identity=None):
    info = stat_at(directory_fd, name)
    if (
        not stat.S_ISREG(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or (info.st_uid, info.st_gid) != (0, 0)
        or stat.S_IMODE(info.st_mode) != 0o644
        or info.st_nlink != 1
        or info.st_size != BODY_SIZE
    ):
        raise ProbeFailure("unsafe probe metadata")
    identity = (info.st_dev, info.st_ino)
    if expected_identity is not None and identity != expected_identity:
        raise ProbeFailure("probe inode changed")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        dir_fd=directory_fd,
    )
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != identity:
            raise ProbeFailure("probe changed before open")
        data = read_exact(descriptor, BODY_SIZE)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (
        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        or len(data) != BODY_SIZE
        or BODY.fullmatch(data) is None
        or (expected_body is not None and data != expected_body)
    ):
        raise ProbeFailure("probe content changed")
    return identity, data


def unlink_verified(directory_fd, name, expected_body=None, expected_identity=None):
    validate_probe(directory_fd, name, expected_body, expected_identity)
    os.unlink(name, dir_fd=directory_fd)
    os.fsync(directory_fd)
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise ProbeFailure("cannot prove probe absence") from error
    raise ProbeFailure("probe remains after unlink")


if DOMAIN.fullmatch(domain) is None:
    raise SystemExit(1)
webroot = pathlib.Path(webroot_raw)
if not webroot.is_absolute() or str(webroot) != webroot_raw or ".." in webroot.parts:
    raise SystemExit(1)
challenge = webroot / ".well-known" / "acme-challenge"
secure_directory_chain(challenge)
directory_fd = os.open(
    challenge,
    os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW,
)
name = None
body = None
identity = None
failure = None
cleanup_failure = None
try:
    directory_info = os.fstat(directory_fd)
    path_info = challenge.lstat()
    if (
        (directory_info.st_dev, directory_info.st_ino)
        != (path_info.st_dev, path_info.st_ino)
        or not stat.S_ISDIR(directory_info.st_mode)
        or (directory_info.st_uid, directory_info.st_gid) != (0, 0)
        or stat.S_IMODE(directory_info.st_mode) & 0o022
    ):
        raise ProbeFailure("challenge directory changed before use")

    # A SIGKILL cannot run a trap.  Converge only exact, nonsensitive probe
    # leftovers; any link, hardlink, owner/mode/size anomaly fails closed.
    for stale in os.listdir(directory_fd):
        if not stale.startswith(PROBE_PREFIX):
            continue
        suffix = stale[len(PROBE_PREFIX):]
        if TOKEN.fullmatch(suffix) is None:
            raise ProbeFailure("malformed stale probe")
        unlink_verified(directory_fd, stale)

    suffix = secrets.token_urlsafe(24)
    payload = secrets.token_urlsafe(32)
    if TOKEN.fullmatch(suffix) is None or len(payload) != 43:
        raise ProbeFailure("random token has the wrong shape")
    name = PROBE_PREFIX + suffix
    if re.fullmatch(r"[A-Za-z0-9_-]{50}", name) is None:
        raise ProbeFailure("ACME probe token has the wrong shape")
    body = ("rr-route-probe-v1:" + payload).encode("ascii")
    if len(body) != BODY_SIZE or BODY.fullmatch(body) is None:
        raise ProbeFailure("probe body has the wrong shape")
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o644,
        dir_fd=directory_fd,
    )
    try:
        os.fchown(descriptor, 0, 0)
        os.fchmod(descriptor, 0o644)
        view = memoryview(body)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise ProbeFailure("short probe write")
            view = view[written:]
        os.fsync(descriptor)
        created = os.fstat(descriptor)
        identity = (created.st_dev, created.st_ino)
    finally:
        os.close(descriptor)
    os.fsync(directory_fd)
    validate_probe(directory_fd, name, body, identity)

    url = f"http://{domain}/.well-known/acme-challenge/{name}"
    for address in ("127.0.0.1", "[::1]"):
        secure_directory_chain(challenge)
        current_directory = challenge.lstat()
        if (current_directory.st_dev, current_directory.st_ino) != (
            directory_info.st_dev,
            directory_info.st_ino,
        ):
            raise ProbeFailure("challenge directory changed before request")
        validate_probe(directory_fd, name, body, identity)
        command = [
            curl_path,
            "-q",
            "--noproxy", "*",
            "--path-as-is",
            "--silent",
            "--show-error",
            "--fail-with-body",
            "--connect-timeout", "2",
            "--max-time", "5",
            "--max-filesize", str(MAX_RESPONSE),
            "--request", "GET",
            "--resolve", f"{domain}:80:{address}",
            "--output", "-",
            "--write-out", "%{http_code}",
            "--url", url,
        ]
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=7,
            check=False,
        )
        if result.returncode != 0 or result.stdout != body + b"200":
            raise ProbeFailure("effective route did not return the exact probe")
    validate_probe(directory_fd, name, body, identity)
except BaseException as error:
    failure = error
finally:
    if name is not None:
        try:
            secure_directory_chain(challenge)
            unlink_verified(directory_fd, name, body, identity)
        except BaseException as error:
            cleanup_failure = error
    os.close(directory_fd)
if failure is not None or cleanup_failure is not None:
    raise SystemExit(1)
PY
)

rr_certbot_acme_http_route_is_ready() {
    # Certbot's timer can be healthy while every Webroot challenge is routed
    # to a 404, an unrelated virtual host, or a closed port.  Prove the local
    # renewal path without changing Nginx, Certbot state or the firewall: one
    # of RR's exact enabled-site names must be a safe root-owned
    # link to a safe root-owned site containing this domain's port-80 Webroot
    # route.  Other concurrently enabled RR sites may serve different domains,
    # but every present RR enabled-site entry must itself remain well formed.
    local domain="${1:-}"
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    local naive_site="${RR_NAIVE_ACME_NGINX_SITE:-/etc/nginx/sites-available/rr-naive-acme.conf}"
    local naive_enabled="${RR_NAIVE_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-naive-acme.conf}"
    local nexus_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nexus_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local nexus_site="${NEXUS_NGINX_SITE:-${nexus_available_dir}/rr-nexus.conf}"

    is_valid_domain "$domain" || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    command -v nginx >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    command -v ss >/dev/null 2>&1 || return 1
    command -v curl >/dev/null 2>&1 || return 1
    declare -F rr_validate_protocol_firewall >/dev/null 2>&1 || return 1

    if ! python3 - "$domain" "$webroot" \
        "$naive_site" "$naive_enabled" \
        "$nexus_site" "$nexus_enabled_dir/rr-nexus.conf" \
        "${nexus_site}.port" "$nexus_enabled_dir/rr-nexus-port.conf" \
        >/dev/null 2>&1 <<'PY'
import os
import pathlib
import re
import stat
import sys

(
    expected_domain,
    webroot_raw,
    *candidate_values,
) = sys.argv[1:]

MAX_SITE_BYTES = 128 * 1024
DOMAIN = re.compile(
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
)


class InvalidRoute(Exception):
    pass


def exact_absolute_path(raw):
    if not raw or "\x00" in raw:
        raise InvalidRoute("empty path")
    path = pathlib.Path(raw)
    if not path.is_absolute() or str(path) != raw or ".." in path.parts:
        raise InvalidRoute("non-canonical path")
    return path


def secure_directory(path):
    try:
        info = path.lstat()
    except OSError as error:
        raise InvalidRoute("missing directory") from error
    mode = stat.S_IMODE(info.st_mode)
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_ISLNK(info.st_mode)
        or (info.st_uid, info.st_gid) != (0, 0)
    ):
        raise InvalidRoute("unsafe directory")
    if path == pathlib.Path("/tmp"):
        if mode != 0o1777:
            raise InvalidRoute("unsafe canonical temporary directory")
    elif mode & 0o022:
        raise InvalidRoute("writable directory")
    try:
        if path.resolve(strict=True) != path:
            raise InvalidRoute("linked directory")
    except OSError as error:
        raise InvalidRoute("unresolvable directory") from error


def secure_directory_chain(path):
    for member in (*reversed(path.parents), path):
        secure_directory(member)


def read_safe_site(path):
    secure_directory_chain(path.parent)
    try:
        before = path.lstat()
    except OSError as error:
        raise InvalidRoute("missing site") from error
    if (
        not stat.S_ISREG(before.st_mode)
        or stat.S_ISLNK(before.st_mode)
        or (before.st_uid, before.st_gid) != (0, 0)
        or stat.S_IMODE(before.st_mode) != 0o644
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > MAX_SITE_BYTES
    ):
        raise InvalidRoute("unsafe site")
    descriptor = None
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
        )
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise InvalidRoute("site changed before open")
        data = b""
        while len(data) <= MAX_SITE_BYTES:
            chunk = os.read(descriptor, min(65536, MAX_SITE_BYTES + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        after = os.fstat(descriptor)
    except OSError as error:
        raise InvalidRoute("cannot read site") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
    if (
        len(data) != before.st_size
        or len(data) > MAX_SITE_BYTES
        or (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        != (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    ):
        raise InvalidRoute("site changed while read")
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise InvalidRoute("site is not UTF-8") from error


def enabled_site(enabled, site):
    secure_directory_chain(enabled.parent)
    try:
        link_info = enabled.lstat()
    except FileNotFoundError:
        return None
    except OSError as error:
        raise InvalidRoute("cannot inspect enabled site") from error
    if (
        not stat.S_ISLNK(link_info.st_mode)
        or (link_info.st_uid, link_info.st_gid) != (0, 0)
        or link_info.st_nlink != 1
    ):
        raise InvalidRoute("unsafe enabled site")
    try:
        raw_target = os.readlink(enabled)
    except OSError as error:
        raise InvalidRoute("cannot read enabled site") from error
    if raw_target != str(site):
        raise InvalidRoute("enabled site has the wrong exact target")
    text = read_safe_site(site)
    try:
        link_after = enabled.lstat()
    except OSError as error:
        raise InvalidRoute("enabled site changed") from error
    if (link_after.st_dev, link_after.st_ino) != (link_info.st_dev, link_info.st_ino):
        raise InvalidRoute("enabled site changed while read")
    return text


def server_blocks(lines):
    blocks = []
    index = 0
    while index < len(lines):
        if re.fullmatch(r"server\s*\{", lines[index].strip()) is None:
            index += 1
            continue
        depth = 0
        end = index
        while end < len(lines):
            line = lines[end]
            if "\x00" in line:
                raise InvalidRoute("NUL in site")
            depth += line.count("{") - line.count("}")
            if depth < 0:
                raise InvalidRoute("unbalanced site")
            if depth == 0:
                blocks.append(lines[index:end + 1])
                index = end + 1
                break
            end += 1
        else:
            raise InvalidRoute("unterminated server block")
    return blocks


def route_from_site(text, expected_webroot):
    lines = text.splitlines()
    if any(re.match(r"^\s*include(?:\s|;)", line) for line in lines):
        raise InvalidRoute("site contains include")
    challenge_mentions = [
        line for line in lines
        if ".well-known/acme-challenge" in line and not line.lstrip().startswith("#")
    ]
    if len(challenge_mentions) != 1:
        raise InvalidRoute("site does not have one exact challenge location")

    def is_port_80_listener(line):
        if not line.startswith("listen ") or not line.endswith(";"):
            return False
        arguments = line[len("listen "):-1].split()
        if not arguments:
            raise InvalidRoute("empty listen directive")
        endpoint = arguments[0].lower()
        if endpoint.startswith("unix:"):
            return False
        return endpoint in {"80", "http"} or endpoint.endswith((":80", ":http"))

    routes = []
    for block in server_blocks(lines):
        depth = 0
        top_level = []
        challenge_body = None
        active_challenge_body = None
        location_depth = None
        for line in block:
            stripped = line.strip()
            if depth == 1:
                top_level.append(stripped)
                if stripped in {
                    "location /.well-known/acme-challenge/ {",
                    "location ^~ /.well-known/acme-challenge/ {",
                }:
                    if challenge_body is not None or active_challenge_body is not None:
                        raise InvalidRoute("duplicate challenge location")
                    active_challenge_body = []
                    location_depth = depth + 1
            elif active_challenge_body is not None and depth == location_depth:
                if stripped == "}":
                    challenge_body = active_challenge_body
                    active_challenge_body = None
                    location_depth = None
                elif stripped:
                    active_challenge_body.append(stripped)
            depth += line.count("{") - line.count("}")
        if active_challenge_body is not None:
            raise InvalidRoute("unterminated challenge location")
        port_80_listeners = [line for line in top_level if is_port_80_listener(line)]
        ipv4_listeners = top_level.count("listen 80;")
        ipv6_listeners = top_level.count("listen [::]:80;")
        if challenge_body is None:
            if port_80_listeners:
                raise InvalidRoute("RR site has an unrelated port-80 server")
            continue
        names = [
            line.removeprefix("server_name ").removesuffix(";")
            for line in top_level
            if line.startswith("server_name ") and line.endswith(";")
        ]
        if (
            ipv4_listeners != 1
            or ipv6_listeners != 1
            or len(port_80_listeners) != 2
            or len(names) != 1
            or DOMAIN.fullmatch(names[0]) is None
        ):
            raise InvalidRoute("challenge server has the wrong listen or host")
        allowed_bodies = (
            [f"root {expected_webroot};"],
            [f"root {expected_webroot};", "try_files $uri =404;"],
        )
        if challenge_body not in allowed_bodies:
            raise InvalidRoute("challenge route has the wrong Webroot behavior")
        routes.append(names[0].lower())
    if len(routes) != 1:
        raise InvalidRoute("site does not have one unambiguous challenge route")
    return routes[0]


if DOMAIN.fullmatch(expected_domain) is None:
    raise SystemExit(1)
webroot = exact_absolute_path(webroot_raw)
for required in (
    webroot,
    webroot / ".well-known",
    webroot / ".well-known" / "acme-challenge",
):
    secure_directory_chain(required)
if len(candidate_values) % 2:
    raise SystemExit(1)
seen = set()
route_domains = []
for raw_site, raw_enabled in zip(candidate_values[::2], candidate_values[1::2]):
    site = exact_absolute_path(raw_site)
    enabled = exact_absolute_path(raw_enabled)
    pair = (site, enabled)
    if pair in seen:
        continue
    seen.add(pair)
    text = enabled_site(enabled, site)
    if text is not None:
        route_domains.append(route_from_site(text, str(webroot)))

if expected_domain.lower() not in route_domains:
    raise SystemExit(1)
PY
    then
        return 1
    fi
    local port_80_listeners=""
    nginx -t >/dev/null 2>&1 || return 1
    systemctl is-active --quiet nginx >/dev/null 2>&1 || return 1
    port_80_listeners=$(ss -H -ltn 'sport = :80' 2>/dev/null) || return 1
    grep -q LISTEN <<< "$port_80_listeners" || return 1
    rr_validate_protocol_firewall 80 tcp open || return 1
    rr_certbot_acme_effective_route_probe "$domain" "$webroot"
}

rr_certbot_renewal_runtime_is_ready() {
    # A structurally renewable lineage is not proof that anything will run
    # `certbot renew`, nor that the resulting HTTP-01 challenge can reach its
    # Webroot.  Accept only the bounded local runtime this project can prove:
    # executable Certbot, loaded/enabled/active timer, exact RR Nginx route,
    # active TCP/80 listener and effective read-only firewall policy.  DNS and
    # public Internet reachability are deliberately outside this local proof.
    local domain="${1:-}" certbot_path="" service_load_state=""
    local service_fragment="" service_dropins="" service_user=""
    local dynamic_user="" remain_after_exit=""
    local private_network="" root_directory="" root_image=""
    local protect_system="" read_only_paths="" inaccessible_paths=""
    local bind_paths="" bind_read_only_paths="" temporary_filesystems=""
    local no_exec_paths="" network_namespace_path=""
    local private_users="" restrict_address_families=""
    local restrict_network_interfaces="" restrict_filesystems=""
    local system_call_filter="" mount_images="" extension_images=""
    local extension_directories="" joins_namespace_of="" ip_address_deny=""
    local timer_load_state="" timer_fragment="" timer_dropins=""
    local timer_conditions="" timer_asserts="" timers_calendar=""
    local randomized_delay="" accuracy="" randomized_offset="0"
    local systemd_version=""
    local fragment_state="" fragment_uid="" fragment_gid=""
    local fragment_mode="" fragment_links="" fragment_type=""
    local enabled_state="" triggers="" calendar_tool="" date_tool=""
    local next_realtime="" next_monotonic="" next_value="" compact=""
    local exec_start="" exec_start_pre="" exec_condition=""
    local unit_conditions="" unit_asserts=""
    local next_scheduled=false
    local -a trigger_units=()
    is_valid_domain "$domain" || return 1
    certbot_path=$(command -v certbot 2>/dev/null) || return 1
    [ -f "$certbot_path" ] && [ -x "$certbot_path" ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    systemd_version=$(systemctl --version 2>/dev/null | awk \
        'NR == 1 && $1 == "systemd" && $2 ~ /^[0-9]+$/ { print $2 }') || \
        return 1
    [[ "$systemd_version" =~ ^[0-9]+$ ]] || return 1
    service_load_state=$(systemctl show certbot.service \
        --property=LoadState --value 2>/dev/null) || return 1
    [ "$service_load_state" = loaded ] || return 1
    service_fragment=$(systemctl show certbot.service \
        --property=FragmentPath --value 2>/dev/null) || return 1
    case "$service_fragment" in
        /lib/systemd/system/certbot.service|\
        /usr/lib/systemd/system/certbot.service) ;;
        *) return 1 ;;
    esac
    [ ! -L "$service_fragment" ] || return 1
    fragment_state=$(LC_ALL=C stat -c '%u:%g:%a:%h:%F' -- \
        "$service_fragment" 2>/dev/null) || return 1
    IFS=: read -r fragment_uid fragment_gid fragment_mode fragment_links \
        fragment_type <<<"$fragment_state"
    [ "$fragment_uid:$fragment_gid:$fragment_links:$fragment_type" = \
        '0:0:1:regular file' ] || return 1
    [[ "$fragment_mode" =~ ^[0-7]{3,4}$ ]] && \
        (( (8#$fragment_mode & 8#022) == 0 )) || return 1
    service_dropins=$(systemctl show certbot.service \
        --property=DropInPaths --value 2>/dev/null) || return 1
    [ -z "${service_dropins//[[:space:]]/}" ] || return 1
    exec_start=$(systemctl show certbot.service --property=ExecStart --value \
        2>/dev/null) || return 1
    exec_start_pre=$(systemctl show certbot.service \
        --property=ExecStartPre --value 2>/dev/null) || return 1
    exec_condition=$(systemctl show certbot.service \
        --property=ExecCondition --value 2>/dev/null) || return 1
    unit_conditions=$(systemctl show certbot.service \
        --property=Conditions --value 2>/dev/null) || return 1
    unit_asserts=$(systemctl show certbot.service \
        --property=Asserts --value 2>/dev/null) || return 1
    service_user=$(systemctl show certbot.service --property=User --value \
        2>/dev/null) || return 1
    # An empty User= is systemd's effective default root identity; explicit
    # root is also accepted across the supported distro package variants.
    case "${service_user//[[:space:]]/}" in ""|root) ;; *) return 1 ;; esac
    dynamic_user=$(systemctl show certbot.service \
        --property=DynamicUser --value 2>/dev/null) || return 1
    [ "$dynamic_user" = no ] || return 1
    remain_after_exit=$(systemctl show certbot.service \
        --property=RemainAfterExit --value 2>/dev/null) || return 1
    [ "$remain_after_exit" = no ] || return 1
    private_network=$(systemctl show certbot.service \
        --property=PrivateNetwork --value 2>/dev/null) || return 1
    [ "$private_network" = no ] || return 1
    root_directory=$(systemctl show certbot.service \
        --property=RootDirectory --value 2>/dev/null) || return 1
    [ -z "${root_directory//[[:space:]]/}" ] || return 1
    root_image=$(systemctl show certbot.service --property=RootImage --value \
        2>/dev/null) || return 1
    compact="${root_image//[[:space:]]/}"
    case "${compact,,}" in ""|n/a) ;; *) return 1 ;; esac
    protect_system=$(systemctl show certbot.service \
        --property=ProtectSystem --value 2>/dev/null) || return 1
    [ "$protect_system" = no ] || return 1
    read_only_paths=$(systemctl show certbot.service \
        --property=ReadOnlyPaths --value 2>/dev/null) || return 1
    inaccessible_paths=$(systemctl show certbot.service \
        --property=InaccessiblePaths --value 2>/dev/null) || return 1
    bind_paths=$(systemctl show certbot.service \
        --property=BindPaths --value 2>/dev/null) || return 1
    bind_read_only_paths=$(systemctl show certbot.service \
        --property=BindReadOnlyPaths --value 2>/dev/null) || return 1
    temporary_filesystems=$(systemctl show certbot.service \
        --property=TemporaryFileSystem --value 2>/dev/null) || return 1
    no_exec_paths=$(systemctl show certbot.service \
        --property=NoExecPaths --value 2>/dev/null) || return 1
    network_namespace_path=$(systemctl show certbot.service \
        --property=NetworkNamespacePath --value 2>/dev/null) || return 1
    private_users=$(systemctl show certbot.service \
        --property=PrivateUsers --value 2>/dev/null) || return 1
    [ "$private_users" = no ] || return 1
    restrict_address_families=$(systemctl show certbot.service \
        --property=RestrictAddressFamilies --value 2>/dev/null) || return 1
    if (( systemd_version >= 250 )); then
        restrict_network_interfaces=$(systemctl show certbot.service \
            --property=RestrictNetworkInterfaces --value 2>/dev/null) || \
            return 1
        restrict_filesystems=$(systemctl show certbot.service \
            --property=RestrictFileSystems --value 2>/dev/null) || return 1
    fi
    system_call_filter=$(systemctl show certbot.service \
        --property=SystemCallFilter --value 2>/dev/null) || return 1
    mount_images=$(systemctl show certbot.service \
        --property=MountImages --value 2>/dev/null) || return 1
    extension_images=$(systemctl show certbot.service \
        --property=ExtensionImages --value 2>/dev/null) || return 1
    if (( systemd_version >= 251 )); then
        extension_directories=$(systemctl show certbot.service \
            --property=ExtensionDirectories --value 2>/dev/null) || return 1
    fi
    joins_namespace_of=$(systemctl show certbot.service \
        --property=JoinsNamespaceOf --value 2>/dev/null) || return 1
    ip_address_deny=$(systemctl show certbot.service \
        --property=IPAddressDeny --value 2>/dev/null) || return 1
    [ -z "${exec_start_pre//[[:space:]]/}" ] || return 1
    [ -z "${exec_condition//[[:space:]]/}" ] || return 1
    [ -z "${unit_conditions//[[:space:]]/}" ] || return 1
    [ -z "${unit_asserts//[[:space:]]/}" ] || return 1
    for next_value in "$read_only_paths" "$inaccessible_paths" "$bind_paths" \
        "$bind_read_only_paths" "$temporary_filesystems" "$no_exec_paths" \
        "$network_namespace_path" "$mount_images" "$extension_images" \
        "$extension_directories" "$joins_namespace_of" "$ip_address_deny"; do
        [ -z "${next_value//[[:space:]]/}" ] || return 1
    done
    [ "$restrict_address_families" = '~' ] || return 1
    if (( systemd_version >= 250 )); then
        [ "$restrict_network_interfaces" = '~' ] && \
            [ "$restrict_filesystems" = '~' ] || return 1
    fi
    [ "$system_call_filter" = '~' ] || return 1
    python3 - "$exec_start" "$certbot_path" <<'PY' || return 1
import re
import sys

raw, certbot_path = sys.argv[1:]
records = re.findall(
    r"\{\s*path=(.*?)\s+;\s+argv\[\]=(.*?)\s+;\s+[A-Za-z_][A-Za-z0-9_]*=",
    raw,
)
if (
    len(records) != 1
    or raw.count("{") != 1
    or raw.count("path=") != 1
    or raw.count("argv[]=") != 1
    or raw.count("ignore_errors=") != 1
):
    raise SystemExit(1)
ignore_errors = re.findall(
    r"(?:^|;)\s*ignore_errors=([^;{}\s]+)\s*(?=;|\})", raw
)
if ignore_errors != ["no"]:
    raise SystemExit(1)
exec_path, exec_argv = records[0]
if exec_path != certbot_path:
    raise SystemExit(1)
arguments = exec_argv.split()
if len(arguments) < 2 or arguments[0] != certbot_path:
    raise SystemExit(1)
renew_seen = False
for argument in arguments[1:]:
    if argument == "renew":
        if renew_seen:
            raise SystemExit(1)
        renew_seen = True
    elif argument not in {"-q", "--quiet", "--no-random-sleep-on-renew"}:
        raise SystemExit(1)
if not renew_seen:
    raise SystemExit(1)
PY
    timer_load_state=$(systemctl show certbot.timer --property=LoadState --value \
        2>/dev/null) || return 1
    [ "$timer_load_state" = loaded ] || return 1
    timer_fragment=$(systemctl show certbot.timer \
        --property=FragmentPath --value 2>/dev/null) || return 1
    case "$timer_fragment" in
        /lib/systemd/system/certbot.timer|\
        /usr/lib/systemd/system/certbot.timer) ;;
        *) return 1 ;;
    esac
    [ ! -L "$timer_fragment" ] || return 1
    fragment_state=$(LC_ALL=C stat -c '%u:%g:%a:%h:%F' -- \
        "$timer_fragment" 2>/dev/null) || return 1
    IFS=: read -r fragment_uid fragment_gid fragment_mode fragment_links \
        fragment_type <<<"$fragment_state"
    [ "$fragment_uid:$fragment_gid:$fragment_links:$fragment_type" = \
        '0:0:1:regular file' ] || return 1
    [[ "$fragment_mode" =~ ^[0-7]{3,4}$ ]] && \
        (( (8#$fragment_mode & 8#022) == 0 )) || return 1
    timer_dropins=$(systemctl show certbot.timer \
        --property=DropInPaths --value 2>/dev/null) || return 1
    [ -z "${timer_dropins//[[:space:]]/}" ] || return 1
    timer_conditions=$(systemctl show certbot.timer \
        --property=Conditions --value 2>/dev/null) || return 1
    timer_asserts=$(systemctl show certbot.timer \
        --property=Asserts --value 2>/dev/null) || return 1
    [ -z "${timer_conditions//[[:space:]]/}" ] || return 1
    [ -z "${timer_asserts//[[:space:]]/}" ] || return 1
    triggers=$(systemctl show certbot.timer --property=Triggers --value \
        2>/dev/null) || return 1
    read -r -a trigger_units <<<"$triggers"
    [ "${#trigger_units[@]}" -eq 1 ] && \
        [ "${trigger_units[0]}" = certbot.service ] || return 1
    next_realtime=$(systemctl show certbot.timer \
        --property=NextElapseUSecRealtime --value 2>/dev/null) || return 1
    next_monotonic=$(systemctl show certbot.timer \
        --property=NextElapseUSecMonotonic --value 2>/dev/null) || return 1
    timers_calendar=$(systemctl show certbot.timer \
        --property=TimersCalendar --value 2>/dev/null) || return 1
    randomized_delay=$(systemctl show certbot.timer \
        --property=RandomizedDelayUSec --value 2>/dev/null) || return 1
    accuracy=$(systemctl show certbot.timer \
        --property=AccuracyUSec --value 2>/dev/null) || return 1
    if (( systemd_version >= 258 )); then
        randomized_offset=$(systemctl show certbot.timer \
            --property=RandomizedOffsetUSec --value 2>/dev/null) || return 1
    fi
    [ "${#timers_calendar}" -le 16384 ] && \
        [ "${#next_realtime}" -le 512 ] && \
        [ "${#next_monotonic}" -le 512 ] && \
        [ "${#randomized_delay}" -le 128 ] && \
        [ "${#accuracy}" -le 128 ] && \
        [ "${#randomized_offset}" -le 128 ] || return 1
    calendar_tool=$(command -v systemd-analyze 2>/dev/null) || return 1
    date_tool=$(command -v date 2>/dev/null) || return 1
    [ -f "$calendar_tool" ] && [ -x "$calendar_tool" ] && \
        [ -f "$date_tool" ] && [ -x "$date_tool" ] || return 1
    # TimersCalendar is a structured D-Bus rendering on systemd 249/252/255.
    # Prove at least two bounded future iterations from its effective
    # OnCalendar expression, then independently prove the manager's actual
    # NextElapse timestamp is in the future and no more than seven days away.
    if python3 - "$timers_calendar" "$next_realtime" "$calendar_tool" \
        "$date_tool" "$randomized_delay" "$accuracy" \
        "$randomized_offset" >/dev/null 2>&1 <<'PY'
from decimal import Decimal, InvalidOperation, ROUND_CEILING
import os
import re
import subprocess
import sys
import time

(
    raw_calendar,
    raw_next,
    calendar_tool,
    date_tool,
    randomized_delay,
    accuracy,
    randomized_offset,
) = sys.argv[1:]
MAX_INTERVAL = 7 * 24 * 60 * 60
MAX_INTERVAL_US = MAX_INTERVAL * 1_000_000
# Supported distro Certbot units use an every-day calendar without a weekday
# selector.  Two days is a conservative bound for one such local-calendar
# cycle even across a daylight-saving transition.
MAX_DAILY_BASE_INTERVAL_US = 2 * 24 * 60 * 60 * 1_000_000
now = int(time.time())
environment = dict(os.environ, LC_ALL="C", TZ="UTC")


def to_epoch(value):
    result = subprocess.run(
        [date_tool, "-u", "--date", value, "+%s"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=2,
        check=False,
        env=environment,
    )
    if result.returncode != 0 or not re.fullmatch(r"[0-9]+\n?", result.stdout):
        raise ValueError("unparseable systemd timestamp")
    return int(result.stdout.strip())


def duration_us(raw):
    value = raw.strip().lower()
    if re.fullmatch(r"[0-9]+", value):
        return int(value)
    units = {
        "us": 1,
        "usec": 1,
        "µs": 1,
        "μs": 1,
        "ms": 1_000,
        "msec": 1_000,
        "s": 1_000_000,
        "sec": 1_000_000,
        "secs": 1_000_000,
        "second": 1_000_000,
        "seconds": 1_000_000,
        "min": 60_000_000,
        "mins": 60_000_000,
        "minute": 60_000_000,
        "minutes": 60_000_000,
        "h": 3_600_000_000,
        "hr": 3_600_000_000,
        "hrs": 3_600_000_000,
        "hour": 3_600_000_000,
        "hours": 3_600_000_000,
        "d": 86_400_000_000,
        "day": 86_400_000_000,
        "days": 86_400_000_000,
        "w": 604_800_000_000,
        "week": 604_800_000_000,
        "weeks": 604_800_000_000,
    }
    token = re.compile(
        r"([0-9]+(?:\.[0-9]+)?)\s*"
        r"(usec|msec|seconds?|secs?|sec|minutes?|mins?|min|"
        r"hours?|hrs?|hr|days?|weeks?|week|[µμ]s|us|ms|s|h|d|w)"
    )
    total = Decimal(0)
    position = 0
    for match in token.finditer(value):
        if value[position:match.start()].strip():
            raise ValueError("invalid duration separator")
        try:
            total += Decimal(match.group(1)) * units[match.group(2)]
        except (InvalidOperation, KeyError) as error:
            raise ValueError("invalid duration") from error
        position = match.end()
    if position == 0 or value[position:].strip():
        raise ValueError("invalid duration")
    result = int(total.to_integral_value(rounding=ROUND_CEILING))
    if result < 0 or result > MAX_INTERVAL_US:
        raise ValueError("unbounded duration")
    return result


worst_delay_us = sum(
    duration_us(value) for value in (randomized_delay, accuracy, randomized_offset)
)
if worst_delay_us > MAX_INTERVAL_US:
    raise SystemExit(1)
if MAX_DAILY_BASE_INTERVAL_US + worst_delay_us > MAX_INTERVAL_US:
    raise SystemExit(1)
next_epoch = to_epoch(raw_next.strip())
if not now < next_epoch <= now + MAX_INTERVAL:
    raise SystemExit(1)

calendar_specs = re.findall(
    r"\{\s*OnCalendar=(.*?)\s*;\s*next_elapse=.*?\}",
    raw_calendar,
)
if not calendar_specs:
    compact_calendar = raw_calendar.strip()
    if compact_calendar and not any(char in compact_calendar for char in "{};\n"):
        calendar_specs = [compact_calendar]
if not calendar_specs or len(calendar_specs) > 8:
    raise SystemExit(1)

stamp = r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC"
for spec in calendar_specs:
    if not spec.strip() or len(spec) > 1024 or "\x00" in spec:
        continue
    result = subprocess.run(
        [
            calendar_tool,
            "calendar",
            f"--base-time=@{now}",
            "--iterations=2",
            spec.strip(),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=3,
        check=False,
        env=environment,
    )
    if result.returncode != 0:
        continue
    normalized_match = re.search(r"^Normalized form:\s+(.+?)\s*$", result.stdout, re.M)
    if normalized_match is None or re.fullmatch(
        r"\*-\*-\* [0-9*~,/.:+-]+", normalized_match.group(1)
    ) is None:
        continue
    first_match = re.search(rf"^\s*Next elapse:\s+({stamp})\s*$", result.stdout, re.M)
    second_match = re.search(
        rf"^\s*Iteration #2:\s+({stamp})\s*$", result.stdout, re.M
    )
    if first_match is None or second_match is None:
        continue
    first = to_epoch(first_match.group(1))
    second = to_epoch(second_match.group(1))
    if (
        now < first
        and (first - now) * 1_000_000 <= MAX_DAILY_BASE_INTERVAL_US
        and first < second
        and (second - first) * 1_000_000 <= MAX_DAILY_BASE_INTERVAL_US
    ):
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
        next_scheduled=true
    fi
    [ "$next_scheduled" = true ] || return 1
    enabled_state=$(systemctl is-enabled certbot.timer 2>/dev/null) || return 1
    case "$enabled_state" in enabled|enabled-runtime) ;; *) return 1 ;; esac
    systemctl is-active --quiet certbot.timer >/dev/null 2>&1 || return 1
    rr_certbot_acme_http_route_is_ready "$domain"
}

rr_enable_certbot_renewal_runtime() {
    local domain="${1:-}"
    is_valid_domain "$domain" || return 1
    command -v certbot >/dev/null 2>&1 || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    # Do not mutate timer state when the domain's local renewal route is
    # already known to be unusable.
    rr_certbot_acme_http_route_is_ready "$domain" || return 1
    systemctl enable --now certbot.timer >/dev/null 2>&1 || return 1
    rr_certbot_renewal_runtime_is_ready "$domain"
}

rr_install_certificate_deploy_hook() {
    local hook_dir="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local hook_source="${RR_RUNTIME_DIR:-/usr/local/lib/rr}/scripts/naive-cert-hook.sh"
    local hook_file="${hook_dir}/rr-certificates.sh"
    [ -s "$hook_source" ] && bash -n "$hook_source" || return 1
    [ ! -L "$hook_dir" ] || return 1
    install -d -o root -g root -m 700 "$hook_dir" || return 1
    install -o root -g root -m 700 "$hook_source" "$hook_file" || return 1
    rm -f "${hook_dir}/rr-naive-cert.sh" || return 1
    declare -F rr_certificate_deploy_hook_is_current >/dev/null 2>&1 || return 1
    rr_certificate_deploy_hook_is_current
}

deploy_subscription_cert_hook() {
    [ "${SUB_ACCESS_MODE:-local}" = https ] || return 0
    is_valid_domain "${SUB_DOMAIN:-}" || return 1
    rr_install_certificate_deploy_hook
}

start_subscription_server() {
    local sub_server_app="${RR_LIB_DIR}/nexus/sub_server.py"
    local server_signature=""
    local access_mode="${SUB_ACCESS_MODE:-local}"
    local cert_file="" key_file="" cert_signature="local-http"
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
    local -a tls_args=()
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝启动订阅入站。${RESET}" >&2
        return 1
    fi
    [ -s "$sub_server_app" ] || {
        echo -e "${RED}[安全拒绝] 订阅服务程序缺失，拒绝回退到无保护的通用 HTTP 服务。${RESET}" >&2
        return 1
    }
    is_valid_port "${SUB_PORT:-}" || return 1
    server_signature=$(sha256sum "$sub_server_app" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$server_signature" =~ ^[a-f0-9]{64}$ ]] || return 1

    case "$access_mode" in
        local)
            SUB_BIND_ADDRESS="127.0.0.1"
            SUB_DOMAIN=""
            ;;
        https)
            is_valid_domain "${SUB_DOMAIN:-}" || {
                echo -e "${RED}[安全拒绝] 公网订阅缺少有效可信域名。${RESET}" >&2
                return 1
            }
            case "${SUB_BIND_ADDRESS:-}" in
                0.0.0.0|::) ;;
                *)
                    echo -e "${RED}[安全拒绝] 公网订阅监听地址无效。${RESET}" >&2
                    return 1
                    ;;
            esac
            cert_file="${le_live_root}/${SUB_DOMAIN}/fullchain.pem"
            key_file="${le_live_root}/${SUB_DOMAIN}/privkey.pem"
            subscription_certificate_pair_valid "$cert_file" "$key_file" "$SUB_DOMAIN" || {
                echo -e "${RED}[安全拒绝] 订阅 HTTPS 证书缺失、即将过期、域名不符、私钥不匹配或不受信任。${RESET}" >&2
                return 1
            }
            declare -F rr_certbot_webroot_lineage_is_renewable \
                >/dev/null 2>&1 || return 1
            rr_certbot_webroot_lineage_is_renewable "$SUB_DOMAIN" || {
                echo -e "${RED}[安全拒绝] 订阅 HTTPS 证书不是结构完整的生产 Webroot lineage。${RESET}" >&2
                return 1
            }
            declare -F rr_certbot_renewal_runtime_is_ready \
                >/dev/null 2>&1 || return 1
            rr_certbot_renewal_runtime_is_ready "$SUB_DOMAIN" || {
                echo -e "${RED}[安全拒绝] Certbot 定时器或 ${SUB_DOMAIN} 的本机 ACME HTTP 路由未就绪。${RESET}" >&2
                return 1
            }
            cert_signature=$(sha256sum "$cert_file" 2>/dev/null | awk '{print $1}') || return 1
            [[ "$cert_signature" =~ ^[a-f0-9]{64}$ ]] || return 1
            tls_args=(--certfile "$cert_file" --keyfile "$key_file")
            if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] && \
               [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then
                # Portable restore preserves the destination access plane and
                # may only read global ACME state during the rollback-capable
                # candidate phase.  The preflight already required this exact
                # hook; repeat the check at use time to close replacement races.
                declare -F rr_certificate_deploy_hook_is_current \
                    >/dev/null 2>&1 || return 1
                rr_certificate_deploy_hook_is_current || return 1
            else
                deploy_subscription_cert_hook || return 1
            fi
            ;;
        *)
            echo -e "${RED}[安全拒绝] 未知订阅访问模式。${RESET}" >&2
            return 1
            ;;
    esac
    # 订阅服务是常驻 Python 进程。仅比较端口/监听地址会导致热更新虽然
    # 替换了 sub_server.py，旧进程却继续返回旧正文。把程序哈希写入状态，
    # 文件内容一变就安全重启；端口和代码都没变时仍保持无扰动幂等。
    local desired_state="${SUB_PORT}|${SUB_BIND_ADDRESS}|${access_mode}|${SUB_DOMAIN:-}|${server_signature}|${cert_signature}"
    local current_state=""
    local old_pid=""
    local used_legacy_pid=false

    ensure_subscription_root || return 1

    [ -f "$SUB_BIND_STATE_FILE" ] && current_state=$(cat "$SUB_BIND_STATE_FILE" 2>/dev/null)
    [ -f "$SUB_PID_FILE" ] && old_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    # 从 7.1.0 及更早版本热更新时接管旧 /tmp PID；身份核验仍由
    # is_subscription_pid 完成，伪造数字不会导致误杀其他进程。
    if [ -z "$old_pid" ] && [ -f /tmp/sub_server.pid ]; then
        old_pid=$(cat /tmp/sub_server.pid 2>/dev/null)
        [ -f /tmp/sub_server.bind ] && current_state=$(cat /tmp/sub_server.bind 2>/dev/null)
        used_legacy_pid=true
    fi

    if is_subscription_pid "$old_pid" && [ "$current_state" = "$desired_state" ]; then
        if [ "$used_legacy_pid" = true ]; then
            printf '%s\n' "$old_pid" > "$SUB_PID_FILE" || return 1
            printf '%s\n' "$current_state" > "$SUB_BIND_STATE_FILE" || return 1
            rm -f /tmp/sub_server.pid /tmp/sub_server.bind
        fi
        return 0
    fi

    if is_subscription_pid "$old_pid"; then
        kill "$old_pid" 2>/dev/null
        sleep 1
    fi

    rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE" /tmp/sub_server.pid /tmp/sub_server.bind

    (
        cd "$SUB_ROOT" || exit 1
        rr_close_inherited_firewall_lock_fd || exit 1
        nohup python3 "$sub_server_app" "$SUB_PORT" --bind "$SUB_BIND_ADDRESS" \
            --directory "$SUB_ROOT" "${tls_args[@]}" >/dev/null 2>&1 &
        echo $! > "$SUB_PID_FILE"
    ) || return 1
    sleep 1
    old_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    if ! is_subscription_pid "$old_pid"; then
        rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE"
        echo -e "${RED}[错误] 订阅服务启动失败（监听 ${SUB_BIND_ADDRESS}:${SUB_PORT}）。${RESET}" >&2
        return 1
    fi
    (umask 077; printf '%s\n' "$desired_state" > "$SUB_BIND_STATE_FILE") || return 1
}
