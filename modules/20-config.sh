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
    "VM_PREVIOUS_PORT", "VM_ENABLED", "VL_ENABLED", "VL_PORT", "HY2_ENABLED", "HY2_PORT",
    "HY2_HOP_PORTS", "HY2_HOP_INTERVAL", "TU5_ENABLED", "TU5_PORT", "TU5_HOP_PORTS",
    "AN_ENABLED", "AN_PORT", "NAIVE_ENABLED", "NAIVE_PORT", "NAIVE_USER", "NAIVE_PASS", "NAIVE_DOMAIN", "CLASH_ENABLED", "SINGBOX_AUTO_RESTART", "CONFIG_VERSION",
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
            VM_TLS_ENABLED|VM_PREVIOUS_PORT|VM_ENABLED|VL_ENABLED|VL_PORT|\
            HY2_ENABLED|HY2_PORT|HY2_HOP_PORTS|HY2_HOP_INTERVAL|\
            TU5_ENABLED|TU5_PORT|TU5_HOP_PORTS|AN_ENABLED|AN_PORT|\
            NAIVE_ENABLED|NAIVE_PORT|NAIVE_USER|NAIVE_PASS|NAIVE_DOMAIN|\
            CLASH_ENABLED|SINGBOX_AUTO_RESTART|CONFIG_VERSION|PRIVATE_KEY|\
            PUBLIC_KEY|SHORT_ID|CERT_SHA256|INSTALL_COMPLETE|HB_ENABLED|HB_INTERVAL)
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
    # NAIVE-SUPPORT：NaiveProxy（HTTP/2+padding 伪装，需真证书）
    NAIVE_ENABLED="${NAIVE_ENABLED:-false}"
    NAIVE_PORT="${NAIVE_PORT:-443}"
    NAIVE_USER="${NAIVE_USER:-}"
    NAIVE_PASS="${NAIVE_PASS:-}"
    NAIVE_DOMAIN="${NAIVE_DOMAIN:-}"
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
    case "$HB_ENABLED" in true|false) ;; *) HB_ENABLED=false ;; esac
    case "$INSTALL_COMPLETE" in true|false) ;; *) INSTALL_COMPLETE=false ;; esac
    [ "$config_read_ok" = true ]
}

any_node_protocol_enabled() {
    [ "${VM_ENABLED:-false}" != "false" ] || \
    [ "${VL_ENABLED:-false}" = "true" ] || \
    [ "${HY2_ENABLED:-false}" = "true" ] || \
    [ "${TU5_ENABLED:-false}" = "true" ] || \
    [ "${AN_ENABLED:-false}" = "true" ]
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

# 凭据完整性保障：检测到掩码/空值/非法格式时重新生成真实凭据并回写配置，
# 保证掩码永不进入 sing-box 配置或订阅。仅在检测到问题时写入，幂等。
# Reality 密钥的重新生成由 30-singbox.sh 的 rotate_reality_keypair 承担
# （需要 sing-box 二进制），此处按需调用。
ensure_credential_integrity() {
    local changed=false
    local new_uuid=""

    # UUID：主凭据（vmess/vless/hy2/tuic/anytls 共用）
    if [ -z "${UUID:-}" ] || is_masked_credential "$UUID" || ! is_valid_uuid "$UUID"; then
        new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
        is_valid_uuid "$new_uuid" || new_uuid=""
        if [ -n "$new_uuid" ]; then
            UUID="$new_uuid"
            [ -f "$CONFIG_FILE" ] && safe_sed "UUID" "$UUID" || true
            changed=true
        fi
    fi
    # NaiveProxy 凭据（用户名/密码，仅 NAIVE_ENABLED 时参与配置生成）
    if [ "${NAIVE_ENABLED:-false}" = "true" ]; then
        if [ -z "${NAIVE_USER:-}" ] || is_masked_credential "$NAIVE_USER"; then
            NAIVE_USER="np_$(head -c 8 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' | head -c 8)"
            [ -f "$CONFIG_FILE" ] && safe_sed "NAIVE_USER" "$NAIVE_USER" || true
            changed=true
        fi
        if [ -z "${NAIVE_PASS:-}" ] || is_masked_credential "$NAIVE_PASS"; then
            NAIVE_PASS="$(head -c 24 /dev/urandom 2>/dev/null | base64 2>/dev/null | tr -d '\n/+= ' | head -c 20)"
            [ -f "$CONFIG_FILE" ] && safe_sed "NAIVE_PASS" "$NAIVE_PASS" || true
            changed=true
        fi
    else
        # 未启用 NaiveProxy：清空遗留掩码凭据（不生成真值），保持配置文件终态干净
        if is_masked_credential "${NAIVE_USER:-}"; then
            NAIVE_USER=""
            [ -f "$CONFIG_FILE" ] && safe_sed "NAIVE_USER" "" || true
            changed=true
        fi
        if is_masked_credential "${NAIVE_PASS:-}"; then
            NAIVE_PASS=""
            [ -f "$CONFIG_FILE" ] && safe_sed "NAIVE_PASS" "" || true
            changed=true
        fi
    fi
    # Reality 密钥材料：掩码一律强制重生成（现有客户端不可能持有掩码密钥）
    if is_masked_credential "${PRIVATE_KEY:-}" || is_masked_credential "${PUBLIC_KEY:-}" || \
       is_masked_credential "${SHORT_ID:-}"; then
        if declare -F rotate_reality_keypair >/dev/null 2>&1; then
            if rotate_reality_keypair; then
                changed=true
            else
                # 降级（R1）：迁移路径不允许因密钥轮换失败（内核缺失/损坏）卡死整体更新
                PRIVATE_KEY=""; PUBLIC_KEY=""; SHORT_ID=""
                if [ -f "$CONFIG_FILE" ]; then
                    safe_sed "PRIVATE_KEY" "" || true; safe_sed "PUBLIC_KEY" "" || true; safe_sed "SHORT_ID" "" || true
                fi
                echo -e "${YELLOW}[警告] Reality 密钥轮换失败（内核不可用？），已清空密钥材料；VLESS-Reality 暂不可用，稍后可通过菜单重新生成。${RESET}" >&2
            fi
        fi
    fi
    # 证书 pin 是派生数据（由证书重新计算），掩码时清空即可，后续流程会自动重算/降级。
    if is_masked_credential "${CERT_SHA256:-}"; then
        CERT_SHA256=""
        [ -f "$CONFIG_FILE" ] && safe_sed "CERT_SHA256" "" || true
        changed=true
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

start_subscription_server() {
    local sub_server_app="${RR_LIB_DIR}/nexus/sub_server.py"
    local desired_state="${SUB_PORT}|${SUB_BIND_ADDRESS}|userinfo-v1"
    local current_state=""
    local old_pid=""

    [ -f "$SUB_BIND_STATE_FILE" ] && current_state=$(cat "$SUB_BIND_STATE_FILE" 2>/dev/null)
    [ -f "$SUB_PID_FILE" ] && old_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)

    if is_subscription_pid "$old_pid" && [ "$current_state" = "$desired_state" ]; then
        return 0
    fi

    if is_subscription_pid "$old_pid"; then
        kill "$old_pid" 2>/dev/null
        sleep 1
    fi

    rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE"

    mkdir -p "$SUB_ROOT"
    (
        cd "$SUB_ROOT" || exit 1
        if [ -s "$sub_server_app" ]; then
            nohup python3 "$sub_server_app" "$SUB_PORT" --bind "$SUB_BIND_ADDRESS" \
                --directory "$SUB_ROOT" >/dev/null 2>&1 &
        else
            nohup python3 -m http.server "$SUB_PORT" --bind "$SUB_BIND_ADDRESS" >/dev/null 2>&1 &
        fi
        echo $! > "$SUB_PID_FILE"
    ) || return 1
    sleep 1
    old_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    if ! is_subscription_pid "$old_pid"; then
        rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE"
        echo -e "${RED}[错误] 订阅服务启动失败（监听 ${SUB_BIND_ADDRESS}:${SUB_PORT}）。${RESET}" >&2
        return 1
    fi
    echo "$desired_state" > "$SUB_BIND_STATE_FILE"
}
