# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 2. 基础依赖与防火墙穿透
# ==========================================
check_supported_os() {
    if [ ! -r "$OS_RELEASE_FILE" ]; then
        echo -e "${RED}[不支持] 无法识别当前操作系统。${RESET}"
        return 1
    fi

    local os_id=""
    local os_name=""
    local os_version=""
    os_id=$(awk -F= '$1 == "ID" {gsub(/\"/, "", $2); print tolower($2); exit}' "$OS_RELEASE_FILE")
    os_name=$(awk -F= '$1 == "PRETTY_NAME" {sub(/^[^=]*=/, ""); gsub(/^\"|\"$/, ""); print; exit}' "$OS_RELEASE_FILE")
    os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/\"/, "", $2); print $2; exit}' "$OS_RELEASE_FILE")

    case "$os_id" in
        ubuntu)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "${os_version:-0}" lt "22.04"; then
                echo -e "${RED}[不支持] Ubuntu ${os_version:-未知} 版本过旧；最低支持 Ubuntu 22.04。${RESET}"
                return 1
            fi
            ;;
        debian)
            if command -v dpkg >/dev/null 2>&1 && dpkg --compare-versions "${os_version:-0}" lt "12"; then
                echo -e "${RED}[不支持] Debian ${os_version:-未知} 版本过旧；最低支持 Debian 12。${RESET}"
                return 1
            fi
            ;;
        *)
            echo -e "${RED}[不支持] 当前系统：${os_name:-未知系统}。${RESET}"
            echo -e "${YELLOW}本脚本仅支持 Ubuntu（含 24.04）和 Debian；请勿选择 Alpine。${RESET}"
            return 1
            ;;
    esac

    if ! command -v apt-get >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
        echo -e "${RED}[不支持] 当前系统缺少 apt-get 或 systemd。${RESET}"
        return 1
    fi
    echo -e "${GREEN}[系统] ${os_name:-$os_id $os_version} 已通过兼容性检查。${RESET}"
}

install_deps() {
    echo -e "\n${YELLOW}正在更新系统源并安装必要组件 ...${RESET}"
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections 2>/dev/null
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections 2>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
        ca-certificates curl wget jq python3 openssl iproute2 qrencode dnsutils cron \
        iptables iptables-persistent procps tar gzip coreutils util-linux || return 1

    if ! command -v vnstat &> /dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y vnstat || return 1
        systemctl enable vnstat >/dev/null 2>&1
        systemctl start vnstat >/dev/null 2>&1
    fi

    echo -e "\n${YELLOW}正在优化网络，开启 BBR ...${RESET}"
    command -v modprobe >/dev/null 2>&1 && modprobe tcp_bbr >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
        local bbr_config_written=true
        if [ ! -f /etc/sysctl.d/99-argo-rr.conf ] || \
           ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.d/99-argo-rr.conf 2>/dev/null; then
            if ! printf '%s\n' 'net.core.default_qdisc=fq' 'net.ipv4.tcp_congestion_control=bbr' \
                > /etc/sysctl.d/99-argo-rr.conf; then
                bbr_config_written=false
            fi
        fi
        [ "$bbr_config_written" = true ] && sysctl --system >/dev/null 2>&1 || true
        if [ "$bbr_config_written" = true ] && \
           [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
            echo -e "${GREEN}[成功] BBR 网络加速已激活！${RESET}"
        else
            echo -e "${YELLOW}[提示] 内核支持 BBR，但当前容器不允许修改 sysctl，已安全跳过。${RESET}"
        fi
    else
        echo -e "${YELLOW}[提示] 当前内核/容器未提供 BBR，已跳过，不影响节点使用。${RESET}"
    fi
}

install_cloudflared() {
    command -v cloudflared >/dev/null 2>&1 && return 0

    echo -e "${YELLOW}仅因已选择 Argo，正在下载并安装 Cloudflared ($SYS_ARCH)...${RESET}"
    local cf_tmp_dir=""
    cf_tmp_dir=$(mktemp -d /tmp/rr-cloudflared.XXXXXX) || return 1
    if ! curl -fL --retry 3 --connect-timeout 10 --max-time 120 --output "$cf_tmp_dir/cloudflared.deb" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${SYS_ARCH}.deb"; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 下载失败。${RESET}"
        return 1
    fi
    if ! dpkg -i "$cf_tmp_dir/cloudflared.deb" >/dev/null 2>&1; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 安装失败。${RESET}"
        return 1
    fi
    rm -rf "$cf_tmp_dir"
}

open_firewall() {
    # Argo 模式只监听 127.0.0.1，不占用公网防火墙端口；TLS 直连时才放行。
    if [ "${VM_TLS_ENABLED:-false}" = "true" ]; then
        open_protocol_firewall "$PORT" "tcp"
    fi
    open_protocol_firewall "$SUB_PORT" "tcp"
}

open_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    if command -v ufw &> /dev/null; then
        ufw allow "$proto_port/$proto_type" comment "$FIREWALL_COMMENT" >/dev/null 2>&1 || true
    fi
    if command -v iptables &> /dev/null; then
        iptables -C INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 || \
            iptables -I INPUT -p "$proto_type" --dport "$proto_port" \
                -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT 2>/dev/null || true
    fi
    if command -v ip6tables &> /dev/null; then
        ip6tables -C INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 || \
            ip6tables -I INPUT -p "$proto_type" --dport "$proto_port" \
                -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT 2>/dev/null || true
    fi
    if command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1; then
        save_firewall
    fi
}

close_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 0
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac

    if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "$proto_port/$proto_type" comment "$FIREWALL_COMMENT" >/dev/null 2>&1 || true
    fi
    while command -v iptables >/dev/null 2>&1 && \
          iptables -C INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1; do
        iptables -D INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
    done
    while command -v ip6tables >/dev/null 2>&1 && \
          ip6tables -C INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1; do
        ip6tables -D INPUT -p "$proto_type" --dport "$proto_port" \
            -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 || break
    done
    save_firewall
}

save_firewall() {
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
    if command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; then
        service iptables save >/dev/null 2>&1 || true
    fi
}

# ==========================================
# 安全 sed 替换函数
# ==========================================
safe_sed() {
    local key="$1"
    local value="$2"
    local encoded_value=""
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
    printf -v encoded_value '%q' "$value"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${encoded_value}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$encoded_value" >> "$CONFIG_FILE"
    fi
}

is_valid_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

is_cloudflare_tls_port() {
    case "${1:-}" in
        443|2053|2083|2087|2096|8443) return 0 ;;
        *) return 1 ;;
    esac
}

tcp_port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltn 2>/dev/null | awk -v suffix=":${port}" '
        {
            endpoint=$4
            if (length(endpoint) >= length(suffix) &&
                substr(endpoint, length(endpoint) - length(suffix) + 1) == suffix) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

udp_port_in_use() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -lun 2>/dev/null | awk -v suffix=":${port}" '
        {
            # ss -H -lun: Local Address:Port is column 4; column 5 is peer address.
            endpoint=$4
            if (length(endpoint) >= length(suffix) &&
                substr(endpoint, length(endpoint) - length(suffix) + 1) == suffix) {
                found=1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

is_valid_hop_spec() {
    local spec="${1:-}"
    local item=""
    local start=""
    local end=""
    local -a hop_items=()
    [ -z "$spec" ] && return 0
    IFS=',' read -r -a hop_items <<< "$spec"
    for item in "${hop_items[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            is_valid_port "$start" && is_valid_port "$end" && \
                (( 10#$start >= 1000 && 10#$end <= 65535 && 10#$start < 10#$end )) || return 1
        elif is_valid_port "$item" && (( 10#$item >= 1000 )); then
            :
        else
            return 1
        fi
    done
}

hop_spec_contains_port() {
    local spec_list="$1"
    local port="$2"
    local item=""
    local start=""
    local end=""
    local -a hop_items=()
    is_valid_hop_spec "$spec_list" || return 1
    is_valid_port "$port" || return 1
    IFS=',' read -r -a hop_items <<< "$spec_list"
    for item in "${hop_items[@]}"; do
        if [[ "$item" =~ ^([0-9]+):([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if (( 10#$port >= 10#$start && 10#$port <= 10#$end )); then
                return 0
            fi
        elif [ "$item" = "$port" ]; then
            return 0
        fi
    done
    return 1
}

validate_hop_spec_availability() {
    local spec_list="$1"
    local main_port="$2"
    local used_port=""
    [ -z "$spec_list" ] && return 0
    is_valid_hop_spec "$spec_list" || return 1

    if [ "${TU5_ENABLED:-false}" = "true" ] && is_valid_port "${TU5_PORT:-0}" && \
       [ "$TU5_PORT" != "$main_port" ] && hop_spec_contains_port "$spec_list" "$TU5_PORT"; then
        echo -e "${RED}[拒绝变更] 跳跃范围包含 Tuic5 正在使用的 UDP 端口 ${TU5_PORT}。${RESET}" >&2
        return 1
    fi

    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r used_port; do
            is_valid_port "$used_port" || continue
            [ "$used_port" = "$main_port" ] && continue
            if hop_spec_contains_port "$spec_list" "$used_port"; then
                echo -e "${RED}[拒绝变更] 跳跃范围包含已被其他服务监听的 UDP 端口 ${used_port}。${RESET}" >&2
                return 1
            fi
        done < <(ss -H -lun 2>/dev/null | awk '{endpoint=$4; sub(/^.*:/, "", endpoint); if (endpoint ~ /^[0-9]+$/) print endpoint}' | sort -nu)
    fi
    return 0
}

is_valid_hop_interval() {
    local interval="${1:-}"
    local amount=""
    local unit=""
    [[ "$interval" =~ ^([1-9][0-9]*)(ms|s|m|h)$ ]] || return 1
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    # 避免超长数字触发 Bash 整数溢出；官方 Hysteria2 建议至少 5 秒。
    [ "${#amount}" -le 8 ] || return 1
    case "$unit" in
        ms) (( 10#$amount >= 5000 && 10#$amount <= 86400000 )) ;;
        s)  (( 10#$amount >= 5 && 10#$amount <= 86400 )) ;;
        m)  (( 10#$amount >= 1 && 10#$amount <= 1440 )) ;;
        h)  (( 10#$amount >= 1 && 10#$amount <= 24 )) ;;
        *) return 1 ;;
    esac
}

duration_to_seconds() {
    local interval="${1:-}"
    local amount=""
    local unit=""
    is_valid_hop_interval "$interval" || return 1
    [[ "$interval" =~ ^([1-9][0-9]*)(ms|s|m|h)$ ]] || return 1
    amount="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    case "$unit" in
        ms) echo $(( (10#$amount + 999) / 1000 )) ;;
        s) echo $(( 10#$amount )) ;;
        m) echo $(( 10#$amount * 60 )) ;;
        h) echo $(( 10#$amount * 3600 )) ;;
    esac
}

is_subscription_pid() {
    local pid="${1:-}"
    local cmdline=""
    local process_cwd=""
    local expected_cwd=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 必须核对进程身份，绝不因陈旧 PID 文件误杀其他服务。
    [ -r "/proc/${pid}/cmdline" ] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
    [[ "$cmdline" == *"python3 -m http.server"* ]] || return 1
    process_cwd=$(readlink -f "/proc/${pid}/cwd" 2>/dev/null) || return 1
    expected_cwd=$(readlink -f "$SUB_ROOT" 2>/dev/null) || return 1
    [ "$process_cwd" = "$expected_cwd" ]
}

# ==========================================
# IPv4 / IPv6 模式与兼容性辅助函数


# ==========================================
# 面板防火墙辅助（rr --fw-* 子命令，端口白名单内操作）
# ==========================================
nexus_fw_known_ports() {
    # 输出白名单端口清单："port:proto:name" 每行
    load_config_with_defaults || return 1
    [ "$VL_ENABLED" = "true" ] && [ "$VL_PORT" != "0" ] && echo "${VL_PORT}:tcp:VLESS-Reality 节点"
    [ "$HY2_ENABLED" = "true" ] && [ "$HY2_PORT" != "0" ] && echo "${HY2_PORT}:udp:Hysteria2 节点"
    [ "$TU5_ENABLED" = "true" ] && [ "$TU5_PORT" != "0" ] && echo "${TU5_PORT}:udp:Tuic5 节点"
    [ "$AN_ENABLED" = "true" ] && [ "$AN_PORT" != "0" ] && echo "${AN_PORT}:tcp:AnyTLS 节点"
    # NAIVE-SUPPORT
    [ "$NAIVE_ENABLED" = "true" ] && [ "${NAIVE_PORT:-0}" != "0" ] && echo "${NAIVE_PORT}:tcp:NaiveProxy 节点"
    [ "$VM_ENABLED" = "true" ] && [ "$VM_TLS_ENABLED" = "true" ] && [ "$PORT" != "0" ] && echo "${PORT}:tcp:VMess-TLS 直连节点"
    [ "${SUB_PORT:-0}" != "0" ] && echo "${SUB_PORT}:tcp:订阅服务"
    [ -n "${SSH_PORT:-22}" ] && echo "${SSH_PORT}:tcp:SSH 管理端口（保护）"
    if [ -f /etc/rr-nexus/nexus.json ]; then
        local panel_port=""
        panel_port=$(jq -r '.public_port // .port // empty' /etc/rr-nexus/nexus.json 2>/dev/null)
        [ -n "$panel_port" ] && [ "$panel_port" != "null" ] && echo "${panel_port}:tcp:RR Nexus 面板"
    fi
    return 0
}

nexus_fw_port_open() {
    # $1=port $2=proto；0=开 1=关
    iptables -C INPUT -p "$2" --dport "$1" -m comment --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1
}

nexus_fw_ports_json() {
    # 输出 JSON：白名单端口 + 状态
    local line="" port="" proto="" name="" open="0"
    local first=true
    printf '['
    while IFS=: read -r port proto name; do
        [ -n "$port" ] || continue
        nexus_fw_port_open "$port" "$proto" && open="1" || open="0"
        [ "$first" = true ] && first=false || printf ','
        printf '{"port":%s,"proto":"%s","name":"%s","open":%s}' "$port" "$proto" "$name" "$open"
    done < <(nexus_fw_known_ports)
    printf ']
'
}

nexus_fw_toggle() {
    # $1=port $2=proto；只允许白名单内端口；SSH 端口受保护不可关
    local port="$1" proto="$2"
    is_valid_port "$port" || { echo '{"ok":false,"error":"invalid_port"}'; return 1; }
    if [ "$port" = "${SSH_PORT:-22}" ] && [ "$proto" = "tcp" ]; then
        echo '{"ok":false,"error":"ssh_port_protected"}'
        return 1
    fi
    case "$proto" in tcp|udp) ;; *) echo '{"ok":false,"error":"invalid_proto"}'; return 1; ;; esac
    local line="" p="" pr="" n=""
    local allowed=false
    while IFS=: read -r p pr n; do
        [ "$p" = "$port" ] && [ "$pr" = "$proto" ] && allowed=true
    done < <(nexus_fw_known_ports)
    [ "$allowed" = true ] || { echo '{"ok":false,"error":"not_allowed_port"}'; return 1; }
    if nexus_fw_port_open "$port" "$proto"; then
        close_protocol_firewall "$port" "$proto"
        echo "{\"ok\":true,\"action\":\"closed\",\"port\":$port,\"proto\":\"$proto\"}"
    else
        open_protocol_firewall "$port" "$proto"
        echo "{\"ok\":true,\"action\":\"opened\",\"port\":$port,\"proto\":\"$proto\"}"
    fi
    return 0
}

nexus_ver_info_json() {
    # 面板版本信息：脚本版本 + 内核版本 + 面板状态 + 出入站模式
    local sb_ver="" panel_state="未安装" panel_mode=""
    load_config_with_defaults || true
    [ -x "$SINGBOX_BIN" ] && sb_ver=$(get_singbox_version 2>/dev/null || echo "")
    if [ -f /etc/rr-nexus/nexus.json ]; then
        panel_state="已安装"
        panel_mode=$(jq -r '.mode // "unknown"' /etc/rr-nexus/nexus.json 2>/dev/null)
    fi
    printf '{"script_version":"%s","core_version":"%s","panel_state":"%s","panel_mode":"%s","entry_ip_mode":"%s","outbound_ip_mode":"%s"}' \
        "${SCRIPT_VERSION:-unknown}" "${sb_ver:-未知}" "$panel_state" "$panel_mode" \
        "${ENTRY_IP_MODE:-auto}" "${OUTBOUND_IP_MODE:-auto}"
}
