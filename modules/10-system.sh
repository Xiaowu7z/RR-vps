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

rr_ufw_installed() {
    command -v ufw >/dev/null 2>&1 || \
        dpkg-query -W -f='${db:Status-Status}\n' ufw 2>/dev/null | grep -qx installed
}

install_deps() {
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '[安全拒绝] 热更新候选迁移不得运行 apt；缺少依赖时将由事务回滚。' >&2
        return 1
    fi
    echo -e "\n${YELLOW}正在更新系统源并安装必要组件 ...${RESET}"
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y || return 1
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
        ca-certificates curl wget jq python3 python3-cryptography sqlite3 openssl iproute2 qrencode dnsutils cron \
        iptables procps tar gzip coreutils util-linux || return 1

    # Debian/Ubuntu 上 iptables-persistent 可能与已有 UFW 互斥并触发 apt
    # 卸载 UFW。保留用户选择的防火墙及其既有规则；UFW 自身负责规则持久化。
    # 只有系统没有 UFW 时才安装 netfilter-persistent 后端。
    if rr_ufw_installed; then
        echo -e "${GREEN}[防火墙] 检测到 UFW，已保留现有 UFW 配置。${RESET}"
    else
        debconf-set-selections 2>/dev/null <<< \
            'iptables-persistent iptables-persistent/autosave_v4 boolean true'
        debconf-set-selections 2>/dev/null <<< \
            'iptables-persistent iptables-persistent/autosave_v6 boolean true'
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
            iptables-persistent || return 1
    fi

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

cloudflared_token_file_supported() {
    local version=""
    command -v cloudflared >/dev/null 2>&1 || return 1
    version=$(cloudflared --version 2>/dev/null | grep -Eo '[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,3}' | head -1) || return 1
    python3 - "$version" <<'PY'
import sys

parts = tuple(int(item) for item in sys.argv[1].split("."))
raise SystemExit(0 if parts >= (2025, 4, 0) else 1)
PY
}

install_cloudflared() {
    cloudflared_token_file_supported && return 0

    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '[安全拒绝] 热更新候选缺少受支持的 Cloudflared；未下载或安装软件包。' >&2
        return 1
    fi

    echo -e "${YELLOW}仅因已选择 Argo，正在下载并安装 Cloudflared ($SYS_ARCH)...${RESET}"
    local cf_tmp_dir=""
    local release_metadata=""
    local release_selection=""
    local release_tag=""
    local asset_url=""
    local expected_sha256=""
    local expected_size=""
    local asset_name="cloudflared-linux-${SYS_ARCH}.deb"
    local release_api="${RR_CLOUDFLARED_RELEASE_API:-https://api.github.com/repos/cloudflare/cloudflared/releases/latest}"
    local -a cf_release_values=()
    cf_tmp_dir=$(mktemp -d /tmp/rr-cloudflared.XXXXXX) || return 1
    release_metadata="$cf_tmp_dir/release.json"
    release_selection="$cf_tmp_dir/selection"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-all-errors \
        --connect-timeout 10 --max-time 60 --max-filesize 5242880 \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        --output "$release_metadata" "$release_api"; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] 无法读取 Cloudflared 官方发布元数据。${RESET}"
        return 1
    fi
    if ! python3 - "$release_metadata" "$asset_name" > "$release_selection" <<'PY'
import json
import re
import sys
import urllib.parse

metadata_path, expected_name = sys.argv[1:]
with open(metadata_path, "r", encoding="utf-8") as release_file:
    release = json.load(release_file)
tag = str(release.get("tag_name", ""))
if release.get("draft") or release.get("prerelease"):
    raise SystemExit("latest cloudflared release is not stable")
if not re.fullmatch(r"20[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,3}", tag):
    raise SystemExit("invalid cloudflared release tag")
if tuple(int(item) for item in tag.split(".")) < (2025, 4, 0):
    raise SystemExit("cloudflared release lacks token-file support")
assets = [item for item in release.get("assets", []) if item.get("name") == expected_name]
if len(assets) != 1:
    raise SystemExit("cloudflared release asset is missing or duplicated")
asset = assets[0]
url = str(asset.get("browser_download_url", ""))
parsed = urllib.parse.urlsplit(url)
expected_path = f"/cloudflare/cloudflared/releases/download/{tag}/{expected_name}"
if parsed.scheme != "https" or parsed.hostname != "github.com" or parsed.path != expected_path:
    raise SystemExit("cloudflared asset URL is not bound to the selected tag")
body = str(release.get("body", ""))
matches = re.findall(
    rf"(?mi)^\s*{re.escape(expected_name)}:\s*([0-9a-f]{{64}})\s*$",
    body,
)
if len(set(matches)) != 1:
    raise SystemExit("cloudflared release checksum is missing or ambiguous")
checksum = matches[0]
api_digest = str(asset.get("digest") or "")
if api_digest and api_digest != f"sha256:{checksum}":
    raise SystemExit("cloudflared API digest disagrees with release checksum")
size = asset.get("size")
if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= 128 * 1024 * 1024:
    raise SystemExit("cloudflared asset size is invalid")
print(tag)
print(url)
print(checksum)
print(size)
PY
    then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared 发布版本、资产或官方 SHA256 元数据无效。${RESET}"
        return 1
    fi
    mapfile -t cf_release_values < "$release_selection"
    if [ "${#cf_release_values[@]}" -ne 4 ]; then
        rm -rf "$cf_tmp_dir"
        return 1
    fi
    release_tag="${cf_release_values[0]}"
    asset_url="${cf_release_values[1]}"
    expected_sha256="${cf_release_values[2]}"
    expected_size="${cf_release_values[3]}"
    if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-all-errors \
        --connect-timeout 10 --max-time 120 --max-filesize "$expected_size" \
        --output "$cf_tmp_dir/cloudflared.deb" \
        "$asset_url"; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 下载失败。${RESET}"
        return 1
    fi
    if [ "$(stat -c '%s' "$cf_tmp_dir/cloudflared.deb" 2>/dev/null || printf 0)" != "$expected_size" ] || \
       ! printf '%s  %s\n' "$expected_sha256" "$cf_tmp_dir/cloudflared.deb" | sha256sum -c - >/dev/null 2>&1 || \
       ! dpkg-deb --info "$cf_tmp_dir/cloudflared.deb" >/dev/null 2>&1; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared ${release_tag} 资产摘要或 DEB 结构校验失败。${RESET}"
        return 1
    fi
    if ! dpkg -i "$cf_tmp_dir/cloudflared.deb" >/dev/null 2>&1; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[失败] Cloudflared 安装失败。${RESET}"
        return 1
    fi
    if ! cloudflared --version 2>/dev/null | grep -Fq "$release_tag" || \
       ! cloudflared_token_file_supported; then
        rm -rf "$cf_tmp_dir"
        echo -e "${RED}[安全拒绝] Cloudflared 安装后的版本与发布元数据不一致。${RESET}"
        return 1
    fi
    rm -rf "$cf_tmp_dir"
}

rr_ufw_backend_state() {
    local status=""
    command -v ufw >/dev/null 2>&1 || return 1
    if status=$(LC_ALL=C ufw status 2>/dev/null); then
        [[ "$status" =~ ^Status:[[:space:]]+active([[:space:]]|$) ]] && return 0
        return 1
    fi
    return 2
}

rr_netfilter_backend_state() {
    local backend="$1"
    command -v "$backend" >/dev/null 2>&1 || return 1
    "$backend" -w 5 -t filter -S INPUT >/dev/null 2>&1 && return 0
    return 2
}

rr_ufw_rule_state() {
    local proto_port="$1" proto_type="$2" action="$3" comment="$4" status=""
    if ! status=$(LC_ALL=C ufw status 2>/dev/null); then
        return 2
    fi
    if printf '%s\n' "$status" | awk -v rule="${proto_port}/${proto_type}" \
        -v action="$action" -v comment="$comment" '
            $1 == rule && toupper($2) == action {
                marker=$0
                if (sub(/^.*#[[:space:]]*/, "", marker) && marker == comment) found=1
            }
            END { exit(found ? 0 : 1) }
        '; then
        return 0
    fi
    return 1
}

rr_netfilter_rule_state() {
    local backend="$1" proto_port="$2" proto_type="$3" comment="$4" target="$5" result=0
    if "$backend" -w 5 -t filter -C INPUT -p "$proto_type" --dport "$proto_port" \
        -m comment --comment "$comment" -j "$target" >/dev/null 2>&1; then
        return 0
    else
        result=$?
    fi
    [ "$result" -eq 1 ] && return 1
    return 2
}

rr_reconcile_ufw_protocol_rule() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local desired_action="" desired_status="" desired_comment=""
    local opposite_action="" opposite_status="" opposite_comment="" state=0 attempts=0
    case "$desired" in
        open)
            desired_action=allow
            desired_status=ALLOW
            desired_comment="$FIREWALL_COMMENT"
            opposite_action=deny
            opposite_status=DENY
            opposite_comment="$FIREWALL_BLOCK_COMMENT"
            ;;
        closed)
            desired_action=deny
            desired_status=DENY
            desired_comment="$FIREWALL_BLOCK_COMMENT"
            opposite_action=allow
            opposite_status=ALLOW
            opposite_comment="$FIREWALL_COMMENT"
            ;;
        *) return 1 ;;
    esac

    while [ "$attempts" -lt 100 ]; do
        if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" "$opposite_comment"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                # UFW only accepts --force for commands that can prompt, such
                # as enable/reset.  Rule add/delete syntax rejects it on the
                # Debian 12 and Ubuntu 22.04/24.04 versions we support.
                ufw delete "$opposite_action" "$proto_port/$proto_type" \
                    comment "$opposite_comment" >/dev/null 2>&1 || return 1
                attempts=$((attempts + 1))
                ;;
            1) break ;;
            *) return 1 ;;
        esac
    done
    [ "$attempts" -lt 100 ] || return 1

    if rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" "$desired_comment"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            ufw "$desired_action" "$proto_port/$proto_type" \
                comment "$desired_comment" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac

    rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" "$desired_comment" || return 1
    if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" "$opposite_comment"; then
        return 1
    else
        state=$?
    fi
    [ "$state" -eq 1 ]
}

rr_reconcile_netfilter_protocol_rule() {
    local backend="$1" proto_port="$2" proto_type="$3" desired="$4"
    local desired_comment="" desired_target="" desired_action=""
    local opposite_comment="" opposite_target="" state=0 attempts=0
    case "$desired" in
        open)
            desired_comment="$FIREWALL_COMMENT"
            desired_target=ACCEPT
            desired_action=-I
            opposite_comment="$FIREWALL_BLOCK_COMMENT"
            opposite_target=DROP
            ;;
        closed)
            desired_comment="$FIREWALL_BLOCK_COMMENT"
            desired_target=DROP
            desired_action=-A
            opposite_comment="$FIREWALL_COMMENT"
            opposite_target=ACCEPT
            ;;
        *) return 1 ;;
    esac

    while [ "$attempts" -lt 100 ]; do
        if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
            "$opposite_comment" "$opposite_target"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                "$backend" -w 5 -t filter -D INPUT -p "$proto_type" --dport "$proto_port" \
                    -m comment --comment "$opposite_comment" -j "$opposite_target" \
                    >/dev/null 2>&1 || return 1
                attempts=$((attempts + 1))
                ;;
            1) break ;;
            *) return 1 ;;
        esac
    done
    [ "$attempts" -lt 100 ] || return 1

    if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$desired_comment" "$desired_target"; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0) ;;
        1)
            "$backend" -w 5 -t filter "$desired_action" INPUT -p "$proto_type" \
                --dport "$proto_port" -m comment --comment "$desired_comment" \
                -j "$desired_target" >/dev/null 2>&1 || return 1
            ;;
        *) return 1 ;;
    esac

    rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$desired_comment" "$desired_target" || return 1
    if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
        "$opposite_comment" "$opposite_target"; then
        return 1
    else
        state=$?
    fi
    [ "$state" -eq 1 ]
}

rr_reconcile_protocol_firewall() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local backend="" state=0 failed=false persist_netfilter=false

    # A release candidate must not insert/reorder INPUT rules or persist a
    # changed ruleset before it commits.  Transaction mode is a strict
    # read-only gate; fresh installs and interactive changes still reconcile.
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        rr_validate_protocol_firewall "$proto_port" "$proto_type" "$desired"
        return $?
    fi

    if rr_ufw_backend_state; then
        state=0
    else
        state=$?
    fi
    case "$state" in
        0)
            if ! rr_reconcile_ufw_protocol_rule "$proto_port" "$proto_type" "$desired"; then
                printf 'UFW 未能写入或验证 RR %s/%s 规则。\n' "$proto_type" "$proto_port" >&2
                failed=true
            fi
            ;;
        1) ;;
        *)
            printf '无法确认 UFW 是否已启用，拒绝静默跳过防火墙变更。\n' >&2
            failed=true
            ;;
    esac

    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            state=0
        else
            state=$?
        fi
        case "$state" in
            0)
                persist_netfilter=true
                if ! rr_reconcile_netfilter_protocol_rule "$backend" "$proto_port" \
                    "$proto_type" "$desired"; then
                    printf '%s 未能写入或验证 RR %s/%s 规则。\n' \
                        "$backend" "$proto_type" "$proto_port" >&2
                    failed=true
                fi
                ;;
            1) ;;
            *)
                printf '%s 已安装但无法读取活动 filter 后端。\n' "$backend" >&2
                failed=true
                ;;
        esac
    done

    if [ "$persist_netfilter" = true ] && ! save_firewall; then
        failed=true
    fi
    [ "$failed" = false ]
}

rr_validate_protocol_firewall() {
    local proto_port="$1" proto_type="$2" desired="$3"
    local backend="" state=0 failed=false
    local desired_comment="" desired_target="" desired_status=""
    local opposite_comment="" opposite_target="" opposite_status=""
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    case "$desired" in
        open)
            desired_comment="$FIREWALL_COMMENT"; desired_target=ACCEPT; desired_status=ALLOW
            opposite_comment="$FIREWALL_BLOCK_COMMENT"; opposite_target=DROP; opposite_status=DENY
            ;;
        closed)
            desired_comment="$FIREWALL_BLOCK_COMMENT"; desired_target=DROP; desired_status=DENY
            opposite_comment="$FIREWALL_COMMENT"; opposite_target=ACCEPT; opposite_status=ALLOW
            ;;
        *) return 1 ;;
    esac

    if rr_ufw_backend_state; then
        rr_ufw_rule_state "$proto_port" "$proto_type" "$desired_status" \
            "$desired_comment" || failed=true
        if rr_ufw_rule_state "$proto_port" "$proto_type" "$opposite_status" \
            "$opposite_comment"; then
            failed=true
        else
            state=$?
            [ "$state" -eq 1 ] || failed=true
        fi
    else
        state=$?
        [ "$state" -eq 1 ] || failed=true
    fi

    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                "$desired_comment" "$desired_target" || failed=true
            if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                "$opposite_comment" "$opposite_target"; then
                failed=true
            else
                state=$?
                [ "$state" -eq 1 ] || failed=true
            fi
        else
            state=$?
            [ "$state" -eq 1 ] || failed=true
        fi
    done

    if [ "$failed" = true ]; then
        printf '热更新只读检查发现 RR 防火墙 %s/%s 规则缺失、冲突或不可读；未修改规则。\n' \
            "$proto_type" "$proto_port" >&2
        return 1
    fi
    return 0
}

rr_local_subscription_loopback_ready() {
    local pid="" state="" argument="" expect_bind=false
    local app_seen=false port_seen=false bind_seen=false
    local proc_root="${RR_PROC_ROOT:-/proc}" cmdline_file=""

    [ "${SUB_ACCESS_MODE:-local}" = local ] || return 1
    is_valid_port "${SUB_PORT:-}" || return 1
    [ -f "${SUB_BIND_STATE_FILE:-}" ] && [ ! -L "${SUB_BIND_STATE_FILE:-}" ] || return 1
    state=$(cat -- "$SUB_BIND_STATE_FILE" 2>/dev/null) || return 1
    case "$state" in
        "${SUB_PORT}|127.0.0.1|local|"*) ;;
        *) return 1 ;;
    esac

    [ -f "${SUB_PID_FILE:-}" ] && [ ! -L "${SUB_PID_FILE:-}" ] || return 1
    pid=$(cat -- "$SUB_PID_FILE" 2>/dev/null) || return 1
    is_subscription_pid "$pid" || return 1
    cmdline_file="${proc_root}/${pid}/cmdline"
    [ -r "$cmdline_file" ] || return 1
    while IFS= read -r -d '' argument; do
        if [ "$expect_bind" = true ]; then
            [ "$argument" = 127.0.0.1 ] && bind_seen=true
            expect_bind=false
            continue
        fi
        case "$argument" in
            */nexus/sub_server.py) app_seen=true ;;
            --bind) expect_bind=true ;;
        esac
        [ "$argument" = "$SUB_PORT" ] && port_seen=true
    done < "$cmdline_file"
    [ "$expect_bind" = false ] && [ "$app_seen" = true ] && \
        [ "$port_seen" = true ] && [ "$bind_seen" = true ]
}

rr_validate_local_subscription_firewall_transition() {
    local proto_port="$1" proto_type="tcp" backend="" state=0
    local closed_state=0 legacy_state=0 failed=false legacy_seen=false

    is_valid_port "$proto_port" || return 1

    # The compatibility exception is deliberately narrower than the generic
    # firewall validator.  Each readable backend must contain either the new
    # exact RR DROP rule or the exact v7.1.0 RR ACCEPT rule -- never an
    # untagged/wrong-port/wrong-protocol allow rule and never both states.
    if rr_ufw_backend_state; then
        if rr_ufw_rule_state "$proto_port" "$proto_type" DENY \
            "$FIREWALL_BLOCK_COMMENT"; then closed_state=0; else closed_state=$?; fi
        if rr_ufw_rule_state "$proto_port" "$proto_type" ALLOW \
            "$FIREWALL_COMMENT"; then legacy_state=0; else legacy_state=$?; fi
        case "${closed_state}:${legacy_state}" in
            0:1) ;;
            1:0) legacy_seen=true ;;
            *) failed=true ;;
        esac
    else
        state=$?
        [ "$state" -eq 1 ] || failed=true
    fi

    for backend in iptables ip6tables; do
        if rr_netfilter_backend_state "$backend"; then
            if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                "$FIREWALL_BLOCK_COMMENT" DROP; then closed_state=0; else closed_state=$?; fi
            if rr_netfilter_rule_state "$backend" "$proto_port" "$proto_type" \
                "$FIREWALL_COMMENT" ACCEPT; then legacy_state=0; else legacy_state=$?; fi
            case "${closed_state}:${legacy_state}" in
                0:1) ;;
                1:0) legacy_seen=true ;;
                *) failed=true ;;
            esac
        else
            state=$?
            [ "$state" -eq 1 ] || failed=true
        fi
    done

    if [ "$failed" = true ]; then
        printf '热更新只读检查拒绝无法精确归属的订阅防火墙规则（tcp/%s）；未修改规则。\n' \
            "$proto_port" >&2
        return 1
    fi
    if [ "$legacy_seen" = true ]; then
        if ! rr_local_subscription_loopback_ready; then
            printf '热更新发现旧版订阅放行规则，但无法证明新订阅服务仅监听 127.0.0.1；拒绝继续。\n' >&2
            return 1
        fi
        RR_FIREWALL_FINALIZE_REQUIRED=true
    fi
    return 0
}

open_firewall() {
    # Argo 模式只监听 127.0.0.1，不占用公网防火墙端口；TLS 直连时才放行。
    if [ "${VM_TLS_ENABLED:-false}" = "true" ]; then
        open_protocol_firewall "$PORT" "tcp" || return 1
    fi
    # Public subscription exposure is decided by its access mode.  Local/SSH
    # mode must never retain an inbound allow rule left by an older release.
    if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
        open_protocol_firewall "$SUB_PORT" "tcp" || return 1
    elif [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        # v7.1.0 always left a precisely tagged public ACCEPT for SUB_PORT.
        # The candidate cannot mutate external firewall state before commit,
        # so accept that one legacy state only while the replacement server is
        # demonstrably loopback-only.  A durable post-commit finalizer removes
        # it; every other closed-port caller remains strict.
        rr_validate_local_subscription_firewall_transition "$SUB_PORT" || return 1
    else
        close_protocol_firewall "$SUB_PORT" "tcp" || return 1
    fi
}

open_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 1
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    rr_reconcile_protocol_firewall "$proto_port" "$proto_type" open
}

close_protocol_firewall() {
    local proto_port="$1"
    local proto_type="$2"
    is_valid_port "$proto_port" || return 0
    case "$proto_type" in tcp|udp) ;; *) return 1 ;; esac
    rr_reconcile_protocol_firewall "$proto_port" "$proto_type" closed
}

open_configured_firewall() {
    load_config_with_defaults || return 1
    open_firewall || return 1
    if [ "${VL_ENABLED:-false}" = true ]; then open_protocol_firewall "$VL_PORT" tcp || return 1; fi
    if [ "${HY2_ENABLED:-false}" = true ]; then open_protocol_firewall "$HY2_PORT" udp || return 1; fi
    if [ "${TU5_ENABLED:-false}" = true ]; then open_protocol_firewall "$TU5_PORT" udp || return 1; fi
    if [ "${AN_ENABLED:-false}" = true ]; then open_protocol_firewall "$AN_PORT" tcp || return 1; fi
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        case "${NAIVE_MODE:-h2}" in
            h2) open_protocol_firewall "$NAIVE_PORT" tcp || return 1 ;;
            h3) open_protocol_firewall "$NAIVE_PORT" udp || return 1 ;;
            both)
                open_protocol_firewall "$NAIVE_PORT" tcp || return 1
                open_protocol_firewall "$NAIVE_PORT" udp || return 1
                ;;
            *) return 1 ;;
        esac
    fi
    if [ -n "${HY2_HOP_PORTS:-}" ] && declare -F install_hop_rules >/dev/null 2>&1; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            declare -F rr_validate_hop_rules >/dev/null 2>&1 || return 1
            rr_validate_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" || return 1
        else
            install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" || return 1
        fi
    fi
    if [ -n "${TU5_HOP_PORTS:-}" ] && declare -F install_hop_rules >/dev/null 2>&1; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            declare -F rr_validate_hop_rules >/dev/null 2>&1 || return 1
            rr_validate_hop_rules TU5 "$TU5_PORT" "$TU5_HOP_PORTS" || return 1
        else
            install_hop_rules TU5 "$TU5_PORT" "$TU5_HOP_PORTS" || return 1
        fi
    fi
    if [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] && \
       [ "$(jq -r '.mode // empty' "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null)" = public ]; then
        local panel_port=""
        panel_port=$(jq -r '.public_port // empty' "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 1
        open_protocol_firewall "$panel_port" tcp || return 1
    fi
    [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] || save_firewall
}

save_firewall() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        if ! netfilter-persistent save >/dev/null 2>&1; then
            printf 'netfilter-persistent 无法持久化 RR 防火墙规则。\n' >&2
            return 1
        fi
    elif command -v service >/dev/null 2>&1 && [ -x /etc/init.d/iptables ]; then
        if ! service iptables save >/dev/null 2>&1; then
            printf 'iptables 服务无法持久化 RR 防火墙规则。\n' >&2
            return 1
        fi
    fi
    return 0
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

ensure_subscription_root() {
    local root_uid=""
    # /tmp 使用 sticky bit 只能保护已经由 root 创建的目录；首次创建前仍可能被
    # 普通用户抢占为目录或符号链接。绝不跟随或接管这类对象，也不自动删除，
    # 以免把攻击者选择的目标变成 root 的递归删除对象。
    if [ -L "$SUB_ROOT" ] || { [ -e "$SUB_ROOT" ] && [ ! -d "$SUB_ROOT" ]; }; then
        echo -e "${RED}[安全拒绝] 订阅目录不是普通目录：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    if [ ! -d "$SUB_ROOT" ]; then
        mkdir -m 700 -- "$SUB_ROOT" 2>/dev/null || true
    fi
    if [ -L "$SUB_ROOT" ] || [ ! -d "$SUB_ROOT" ]; then
        echo -e "${RED}[安全拒绝] 无法安全创建订阅目录：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    root_uid=$(stat -c '%u' -- "$SUB_ROOT" 2>/dev/null) || return 1
    if [ "$root_uid" != 0 ]; then
        echo -e "${RED}[安全拒绝] 订阅目录不属于 root：${SUB_ROOT}${RESET}" >&2
        return 1
    fi
    chmod 700 -- "$SUB_ROOT" || return 1
    # chmod 后再次检查，防止检查与使用之间对象发生变化。
    [ ! -L "$SUB_ROOT" ] && [ -d "$SUB_ROOT" ] && \
        [ "$(stat -c '%u' -- "$SUB_ROOT" 2>/dev/null)" = 0 ]
}

rr_subscription_process_matches() {
    local process_dir="${1:-}"
    local expected_cwd="${2:-}"
    local expected_app="${3:-}"
    local uid_line=""
    local python_name=""
    local port=""
    local process_cwd=""
    local cwd_links=""
    local -a arguments=()

    [ -n "$process_dir" ] && [ -n "$expected_cwd" ] && [ -n "$expected_app" ] || return 1
    [ -r "$process_dir/status" ] && [ -r "$process_dir/cmdline" ] || return 1

    # RR launches this worker as root.  Requiring all four kernel UID fields
    # prevents a user-owned Python process from becoming a kill candidate even
    # if it can imitate the remaining argv/cwd evidence.
    uid_line=$(awk '$1 == "Uid:" { print $2 ":" $3 ":" $4 ":" $5; exit }' \
        "$process_dir/status" 2>/dev/null) || return 1
    [ "$uid_line" = 0:0:0:0 ] || return 1

    # Parse the NUL-delimited argv instead of substring-matching a flattened
    # command line.  The latter could accept an unrelated Python command that
    # merely carries nexus/sub_server.py as data in a later argument.
    mapfile -d '' -t arguments < "$process_dir/cmdline" 2>/dev/null || return 1
    [ "${#arguments[@]}" -ge 3 ] || return 1
    python_name="${arguments[0]##*/}"
    [[ "$python_name" =~ ^python3([.][0-9]+)?$ ]] || return 1
    if [ "${arguments[1]}" = "$expected_app" ]; then
        port="${arguments[2]}"
    elif [ "${#arguments[@]}" -ge 4 ] && [ "${arguments[1]}" = -m ] && \
         [ "${arguments[2]}" = http.server ]; then
        port="${arguments[3]}"
    else
        return 1
    fi
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1

    process_cwd=$(readlink -- "$process_dir/cwd" 2>/dev/null) || return 1
    [ "$process_cwd" = "$expected_cwd" ] && return 0
    [ "$process_cwd" = "${expected_cwd} (deleted)" ] || return 1
    # procfs appends " (deleted)" to an unlinked cwd, but those characters
    # are also legal in a real directory name.  st_nlink==0 proves that the
    # matched inode is actually unlinked and rejects that literal-name trap.
    cwd_links=$(stat -Lc '%h' -- "$process_dir/cwd" 2>/dev/null) || return 1
    [ "$cwd_links" = 0 ]
}

rr_subscription_pid_is_managed() {
    local pid="${1:-}"
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local expected_cwd=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    expected_cwd=$(readlink -f -- "$SUB_ROOT" 2>/dev/null) || return 1
    rr_subscription_process_matches "$proc_root/$pid" "$expected_cwd" \
        "$RR_LIB_DIR/nexus/sub_server.py"
}

is_subscription_pid() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 必须核对进程身份，绝不因陈旧 PID 文件误杀其他服务。
    rr_subscription_pid_is_managed "$pid"
}

managed_subscription_pids() {
    # 状态文件可能因跨版本更新/回滚位于 /run 或旧版 /tmp，甚至已经丢失。
    # 按“受支持命令行 + RR 订阅根 cwd”双重条件扫描 /proc，避免仅凭名称
    # pkill 误伤用户进程，也确保无 PID 文件的 RR 孤儿 worker 仍可回收。
    local proc_root="${RR_PROC_ROOT:-/proc}"
    local process_dir=""
    local pid=""
    for process_dir in "$proc_root"/[0-9]*; do
        pid="${process_dir##*/}"
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        rr_subscription_pid_is_managed "$pid" || continue
        printf '%s\n' "$pid" 2>/dev/null || return 0
    done
}

subscription_server_running() {
    local pid=""
    while IFS= read -r pid; do
        [ -n "$pid" ] && return 0
    done < <(managed_subscription_pids)
    return 1
}

stop_subscription_servers() {
    local pid=""
    local stopped=true
    local attempt=0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        # 扫描后立即复核完整身份，收窄退出/PID 复用窗口。
        rr_subscription_pid_is_managed "$pid" || continue
        kill "$pid" 2>/dev/null || true
    done < <(managed_subscription_pids)
    while [ "$attempt" -lt 20 ] && subscription_server_running; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    subscription_server_running && stopped=false
    rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE" \
        /run/rr-vps-subscription.pid /run/rr-vps-subscription.bind \
        /tmp/sub_server.pid /tmp/sub_server.bind
    [ "$stopped" = true ]
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
    # NAIVE-SUPPORT: H2/TCP 与 H3/UDP 可同端口并存。
    if [ "$NAIVE_ENABLED" = "true" ] && [ "${NAIVE_PORT:-0}" != "0" ]; then
        [ "${NAIVE_MODE:-h2}" != h3 ] && echo "${NAIVE_PORT}:tcp:NaiveProxy H2 节点"
        [ "${NAIVE_MODE:-h2}" != h2 ] && echo "${NAIVE_PORT}:udp:NaiveProxy H3 节点"
    fi
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
    # $1=port $2=proto；0=放行 1=关闭
    # 真实状态：端口实际被监听（节点协议已开启）即视为放行；
    # 防火墙 ACCEPT 规则存在也算放行（任一满足）
    case "$2" in
        tcp) ss -H -ltn "sport = :$1" 2>/dev/null | grep -q LISTEN && return 0 ;;
        udp) ss -H -lun "sport = :$1" 2>/dev/null | grep -qE "UNCONN|ESTAB" && return 0 ;;
    esac
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
