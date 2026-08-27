# shellcheck shell=bash
# RR Nexus 可选管理面板、多用户凭据与独立订阅。

NEXUS_CONFIG_FILE="/etc/rr-nexus/nexus.json"
NEXUS_DATA_DIR="/var/lib/rr-nexus"
NEXUS_DB_FILE="${NEXUS_DATA_DIR}/nexus.db"
NEXUS_SUB_ROOT="${NEXUS_DATA_DIR}/subscriptions"
NEXUS_SERVICE_FILE="/etc/systemd/system/rr-nexus.service"
NEXUS_NGINX_SITE="/etc/nginx/sites-available/rr-nexus.conf"
NEXUS_APP="${RR_LIB_DIR}/nexus/rr_nexus.py"
NEXUS_CORE_UPSTREAM_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
NEXUS_CORE_RELEASE_API="https://api.github.com/repos/${RR_REPOSITORY}/releases/tags"

nexus_is_installed() {
    [ -f "$NEXUS_CONFIG_FILE" ] && [ -f "$NEXUS_SERVICE_FILE" ] && [ -f "$NEXUS_APP" ]
}

nexus_mode() {
    [ -r "$NEXUS_CONFIG_FILE" ] || { echo "未安装"; return; }
    jq -r '.mode // "未知"' "$NEXUS_CONFIG_FILE" 2>/dev/null || echo "异常"
}

nexus_panel_url() {
    # 输出面板管理地址（供主菜单/安装结果展示）；未安装或异常时输出空
    [ -r "$NEXUS_CONFIG_FILE" ] || return 1
    local mode=""
    local domain=""
    local public_port=""
    local ssh_host=""
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    public_port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    ssh_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    if [ "$mode" = "local" ]; then
        printf 'http://127.0.0.1:%s（SSH 隧道）' "${public_port:-7900}"
        return 0
    fi
    [ "$mode" = "public" ] || return 1
    # 域名模式（真证书）；IP 直连（自签证书）
    if [ -n "$domain" ] && [ "$domain" != "ip" ] && ! printf '%s' "$domain" | grep -qE '^[0-9.]+$'; then
        if [ "${public_port:-443}" = "443" ]; then
            printf 'https://%s' "$domain"
        else
            printf 'https://%s:%s' "$domain" "${public_port:-443}"
        fi
    else
        local host=""
        host="${ssh_host:-$domain}"
        [ -n "$host" ] || return 1
        printf 'https://%s:%s' "$host" "${public_port:-7900}"
    fi
}

nexus_show_local_tutorial() {
    # 本地模式 SSH 隧道连接教程（安装完成后与 14 菜单中展示，防止忘记）
    [ -r "$NEXUS_CONFIG_FILE" ] || return 1
    local tunnel_port=""
    local ssh_host=""
    tunnel_port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    [ -n "$tunnel_port" ] || tunnel_port="7900"
    ssh_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    if [ -z "$ssh_host" ]; then
        select_entry_ip >/dev/null 2>&1 && ssh_host="$ENTRY_IP_RAW"
    fi
    [ -n "$ssh_host" ] || return 1
    [[ "$ssh_host" == *:* ]] && ssh_host="[$ssh_host]"
    echo -e "${CYAN}============ 本地模式连接教程（每次打开面板前执行） ============${RESET}"
    echo -e "${YELLOW}1. 在你自己的电脑终端（不是当前 VPS SSH 窗口）执行：${RESET}"
    echo -e "${GREEN}ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L ${tunnel_port}:127.0.0.1:7900 root@${ssh_host}${RESET}"
    echo -e "${YELLOW}2. 输入服务器 root 密码（屏幕不显示字符是正常的安全行为）。${RESET}"
    echo -e "${YELLOW}3. 保持该终端窗口打开，再用浏览器访问：${RESET}${CYAN}http://127.0.0.1:${tunnel_port}${RESET}"
    echo -e "${YELLOW}4. 用完按 Ctrl+C 关闭隧道；终端一关，面板本地访问也会断开。${RESET}"
    echo -e "${CYAN}=================================================================================${RESET}"
}

nexus_core_supports_traffic() {
    [ -x "$SINGBOX_BIN" ] || return 1
    "$SINGBOX_BIN" version 2>/dev/null | grep -qw 'with_v2ray_api'
}

nexus_fetch_traffic_core_release() {
    local target_file="$1"
    local upstream_file="${target_file}.upstream"
    local upstream_tag=""
    local release_tag=""
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$upstream_file" "$NEXUS_CORE_UPSTREAM_API" || return 1
    upstream_tag=$(jq -r '.tag_name // empty' "$upstream_file")
    [[ "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    release_tag="rr-nexus-core-${upstream_tag}"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 40 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$target_file" "${NEXUS_CORE_RELEASE_API}/${release_tag}" || return 1
    jq -e --arg tag "$release_tag" \
        '.tag_name == $tag and .draft == false and .prerelease == false' \
        "$target_file" >/dev/null || return 1
}

nexus_stats_port() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 1
    local port=""
    port=$(jq -r '.stats_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    is_valid_port "$port" || return 1
    printf '%s\n' "$port"
}

nexus_device_naive_password() {
    # 每设备独立 naive 密码（无状态可复算：SHA256(NAIVE_PASS:device_id) 前 24 位）
    local device_id="$1"
    load_config_with_defaults 2>/dev/null || true
    [ -n "${NAIVE_PASS:-}" ] || return 1
    printf '%s' "${NAIVE_PASS}:${device_id}" | sha256sum | cut -c1-24
}

nexus_atomic_copy() {
    # 订阅客户端可能恰好在刷新过程中拉取文件；始终先写同目录临时文件，
    # 再原子替换，避免返回截断的 Base64/JSON/YAML。
    local source_path="$1"
    local target_path="$2"
    local target_tmp=""
    [ -f "$source_path" ] || return 1
    target_tmp=$(mktemp "${target_path}.XXXXXX") || return 1
    if ! cp -f "$source_path" "$target_tmp" || ! chmod 600 "$target_tmp"; then
        rm -f "$target_tmp"
        return 1
    fi
    mv -f "$target_tmp" "$target_path"
}

nexus_traffic_user_names() {
    if [ ! -f "$NEXUS_DB_FILE" ]; then
        printf '%s\n' '[]'
        return 0
    fi
    python3 - "$NEXUS_DB_FILE" <<'PY'
import datetime
import json
import sqlite3
import sys

today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
connection = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=5)
rows = connection.execute(
    """SELECT id FROM devices
       WHERE enabled=1
         AND (expires_at IS NULL OR expires_at='' OR expires_at>=?)
         AND (quota_bytes=0 OR used_bytes<quota_bytes)
       ORDER BY created_at""",
    (today,),
).fetchall()
print(json.dumps([row[0] for row in rows], separators=(",", ":")))
PY
}

nexus_collect_traffic_once() {
    nexus_is_installed || return 0
    command -v python3 >/dev/null 2>&1 || return 1
    RR_NEXUS_CONFIG="$NEXUS_CONFIG_FILE" python3 "$NEXUS_APP" --collect-traffic
}

nexus_traffic_core_version() {
    local work_dir=""
    local release_json=""
    local build_info=""
    local info_url=""
    local version=""
    work_dir=$(mktemp -d /tmp/rr-nexus-version.XXXXXX) || return 1
    release_json="$work_dir/release.json"
    build_info="$work_dir/BUILD_INFO"
    if ! nexus_fetch_traffic_core_release "$release_json"; then
        rm -rf "$work_dir"
        return 1
    fi
    local release_tag=""
    release_tag=$(jq -r '.tag_name // empty' "$release_json")
    info_url=$(jq -r '.assets[] | select(.name == "BUILD_INFO") | .browser_download_url' \
        "$release_json" | head -n 1)
    if [ "$info_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/BUILD_INFO" ] || \
       ! curl -fL --retry 2 --connect-timeout 8 --max-time 30 \
           -o "$build_info" "$info_url"; then
        rm -rf "$work_dir"
        return 1
    fi
    version=$(awk -F= '$1 == "SING_BOX_VERSION" {print $2; exit}' "$build_info")
    rm -rf "$work_dir"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    printf '%s\n' "$version"
}

nexus_download_traffic_core() {
    local work_dir="$1"
    local release_json="$work_dir/release.json"
    local checksums="$work_dir/SHA256SUMS"
    local build_info="$work_dir/BUILD_INFO"
    local archive_name=""
    local archive_url=""
    local checksum_url=""
    local info_url=""
    local expected=""
    local actual=""
    local version=""
    local source_tag=""
    local extracted=""

    nexus_fetch_traffic_core_release "$release_json" || return 1
    local release_tag=""
    release_tag=$(jq -r '.tag_name // empty' "$release_json")
    checksum_url=$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' \
        "$release_json" | head -n 1)
    info_url=$(jq -r '.assets[] | select(.name == "BUILD_INFO") | .browser_download_url' \
        "$release_json" | head -n 1)
    if [ "$checksum_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/SHA256SUMS" ] || \
       [ "$info_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/BUILD_INFO" ]; then
        return 1
    fi
    curl -fL --retry 3 --connect-timeout 10 --max-time 40 -o "$checksums" "$checksum_url" || return 1
    curl -fL --retry 3 --connect-timeout 10 --max-time 40 -o "$build_info" "$info_url" || return 1
    version=$(awk -F= '$1 == "SING_BOX_VERSION" {print $2; exit}' "$build_info")
    source_tag=$(awk -F= '$1 == "SING_BOX_TAG" {print $2; exit}' "$build_info")
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    [ "$source_tag" = "v${version}" ] || return 1
    [ "$release_tag" = "rr-nexus-core-${source_tag}" ] || return 1
    grep -Eq '^SOURCE_COMMIT=[0-9a-f]{40}$' "$build_info" || return 1
    awk '
        NF != 2 || $1 !~ /^[0-9a-f]{64}$/ ||
        $2 !~ /^rr-sing-box-[0-9A-Za-z.-]+-linux-(amd64|arm64)\.tar\.gz$/ { exit 1 }
        seen[$2]++ { exit 1 }
        END { if (NR != 2) exit 1 }
    ' "$checksums" || return 1
    archive_name="rr-sing-box-${version}-linux-${SYS_ARCH}.tar.gz"
    archive_url=$(jq -r --arg name "$archive_name" \
        '.assets[] | select(.name == $name) | .browser_download_url' "$release_json" | head -n 1)
    [ "$archive_url" = "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/${archive_name}" ] || return 1
    curl -fL --retry 3 --connect-timeout 10 --max-time 240 --max-filesize 104857600 \
        -o "$work_dir/$archive_name" "$archive_url" || return 1
    [ "$(stat -c %s "$work_dir/$archive_name" 2>/dev/null || echo 0)" -le 104857600 ] || return 1
    expected=$(awk -v name="$archive_name" '$2 == name {print $1; exit}' "$checksums")
    actual=$(sha256sum "$work_dir/$archive_name" | awk '{print $1}')
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] || return 1
    extracted="sing-box-${version}-linux-${SYS_ARCH}/sing-box"
    tar -tzf "$work_dir/$archive_name" "$extracted" >/dev/null 2>&1 || return 1
    tar --no-same-owner -xzf "$work_dir/$archive_name" -C "$work_dir" "$extracted" 2>/dev/null || return 1
    [ -f "$work_dir/$extracted" ] && [ ! -L "$work_dir/$extracted" ] && \
        [ "$(stat -c %h "$work_dir/$extracted" 2>/dev/null || echo 0)" -eq 1 ] || return 1
    install -m 755 "$work_dir/$extracted" "$work_dir/sing-box" || return 1
    "$work_dir/sing-box" version 2>/dev/null | grep -qw 'with_v2ray_api' || return 1
    version_ge "$(get_singbox_version "$work_dir/sing-box")" "$MIN_SINGBOX_VERSION" || return 1
}

nexus_enable_traffic_engine() {
    local tx_dir=""
    local was_running=false
    local installed_new_core=false
    tx_dir=$(mktemp -d /tmp/rr-nexus-core.XXXXXX) || return 1
    [ -x "$SINGBOX_BIN" ] && cp -p "$SINGBOX_BIN" "$tx_dir/sing-box.previous"
    [ -f /etc/sing-box/config.json ] && cp -p /etc/sing-box/config.json "$tx_dir/config.previous"
    managed_singbox_running && was_running=true

    if ! nexus_core_supports_traffic; then
        echo -e "${YELLOW}正在安装 RR Nexus 实时流量统计内核（官方 Sing-box 源码构建）……${RESET}"
        if ! nexus_download_traffic_core "$tx_dir"; then
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 无法下载或校验 RR Nexus 统计内核。${RESET}"
            return 1
        fi
        install -m 755 "$tx_dir/sing-box" "${SINGBOX_BIN}.new" || { rm -rf "$tx_dir"; return 1; }
        mv -f "${SINGBOX_BIN}.new" "$SINGBOX_BIN"
        installed_new_core=true
    fi

    if ! build_singbox_config || ! nexus_core_supports_traffic; then
        [ -f "$tx_dir/sing-box.previous" ] && install -m 755 "$tx_dir/sing-box.previous" "$SINGBOX_BIN"
        [ -f "$tx_dir/config.previous" ] && cp -p "$tx_dir/config.previous" /etc/sing-box/config.json
        rm -rf "$tx_dir"
        echo -e "${RED}[失败] 实时流量统计配置未通过 Sing-box 校验，已回滚。${RESET}"
        return 1
    fi
    if [ "$was_running" = true ] && \
       [[ "$SINGBOX_CONFIG_CHANGED" = true || "$installed_new_core" = true ]]; then
        if ! restart_singbox; then
            [ -f "$tx_dir/sing-box.previous" ] && install -m 755 "$tx_dir/sing-box.previous" "$SINGBOX_BIN"
            [ -f "$tx_dir/config.previous" ] && cp -p "$tx_dir/config.previous" /etc/sing-box/config.json
            restart_singbox >/dev/null 2>&1 || true
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 统计内核启动失败，已恢复原节点内核和配置。${RESET}"
            return 1
        fi
    elif [ "$was_running" != true ] && any_node_protocol_enabled; then
        if ! ensure_node_service_running; then
            [ -f "$tx_dir/sing-box.previous" ] && install -m 755 "$tx_dir/sing-box.previous" "$SINGBOX_BIN"
            [ -f "$tx_dir/config.previous" ] && cp -p "$tx_dir/config.previous" /etc/sing-box/config.json
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 统计内核无法启动，已恢复原节点内核和配置。${RESET}"
            return 1
        fi
    fi
    rm -rf "$tx_dir"
    echo -e "${GREEN}[成功] 单独用户实时流量统计已启用。${RESET}"
    return 0
}

nexus_protocol_users() {
    local protocol="$1"
    local legacy_uuid="$2"
    if [ ! -r "$NEXUS_CONFIG_FILE" ] || [ ! -f "$NEXUS_DB_FILE" ]; then
        case "$protocol" in
            vmess) jq -nc --arg id "$legacy_uuid" '[{name:"legacy",uuid:$id,alterId:0}]' ;;
            vless) jq -nc --arg id "$legacy_uuid" '[{name:"legacy",uuid:$id,flow:"xtls-rprx-vision"}]' ;;
            hysteria2|anytls) jq -nc --arg id "$legacy_uuid" '[{name:"legacy",password:$id}]' ;;
            tuic) jq -nc --arg id "$legacy_uuid" '[{name:"legacy",uuid:$id,password:$id}]' ;;
            *) return 1 ;;
        esac
        return
    fi

    python3 - "$NEXUS_DB_FILE" "$protocol" "$legacy_uuid" <<'PY'
import datetime
import json
import sqlite3
import sys

database, protocol, legacy = sys.argv[1:]
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
base = {
    "vmess": {"name": "legacy", "uuid": legacy, "alterId": 0},
    "vless": {"name": "legacy", "uuid": legacy, "flow": "xtls-rprx-vision"},
    "hysteria2": {"name": "legacy", "password": legacy},
    "tuic": {"name": "legacy", "uuid": legacy, "password": legacy},
    "anytls": {"name": "legacy", "password": legacy},
}
if protocol not in base:
    raise SystemExit(2)
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=5)
connection.row_factory = sqlite3.Row
rows = connection.execute(
    """SELECT id,credential FROM devices
       WHERE enabled=1
         AND (expires_at IS NULL OR expires_at='' OR expires_at>=?)
         AND (quota_bytes=0 OR used_bytes<quota_bytes)
       ORDER BY created_at""",
    (today,),
).fetchall()
users = [base[protocol]]
for row in rows:
    credential = row["credential"]
    name = row["id"]
    if protocol == "vmess":
        users.append({"name": name, "uuid": credential, "alterId": 0})
    elif protocol == "vless":
        users.append({"name": name, "uuid": credential, "flow": "xtls-rprx-vision"})
    elif protocol in {"hysteria2", "anytls"}:
        users.append({"name": name, "password": credential})
    else:
        users.append({"name": name, "uuid": credential, "password": credential})
print(json.dumps(users, ensure_ascii=False, separators=(",", ":")))
PY
}

generate_nexus_device_subscriptions() {
    [ -f "$NEXUS_DB_FILE" ] || return 0
    load_config_with_defaults || return 1
    ensure_subscription_root || return 1
    validate_subscription_crypto_material || return 1
    select_entry_ip || return 1
    # 面板进程会在每次打开「链接与二维码」时重读这两个值。这样入口 IP、
    # IPv4/IPv6 或 NAT 公网订阅端口变化后，无需重启面板也不会生成旧二维码。
    nexus_sync_subscription_endpoint || return 1
    install -d -m 700 "$NEXUS_DATA_DIR" "$NEXUS_SUB_ROOT" || return 1

    local rows_file=""
    rows_file=$(mktemp /tmp/rr-nexus-devices.XXXXXX) || return 1
    if ! python3 - "$NEXUS_DB_FILE" > "$rows_file" <<'PY'; then
import datetime
import sqlite3
import sys

# 不用 mode=ro：SQLite 只读连接在 -shm 缺失时读不到 WAL 里的新提交，导致刚创建的设备"消失"
connection = sqlite3.connect(sys.argv[1], timeout=5)
# B2/E15：与面板 /sub 路由、sing-box 用户生成（nexus_protocol_users）语义对齐——
# 停用/已到期/额度用尽的设备不再生成订阅文件，双路由（面板 /sub 与 sub_server /nexus）一致拒绝。
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
for row in connection.execute(
    "SELECT id,credential,name,subscription_token FROM devices "
    "WHERE enabled=1 "
    "AND (expires_at IS NULL OR expires_at='' OR expires_at>=?) "
    "AND (quota_bytes=0 OR used_bytes<quota_bytes) "
    "ORDER BY created_at",
    (today,),
):
    print("\t".join(str(value) for value in row))
PY
        rm -f "$rows_file"
        return 1
    fi

    local device_id=""
    local credential=""
    local device_name=""
    local sub_token=""
    local display_name=""
    local node_alias=""
    local all_links=""
    local link=""
    local active_ids="|"
    local active_tokens="|"
    local server_uri="$ENTRY_IP_URI"
    local server_raw="$ENTRY_IP_RAW"
    local output_tmp=""
    while IFS=$'\t' read -r device_id credential device_name sub_token; do
        [[ "$device_id" =~ ^dev_[a-f0-9]{12}$ ]] || continue
        is_valid_uuid "$credential" || continue
        # 设备备注只供管理员在面板辨认，绝不进入客户端订阅。设备 ID 本身由
        # 12 位随机十六进制生成，取前 8 位作为稳定且不可读出备注的节点别名。
        node_alias="RR-${device_id#dev_}"
        node_alias="${node_alias:0:11}"
        node_alias=$(printf '%s' "$node_alias" | tr '[:lower:]' '[:upper:]')
        display_name=$(jq -nr --arg value "$node_alias" '$value|@uri')
        all_links=""

        if [ "$VM_ENABLED" != "false" ]; then
            local vm_json=""
            if [ "$VM_TLS_ENABLED" = "true" ]; then
                vm_json=$(jq -nc --arg name "VMess · $node_alias" --arg add "$server_raw" \
                    --arg port "$PORT" --arg id "$credential" --arg path "/${UUID}-vm" \
                    '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:"www.bing.com",path:$path,tls:"tls",sni:"www.bing.com",fp:"chrome",allowInsecure:"1",insecure:"1"}')
            else
                vm_json=$(jq -nc --arg name "VMess Argo · $node_alias" --arg add "$CDN_IP" \
                    --arg port "$ARGO_EDGE_PORT" --arg id "$credential" --arg host "$ARGO_DOMAIN" \
                    --arg path "/${UUID}-vm" \
                    '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:$host,path:$path,tls:"tls",sni:$host,fp:"chrome"}')
            fi
            link="vmess://$(printf '%s' "$vm_json" | base64 -w 0)"
            all_links="$link"
            # Argo 优选副节点（自动优选 worker 解析的 CNAME，仅 Argo 模式）
            if [ "$VM_TLS_ENABLED" != "true" ] && [ -s /tmp/sub_server/preferred_cnames.txt ]; then
                local pref_add="" pref_index=1
                while IFS= read -r pref_add; do
                    [ -n "$pref_add" ] || continue
                    vm_json=$(jq -nc --arg name "VMess Argo优选${pref_index} · $node_alias" --arg add "$pref_add" \
                        --arg port "$ARGO_EDGE_PORT" --arg id "$credential" --arg host "$ARGO_DOMAIN" \
                        --arg path "/${UUID}-vm" \
                        '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:$host,path:$path,tls:"tls",sni:$host,fp:"chrome"}')
                    link="vmess://$(printf '%s' "$vm_json" | base64 -w 0)"
                    all_links="${all_links}
$link"
                    pref_index=$((pref_index + 1))
                done < /tmp/sub_server/preferred_cnames.txt
            fi
        fi
        if [ "$VL_ENABLED" = "true" ] && [ "$VL_PORT" != "0" ]; then
            link="vless://${credential}@${server_uri}:${VL_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${display_name}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$HY2_ENABLED" = "true" ] && [ "$HY2_PORT" != "0" ]; then
            local hy2_hop=""
            local hy2_extra=""
            hy2_hop=$(get_hop_ports "$HY2_PORT")
            [ -n "$hy2_hop" ] && hy2_extra="&mport=$(printf '%s' "$hy2_hop" | tr ':' '-')"
            # 服务端启用了 Salamander 混淆；个人 URI 必须携带同一混淆密码，
            # 否则 NekoBox 等客户端虽能导入，却无法建立连接。
            link="hysteria2://${credential}@${server_uri}:${HY2_PORT}?security=tls&alpn=h3&insecure=1&sni=www.bing.com&pinSHA256=${CERT_SHA256}&obfs=salamander&obfs-password=${UUID}${hy2_extra}#HY2-${display_name}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$TU5_ENABLED" = "true" ] && [ "$TU5_PORT" != "0" ]; then
            link="tuic://${credential}:${credential}@${server_uri}:${TU5_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&insecure=1&allow_insecure=1#TUIC-${display_name}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$AN_ENABLED" = "true" ] && [ "$AN_PORT" != "0" ]; then
            link="anytls://${credential}@${server_uri}:${AN_PORT}?sni=www.bing.com&insecure=1#AnyTLS-${display_name}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        # NAIVE-SUPPORT: NaiveProxy URI（每设备独立凭据：username=设备ID，密码=无状态复算，流量可精确归属）
        if [ "$NAIVE_ENABLED" = "true" ] && [ "$NAIVE_PORT" != "0" ]; then
            local ndev_pw=""
            ndev_pw=$(nexus_device_naive_password "$device_id") || ndev_pw="$NAIVE_PASS"
            if [ "${NAIVE_MODE:-h2}" != h3 ]; then
                link="naive+https://${device_id}:${ndev_pw}@${NAIVE_DOMAIN}:${NAIVE_PORT}#RR-Naive-H2·${display_name}"
                all_links="${all_links:+$all_links$'\n'}$link"
            fi
            if [ "${NAIVE_MODE:-h2}" != h2 ]; then
                link="naive+quic://${device_id}:${ndev_pw}@${NAIVE_DOMAIN}:${NAIVE_PORT}?congestion_control=${NAIVE_QUIC_CC:-bbr}#RR-Naive-H3·${display_name}"
                all_links="${all_links:+$all_links$'\n'}$link"
            fi
        fi

        output_tmp=$(mktemp "$NEXUS_SUB_ROOT/.${device_id}.XXXXXX") || { rm -f "$rows_file"; return 1; }
        printf '%s\n' "$all_links" > "$output_tmp"
        chmod 600 "$output_tmp"
        mv -f "$output_tmp" "$NEXUS_SUB_ROOT/${device_id}.txt"
        # 多格式订阅：Sing-box 完整配置 + Clash Meta YAML（复用主订阅生成器，凭据与输出目录覆盖）
        # NAIVE-SUPPORT: json/yaml 里的 naive 由 generate_client_json/generate_clash_yaml 内部处理（主线 40-subscription.sh 已支持），此处无需额外逻辑
        if declare -F generate_client_json >/dev/null 2>&1 && declare -F generate_clash_yaml >/dev/null 2>&1; then
            local device_sub_dir="${NEXUS_SUB_ROOT}/.fmt-${device_id}"
            install -d -m 700 "$device_sub_dir"
            local ndev_ou="$device_id"
            local ndev_op=""
            ndev_op=$(nexus_device_naive_password "$device_id") || ndev_op="$NAIVE_PASS"
            if RR_CLIENT_UUID_OVERRIDE="$credential" RR_CLIENT_NAME_OVERRIDE="$node_alias" RR_NAIVE_USER_OVERRIDE="$ndev_ou" RR_NAIVE_PASS_OVERRIDE="$ndev_op" RR_SUB_OUTPUT_DIR="$device_sub_dir" \
                generate_client_json "$server_raw" 2>/dev/null; then
                nexus_atomic_copy "$device_sub_dir/client.json" "$NEXUS_SUB_ROOT/${device_id}.json" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                # 旧版 Reality 单节点地址继续生成，仅用于已有订阅平滑热更。
                if RR_CLIENT_UUID_OVERRIDE="$credential" RR_CLIENT_NAME_OVERRIDE="$node_alias" RR_NAIVE_USER_OVERRIDE="$ndev_ou" RR_NAIVE_PASS_OVERRIDE="$ndev_op" RR_SUB_OUTPUT_DIR="$device_sub_dir" \
                    generate_client_json "$server_raw" vless 2>/dev/null; then
                    nexus_atomic_copy "$device_sub_dir/client-vl.json" "$NEXUS_SUB_ROOT/${device_id}-vl.json" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                else
                    rm -f "$NEXUS_SUB_ROOT/${device_id}-vl.json"
                fi
            else
                rm -f "$NEXUS_SUB_ROOT/${device_id}.json" "$NEXUS_SUB_ROOT/${device_id}-vl.json"
            fi
            # URI/Base64 订阅只依赖上面已经生成的原始链接，不能被 Sing-box
            # JSON 的生成结果连带跳过；这保证 NekoBox 等地址始终同步刷新。
            local _dev_txt="$NEXUS_SUB_ROOT/${device_id}.txt"
            if [ -s "$_dev_txt" ]; then
                local _encoded_tmp=""
                _encoded_tmp=$(mktemp "$NEXUS_SUB_ROOT/.${device_id}-encoded.XXXXXX") || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                if ! base64 -w0 < "$_dev_txt" > "$_encoded_tmp" || ! chmod 600 "$_encoded_tmp"; then
                    rm -f "$_encoded_tmp"
                    rm -rf "$device_sub_dir"
                    rm -f "$rows_file"
                    return 1
                fi
                mv -f "$_encoded_tmp" "$NEXUS_SUB_ROOT/${device_id}-v2rayn.txt"
                nexus_atomic_copy "$NEXUS_SUB_ROOT/${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-v2rayng.txt" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                nexus_atomic_copy "$NEXUS_SUB_ROOT/${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-sr.txt" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                nexus_atomic_copy "$NEXUS_SUB_ROOT/${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
            fi
            if RR_CLIENT_UUID_OVERRIDE="$credential" RR_CLIENT_NAME_OVERRIDE="$node_alias" RR_SUB_OUTPUT_DIR="$device_sub_dir" \
                generate_clash_yaml "$server_raw" 2>/dev/null && \
                RR_CLIENT_UUID_OVERRIDE="$credential" RR_SUB_OUTPUT_DIR="$device_sub_dir" generate_clash_client_copies 2>/dev/null; then
                nexus_atomic_copy "$device_sub_dir/clash_meta.yaml" "$NEXUS_SUB_ROOT/${device_id}.yaml" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                nexus_atomic_copy "$device_sub_dir/client-mihomo.yaml" "$NEXUS_SUB_ROOT/${device_id}-mihomo.yaml" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                nexus_atomic_copy "$device_sub_dir/client-clash-verge.yaml" "$NEXUS_SUB_ROOT/${device_id}-clash-verge.yaml" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
                nexus_atomic_copy "$device_sub_dir/client-flclash.yaml" "$NEXUS_SUB_ROOT/${device_id}-flclash.yaml" || { rm -rf "$device_sub_dir"; rm -f "$rows_file"; return 1; }
            else
                rm -f "$NEXUS_SUB_ROOT/${device_id}.yaml" "$NEXUS_SUB_ROOT/${device_id}-mihomo.yaml" \
                    "$NEXUS_SUB_ROOT/${device_id}-clash-verge.yaml" "$NEXUS_SUB_ROOT/${device_id}-flclash.yaml"
            fi
            rm -rf "$device_sub_dir"
        fi
        # 同步一份到主订阅服务器目录（本地模式用户通过主订阅地址获取个人订阅）
        if [ -n "$sub_token" ] && [ -d "$SUB_ROOT" ]; then
            local nexus_pub_dir="${SUB_ROOT}/nexus"
            install -d -m 700 "$nexus_pub_dir"
            nexus_atomic_copy "$NEXUS_SUB_ROOT/${device_id}.txt" "$nexus_pub_dir/${sub_token}.txt" || { rm -f "$rows_file"; return 1; }
            # 逐格式同步；新一轮未生成的格式必须同时删除旧发布副本，避免
            # 个人地址/二维码继续返回上一次配置的陈旧内容。
            local _split_sfx=""
            for _split_sfx in ".json" ".yaml" "-vl.json" "-mihomo.yaml" "-clash-verge.yaml" "-flclash.yaml" "-v2rayn.txt" "-v2rayng.txt" "-sr.txt" "-nekobox.txt"; do
                if [ -f "$NEXUS_SUB_ROOT/${device_id}${_split_sfx}" ]; then
                    nexus_atomic_copy "$NEXUS_SUB_ROOT/${device_id}${_split_sfx}" "$nexus_pub_dir/${sub_token}${_split_sfx}" || { rm -f "$rows_file"; return 1; }
                else
                    rm -f "$nexus_pub_dir/${sub_token}${_split_sfx}"
                fi
            done
            active_tokens="${active_tokens}${sub_token}|"
        fi
        active_ids="${active_ids}${device_id}|"
    done < "$rows_file"
    rm -f "$rows_file"

    local existing_file=""
    for existing_file in "$NEXUS_SUB_ROOT"/dev_*.txt; do
        [ -f "$existing_file" ] || continue
        device_id=$(basename "$existing_file" .txt)
        # 跳过按客户端拆分的订阅文件。
        case "$device_id" in
            *-v2rayn|*-v2rayng|*-sr|*-nekobox) continue ;;
        esac
        if [[ "$active_ids" != *"|${device_id}|"* ]]; then
            # 同步删除按客户端拆分的订阅文件（-vl/-v2rayn/-v2rayng/-sr/-nekobox），
            # 旧实现只删 .txt/.json/.yaml，已删设备的拆分文件残留（D10）
            rm -f "$existing_file" "$NEXUS_SUB_ROOT/${device_id}.json" "$NEXUS_SUB_ROOT/${device_id}.yaml" \
                "$NEXUS_SUB_ROOT/${device_id}-vl.json" "$NEXUS_SUB_ROOT/${device_id}-mihomo.yaml" "$NEXUS_SUB_ROOT/${device_id}-clash-verge.yaml" \
                "$NEXUS_SUB_ROOT/${device_id}-flclash.yaml" "$NEXUS_SUB_ROOT/${device_id}-v2rayn.txt" "$NEXUS_SUB_ROOT/${device_id}-v2rayng.txt" \
                "$NEXUS_SUB_ROOT/${device_id}-sr.txt" "$NEXUS_SUB_ROOT/${device_id}-nekobox.txt"
        fi
    done
    # 清理主订阅目录中已删除设备的订阅副本
    if [ -d "${SUB_ROOT}/nexus" ]; then
        # 目录枚举防护（D4）：与根目录/短路由目录一致放置空白 index.html（0600），
        # SimpleHTTPServer 存在 index.html 时不输出目录清单
        : > "${SUB_ROOT}/nexus/index.html" 2>/dev/null || true
        chmod 600 "${SUB_ROOT}/nexus/index.html" 2>/dev/null || true
        for pub_file in "${SUB_ROOT}"/nexus/*.txt; do
            [ -f "$pub_file" ] || continue
            pub_token=$(basename "$pub_file" .txt)
            case "$pub_token" in
                *-v2rayn|*-v2rayng|*-sr|*-nekobox) continue ;;
            esac
            if [[ "$active_tokens" != *"|${pub_token}|"* ]]; then
                rm -f "$pub_file" "${SUB_ROOT}/nexus/${pub_token}.json" "${SUB_ROOT}/nexus/${pub_token}.yaml" \
                    "${SUB_ROOT}/nexus/${pub_token}-vl.json" "${SUB_ROOT}/nexus/${pub_token}-mihomo.yaml" "${SUB_ROOT}/nexus/${pub_token}-clash-verge.yaml" \
                    "${SUB_ROOT}/nexus/${pub_token}-flclash.yaml" "${SUB_ROOT}/nexus/${pub_token}-v2rayn.txt" "${SUB_ROOT}/nexus/${pub_token}-v2rayng.txt" \
                    "${SUB_ROOT}/nexus/${pub_token}-sr.txt" "${SUB_ROOT}/nexus/${pub_token}-nekobox.txt"
            fi
        done
    fi
    return 0
}

sync_nexus_devices() {
    [ -f "$CONFIG_FILE" ] || return 1
    load_config_with_defaults || return 1
    # QueryStats(reset=true) flushes the current per-user delta before a
    # configuration restart, minimizing the otherwise unavoidable reload gap.
    nexus_collect_traffic_once >/dev/null 2>&1 || true
    local snapshot=""
    local was_running=false
    snapshot=$(mktemp /tmp/rr-nexus-singbox.XXXXXX) || return 1
    if [ -f /etc/sing-box/config.json ]; then
        cp -p /etc/sing-box/config.json "$snapshot" || { rm -f "$snapshot"; return 1; }
    else
        : > "$snapshot"
    fi
    managed_singbox_running && was_running=true

    if ! build_singbox_config; then
        rm -f "$snapshot"
        return 1
    fi
    if [ "$SINGBOX_CONFIG_CHANGED" = true ] && [ "$was_running" = true ] && any_node_protocol_enabled; then
        if ! restart_singbox; then
            [ -s "$snapshot" ] && cp -p "$snapshot" /etc/sing-box/config.json
            restart_singbox >/dev/null 2>&1 || true
            rm -f "$snapshot"
            return 1
        fi
    fi
    if ! generate_nexus_device_subscriptions; then
        if [ -s "$snapshot" ]; then
            cp -p "$snapshot" /etc/sing-box/config.json
            [ "$was_running" = true ] && restart_singbox >/dev/null 2>&1 || true
        fi
        rm -f "$snapshot"
        return 1
    fi
    rm -f "$snapshot"
    return 0
}

nexus_install_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=120 update -y || return 1
    apt-get -o DPkg::Lock::Timeout=120 install -y \
        python3 python3-pip python3-argon2 python3-cryptography qrencode sqlite3 jq || return 1

    # P1 修复：grpcio < 1.43 在 Ubuntu 22.04 上会导致面板 CPU 死循环。
    # 优先级：已装新版跳过 → apt 源版（Debian12=1.51 / Ubuntu24=1.60 直接满足，
    # 且不引入 pip 依赖冲突）→ 最后才 pip 兜底（仅 Ubuntu22 需要，源版 1.41）。
    grpcio_version_ok() {
        python3 -c 'import grpc; v = grpc.__version__.split("."); raise SystemExit(0 if int(v[0]) > 1 or (int(v[0]) == 1 and int(v[1]) >= 43) else 1)' 2>/dev/null
    }
    if grpcio_version_ok; then
        return 0
    fi
    if apt-get -o DPkg::Lock::Timeout=120 install -y python3-grpcio >/dev/null 2>&1 && grpcio_version_ok; then
        return 0
    fi

    # pip 兜底：卸载 apt 旧版（Ubuntu22 的 1.41），改从 PyPI 装 >=1.43。
    # 坑：apt 装的 typing_extensions 无 pip RECORD 文件，pip 升级它时报
    # "Cannot uninstall typing_extensions" 导致整个安装失败——
    # 先 --ignore-installed 装 pip 版 shadow 掉 debian 版（/usr/local/lib 优先）。
    if dpkg -l python3-grpcio >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=120 remove -y python3-grpcio >/dev/null 2>&1 || true
    fi
    local pip_extra=""
    if python3 -m pip install --help 2>&1 | grep -q -- '--break-system-packages'; then
        pip_extra="--break-system-packages"
    fi
    python3 -m pip install $pip_extra -q --ignore-installed typing_extensions 2>/dev/null || true
    python3 -m pip install $pip_extra -q "grpcio>=1.43" || {
        echo -e "${RED}错误：pip 安装 grpcio 失败（网络或依赖冲突），面板安装中止。${RESET}" >&2
        return 1
    }

    # 验证安装结果：版本必须 >= 1.43
    if ! grpcio_version_ok; then
        echo -e "${RED}错误：grpcio 版本低于 1.43（存在 CPU 死循环缺陷），安装失败${RESET}" >&2
        return 1
    fi
    return 0
}

nexus_write_config() {
    local mode="$1"        # local / public
    local domain="$2"      # domain or "ip"
    local user_port="$3"   # user-facing port
    local traffic_mode_val="${6:-both}"
    local backend_port=7900  # backend ALWAYS binds to 7900
    local stats_port="$4"
    local ssh_host="$5"

    mkdir -p /etc/rr-nexus /var/lib/rr-nexus/subscriptions
    local cfg='{
  "mode": "__MODE__",
  "listen": "127.0.0.1",
  "port": __BACKEND_PORT__,
  "domain": "__DOMAIN__",
  "database": "/var/lib/rr-nexus/nexus.db",
  "subscription_root": "/var/lib/rr-nexus/subscriptions",
  "published_subscription_root": "__PUBLISHED_SUB_ROOT__",
  "stats_port": __STATS_PORT__,
  "ssh_host": "__SSH_HOST__",
  "public_port": __USER_PORT__,
  "sub_port": __SUB_PORT__,
  "traffic_mode": "__TRAFFIC_MODE__"
}'
    cfg="${cfg//__MODE__/$mode}"
    cfg="${cfg//__BACKEND_PORT__/$backend_port}"
    cfg="${cfg//__DOMAIN__/$domain}"
    cfg="${cfg//__PUBLISHED_SUB_ROOT__/${SUB_ROOT}\/nexus}"
    cfg="${cfg//__STATS_PORT__/$stats_port}"
    cfg="${cfg//__SSH_HOST__/$ssh_host}"
    cfg="${cfg//__USER_PORT__/$user_port}"
    # sub_port 在 Nexus 配置里表示二维码/订阅地址应使用的公网端口。
    # 普通 VPS 与 SUB_PORT 相同；NAT/LXD 必须使用当前入口族的映射端口。
    cfg="${cfg//__SUB_PORT__/${SUB_URL_PORT:-${SUB_PORT:-0}}}"
    cfg="${cfg//__TRAFFIC_MODE__/$traffic_mode_val}"
    echo "$cfg" > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
}

nexus_sync_subscription_endpoint() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    [ -n "${ENTRY_IP_RAW:-}" ] || return 1
    is_valid_port "${SUB_URL_PORT:-}" || return 1

    local current_host=""
    local current_port=""
    local tmp=""
    current_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    current_port=$(jq -r '.sub_port // 0' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    if [ "$current_host" = "$ENTRY_IP_RAW" ] && [ "$current_port" = "$SUB_URL_PORT" ]; then
        return 0
    fi

    tmp=$(mktemp /tmp/rr-nexus-endpoint.XXXXXX) || return 1
    if ! jq --arg ssh_host "$ENTRY_IP_RAW" --argjson sub_port "$SUB_URL_PORT" \
        '.ssh_host=$ssh_host | .sub_port=$sub_port' "$NEXUS_CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    install -m 600 "$tmp" "$NEXUS_CONFIG_FILE"
    rm -f "$tmp"
}

nexus_migrate_runtime_config() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 1
    local panel_port=""
    local stats_port=""
    local ssh_host=""
    local sub_url_port=""
    local tmp=""
    panel_port=$(jq -r '.port // 7900' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    is_valid_port "$panel_port" || return 1
    stats_port=$(jq -r '.stats_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    if ! is_valid_port "$stats_port" || [ "$stats_port" = "$panel_port" ]; then
        stats_port=$(nexus_choose_stats_port "$panel_port") || return 1
    fi
    ssh_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    sub_url_port=$(jq -r '.sub_port // 0' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    if select_entry_ip >/dev/null 2>&1; then
        ssh_host="$ENTRY_IP_RAW"
        if is_valid_port "${SUB_URL_PORT:-}"; then
            sub_url_port="$SUB_URL_PORT"
        elif ! is_valid_port "$sub_url_port"; then
            sub_url_port="${SUB_PORT:-0}"
            is_valid_port "$sub_url_port" || sub_url_port=0
        fi
    else
        if [ -z "$ssh_host" ]; then
            ssh_host=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
            ssh_host="${ssh_host:-服务器IP}"
        fi
        is_valid_port "$sub_url_port" || sub_url_port="${SUB_PORT:-0}"
        is_valid_port "$sub_url_port" || sub_url_port=0
    fi
    tmp=$(mktemp /tmp/rr-nexus-migrate.XXXXXX) || return 1
    if ! jq --argjson stats_port "$stats_port" --arg ssh_host "$ssh_host" --argjson sub_port "$sub_url_port" \
        --arg published_subscription_root "${SUB_ROOT}/nexus" \
        '.listen="127.0.0.1" | .port=7900 | .database="/var/lib/rr-nexus/nexus.db" |
         .subscription_root="/var/lib/rr-nexus/subscriptions" |
         .stats_port=$stats_port | .ssh_host=$ssh_host | .sub_port=$sub_port |
         .published_subscription_root=$published_subscription_root' \
        "$NEXUS_CONFIG_FILE" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    install -m 600 "$tmp" "$NEXUS_CONFIG_FILE"
    rm -f "$tmp"
}

nexus_write_service() {
    local tmp=""
    tmp=$(mktemp /etc/systemd/system/.rr-nexus.service.XXXXXX) || return 1
    if ! cat > "$tmp" <<EOF
[Unit]
Description=RR Nexus management console
Wants=network-online.target
After=network-online.target sing-box.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${RR_LIB_DIR}/nexus
ExecStart=/usr/bin/python3 ${NEXUS_APP}
Restart=on-failure
# T4：数据库损坏以退出码 3 明确拒绝启动（rr_nexus.py 打印恢复路径），
# 不触发 Restart 循环；配合 StartLimit 双保险，杜绝无限崩溃循环。
RestartPreventExitStatus=3
RestartSec=3
UMask=0077
# 不使用 PrivateTmp：面板 sync 子进程需要访问主订阅目录（SUB_ROOT 默认 /tmp/sub_server）
ProtectHome=true
NoNewPrivileges=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$NEXUS_SERVICE_FILE"
    systemctl daemon-reload || return 1
}

# T4：为旧版已安装的 rr-nexus 单元幂等补齐 StartLimit 与损坏数据库防重启（退出码 3）。
# 与 ensure_singbox_service_guards 同模式：热更新 post_update_migrate 与健康定时器
# 都会调用，已部署机器无需重装即可获得修复。
ensure_nexus_service_guards() {
    local unit_file="$NEXUS_SERVICE_FILE"
    [ -f "$unit_file" ] || return 0

    local changed=false
    if ! grep -q '^StartLimitIntervalSec=' "$unit_file" 2>/dev/null; then
        sed -i '/^\[Unit\]$/a StartLimitIntervalSec=300' "$unit_file"
        changed=true
    fi
    if ! grep -q '^StartLimitBurst=' "$unit_file" 2>/dev/null; then
        sed -i '/^StartLimitIntervalSec=/a StartLimitBurst=5' "$unit_file"
        changed=true
    fi
    if ! grep -q '^RestartPreventExitStatus=3$' "$unit_file" 2>/dev/null; then
        sed -i '/^Restart=on-failure$/a RestartPreventExitStatus=3' "$unit_file"
        changed=true
    fi
    [ "$changed" = true ] && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

nexus_prompt_admin() {
    local username=""
    local password=""
    local password_again=""
    local init_output=""
    while true; do
        read -rp "管理员账号: " username
        [[ "$username" =~ ^[A-Za-z][A-Za-z0-9_.-]{2,31}$ ]] && break
        echo -e "${RED}账号需以字母开头，仅含字母、数字、点、下划线或连字符（3–32 位）。${RESET}"
    done
    while true; do
        read -rsp "管理员密码: " password; echo
        [ "${#password}" -ge 12 ] && [ "${#password}" -le 512 ] || {
            echo -e "${RED}密码需为 12–512 个字符。${RESET}"
            continue
        }
        read -rsp "再次输入密码: " password_again; echo
        [ "$password" = "$password_again" ] && break
        echo -e "${RED}两次密码不一致。${RESET}"
    done
    if ! init_output=$(printf '%s\n' "$password" | RR_NEXUS_CONFIG="$NEXUS_CONFIG_FILE" python3 "$NEXUS_APP" --init-admin "$username" 2>&1); then
        unset password password_again
        echo -e "${RED}[失败] 管理员初始化失败：${RESET}" >&2
        printf '%s\n' "$init_output" >&2
        return 1
    fi
    unset password password_again
    echo -e "${GREEN}[成功] 管理员账号已创建。${RESET}"
    echo -e "${YELLOW}以下 8 个一次性恢复码只显示这一次，请立即离线保存：${RESET}"
    printf '%s\n' "${init_output#RR_NEXUS_RECOVERY_CODES=}" | tr ',' '\n' | sed 's/^/  /'
}

nexus_port_available() {
    local port="$1"
    [ -f "$NEXUS_CONFIG_FILE" ] && [ "$(jq -r '.port // 0' "$NEXUS_CONFIG_FILE" 2>/dev/null)" = "$port" ] && return 0
    ! tcp_port_in_use "$port"
}

nexus_choose_port() {
    local port=""
    local preferred_port="${1:-}"
    # 推荐端口（域名模式传 443）；否则随机高位端口作为默认
    local random_port=""
    if [ -n "$preferred_port" ]; then
        random_port="$preferred_port"
    else
        random_port=$(( (RANDOM % 30000) + 10000 ))
        while ! nexus_port_available "$random_port" 2>/dev/null; do
            random_port=$(( (RANDOM % 30000) + 10000 ))
        done
    fi
    while true; do
        read -rp "面板端口（推荐 ${random_port}）: " port
        port="${port:-$random_port}"
        # 7900 是后端内部端口，不能对外使用

        if ! is_valid_port "$port"; then
            echo -e "${RED}端口无效，请输入 1-65535。${RESET}" >&2
            continue
        fi
        if nexus_port_available "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        # 提示文字必须走 stderr：本函数 stdout 只允许输出端口号（调用方 $(...) 捕获）
        echo -e "${RED}端口 ${port} 已被占用。为避免误杀 SSH、节点或其他服务，请选择其他端口。${RESET}" >&2
    done
}

nexus_choose_stats_port() {
    local panel_port="$1"
    local existing=""
    local candidate=39091
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        existing=$(jq -r '.stats_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
        if is_valid_port "$existing" && [ "$existing" != "$panel_port" ]; then
            printf '%s\n' "$existing"
            return 0
        fi
    fi
    if [ "$candidate" = "$panel_port" ] || tcp_port_in_use "$candidate"; then
        while true; do
            candidate=$(gen_random_port tcp) || return 1
            [ "$candidate" != "$panel_port" ] && break
        done
    fi
    printf '%s\n' "$candidate"
}

nexus_write_nginx_site() {
    local domain="$1"
    local port="$2"
    local tmp=""
    tmp=$(mktemp /etc/nginx/sites-available/.rr-nexus.XXXXXX) || return 1
    if ! cat > "$tmp" <<EOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 32k;

    location /.well-known/acme-challenge/ {
        root /var/www/rr-nexus-certbot;
    }

    location = /api/login {
        limit_req zone=rr_nexus_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
}
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "$NEXUS_NGINX_SITE"
    ln -sfn "$NEXUS_NGINX_SITE" /etc/nginx/sites-enabled/rr-nexus.conf
    # 语法通过后必须 reload，否则新写的 server 块不生效（仍走 default 站
    # 导致 LE acme-challenge 404，证书签发失败——6.6.14 修复）
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
}

nexus_write_nginx_custom_port() {
    local domain="$1"
    local port="$2"
    local tmp=""
    tmp=$(mktemp /etc/nginx/sites-available/.rr-nexus-port.XXXXXX) || return 1
    if ! cat > "$tmp" <<EOF
server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name ${domain};
    client_max_body_size 32k;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /api/login {
        limit_req zone=rr_nexus_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root /var/www/rr-nexus-certbot;
    }
    location / {
        return 301 https://\$host:${port}\$request_uri;
    }
}
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    mv -f "$tmp" "${NEXUS_NGINX_SITE}.port"
    ln -sfn "${NEXUS_NGINX_SITE}.port" /etc/nginx/sites-enabled/rr-nexus-port.conf
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    fi
}

nexus_enable_public_https() {
    local domain="$1"
    local email="$2"
    local port="$3"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y nginx certbot python3-certbot-nginx || return 1
    if { tcp_port_in_use 80 || tcp_port_in_use 443; } && \
       ! pgrep -x nginx >/dev/null 2>&1; then
        echo -e "${RED}[拒绝] 80/443 已被非 Nginx 程序占用，无法安全签发和托管证书。${RESET}"
        return 1
    fi
    nexus_write_nginx_site "$domain" "$port" || return 1
    systemctl enable --now nginx >/dev/null 2>&1 || return 1
    open_protocol_firewall 80 tcp

    if [ "$port" = "443" ]; then
        # 标准流程：certbot 自动配置 443 SSL 并重定向 HTTP
        open_protocol_firewall 443 tcp
        if ! certbot --nginx -d "$domain" -m "$email" --agree-tos --non-interactive --redirect; then
            echo -e "${RED}[失败] Let's Encrypt 证书签发失败。请检查域名解析和 80/443 入站后重试。${RESET}"
            nexus_remove_public_proxy
            return 1
        fi
    else
        # 自定义端口：webroot 验证签证书（不碰 443），再手写独立端口 HTTPS server
        local webroot="/var/www/rr-nexus-certbot"
        # 6.6.15：机器 root umask 077（如 DMIT 模板）时 mkdir/certbot 生成的
        # 目录为 700、挑战文件为 600，nginx(www-data) 读取报 Permission denied
        # 导致 LE 验证 403。显式 chmod 目录链 + umask 022 子壳跑 certbot。
        mkdir -p "$webroot/.well-known/acme-challenge"
        chmod 755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"
        if ! (umask 022 && certbot certonly --webroot -w "$webroot" -d "$domain" -m "$email" --agree-tos --non-interactive); then
            echo -e "${RED}[失败] Let's Encrypt 证书签发失败。请检查域名解析和 80 端口入站后重试。${RESET}"
            nexus_remove_public_proxy
            return 1
        fi
        if ! nexus_write_nginx_custom_port "$domain" "$port"; then
            echo -e "${RED}[失败] 独立端口 HTTPS 配置写入失败。${RESET}"
            nexus_remove_public_proxy
            return 1
        fi
        open_protocol_firewall "$port" tcp
    fi

    if [ ! -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
        nexus_remove_public_proxy
        return 1
    fi
    if ! nginx -t || ! systemctl reload nginx; then
        nexus_remove_public_proxy
        return 1
    fi
    systemctl enable --now certbot.timer >/dev/null 2>&1 || \
        echo -e "${YELLOW}[提示] 系统未提供 certbot.timer，请确认发行版自带的 Certbot cron 续签任务正常。${RESET}"
    return 0
}

nexus_remove_public_proxy() {
    rm -f /etc/nginx/sites-enabled/rr-nexus.conf "$NEXUS_NGINX_SITE"
    rm -f /etc/nginx/sites-enabled/rr-nexus-ip.conf /etc/nginx/sites-available/rr-nexus-ip.conf
    rm -f /etc/nginx/sites-enabled/rr-nexus-port.conf "${NEXUS_NGINX_SITE}.port"
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
}

nexus_start_service() {
    local listen_port="${1:-7900}"
    local nginx_was_running=false
    # 检测端口冲突
    if ss -tlnp 2>/dev/null | grep -q ":${listen_port} "; then
        local occupant=""
        occupant=$(ss -tlnp 2>/dev/null | grep ":${listen_port} " | awk '{print $NF}' | head -1)
        if echo "$occupant" | grep -q "nginx"; then echo -e "${GREEN}端口 ${listen_port} 由 Nginx 对外服务 ✓${RESET}"; else echo -e "${YELLOW}端口 ${listen_port} 已被占用：${occupant}${RESET}"; fi
        if echo "$occupant" | grep -q "nginx"; then
            nginx_was_running=true
            systemctl stop nginx 2>/dev/null || true
            sleep 1
            if ss -tlnp 2>/dev/null | grep -q ":${listen_port} "; then
                echo -e "${RED}端口 ${listen_port} 释放失败。${RESET}"
                systemctl start nginx 2>/dev/null || true
                return 1
            fi
        else
            echo -e "${RED}拒绝强制终止占用进程；请先释放端口 ${listen_port} 后重试。${RESET}"
            return 1
        fi
    fi

    nexus_write_service || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable rr-nexus >/dev/null 2>&1 || return 1

    # 停止 Nginx 释放端口（如果有冲突）
    systemctl is-active --quiet nginx 2>/dev/null && { nginx_was_running=true; systemctl stop nginx 2>/dev/null || true; sleep 1; }

    # 启动 Nexus，最多重试 3 次
    local retry=0
    while [ $retry -lt 3 ]; do
        systemctl restart rr-nexus >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet rr-nexus; then
            break
        fi
        retry=$((retry + 1))
        [ $retry -lt 3 ] && echo -e "${YELLOW}Nexus 启动失败，第 ${retry} 次重试……${RESET}"
    done

    # 恢复 Nginx（如果之前停过）
    [ "$nginx_was_running" = true ] && systemctl start nginx 2>/dev/null || true

    if ! systemctl is-active --quiet rr-nexus; then
        echo -e "${RED}Nexus 启动失败。${RESET}"
        return 1
    fi
    echo -e "${GREEN}Nexus 已启动（内部 7900，外部 ${listen_port}）。${RESET}"
    return 0
}

nexus_install() {
    [ -f "$CONFIG_FILE" ] || { echo -e "${RED}请先执行选项 1，建立 RR-vps 基础配置。${RESET}"; sleep 2; return 1; }
    [ -f "$NEXUS_APP" ] || { echo -e "${RED}当前 RR-vps 版本不包含 RR Nexus 文件，请先更新脚本。${RESET}"; sleep 2; return 1; }
    load_config_with_defaults || return 1
    if [ "$INSTALL_COMPLETE" != "true" ]; then
        echo -e "${RED}RR-vps 首次安装尚未完成，请先返回主菜单执行选项 1 修复节点。${RESET}"
        return 1
    fi
    if nexus_is_installed; then
        echo -e "${RED}[拒绝安装] 检测到已安装的 RR Nexus（当前模式: ${YELLOW}$(nexus_mode)${RED}）。${RESET}"
        echo -e "${RED}  请先在本菜单选择 5 卸载旧面板，再重新安装。${RESET}"
        sleep 3
        return 1
    fi
    echo -e "${YELLOW}正在安装 RR Nexus 安全依赖……${RESET}"
    nexus_install_dependencies || return 1
    select_entry_ip || return 1

    echo -e "${CYAN}1. 本地模式（推荐）：仅 127.0.0.1，通过 SSH 隧道访问，不开放管理端口${RESET}"
    echo -e "${CYAN}2. 公网域名模式：域名 + Nginx + Let's Encrypt HTTPS${RESET}"
    echo -e "${CYAN}3. 公网直连模式：无需域名，IP + 自签证书 HTTPS（浏览器会提示警告）${RESET}"
    local choice=""
    while true; do
        read -rp "请选择访问模式 [1-3，默认 1]: " choice
        choice="${choice:-1}"
        [[ "$choice" =~ ^[123]$ ]] && break
        echo -e "${RED}无效选择，请输入 1、2 或 3。${RESET}"
    done
    local port=""
    local stats_port=""
    local domain=""
    local email=""
    # 设备额度采用上下行合计；服务器套餐的双向/单向计费在面板内独立设置。
    local traffic_mode_val="both"
    if [ "$choice" = "2" ]; then
        echo -e "${YELLOW}[建议] 域名模式推荐用 443 作为面板端口：访问网址无需带端口号，证书续签也更省事。${RESET}"
        echo -e "${YELLOW}        如果 443 已留给节点协议使用，可填写其他可用端口（面板将使用 HTTPS 独立端口）。${RESET}"
        port=$(nexus_choose_port 443) || return 1
    else
        port=$(nexus_choose_port) || return 1
    fi
    stats_port=$(nexus_choose_stats_port "$port") || return 1
    case "$choice" in
        1)
            nexus_write_config local "" "$port" "$stats_port" "$ENTRY_IP_RAW" "$traffic_mode_val" || return 1
            nexus_remove_public_proxy
            ;;
        2)
            nexus_remove_public_proxy
            while true; do
                read -rp "面板域名（例如 panel.example.com）: " domain
                [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] && break
                echo -e "${RED}域名格式无效。${RESET}"
            done
            echo -e "${YELLOW}正在检测 DNS 解析……${RESET}"
            local resolved_ip=""
            resolved_ip=$(dig +short "${domain,,}" A 2>/dev/null | tail -1)
            [ -z "$resolved_ip" ] && resolved_ip=$(nslookup "${domain,,}" 2>/dev/null | awk "/^Address: / {print \$2}" | tail -1)
            if [ -n "$resolved_ip" ] && [ "$resolved_ip" != "$ENTRY_IP_RAW" ]; then
                echo -e "${RED}[警告] ${domain} 解析到 ${resolved_ip}，本服务器 IP 为 ${ENTRY_IP_RAW}。${RESET}"
                read -rp "确认解析正确并已生效？输入 YES 继续: " confirm
                [[ "$confirm" != "YES" ]] && { echo -e "${RED}已取消。${RESET}"; return 1; }
            elif [ -z "$resolved_ip" ]; then
                echo -e "${YELLOW}无法检测 DNS，请确认域名已指向本服务器 IP。${RESET}"
                read -rp "已确认？输入 YES 继续: " confirm
                [[ "$confirm" != "YES" ]] && { echo -e "${RED}已取消。${RESET}"; return 1; }
            else
                echo -e "${GREEN}DNS 解析正确: ${domain} -> ${resolved_ip}${RESET}"
            fi
            while true; do
                read -rp "Let's Encrypt 通知邮箱: " email
                [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
                echo -e "${RED}邮箱格式无效。${RESET}"
            done
            nexus_write_config public "${domain,,}" "$port" "$stats_port" "$ENTRY_IP_RAW" "$traffic_mode_val" || return 1
            nexus_enable_public_https "${domain,,}" "$email" "$port" || return 1
            ;;
                3)
            nexus_remove_public_proxy
            nexus_write_config public "$ENTRY_IP_RAW" "$port" "$stats_port" "$ENTRY_IP_RAW" "$traffic_mode_val" || return 1
            # B4/E12：直连模式面板端口防火墙放行（与订阅端口放行同模式）。
            # 默认 DROP 策略的机器上不加此规则面板公网不可达。
            open_protocol_firewall "$port" "tcp"
            local ngx_port=""
            ngx_port=$(jq -r ".public_port // 7900" "$NEXUS_CONFIG_FILE" 2>/dev/null || echo "$port")
            
            echo -e "${YELLOW}正在配置 IP 直连 HTTPS（自签证书）……${RESET}"
            local cert_dir="/etc/rr-nexus/certs"
            mkdir -p "$cert_dir"
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048                 -keyout "$cert_dir/ip.key" -out "$cert_dir/ip.crt"                 -subj "/CN=${ENTRY_IP_RAW}" -addext "subjectAltName=IP:${ENTRY_IP_RAW}" 2>/dev/null || {
                echo -e "${RED}[失败] 自签证书生成失败。${RESET}"
                return 1
            }
            chmod 600 "$cert_dir/ip.key" "$cert_dir/ip.crt"
            apt-get install -y nginx libnginx-mod-stream >/dev/null 2>&1 || true

            # 生成 HTTP 反代配置
            cat > /etc/nginx/sites-available/rr-nexus-ip.conf <<NGXEOF
server {
    listen 80;
    listen PORT_PLACEHOLDER ssl;
    ssl_certificate ${cert_dir}/ip.crt;
    ssl_certificate_key ${cert_dir}/ip.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGXEOF
            sed -i "s/PORT_PLACEHOLDER/${ngx_port}/g" /etc/nginx/sites-available/rr-nexus-ip.conf

            # 443 被占用时走独立端口，不搞 SNI 分流
            local need_sni=false
            if ss -tlnp 2>/dev/null | grep -q ":443 "; then
                echo -e "${YELLOW}[提示] 443 被占用，面板将使用独立端口 ${ngx_port}。${RESET}"
                need_sni=false
            fi

            if [ "$need_sni" = true ]; then
                # === SNI 分流模式 ===
                # 1. 修改 sing-box 监听从 *:443 到 127.0.0.1:8443
                local sb_config="/etc/sing-box/config.json"
                local sb_backup="/etc/sing-box/config.json.bak.nx.$(date +%s)"
                if [ -f "$sb_config" ]; then
                    cp "$sb_config" "$sb_backup" || return 1
                    # 替换 VLESS Reality listen
                    local tmp_sb=""
                    tmp_sb=$(mktemp /tmp/sb-config-nx.XXXXXX) || return 1
                    jq '
                        .inbounds |= map(
                            if (.listen == "::" or .listen == "" or .listen == "0.0.0.0") and (.listen_port == 443) then
                                .listen = "127.0.0.1" | .listen_port = 8443
                            else . end
                        )
                    ' "$sb_config" > "$tmp_sb" 2>/dev/null || {
                        cp "$sb_backup" "$sb_config" 2>/dev/null
                        rm -f "$tmp_sb" "$sb_backup"
                        echo -e "${RED}[失败] sing-box 配置修改失败，原配置已恢复。${RESET}"
                        return 1
                    }
                    mv "$tmp_sb" "$sb_config" || return 1
                    chmod 600 "$sb_config"
                fi

                # 2. Nginx stream SNI 分流接管 443
                [ -z "$(nginx -V 2>&1 | grep stream_module)" ] && apt-get install -y libnginx-mod-stream >/dev/null 2>&1 || true
                sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf 2>/dev/null || true
                sed -i '/^load_module.*stream/d' /etc/nginx/nginx.conf 2>/dev/null || true
                local stream_tmp=""
                local nginx_conf_tmp=""
                stream_tmp=$(mktemp /tmp/rr-nexus-stream.XXXXXX) || return 1
                nginx_conf_tmp=$(mktemp /etc/nginx/.nginx.conf.XXXXXX) || { rm -f "$stream_tmp"; return 1; }
                cat > "$stream_tmp" <<NGXEOF
stream {
    map \$ssl_preread_server_name \$backend {
        ${ENTRY_IP_RAW}  nexus_panel;
        # B5/E14：其余 SNI 走节点上游（修正前 default 也指向 nexus_panel，
        # singbox_node 上游从未被引用——若该分支被启用会将 443 节点流量全导面板）
        default          singbox_node;
    }
    upstream nexus_panel {
        server 127.0.0.1:${ngx_port};
    }
    upstream singbox_node {
        server 127.0.0.1:8443;
    }
    server {
        listen 443;
        listen [::]:443;
        ssl_preread on;
        proxy_pass \$backend;
    }
}
NGXEOF
                if ! python3 - "$stream_tmp" /etc/nginx/nginx.conf "$nginx_conf_tmp" <<'PY'; then
import pathlib
import sys

stream_path, nginx_path, output_path = map(pathlib.Path, sys.argv[1:])
lines = nginx_path.read_text(encoding="utf-8").splitlines(keepends=True)
# Prepend load_module if not present
if not any('load_module' in l and 'stream' in l for l in lines):
    lines.insert(0,'load_module modules/ngx_stream_module.so;\n')
# Insert stream after last }
for i in range(len(lines)-1,-1,-1):
    if '}' in lines[i] and not lines[i].strip().startswith('#'):
        lines.insert(i+1,'\n')
        lines.insert(i+1, stream_path.read_text(encoding="utf-8"))
        break
else:
    raise SystemExit("nginx.conf has no insertion point")
with output_path.open("w", encoding="utf-8") as output:
    output.write(''.join(lines))
PY
                    rm -f "$stream_tmp" "$nginx_conf_tmp"
                    return 1
                fi
                chmod --reference=/etc/nginx/nginx.conf "$nginx_conf_tmp" || { rm -f "$stream_tmp" "$nginx_conf_tmp"; return 1; }
                mv -f "$nginx_conf_tmp" /etc/nginx/nginx.conf || { rm -f "$stream_tmp" "$nginx_conf_tmp"; return 1; }
                rm -f "$stream_tmp"

                echo -e "${CYAN}SNI 分流：面板 IP → Nexus，其他域名 → sing-box${RESET}"
            else
                # === 直连模式（端口不冲突） ===
                sed -i '/^stream {/,/^}/d' /etc/nginx/nginx.conf 2>/dev/null || true
            fi

            rm -f /etc/nginx/sites-enabled/rr-nexus-ip.conf
            ln -sf /etc/nginx/sites-available/rr-nexus-ip.conf /etc/nginx/sites-enabled/rr-nexus-ip.conf
            rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

            # 启动 Nginx
            if ! nginx -t; then
                echo -e "${RED}[失败] Nginx 配置错误。${RESET}"
                [ "$need_sni" = true ] && [ -f "$sb_backup" ] && cp "$sb_backup" "$sb_config" 2>/dev/null
                return 1
            fi
            systemctl stop nginx 2>/dev/null || true
            sleep 1
            systemctl start nginx || { echo -e "${RED}[失败] Nginx 启动失败。${RESET}"; [ "$need_sni" = true ] && [ -f "$sb_backup" ] && cp "$sb_backup" "$sb_config" 2>/dev/null; return 1; }
            sleep 1

            # 重启 sing-box（如果改了配置）
            if [ "$need_sni" = true ] && systemctl is-active --quiet sing-box 2>/dev/null; then
                systemctl restart sing-box 2>/dev/null || true
                sleep 1
                if ! systemctl is-active --quiet sing-box; then
                    echo -e "${RED}[警告] sing-box 重启失败，正在回滚配置……${RESET}"
                    [ -f "$sb_backup" ] && cp "$sb_backup" "$sb_config" 2>/dev/null
                    systemctl restart sing-box 2>/dev/null || true
                fi
            fi
            rm -f "$sb_backup" 2>/dev/null || true
            systemctl enable --now nginx 2>/dev/null || true
            ;;
        *) echo -e "${RED}输入无效，未安装。${RESET}"; return 1 ;;
    esac

    local reset_admin=""
    if [ -f "$NEXUS_DB_FILE" ] && \
       sqlite3 "$NEXUS_DB_FILE" 'SELECT 1 FROM admins LIMIT 1;' 2>/dev/null | grep -q '^1$'; then
        read -rp "检测到原管理员账号，是否同时重置账号、密码与恢复码？[y/N]: " reset_admin
        if [[ "$reset_admin" =~ ^[Yy]$ ]]; then
            nexus_prompt_admin || return 1
        else
            echo -e "${GREEN}已保留原管理员账号、密码、恢复码和设备数据库。${RESET}"
        fi
    else
        nexus_prompt_admin || return 1
    fi
    nexus_enable_traffic_engine || return 1
    generate_nexus_device_subscriptions || return 1
    # Start backend on 7900, Nginx will listen on user port
    nexus_start_service "$port" || return 1
    echo -e "${GREEN}[成功] RR Nexus 已安装并启用。${RESET}"
    if [ "$choice" = "1" ]; then
        nexus_show_local_tutorial 2>/dev/null || true
    elif [ "$choice" = "2" ]; then
        if [ "$port" = "443" ]; then
            echo -e "公网访问：${CYAN}https://${domain,,}${RESET}"
        else
            echo -e "公网访问：${CYAN}https://${domain,,}:${port}${RESET}"
        fi
    else
        local show_ip="$ENTRY_IP_RAW"
        local up=$(jq -r ".public_port // 7900" "$NEXUS_CONFIG_FILE" 2>/dev/null || echo "$port")
        [[ "$show_ip" == *:* ]] && show_ip="[$show_ip]"
        echo -e "公网访问：${GREEN}https://${show_ip}:${up}${RESET}"
        echo -e "${YELLOW}自签证书，浏览器会警告，点击「高级」→「继续访问」即可。${RESET}"
    fi
    echo -e "${YELLOW}面板始终只监听 127.0.0.1；公网访问由 Nginx HTTPS 反向代理。${RESET}"
    local test_url=""
    local reachability_ok=false
    case "$choice" in
        1)
            echo -e "${CYAN}正在检测本机健康端点……${RESET}"
            test_url="http://127.0.0.1:7900/healthz"
            curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
                "$test_url" >/dev/null 2>&1 && reachability_ok=true
            ;;
        2)
            echo -e "${CYAN}正在检测公网域名与证书……${RESET}"
            if [ "$port" = "443" ]; then
                test_url="https://${domain,,}/healthz"
            else
                test_url="https://${domain,,}:${port}/healthz"
            fi
            curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
                "$test_url" >/dev/null 2>&1 && reachability_ok=true
            ;;
        3)
            echo -e "${CYAN}正在检测公网 IP 入口……${RESET}"
            test_url=$(nexus_access_url)
            # 仅自签 IP 模式允许跳过 CA 校验；域名模式必须通过完整 TLS 校验。
            curl --fail --silent --show-error --insecure --connect-timeout 5 --max-time 10 \
                "${test_url%/}/healthz" >/dev/null 2>&1 && reachability_ok=true
            ;;
    esac
    if [ "$reachability_ok" = true ]; then
        echo -e "${GREEN}✓ Nexus 可达，面板可正常访问。${RESET}"
    elif [ "$choice" = "1" ]; then
        echo -e "${YELLOW}⚠ 本机健康检查失败，请运行 rr doctor 查看 Nexus 日志。${RESET}"
    else
        echo -e "${YELLOW}⚠ 面板入口暂不可达，请检查 DNS、证书和上游防火墙。${RESET}"
    fi
    read -rp "按回车键返回……"
    systemctl enable --now nginx 2>/dev/null || true
}

nexus_reset_admin() {
    nexus_is_installed || { echo -e "${RED}RR Nexus 尚未完整安装。${RESET}"; sleep 2; return 1; }
    nexus_prompt_admin || return 1
    systemctl restart rr-nexus >/dev/null 2>&1 || return 1
    read -rp "按回车键返回……"
}

nexus_uninstall() {
    echo -e "${RED}这会关闭 RR Nexus，并删除面板配置；节点协议和主订阅不受影响。${RESET}"
    local confirm=""
    read -rp "确认卸载请输入 y: " confirm
    [ "$confirm" = "y" ] || { echo -e "${YELLOW}已取消卸载。${RESET}"; return 0; }
    systemctl disable --now rr-nexus >/dev/null 2>&1 || true
    rm -f "$NEXUS_SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
    nexus_remove_public_proxy
    # B4/E12：直连模式（公网 + IP 域名）卸载时收回面板端口防火墙放行规则。
    # 仅精确匹配自签 IP 直连模式，避免误删节点/域名模式端口上的同注释规则。
    if [ -f /etc/rr-nexus/nexus.json ] && [ "$(jq -r '.mode // empty' /etc/rr-nexus/nexus.json 2>/dev/null)" = "public" ]; then
        local panel_port="" panel_domain=""
        panel_port=$(jq -r '.public_port // empty' /etc/rr-nexus/nexus.json 2>/dev/null)
        panel_domain=$(jq -r '.domain // empty' /etc/rr-nexus/nexus.json 2>/dev/null)
        if [[ "$panel_domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && is_valid_port "$panel_port"; then
            close_protocol_firewall "$panel_port" "tcp" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf /etc/rr-nexus
    local keep=""
    read -rp "保留设备数据库和独立订阅以便以后恢复？[Y/n]: " keep
    if [[ "${keep:-Y}" =~ ^[Nn]$ ]]; then
        rm -rf "$NEXUS_DATA_DIR"
        echo -e "${YELLOW}设备数据库已删除，无法恢复；Let's Encrypt 证书未自动删除。${RESET}"
    else
        echo -e "${GREEN}设备数据库已保留在 ${NEXUS_DATA_DIR}。${RESET}"
    fi
    echo -e "${GREEN}RR Nexus 已卸载。${RESET}"
    sleep 2
}

nexus_menu() {
    while true; do
        clear
        local installed="${RED}未安装${RESET}"
        local service_state="未运行"
        local mode="未配置"
        if nexus_is_installed; then
            installed="${GREEN}已安装${RESET}"
            mode=$(nexus_mode)
            systemctl is-active --quiet rr-nexus && service_state="${GREEN}运行中${RESET}" || service_state="${RED}已停止${RESET}"
        fi
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              RR Nexus · 星枢管理界面${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " 状态：$installed  |  模式：${YELLOW}${mode}${RESET}  |  服务：$service_state"
        if nexus_is_installed && [ "$mode" = "local" ]; then
            nexus_show_local_tutorial 2>/dev/null || true
        fi
        echo -e " 安全：Argon2id 密码、登录限流、CSRF、HttpOnly 会话、恢复码、审计日志"
        echo -e " 设备：独立凭据、独立协议链接、二维码、启停、到期与实时上下行流量"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "  ${PURPLE}1.${RESET} 安装 / 重新配置访问模式"
        echo -e "  ${PURPLE}2.${RESET} 重置面板登录密码（忘记密码 / 登录被锁定时使用）"
        echo -e "  ${PURPLE}3.${RESET} 查看 RR Nexus 服务日志"
        echo -e "  ${PURPLE}4.${RESET} 重启 RR Nexus"
        echo -e "  ${PURPLE}5.${RESET} 卸载 RR Nexus"
        echo -e "  ${PURPLE}0.${RESET} 返回主菜单"
        read -rp "请选择操作 [0-5]: " nexus_choice
        case "$nexus_choice" in
            1)
                if ! nexus_install; then
                    echo -e "${RED}[失败] RR Nexus 未安装；上方已显示具体原因。${RESET}"
                    read -rp "按回车键返回……"
                fi
                ;;
            2) nexus_reset_admin ;;
            3) journalctl -u rr-nexus -n 80 --no-pager 2>/dev/null || true; read -rp "按回车键返回……" ;;
            4) systemctl restart rr-nexus && echo -e "${GREEN}已重启。${RESET}" || echo -e "${RED}重启失败。${RESET}"; sleep 2 ;;
            5) nexus_uninstall ;;
            0) return ;;
            *) echo "输入无效"; sleep 1 ;;
        esac
    done
}
