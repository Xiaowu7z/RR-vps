# shellcheck shell=bash
# RR Nexus 可选管理面板、多用户凭据与独立订阅。

NEXUS_CONFIG_FILE="/etc/rr-nexus/nexus.json"
NEXUS_DATA_DIR="/var/lib/rr-nexus"
NEXUS_DB_FILE="${NEXUS_DATA_DIR}/nexus.db"
NEXUS_SUB_ROOT="${NEXUS_DATA_DIR}/subscriptions"
NEXUS_SERVICE_FILE="/etc/systemd/system/rr-nexus.service"
NEXUS_NGINX_SITE="/etc/nginx/sites-available/rr-nexus.conf"
NEXUS_APP="${RR_LIB_DIR}/nexus/rr_nexus.py"
NEXUS_CORE_TARGET_VERSION="1.14.0"
NEXUS_CORE_TARGET_TAG="v${NEXUS_CORE_TARGET_VERSION}"
NEXUS_CORE_SOURCE_COMMIT="0b8995879f29a9b98ee027bc17b75e101445b238"
NEXUS_CORE_UPSTREAM_RELEASE_ID="379452161"
NEXUS_CORE_GO_VERSION="go1.25.5"
NEXUS_CORE_MIN_GO_VERSION="1.25.0"
NEXUS_CORE_EXPECTED_BUILD_TAGS="with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api,with_tailscale,with_ccm,with_ocm,with_cloudflared,with_usbip,with_openvpn,with_openconnect,badlinkname,tfogo_checklinkname0,with_v2ray_api"
NEXUS_CORE_UPSTREAM_API="https://api.github.com/repos/SagerNet/sing-box/releases/tags/${NEXUS_CORE_TARGET_TAG}"
NEXUS_CORE_RELEASE_API="https://api.github.com/repos/${RR_REPOSITORY}/releases/tags"
NEXUS_CORE_RELEASE_REVISION=1
NEXUS_SYNC_LOCK_FILE="${RR_NEXUS_SYNC_LOCK_FILE:-/run/rr-vps/locks/nexus-sync.lock}"
NEXUS_SYNC_LOCK_WAIT_SECONDS="${RR_NEXUS_SYNC_LOCK_WAIT_SECONDS:-300}"

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
    local domain_is_ip=false
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    public_port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    ssh_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    if [ "$mode" = "local" ]; then
        printf 'http://127.0.0.1:%s（SSH 隧道）' "${public_port:-7900}"
        return 0
    fi
    [ "$mode" = "public" ] || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    # 域名模式使用 DNS 证书；IP 模式必须使用配置中的证书身份，
    # 不能跟随可能因入口族或 SSH 教程而变化的 ssh_host。
    if [ -n "$domain" ] && [ "$domain" != "ip" ] && [ "$domain_is_ip" = false ]; then
        if [ "${public_port:-443}" = "443" ]; then
            printf 'https://%s' "$domain"
        else
            printf 'https://%s:%s' "$domain" "${public_port:-443}"
        fi
    else
        local host=""
        host="$domain"
        [ "$host" = ip ] && host="$ssh_host"
        [ -n "$host" ] || return 1
        host="${host#[}"
        host="${host%]}"
        is_ip_version "$host" 6 && host="[$host]"
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
    echo -e "${GREEN}ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L ${tunnel_port}:127.0.0.1:7900 root@${ssh_host}${RESET}"
    echo -e "${YELLOW}2. 首次连接先核对 SSH 主机指纹，再确认写入 known_hosts；不要关闭主机密钥校验。${RESET}"
    echo -e "${YELLOW}3. 输入服务器 root 密码（屏幕不显示字符是正常的安全行为）。${RESET}"
    echo -e "${YELLOW}4. 保持该终端窗口打开，再用浏览器访问：${RESET}${CYAN}http://127.0.0.1:${tunnel_port}${RESET}"
    echo -e "${YELLOW}5. 用完按 Ctrl+C 关闭隧道；终端一关，面板本地访问也会断开。${RESET}"
    echo -e "${CYAN}=================================================================================${RESET}"
}

nexus_core_supports_traffic() {
    [ -x "$SINGBOX_BIN" ] || return 1
    nexus_validate_traffic_core_binary "$SINGBOX_BIN" "$SYS_ARCH"
}

nexus_validate_upstream_core_release() {
    local upstream_file="$1"
    [ -f "$upstream_file" ] && [ ! -L "$upstream_file" ] || return 1
    jq -e --arg tag "$NEXUS_CORE_TARGET_TAG" \
        --argjson release_id "$NEXUS_CORE_UPSTREAM_RELEASE_ID" '
        .id == $release_id and .tag_name == $tag and
        .draft == false and .prerelease == false and .immutable == true and
        .author.login == "github-actions[bot]" and
        .url == ("https://api.github.com/repos/SagerNet/sing-box/releases/" +
            ($release_id | tostring)) and
        .html_url == ("https://github.com/SagerNet/sing-box/releases/tag/" + $tag)
    ' "$upstream_file" >/dev/null || return 1
}

nexus_validate_traffic_core_release() {
    local release_file="$1"
    local upstream_tag="$2"
    local version=""
    local release_tag=""
    local builder_commit=""
    local expected_assets=""
    local asset_base=""
    [ -f "$release_file" ] && [ ! -L "$release_file" ] || return 1
    [ "$upstream_tag" = "$NEXUS_CORE_TARGET_TAG" ] || return 1
    version="$NEXUS_CORE_TARGET_VERSION"
    release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"
    builder_commit=$(jq -r '.target_commitish // empty' "$release_file" 2>/dev/null) || return 1
    [[ "$builder_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    expected_assets=$(jq -cn --arg version "$version" '[
        "BUILD_INFO", "SHA256SUMS",
        "rr-sing-box-\($version)-linux-amd64.tar.gz",
        "rr-sing-box-\($version)-linux-arm64.tar.gz"
    ] | sort') || return 1
    asset_base="https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/"
    jq -e --arg tag "$release_tag" --arg target "$builder_commit" \
        --arg base "$asset_base" --argjson assets "$expected_assets" '
        .tag_name == $tag and .target_commitish == $target and
        .draft == false and .prerelease == false and .immutable == true and
        .author.login == "github-actions[bot]" and
        (.assets | type) == "array" and
        ([.assets[].name] | sort) == $assets and
        all(.assets[];
            (.name | type) == "string" and
            .browser_download_url == ($base + .name) and
            .state == "uploaded" and
            .uploader.login == "github-actions[bot]")
    ' "$release_file" >/dev/null || return 1
}

nexus_fetch_traffic_core_release() {
    local target_file="$1"
    local upstream_file="${target_file}.upstream"
    local upstream_tag=""
    local release_tag=""
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$upstream_file" "$NEXUS_CORE_UPSTREAM_API" || return 1
    nexus_validate_upstream_core_release "$upstream_file" || return 1
    upstream_tag=$(jq -r '.tag_name // empty' "$upstream_file")
    [ "$upstream_tag" = "$NEXUS_CORE_TARGET_TAG" ] || return 1
    release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$target_file" "${NEXUS_CORE_RELEASE_API}/${release_tag}" || {
        rm -f "$target_file"
        return 1
    }
    nexus_validate_traffic_core_release "$target_file" "$upstream_tag"
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

nexus_prepare_sync_lock() {
    local lock_file="$1" lock_dir="" canonical=""
    lock_dir=$(dirname -- "$lock_file") || return 1
    if [ -e "$lock_dir" ] || [ -L "$lock_dir" ]; then
        [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
        [ "$(stat -c %u:%g -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    else
        mkdir -p -- "$lock_dir" || return 1
    fi
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] || return 1
    [ "$(stat -c %u:%g -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    chmod 0700 -- "$lock_dir" || return 1
    [ "$(stat -c %a -- "$lock_dir" 2>/dev/null)" = 700 ] || return 1
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        (umask 077; set -o noclobber; : > "$lock_file") 2>/dev/null || true
    fi
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    [ "$(stat -c %u:%h -- "$lock_file" 2>/dev/null)" = "0:1" ] || return 1
    chown 0:0 -- "$lock_file" || return 1
    chmod 0600 -- "$lock_file" || return 1
    [ "$(stat -c %u:%g:%a:%h -- "$lock_file" 2>/dev/null)" = "0:0:600:1" ]
}

nexus_sync_lock_fd_is_safe() {
    local lock_file="$1" lock_fd="$2" path_identity="" fd_identity=""
    local shell_pid="${BASHPID:-$$}"
    local fd_path="/proc/$shell_pid/fd/$lock_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$lock_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || return 1
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || return 1
    [ "$path_identity" = "$fd_identity" ] && [[ "$fd_identity" == *:0:0:600:1 ]]
}

nexus_with_sync_lock() {
    # The panel, cron worker and health timer are separate processes.  A
    # thread-only lock in rr_nexus.py cannot serialize their config rebuilds.
    local callback="${1:-}"
    shift || true
    declare -F "$callback" >/dev/null 2>&1 || return 2
    if [ "${RR_NEXUS_SYNC_LOCK_HELD:-false}" = true ]; then
        "$callback" "$@"
        return $?
    fi

    local wait_seconds="${NEXUS_SYNC_LOCK_WAIT_SECONDS:-300}"
    local lock_fd=""
    local status=0
    [[ "$wait_seconds" =~ ^[1-9][0-9]{0,3}$ ]] || wait_seconds=300
    nexus_prepare_sync_lock "$NEXUS_SYNC_LOCK_FILE" || return 1
    exec {lock_fd}>>"$NEXUS_SYNC_LOCK_FILE" || return 1
    if ! nexus_sync_lock_fd_is_safe "$NEXUS_SYNC_LOCK_FILE" "$lock_fd"; then
        exec {lock_fd}>&-
        return 1
    fi
    if ! flock -w "$wait_seconds" "$lock_fd"; then
        echo "RR Nexus device sync lock timed out after ${wait_seconds}s" >&2
        exec {lock_fd}>&-
        return 75
    fi

    # Bash locals are dynamically scoped, so nested generation called by the
    # locked sync transaction reuses this lock instead of deadlocking itself.
    local RR_NEXUS_SYNC_LOCK_HELD=true
    "$callback" "$@" || status=$?
    flock -u "$lock_fd" 2>/dev/null || true
    exec {lock_fd}>&-
    return "$status"
}

nexus_atomic_exchange_tree() {
    # Both paths are sibling directories created by this sync.  renameat2's
    # RENAME_EXCHANGE makes the complete generation visible in one operation;
    # the source path then contains the previous generation for rollback.
    local source_dir="$1"
    local target_dir="$2"
    [[ "$source_dir" = "${target_dir}.stage."* ]] || return 1
    [ -d "$source_dir" ] && [ ! -L "$source_dir" ] || return 1
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    python3 - "$source_dir" "$target_dir" <<'PY'
import ctypes
import errno
import os
import sys

source, target = map(os.path.abspath, sys.argv[1:])
if os.path.dirname(source) != os.path.dirname(target):
    raise SystemExit(2)
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    raise SystemExit(3)
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, os.fsencode(source), -100, os.fsencode(target), 2) != 0:
    error = ctypes.get_errno()
    if error in (errno.ENOSYS, errno.EINVAL, errno.EXDEV):
        raise SystemExit(3)
    raise OSError(error, os.strerror(error), target)
directory_fd = os.open(os.path.dirname(target), os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
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

nexus_validate_traffic_core_binary() {
    local binary="$1"
    local expected_arch="${2:-$SYS_ARCH}"
    local version_output=""
    local -a version_lines=()
    [ -f "$binary" ] && [ ! -L "$binary" ] && [ -x "$binary" ] || return 1
    case "$expected_arch" in
        amd64|arm64) ;;
        *) return 1 ;;
    esac
    version_output=$("$binary" version 2>/dev/null) || return 1
    mapfile -t version_lines <<< "$version_output"
    [ "${#version_lines[@]}" -eq 6 ] || return 1
    [ "${version_lines[0]}" = \
        "sing-box version ${NEXUS_CORE_TARGET_VERSION}" ] || return 1
    [ -z "${version_lines[1]}" ] || return 1
    [ "${version_lines[2]}" = \
        "Environment: ${NEXUS_CORE_GO_VERSION} linux/${expected_arch}" ] || return 1
    [ "${version_lines[3]}" = \
        "Tags: ${NEXUS_CORE_EXPECTED_BUILD_TAGS}" ] || return 1
    [ "${version_lines[4]}" = \
        "Revision: ${NEXUS_CORE_SOURCE_COMMIT}" ] || return 1
    [ "${version_lines[5]}" = "CGO: disabled" ] || return 1
    version_ge "${NEXUS_CORE_GO_VERSION#go}" "$NEXUS_CORE_MIN_GO_VERSION"
}

nexus_validate_core_build_info() {
    local build_info="$1"
    local expected_version="$2"
    local expected_release="$3"
    local expected_builder_commit="$4"
    local line=""
    local key=""
    local value=""
    local source_commit=""
    local -A fields=()
    [ -f "$build_info" ] && [ ! -L "$build_info" ] || return 1
    [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    [ "$expected_release" = \
        "rr-nexus-core-v${expected_version}-r${NEXUS_CORE_RELEASE_REVISION}" ] || return 1
    [[ "$expected_builder_commit" =~ ^[0-9a-f]{40}$ ]] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] && [[ "$line" != *$'\r'* ]] && [[ "$line" != *$'\t'* ]] || return 1
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] && [ -n "$value" ] || return 1
        case "$key" in
            SING_BOX_VERSION|SING_BOX_TAG|SOURCE_COMMIT|RR_BUILDER_COMMIT|RR_CORE_RELEASE|GO_VERSION|CGO_ENABLED|BUILD_TAG|BUILD_TAGS|SOURCE) ;;
            *) return 1 ;;
        esac
        [ -z "${fields[$key]+present}" ] || return 1
        fields["$key"]="$value"
    done < "$build_info"

    [ "${#fields[@]}" -eq 10 ] || return 1
    [ "${fields[SING_BOX_VERSION]:-}" = "$expected_version" ] || return 1
    [ "$expected_version" = "$NEXUS_CORE_TARGET_VERSION" ] || return 1
    [ "${fields[SING_BOX_TAG]:-}" = "v${expected_version}" ] || return 1
    source_commit="${fields[SOURCE_COMMIT]:-}"
    [ "$source_commit" = "$NEXUS_CORE_SOURCE_COMMIT" ] || return 1
    [ "${fields[RR_BUILDER_COMMIT]:-}" = "$expected_builder_commit" ] || return 1
    [ "${fields[RR_CORE_RELEASE]:-}" = "$expected_release" ] || return 1
    [ "${fields[GO_VERSION]:-}" = "$NEXUS_CORE_GO_VERSION" ] || return 1
    [ "${fields[CGO_ENABLED]:-}" = 0 ] || return 1
    [ "${fields[BUILD_TAG]:-}" = with_v2ray_api ] || return 1
    [ "${fields[BUILD_TAGS]:-}" = "$NEXUS_CORE_EXPECTED_BUILD_TAGS" ] || return 1
    [ "${fields[SOURCE]:-}" = \
        "https://github.com/SagerNet/sing-box/tree/v${expected_version}" ] || return 1
    version_ge "${fields[GO_VERSION]#go}" "$NEXUS_CORE_MIN_GO_VERSION"
}

nexus_traffic_core_version() {
    local work_dir=""
    local release_json=""
    local build_info=""
    local info_url=""
    local version=""
    local source_tag=""
    local release_tag=""
    local builder_commit=""
    work_dir=$(mktemp -d /tmp/rr-nexus-version.XXXXXX) || return 1
    release_json="$work_dir/release.json"
    build_info="$work_dir/BUILD_INFO"
    if ! nexus_fetch_traffic_core_release "$release_json"; then
        rm -rf "$work_dir"
        return 1
    fi
    release_tag=$(jq -r '.tag_name // empty' "$release_json")
    builder_commit=$(jq -r '.target_commitish // empty' "$release_json")
    source_tag=$(jq -r '.tag_name // empty' "${release_json}.upstream")
    version="${source_tag#v}"
    [ "$version" = "$NEXUS_CORE_TARGET_VERSION" ] || {
        rm -rf "$work_dir"
        return 1
    }
    info_url=$(jq -r '.assets[] | select(.name == "BUILD_INFO") | .browser_download_url' \
        "$release_json" | head -n 1)
    if [ "$info_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/BUILD_INFO" ] || \
       ! curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
           --retry 2 --connect-timeout 8 --max-time 30 \
           -o "$build_info" "$info_url"; then
        rm -rf "$work_dir"
        return 1
    fi
    if ! nexus_validate_core_build_info \
        "$build_info" "$version" "$release_tag" "$builder_commit"; then
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
    printf '%s\n' "$version"
}

nexus_validate_core_checksums() {
    local checksums="$1"
    local expected_version="$2"
    local awk_bin="${RR_AWK_BIN:-awk}"
    [ -f "$checksums" ] || return 1
    [[ "$expected_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    command -v "$awk_bin" >/dev/null 2>&1 || return 1
    # Debian 12 and Ubuntu 22.04 use mawk versions where interval expressions
    # such as {64} are not portable.  Check length separately so a valid
    # digest is accepted by the same default awk users actually run.
    "$awk_bin" -v expected="$expected_version" '
        BEGIN {
            amd64 = "rr-sing-box-" expected "-linux-amd64.tar.gz"
            arm64 = "rr-sing-box-" expected "-linux-arm64.tar.gz"
        }
        /[\r\t]/ || NF != 2 || $0 != ($1 "  " $2) ||
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ ||
        ($2 != amd64 && $2 != arm64) { invalid = 1; exit }
        seen[$2]++ { exit 1 }
        END {
            if (invalid || NR != 2 || seen[amd64] != 1 || seen[arm64] != 1) exit 1
        }
    ' "$checksums"
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
    local actual_size=""
    local version=""
    local source_tag=""
    local builder_commit=""
    local extracted=""
    local actual_version=""

    local release_tag=""
    nexus_fetch_traffic_core_release "$release_json" || return 1
    release_tag=$(jq -r '.tag_name // empty' "$release_json")
    builder_commit=$(jq -r '.target_commitish // empty' "$release_json")
    source_tag=$(jq -r '.tag_name // empty' "${release_json}.upstream")
    version="${source_tag#v}"
    [ "$version" = "$NEXUS_CORE_TARGET_VERSION" ] || return 1
    checksum_url=$(jq -r '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' \
        "$release_json" | head -n 1)
    info_url=$(jq -r '.assets[] | select(.name == "BUILD_INFO") | .browser_download_url' \
        "$release_json" | head -n 1)
    if [ "$checksum_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/SHA256SUMS" ] || \
       [ "$info_url" != "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/BUILD_INFO" ]; then
        return 1
    fi
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 \
        -o "$checksums" "$checksum_url" || return 1
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 \
        -o "$build_info" "$info_url" || return 1
    nexus_validate_core_build_info \
        "$build_info" "$version" "$release_tag" "$builder_commit" || return 1
    nexus_validate_core_checksums "$checksums" "$version" || return 1
    archive_name="rr-sing-box-${version}-linux-${SYS_ARCH}.tar.gz"
    archive_url=$(jq -r --arg name "$archive_name" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "$release_json" | head -n 1)
    [ "$archive_url" = \
        "https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/${archive_name}" ] || return 1
    expected=$(awk -v name="$archive_name" '$2 == name {print $1; exit}' "$checksums")
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 240 --max-filesize 104857600 \
        -o "$work_dir/$archive_name" "$archive_url" || return 1
    actual_size=$(stat -c %s "$work_dir/$archive_name" 2>/dev/null || echo 0)
    [ "$actual_size" -le 104857600 ] || return 1
    actual=$(sha256sum "$work_dir/$archive_name" | awk '{print $1}')
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] || return 1
    extracted="sing-box-${version}-linux-${SYS_ARCH}/sing-box"
    tar -tzf "$work_dir/$archive_name" "$extracted" >/dev/null 2>&1 || return 1
    tar --no-same-owner -xzf "$work_dir/$archive_name" -C "$work_dir" "$extracted" 2>/dev/null || return 1
    [ -f "$work_dir/$extracted" ] && [ ! -L "$work_dir/$extracted" ] && \
        [ "$(stat -c %h "$work_dir/$extracted" 2>/dev/null || echo 0)" -eq 1 ] || return 1
    install -m 755 "$work_dir/$extracted" "$work_dir/sing-box" || return 1
    nexus_validate_traffic_core_binary "$work_dir/sing-box" "$SYS_ARCH" || return 1
    actual_version=$(get_singbox_version "$work_dir/sing-box") || return 1
    [ "$actual_version" = "$version" ] || return 1
    version_ge "$actual_version" "$MIN_SINGBOX_VERSION" || return 1
}

nexus_capture_singbox_file_state() {
    local source="${1:-}"
    local snapshot="${2:-}"
    local output_name="${3:-}"
    local metadata="" mode="" digest="" snapshot_digest=""
    local owner="" group="" links=""
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    if [ ! -e "$source" ] && [ ! -L "$source" ]; then
        printf -v "$output_name" '%s' absent
        return 0
    fi
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$source" 2>/dev/null) || return 1
    IFS=: read -r owner group mode links <<<"$metadata"
    [ "$owner:$group:$links" = 0:0:1 ] && [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    [ ! -e "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    cp -p -- "$source" "$snapshot" || return 1
    sync -f "$snapshot" || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$snapshot" 2>/dev/null)" = \
      "0:0:${mode}:1" ] || return 1
    digest=$(sha256sum "$source" 2>/dev/null | awk '{print $1}') || return 1
    snapshot_digest=$(sha256sum "$snapshot" 2>/dev/null | awk '{print $1}') || \
        return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && [ "$snapshot_digest" = "$digest" ] || \
        return 1
    printf -v "$output_name" 'present:%s:%s' "$digest" "$mode"
}

nexus_restore_singbox_file_state() {
    local snapshot="${1:-}"
    local target="${2:-}"
    local state="${3:-}"
    local target_dir="" directory_mode="" kind="" digest="" mode=""
    local actual_digest="" temporary=""
    [ "$state" = skip ] && return 0
    target_dir=$(dirname -- "$target") || return 1
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$target_dir" 2>/dev/null)" = 0:0 ] || return 1
    directory_mode=$(stat -c %a -- "$target_dir" 2>/dev/null) || return 1
    [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$directory_mode & 8#022)) -eq 0 ] || return 1
    if [ "$state" = absent ]; then
        if [ -e "$target" ] || [ -L "$target" ]; then
            [ ! -d "$target" ] || return 1
            unlink "$target" 2>/dev/null || return 1
        fi
        sync -f "$target_dir" || return 1
        [ ! -e "$target" ] && [ ! -L "$target" ]
        return $?
    fi
    IFS=: read -r kind digest mode <<<"$state"
    [ "$kind" = present ] && [[ "$digest" =~ ^[0-9a-f]{64}$ ]] && \
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$snapshot" 2>/dev/null)" = \
          "0:0:${mode}:1" ] || return 1
    actual_digest=$(sha256sum "$snapshot" 2>/dev/null | awk '{print $1}') || \
        return 1
    [ "$actual_digest" = "$digest" ] || return 1
    temporary=$(mktemp "$target_dir/.nexus-singbox-restore.XXXXXX") || return 1
    if ! cp -p -- "$snapshot" "$temporary" || ! chown 0:0 "$temporary" || \
       ! chmod "$mode" "$temporary" || ! sync -f "$temporary" || \
       ! mv -f -- "$temporary" "$target" || ! sync -f "$target_dir"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 1
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = \
          "0:0:${mode}:1" ] || return 1
    actual_digest=$(sha256sum "$target" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual_digest" = "$digest" ]
}

nexus_singbox_runtime_generation() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local fragment="" pid="" stat_line="" remainder="" starttime=""
    local -a pids=()
    if [ -e "$service_file" ] || [ -L "$service_file" ]; then
        [ -f "$service_file" ] && [ ! -L "$service_file" ] || return 1
        systemctl is-active --quiet sing-box >/dev/null 2>&1 || return 1
        fragment=$(systemctl show --property=FragmentPath --value sing-box.service \
            2>/dev/null) || return 1
        [ "$fragment" = "$service_file" ] || return 1
        pid=$(systemctl show sing-box -p MainPID --value 2>/dev/null) || return 1
    else
        mapfile -t pids < <(managed_singbox_pids) || return 1
        [ "${#pids[@]}" -eq 1 ] || return 1
        pid="${pids[0]}"
    fi
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    is_managed_singbox_pid "$pid" || return 1
    stat_line=$(<"/proc/${pid}/stat") || return 1
    remainder=${stat_line##*) }
    set -- $remainder
    starttime="${20:-}"
    [[ "$starttime" =~ ^[0-9]+$ ]] || return 1
    printf '%s:%s\n' "$pid" "$starttime"
}

nexus_singbox_runtime_is_proved_stopped() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local active_status=0
    managed_singbox_running && return 1
    if [ -e "$service_file" ] || [ -L "$service_file" ]; then
        [ -f "$service_file" ] && [ ! -L "$service_file" ] || return 1
        if systemctl is-active --quiet sing-box >/dev/null 2>&1; then
            return 1
        else
            active_status=$?
        fi
        [ "$active_status" -eq 3 ] || return 1
    fi
    return 0
}

nexus_singbox_runtime_matches_restored_files() {
    local previous_generation="${1:-}"
    local generation="" pid="" executable="" binary_digest="" runtime_digest=""
    generation=$(nexus_singbox_runtime_generation) || return 1
    [ -z "$previous_generation" ] || [ "$generation" != "$previous_generation" ] || \
        return 1
    pid=${generation%%:*}
    executable=$(readlink -- "/proc/${pid}/exe" 2>/dev/null) || return 1
    case "$executable" in
        "$SINGBOX_BIN"|"$SINGBOX_BIN (deleted)") ;;
        *) return 1 ;;
    esac
    [ -f "$SINGBOX_BIN" ] && [ ! -L "$SINGBOX_BIN" ] || return 1
    binary_digest=$(sha256sum "$SINGBOX_BIN" 2>/dev/null | awk '{print $1}') || \
        return 1
    runtime_digest=$(sha256sum "/proc/${pid}/exe" 2>/dev/null | awk '{print $1}') || \
        return 1
    [[ "$binary_digest" =~ ^[0-9a-f]{64}$ ]] && \
        [ "$runtime_digest" = "$binary_digest" ]
}

nexus_restore_singbox_transaction() {
    local binary_snapshot="${1:-}"
    local binary_state="${2:-skip}"
    local config_snapshot="${3:-}"
    local config_state="${4:-skip}"
    local was_running="${5:-false}"
    local context="${6:-Nexus Sing-box 回滚无法证明}"
    local config_target="${NEXUS_SINGBOX_CONFIG_FILE:-/etc/sing-box/config.json}"
    local previous_generation="" runtime_before_known=true
    local restart_status=0
    if [ "$was_running" = true ]; then
        if ! previous_generation=$(nexus_singbox_runtime_generation); then
            previous_generation=""
            nexus_singbox_runtime_is_proved_stopped || runtime_before_known=false
        fi
    fi
    if ! nexus_restore_singbox_file_state "$binary_snapshot" "$SINGBOX_BIN" \
            "$binary_state" || \
       ! nexus_restore_singbox_file_state "$config_snapshot" \
            "$config_target" "$config_state"; then
        nexus_firewall_fail_closed "$context（旧文件恢复失败）"
        return $?
    fi
    if [ "$was_running" = true ]; then
        restart_singbox >/dev/null 2>&1 || restart_status=$?
        if [ "$runtime_before_known" = true ] && \
           nexus_singbox_runtime_matches_restored_files "$previous_generation"; then
            return 0
        fi
        nexus_firewall_fail_closed \
            "$context（回滚重启=${restart_status}，旧运行代无法精确证明）"
        return $?
    fi
    stop_singbox_instances >/dev/null 2>&1 && \
        nexus_singbox_runtime_is_proved_stopped && return 0
    nexus_firewall_fail_closed "$context（原停机态无法恢复）"
}

nexus_enable_traffic_engine() {
    local tx_dir=""
    local was_running=false
    local installed_new_core=false
    local binary_state="" config_state="" rollback_status=0
    tx_dir=$(mktemp -d /tmp/rr-nexus-core.XXXXXX) || return 1
    nexus_capture_singbox_file_state "$SINGBOX_BIN" \
        "$tx_dir/sing-box.previous" binary_state || { rm -rf "$tx_dir"; return 1; }
    nexus_capture_singbox_file_state /etc/sing-box/config.json \
        "$tx_dir/config.previous" config_state || { rm -rf "$tx_dir"; return 1; }
    managed_singbox_running && was_running=true

    if ! nexus_core_supports_traffic; then
        echo -e "${YELLOW}正在安装或升级 RR Nexus 实时流量统计内核至 Sing-box ${NEXUS_CORE_TARGET_VERSION}（官方源码固定提交构建）……${RESET}"
        if ! nexus_download_traffic_core "$tx_dir"; then
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 无法下载或校验 RR Nexus 统计内核。${RESET}"
            return 1
        fi
        install -m 755 "$tx_dir/sing-box" "${SINGBOX_BIN}.new" || { rm -rf "$tx_dir"; return 1; }
        mv -f "${SINGBOX_BIN}.new" "$SINGBOX_BIN" || {
            rm -rf "$tx_dir"
            return 1
        }
        installed_new_core=true
    fi

    if ! build_singbox_config || ! nexus_core_supports_traffic; then
        nexus_restore_singbox_transaction "$tx_dir/sing-box.previous" \
            "$binary_state" "$tx_dir/config.previous" "$config_state" \
            "$was_running" 'Nexus 流量配置校验失败后的 Sing-box 回滚' || \
            rollback_status=$?
        if [ "$rollback_status" -ne 0 ]; then
            printf '[错误] Sing-box 回滚证据保留在 %s。\n' "$tx_dir" >&2
            return "$rollback_status"
        fi
        rm -rf "$tx_dir"
        echo -e "${RED}[失败] 实时流量统计配置未通过 Sing-box 校验，已回滚。${RESET}"
        return 1
    fi
    if [ "$was_running" = true ] && \
       [[ "$SINGBOX_CONFIG_CHANGED" = true || "$installed_new_core" = true ]]; then
        if ! restart_singbox; then
            nexus_restore_singbox_transaction "$tx_dir/sing-box.previous" \
                "$binary_state" "$tx_dir/config.previous" "$config_state" \
                "$was_running" 'Nexus 候选统计内核启动失败后的 Sing-box 回滚' || \
                rollback_status=$?
            if [ "$rollback_status" -ne 0 ]; then
                printf '[错误] Sing-box 回滚证据保留在 %s。\n' "$tx_dir" >&2
                return "$rollback_status"
            fi
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 统计内核启动失败，已恢复原节点内核和配置。${RESET}"
            return 1
        fi
    elif [ "$was_running" != true ] && any_node_protocol_enabled; then
        if ! ensure_node_service_running; then
            nexus_restore_singbox_transaction "$tx_dir/sing-box.previous" \
                "$binary_state" "$tx_dir/config.previous" "$config_state" \
                "$was_running" 'Nexus 候选统计内核首次启动失败后的 Sing-box 回滚' || \
                rollback_status=$?
            if [ "$rollback_status" -ne 0 ]; then
                printf '[错误] Sing-box 回滚证据保留在 %s。\n' "$tx_dir" >&2
                return "$rollback_status"
            fi
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
    nexus_with_sync_lock _generate_nexus_device_subscriptions_staged
}

_generate_nexus_device_subscriptions_staged() {
    local private_target="$NEXUS_SUB_ROOT"
    local published_target="${SUB_ROOT}/nexus"
    local private_stage=""
    local published_stage=""
    [ ! -L "$private_target" ] && [ ! -L "$published_target" ] || return 1
    ensure_subscription_root || return 1
    install -d -m 700 "$NEXUS_DATA_DIR" "$private_target" "$published_target" || return 1
    private_stage=$(mktemp -d "${private_target}.stage.XXXXXX") || return 1
    published_stage=$(mktemp -d "${published_target}.stage.XXXXXX") || {
        rm -rf -- "$private_stage"
        return 1
    }

    if ! NEXUS_SUB_ROOT="$private_stage" RR_NEXUS_PUBLISH_ROOT="$published_stage" \
        _generate_nexus_device_subscriptions_into_stage; then
        rm -rf -- "$private_stage" "$published_stage"
        return 1
    fi
    if ! nexus_atomic_exchange_tree "$private_stage" "$private_target"; then
        rm -rf -- "$private_stage" "$published_stage"
        return 1
    fi
    if ! nexus_atomic_exchange_tree "$published_stage" "$published_target"; then
        # The public tree was not exposed.  Put the private tree back too so a
        # failed two-target publication never reports success with split state.
        nexus_atomic_exchange_tree "$private_stage" "$private_target" >/dev/null 2>&1 || true
        rm -rf -- "$private_stage" "$published_stage"
        return 1
    fi
    # After RENAME_EXCHANGE these paths contain the complete previous trees.
    rm -rf -- "$private_stage" "$published_stage"
    return 0
}

_generate_nexus_device_subscriptions_into_stage() {
    load_config_with_defaults || return 1
    ensure_subscription_root || return 1
    validate_subscription_crypto_material || return 1
    select_entry_ip || return 1
    # 面板进程会在每次打开「链接与二维码」时重读这两个值。这样入口 IP、
    # IPv4/IPv6 或 NAT 公网订阅端口变化后，无需重启面板也不会生成旧二维码。
    nexus_sync_subscription_endpoint || return 1
    install -d -m 700 "$NEXUS_SUB_ROOT" "$RR_NEXUS_PUBLISH_ROOT" || return 1

    local work_dir="$NEXUS_SUB_ROOT/.work"
    local rows_file="$work_dir/devices.tsv"
    local active_file="$work_dir/active.tsv"
    local template_dir="$work_dir/templates"
    local template_uuid="00000000-0000-4000-8000-000000000001"
    local template_alias="RR-NEXUS-TEMPLATE-ALIAS-A1B2C3D4"
    local template_user="rr_nexus_template_user_a1b2c3d4"
    local template_password="rr_nexus_template_password_a1b2c3d4"
    [ "$template_uuid" != "$UUID" ] || template_uuid="00000000-0000-4000-8000-000000000002"
    install -d -m 700 "$work_dir" "$template_dir" || return 1
    : > "$active_file"

    if ! python3 - "$NEXUS_DB_FILE" "${NAIVE_PASS:-}" > "$rows_file" <<'PY'; then
import datetime
import hashlib
import sqlite3
import sys

database, naive_password = sys.argv[1:]
# A writable connection sees committed WAL rows even when a read-only URI is
# opened before SQLite has created the shared-memory sidecar.
connection = sqlite3.connect(database, timeout=5)
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
for device_id, credential, token in connection.execute(
    "SELECT id,credential,subscription_token FROM devices "
    "WHERE enabled=1 "
    "AND (expires_at IS NULL OR expires_at='' OR expires_at>=?) "
    "AND (quota_bytes=0 OR used_bytes<quota_bytes) "
    "ORDER BY created_at",
    (today,),
):
    naive = hashlib.sha256(f"{naive_password}:{device_id}".encode()).hexdigest()[:24]
    print(device_id, credential, token, naive, sep="\t")
connection.close()
PY
        return 1
    fi

    # Full Sing-box and Clash output depends on node settings, but device
    # differences are four scalar values.  Build each format once and perform
    # byte-safe substitutions in one Python pass instead of spawning jq and
    # file utilities thousands of times for 500 devices.
    if declare -F generate_client_json >/dev/null 2>&1 && \
       declare -F generate_clash_yaml >/dev/null 2>&1; then
        RR_CLIENT_UUID_OVERRIDE="$template_uuid" RR_CLIENT_NAME_OVERRIDE="$template_alias" \
            RR_NAIVE_USER_OVERRIDE="$template_user" RR_NAIVE_PASS_OVERRIDE="$template_password" \
            RR_SUB_OUTPUT_DIR="$template_dir" generate_client_json "$ENTRY_IP_RAW" 2>/dev/null || true
        RR_CLIENT_UUID_OVERRIDE="$template_uuid" RR_CLIENT_NAME_OVERRIDE="$template_alias" \
            RR_NAIVE_USER_OVERRIDE="$template_user" RR_NAIVE_PASS_OVERRIDE="$template_password" \
            RR_SUB_OUTPUT_DIR="$template_dir" generate_client_json "$ENTRY_IP_RAW" vless 2>/dev/null || true
        RR_CLIENT_UUID_OVERRIDE="$template_uuid" RR_CLIENT_NAME_OVERRIDE="$template_alias" \
            RR_SUB_OUTPUT_DIR="$template_dir" generate_clash_yaml "$ENTRY_IP_RAW" 2>/dev/null || true
    fi

    local vm_templates="$work_dir/vmess-json.tsv"
    : > "$vm_templates"
    if [ "$VM_ENABLED" != false ]; then
        local vm_json=""
        if [ "$VM_TLS_ENABLED" = true ]; then
            vm_json=$(jq -nc --arg name "VMess · $template_alias" --arg add "$ENTRY_IP_RAW" \
                --arg port "$PORT" --arg id "$template_uuid" --arg path "/${UUID}-vm" \
                '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:"www.bing.com",path:$path,tls:"tls",sni:"www.bing.com",fp:"chrome",allowInsecure:"1",insecure:"1"}') || return 1
            printf '%s\n' "$vm_json" >> "$vm_templates"
        else
            vm_json=$(jq -nc --arg name "VMess Argo · $template_alias" --arg add "$CDN_IP" \
                --arg port "$ARGO_EDGE_PORT" --arg id "$template_uuid" --arg host "$ARGO_DOMAIN" \
                --arg path "/${UUID}-vm" \
                '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:$host,path:$path,tls:"tls",sni:$host,fp:"chrome"}') || return 1
            printf '%s\n' "$vm_json" >> "$vm_templates"
            if [ -s /tmp/sub_server/preferred_cnames.txt ]; then
                local pref_add=""
                local pref_index=1
                while IFS= read -r pref_add; do
                    [ -n "$pref_add" ] || continue
                    vm_json=$(jq -nc --arg name "VMess Argo优选${pref_index} · $template_alias" --arg add "$pref_add" \
                        --arg port "$ARGO_EDGE_PORT" --arg id "$template_uuid" --arg host "$ARGO_DOMAIN" \
                        --arg path "/${UUID}-vm" \
                        '{v:"2",ps:$name,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"",host:$host,path:$path,tls:"tls",sni:$host,fp:"chrome"}') || return 1
                    printf '%s\n' "$vm_json" >> "$vm_templates"
                    pref_index=$((pref_index + 1))
                done < /tmp/sub_server/preferred_cnames.txt
            fi
        fi
    fi

    local hy2_extra=""
    local hy2_hop=""
    if [ "$HY2_ENABLED" = true ] && [ "$HY2_PORT" != 0 ]; then
        hy2_hop=$(get_hop_ports "$HY2_PORT")
        [ -n "$hy2_hop" ] && hy2_extra="&mport=${hy2_hop//:/-}"
    fi
    local device_id=""
    local credential=""
    local sub_token=""
    local ndev_pw=""
    local node_alias=""
    local all_links=""
    local link=""
    while IFS=$'\t' read -r device_id credential sub_token ndev_pw; do
        [[ "$device_id" =~ ^dev_[a-f0-9]{12}$ ]] || continue
        is_valid_uuid "$credential" || continue
        [[ "$sub_token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || sub_token=""
        [[ "$ndev_pw" =~ ^[a-f0-9]{24}$ ]] || return 1
        node_alias="RR-${device_id#dev_}"
        node_alias="${node_alias:0:11}"
        node_alias="${node_alias^^}"
        all_links=""

        while IFS= read -r vm_json; do
            [ -n "$vm_json" ] || continue
            vm_json="${vm_json//$template_uuid/$credential}"
            vm_json="${vm_json//$template_alias/$node_alias}"
            link="RR_NEXUS_VMESS_JSON:${vm_json}"
            all_links="${all_links:+$all_links$'\n'}$link"
        done < "$vm_templates"
        if [ "$VL_ENABLED" = true ] && [ "$VL_PORT" != 0 ]; then
            link="vless://${credential}@${ENTRY_IP_URI}:${VL_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VLESS-${node_alias}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$HY2_ENABLED" = true ] && [ "$HY2_PORT" != 0 ]; then
            link="hysteria2://${credential}@${ENTRY_IP_URI}:${HY2_PORT}?security=tls&alpn=h3&insecure=1&sni=www.bing.com&pinSHA256=${CERT_SHA256}&obfs=salamander&obfs-password=${UUID}${hy2_extra}#HY2-${node_alias}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$TU5_ENABLED" = true ] && [ "$TU5_PORT" != 0 ]; then
            link="tuic://${credential}:${credential}@${ENTRY_IP_URI}:${TU5_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&insecure=1&allow_insecure=1#TUIC-${node_alias}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$AN_ENABLED" = true ] && [ "$AN_PORT" != 0 ]; then
            link="anytls://${credential}@${ENTRY_IP_URI}:${AN_PORT}?sni=www.bing.com&insecure=1#AnyTLS-${node_alias}"
            all_links="${all_links:+$all_links$'\n'}$link"
        fi
        if [ "$NAIVE_ENABLED" = true ] && [ "$NAIVE_PORT" != 0 ]; then
            if [ "${NAIVE_MODE:-h2}" != h3 ]; then
                link="naive+https://${device_id}:${ndev_pw}@${NAIVE_DOMAIN}:${NAIVE_PORT}#RR-Naive-H2·${node_alias}"
                all_links="${all_links:+$all_links$'\n'}$link"
            fi
            if [ "${NAIVE_MODE:-h2}" != h2 ]; then
                link="naive+quic://${device_id}:${ndev_pw}@${NAIVE_DOMAIN}:${NAIVE_PORT}?congestion_control=${NAIVE_QUIC_CC:-bbr}#RR-Naive-H3·${node_alias}"
                all_links="${all_links:+$all_links$'\n'}$link"
            fi
        fi
        printf '%s\n' "$all_links" > "$NEXUS_SUB_ROOT/${device_id}.txt" || return 1
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "$device_id" "$credential" "$sub_token" "$node_alias" "$ndev_pw" >> "$active_file"
    done < "$rows_file"

    if ! python3 - "$active_file" "$NEXUS_SUB_ROOT" "$RR_NEXUS_PUBLISH_ROOT" \
        "$template_dir" "$template_uuid" "$template_alias" "$template_user" "$template_password" <<'PY'; then
import base64
import os
from pathlib import Path
import re
import shutil
import sys

active_path, private_raw, public_raw, template_raw, *placeholder_raw = sys.argv[1:]
private_root = Path(private_raw)
public_root = Path(public_raw)
template_root = Path(template_raw)
placeholders = [value.encode() for value in placeholder_raw]
device_re = re.compile(r"dev_[a-f0-9]{12}\Z")
token_re = re.compile(r"[A-Za-z0-9_-]{16,128}\Z")

def write(path: Path, content: bytes) -> None:
    with path.open("wb") as output:
        output.write(content)
    path.chmod(0o600)

templates = {}
for source_name, suffix in (
    ("client.json", ".json"),
    ("client-vl.json", "-vl.json"),
    ("clash_meta.yaml", ".yaml"),
):
    source = template_root / source_name
    if source.is_file():
        templates[suffix] = source.read_bytes()

suffixes = (
    ".txt", ".json", ".yaml", "-vl.json", "-mihomo.yaml",
    "-clash-verge.yaml", "-flclash.yaml", "-v2rayn.txt",
    "-v2rayng.txt", "-sr.txt", "-nekobox.txt",
)
with open(active_path, encoding="utf-8") as active:
    for line in active:
        device_id, credential, token, alias, naive_password = line.rstrip("\n").split("\t")
        if not device_re.fullmatch(device_id):
            raise ValueError("invalid device id in staged sync")
        raw_path = private_root / f"{device_id}.txt"
        converted = []
        for raw_line in raw_path.read_bytes().splitlines():
            marker = b"RR_NEXUS_VMESS_JSON:"
            if raw_line.startswith(marker):
                raw_line = b"vmess://" + base64.b64encode(raw_line[len(marker):])
            converted.append(raw_line)
        raw = b"\n".join(converted) + b"\n"
        write(raw_path, raw)

        replacements = [credential.encode(), alias.encode(), device_id.encode(), naive_password.encode()]
        for suffix, template in templates.items():
            rendered = template
            for old, new in zip(placeholders, replacements):
                rendered = rendered.replace(old, new)
            write(private_root / f"{device_id}{suffix}", rendered)

        encoded = base64.b64encode(raw)
        for suffix in ("-v2rayn.txt", "-v2rayng.txt", "-sr.txt", "-nekobox.txt"):
            write(private_root / f"{device_id}{suffix}", encoded)
        yaml_path = private_root / f"{device_id}.yaml"
        if yaml_path.is_file():
            yaml = yaml_path.read_bytes()
            for suffix in ("-mihomo.yaml", "-clash-verge.yaml", "-flclash.yaml"):
                write(private_root / f"{device_id}{suffix}", yaml)

        if token and token_re.fullmatch(token):
            for suffix in suffixes:
                source = private_root / f"{device_id}{suffix}"
                if source.is_file():
                    write(public_root / f"{token}{suffix}", source.read_bytes())

write(public_root / "index.html", b"")
PY
        return 1
    fi
    rm -rf -- "$work_dir"
    return 0
}

sync_nexus_devices() {
    nexus_with_sync_lock _sync_nexus_devices_locked
}

_sync_nexus_devices_locked() {
    [ -f "$CONFIG_FILE" ] || return 1
    load_config_with_defaults || return 1
    # QueryStats(reset=true) flushes the current per-user delta before a
    # configuration restart, minimizing the otherwise unavoidable reload gap.
    nexus_collect_traffic_once >/dev/null 2>&1 || true
    local snapshot_dir=""
    local snapshot=""
    local config_state=""
    local was_running=false
    local config_changed=false
    local rollback_status=0
    snapshot_dir=$(mktemp -d /tmp/rr-nexus-singbox.XXXXXX) || return 1
    snapshot="$snapshot_dir/config.previous"
    nexus_capture_singbox_file_state /etc/sing-box/config.json "$snapshot" \
        config_state || { rm -rf "$snapshot_dir"; return 1; }
    managed_singbox_running && was_running=true

    if ! build_singbox_config; then
        nexus_restore_singbox_transaction "" skip "$snapshot" "$config_state" \
            "$was_running" 'Nexus 设备同步配置构建失败后的 Sing-box 回滚' || \
            rollback_status=$?
        if [ "$rollback_status" -ne 0 ]; then
            printf '[错误] Sing-box 回滚证据保留在 %s。\n' "$snapshot_dir" >&2
            return "$rollback_status"
        fi
        rm -rf "$snapshot_dir"
        return 1
    fi
    [ "$SINGBOX_CONFIG_CHANGED" = true ] && config_changed=true
    if [ "$SINGBOX_CONFIG_CHANGED" = true ] && [ "$was_running" = true ] && any_node_protocol_enabled; then
        if ! restart_singbox; then
            nexus_restore_singbox_transaction "" skip "$snapshot" \
                "$config_state" "$was_running" \
                'Nexus 设备同步候选重启失败后的 Sing-box 回滚' || \
                rollback_status=$?
            if [ "$rollback_status" -ne 0 ]; then
                printf '[错误] Sing-box 回滚证据保留在 %s。\n' \
                    "$snapshot_dir" >&2
                return "$rollback_status"
            fi
            rm -rf "$snapshot_dir"
            return 1
        fi
    fi
    if ! generate_nexus_device_subscriptions; then
        # A subscription-only failure must not bounce an unchanged node.  Only
        # roll back/restart when this transaction actually installed a new
        # Sing-box config (normally because the effective user list changed).
        if [ "$config_changed" = true ]; then
            nexus_restore_singbox_transaction "" skip "$snapshot" \
                "$config_state" "$was_running" \
                'Nexus 订阅发布失败后的 Sing-box 回滚' || \
                rollback_status=$?
            if [ "$rollback_status" -ne 0 ]; then
                printf '[错误] Sing-box 回滚证据保留在 %s。\n' \
                    "$snapshot_dir" >&2
                return "$rollback_status"
            fi
        fi
        rm -rf "$snapshot_dir"
        return 1
    fi
    rm -rf "$snapshot_dir"
    return 0
}

NEXUS_GRPCIO_MIN_VERSION="1.43.0"
NEXUS_GRPCIO_PIP_VERSION="1.83.0"
NEXUS_TYPING_EXTENSIONS_PIP_VERSION="4.12.2"
NEXUS_PYPI_API_ROOT="https://pypi.org/pypi"
NEXUS_PYPI_FILES_HOST="files.pythonhosted.org"
NEXUS_PYPI_METADATA_MAX_BYTES=5242880
NEXUS_PYPI_WHEEL_MAX_BYTES=134217728

nexus_system_python() {
    env -u PYTHONHOME -u PYTHONPATH python3 -I "$@"
}

nexus_python_pip() {
    nexus_system_python -m pip "$@"
}

nexus_version_is_numeric() {
    nexus_system_python - "$1" <<'PY'
import re
import sys

raise SystemExit(0 if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", sys.argv[1]) else 1)
PY
}

nexus_version_at_least() {
    nexus_system_python - "$1" "$2" <<'PY'
import re
import sys

values = sys.argv[1:]
if not all(re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value) for value in values):
    raise SystemExit(2)
parts = [[int(part) for part in value.split(".")] for value in values]
width = max(map(len, parts))
parts = [part + [0] * (width - len(part)) for part in parts]
raise SystemExit(0 if parts[0] >= parts[1] else 1)
PY
}

nexus_grpc_installed_version() {
    nexus_system_python - <<'PY'
import re

try:
    import grpc
except Exception:
    raise SystemExit(1)
value = getattr(grpc, "__version__", "")
if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
    raise SystemExit(1)
print(value)
PY
}

nexus_typing_extensions_installed_version() {
    nexus_system_python - <<'PY'
import re
from importlib import metadata

try:
    import typing_extensions
    value = metadata.version("typing_extensions")
except Exception:
    raise SystemExit(1)
if not hasattr(typing_extensions, "Self") or not hasattr(typing_extensions, "override"):
    raise SystemExit(1)
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", value):
    raise SystemExit(1)
print(value)
PY
}

nexus_current_python_abi() {
    nexus_system_python - <<'PY'
import sys

if sys.implementation.name != "cpython":
    raise SystemExit(1)
print(f"cp{sys.version_info.major}{sys.version_info.minor}")
PY
}

nexus_current_wheel_arch() {
    local machine=""
    machine=$(uname -m) || return 1
    case "$machine" in
        x86_64|amd64) printf '%s\n' x86_64 ;;
        aarch64|arm64) printf '%s\n' aarch64 ;;
        *)
            echo "Unsupported grpcio wheel architecture: $machine" >&2
            return 1
            ;;
    esac
}

nexus_pypi_fetch() {
    local url="$1"
    local output_file="$2"
    local max_bytes="$3"
    [[ "$max_bytes" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    curl --fail --silent --show-error \
        --proto '=https' --tlsv1.2 \
        --retry 4 --retry-all-errors --retry-delay 2 --retry-max-time 300 \
        --connect-timeout 10 --max-time 180 --max-filesize "$max_bytes" \
        -H 'User-Agent: RR-vps Nexus dependency installer' \
        --output "$output_file" "$url"
}

nexus_resolve_pypi_wheel() {
    local metadata_file="$1"
    local package="$2"
    local expected_version="$3"
    local python_abi="$4"
    local wheel_arch="$5"
    nexus_system_python - "$metadata_file" "$package" "$expected_version" \
        "$python_abi" "$wheel_arch" "$NEXUS_PYPI_FILES_HOST" <<'PY'
import json
import re
import sys
from urllib.parse import urlsplit

metadata_path, package, expected_version, python_abi, wheel_arch, files_host = sys.argv[1:]


def reject(message):
    print(f"Invalid PyPI metadata: {message}", file=sys.stderr)
    raise SystemExit(1)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


if package not in {"grpcio", "typing_extensions"}:
    reject("unexpected package")
if not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", expected_version):
    reject("unexpected version")
if package == "grpcio":
    if not re.fullmatch(r"cp[0-9]+", python_abi):
        reject("unexpected Python ABI")
    if wheel_arch not in {"x86_64", "aarch64"}:
        reject("unsupported architecture")

try:
    with open(metadata_path, "r", encoding="utf-8") as metadata_stream:
        metadata = json.load(metadata_stream, object_pairs_hook=unique_object)
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    reject(str(error))

if not isinstance(metadata, dict):
    reject("root is not an object")
info = metadata.get("info")
members = metadata.get("urls")
metadata_name = info.get("name") if isinstance(info, dict) else None
canonical_name = lambda value: re.sub(r"[-_.]+", "-", value).lower()
if (
    not isinstance(metadata_name, str)
    or canonical_name(metadata_name) != canonical_name(package)
):
    reject("package name mismatch")
if info.get("version") != expected_version:
    reject("release version mismatch")
if not isinstance(members, list) or not members or len(members) > 512:
    reject("invalid release member list")

seen_filenames = set()
seen_urls = set()
candidates = []
for member in members:
    if not isinstance(member, dict):
        reject("release member is not an object")
    filename = member.get("filename")
    url = member.get("url")
    if not isinstance(filename, str) or not re.fullmatch(r"[A-Za-z0-9._+-]+", filename):
        reject("invalid member filename")
    if not isinstance(url, str):
        reject("invalid member URL")
    if filename in seen_filenames or url in seen_urls:
        reject("duplicate release member")
    seen_filenames.add(filename)
    seen_urls.add(url)

    try:
        parsed = urlsplit(url)
        port = parsed.port
    except ValueError:
        reject("malformed member URL")
    expected_path = rf"/packages/[0-9a-f]{{2}}/[0-9a-f]{{2}}/[0-9a-f]{{60}}/{re.escape(filename)}"
    if (
        parsed.scheme != "https"
        or parsed.hostname != files_host
        or parsed.netloc != files_host
        or port is not None
        or parsed.query
        or parsed.fragment
        or not re.fullmatch(expected_path, parsed.path)
    ):
        reject("member URL is outside the trusted PyPI file host")

    matches = False
    if package == "typing_extensions":
        matches = (
            filename == f"typing_extensions-{expected_version}-py3-none-any.whl"
            and member.get("python_version") == "py3"
        )
    else:
        prefix = f"grpcio-{expected_version}-{python_abi}-{python_abi}-"
        if filename.startswith(prefix) and filename.endswith(".whl"):
            platform = filename[len(prefix):-4]
            allowed_tags = {
                f"manylinux_2_17_{wheel_arch}",
                f"manylinux2014_{wheel_arch}",
            }
            platform_tags = platform.split(".")
            matches = (
                len(platform_tags) == len(set(platform_tags))
                and f"manylinux_2_17_{wheel_arch}" in platform_tags
                and set(platform_tags) <= allowed_tags
                and member.get("python_version") == python_abi
            )
    if not matches:
        continue
    if member.get("packagetype") != "bdist_wheel" or member.get("yanked") is not False:
        reject("matching file is not an active binary wheel")
    digests = member.get("digests")
    digest = digests.get("sha256") if isinstance(digests, dict) else None
    size = member.get("size")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        reject("invalid wheel SHA256")
    if isinstance(size, bool) or not isinstance(size, int) or not 0 < size <= 134217728:
        reject("invalid wheel size")
    candidates.append((filename, url, digest, size))

if len(candidates) != 1:
    reject(f"expected exactly one compatible wheel, found {len(candidates)}")
print(*candidates[0], sep="\n")
PY
}

nexus_pip_install_local_wheel() {
    local wheel_file="$1"
    local pip_help=""
    local -a pip_args=(
        --isolated install --disable-pip-version-check --no-input
        --no-index --no-deps --no-cache-dir --only-binary=:all:
    )
    pip_help=$(PIP_CONFIG_FILE=/dev/null nexus_python_pip --isolated install --help 2>&1) || true
    if [[ "$pip_help" == *"--break-system-packages"* ]]; then
        pip_args+=(--break-system-packages)
    fi
    (
        unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_FIND_LINKS PIP_TARGET PIP_PREFIX
        unset PIP_REQUIRE_VIRTUALENV PIP_CONSTRAINT PIP_BUILD_CONSTRAINT PIP_CACHE_DIR
        export PIP_CONFIG_FILE=/dev/null
        nexus_python_pip "${pip_args[@]}" "$wheel_file"
    )
}

nexus_install_verified_pypi_wheel() (
    local package="$1"
    local expected_version="$2"
    local python_abi="py3"
    local wheel_arch="any"
    local metadata_url=""
    local work_dir=""
    local metadata_file=""
    local resolved=""
    local wheel_name=""
    local wheel_url=""
    local expected_digest=""
    local expected_size=""
    local wheel_file=""
    local actual_digest=""
    local actual_size=""
    local -a wheel_fields=()

    case "$package" in
        grpcio)
            python_abi=$(nexus_current_python_abi) || return 1
            wheel_arch=$(nexus_current_wheel_arch) || return 1
            ;;
        typing_extensions) ;;
        *) return 1 ;;
    esac
    umask 077
    work_dir=$(mktemp -d /tmp/rr-nexus-pypi.XXXXXX) || return 1
    trap 'rm -rf -- "$work_dir"' EXIT
    metadata_file="$work_dir/release.json"
    metadata_url="${NEXUS_PYPI_API_ROOT}/${package}/${expected_version}/json"
    nexus_pypi_fetch "$metadata_url" "$metadata_file" \
        "$NEXUS_PYPI_METADATA_MAX_BYTES" || return 1
    [ -f "$metadata_file" ] && [ ! -L "$metadata_file" ] || return 1
    actual_size=$(stat -c '%s' "$metadata_file") || return 1
    [ "$actual_size" -gt 0 ] && [ "$actual_size" -le "$NEXUS_PYPI_METADATA_MAX_BYTES" ] || return 1
    resolved=$(nexus_resolve_pypi_wheel \
        "$metadata_file" "$package" "$expected_version" "$python_abi" "$wheel_arch") || return 1
    mapfile -t wheel_fields <<< "$resolved"
    [ "${#wheel_fields[@]}" -eq 4 ] || return 1
    wheel_name="${wheel_fields[0]}"
    wheel_url="${wheel_fields[1]}"
    expected_digest="${wheel_fields[2]}"
    expected_size="${wheel_fields[3]}"
    case "$wheel_url" in
        "https://${NEXUS_PYPI_FILES_HOST}/packages/"*) ;;
        *) return 1 ;;
    esac

    wheel_file="$work_dir/$wheel_name"
    nexus_pypi_fetch "$wheel_url" "$wheel_file" \
        "$NEXUS_PYPI_WHEEL_MAX_BYTES" || return 1
    [ -f "$wheel_file" ] && [ ! -L "$wheel_file" ] || return 1
    actual_size=$(stat -c '%s' "$wheel_file") || return 1
    [ "$actual_size" = "$expected_size" ] && \
        [ "$actual_size" -le "$NEXUS_PYPI_WHEEL_MAX_BYTES" ] || return 1
    actual_digest=$(sha256sum "$wheel_file") || return 1
    actual_digest="${actual_digest%% *}"
    if [ "$actual_digest" != "$expected_digest" ]; then
        echo "PyPI wheel SHA256 mismatch for $wheel_name" >&2
        return 1
    fi
    nexus_pip_install_local_wheel "$wheel_file"
)

nexus_ensure_typing_extensions() {
    local installed_version=""
    installed_version=$(nexus_typing_extensions_installed_version 2>/dev/null) || true
    if [ -n "$installed_version" ]; then
        nexus_version_is_numeric "$installed_version" || return 1
        if nexus_version_at_least "$installed_version" 4.12.0 && \
            ! nexus_version_at_least "$installed_version" 5.0.0; then
            return 0
        fi
        if nexus_version_at_least "$installed_version" 5.0.0; then
            echo "Refusing to downgrade typing_extensions $installed_version" >&2
            return 1
        fi
    fi
    nexus_install_verified_pypi_wheel \
        typing_extensions "$NEXUS_TYPING_EXTENSIONS_PIP_VERSION" || return 1
    installed_version=$(nexus_typing_extensions_installed_version 2>/dev/null) || return 1
    [ "$installed_version" = "$NEXUS_TYPING_EXTENSIONS_PIP_VERSION" ]
}

nexus_install_grpcio_pip_fallback() {
    local installed_version=""
    installed_version=$(nexus_grpc_installed_version 2>/dev/null) || true
    if [ -n "$installed_version" ]; then
        nexus_version_is_numeric "$installed_version" || return 1
        if nexus_version_at_least "$installed_version" "$NEXUS_GRPCIO_PIP_VERSION" && \
            [ "$installed_version" != "$NEXUS_GRPCIO_PIP_VERSION" ]; then
            echo "Keeping newer grpcio $installed_version; refusing to downgrade it." >&2
            return 0
        fi
        [ "$installed_version" = "$NEXUS_GRPCIO_PIP_VERSION" ] && return 0
    fi
    nexus_ensure_typing_extensions || return 1
    nexus_install_verified_pypi_wheel grpcio "$NEXUS_GRPCIO_PIP_VERSION" || return 1
    installed_version=$(nexus_grpc_installed_version 2>/dev/null) || return 1
    if [ "$installed_version" != "$NEXUS_GRPCIO_PIP_VERSION" ]; then
        echo "grpcio post-install version mismatch: expected $NEXUS_GRPCIO_PIP_VERSION, got ${installed_version:-missing}" >&2
        return 1
    fi
}

nexus_install_dependencies() {
    local grpcio_version=""
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        nexus_dependencies_available || {
            echo -e "${RED}错误：热更新候选缺少 Nexus 依赖；未运行 apt/pip，事务将回滚。${RESET}" >&2
            return 1
        }
        return 0
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=120 update -y || return 1
    apt-get -o DPkg::Lock::Timeout=120 install -y \
        python3 python3-pip python3-argon2 python3-cryptography \
        python3-typing-extensions qrencode sqlite3 jq || return 1

    # Debian 12 and Ubuntu 24.04 ship a safe grpcio and remain apt-only.  The
    # Ubuntu 22.04 package is 1.41, so it falls through to the verified wheel.
    apt-get -o DPkg::Lock::Timeout=120 install -y python3-grpcio >/dev/null 2>&1 || true
    grpcio_version=$(nexus_grpc_installed_version 2>/dev/null) || true
    if [ -n "$grpcio_version" ]; then
        nexus_version_is_numeric "$grpcio_version" || return 1
        if nexus_version_at_least "$grpcio_version" "$NEXUS_GRPCIO_MIN_VERSION"; then
            return 0
        fi
    fi

    if ! nexus_install_grpcio_pip_fallback; then
        echo -e "${RED}错误：无法安全安装固定版本 grpcio ${NEXUS_GRPCIO_PIP_VERSION}，面板安装中止。${RESET}" >&2
        return 1
    fi
    return 0
}

nexus_dependencies_available() {
    local grpcio_version=""
    local command_name=""
    local PYTHONDONTWRITEBYTECODE=1
    export PYTHONDONTWRITEBYTECODE
    for command_name in python3 qrencode sqlite3 jq; do
        command -v "$command_name" >/dev/null 2>&1 || return 1
    done
    python3 - <<'PY' >/dev/null 2>&1 || return 1
import argon2
import cryptography
import grpc
PY
    grpcio_version=$(nexus_grpc_installed_version 2>/dev/null) || return 1
    nexus_version_is_numeric "$grpcio_version" && \
        nexus_version_at_least "$grpcio_version" "$NEXUS_GRPCIO_MIN_VERSION"
}

nexus_publish_config_candidate() {
    local candidate="${1:-}"
    local target="${2:-$NEXUS_CONFIG_FILE}"
    local target_dir=""
    local target_mode=""
    local expected_hash=""
    local actual_hash=""
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    target_dir=$(dirname -- "$target") || return 1
    [ "$(dirname -- "$candidate")" = "$target_dir" ] || return 1
    [ -d "$target_dir" ] && [ ! -L "$target_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$target_dir" 2>/dev/null)" = 0:0 ] || return 1
    target_mode=$(stat -c %a -- "$target_dir" 2>/dev/null) || return 1
    [[ "$target_mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$target_mode & 8#022)) -eq 0 ] || return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || return 1
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = 0:0:600:1 ] || \
            return 1
    fi
    chmod 600 "$candidate" || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$candidate" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    jq -e 'type == "object"' "$candidate" >/dev/null 2>&1 || return 1
    expected_hash=$(sha256sum "$candidate" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    sync -f "$candidate" || return 1
    mv -f -- "$candidate" "$target" || return 1
    sync -f "$target_dir" || return 1
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    jq -e 'type == "object"' "$target" >/dev/null 2>&1 || return 1
    actual_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual_hash" = "$expected_hash" ]
}

nexus_write_config() {
    local mode="$1"        # local / public
    local domain="$2"      # domain or "ip"
    local user_port="$3"   # user-facing port
    local traffic_mode_val="${6:-both}"
    local backend_port=7900  # backend ALWAYS binds to 7900
    local stats_port="$4"
    local ssh_host="$5"
    local acme_email="${7:-}"
    local certificate_mode="${8:-none}"
    local config_dir=""
    local tmp=""

    config_dir=$(dirname -- "$NEXUS_CONFIG_FILE") || return 1
    install -d -m 700 "$config_dir" || return 1
    install -d -m 700 "$NEXUS_DATA_DIR" "$NEXUS_SUB_ROOT" || return 1
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
  "subscription_access_mode": "__SUB_ACCESS_MODE__",
  "subscription_domain": "__SUB_DOMAIN__",
  "certificate_mode": "__CERTIFICATE_MODE__",
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
    cfg="${cfg//__SUB_ACCESS_MODE__/${SUB_ACCESS_MODE:-local}}"
    cfg="${cfg//__SUB_DOMAIN__/${SUB_DOMAIN:-}}"
    cfg="${cfg//__CERTIFICATE_MODE__/$certificate_mode}"
    cfg="${cfg//__TRAFFIC_MODE__/$traffic_mode_val}"
    if [ -n "$acme_email" ]; then
        cfg=$(jq --arg acme_email "$acme_email" '.acme_email=$acme_email' <<<"$cfg") || return 1
    fi
    tmp=$(mktemp "$config_dir/.nexus.json.XXXXXX") || return 1
    if ! printf '%s\n' "$cfg" > "$tmp" || \
       ! nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
}

nexus_sync_subscription_endpoint() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    [ -n "${ENTRY_IP_RAW:-}" ] || return 1
    is_valid_port "${SUB_URL_PORT:-}" || return 1

    local current_host=""
    local current_port=""
    local current_access_mode=""
    local current_sub_domain=""
    local tmp=""
    current_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    current_port=$(jq -r '.sub_port // 0' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    current_access_mode=$(jq -r '.subscription_access_mode // "local"' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    current_sub_domain=$(jq -r '.subscription_domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    if [ "$current_host" = "$ENTRY_IP_RAW" ] && [ "$current_port" = "$SUB_URL_PORT" ] && \
       [ "$current_access_mode" = "${SUB_ACCESS_MODE:-local}" ] && \
       [ "$current_sub_domain" = "${SUB_DOMAIN:-}" ]; then
        return 0
    fi

    tmp=$(mktemp "$(dirname -- "$NEXUS_CONFIG_FILE")/.nexus-endpoint.XXXXXX") || \
        return 1
    if ! jq --arg ssh_host "$ENTRY_IP_RAW" --argjson sub_port "$SUB_URL_PORT" \
        --arg subscription_access_mode "${SUB_ACCESS_MODE:-local}" \
        --arg subscription_domain "${SUB_DOMAIN:-}" \
        '.ssh_host=$ssh_host | .sub_port=$sub_port |
         .subscription_access_mode=$subscription_access_mode |
         .subscription_domain=$subscription_domain' "$NEXUS_CONFIG_FILE" > "$tmp"; then
        unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
}

nexus_set_certificate_mode() {
    local expected_mode="${1:-}"
    local next_mode="${2:-}"
    local config_dir="" current_mode="" tmp=""
    case "$expected_mode:$next_mode" in
        pending-acme-ip:acme-ip-shortlived|acme-ip-shortlived:pending-acme-ip) ;;
        *) return 1 ;;
    esac
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_CONFIG_FILE" 2>/dev/null)" = 0:0:600:1 ] || return 1
    current_mode=$(jq -r '.certificate_mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    [ "$current_mode" = "$expected_mode" ] || return 1
    config_dir=$(dirname -- "$NEXUS_CONFIG_FILE") || return 1
    tmp=$(mktemp "$config_dir/.nexus-cert-mode.XXXXXX") || return 1
    if ! jq --arg expected "$expected_mode" --arg next "$next_mode" '
        select(.certificate_mode == $expected) |
        .certificate_mode = $next
    ' "$NEXUS_CONFIG_FILE" > "$tmp" || [ ! -s "$tmp" ]; then
        unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    [ "$(jq -r '.certificate_mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)" = "$next_mode" ]
}

nexus_set_ip_certificate_domain() {
    local expected_address="${1:-}" next_address="${2:-}"
    local expected_canonical="" next_canonical="" config_dir="" tmp=""
    declare -F nexus_ip_acme_normalize_address >/dev/null 2>&1 || return 1
    nexus_ip_acme_normalize_address "$expected_address" expected_canonical || \
        return 1
    nexus_ip_acme_normalize_address "$next_address" next_canonical || return 1
    [ "$expected_canonical" = "$next_canonical" ] && \
        [ "$next_address" = "$next_canonical" ] || return 1
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_CONFIG_FILE" 2>/dev/null)" = \
      0:0:600:1 ] || return 1
    config_dir=$(dirname -- "$NEXUS_CONFIG_FILE") || return 1
    tmp=$(mktemp "$config_dir/.nexus-ip-domain.XXXXXX") || return 1
    if ! jq --arg expected "$expected_address" --arg next "$next_address" '
        select(.mode == "public") |
        select(.certificate_mode == "pending-acme-ip" or
               .certificate_mode == "acme-ip-shortlived") |
        select(.domain == $expected) |
        .domain = $next
    ' "$NEXUS_CONFIG_FILE" > "$tmp" || [ ! -s "$tmp" ]; then
        unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    [ "$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)" = \
      "$next_address" ]
}

nexus_migrate_runtime_config() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 1
    local panel_port=""
    local stats_port=""
    local ssh_host=""
    local sub_url_port=""
    local mode=""
    local domain=""
    local domain_is_ip=false
    local certificate_mode=""
    local tmp=""
    panel_port=$(jq -r '.port // 7900' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    is_valid_port "$panel_port" || return 1
    stats_port=$(jq -r '.stats_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    if ! is_valid_port "$stats_port" || [ "$stats_port" = "$panel_port" ]; then
        stats_port=$(nexus_choose_stats_port "$panel_port") || return 1
    fi
    ssh_host=$(jq -r '.ssh_host // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    sub_url_port=$(jq -r '.sub_port // 0' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)
    certificate_mode=$(jq -r '.certificate_mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
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
    tmp=$(mktemp "$(dirname -- "$NEXUS_CONFIG_FILE")/.nexus-migrate.XXXXXX") || \
        return 1
    # Only the historical literal sentinel may be resolved to the current
    # entry address.  A real IP is a certificate SAN and must stay immutable.
    if [ "$mode" = public ] && [ "$domain" = ip ]; then
        domain="$ssh_host"
        is_ip_version "$domain" 4 && domain_is_ip=true
        is_ip_version "$domain" 6 && domain_is_ip=true
    fi
    if [ "$mode" = public ] && [ "$domain_is_ip" = true ]; then
        case "$certificate_mode" in
            acme-ip-shortlived|pending-acme-ip|legacy-self-signed) ;;
            "") certificate_mode=legacy-self-signed ;;
            *) return 1 ;;
        esac
    elif [ "$mode" = public ]; then
        certificate_mode=certbot-domain
    else
        certificate_mode=none
    fi
    if ! jq --argjson stats_port "$stats_port" --arg ssh_host "$ssh_host" --arg domain "$domain" --argjson sub_port "$sub_url_port" \
        --arg subscription_access_mode "${SUB_ACCESS_MODE:-local}" \
        --arg subscription_domain "${SUB_DOMAIN:-}" \
        --arg certificate_mode "$certificate_mode" \
        --arg published_subscription_root "${SUB_ROOT}/nexus" \
        '.listen="127.0.0.1" | .port=7900 | .database="/var/lib/rr-nexus/nexus.db" |
         .subscription_root="/var/lib/rr-nexus/subscriptions" |
         .stats_port=$stats_port | .ssh_host=$ssh_host | .domain=$domain | .sub_port=$sub_port |
         .subscription_access_mode=$subscription_access_mode |
         .subscription_domain=$subscription_domain |
         .certificate_mode=$certificate_mode |
         .published_subscription_root=$published_subscription_root' \
        "$NEXUS_CONFIG_FILE" > "$tmp"; then
        unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! nexus_publish_config_candidate "$tmp" "$NEXUS_CONFIG_FILE"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
}

nexus_emit_service_unit() {
    cat <<EOF
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
}

nexus_service_effective_guards_are_exact() {
    local interval="" burst="" restart_prevent=""
    interval=$(systemctl show rr-nexus.service \
        --property=StartLimitIntervalUSec --value 2>/dev/null) || return 1
    burst=$(systemctl show rr-nexus.service \
        --property=StartLimitBurst --value 2>/dev/null) || return 1
    restart_prevent=$(systemctl show rr-nexus.service \
        --property=RestartPreventExitStatus --value 2>/dev/null) || return 1
    case "$interval" in 5min|300s|300000000us|300000000) ;; *) return 1 ;; esac
    [ "$burst" = 5 ] || return 1
    restart_prevent=$(printf '%s' "$restart_prevent" | tr -d '{}[:space:]') || \
        return 1
    [ "$restart_prevent" = 3 ]
}

nexus_service_effective_identity_is_exact() {
    local load_state="" fragment="" exec_start="" exec_start_pre=""
    local exec_reload="" user="" group="" working_directory=""
    local dynamic_user="" private_network="" root_directory="" root_image=""
    local conditions="" asserts="" dropin_paths="" exec_condition=""
    local service_dir="" service_dir_mode="" canonical="" managed_file=""
    local managed_dir="" managed_dir_mode="" restore_present=false
    local firewall_present=false i=0
    local systemd_root="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}"
    local restore_name="${RR_RESTORE_GATE_DROPIN_NAME:-zzzz-rr-restore-gate.conf}"
    local firewall_name="${RR_RESTORE_FIREWALL_GATE_DROPIN_NAME:-zzzzz-rr-firewall-quarantine.conf}"
    local firewall_marker="${RR_RESTORE_FIREWALL_QUARANTINE_FILE:-/var/lib/rr-vps/firewall-quarantine}"
    local guard_file="${NEXUS_SERVICE_GUARD_DROPIN:-/etc/systemd/system/rr-nexus.service.d/40-rr-nexus-guards.conf}"
    local restore_dropin="$systemd_root/rr-nexus.service.d/$restore_name"
    local firewall_dropin="$systemd_root/rr-nexus.service.d/$firewall_name"
    local restore_argv="/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate"
    local -a expected_dropins=("$guard_file") effective_dropins=()
    [[ "$NEXUS_SERVICE_FILE" = /* && "$NEXUS_SERVICE_FILE" != *[[:space:]]* && \
       "$guard_file" = /* && "$guard_file" != *[[:space:]]* && \
       "$restore_dropin" = /* && "$restore_dropin" != *[[:space:]]* && \
       "$firewall_dropin" = /* && "$firewall_dropin" != *[[:space:]]* && \
       "$firewall_marker" = /* && "$firewall_marker" != *[[:space:]]* ]] || \
        return 1
    [ -f "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_SERVICE_FILE" 2>/dev/null)" = \
          0:0:644:1 ] || return 1
    canonical=$(readlink -f -- "$NEXUS_SERVICE_FILE" 2>/dev/null) || return 1
    [ "$canonical" = "$NEXUS_SERVICE_FILE" ] || return 1
    service_dir=$(dirname -- "$NEXUS_SERVICE_FILE") || return 1
    [ -d "$service_dir" ] && [ ! -L "$service_dir" ] && \
        [ "$(stat -c '%u:%g' -- "$service_dir" 2>/dev/null)" = 0:0 ] || \
        return 1
    service_dir_mode=$(stat -c %a -- "$service_dir" 2>/dev/null) || return 1
    [[ "$service_dir_mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$service_dir_mode & 8#022)) -eq 0 ] || return 1
    cmp -s -- "$NEXUS_SERVICE_FILE" <(nexus_emit_service_unit) || return 1
    for managed_file in "$guard_file" "$restore_dropin" "$firewall_dropin"; do
        if [ "$managed_file" != "$guard_file" ] && \
           [ ! -e "$managed_file" ] && [ ! -L "$managed_file" ]; then
            continue
        fi
        [ -f "$managed_file" ] && [ ! -L "$managed_file" ] && \
            [ "$(stat -c '%u:%g:%a:%h' -- "$managed_file" 2>/dev/null)" = \
              0:0:644:1 ] || return 1
        canonical=$(readlink -f -- "$managed_file" 2>/dev/null) || return 1
        [ "$canonical" = "$managed_file" ] || return 1
        managed_dir=$(dirname -- "$managed_file") || return 1
        [ -d "$managed_dir" ] && [ ! -L "$managed_dir" ] && \
            [ "$(stat -c '%u:%g' -- "$managed_dir" 2>/dev/null)" = 0:0 ] || \
            return 1
        managed_dir_mode=$(stat -c %a -- "$managed_dir" 2>/dev/null) || return 1
        [[ "$managed_dir_mode" =~ ^[0-7]{3,4}$ ]] && \
            [ $((8#$managed_dir_mode & 8#022)) -eq 0 ] || return 1
    done
    cmp -s -- "$guard_file" <(printf '%s\n' \
        '[Unit]' \
        'StartLimitIntervalSec=300' \
        'StartLimitBurst=5' \
        '' \
        '[Service]' \
        'RestartPreventExitStatus=' \
        'RestartPreventExitStatus=3') || return 1
    if [ -e "$restore_dropin" ] || [ -L "$restore_dropin" ]; then
        cmp -s -- "$restore_dropin" <(printf '%s\n' \
            '[Service]' \
            "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'") || \
            return 1
        restore_present=true
        expected_dropins+=("$restore_dropin")
    fi
    if [ -e "$firewall_dropin" ] || [ -L "$firewall_dropin" ]; then
        cmp -s -- "$firewall_dropin" <(printf '%s\n' \
            '[Service]' \
            "ExecCondition=/usr/bin/test ! -e $firewall_marker" \
            "ExecCondition=/usr/bin/test ! -L $firewall_marker") || return 1
        firewall_present=true
        expected_dropins+=("$firewall_dropin")
    fi
    load_state=$(systemctl show rr-nexus.service --property=LoadState --value \
        2>/dev/null) || return 1
    [ "$load_state" = loaded ] || return 1
    fragment=$(systemctl show rr-nexus.service --property=FragmentPath --value \
        2>/dev/null) || return 1
    [ "$fragment" = "$NEXUS_SERVICE_FILE" ] || return 1
    dropin_paths=$(systemctl show rr-nexus.service --property=DropInPaths --value \
        2>/dev/null) || return 1
    read -r -a effective_dropins <<< "$dropin_paths"
    [ "${#effective_dropins[@]}" -eq "${#expected_dropins[@]}" ] || return 1
    for ((i = 0; i < ${#expected_dropins[@]}; i++)); do
        [ "${effective_dropins[i]}" = "${expected_dropins[i]}" ] || return 1
    done
    exec_start=$(systemctl show rr-nexus.service --property=ExecStart --value \
        2>/dev/null) || return 1
    python3 - "$exec_start" "$NEXUS_APP" <<'PY' || return 1
import re
import sys

raw, app = sys.argv[1:]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
if len(matches) != 1 or (raw[:matches[0].start()] + raw[matches[0].end():]).strip():
    raise SystemExit(1)
fields = {}
for item in matches[0].group(1).split(";"):
    item = item.strip()
    if not item:
        continue
    if "=" not in item:
        raise SystemExit(1)
    key, value = item.split("=", 1)
    key = key.strip()
    if key in fields:
        raise SystemExit(1)
    fields[key] = value.strip()
if (
    (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    != ("/usr/bin/python3", f"/usr/bin/python3 {app}", "no")
    or raw.count("path=") != 1
    or raw.count("argv[]=") != 1
    or raw.count("ignore_errors=") != 1
):
    raise SystemExit(1)
PY
    exec_start_pre=$(systemctl show rr-nexus.service \
        --property=ExecStartPre --value 2>/dev/null) || return 1
    exec_reload=$(systemctl show rr-nexus.service --property=ExecReload --value \
        2>/dev/null) || return 1
    [ -z "${exec_start_pre//[[:space:]]/}" ] && \
        [ -z "${exec_reload//[[:space:]]/}" ] || return 1
    user=$(systemctl show rr-nexus.service --property=User --value \
        2>/dev/null) || return 1
    group=$(systemctl show rr-nexus.service --property=Group --value \
        2>/dev/null) || return 1
    working_directory=$(systemctl show rr-nexus.service \
        --property=WorkingDirectory --value 2>/dev/null) || return 1
    dynamic_user=$(systemctl show rr-nexus.service --property=DynamicUser --value \
        2>/dev/null) || return 1
    private_network=$(systemctl show rr-nexus.service \
        --property=PrivateNetwork --value 2>/dev/null) || return 1
    root_directory=$(systemctl show rr-nexus.service \
        --property=RootDirectory --value 2>/dev/null) || return 1
    root_image=$(systemctl show rr-nexus.service --property=RootImage --value \
        2>/dev/null) || return 1
    conditions=$(systemctl show rr-nexus.service --property=Conditions --value \
        2>/dev/null) || return 1
    asserts=$(systemctl show rr-nexus.service --property=Asserts --value \
        2>/dev/null) || return 1
    [ "$user" = root ] && [ "$working_directory" = "${RR_LIB_DIR}/nexus" ] && \
        [ "$dynamic_user" = no ] && [ "$private_network" = no ] && \
        [ -z "${root_directory//[[:space:]]/}" ] && \
        [ -z "${root_image//[[:space:]]/}" ] && \
        [ -z "${conditions//[[:space:]]/}" ] && \
        [ -z "${asserts//[[:space:]]/}" ] || return 1
    # Group= is implicit when User=root on older systemd releases; newer
    # releases may materialize the resolved primary group as `root`.
    case "${group//[[:space:]]/}" in ""|root) ;; *) return 1 ;; esac
    exec_condition=$(systemctl show rr-nexus.service \
        --property=ExecCondition --value 2>/dev/null) || return 1
    python3 - "$exec_condition" "$restore_present" "$restore_argv" \
        "$firewall_present" "$firewall_marker" <<'PY'
import re
import sys

raw, restore_present, restore_argv, firewall_present, marker = sys.argv[1:]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if residual.strip():
    raise SystemExit(1)
records = []
for match in matches:
    fields = {}
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(1)
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
expected = []
if restore_present == "true":
    expected.append(("/bin/sh", restore_argv, "no"))
if firewall_present == "true":
    expected.extend(
        [
            ("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no"),
            ("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no"),
        ]
    )
if (
    records != expected
    or raw.count("{") != len(expected)
    or raw.count("}") != len(expected)
    or raw.count("path=") != len(expected)
    or raw.count("argv[]=") != len(expected)
    or raw.count("ignore_errors=") != len(expected)
):
    raise SystemExit(1)
PY
}

nexus_write_service() {
    local service_dir=""
    local tmp=""
    local expected_hash=""
    local actual_hash=""
    local mode=""
    service_dir=$(dirname -- "$NEXUS_SERVICE_FILE") || return 1
    [ -d "$service_dir" ] && [ ! -L "$service_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$service_dir" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c %a -- "$service_dir" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    if [ -e "$NEXUS_SERVICE_FILE" ] || [ -L "$NEXUS_SERVICE_FILE" ]; then
        [ -f "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] || \
            return 1
        [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_SERVICE_FILE" 2>/dev/null)" = \
          0:0:644:1 ] || return 1
    fi
    tmp=$(mktemp "$service_dir/.rr-nexus.service.XXXXXX") || return 1
    if ! nexus_emit_service_unit > "$tmp" || ! chmod 644 "$tmp"; then
        unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    expected_hash=$(sha256sum "$tmp" 2>/dev/null | awk '{print $1}') || {
        unlink "$tmp" 2>/dev/null || true
        return 1
    }
    if ! sync -f "$tmp" || ! mv -f -- "$tmp" "$NEXUS_SERVICE_FILE" || \
       ! sync -f "$service_dir"; then
        [ -e "$tmp" ] || [ -L "$tmp" ] || tmp=""
        [ -z "$tmp" ] || unlink "$tmp" 2>/dev/null || true
        return 1
    fi
    [ -f "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_SERVICE_FILE" 2>/dev/null)" = \
          0:0:644:1 ] || return 1
    actual_hash=$(sha256sum "$NEXUS_SERVICE_FILE" 2>/dev/null | awk '{print $1}') || \
        return 1
    [ "$actual_hash" = "$expected_hash" ] || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    ensure_nexus_service_guards || return 1
    nexus_service_effective_identity_is_exact && \
        nexus_service_effective_guards_are_exact
}

# T4：为旧版已安装的 rr-nexus 单元幂等补齐 StartLimit 与损坏数据库防重启（退出码 3）。
# 与 ensure_singbox_service_guards 同模式：热更新 post_update_migrate 与健康定时器
# 都会调用，已部署机器无需重装即可获得修复。
ensure_nexus_service_guards() {
    local unit_file="$NEXUS_SERVICE_FILE"
    local guard_file="${NEXUS_SERVICE_GUARD_DROPIN:-/etc/systemd/system/rr-nexus.service.d/40-rr-nexus-guards.conf}"
    local guard_dir=""
    local guard_tmp=""
    local expected_hash=""
    local actual_hash=""
    [ -e "$unit_file" ] || [ -L "$unit_file" ] || return 0
    [ -f "$unit_file" ] && [ ! -L "$unit_file" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$unit_file" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    [[ "$guard_file" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    guard_dir=$(dirname -- "$guard_file") || return 1
    install -d -m 755 "$guard_dir" || return 1
    [ -d "$guard_dir" ] && [ ! -L "$guard_dir" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$guard_dir" 2>/dev/null)" = 0:0:755 ] || \
        return 1
    guard_tmp=$(mktemp "$guard_dir/.rr-nexus-guards.XXXXXX") || return 1
    if ! cat > "$guard_tmp" <<'EOF'
[Unit]
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
RestartPreventExitStatus=
RestartPreventExitStatus=3
EOF
    then
        unlink "$guard_tmp" 2>/dev/null || true
        return 1
    fi
    chmod 644 "$guard_tmp" || {
        unlink "$guard_tmp" 2>/dev/null || true
        return 1
    }
    expected_hash=$(sha256sum "$guard_tmp" 2>/dev/null | awk '{print $1}') || {
        unlink "$guard_tmp" 2>/dev/null || true
        return 1
    }
    sync -f "$guard_tmp" || {
        unlink "$guard_tmp" 2>/dev/null || true
        return 1
    }
    mv -f -- "$guard_tmp" "$guard_file" || {
        [ -e "$guard_tmp" ] || [ -L "$guard_tmp" ] || guard_tmp=""
        [ -z "$guard_tmp" ] || unlink "$guard_tmp" 2>/dev/null || true
        return 1
    }
    sync -f "$guard_dir" || return 1
    [ -f "$guard_file" ] && [ ! -L "$guard_file" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$guard_file" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    actual_hash=$(sha256sum "$guard_file" 2>/dev/null | awk '{print $1}') || return 1
    [ "$actual_hash" = "$expected_hash" ] || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    nexus_service_effective_guards_are_exact && \
        nexus_service_effective_identity_is_exact
}

nexus_service_start_preflight() {
    # Every start/restart path shares one ownership barrier.  Re-emitting the
    # exact guard is safe and idempotent; the final identity proof rejects an
    # unknown fragment, runtime identity, command, condition or drop-in before
    # systemd is allowed to execute any service command.
    ensure_nexus_service_guards || return 1
    nexus_service_effective_identity_is_exact
}

nexus_systemctl_start_checked() {
    nexus_service_start_preflight || return 1
    systemctl start rr-nexus "$@"
}

nexus_systemctl_restart_checked() {
    nexus_service_start_preflight || return 1
    systemctl reset-failed rr-nexus >/dev/null 2>&1 || return 1
    systemctl restart rr-nexus "$@"
}

nexus_service_runtime_generation() {
    # A successful `systemctl restart` return is not a generation proof.  Close
    # over both PID and the monotonic exec timestamp, and require the exact
    # loaded/active/enabled unit state before callers expose a new config.
    local load_state="" active_state="" sub_state="" unit_file_state=""
    local fragment="" main_pid="" started_at=""
    load_state=$(systemctl show rr-nexus.service --property=LoadState --value \
        2>/dev/null) || return 1
    active_state=$(systemctl show rr-nexus.service --property=ActiveState --value \
        2>/dev/null) || return 1
    sub_state=$(systemctl show rr-nexus.service --property=SubState --value \
        2>/dev/null) || return 1
    unit_file_state=$(systemctl show rr-nexus.service \
        --property=UnitFileState --value 2>/dev/null) || return 1
    fragment=$(systemctl show rr-nexus.service --property=FragmentPath --value \
        2>/dev/null) || return 1
    main_pid=$(systemctl show rr-nexus.service --property=MainPID --value \
        2>/dev/null) || return 1
    started_at=$(systemctl show rr-nexus.service \
        --property=ExecMainStartTimestampMonotonic --value 2>/dev/null) || return 1
    [ "$load_state:$active_state:$sub_state:$unit_file_state" = \
      loaded:active:running:enabled ] && \
        [ "$fragment" = "$NEXUS_SERVICE_FILE" ] && \
        [[ "$main_pid" =~ ^[0-9]+$ ]] && [ "$main_pid" -gt 1 ] && \
        [[ "$started_at" =~ ^[0-9]+$ ]] && [ "$started_at" -gt 0 ] || return 1
    printf '%s:%s\n' "$main_pid" "$started_at"
}

nexus_service_active_generation() {
    nexus_service_start_preflight || return 1
    nexus_service_runtime_generation
}

nexus_service_inactive_generation_is_proved() {
    local active_status=0 load_state="" active_state="" sub_state="" main_pid=""
    if systemctl is-active --quiet rr-nexus.service >/dev/null 2>&1; then
        return 1
    else
        active_status=$?
    fi
    [ "$active_status" -eq 3 ] || return 1
    load_state=$(systemctl show rr-nexus.service --property=LoadState --value \
        2>/dev/null) || return 1
    active_state=$(systemctl show rr-nexus.service --property=ActiveState --value \
        2>/dev/null) || return 1
    sub_state=$(systemctl show rr-nexus.service --property=SubState --value \
        2>/dev/null) || return 1
    main_pid=$(systemctl show rr-nexus.service --property=MainPID --value \
        2>/dev/null) || return 1
    [ "$load_state:$active_state:$sub_state:$main_pid" = loaded:inactive:dead:0 ]
}

nexus_service_stopped_disabled_is_exact() {
    local enabled_status=0 unit_file_state=""
    if systemctl is-enabled --quiet rr-nexus.service >/dev/null 2>&1; then
        return 1
    else
        enabled_status=$?
    fi
    [ "$enabled_status" -eq 1 ] || return 1
    unit_file_state=$(systemctl show rr-nexus.service \
        --property=UnitFileState --value 2>/dev/null) || return 1
    [ "$unit_file_state" = disabled ] && nexus_service_inactive_generation_is_proved
}

nexus_restart_service_generation_checked() {
    local previous_generation="${1:-}"
    local next_generation="" attempt=0 restart_status=0
    local previous_pid="" previous_started_at=""
    local next_pid="" next_started_at=""
    local attempts="${NEXUS_SERVICE_GENERATION_ATTEMPTS:-10}"
    local wait_seconds="${NEXUS_SERVICE_GENERATION_WAIT_SECONDS:-1}"
    [[ "$attempts" =~ ^[1-9][0-9]?$ ]] || attempts=10
    [[ "$wait_seconds" =~ ^[0-9]$ ]] || wait_seconds=1
    if [ -z "$previous_generation" ]; then
        previous_generation=$(nexus_service_active_generation) || return 1
    fi
    [[ "$previous_generation" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    previous_pid="${previous_generation%%:*}"
    previous_started_at="${previous_generation#*:}"
    [ "$previous_pid" -gt 1 ] && [ "$previous_started_at" -gt 0 ] || return 1
    nexus_systemctl_restart_checked >/dev/null 2>&1 || restart_status=$?
    [ "$restart_status" -eq 0 ] || return "$restart_status"
    while [ "$attempt" -lt "$attempts" ]; do
        next_generation=$(nexus_service_runtime_generation 2>/dev/null) || \
            next_generation=""
        if [[ "$next_generation" =~ ^[0-9]+:[0-9]+$ ]]; then
            next_pid="${next_generation%%:*}"
            next_started_at="${next_generation#*:}"
        else
            next_pid=""
            next_started_at=""
        fi
        # A changed pair is not enough: a stale PID with a forged/later time,
        # or a recycled PID with the old time, is not a proved new process.
        # Require both independent systemd generation fields to advance.
        if [ -n "$next_pid" ] && [ "$next_pid" -ne "$previous_pid" ] && \
           [ "$next_started_at" -gt "$previous_started_at" ]; then
            nexus_local_backend_health_check || return 1
            printf '%s\n' "$next_generation"
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt "$attempts" ] && [ "$wait_seconds" -gt 0 ] && \
            sleep "$wait_seconds"
    done
    return 1
}

nexus_backend_subscription_mode_error_is() {
    # The public subscription handler deliberately returns two different 404
    # errors. `not_found` means the static process config is closed; once the
    # trusted public mode has really been loaded, the same harmless nonexistent
    # device reaches token lookup and returns `subscription_not_found`.
    local expected_error="${1:-}" response="" body="" http_status=""
    case "$expected_error" in not_found|subscription_not_found) ;; *) return 1 ;; esac
    response=$(curl --silent --show-error --noproxy '*' --proto '=http' \
        --connect-timeout 1 --max-time 3 --write-out $'\n%{http_code}' \
        'http://127.0.0.1:7900/sub/rr_generation_probe/rr_generation_probe/txt') || \
        return 1
    http_status="${response##*$'\n'}"
    body="${response%$'\n'*}"
    [ "$http_status" = 404 ] || return 1
    jq -e --arg expected "$expected_error" \
        'type == "object" and length == 1 and .error == $expected' \
        <<< "$body" >/dev/null 2>&1
}

nexus_backend_subscription_mode_is_active() {
    nexus_backend_subscription_mode_error_is subscription_not_found
}

nexus_backend_subscription_mode_is_closed() {
    nexus_backend_subscription_mode_error_is not_found
}

nexus_backend_real_subscription_token_is_reachable() {
    # If at least one usable personal device exists, promotion is not complete
    # until that exact device/token reaches the freshly restarted backend and
    # returns non-empty subscription bytes. A brand-new panel legitimately has
    # no device yet; the mode discriminator above remains the generation proof
    # for that empty state.
    local row="" device_id="" token="" extra="" response_file=""
    local http_status="" query=""
    [ -f "$NEXUS_DB_FILE" ] && [ ! -L "$NEXUS_DB_FILE" ] || return 1
    query="SELECT id,subscription_token FROM devices WHERE enabled=1 AND (expires_at IS NULL OR expires_at='' OR expires_at>=date('now')) AND (quota_bytes=0 OR used_bytes<quota_bytes) ORDER BY created_at LIMIT 1;"
    row=$(sqlite3 -readonly -separator $'\t' "$NEXUS_DB_FILE" "$query") || \
        return 1
    [ -n "$row" ] || return 0
    IFS=$'\t' read -r device_id token extra <<< "$row"
    [ -z "$extra" ] && [[ "$device_id" =~ ^dev_[A-Za-z0-9_-]+$ ]] && \
        [[ "$token" =~ ^[A-Za-z0-9_-]{16,128}$ ]] || return 1
    [ -f "$NEXUS_SUB_ROOT/${device_id}.txt" ] && \
        [ ! -L "$NEXUS_SUB_ROOT/${device_id}.txt" ] || return 1
    response_file=$(mktemp "$NEXUS_DATA_DIR/.nexus-sub-generation.XXXXXX") || \
        return 1
    chmod 600 "$response_file" || {
        unlink "$response_file" 2>/dev/null || true
        return 1
    }
    # Feed the URL through curl's stdin config so the real long-lived token is
    # never present in the process argument list.
    http_status=$(printf 'url = "http://127.0.0.1:7900/sub/%s/%s/txt"\n' \
        "$device_id" "$token" | curl --silent --show-error --noproxy '*' \
        --proto '=http' --connect-timeout 1 --max-time 5 --output "$response_file" \
        --write-out '%{http_code}' --config -) || {
        unlink "$response_file" 2>/dev/null || true
        return 1
    }
    if [ "$http_status" != 200 ] || [ ! -s "$response_file" ]; then
        unlink "$response_file" 2>/dev/null || true
        return 1
    fi
    unlink "$response_file" 2>/dev/null
}

nexus_publish_local_runtime_config() {
    local config_dir="" temporary=""
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || return 1
    config_dir=$(dirname -- "$NEXUS_CONFIG_FILE") || return 1
    temporary=$(mktemp "$config_dir/.nexus-local-transition.XXXXXX") || return 1
    if ! jq '
        .mode = "local" |
        .domain = "" |
        .certificate_mode = "none" |
        .subscription_access_mode = "local" |
        .subscription_domain = "" |
        del(.acme_email)
    ' "$NEXUS_CONFIG_FILE" > "$temporary" || \
       ! nexus_publish_config_candidate "$temporary" "$NEXUS_CONFIG_FILE"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 1
    fi
}

nexus_transition_to_local_generation() {
    local public_config_snapshot="${1:-}"
    local previous_generation="" service_was_active=true cleanup_status=0
    [ -f "$public_config_snapshot" ] && [ ! -L "$public_config_snapshot" ] || \
        return 2
    if ! previous_generation=$(nexus_service_active_generation 2>/dev/null); then
        nexus_service_inactive_generation_is_proved || return 2
        service_was_active=false
    fi
    # The externally reachable path is retired before the first config rename.
    # Therefore a power loss/SIGKILL after local:none reaches disk but before
    # the process restart cannot leave the old in-memory public generation
    # reachable through Nginx or its firewall tuple.
    nexus_deactivate_public_access "$public_config_snapshot" || cleanup_status=$?
    [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
    if ! nexus_publish_local_runtime_config; then
        # Public access is already closed and the recoverable intent remains.
        return 1
    fi
    if [ "$service_was_active" = false ]; then
        return 0
    fi
    if nexus_restart_service_generation_checked "$previous_generation" \
        >/dev/null && nexus_backend_subscription_mode_is_closed; then
        return 0
    fi
    # The old process may still hold a public config, but the public path was
    # synchronously retired before publication. Keep all ACME evidence intact.
    return 1
}

nexus_commit_ip_acme_active_generation() {
    local previous_generation="${1:-}" rollback_generation=""
    local rollback_status=0 cleanup_status=0
    [[ "$previous_generation" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    nexus_set_certificate_mode pending-acme-ip acme-ip-shortlived || return 1
    if nexus_restart_service_generation_checked "$previous_generation" \
        >/dev/null && nexus_backend_subscription_mode_is_active && \
       nexus_backend_real_subscription_token_is_reachable; then
        return 0
    fi
    # Once an active process may exist, close the external path before writing
    # pending to disk. A kill between that rename and the rollback restart can
    # then leave only a loopback-only stale process, never a public /sub route.
    nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || cleanup_status=$?
    [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
    nexus_set_certificate_mode acme-ip-shortlived pending-acme-ip || \
        rollback_status=2
    if [ "$rollback_status" -eq 0 ]; then
        # Whether the failed restart left the old process or a partially new
        # one behind, restart once more from the exact observed generation and
        # prove that pending mode has closed /sub again. Callers still withdraw
        # Nginx/firewall on the returned failure.
        rollback_generation=$(nexus_service_active_generation 2>/dev/null) || \
            rollback_status=2
    fi
    if [ "$rollback_status" -eq 0 ]; then
        nexus_restart_service_generation_checked "$rollback_generation" \
            >/dev/null && nexus_backend_subscription_mode_is_closed || \
            rollback_status=2
    fi
    [ "$rollback_status" -eq 0 ] || return "$rollback_status"
    return 1
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

nexus_emit_nginx_domain_http_site() {
    local domain="${1:-}"
    local webroot="${2:-${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}}"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || \
        return 1
    [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
        [[ "/$webroot/" != *'/../'* && "/$webroot/" != *'/./'* && \
           "$webroot" != *//* ]] || return 1
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 32k;

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }

    location / {
        return 444;
    }
}
EOF
}

nexus_emit_nginx_domain_http_site_v711() {
    local domain="${1:-}"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || \
        return 1
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 32k;

    location /.well-known/acme-challenge/ {
        root /var/www/rr-nexus-certbot;
    }

    location / {
        return 444;
    }
}
EOF
}

nexus_emit_nginx_domain_custom_site() {
    local domain="${1:-}" port="${2:-}"
    local webroot="${3:-${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}}"
    local legacy="${4:-false}"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || \
        return 1
    is_valid_port "$port" && [ "$port" != 80 ] && [ "$port" != 7900 ] || \
        return 1
    case "$legacy" in true|false) ;; *) return 1 ;; esac
    if [ "$legacy" = false ]; then
        [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
            [[ "/$webroot/" != *'/../'* && "/$webroot/" != *'/./'* && \
               "$webroot" != *//* ]] || return 1
    else
        webroot=/var/www/rr-nexus-certbot
    fi
    cat <<EOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name ${domain};
    client_max_body_size 32k;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    # 热更新时，已打开但未刷新的旧页面可能仍把订阅 token 放在
    # ?raw= 查询串。后端会拒绝它，但 Nginx 必须在转发前就停止记录。
    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

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
EOF
    if [ "$legacy" = true ]; then
        cat <<EOF
    location /.well-known/acme-challenge/ {
        root ${webroot};
    }
EOF
    else
        cat <<EOF
    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }
EOF
    fi
    cat <<EOF
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location / {
        return 301 https://\$host:${port}\$request_uri;
    }
}
EOF
}

nexus_emit_nginx_ip_site() {
    # address is validated even though Nginx uses server_name _. Keeping it in
    # the interface binds callers to the intended certificate identity.
    local address="${1:-}" port="${2:-}" certificate_mode="${3:-}"
    local legacy_renderer="${4:-false}"
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    local cert_file="$cert_dir/ip.crt" key_file="$cert_dir/ip.key"
    local trusted=false
    is_ip_version "$address" 4 || is_ip_version "$address" 6 || return 1
    is_valid_port "$port" && [ "$port" != 80 ] && [ "$port" != 7900 ] || \
        return 1
    case "$certificate_mode" in
        acme-ip-shortlived|pending-acme-ip) trusted=true ;;
        legacy-self-signed) trusted=false ;;
        *) return 1 ;;
    esac
    case "$legacy_renderer" in true|false) ;; *) return 1 ;; esac
    [ "$legacy_renderer" = false ] || [ "$trusted" = false ] || return 1
    cat <<EOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_ip_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name _;
    client_max_body_size 32k;
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;

EOF
    if [ "$trusted" = true ]; then
        cat <<'EOF'
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
EOF
    elif [ "$legacy_renderer" = true ]; then
        cat <<'EOF'
    # IP 模式使用自签证书，不能作为订阅客户端的可信入口。即使调用方
    # 知道设备 token，也必须在代理层拒绝，且不能把 token 写入日志。
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
EOF
    else
        cat <<'EOF'
    # Legacy self-signed IP mode is panel-only.  Tokens are never forwarded.
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
EOF
    fi
    cat <<'EOF'

    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    location = /api/login {
        limit_req zone=rr_nexus_ip_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
}
EOF
}

nexus_nginx_managed_directory_is_safe() {
    local directory="${1:-}" canonical="" mode="" current="" parent=""
    local trust_root="${NEXUS_NGINX_TRUST_ROOT:-/}"
    [[ "$directory" = /* && "$directory" != *[[:space:]]* ]] || return 1
    [[ "$trust_root" = /* && "$trust_root" != *[[:space:]]* ]] || return 1
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    canonical=$(readlink -f -- "$trust_root" 2>/dev/null) || return 1
    [ "$canonical" = "$trust_root" ] || return 1
    case "${directory}/" in
        "${trust_root%/}/"*) ;;
        *) return 1 ;;
    esac
    current="$directory"
    while true; do
        [ -d "$current" ] && [ ! -L "$current" ] || return 1
        [ "$(stat -c '%u:%g' -- "$current" 2>/dev/null)" = 0:0 ] || return 1
        mode=$(stat -c %a -- "$current" 2>/dev/null) || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
            [ $((8#$mode & 8#022)) -eq 0 ] || return 1
        canonical=$(readlink -f -- "$current" 2>/dev/null) || return 1
        [ "$canonical" = "$current" ] || return 1
        [ "$current" = "$trust_root" ] && return 0
        parent=$(dirname -- "$current") || return 1
        [ "$parent" != "$current" ] || return 1
        current="$parent"
    done
}

nexus_nginx_regular_site_metadata_is_exact() {
    local path="${1:-}" parent="" canonical=""
    [[ "$path" = /* && "$path" != *[[:space:]]* ]] || return 1
    parent=$(dirname -- "$path") || return 1
    nexus_nginx_managed_directory_is_safe "$parent" || return 1
    [ -f "$path" ] && [ ! -L "$path" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$path" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    canonical=$(readlink -f -- "$path" 2>/dev/null) || return 1
    [ "$canonical" = "$path" ]
}

nexus_nginx_enabled_link_is_exact() {
    local link="${1:-}" expected_target="${2:-}" parent="" metadata=""
    [[ "$link" = /* && "$link" != *[[:space:]]* && \
       "$expected_target" = /* && "$expected_target" != *[[:space:]]* ]] || \
        return 1
    parent=$(dirname -- "$link") || return 1
    nexus_nginx_managed_directory_is_safe "$parent" || return 1
    [ -L "$link" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$link" 2>/dev/null) || return 1
    [ "$metadata" = 0:0:777:1 ] && \
        [ "$(readlink -- "$link" 2>/dev/null)" = "$expected_target" ]
}

nexus_nginx_site_parameters() {
    local path="${1:-}" kind="${2:-}"
    python3 - "$path" "$kind" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
kind = sys.argv[2]
try:
    data = path.read_bytes()
    text = data.decode("utf-8", "strict")
except (OSError, UnicodeError):
    raise SystemExit(1)
if not data or len(data) > 131072 or b"\0" in data:
    raise SystemExit(1)

domains = re.findall(r"^    server_name ([^;\r\n]+);$", text, re.MULTILINE)
roots = re.findall(r"^        root ([^;\r\n]+);$", text, re.MULTILINE)
ssl_ports = re.findall(
    r"^    listen ([0-9]{1,5}) ssl;$", text, re.MULTILINE
)
certificates = re.findall(
    r"^    ssl_certificate ([^;\r\n]+);$", text, re.MULTILINE
)
keys = re.findall(
    r"^    ssl_certificate_key ([^;\r\n]+);$", text, re.MULTILINE
)

dns = re.compile(
    r"(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}"
)
safe_path = re.compile(r"/[A-Za-z0-9_./-]+")
def valid_path(value: str) -> bool:
    return bool(
        safe_path.fullmatch(value)
        and "//" not in value
        and "/../" not in f"/{value}/"
        and "/./" not in f"/{value}/"
    )

if kind == "domain-http":
    if len(domains) != 1 or not dns.fullmatch(domains[0]) or len(roots) != 1:
        raise SystemExit(1)
    if ssl_ports or certificates or keys or not valid_path(roots[0]):
        raise SystemExit(1)
    print(domains[0], roots[0], sep="\t")
elif kind == "domain-custom":
    if (
        len(domains) != 2
        or domains[0] != domains[1]
        or not dns.fullmatch(domains[0])
        or len(roots) != 1
        or len(ssl_ports) != 1
        or not 1 <= int(ssl_ports[0]) <= 65535
        or int(ssl_ports[0]) in {80, 7900}
        or len(certificates) != 1
        or certificates[0]
        != f"/etc/letsencrypt/live/{domains[0]}/fullchain.pem"
        or len(keys) != 1
        or keys[0] != f"/etc/letsencrypt/live/{domains[0]}/privkey.pem"
        or not valid_path(roots[0])
    ):
        raise SystemExit(1)
    print(domains[0], ssl_ports[0], roots[0], sep="\t")
elif kind == "ip":
    if (
        domains != ["_"]
        or roots
        or len(ssl_ports) != 1
        or not 1 <= int(ssl_ports[0]) <= 65535
        or int(ssl_ports[0]) in {80, 7900}
        or len(certificates) != 1
        or len(keys) != 1
        or not valid_path(certificates[0])
        or not valid_path(keys[0])
    ):
        raise SystemExit(1)
    print(ssl_ports[0], certificates[0], keys[0], sep="\t")
else:
    raise SystemExit(1)
PY
}

nexus_nginx_domain_http_site_is_supported() {
    local site="${1:-}" parameters="" domain="" webroot=""
    nexus_nginx_regular_site_metadata_is_exact "$site" || return 1
    parameters=$(nexus_nginx_site_parameters "$site" domain-http) || return 1
    IFS=$'\t' read -r domain webroot <<< "$parameters"
    cmp -s -- "$site" <(nexus_emit_nginx_domain_http_site "$domain" "$webroot") && \
        return 0
    cmp -s -- "$site" <(nexus_emit_nginx_domain_http_site_v711 "$domain")
}

nexus_nginx_domain_custom_site_is_supported() {
    local site="${1:-}" parameters="" domain="" port="" webroot=""
    nexus_nginx_regular_site_metadata_is_exact "$site" || return 1
    parameters=$(nexus_nginx_site_parameters "$site" domain-custom) || return 1
    IFS=$'\t' read -r domain port webroot <<< "$parameters"
    cmp -s -- "$site" \
        <(nexus_emit_nginx_domain_custom_site "$domain" "$port" "$webroot" false) && \
        return 0
    cmp -s -- "$site" \
        <(nexus_emit_nginx_domain_custom_site "$domain" "$port" "$webroot" true)
}

nexus_nginx_ip_site_is_supported() {
    local site="${1:-}" parameters="" port="" cert_file="" key_file=""
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    nexus_nginx_regular_site_metadata_is_exact "$site" || return 1
    parameters=$(nexus_nginx_site_parameters "$site" ip) || return 1
    IFS=$'\t' read -r port cert_file key_file <<< "$parameters"
    [ "$cert_file" = "$cert_dir/ip.crt" ] && \
        [ "$key_file" = "$cert_dir/ip.key" ] || return 1
    cmp -s -- "$site" \
        <(nexus_emit_nginx_ip_site 127.0.0.1 "$port" acme-ip-shortlived false) && \
        return 0
    cmp -s -- "$site" \
        <(nexus_emit_nginx_ip_site 127.0.0.1 "$port" legacy-self-signed false) && \
        return 0
    cmp -s -- "$site" \
        <(nexus_emit_nginx_ip_site 127.0.0.1 "$port" legacy-self-signed true)
}

nexus_ip_nginx_site_is_exact() {
    # Read-only. Both paths absent is valid. If either exists, each existing
    # object is independently proved; an exact dangling enabled link is safe.
    local address="${1:-}" port="${2:-}" certificate_mode="${3:-}"
    local site="${4:-}" enabled_link="${5:-}"
    is_ip_version "$address" 4 || is_ip_version "$address" 6 || return 1
    case "$certificate_mode" in
        acme-ip-shortlived|pending-acme-ip|legacy-self-signed) ;;
        *) return 1 ;;
    esac
    is_valid_port "$port" && [ "$port" != 80 ] && [ "$port" != 7900 ] || \
        return 1
    if [ -e "$site" ] || [ -L "$site" ]; then
        nexus_nginx_regular_site_metadata_is_exact "$site" || return 1
        cmp -s -- "$site" \
            <(nexus_emit_nginx_ip_site "$address" "$port" "$certificate_mode" false) || {
            [ "$certificate_mode" = legacy-self-signed ] && \
                cmp -s -- "$site" \
                    <(nexus_emit_nginx_ip_site "$address" "$port" \
                        legacy-self-signed true) || return 1
        }
    fi
    if [ -e "$enabled_link" ] || [ -L "$enabled_link" ]; then
        nexus_nginx_enabled_link_is_exact "$enabled_link" "$site" || return 1
    fi
    return 0
}

nexus_nginx_managed_path_is_owned() {
    local path="${1:-}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    case "$path" in
        "$NEXUS_NGINX_SITE") nexus_nginx_domain_http_site_is_supported "$path" ;;
        "${NEXUS_NGINX_SITE}.port") nexus_nginx_domain_custom_site_is_supported "$path" ;;
        "$nginx_available_dir/rr-nexus-ip.conf")
            nexus_nginx_ip_site_is_supported "$path"
            ;;
        "$nginx_enabled_dir/rr-nexus.conf")
            nexus_nginx_enabled_link_is_exact "$path" "$NEXUS_NGINX_SITE"
            ;;
        "$nginx_enabled_dir/rr-nexus-port.conf")
            nexus_nginx_enabled_link_is_exact "$path" "${NEXUS_NGINX_SITE}.port"
            ;;
        "$nginx_enabled_dir/rr-nexus-ip.conf")
            nexus_nginx_enabled_link_is_exact "$path" \
                "$nginx_available_dir/rr-nexus-ip.conf"
            ;;
        *) return 1 ;;
    esac
}

nexus_nginx_managed_path_is_fixed() {
    local path="${1:-}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    case "$path" in
        "$NEXUS_NGINX_SITE"|"${NEXUS_NGINX_SITE}.port"|\
        "$nginx_available_dir/rr-nexus-ip.conf"|\
        "$nginx_enabled_dir/rr-nexus.conf"|\
        "$nginx_enabled_dir/rr-nexus-port.conf"|\
        "$nginx_enabled_dir/rr-nexus-ip.conf") return 0 ;;
        *) return 1 ;;
    esac
}

nexus_nginx_candidate_matches_target() {
    local candidate="${1:-}" target="${2:-}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    case "$target" in
        "$NEXUS_NGINX_SITE")
            nexus_nginx_domain_http_site_is_supported "$candidate"
            ;;
        "${NEXUS_NGINX_SITE}.port")
            nexus_nginx_domain_custom_site_is_supported "$candidate"
            ;;
        "$nginx_available_dir/rr-nexus-ip.conf")
            nexus_nginx_ip_site_is_supported "$candidate"
            ;;
        *) return 1 ;;
    esac
}

nexus_nginx_managed_paths_are_owned() {
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local path=""
    local -a paths=(
        "$nginx_enabled_dir/rr-nexus.conf"
        "$NEXUS_NGINX_SITE"
        "$nginx_enabled_dir/rr-nexus-ip.conf"
        "$nginx_available_dir/rr-nexus-ip.conf"
        "$nginx_enabled_dir/rr-nexus-port.conf"
        "${NEXUS_NGINX_SITE}.port"
    )
    [ "$(dirname -- "$NEXUS_NGINX_SITE")" = "$nginx_available_dir" ] && \
        [ "$(basename -- "$NEXUS_NGINX_SITE")" = rr-nexus.conf ] || return 1
    for path in "$nginx_available_dir" "$nginx_enabled_dir"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            nexus_nginx_managed_directory_is_safe "$path" || return 1
        fi
    done
    for path in "${paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            nexus_nginx_managed_path_is_owned "$path" || return 1
        fi
    done
}

nexus_nginx_unlink_owned_path() {
    local path="${1:-}" parent=""
    [ -e "$path" ] || [ -L "$path" ] || return 0
    nexus_nginx_managed_path_is_owned "$path" || return 2
    parent=$(dirname -- "$path") || return 2
    nexus_nginx_managed_directory_is_safe "$parent" || return 2
    unlink "$path" 2>/dev/null || return 2
    sync -f "$parent" || return 2
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

nexus_nginx_snapshot_matches_path() {
    local snapshot="${1:-}" path="${2:-}"
    local snapshot_metadata="" path_metadata=""
    if [ -L "$snapshot" ]; then
        [ -L "$path" ] || return 1
        snapshot_metadata=$(stat -c '%u:%g:%a:%h' -- "$snapshot" 2>/dev/null) || \
            return 1
        path_metadata=$(stat -c '%u:%g:%a:%h' -- "$path" 2>/dev/null) || return 1
        [ "$snapshot_metadata" = "$path_metadata" ] && \
            [ "$(readlink -- "$snapshot" 2>/dev/null)" = \
              "$(readlink -- "$path" 2>/dev/null)" ]
        return
    fi
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] && \
        [ -f "$path" ] && [ ! -L "$path" ] || return 1
    snapshot_metadata=$(stat -c '%u:%g:%a:%h' -- "$snapshot" 2>/dev/null) || \
        return 1
    path_metadata=$(stat -c '%u:%g:%a:%h' -- "$path" 2>/dev/null) || return 1
    [ "$snapshot_metadata" = "$path_metadata" ] && cmp -s -- "$snapshot" "$path"
}

nexus_nginx_copy_snapshot_noreplace() {
    # Snapshot restoration may create an absent fixed path, but must never
    # replace a name that appears after the ownership preflight.  Older
    # supported coreutils accepts --no-clobber but not the valued update mode;
    # prefer the latter when supported so newer releases do not emit the
    # --no-clobber deprecation warning.  -T also prevents a raced-in directory
    # from being reinterpreted as a destination directory.
    local snapshot="${1:-}" path="${2:-}"
    [ -f "$snapshot" ] || [ -L "$snapshot" ] || return 2
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 2
    if command cp --update=none --version >/dev/null 2>&1; then
        command cp -a -T --update=none -- "$snapshot" "$path" || return 2
    else
        command cp -a -T --no-clobber -- "$snapshot" "$path" || return 2
    fi
}

nexus_nginx_restore_snapshot_path() {
    local snapshot="${1:-}" path="${2:-}" parent=""
    nexus_nginx_managed_path_is_fixed "$path" || return 2
    [ -e "$snapshot" ] || [ -L "$snapshot" ] || return 2
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 2
    parent=$(dirname -- "$path") || return 2
    nexus_nginx_managed_directory_is_safe "$parent" || return 2
    nexus_nginx_copy_snapshot_noreplace "$snapshot" "$path" || return 2
    nexus_nginx_snapshot_matches_path "$snapshot" "$path" || return 2
    sync -f "$parent" || return 2
    nexus_nginx_managed_path_is_owned "$path" || return 2
}

nexus_nginx_rename_noreplace() {
    # renameat2(RENAME_NOREPLACE) is one atomic namespace mutation: it cannot
    # overwrite a collision and, unlike a link+unlink publication, SIGKILL can
    # never strand the managed target at nlink=2.
    local candidate="${1:-}" target="${2:-}" parent=""
    parent=$(dirname -- "$target") || return 2
    [ "$(dirname -- "$candidate")" = "$parent" ] || return 2
    nexus_nginx_managed_directory_is_safe "$parent" || return 2
    python3 - "$candidate" "$target" <<'PY'
import ctypes
import errno
import os
import pathlib
import stat
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
if source.parent != target.parent or source.name in {"", ".", ".."} or target.name in {"", ".", ".."}:
    raise SystemExit(2)

flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
if hasattr(os, "O_NOFOLLOW"):
    flags |= os.O_NOFOLLOW
try:
    directory_fd = os.open(source.parent, flags)
except OSError:
    raise SystemExit(2)
try:
    before = os.stat(source.name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != 0
        or before.st_gid != 0
        or stat.S_IMODE(before.st_mode) != 0o644
        or before.st_nlink != 1
    ):
        raise SystemExit(2)
    try:
        os.stat(target.name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit(2)

    libc = ctypes.CDLL(None, use_errno=True)
    renameat2 = getattr(libc, "renameat2", None)
    if renameat2 is None:
        raise SystemExit(2)
    renameat2.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameat2.restype = ctypes.c_int
    if renameat2(
        directory_fd,
        os.fsencode(source.name),
        directory_fd,
        os.fsencode(target.name),
        1,  # RENAME_NOREPLACE
    ) != 0:
        error = ctypes.get_errno()
        if error == errno.EEXIST:
            raise SystemExit(2)
        raise SystemExit(2)

    after = os.stat(target.name, dir_fd=directory_fd, follow_symlinks=False)
    if (
        (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        or after.st_nlink != 1
        or not stat.S_ISREG(after.st_mode)
    ):
        raise SystemExit(2)
    try:
        os.stat(source.name, dir_fd=directory_fd, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit(2)
    os.fsync(directory_fd)
finally:
    os.close(directory_fd)
PY
}

nexus_nginx_publish_candidate() {
    # Publish without rename-overwrite. A collision that appears after the
    # ownership preflight is preserved by the atomic kernel operation.
    local candidate="${1:-}" target="${2:-}" parent=""
    [ -f "$candidate" ] && [ ! -L "$candidate" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$candidate" 2>/dev/null)" = 0:0:644:1 ] || \
        return 2
    nexus_nginx_managed_path_is_fixed "$target" || return 2
    nexus_nginx_candidate_matches_target "$candidate" "$target" || return 2
    nexus_nginx_managed_paths_are_owned || return 2
    if [ -e "$target" ] || [ -L "$target" ]; then
        nexus_nginx_unlink_owned_path "$target" || return 2
    fi
    parent=$(dirname -- "$target") || return 2
    nexus_nginx_managed_directory_is_safe "$parent" || return 2
    [ ! -e "$target" ] && [ ! -L "$target" ] || return 2
    nexus_nginx_rename_noreplace "$candidate" "$target" || return 2
    nexus_nginx_managed_path_is_owned "$target" || return 2
}

nexus_nginx_publish_enabled_link() {
    local target="${1:-}" enabled_link="${2:-}" parent=""
    nexus_nginx_managed_path_is_fixed "$target" && \
        nexus_nginx_managed_path_is_fixed "$enabled_link" || return 2
    nexus_nginx_managed_paths_are_owned || return 2
    [ -e "$target" ] && [ ! -L "$target" ] && \
        nexus_nginx_managed_path_is_owned "$target" || return 2
    if [ -e "$enabled_link" ] || [ -L "$enabled_link" ]; then
        nexus_nginx_unlink_owned_path "$enabled_link" || return 2
    fi
    parent=$(dirname -- "$enabled_link") || return 2
    nexus_nginx_managed_directory_is_safe "$parent" || return 2
    [ ! -e "$enabled_link" ] && [ ! -L "$enabled_link" ] || return 2
    ln -s -- "$target" "$enabled_link" 2>/dev/null || return 2
    sync -f "$parent" || return 2
    nexus_nginx_enabled_link_is_exact "$enabled_link" "$target" || return 2
}

nexus_commit_nginx_candidate() {
    local candidate="$1"
    local target="$2"
    local enabled_link="$3"
    local obsolete_link="${4:-}"
    local transaction_dir=""
    local path=""
    local index=0
    local nginx_was_active=false
    local transaction_ok=true
    local restore_ok=true
    local -a managed_paths=("$target" "$enabled_link")
    local -a managed_present=()
    [ -n "$obsolete_link" ] && managed_paths+=("$obsolete_link")
    [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
    nexus_nginx_managed_path_is_fixed "$target" && \
        nexus_nginx_managed_path_is_fixed "$enabled_link" || return 2
    [ -z "$obsolete_link" ] || \
        nexus_nginx_managed_path_is_fixed "$obsolete_link" || return 2
    # This is deliberately before snapshots: a foreign same-name object must
    # never be copied into an RR transaction and later treated as owned.
    nexus_nginx_managed_paths_are_owned || return 2

    systemctl is-active --quiet nginx >/dev/null 2>&1 && nginx_was_active=true
    transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/rr-nexus-nginx-site.XXXXXX") || return 1
    mkdir -p "$transaction_dir/items" || {
        rm -rf "$transaction_dir"
        return 1
    }
    for index in "${!managed_paths[@]}"; do
        path="${managed_paths[$index]}"
        managed_present[$index]=false
        if [ -e "$path" ] || [ -L "$path" ]; then
            nexus_nginx_managed_path_is_owned "$path" || {
                rm -rf "$transaction_dir"
                return 2
            }
            cp -a -- "$path" "$transaction_dir/items/$index" || {
                rm -rf "$transaction_dir"
                return 1
            }
            managed_present[$index]=true
        fi
    done

    nexus_nginx_managed_paths_are_owned || transaction_ok=false
    if [ "$transaction_ok" = true ]; then
        if nexus_nginx_publish_candidate "$candidate" "$target"; then
            candidate=""
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        nexus_nginx_unlink_owned_path "$enabled_link" || transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && [ -n "$obsolete_link" ]; then
        nexus_nginx_unlink_owned_path "$obsolete_link" || transaction_ok=false
    fi
    if [ "$transaction_ok" = true ]; then
        nexus_nginx_publish_enabled_link "$target" "$enabled_link" || \
            transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && ! nginx -t >/dev/null 2>&1; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && [ "$nginx_was_active" = true ] && \
       ! systemctl reload nginx >/dev/null 2>&1; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ]; then
        rm -rf "$transaction_dir"
        return 0
    fi

    # Validation/reload failure must restore the exact former RR-owned files.
    # This keeps a bad candidate from poisoning the next boot or unrelated
    # Nginx maintenance, while leaving every user-owned site untouched.
    [ -z "$candidate" ] || rm -f -- "$candidate"
    for path in "${managed_paths[@]}"; do
        if [ -e "$path" ] || [ -L "$path" ]; then
            nexus_nginx_unlink_owned_path "$path" || restore_ok=false
        fi
    done
    for index in "${!managed_paths[@]}"; do
        if [ "${managed_present[$index]}" = true ]; then
            if [ -e "${managed_paths[$index]}" ] || \
               [ -L "${managed_paths[$index]}" ] || \
               ! nexus_nginx_restore_snapshot_path \
                    "$transaction_dir/items/$index" \
                    "${managed_paths[$index]}"; then
                restore_ok=false
            fi
        fi
    done
    if [ "$restore_ok" = true ] && [ "$nginx_was_active" = true ]; then
        nginx -t >/dev/null 2>&1 || restore_ok=false
        [ "$restore_ok" = true ] && \
            systemctl reload nginx >/dev/null 2>&1 || restore_ok=false
    fi
    rm -rf "$transaction_dir"
    [ "$restore_ok" = true ] || \
        printf '%s\n' '[错误] Nexus Nginx 站点写入失败，且原配置未能完整恢复。' >&2
    return 1
}

nexus_write_nginx_site() {
    local domain="$1"
    local port="$2"
    local tmp=""
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    nexus_emit_nginx_domain_http_site "$domain" "$webroot" >/dev/null || return 1
    nexus_nginx_managed_paths_are_owned || return 2
    tmp=$(mktemp "$nginx_available_dir/.rr-nexus.XXXXXX") || return 1
    if ! cat > "$tmp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 32k;

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }

    location / {
        return 444;
    }
}
EOF
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    cmp -s -- "$tmp" \
        <(nexus_emit_nginx_domain_http_site "$domain" "$webroot") || {
        rm -f "$tmp"
        return 2
    }
    nexus_commit_nginx_candidate "$tmp" "$NEXUS_NGINX_SITE" \
        "$nginx_enabled_dir/rr-nexus.conf"
}

nexus_write_nginx_custom_port() {
    local domain="$1"
    local port="$2"
    local tmp=""
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    nexus_emit_nginx_domain_custom_site "$domain" "$port" "$webroot" false \
        >/dev/null || return 1
    nexus_nginx_managed_paths_are_owned || return 2
    tmp=$(mktemp "$nginx_available_dir/.rr-nexus-port.XXXXXX") || return 1
    if ! cat > "$tmp" <<EOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name ${domain};
    client_max_body_size 32k;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    # 热更新时，已打开但未刷新的旧页面可能仍把订阅 token 放在
    # ?raw= 查询串。后端会拒绝它，但 Nginx 必须在转发前就停止记录。
    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

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
    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        return 404;
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
    chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
    cmp -s -- "$tmp" \
        <(nexus_emit_nginx_domain_custom_site "$domain" "$port" "$webroot" false) || {
        rm -f "$tmp"
        return 2
    }
    nexus_commit_nginx_candidate "$tmp" "${NEXUS_NGINX_SITE}.port" \
        "$nginx_enabled_dir/rr-nexus-port.conf" \
        "$nginx_enabled_dir/rr-nexus.conf"
}

nexus_certificate_deploy_hook_is_ready() {
    # Portable restore is read-only for global ACME state.  Other install and
    # reconcile paths may install the generic hook, but all paths must finish
    # with the byte-identical current hook before claiming HTTPS readiness.
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] && \
       [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then
        declare -F rr_certificate_deploy_hook_is_current >/dev/null 2>&1 || return 1
        rr_certificate_deploy_hook_is_current
    else
        declare -F rr_install_certificate_deploy_hook >/dev/null 2>&1 || return 1
        rr_install_certificate_deploy_hook
    fi
}

nexus_firewall_tuple_needed_without_nexus() {
    # Return 0 when another RR consumer still requires the tuple, 1 when it
    # does not, and 2 when the shared-consumer state cannot be proved.  Bash
    # locals are dynamically scoped, so /dev/null hides the current Nexus
    # configuration from the common protocol accounting helper without
    # changing any global state.
    local tuple_port="${1:-}"
    local tuple_proto="${2:-}"
    local NEXUS_CONFIG_FILE=/dev/null
    local -a nexus_firewall_no_updates=()
    is_valid_port "$tuple_port" || return 2
    case "$tuple_proto" in tcp|udp) ;; *) return 2 ;; esac
    # TCP/80 is a certificate-renewal consumer, not the Naive/Sub public data
    # port.  The generic protocol tuple helper accounts only data listeners,
    # so preserve HTTP-01 reachability for every other configured certificate
    # consumer after hiding Nexus itself.
    if [ "$tuple_port" = 80 ] && [ "$tuple_proto" = tcp ]; then
        if [ "${NAIVE_ENABLED:-false}" = true ] && \
           [[ "${NAIVE_DOMAIN:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
            return 0
        fi
        if [ "${SUB_ACCESS_MODE:-local}" = https ] && \
           [[ "${SUB_DOMAIN:-}" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
            return 0
        fi
    fi
    declare -F rr_firewall_protocol_tuple_needed_after_updates \
        >/dev/null 2>&1 || return 2
    rr_firewall_protocol_tuple_needed_after_updates "$tuple_port" \
        "$tuple_proto" nexus_firewall_no_updates
}

nexus_firewall_open_accounted() {
    # The output flag means that this invocation changed a previously
    # non-open tuple.  Callers compensate only that flag on a later failure;
    # a rule that was already open before this invocation is never removed.
    local tuple_port="${1:-}"
    local tuple_proto="${2:-}"
    local output_name="${3:-}"
    local operation_status=0
    [[ "$output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 2
    printf -v "$output_name" '%s' false
    if rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" open; then
        return 0
    fi
    open_protocol_firewall "$tuple_port" "$tuple_proto" || operation_status=$?
    [ "$operation_status" -eq 0 ] || return "$operation_status"
    # The authoritative transaction succeeded after the pre-check could not
    # prove an existing allow, so this invocation owns compensation.  A
    # low-level indeterminate return never reaches this assignment.
    printf -v "$output_name" '%s' true
    rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" open || return 2
}

nexus_firewall_reconcile_without_nexus() {
    local tuple_port="${1:-}"
    local tuple_proto="${2:-}"
    local desired=""
    local needed_status=0
    local operation_status=0
    if nexus_firewall_tuple_needed_without_nexus "$tuple_port" "$tuple_proto"; then
        desired=open
    else
        needed_status=$?
        case "$needed_status" in
            1) desired=closed ;;
            *) return 2 ;;
        esac
    fi
    rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" "$desired" && return 0
    if [ "$desired" = open ]; then
        open_protocol_firewall "$tuple_port" "$tuple_proto" || operation_status=$?
    else
        close_protocol_firewall "$tuple_port" "$tuple_proto" || operation_status=$?
    fi
    [ "$operation_status" -eq 0 ] || return "$operation_status"
    rr_validate_protocol_firewall "$tuple_port" "$tuple_proto" "$desired" || return 2
}

nexus_firewall_compensate_public_opens() {
    local http_created="${1:-false}"
    local panel_created="${2:-false}"
    local panel_port="${3:-}"
    local operation_status=0
    local aggregate_status=0
    if [ "$panel_created" = true ] && [ "$panel_port" != 80 ]; then
        nexus_firewall_reconcile_without_nexus "$panel_port" tcp || operation_status=$?
        if [ "$operation_status" -ge 2 ]; then
            aggregate_status=2
        elif [ "$operation_status" -ne 0 ] && [ "$aggregate_status" -eq 0 ]; then
            aggregate_status=1
        fi
    fi
    operation_status=0
    if [ "$http_created" = true ]; then
        nexus_firewall_reconcile_without_nexus 80 tcp || operation_status=$?
        if [ "$operation_status" -ge 2 ]; then
            aggregate_status=2
        elif [ "$operation_status" -ne 0 ] && [ "$aggregate_status" -eq 0 ]; then
            aggregate_status=1
        fi
    fi
    return "$aggregate_status"
}

nexus_firewall_fail_closed() {
    local context="${1:-Nexus 防火墙状态不确定}"
    local stop_status=0
    if ! declare -F rr_firewall_fail_closed_stop_nodes >/dev/null 2>&1; then
        printf '%s\n' '[紧急] 缺少通用防火墙隔离器，无法证明 RR 公网运行面安全。' >&2
        return 3
    fi
    rr_firewall_fail_closed_stop_nodes "$context" || stop_status=$?
    [ "$stop_status" -ge 2 ] && return "$stop_status"
    return 3
}

nexus_abort_public_activation() {
    local original_status="${1:-1}"
    local http_created="${2:-false}"
    local panel_created="${3:-false}"
    local panel_port="${4:-}"
    local firewall_indeterminate="${5:-false}"
    local cleanup_status=0
    nexus_remove_public_proxy || cleanup_status=2
    if ! nexus_firewall_compensate_public_opens "$http_created" \
        "$panel_created" "$panel_port"; then
        cleanup_status=2
    fi
    if [ "$cleanup_status" -ne 0 ] || [ "$firewall_indeterminate" = true ]; then
        printf '%s\n' \
            '[错误] Nexus 公网入口失败，且代理或防火墙补偿无法完整证明；已停止报告成功，请立即核对。' >&2
        nexus_firewall_fail_closed 'Nexus 公网入口失败且无法证明防火墙原态'
        return $?
    fi
    # A writer=0/post-validate failure is no longer indeterminate after both
    # the proxy rollback and this-run firewall compensation validate.  Report
    # an ordinary failed activation rather than propagating a stale status 2.
    return 1
}

nexus_enable_public_https() {
    local domain="$1"
    local email="$2"
    local port="$3"
    local http_output_name="${4:-}"
    local panel_output_name="${5:-}"
    local http_created=false
    local panel_created=false
    local firewall_indeterminate=false
    local operation_status=0
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
    if [ -n "$http_output_name" ]; then
        [[ "$http_output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
        printf -v "$http_output_name" '%s' false
    fi
    if [ -n "$panel_output_name" ]; then
        [[ "$panel_output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
        printf -v "$panel_output_name" '%s' false
    fi
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 1
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || return 1
    is_valid_port "$port" && [ "$port" != 80 ] && [ "$port" != 7900 ] || return 1
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        echo -e "${RED}[失败] 热更新事务不新签发面板证书；请先修复既有 HTTPS 状态。${RESET}" >&2
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y nginx certbot python3-certbot-nginx || return 1
    if { tcp_port_in_use 80 || tcp_port_in_use 443; } && \
       ! pgrep -x nginx >/dev/null 2>&1; then
        echo -e "${RED}[拒绝] 80/443 已被非 Nginx 程序占用，无法安全签发和托管证书。${RESET}"
        return 1
    fi
    nexus_write_nginx_site "$domain" "$port" || {
        operation_status=$?
        nexus_abort_public_activation "$operation_status" "$http_created" \
            "$panel_created" "$port" || operation_status=$?
        return "$operation_status"
    }
    systemctl enable --now nginx >/dev/null 2>&1 || {
        operation_status=$?
        nexus_abort_public_activation "$operation_status" "$http_created" \
            "$panel_created" "$port" || operation_status=$?
        return "$operation_status"
    }
    nexus_firewall_open_accounted 80 tcp http_created || {
        operation_status=$?
        [ "$operation_status" -ge 2 ] && [ "$http_created" != true ] && \
            firewall_indeterminate=true
        nexus_abort_public_activation "$operation_status" "$http_created" \
            "$panel_created" "$port" "$firewall_indeterminate" || operation_status=$?
        return "$operation_status"
    }

    # 始终使用可审计的 webroot 签发，再由 RR 写入完整 TLS/HTTP 分离配置。
    # 不能使用 certbot --redirect：它生成的 server 级跳转可能把首次出现的
    # /sub/<token> 明文请求重定向并写日志，token 在跳转前就已经泄露。
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    if ! mkdir -p "$webroot/.well-known/acme-challenge" || \
       ! chmod 755 "$webroot" "$webroot/.well-known" \
           "$webroot/.well-known/acme-challenge"; then
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! (umask 022 && certbot certonly --webroot -w "$webroot" -d "$domain" \
        --cert-name "$domain" -m "$email" --agree-tos --non-interactive); then
        echo -e "${RED}[失败] Let's Encrypt 证书签发失败。请检查域名解析和 80 端口入站后重试。${RESET}"
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! subscription_certificate_pair_valid \
           "${le_live_root}/${domain}/fullchain.pem" \
           "${le_live_root}/${domain}/privkey.pem" "$domain" || \
       ! rr_certbot_webroot_lineage_is_renewable "$domain"; then
        echo -e "${RED}[失败] 新签证书未形成结构完整的生产 Webroot lineage。${RESET}"
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! nexus_certificate_deploy_hook_is_ready; then
        echo -e "${RED}[失败] Nexus HTTPS 证书部署钩子未能安装为当前受信版本。${RESET}" >&2
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! rr_enable_certbot_renewal_runtime "$domain"; then
        echo -e "${RED}[失败] certbot.timer 或该域名的本机 ACME HTTP 路由未就绪，拒绝把 Nexus HTTPS 报告为可自动续签。${RESET}" >&2
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! nexus_write_nginx_custom_port "$domain" "$port"; then
        echo -e "${RED}[失败] HTTPS 配置写入失败。${RESET}"
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    nexus_firewall_open_accounted "$port" tcp panel_created || {
        operation_status=$?
        [ "$operation_status" -ge 2 ] && [ "$panel_created" != true ] && \
            firewall_indeterminate=true
        nexus_abort_public_activation "$operation_status" "$http_created" \
            "$panel_created" "$port" "$firewall_indeterminate" || operation_status=$?
        return "$operation_status"
    }

    if [ ! -s "${le_live_root}/${domain}/fullchain.pem" ]; then
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    if ! nginx -t || ! systemctl reload nginx; then
        nexus_abort_public_activation 1 "$http_created" "$panel_created" \
            "$port" || operation_status=$?
        return "${operation_status:-1}"
    fi
    rr_certbot_renewal_runtime_is_ready "$domain" || {
        operation_status=$?
        nexus_abort_public_activation "$operation_status" "$http_created" \
            "$panel_created" "$port" || operation_status=$?
        return "$operation_status"
    }
    [ -z "$http_output_name" ] || \
        printf -v "$http_output_name" '%s' "$http_created"
    [ -z "$panel_output_name" ] || \
        printf -v "$panel_output_name" '%s' "$panel_created"
    return 0
}

nexus_remove_public_proxy() {
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local active_status=0
    local path=""
    local -a managed_paths=(
        "$nginx_enabled_dir/rr-nexus.conf"
        "$nginx_enabled_dir/rr-nexus-ip.conf"
        "$nginx_enabled_dir/rr-nexus-port.conf"
        "$NEXUS_NGINX_SITE"
        "$nginx_available_dir/rr-nexus-ip.conf"
        "${NEXUS_NGINX_SITE}.port"
    )
    # Refuse the complete operation before its first live mutation if any
    # fixed name is foreign.  Each unlink below repeats the proof so a swap
    # between deletion boundaries is preserved and stops the transaction.
    nexus_nginx_managed_paths_are_owned || return 2
    for path in "${managed_paths[@]}"; do
        nexus_nginx_unlink_owned_path "$path" || return 2
    done
    for path in "${managed_paths[@]}"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 2
    done
    command -v nginx >/dev/null 2>&1 || return 0
    nginx -t >/dev/null 2>&1 || return 1
    if systemctl is-active --quiet nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || return 1
        return 0
    else
        active_status=$?
    fi
    # systemctl uses 3 for an inactive/failed unit.  Any other result is an
    # inability to prove whether a live Nginx still holds the removed proxy.
    [ "$active_status" -eq 3 ]
}

nexus_update_ip_certificate_files_are_safe() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local cert_metadata=""
    local key_metadata=""
    [ -n "$cert_file" ] && [ -n "$key_file" ] || return 1
    [ -f "$cert_file" ] && [ ! -L "$cert_file" ] || return 1
    [ -f "$key_file" ] && [ ! -L "$key_file" ] || return 1
    cert_metadata=$(stat -c '%u:%g:%a:%h' -- "$cert_file" 2>/dev/null) || return 1
    key_metadata=$(stat -c '%u:%g:%a:%h' -- "$key_file" 2>/dev/null) || return 1
    case "$cert_metadata" in
        0:0:600:1|0:0:644:1) ;;
        *) return 1 ;;
    esac
    [ "$key_metadata" = 0:0:600:1 ]
}

nexus_ip_certificate_pending_is_trusted() {
    local pending_file="${1:-}"
    local metadata=""
    [ -f "$pending_file" ] && [ ! -L "$pending_file" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$pending_file" 2>/dev/null) || return 1
    [ "$metadata" = 0:0:600:1 ] || return 1
    [ "$(cat -- "$pending_file" 2>/dev/null)" = rr-nexus-ip-cert-pending-v1 ]
}

nexus_ip_certificate_mark_pending() {
    local cert_dir="${1:-}"
    local pending_file="${2:-}"
    local pending_tmp=""
    [ -d "$cert_dir" ] && [ ! -L "$cert_dir" ] || return 1
    if [ -e "$pending_file" ] || [ -L "$pending_file" ]; then
        nexus_ip_certificate_pending_is_trusted "$pending_file"
        return $?
    fi
    pending_tmp=$(mktemp "$cert_dir/.ip-cert-pending.XXXXXX") || return 1
    if ! chmod 600 "$pending_tmp" || \
       ! printf '%s\n' rr-nexus-ip-cert-pending-v1 > "$pending_tmp" || \
       ! sync -f "$pending_tmp" || \
       ! mv -f -- "$pending_tmp" "$pending_file" || \
       ! sync -f "$cert_dir"; then
        [ -e "$pending_tmp" ] || [ -L "$pending_tmp" ] || pending_tmp=""
        [ -z "$pending_tmp" ] || unlink "$pending_tmp" 2>/dev/null || true
        return 1
    fi
    nexus_ip_certificate_pending_is_trusted "$pending_file"
}

nexus_ip_certificate_clear_pending() {
    local cert_dir="${1:-}"
    local pending_file="${2:-}"
    nexus_ip_certificate_pending_is_trusted "$pending_file" || return 1
    unlink "$pending_file" 2>/dev/null || return 1
    sync -f "$cert_dir" || return 1
    [ ! -e "$pending_file" ] && [ ! -L "$pending_file" ]
}

nexus_ip_certificate_pair_is_ready() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local address="${3:-}"
    nexus_update_ip_certificate_files_are_safe "$cert_file" "$key_file" && \
        certificate_identity_matches "$cert_file" "$address" && \
        certificate_private_key_matches "$cert_file" "$key_file"
}

nexus_ip_certificate_restored_state_is_safe() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local site_file="${3:-}"
    local enabled_site="${4:-}"
    if [ -e "$cert_file" ] || [ -L "$cert_file" ] || \
       [ -e "$key_file" ] || [ -L "$key_file" ]; then
        nexus_update_ip_certificate_files_are_safe "$cert_file" "$key_file" && \
            certificate_private_key_matches "$cert_file" "$key_file"
        return $?
    fi
    [ ! -e "$site_file" ] && [ ! -L "$site_file" ] && \
        [ ! -e "$enabled_site" ] && [ ! -L "$enabled_site" ]
}

nexus_emit_ip_certificate_gate_script() {
    cat <<'EOF'
#!/bin/sh
set -eu
[ "$#" -eq 3 ] || exit 1
cert_file=$1
key_file=$2
pending_file=$3
if [ -e "$pending_file" ] || [ -L "$pending_file" ]; then
    exit 1
fi
if [ ! -e "$cert_file" ] && [ ! -L "$cert_file" ] && \
   [ ! -e "$key_file" ] && [ ! -L "$key_file" ]; then
    exit 0
fi
[ -f "$cert_file" ] && [ ! -L "$cert_file" ] && \
    [ -f "$key_file" ] && [ ! -L "$key_file" ] || exit 1
openssl x509 -in "$cert_file" -noout >/dev/null 2>&1 || exit 1
openssl pkey -in "$key_file" -check -noout -passin pass: >/dev/null 2>&1 || exit 1
cert_public=$(openssl x509 -in "$cert_file" -pubkey -noout 2>/dev/null | \
    sha256sum | awk '{print $1}') || exit 1
key_public=$(openssl pkey -in "$key_file" -pubout 2>/dev/null | \
    sha256sum | awk '{print $1}') || exit 1
[ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ]
EOF
}

nexus_emit_ip_certificate_gate_dropin() {
    local gate_script="${1:-}"
    local cert_file="${2:-}"
    local key_file="${3:-}"
    local pending_file="${4:-}"
    local path=""
    for path in "$gate_script" "$cert_file" "$key_file" "$pending_file"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    done
    printf '[Service]\nExecCondition=%s %s %s %s\n' \
        "$gate_script" "$cert_file" "$key_file" "$pending_file"
}

nexus_ip_certificate_gate_script_is_current() {
    local gate_script="${1:-}"
    local expected="" actual=""
    [ -f "$gate_script" ] && [ ! -L "$gate_script" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$gate_script" 2>/dev/null)" = 0:0:755:1 ] || \
        return 1
    expected=$(nexus_emit_ip_certificate_gate_script | sha256sum | awk '{print $1}') || \
        return 1
    actual=$(sha256sum "$gate_script" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ]
}

nexus_ip_certificate_gate_dropin_is_current() {
    local gate_dropin="${1:-}"
    local gate_script="${2:-}"
    local cert_file="${3:-}"
    local key_file="${4:-}"
    local pending_file="${5:-}"
    local expected="" actual=""
    [ -f "$gate_dropin" ] && [ ! -L "$gate_dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$gate_dropin" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    expected=$(nexus_emit_ip_certificate_gate_dropin "$gate_script" \
        "$cert_file" "$key_file" "$pending_file" | sha256sum | awk '{print $1}') || \
        return 1
    actual=$(sha256sum "$gate_dropin" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ]
}

nexus_ip_certificate_gate_artifacts_are_current() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local pending_file="${3:-}"
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    nexus_ip_certificate_gate_script_is_current "$gate_script" && \
        nexus_ip_certificate_gate_dropin_is_current "$gate_dropin" \
            "$gate_script" "$cert_file" "$key_file" "$pending_file"
}

nexus_restore_gate_dropin_is_exact() {
    local restore_dropin="${1:-}"
    local -a lines=()
    [ -f "$restore_dropin" ] && [ ! -L "$restore_dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$restore_dropin" 2>/dev/null)" = 0:0:644:1 ] || \
        return 1
    mapfile -t lines < "$restore_dropin" || return 1
    [ "${#lines[@]}" -eq 2 ] && [ "${lines[0]}" = '[Service]' ] && \
        [ "${lines[1]}" = \
          "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" ]
}

nexus_nginx_exec_condition_set_is_exact() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local pending_file="${3:-}"
    local expect_nexus="${4:-true}"
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    local restore_dropin="${NEXUS_RESTORE_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzz-rr-restore-gate.conf}"
    local load_state="" fragment_path="" dropin_paths="" conditions=""
    local expect_restore=false
    local restore_argv="/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'"
    local nexus_argv="$gate_script $cert_file $key_file $pending_file"
    case "$expect_nexus" in true|false) ;; *) return 1 ;; esac
    if [ -e "$restore_dropin" ] || [ -L "$restore_dropin" ]; then
        nexus_restore_gate_dropin_is_exact "$restore_dropin" || return 1
        expect_restore=true
    fi
    if [ "$expect_nexus" = true ]; then
        nexus_ip_certificate_gate_artifacts_are_current "$cert_file" "$key_file" \
            "$pending_file" || return 1
    fi
    load_state=$(systemctl show nginx.service --property=LoadState --value \
        2>/dev/null) || return 1
    if [ "$load_state" = not-found ]; then
        [ "$expect_nexus" = false ] || return 1
        [ ! -e "$gate_script" ] && [ ! -L "$gate_script" ] && \
            [ ! -e "$gate_dropin" ] && [ ! -L "$gate_dropin" ] || return 1
        fragment_path=$(systemctl show nginx.service --property=FragmentPath \
            --value 2>/dev/null) || return 1
        dropin_paths=$(systemctl show nginx.service --property=DropInPaths --value \
            2>/dev/null) || return 1
        conditions=$(systemctl show nginx.service --property=ExecCondition --value \
            2>/dev/null) || return 1
        [ -z "$fragment_path" ] && [ -z "$dropin_paths" ] && \
            [ -z "$conditions" ] || return 1
        [ ! -e "$gate_script" ] && [ ! -L "$gate_script" ] && \
            [ ! -e "$gate_dropin" ] && [ ! -L "$gate_dropin" ] || return 1
        return 0
    fi
    [ "$load_state" = loaded ] || return 1
    dropin_paths=$(systemctl show nginx.service --property=DropInPaths --value \
        2>/dev/null) || return 1
    conditions=$(systemctl show nginx.service --property=ExecCondition --value \
        2>/dev/null) || return 1
    python3 - "$dropin_paths" "$conditions" "$restore_dropin" \
        "$gate_dropin" "$expect_nexus" "$expect_restore" "$restore_argv" \
        "$nexus_argv" <<'PY'
import os
import re
import stat
import sys

(
    raw_paths,
    raw_conditions,
    restore_dropin,
    nexus_dropin,
    expect_nexus,
    expect_restore,
    restore_argv,
    nexus_argv,
) = sys.argv[1:]
paths = raw_paths.split()
if any("\\" in path or not path.startswith("/") for path in paths):
    raise SystemExit(1)
nexus_name = os.fsencode(os.path.basename(nexus_dropin))
restore_name = os.fsencode(os.path.basename(restore_dropin))
restore_count = 0
nexus_count = 0
for path in paths:
    if os.path.normpath(path) != path:
        raise SystemExit(1)
    name = os.fsencode(os.path.basename(path))
    if not name.endswith(b".conf") or name > nexus_name:
        raise SystemExit(1)
    if path == restore_dropin:
        restore_count += 1
    elif name == restore_name:
        raise SystemExit(1)
    if path == nexus_dropin:
        nexus_count += 1
    elif name == nexus_name:
        raise SystemExit(1)
    if path not in {restore_dropin, nexus_dropin}:
        try:
            info = os.stat(path, follow_symlinks=False)
        except OSError:
            raise SystemExit(1)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_gid != 0
            or info.st_nlink != 1
            or info.st_mode & 0o022
        ):
            raise SystemExit(1)
        try:
            data = open(path, "rb").read(65537)
        except OSError:
            raise SystemExit(1)
        if len(data) > 65536 or b"\0" in data:
            raise SystemExit(1)
        for line in data.decode("utf-8", "strict").splitlines():
            line = line.strip()
            if line and not line.startswith(("#", ";")) and re.match(
                r"ExecCondition\s*=", line
            ):
                raise SystemExit(1)
if restore_count != (1 if expect_restore == "true" else 0) or nexus_count != (
    1 if expect_nexus == "true" else 0
):
    raise SystemExit(1)
records = re.findall(
    r"\{\s*path=(.*?)\s+;\s+argv\[\]=(.*?)\s+;\s+[A-Za-z_][A-Za-z0-9_]*=",
    raw_conditions,
)
expected = []
if expect_restore == "true":
    expected.append(("/bin/sh", restore_argv))
if expect_nexus == "true":
    expected.append((nexus_argv.split(" ", 1)[0], nexus_argv))
if (
    records != expected
    or raw_conditions.count("{") != len(expected)
    or raw_conditions.count("path=") != len(expected)
    or raw_conditions.count("argv[]=") != len(expected)
):
    raise SystemExit(1)
PY
}

nexus_install_ip_certificate_gate() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local pending_file="${3:-}"
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    local script_tmp=""
    local dropin_tmp=""
    local script_dir=""
    local dropin_dir=""
    local path=""
    for path in "$cert_file" "$key_file" "$pending_file" "$gate_script" "$gate_dropin"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    done
    script_dir=$(dirname -- "$gate_script") || return 1
    dropin_dir=$(dirname -- "$gate_dropin") || return 1
    install -d -m 755 "$script_dir" "$dropin_dir" || return 1
    for path in "$script_dir" "$dropin_dir"; do
        [ -d "$path" ] && [ ! -L "$path" ] && \
            [ "$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null)" = 0:0:755 ] || \
            return 1
    done
    script_tmp=$(mktemp "$script_dir/.nexus-ip-cert-gate.XXXXXX") || \
        return 1
    if ! nexus_emit_ip_certificate_gate_script > "$script_tmp"; then
        unlink "$script_tmp" 2>/dev/null || true
        return 1
    fi
    chmod 755 "$script_tmp" || {
        unlink "$script_tmp" 2>/dev/null || true
        return 1
    }
    dropin_tmp=$(mktemp "$dropin_dir/.nexus-ip-cert-gate.XXXXXX") || {
        unlink "$script_tmp" 2>/dev/null || true
        return 1
    }
    if ! nexus_emit_ip_certificate_gate_dropin "$gate_script" "$cert_file" \
       "$key_file" "$pending_file" > "$dropin_tmp" || \
       ! chmod 644 "$dropin_tmp" || \
       ! sync -f "$script_tmp" || ! sync -f "$dropin_tmp" || \
       ! mv -f -- "$script_tmp" "$gate_script" || \
       ! sync -f "$script_dir" || \
       ! mv -f -- "$dropin_tmp" "$gate_dropin" || \
       ! sync -f "$dropin_dir" || \
       ! systemctl daemon-reload >/dev/null 2>&1; then
        [ -e "$script_tmp" ] || [ -L "$script_tmp" ] || script_tmp=""
        [ -e "$dropin_tmp" ] || [ -L "$dropin_tmp" ] || dropin_tmp=""
        [ -z "$script_tmp" ] || unlink "$script_tmp" 2>/dev/null || true
        [ -z "$dropin_tmp" ] || unlink "$dropin_tmp" 2>/dev/null || true
        return 1
    fi
    nexus_ip_certificate_gate_artifacts_are_current "$cert_file" "$key_file" \
        "$pending_file" || return 1
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" true
}

nexus_ip_certificate_gate_allows() {
    local cert_file="${1:-}"
    local key_file="${2:-}"
    local pending_file="${3:-}"
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    nexus_ip_certificate_gate_artifacts_are_current "$cert_file" "$key_file" \
        "$pending_file" && \
        "$gate_script" "$cert_file" "$key_file" "$pending_file"
}

nexus_remove_ip_certificate_gate() {
    local cert_file="${1:-/etc/rr-nexus/certs/ip.crt}"
    local key_file="${2:-/etc/rr-nexus/certs/ip.key}"
    local pending_file="${3:-/etc/rr-nexus/certs/.ip-cert-pending}"
    local gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    local path=""
    for path in "$cert_file" "$key_file" "$pending_file" "$gate_script" "$gate_dropin"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 2
    done

    if [ -e "$gate_dropin" ] || [ -L "$gate_dropin" ]; then
        nexus_ip_certificate_gate_dropin_is_current "$gate_dropin" \
            "$gate_script" "$cert_file" "$key_file" "$pending_file" || return 2
        if [ ! -e "$gate_script" ] && [ ! -L "$gate_script" ]; then
            # Repair the safe executable half first so a daemon still holding
            # the drop-in never references a missing program during cleanup.
            nexus_install_ip_certificate_gate "$cert_file" "$key_file" \
                "$pending_file" || return 2
        else
            nexus_ip_certificate_gate_script_is_current "$gate_script" || return 2
        fi
        unlink "$gate_dropin" 2>/dev/null || return 2
        sync -f "$(dirname -- "$gate_dropin")" || return 2
    elif [ -e "$gate_script" ] || [ -L "$gate_script" ]; then
        nexus_ip_certificate_gate_script_is_current "$gate_script" || return 2
    fi

    systemctl daemon-reload >/dev/null 2>&1 || return 2
    nexus_nginx_exec_condition_set_is_exact "$cert_file" "$key_file" \
        "$pending_file" false || return 2
    if [ -e "$gate_script" ] || [ -L "$gate_script" ]; then
        nexus_ip_certificate_gate_script_is_current "$gate_script" || return 2
        unlink "$gate_script" 2>/dev/null || return 2
        sync -f "$(dirname -- "$gate_script")" || return 2
    fi
    [ ! -e "$gate_dropin" ] && [ ! -L "$gate_dropin" ] && \
        [ ! -e "$gate_script" ] && [ ! -L "$gate_script" ]
}

nexus_publish_ip_certificate_pair() {
    local cert_tmp="${1:-}"
    local key_tmp="${2:-}"
    local cert_file="${3:-}"
    local key_file="${4:-}"
    local cert_dir="${5:-}"
    local pending_file="${6:-}"
    local address="${7:-}"
    [ -f "$cert_tmp" ] && [ ! -L "$cert_tmp" ] && \
        [ -f "$key_tmp" ] && [ ! -L "$key_tmp" ] || return 1
    nexus_ip_certificate_mark_pending "$cert_dir" "$pending_file" || return 1
    mv -f -- "$key_tmp" "$key_file" || return 1
    sync -f "$cert_dir" || return 1
    mv -f -- "$cert_tmp" "$cert_file" || return 1
    sync -f "$cert_dir" || return 1
    nexus_ip_certificate_pair_is_ready "$cert_file" "$key_file" "$address" || \
        return 1
    nexus_ip_certificate_clear_pending "$cert_dir" "$pending_file"
}

nexus_enable_public_ip_https() {
    local address="$1"
    local port="$2"
    local panel_output_name="${3:-}"
    local certificate_mode="${4:-}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    local cert_file="$cert_dir/ip.crt"
    local key_file="$cert_dir/ip.key"
    local pending_file="$cert_dir/.ip-cert-pending"
    local site="$nginx_available_dir/rr-nexus-ip.conf"
    local site_tmp=""
    local cert_tmp=""
    local key_tmp=""
    local transaction_dir=""
    local transaction_ok=true
    local restore_ok=true
    local panel_created=false
    local operation_status=0
    local replace_cert=false
    local candidate_reload_attempted=false
    local nginx_was_active=false
    local nginx_was_enabled=false
    local trusted_ip_certificate=false
    local path=""
    local index=0
    local -a managed_paths=()
    local -a managed_present=()
    if [ -n "$panel_output_name" ]; then
        [[ "$panel_output_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
        printf -v "$panel_output_name" '%s' false
    fi
    is_ip_version "$address" 4 || is_ip_version "$address" 6 || return 1
    is_valid_port "$port" || return 1
    [ "$port" != 80 ] && [ "$port" != 7900 ] || return 1
    if [ -z "$certificate_mode" ] && [ -r "$NEXUS_CONFIG_FILE" ]; then
        certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    fi
    case "${certificate_mode:-legacy-self-signed}" in
        acme-ip-shortlived|pending-acme-ip)
            is_global_ip_version "$address" 4 || \
                is_global_ip_version "$address" 6 || return 1
            declare -F nexus_ip_acme_runtime_is_ready >/dev/null 2>&1 || return 1
            nexus_ip_acme_runtime_is_ready "$address" || return 1
            trusted_ip_certificate=true
            ;;
        legacy-self-signed) ;;
        *) return 1 ;;
    esac
    certificate_mode="${certificate_mode:-legacy-self-signed}"
    # A foreign collision must stop this command before apt, certificate or
    # Nginx state can be changed.
    nexus_nginx_managed_paths_are_owned || return 2

    systemctl is-active --quiet nginx >/dev/null 2>&1 && nginx_was_active=true
    systemctl is-enabled --quiet nginx >/dev/null 2>&1 && nginx_was_enabled=true
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] && [ "$nginx_was_active" != true ]; then
        echo -e "${RED}[失败] 热更新候选不会启动原本停止的 Nginx。${RESET}" >&2
        return 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    if ! command -v nginx >/dev/null 2>&1; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            echo -e "${RED}[失败] 热更新候选缺少 Nginx；未运行 apt 安装。${RESET}" >&2
            return 1
        fi
        apt-get install -y nginx >/dev/null 2>&1 || return 1
    elif [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ]; then
        # Keep the existing interactive repair behavior outside an update.
        apt-get install -y nginx >/dev/null 2>&1 || return 1
    fi
    if [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ]; then
        install -d -m 700 "$cert_dir" || return 1
    elif ! nexus_update_ip_certificate_files_are_safe "$cert_file" "$key_file"; then
        echo -e "${RED}[失败] 热更新候选拒绝不安全的公网 IP 面板证书文件。${RESET}" >&2
        return 1
    fi
    if [ ! -s "$cert_file" ] || [ ! -s "$key_file" ] || \
       ! certificate_identity_matches "$cert_file" "$address" || \
       ! certificate_private_key_matches "$cert_file" "$key_file"; then
        if [ "$trusted_ip_certificate" = true ]; then
            echo -e "${RED}[失败] 可信 IP 证书尚未完整发布，已拒绝回退自签证书。${RESET}" >&2
            return 1
        elif [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            echo -e "${RED}[失败] 热更新候选不会生成新的公网 IP 面板证书。${RESET}" >&2
            return 1
        fi
        replace_cert=true
        cert_tmp=$(mktemp "$cert_dir/.ip.crt.XXXXXX") || return 1
        key_tmp=$(mktemp "$cert_dir/.ip.key.XXXXXX") || { rm -f "$cert_tmp"; return 1; }
        if ! (umask 077; openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$key_tmp" -out "$cert_tmp" -subj "/CN=${address}" \
            -addext "subjectAltName=IP:${address}" >/dev/null 2>&1); then
            rm -f "$cert_tmp" "$key_tmp"
            return 1
        fi
        chmod 600 "$key_tmp" || { rm -f "$cert_tmp" "$key_tmp"; return 1; }
        chmod 644 "$cert_tmp" || { rm -f "$cert_tmp" "$key_tmp"; return 1; }
    fi

    install -d -m 755 "$nginx_available_dir" "$nginx_enabled_dir" || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    site_tmp=$(mktemp "$nginx_available_dir/.rr-nexus-ip.XXXXXX") || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    if ! nexus_emit_nginx_ip_site "$address" "$port" "$certificate_mode" \
        false > "$site_tmp"; then
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    fi
    chmod 644 "$site_tmp" || {
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    }
    cmp -s -- "$site_tmp" \
        <(nexus_emit_nginx_ip_site "$address" "$port" "$certificate_mode" false) || {
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 2
    }

    # Only RR-owned files take part in this transaction.  In particular, the
    # distro default site and user-created Nginx sites must never be removed or
    # rewritten while Nexus changes access mode.
    managed_paths=(
        "$site"
        "$nginx_enabled_dir/rr-nexus.conf"
        "$nginx_enabled_dir/rr-nexus-port.conf"
        "$nginx_enabled_dir/rr-nexus-ip.conf"
        "$cert_file"
        "$key_file"
    )
    nexus_nginx_managed_paths_are_owned || {
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 2
    }
    transaction_dir=$(mktemp -d "${TMPDIR:-/tmp}/rr-nexus-nginx.XXXXXX") || {
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    }
    mkdir -p "$transaction_dir/items" || {
        rm -rf "$transaction_dir"
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    }
    for index in "${!managed_paths[@]}"; do
        path="${managed_paths[$index]}"
        managed_present[$index]=false
        if [ -e "$path" ] || [ -L "$path" ]; then
            if nexus_nginx_managed_path_is_fixed "$path" && \
               ! nexus_nginx_managed_path_is_owned "$path"; then
                rm -rf "$transaction_dir"
                rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
                return 2
            fi
            if ! cp -a -- "$path" "$transaction_dir/items/$index"; then
                rm -rf "$transaction_dir"
                rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
                return 1
            fi
            managed_present[$index]=true
        fi
    done

    # Install and prove the reboot gate before publishing either half of the
    # certificate pair.  The gate is deliberately durable across a failed
    # candidate transaction: leaving it behind is safe for the old matched
    # pair and is required to block a reboot after SIGKILL mid-publication.
    if ! nexus_install_ip_certificate_gate "$cert_file" "$key_file" \
        "$pending_file"; then
        rm -rf "$transaction_dir"
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    fi
    if [ -e "$pending_file" ] || [ -L "$pending_file" ]; then
        if ! nexus_ip_certificate_pending_is_trusted "$pending_file"; then
            rm -rf "$transaction_dir"
            rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
            nexus_firewall_fail_closed \
                'Nexus IP 证书 pending marker 不可信，拒绝启动/重载 Nginx'
            return $?
        fi
        if nexus_ip_certificate_pair_is_ready "$cert_file" "$key_file" \
            "$address"; then
            nexus_ip_certificate_clear_pending "$cert_dir" "$pending_file" || {
                rm -rf "$transaction_dir"
                rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
                nexus_firewall_fail_closed \
                    'Nexus IP 证书已匹配但 pending marker 无法安全清除'
                return $?
            }
        elif [ "$replace_cert" != true ]; then
            rm -rf "$transaction_dir"
            rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
            nexus_firewall_fail_closed \
                'Nexus IP 证书 pending 状态与当前证书对不一致'
            return $?
        fi
    fi

    # Stage every file and link change before asking Nginx to load it.  Any
    # failed validation/service operation below restores this exact snapshot.
    if [ "$replace_cert" = true ]; then
        if nexus_publish_ip_certificate_pair "$cert_tmp" "$key_tmp" \
            "$cert_file" "$key_file" "$cert_dir" "$pending_file" \
            "$address"; then
            key_tmp=""
            cert_tmp=""
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            # 7.1.0 created both the public certificate and its private key as
            # 0600.  Preserve that stricter certificate mode during an update;
            # newly generated certificates remain 0644.  Never chmod or follow
            # links in the candidate transaction.
            nexus_update_ip_certificate_files_are_safe \
                "$cert_file" "$key_file" || transaction_ok=false
        elif ! chmod 600 "$key_file" || ! chmod 644 "$cert_file"; then
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        if nexus_nginx_managed_paths_are_owned && \
           nexus_nginx_publish_candidate "$site_tmp" "$site"; then
            site_tmp=""
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        for path in "$nginx_enabled_dir/rr-nexus.conf" \
            "$nginx_enabled_dir/rr-nexus-port.conf" \
            "$nginx_enabled_dir/rr-nexus-ip.conf"; do
            nexus_nginx_unlink_owned_path "$path" || {
                transaction_ok=false
                break
            }
        done
    fi
    if [ "$transaction_ok" = true ] && \
       ! nexus_nginx_publish_enabled_link "$site" \
           "$nginx_enabled_dir/rr-nexus-ip.conf"; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && \
       { ! nexus_ip_certificate_pair_is_ready "$cert_file" "$key_file" \
             "$address" || \
         ! nexus_ip_certificate_gate_allows "$cert_file" "$key_file" \
             "$pending_file"; }; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && ! nginx -t >/dev/null 2>&1; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ]; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            systemctl is-active --quiet nginx >/dev/null 2>&1 || transaction_ok=false
        elif ! systemctl enable --now nginx >/dev/null 2>&1; then
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        candidate_reload_attempted=true
        if nexus_ip_certificate_gate_allows "$cert_file" "$key_file" \
               "$pending_file" && \
           systemctl reload nginx >/dev/null 2>&1; then
            :
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ] && \
       [ "$trusted_ip_certificate" = true ]; then
        # A successful reload only proves that the signal/ExecReload command
        # returned.  Old workers can still serve the previous valid
        # certificate for the same IP if the new generation was not adopted.
        # Bind first activation to the exact live leaf before opening the
        # externally reachable panel port; renewal already uses this same
        # loopback TLS+CA+identity+leaf-hash proof in module 86.
        if ! declare -F nexus_ip_acme_served_leaf_matches_live \
                >/dev/null 2>&1 || \
           ! nexus_ip_acme_served_leaf_matches_live "$address" "$port"; then
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        nexus_firewall_open_accounted "$port" tcp panel_created || {
            operation_status=$?
            transaction_ok=false
        }
    fi

    if [ "$transaction_ok" != true ]; then
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        # A failure after successful publication may already have cleared the
        # first marker.  Recreate and fsync it before the first rollback file
        # removal so a crash while restoring cert/key is equally fail-closed.
        if [ "$replace_cert" = true ] && \
           ! nexus_ip_certificate_mark_pending "$cert_dir" "$pending_file"; then
            rm -rf "$transaction_dir"
            printf '%s\n' \
                '[错误] Nexus IP 证书回滚前无法建立持久 pending marker；未继续改写证书。' >&2
            nexus_firewall_fail_closed \
                'Nexus IP 证书回滚门禁无法持久化'
            return $?
        fi
        for path in "${managed_paths[@]}"; do
            if nexus_nginx_managed_path_is_fixed "$path"; then
                if { [ -e "$path" ] || [ -L "$path" ]; } && \
                   ! nexus_nginx_unlink_owned_path "$path"; then
                    restore_ok=false
                fi
            elif ! rm -f -- "$path"; then
                restore_ok=false
            fi
        done
        for index in "${!managed_paths[@]}"; do
            if [ "${managed_present[$index]}" = true ]; then
                path="${managed_paths[$index]}"
                if nexus_nginx_managed_path_is_fixed "$path"; then
                    if [ -e "$path" ] || [ -L "$path" ] || \
                       ! nexus_nginx_restore_snapshot_path \
                            "$transaction_dir/items/$index" "$path"; then
                        restore_ok=false
                    fi
                elif ! cp -a -- "$transaction_dir/items/$index" "$path"; then
                    restore_ok=false
                fi
            fi
        done

        if [ "$replace_cert" = true ]; then
            if nexus_ip_certificate_restored_state_is_safe "$cert_file" \
                "$key_file" "$site" \
                "$nginx_enabled_dir/rr-nexus-ip.conf"; then
                nexus_ip_certificate_clear_pending "$cert_dir" \
                    "$pending_file" || restore_ok=false
            else
                restore_ok=false
            fi
        fi

        # Restore both dimensions of the original unit state.  Once a reload
        # was attempted its outcome can be ambiguous, so reload the restored
        # site (or restart as a last resort) before reporting the failure.
        systemctl daemon-reload >/dev/null 2>&1 || restore_ok=false
        if [ "$restore_ok" = true ] && [ "$nginx_was_active" = true ]; then
            if ! systemctl is-active --quiet nginx >/dev/null 2>&1; then
                systemctl start nginx >/dev/null 2>&1 || restore_ok=false
            elif [ "$candidate_reload_attempted" = true ]; then
                systemctl reload nginx >/dev/null 2>&1 || \
                    systemctl restart nginx >/dev/null 2>&1 || restore_ok=false
            fi
        elif [ "$restore_ok" = true ]; then
            systemctl stop nginx >/dev/null 2>&1 || restore_ok=false
        fi
        if [ "$restore_ok" = true ] && [ "$nginx_was_enabled" = true ]; then
            systemctl enable nginx >/dev/null 2>&1 || restore_ok=false
        elif [ "$restore_ok" = true ]; then
            systemctl disable nginx >/dev/null 2>&1 || restore_ok=false
        fi
        if ! nexus_firewall_compensate_public_opens false "$panel_created" \
            "$port"; then
            restore_ok=false
        fi
        rm -rf "$transaction_dir"
        if [ "$restore_ok" != true ]; then
            printf '%s\n' '[错误] Nexus Nginx 配置切换失败，且自动回滚未完整完成。' >&2
            nexus_firewall_fail_closed \
                'Nexus IP HTTPS 切换失败且无法证明代理/防火墙原态'
            return $?
        fi
        if [ "$operation_status" -ge 2 ] && [ "$panel_created" != true ]; then
            nexus_firewall_fail_closed \
                'Nexus IP HTTPS 防火墙写入状态不确定且无本次 ownership 证据'
            return $?
        fi
        # A writer=0/post-validate failure has been compensated and re-proved
        # closed above, so it is now a determinate failed activation.
        return 1
    fi

    rm -rf "$transaction_dir"
    [ -z "$panel_output_name" ] || \
        printf -v "$panel_output_name" '%s' "$panel_created"
    return 0
}

nexus_firewall_tuple_array_add() {
    local output_name="${1:-}"
    local tuple_port="${2:-}"
    local tuple_proto="${3:-}"
    local record=""
    local -n output_ref="$output_name"
    is_valid_port "$tuple_port" || return 2
    case "$tuple_proto" in tcp|udp) ;; *) return 2 ;; esac
    for record in "${output_ref[@]}"; do
        [ "$record" = "${tuple_port}|${tuple_proto}" ] && return 0
    done
    output_ref+=("${tuple_port}|${tuple_proto}")
}

nexus_collect_configured_public_firewall_tuples() {
    local output_name="${1:-}"
    local config_file="${2:-$NEXUS_CONFIG_FILE}"
    local mode="" domain="" panel_port="" domain_is_ip=false certificate_mode=""
    local -n output_ref="$output_name"
    [ -r "$config_file" ] || return 0
    mode=$(jq -r '.mode // empty' "$config_file" 2>/dev/null) || return 2
    [ "$mode" = local ] && return 0
    [ "$mode" = public ] || return 2
    domain=$(jq -r '.domain // empty' "$config_file" 2>/dev/null) || return 2
    panel_port=$(jq -r '.public_port // empty' "$config_file" 2>/dev/null) || return 2
    is_valid_port "$panel_port" || return 2
    nexus_firewall_tuple_array_add "$output_name" "$panel_port" tcp || return 2
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    if [ "$domain_is_ip" = true ]; then
        certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "$config_file" 2>/dev/null) || return 2
        case "$certificate_mode" in
            acme-ip-shortlived|pending-acme-ip)
                is_global_ip_version "$domain" 4 || \
                    is_global_ip_version "$domain" 6 || return 2
                nexus_firewall_tuple_array_add "$output_name" 80 tcp || return 2
                ;;
            legacy-self-signed) ;;
            *) return 2 ;;
        esac
    else
        [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 2
        nexus_firewall_tuple_array_add "$output_name" 80 tcp || return 2
    fi
    # Keep the nameref live until all writes above have completed.
    : "${#output_ref[@]}"
}

nexus_collect_managed_proxy_firewall_tuples() {
    local output_name="${1:-}"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local records=""
    local record="" tuple_port="" tuple_proto=""
    local -n output_ref="$output_name"
    # Never derive firewall ownership from an arbitrary same-name site.
    nexus_nginx_managed_paths_are_owned || return 2
    records=$(python3 - "$NEXUS_NGINX_SITE" "${NEXUS_NGINX_SITE}.port" \
        "$nginx_available_dir/rr-nexus-ip.conf" <<'PY'
import os
import pathlib
import re
import stat
import sys

ports = set()
for raw_path in sys.argv[1:]:
    path = pathlib.Path(raw_path)
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        continue
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) & 0o022
    ):
        raise SystemExit(2)
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(
        r"^\s*listen\s+(?:\[[^\]]+\]:)?([0-9]{1,5})\s+ssl(?:\s|;)",
        text,
        re.MULTILINE,
    ):
        port = int(match.group(1))
        if not 1 <= port <= 65535:
            raise SystemExit(2)
        ports.add(port)
    if "/.well-known/acme-challenge/" in text and re.search(
        r"^\s*listen\s+(?:\[[^\]]+\]:)?80(?:\s|;)", text, re.MULTILINE
    ):
        ports.add(80)

for port in sorted(ports):
    print(f"{port}|tcp")
PY
    ) || return 2
    while IFS= read -r record; do
        [ -n "$record" ] || continue
        IFS='|' read -r tuple_port tuple_proto <<< "$record"
        [ "$record" = "${tuple_port}|${tuple_proto}" ] || return 2
        nexus_firewall_tuple_array_add "$output_name" "$tuple_port" \
            "$tuple_proto" || return 2
    done <<< "$records"
    : "${#output_ref[@]}"
}

nexus_reconcile_firewall_tuple_list() {
    local input_name="${1:-}"
    local record="" tuple_port="" tuple_proto=""
    local operation_status=0
    local aggregate_status=0
    local -n input_ref="$input_name"
    for record in "${input_ref[@]}"; do
        IFS='|' read -r tuple_port tuple_proto <<< "$record"
        operation_status=0
        nexus_firewall_reconcile_without_nexus "$tuple_port" "$tuple_proto" || \
            operation_status=$?
        if [ "$operation_status" -ge 2 ]; then
            aggregate_status=2
        elif [ "$operation_status" -ne 0 ] && [ "$aggregate_status" -eq 0 ]; then
            aggregate_status=1
        fi
    done
    return "$aggregate_status"
}

nexus_deactivate_public_access() {
    local config_file="${1:-$NEXUS_CONFIG_FILE}"
    local reconcile_status=0
    local -a retired_tuples=()
    nexus_collect_configured_public_firewall_tuples retired_tuples \
        "$config_file" || {
        nexus_firewall_fail_closed \
            'Nexus 公网入口上下文不可证明，拒绝在运行状态下继续转换'
        return $?
    }
    nexus_collect_managed_proxy_firewall_tuples retired_tuples || {
        nexus_firewall_fail_closed \
            'Nexus 受管代理上下文不可证明，拒绝在运行状态下继续转换'
        return $?
    }
    nexus_remove_public_proxy || {
        nexus_firewall_fail_closed \
            'Nexus 代理撤回失败，无法证明旧公网入口已失效'
        return $?
    }
    nexus_reconcile_firewall_tuple_list retired_tuples || reconcile_status=$?
    if [ "$reconcile_status" -ge 2 ]; then
        nexus_firewall_fail_closed \
            'Nexus 公网入口撤回后无法证明防火墙已按剩余消费者收敛'
        return $?
    fi
    return "$reconcile_status"
}

nexus_reconcile_public_proxy() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    local mode="" domain="" port="" acme_email="" domain_is_ip=false
    local certificate_mode=""
    local http_created=false panel_created=false operation_status=0
    local previous_generation="" cleanup_status=0
    local firewall_indeterminate=false
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE") || return 1
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE") || return 1
    port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE") || return 1
    is_valid_port "$port" || return 1
    if [ "$mode" = local ]; then
        nexus_deactivate_public_access "$NEXUS_CONFIG_FILE"
        return $?
    fi
    [ "$mode" = public ] || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    if [ "$domain_is_ip" = true ]; then
        certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
        case "$certificate_mode" in
            acme-ip-shortlived)
                is_global_ip_version "$domain" 4 || \
                    is_global_ip_version "$domain" 6 || return 1
                declare -F nexus_ip_acme_runtime_is_ready >/dev/null 2>&1 || return 1
                nexus_ip_acme_runtime_is_ready "$domain" || return 1
                nexus_enable_public_ip_https "$domain" "$port" "" \
                    acme-ip-shortlived
                return $?
                ;;
            pending-acme-ip)
                # A candidate update may verify an already active trusted
                # runtime, but it must not advance an interrupted external
                # installation transaction behind the rollback snapshot.
                [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ] || return 1
                declare -F nexus_ip_acme_recover >/dev/null 2>&1 || return 1
                declare -F nexus_ip_acme_disarm >/dev/null 2>&1 || return 1
                previous_generation=$(nexus_service_active_generation) || return 1
                nexus_ip_acme_recover || return 1
                nexus_enable_public_ip_https "$domain" "$port" "" \
                    pending-acme-ip || return 1
                nexus_public_proxy_health_check || return 1
                if nexus_commit_ip_acme_active_generation \
                    "$previous_generation"; then
                    return 0
                else
                    operation_status=$?
                fi
                nexus_ip_acme_disarm >/dev/null 2>&1 || operation_status=2
                nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || \
                    cleanup_status=$?
                [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
                [ "$operation_status" -ge 2 ] && return "$operation_status"
                return 1
                ;;
            legacy-self-signed)
                nexus_enable_public_ip_https "$domain" "$port" "" \
                    legacy-self-signed
                return $?
                ;;
            *) return 1 ;;
        esac
    fi
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 1
    [ "$port" != 80 ] && [ "$port" != 7900 ] || return 1
    if [ -s "${le_live_root}/${domain}/fullchain.pem" ] && \
       { [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] || [ -s "$NEXUS_NGINX_SITE" ] || \
         [ -s "${NEXUS_NGINX_SITE}.port" ]; }; then
        subscription_certificate_pair_valid \
            "${le_live_root}/${domain}/fullchain.pem" \
            "${le_live_root}/${domain}/privkey.pem" "$domain" || return 1
        rr_certbot_webroot_lineage_is_renewable "$domain" || return 1
        nexus_certificate_deploy_hook_is_ready || return 1
        # 旧版本的自定义端口站点可能缺少登录限流共享区或订阅日志保护。
        # 每次更新都从当前可信配置重建，不能只因为旧文件能通过 nginx -t
        # 就继续沿用。
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            command -v nginx >/dev/null 2>&1 && \
                systemctl is-active --quiet nginx >/dev/null 2>&1 || {
                printf '%s\n' '热更新候选不会安装或启动原本不可用的 Nginx。' >&2
                return 1
            }
        fi
        nexus_write_nginx_custom_port "$domain" "$port" || {
            operation_status=$?
            nexus_abort_public_activation "$operation_status" "$http_created" \
                "$panel_created" "$port" || operation_status=$?
            return "$operation_status"
        }
        if [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ]; then
            systemctl enable --now nginx >/dev/null 2>&1 || {
                operation_status=$?
                nexus_abort_public_activation "$operation_status" \
                    "$http_created" "$panel_created" "$port" || operation_status=$?
                return "$operation_status"
            }
        fi
        nexus_firewall_open_accounted 80 tcp http_created || {
            operation_status=$?
            [ "$operation_status" -ge 2 ] && [ "$http_created" != true ] && \
                firewall_indeterminate=true
            nexus_abort_public_activation "$operation_status" "$http_created" \
                "$panel_created" "$port" "$firewall_indeterminate" || operation_status=$?
            return "$operation_status"
        }
        nexus_firewall_open_accounted "$port" tcp panel_created || {
            operation_status=$?
            [ "$operation_status" -ge 2 ] && [ "$panel_created" != true ] && \
                firewall_indeterminate=true
            nexus_abort_public_activation "$operation_status" "$http_created" \
                "$panel_created" "$port" "$firewall_indeterminate" || operation_status=$?
            return "$operation_status"
        }
        rr_certbot_renewal_runtime_is_ready "$domain" || {
            operation_status=$?
            nexus_abort_public_activation "$operation_status" "$http_created" \
                "$panel_created" "$port" || operation_status=$?
            return "$operation_status"
        }
        return 0
    fi
    acme_email=$(jq -r '.acme_email // empty' "$NEXUS_CONFIG_FILE") || return 1
    [[ "$acme_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || {
        printf '公网域名备份缺少 ACME 邮箱，无法在目标机安全重建证书。\n' >&2
        return 1
    }
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '热更新候选不会删除代理站点或新签发面板证书。' >&2
        return 1
    fi
    nexus_remove_public_proxy || return 2
    nexus_enable_public_https "$domain" "$acme_email" "$port"
}

nexus_public_proxy_health_check() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    local mode="" domain="" port="" health_host="" domain_is_ip=false
    local certificate_mode="" trusted_ip_certificate=false
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE") || return 1
    [ "$mode" = public ] || return 0
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE") || return 1
    port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE") || return 1
    is_valid_port "$port" || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    if [ "$domain_is_ip" = true ]; then
        certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
        case "$certificate_mode" in
            acme-ip-shortlived|pending-acme-ip)
                is_global_ip_version "$domain" 4 || \
                    is_global_ip_version "$domain" 6 || return 1
                declare -F nexus_ip_acme_runtime_is_ready >/dev/null 2>&1 || return 1
                nexus_ip_acme_runtime_is_ready "$domain" || return 1
                trusted_ip_certificate=true
                ;;
            legacy-self-signed) ;;
            *) return 1 ;;
        esac
        nexus_ip_certificate_gate_allows \
            /etc/rr-nexus/certs/ip.crt /etc/rr-nexus/certs/ip.key \
            /etc/rr-nexus/certs/.ip-cert-pending || return 1
        certificate_identity_matches /etc/rr-nexus/certs/ip.crt "$domain" || return 1
        if [ "$trusted_ip_certificate" = true ]; then
            # IP certificates are intentionally short-lived (about 160h).
            # Six hours leaves a bounded repair window without rejecting a
            # freshly issued certificate for being shorter than seven days.
            openssl x509 -in /etc/rr-nexus/certs/ip.crt -noout \
                -checkend 21600 >/dev/null 2>&1 || return 1
        else
            openssl x509 -in /etc/rr-nexus/certs/ip.crt -noout \
                -checkend 604800 >/dev/null 2>&1 || return 1
        fi
    else
        certificate_identity_matches "/etc/letsencrypt/live/${domain}/fullchain.pem" "$domain" || return 1
        openssl x509 -in "/etc/letsencrypt/live/${domain}/fullchain.pem" \
            -noout -checkend 604800 >/dev/null 2>&1 || return 1
    fi
    # Exercise the real TLS/Nginx proxy locally.  The external VPS job checks
    # the public route and firewall separately so NAT hairpin support is not a
    # prerequisite for a safe local rollback decision.
    if [ "$domain_is_ip" = true ]; then
        health_host="$domain"
        is_ip_version "$domain" 6 && health_host="[${domain}]"
        if [ "$trusted_ip_certificate" = true ]; then
            # Connect to loopback while retaining the public IP as the TLS
            # verification identity.  No insecure/self-signed fallback exists.
            curl -fSs --noproxy '*' --proto '=https' \
                --connect-timeout 3 --max-time 8 \
                --connect-to "${health_host}:${port}:127.0.0.1:${port}" \
                "https://${health_host}:${port}/healthz" >/dev/null
        else
            # Historical self-signed installs stay panel-only.
            curl -fkSs --connect-timeout 3 --max-time 8 \
                -H "Host: ${health_host}" \
                "https://127.0.0.1:${port}/healthz" >/dev/null
        fi
    else
        curl -fSs --connect-timeout 3 --max-time 8 \
            --resolve "${domain}:${port}:127.0.0.1" \
            "https://${domain}:${port}/healthz" >/dev/null
    fi
}

nexus_activate_ip_acme_existing() {
    local requested_address="${1:-}" requested_email="${2:-}"
    local configured_address="" configured_canonical="" configured_email=""
    local certificate_mode=""
    local panel_port="" previous_generation="" rollback_generation=""
    local status=0 cleanup_status=0
    nexus_is_installed || return 1
    previous_generation=$(nexus_service_active_generation) || return 1
    nexus_local_backend_health_check || return 1
    declare -F nexus_ip_acme_normalize_address >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_is_global_address >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_install >/dev/null 2>&1 && \
        declare -F nexus_ip_acme_disarm >/dev/null 2>&1 || return 1
    nexus_ip_acme_normalize_address "$requested_address" requested_address || \
        return 1
    nexus_ip_acme_is_global_address "$requested_address" || return 1
    nexus_ip_acme_email_is_valid "$requested_email" || return 1
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_CONFIG_FILE" 2>/dev/null)" = 0:0:600:1 ] || return 1
    [ "$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)" = public ] || return 1
    configured_address=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    configured_email=$(jq -r '.acme_email // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    certificate_mode=$(jq -r '.certificate_mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    panel_port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    nexus_ip_acme_normalize_address "$configured_address" \
        configured_canonical || return 1
    [ "$configured_canonical" = "$requested_address" ] && \
        [ "$configured_email" = "$requested_email" ] || return 1
    if [ "$configured_address" != "$configured_canonical" ]; then
        nexus_set_ip_certificate_domain "$configured_address" \
            "$configured_canonical" || return 1
        configured_address="$configured_canonical"
    fi
    is_valid_port "$panel_port" && [ "$panel_port" != 80 ] && \
        [ "$panel_port" != 7900 ] || return 1
    case "$certificate_mode" in
        acme-ip-shortlived)
            nexus_reconcile_public_proxy && nexus_public_proxy_health_check && \
                nexus_restart_service_generation_checked \
                    "$previous_generation" >/dev/null && \
                nexus_backend_subscription_mode_is_active && \
                nexus_backend_real_subscription_token_is_reachable && return 0
            status=$?
            # The same crash barrier as initial promotion: withdraw Nginx and
            # firewall before persisting pending, while the old active process
            # may still be alive on loopback.
            nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || \
                cleanup_status=$?
            if [ "$cleanup_status" -ne 0 ]; then
                nexus_ip_acme_disarm >/dev/null 2>&1 || cleanup_status=2
                return "$cleanup_status"
            elif nexus_set_certificate_mode \
                acme-ip-shortlived pending-acme-ip; then
                rollback_generation=$(nexus_service_active_generation \
                    2>/dev/null) || status=2
                if [ "$status" -lt 2 ]; then
                    nexus_restart_service_generation_checked \
                        "$rollback_generation" >/dev/null && \
                        nexus_backend_subscription_mode_is_closed || status=2
                fi
            else
                status=2
            fi
            nexus_ip_acme_disarm >/dev/null 2>&1 || status=2
            nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || \
                cleanup_status=$?
            [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
            [ "$status" -ge 2 ] && return "$status"
            return 1
            ;;
        pending-acme-ip) ;;
        *) return 1 ;;
    esac

    nexus_firewall_open_accounted 80 tcp >/dev/null || status=$?
    if [ "$status" -eq 0 ]; then
        nexus_ip_acme_install "$requested_address" "$requested_email" && \
            nexus_enable_public_ip_https "$requested_address" "$panel_port" \
                "" pending-acme-ip && \
            nexus_public_proxy_health_check && \
            nexus_commit_ip_acme_active_generation "$previous_generation" || \
                status=$?
    fi
    if [ "$status" -eq 0 ]; then
        return 0
    fi
    nexus_ip_acme_disarm >/dev/null 2>&1 || status=2
    nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || cleanup_status=$?
    [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
    [ "$status" -ge 2 ] && return "$status"
    status=1
    return "$status"
}

nexus_ip_acme_uninstall_intent_path() {
    printf '%s\n' "${NEXUS_IP_ACME_UNINSTALL_INTENT:-${NEXUS_DATA_DIR}/ip-acme-uninstall-intent.json}"
}

nexus_ip_acme_uninstall_intent_is_safe() {
    local intent="${1:-}" address="" normalized="" email="" mode=""
    local certificate_mode="" public_port=""
    [ -f "$intent" ] && [ ! -L "$intent" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$intent" 2>/dev/null)" = 0:0:600:1 ] || \
        return 1
    jq -e '
        type == "object" and .rr_ip_acme_uninstall_intent == 1 and
        .mode == "public" and
        (.certificate_mode == "pending-acme-ip" or
         .certificate_mode == "acme-ip-shortlived") and
        (.domain | type) == "string" and
        (.acme_email | type) == "string" and
        (.public_port | type) == "number"
    ' "$intent" >/dev/null 2>&1 || return 1
    address=$(jq -r '.domain' "$intent" 2>/dev/null) || return 1
    email=$(jq -r '.acme_email' "$intent" 2>/dev/null) || return 1
    mode=$(jq -r '.mode' "$intent" 2>/dev/null) || return 1
    certificate_mode=$(jq -r '.certificate_mode' "$intent" 2>/dev/null) || \
        return 1
    public_port=$(jq -r '.public_port' "$intent" 2>/dev/null) || return 1
    [ "$mode" = public ] && \
        case "$certificate_mode" in
            pending-acme-ip|acme-ip-shortlived) true ;;
            *) false ;;
        esac || return 1
    declare -F nexus_ip_acme_normalize_address >/dev/null 2>&1 || return 1
    nexus_ip_acme_normalize_address "$address" normalized || return 1
    [ "$address" = "$normalized" ] && \
        nexus_ip_acme_is_global_address "$address" && \
        nexus_ip_acme_email_is_valid "$email" && \
        is_valid_port "$public_port" && [ "$public_port" != 80 ] && \
        [ "$public_port" != 7900 ]
}

nexus_write_ip_acme_uninstall_intent() {
    local source_config="${1:-}" intent="" intent_dir="" temporary=""
    local source_address="" intent_address="" source_email="" intent_email=""
    local source_port="" intent_port=""
    intent=$(nexus_ip_acme_uninstall_intent_path) || return 2
    intent_dir=$(dirname -- "$intent") || return 2
    [ "$intent_dir" = "$NEXUS_DATA_DIR" ] || return 2
    install -d -m 700 "$intent_dir" || return 2
    if [ -e "$intent" ] || [ -L "$intent" ]; then
        nexus_ip_acme_uninstall_intent_is_safe "$intent" || return 2
        source_address=$(jq -r '.domain // empty' "$source_config" 2>/dev/null) || \
            return 2
        source_email=$(jq -r '.acme_email // empty' "$source_config" 2>/dev/null) || \
            return 2
        source_port=$(jq -r '.public_port // empty' "$source_config" 2>/dev/null) || \
            return 2
        intent_address=$(jq -r '.domain' "$intent" 2>/dev/null) || return 2
        intent_email=$(jq -r '.acme_email' "$intent" 2>/dev/null) || return 2
        intent_port=$(jq -r '.public_port' "$intent" 2>/dev/null) || return 2
        [ "$source_address:$source_email:$source_port" = \
          "$intent_address:$intent_email:$intent_port" ] || return 2
        printf '%s\n' "$intent"
        return 0
    fi
    temporary=$(mktemp "$intent_dir/.ip-acme-uninstall-intent.XXXXXX") || \
        return 2
    if ! jq '.rr_ip_acme_uninstall_intent = 1' "$source_config" > "$temporary" || \
       ! nexus_publish_config_candidate "$temporary" "$intent" || \
       ! nexus_ip_acme_uninstall_intent_is_safe "$intent"; then
        [ -e "$temporary" ] || [ -L "$temporary" ] || temporary=""
        [ -z "$temporary" ] || unlink "$temporary" 2>/dev/null || true
        return 2
    fi
    printf '%s\n' "$intent"
}

nexus_ip_acme_owned_state_matches_uninstall_intent() {
    local intent="${1:-}" address=""
    local state_root="${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}"
    nexus_ip_acme_uninstall_intent_is_safe "$intent" || return 1
    if [ ! -e "$state_root" ] && [ ! -L "$state_root" ]; then
        # A prior cleanup may already have removed the core state before a
        # later gate/live cleanup failed. The durable root-owned intent is the
        # retry authority for those remaining exact-owned artifacts.
        return 0
    fi
    declare -F nexus_ip_acme_owned_state_is_safe >/dev/null 2>&1 || return 1
    address=$(jq -r '.domain' "$intent" 2>/dev/null) || return 1
    nexus_ip_acme_owned_state_is_safe "$address"
}

nexus_ensure_local_service_generation() {
    local public_config_snapshot="${1:-}" generation=""
    local cleanup_status=0
    if ! generation=$(nexus_service_active_generation 2>/dev/null); then
        nexus_service_inactive_generation_is_proved
        return $?
    fi
    nexus_backend_subscription_mode_is_closed && return 0
    if nexus_restart_service_generation_checked "$generation" >/dev/null && \
       nexus_backend_subscription_mode_is_closed; then
        return 0
    fi
    nexus_deactivate_public_access "$public_config_snapshot" || cleanup_status=$?
    [ "$cleanup_status" -eq 0 ] || return "$cleanup_status"
    return 1
}

nexus_uninstall_ip_acme_existing() {
    local mode="" certificate_mode="" status=0
    local config_snapshot="" intent_path=""
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    local -a retired_tuples=()
    nexus_is_installed || return 1
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_CONFIG_FILE" 2>/dev/null)" = \
          0:0:600:1 ] || return 1
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    certificate_mode=$(jq -r '.certificate_mode // empty' \
        "$NEXUS_CONFIG_FILE" 2>/dev/null) || return 1
    declare -F nexus_ip_acme_uninstall >/dev/null 2>&1 || return 2
    intent_path=$(nexus_ip_acme_uninstall_intent_path) || return 2
    case "$mode:$certificate_mode" in
        public:acme-ip-shortlived|public:pending-acme-ip)
            config_snapshot=$(nexus_write_ip_acme_uninstall_intent \
                "$NEXUS_CONFIG_FILE") || return $?
            ;;
        local:none)
            # Idempotent continuation after the public->local publication was
            # already committed but core/gate/live cleanup was interrupted.
            nexus_ip_acme_uninstall_intent_is_safe "$intent_path" || return 1
            config_snapshot="$intent_path"
            ;;
        *) return 1 ;;
    esac
    nexus_ip_acme_owned_state_matches_uninstall_intent "$config_snapshot" || \
        return 2
    nexus_collect_configured_public_firewall_tuples retired_tuples \
        "$config_snapshot" || return 2
    nexus_collect_managed_proxy_firewall_tuples retired_tuples || return 2
    # Publish the non-public intent first, then prove a fresh backend process
    # loaded it. Certificate/account evidence stays intact until this barrier.
    if [ "$mode:$certificate_mode" = local:none ]; then
        nexus_ensure_local_service_generation "$config_snapshot" || return $?
    else
        nexus_transition_to_local_generation "$config_snapshot" || return $?
    fi
    nexus_remove_public_proxy || {
        nexus_firewall_fail_closed \
            'Nexus IP ACME 卸载无法证明旧公网代理已撤回'
        return $?
    }
    nexus_reconcile_firewall_tuple_list retired_tuples || status=$?
    if [ "$status" -ne 0 ]; then
        [ "$status" -lt 2 ] && return "$status"
        nexus_firewall_fail_closed \
            'Nexus IP ACME 卸载无法证明防火墙已按剩余消费者收敛'
        return $?
    fi
    nexus_ip_acme_uninstall || return $?
    nexus_remove_ip_certificate_gate "$cert_dir/ip.crt" "$cert_dir/ip.key" \
        "$cert_dir/.ip-cert-pending" || return 2
    for _nexus_ip_cert_path in "$cert_dir/ip.crt" "$cert_dir/ip.key" \
        "$cert_dir/.ip-cert-pending"; do
        if [ -e "$_nexus_ip_cert_path" ] || [ -L "$_nexus_ip_cert_path" ]; then
            [ -f "$_nexus_ip_cert_path" ] && [ ! -L "$_nexus_ip_cert_path" ] && \
                [ "$(stat -c '%u:%g:%h' -- "$_nexus_ip_cert_path" 2>/dev/null)" = 0:0:1 ] || return 2
            unlink "$_nexus_ip_cert_path" 2>/dev/null || return 2
        fi
    done
    sync -f "$cert_dir" || return 2
    nexus_ip_acme_uninstall_intent_is_safe "$config_snapshot" || return 2
    unlink "$config_snapshot" 2>/dev/null || return 2
    sync -f "$NEXUS_DATA_DIR" || return 2
    return 0
}

nexus_local_backend_health_check() {
    # Type=simple can become active before the Python application has bound
    # its socket or can serve requests.  Prove the fixed loopback backend
    # itself before an installer exposes Nginx/firewall state or discards its
    # rollback evidence.  Keep this bounded so a broken backend cannot hang an
    # interactive install indefinitely.
    local attempt=0
    while [ "$attempt" -lt 10 ]; do
        if curl --fail --silent --show-error --noproxy '*' --proto '=http' \
            --connect-timeout 1 --max-time 2 \
            http://127.0.0.1:7900/healthz >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt 10 ] && sleep 1
    done
    return 1
}

nexus_start_service() {
    local listen_port="${1:-7900}"
    local nginx_was_running=false
    local started_generation=""
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
        nexus_systemctl_restart_checked >/dev/null 2>&1
        sleep 2
        if systemctl is-active --quiet rr-nexus; then
            break
        fi
        retry=$((retry + 1))
        [ $retry -lt 3 ] && echo -e "${YELLOW}Nexus 启动失败，第 ${retry} 次重试……${RESET}"
    done

    # 恢复 Nginx（如果之前停过）
    [ "$nginx_was_running" = true ] && systemctl start nginx 2>/dev/null || true

    if ! started_generation=$(nexus_service_active_generation); then
        echo -e "${RED}Nexus 启动失败，或 systemd 运行身份/代际无法精确证明。${RESET}"
        return 1
    fi
    if ! nexus_local_backend_health_check; then
        echo -e "${RED}Nexus 进程已启动，但本机健康端点未就绪。${RESET}" >&2
        return 1
    fi
    echo -e "${GREEN}Nexus 已启动（内部 7900，外部 ${listen_port}）。${RESET}"
    return 0
}

nexus_abort_install_transaction() {
    local transaction_dir="${1:-}"
    local had_config="${2:-false}"
    local had_service="${3:-false}"
    local service_may_run="${4:-false}"
    local original_status="${5:-1}"
    local preserve_pending_ip_config="${6:-false}"
    local cleanup_status=0
    [ -d "$transaction_dir" ] || return 2
    case "$preserve_pending_ip_config" in true|false) ;; *) return 2 ;; esac

    if [ "$service_may_run" = true ]; then
        systemctl disable --now rr-nexus.service >/dev/null 2>&1 || \
            cleanup_status=2
        [ "$cleanup_status" -ne 0 ] || \
            nexus_service_stopped_disabled_is_exact || cleanup_status=2
    fi
    nexus_remove_public_proxy || cleanup_status=2
    if [ "$cleanup_status" -ne 0 ]; then
        printf '%s\n' \
            "[错误] Nexus 安装失败，且无法证明服务/代理已完全撤回；当前配置与事务证据保留在 ${transaction_dir}。" >&2
        nexus_firewall_fail_closed \
            'Nexus 安装回滚无法证明服务与公网代理均已撤回'
        return $?
    fi

    rm -f "$NEXUS_SERVICE_FILE" || {
        nexus_firewall_fail_closed 'Nexus 安装回滚无法移除候选服务元数据'
        return $?
    }
    if [ "$had_service" = true ]; then
        install -m 644 "$transaction_dir/service.before" \
            "$NEXUS_SERVICE_FILE" || {
            nexus_firewall_fail_closed 'Nexus 安装回滚无法恢复原服务元数据'
            return $?
        }
    fi
    systemctl daemon-reload >/dev/null 2>&1 || {
        nexus_firewall_fail_closed 'Nexus 安装回滚后 systemd 状态无法证明'
        return $?
    }

    # An indeterminate firewall result keeps the current public config as
    # ownership evidence.  A proved compensation restores the exact metadata
    # that existed before this install attempt.
    if [ "$original_status" -lt 2 ]; then
        if [ "$preserve_pending_ip_config" = true ]; then
            [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] && \
                [ "$(stat -c '%u:%g:%a:%h' -- "$NEXUS_CONFIG_FILE" 2>/dev/null)" = 0:0:600:1 ] && \
                [ "$(jq -r '.certificate_mode // empty' "$NEXUS_CONFIG_FILE" 2>/dev/null)" = pending-acme-ip ] || {
                nexus_firewall_fail_closed \
                    'Nexus IP ACME 安装回滚无法证明持久 pending 意图'
                return $?
            }
            rm -rf "$transaction_dir" || return 2
            return 1
        fi
        rm -f "$NEXUS_CONFIG_FILE" || {
            nexus_firewall_fail_closed 'Nexus 安装回滚无法移除候选公网配置'
            return $?
        }
        if [ "$had_config" = true ]; then
            install -m 600 "$transaction_dir/config.before" \
                "$NEXUS_CONFIG_FILE" || {
                nexus_firewall_fail_closed 'Nexus 安装回滚无法恢复原配置'
                return $?
            }
        fi
        rm -rf "$transaction_dir"
        return 1
    fi
    return "$original_status"
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
    echo -e "${CYAN}3. 公网 IP 可信模式：无需域名，Let's Encrypt 短期 IP 证书 + HTTPS 订阅${RESET}"
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
    local install_transaction_dir=""
    local install_had_config=false
    local install_had_service=false
    local install_http_created=false
    local install_panel_created=false
    local install_backend_generation=""
    local operation_status=0
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
    local install_transaction_root="${NEXUS_INSTALL_TRANSACTION_ROOT:-${NEXUS_DATA_DIR}/install-transactions}"
    install -d -m 700 "$NEXUS_DATA_DIR" "$install_transaction_root" || return 1
    install_transaction_dir=$(mktemp -d \
        "${install_transaction_root}/install.XXXXXX") || return 1
    chmod 700 "$install_transaction_dir" || {
        rm -rf "$install_transaction_dir"
        return 1
    }
    if [ -e "$NEXUS_CONFIG_FILE" ] || [ -L "$NEXUS_CONFIG_FILE" ]; then
        [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || {
            rm -rf "$install_transaction_dir"
            return 1
        }
        install -m 600 "$NEXUS_CONFIG_FILE" \
            "$install_transaction_dir/config.before" || {
            rm -rf "$install_transaction_dir"
            return 1
        }
        install_had_config=true
    fi
    if [ -e "$NEXUS_SERVICE_FILE" ] || [ -L "$NEXUS_SERVICE_FILE" ]; then
        [ -f "$NEXUS_SERVICE_FILE" ] && [ ! -L "$NEXUS_SERVICE_FILE" ] || {
            rm -rf "$install_transaction_dir"
            return 1
        }
        install -m 644 "$NEXUS_SERVICE_FILE" \
            "$install_transaction_dir/service.before" || {
            rm -rf "$install_transaction_dir"
            return 1
        }
        install_had_service=true
    fi
    # A prior interrupted install must not stay publicly reachable while new
    # administrator/backend state is being prepared.
    nexus_deactivate_public_access "$NEXUS_CONFIG_FILE" || {
        operation_status=$?
        rm -rf "$install_transaction_dir"
        return "$operation_status"
    }
    case "$choice" in
        1)
            nexus_write_config local "" "$port" "$stats_port" "$ENTRY_IP_RAW" \
                "$traffic_mode_val" "" none || {
                operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" false \
                    "$operation_status" || operation_status=$?
                return "$operation_status"
            }
            ;;
        2)
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
                if [[ "$confirm" != "YES" ]]; then
                    echo -e "${RED}已取消。${RESET}"
                    nexus_abort_install_transaction "$install_transaction_dir" \
                        "$install_had_config" "$install_had_service" false 1 || \
                        operation_status=$?
                    return "${operation_status:-1}"
                fi
            elif [ -z "$resolved_ip" ]; then
                echo -e "${YELLOW}无法检测 DNS，请确认域名已指向本服务器 IP。${RESET}"
                read -rp "已确认？输入 YES 继续: " confirm
                if [[ "$confirm" != "YES" ]]; then
                    echo -e "${RED}已取消。${RESET}"
                    nexus_abort_install_transaction "$install_transaction_dir" \
                        "$install_had_config" "$install_had_service" false 1 || \
                        operation_status=$?
                    return "${operation_status:-1}"
                fi
            else
                echo -e "${GREEN}DNS 解析正确: ${domain} -> ${resolved_ip}${RESET}"
            fi
            while true; do
                read -rp "Let's Encrypt 通知邮箱: " email
                [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
                echo -e "${RED}邮箱格式无效。${RESET}"
            done
            nexus_write_config public "${domain,,}" "$port" "$stats_port" \
                "$ENTRY_IP_RAW" "$traffic_mode_val" "$email" certbot-domain || {
                operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" false \
                    "$operation_status" || operation_status=$?
                return "$operation_status"
            }
            ;;
        3)
            is_global_ip_version "$ENTRY_IP_RAW" 4 || \
                is_global_ip_version "$ENTRY_IP_RAW" 6 || {
                echo -e "${RED}当前入口不是可签发的全局公网 IP，已拒绝联网请求。${RESET}" >&2
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" false 1 || \
                    operation_status=$?
                return "${operation_status:-1}"
            }
            while true; do
                read -rp "Let's Encrypt 通知邮箱: " email
                [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] && break
                echo -e "${RED}邮箱格式无效。${RESET}"
            done
            nexus_write_config public "$ENTRY_IP_RAW" "$port" "$stats_port" \
                "$ENTRY_IP_RAW" "$traffic_mode_val" "$email" pending-acme-ip || {
                operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" false \
                    "$operation_status" || operation_status=$?
                return "$operation_status"
            }
            ;;
        *)
            echo -e "${RED}输入无效，未安装。${RESET}"
            nexus_abort_install_transaction "$install_transaction_dir" \
                "$install_had_config" "$install_had_service" false 1 || \
                operation_status=$?
            return "${operation_status:-1}"
            ;;
    esac

    local reset_admin=""
    if [ -f "$NEXUS_DB_FILE" ] && \
       sqlite3 "$NEXUS_DB_FILE" 'SELECT 1 FROM admins LIMIT 1;' 2>/dev/null | grep -q '^1$'; then
        read -rp "检测到原管理员账号，是否同时重置账号、密码与恢复码？[y/N]: " reset_admin
        if [[ "$reset_admin" =~ ^[Yy]$ ]]; then
            nexus_prompt_admin || {
                operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" false \
                    "$operation_status" || operation_status=$?
                return "$operation_status"
            }
        else
            echo -e "${GREEN}已保留原管理员账号、密码、恢复码和设备数据库。${RESET}"
        fi
    else
        nexus_prompt_admin || {
            operation_status=$?
            nexus_abort_install_transaction "$install_transaction_dir" \
                "$install_had_config" "$install_had_service" false \
                "$operation_status" || operation_status=$?
            return "$operation_status"
        }
    fi
    nexus_enable_traffic_engine || {
        operation_status=$?
        nexus_abort_install_transaction "$install_transaction_dir" \
            "$install_had_config" "$install_had_service" false \
            "$operation_status" || operation_status=$?
        return "$operation_status"
    }
    generate_nexus_device_subscriptions || {
        operation_status=$?
        nexus_abort_install_transaction "$install_transaction_dir" \
            "$install_had_config" "$install_had_service" false \
            "$operation_status" || operation_status=$?
        return "$operation_status"
    }
    # Start backend on 7900, Nginx will listen on user port
    nexus_start_service "$port" || {
        operation_status=$?
        nexus_abort_install_transaction "$install_transaction_dir" \
            "$install_had_config" "$install_had_service" true \
            "$operation_status" || operation_status=$?
        return "$operation_status"
    }
    if [ "$choice" = 3 ]; then
        install_backend_generation=$(nexus_service_active_generation) || {
            operation_status=$?
            nexus_abort_install_transaction "$install_transaction_dir" \
                "$install_had_config" "$install_had_service" true \
                "$operation_status" true || operation_status=$?
            return "$operation_status"
        }
    fi
    case "$choice" in
        1) ;;
        2)
            nexus_enable_public_https "${domain,,}" "$email" "$port" \
                install_http_created install_panel_created || {
                operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" || operation_status=$?
                return "$operation_status"
            }
            ;;
        3)
            echo -e "${YELLOW}正在配置可信公网 IP 短期证书与 HTTPS 订阅……${RESET}"
            declare -F nexus_ip_acme_install >/dev/null 2>&1 && \
                declare -F nexus_ip_acme_disarm >/dev/null 2>&1 || {
                operation_status=1
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" true || operation_status=$?
                return "$operation_status"
            }
            export DEBIAN_FRONTEND=noninteractive
            command -v nginx >/dev/null 2>&1 || \
                apt-get install -y nginx >/dev/null 2>&1 || {
                operation_status=1
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" true || operation_status=$?
                return "$operation_status"
            }
            nexus_firewall_open_accounted 80 tcp install_http_created || {
                operation_status=$?
                nexus_abort_public_activation "$operation_status" \
                    "$install_http_created" "$install_panel_created" "$port" || \
                    operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" true || operation_status=$?
                return "$operation_status"
            }
            nexus_ip_acme_install "$ENTRY_IP_RAW" "$email" && \
                nexus_enable_public_ip_https "$ENTRY_IP_RAW" "$port" \
                    install_panel_created pending-acme-ip || {
                operation_status=$?
                nexus_ip_acme_disarm >/dev/null 2>&1 || operation_status=2
                nexus_abort_public_activation "$operation_status" \
                    "$install_http_created" "$install_panel_created" "$port" || \
                    operation_status=$?
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" true || operation_status=$?
                return "$operation_status"
            }
            ;;
    esac
    if [ "$choice" != 1 ]; then
        nexus_public_proxy_health_check || {
            operation_status=$?
            echo -e "${RED}[失败] Nexus 本机 TLS/Nginx 代理健康检查未通过，正在撤回本次公网入口。${RESET}" >&2
            nexus_abort_public_activation "$operation_status" \
                "$install_http_created" "$install_panel_created" "$port" || \
                operation_status=$?
            if [ "$choice" = 3 ]; then
                nexus_ip_acme_disarm >/dev/null 2>&1 || operation_status=2
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" true || operation_status=$?
            else
                nexus_abort_install_transaction "$install_transaction_dir" \
                    "$install_had_config" "$install_had_service" true \
                    "$operation_status" false || operation_status=$?
            fi
            return "$operation_status"
        }
    fi
    if [ "$choice" = 3 ]; then
        nexus_commit_ip_acme_active_generation \
            "$install_backend_generation" || {
            operation_status=$?
            nexus_ip_acme_disarm >/dev/null 2>&1 || operation_status=2
            nexus_abort_public_activation "$operation_status" \
                "$install_http_created" "$install_panel_created" "$port" || \
                operation_status=$?
            nexus_abort_install_transaction "$install_transaction_dir" \
                "$install_had_config" "$install_had_service" true \
                "$operation_status" true || operation_status=$?
            return "$operation_status"
        }
    fi
    rm -rf "$install_transaction_dir"
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
        echo -e "${GREEN}Let's Encrypt 可信短期 IP 证书已生效，个人设备可直接使用 HTTPS 订阅。${RESET}"
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
            test_url=$(nexus_panel_url)
            curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
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
    return 0
}

nexus_reset_admin() {
    nexus_is_installed || { echo -e "${RED}RR Nexus 尚未完整安装。${RESET}"; sleep 2; return 1; }
    nexus_prompt_admin || return 1
    nexus_systemctl_restart_checked >/dev/null 2>&1 || return 1
    read -rp "按回车键返回……"
}

nexus_uninstall() {
    echo -e "${RED}这会关闭 RR Nexus，并删除面板配置；节点协议和主订阅不受影响。${RESET}"
    local confirm=""
    read -rp "确认卸载请输入 y: " confirm
    [ "$confirm" = "y" ] || { echo -e "${YELLOW}已取消卸载。${RESET}"; return 0; }
    local config_dir=""
    local config_snapshot=""
    local certificate_mode=""
    local service_status=0
    local firewall_status=0
    local -a retired_tuples=()
    config_dir=$(dirname -- "$NEXUS_CONFIG_FILE") || return 1
    [ -n "$config_dir" ] && [ "$config_dir" != / ] || return 1
    [ -f "$NEXUS_CONFIG_FILE" ] && [ ! -L "$NEXUS_CONFIG_FILE" ] || {
        echo -e "${RED}[失败] Nexus 配置不存在或不是安全常规文件；卸载尚未修改服务。${RESET}" >&2
        return 1
    }
    install -d -m 700 "$NEXUS_DATA_DIR" || return 1
    config_snapshot=$(mktemp "$NEXUS_DATA_DIR/.uninstall-config.XXXXXX") || return 1
    if ! install -m 600 "$NEXUS_CONFIG_FILE" "$config_snapshot"; then
        rm -f "$config_snapshot"
        return 1
    fi
    nexus_collect_configured_public_firewall_tuples retired_tuples \
        "$config_snapshot" || {
        echo -e "${RED}[失败] 无法从配置快照证明 Nexus 公网端口；服务和代理均未修改。${RESET}" >&2
        nexus_firewall_fail_closed \
            'Nexus 卸载无法证明原公网端口 ownership'
        return $?
    }
    nexus_collect_managed_proxy_firewall_tuples retired_tuples || {
        echo -e "${RED}[失败] 无法安全解析 RR 管理的代理站点；服务和代理均未修改。${RESET}" >&2
        nexus_firewall_fail_closed \
            'Nexus 卸载无法证明受管代理拓扑'
        return $?
    }

    systemctl disable --now rr-nexus >/dev/null 2>&1 || {
        echo -e "${RED}[失败] rr-nexus 无法停止并禁用；配置快照保留在 ${config_snapshot}。${RESET}" >&2
        nexus_firewall_fail_closed 'Nexus 卸载停止/禁用 rr-nexus 的结果不确定'
        return $?
    }
    if systemctl is-active --quiet rr-nexus >/dev/null 2>&1; then
        echo -e "${RED}[失败] rr-nexus 在停止后仍处于活动状态；配置快照保留在 ${config_snapshot}。${RESET}" >&2
        nexus_firewall_fail_closed 'Nexus 卸载无法停止 rr-nexus'
        return $?
    else
        service_status=$?
    fi
    if [ "$service_status" -ne 3 ]; then
        echo -e "${RED}[失败] 无法证明 rr-nexus 已停止；配置快照保留在 ${config_snapshot}。${RESET}" >&2
        nexus_firewall_fail_closed 'Nexus 卸载无法证明 rr-nexus inactive'
        return $?
    fi
    nexus_remove_public_proxy || {
        echo -e "${RED}[失败] Nexus 代理移除或 Nginx 重载未完成；配置快照保留在 ${config_snapshot}。${RESET}" >&2
        nexus_firewall_fail_closed 'Nexus 卸载无法证明公网代理已撤回'
        return $?
    }
    nexus_reconcile_firewall_tuple_list retired_tuples || firewall_status=$?
    if [ "$firewall_status" -ne 0 ]; then
        echo -e "${RED}[失败] Nexus 防火墙清理未能完整持久化并验证；配置与快照均已保留，未报告卸载成功。${RESET}" >&2
        if [ "$firewall_status" -ge 2 ]; then
            nexus_firewall_fail_closed \
                'Nexus 卸载防火墙清理状态不确定'
            return $?
        fi
        return "$firewall_status"
    fi
    certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
        "$config_snapshot" 2>/dev/null) || return 1
    if [ "$certificate_mode" = acme-ip-shortlived ] || \
       [ "$certificate_mode" = pending-acme-ip ] || \
       [ -e "${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}" ] || \
       [ -L "${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}" ]; then
        declare -F nexus_ip_acme_uninstall >/dev/null 2>&1 || {
            echo -e "${RED}[失败] 当前运行时缺少 IP ACME 精确卸载器；已保留证书账户与配置。${RESET}" >&2
            return 2
        }
        nexus_ip_acme_uninstall || {
            echo -e "${RED}[失败] IP ACME 续签单元或自有状态未能精确清理；已停止卸载。${RESET}" >&2
            return 2
        }
    fi
    if ! nexus_remove_ip_certificate_gate \
        "$(dirname -- "$NEXUS_CONFIG_FILE")/certs/ip.crt" \
        "$(dirname -- "$NEXUS_CONFIG_FILE")/certs/ip.key" \
        "$(dirname -- "$NEXUS_CONFIG_FILE")/certs/.ip-cert-pending"; then
        echo -e "${RED}[失败] Nexus IP 证书启动门禁无法精确移除；配置与快照已保留，未报告卸载成功。${RESET}" >&2
        nexus_firewall_fail_closed \
            'Nexus 卸载无法证明 Nginx IP 证书门禁已精确清理'
        return $?
    fi
    rm -f "$NEXUS_SERVICE_FILE" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || {
        echo -e "${RED}[失败] systemd 重载失败；配置与快照仍保留，未报告卸载成功。${RESET}" >&2
        return 1
    }
    rm -rf -- "$config_dir" || return 1
    rm -f "$config_snapshot" || return 1
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
    return 0
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
        echo -e " 安全：Argon2id 密码、登录限流、CSRF、同源标签页 Bearer 会话、恢复码、审计日志"
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
            4) nexus_systemctl_restart_checked && echo -e "${GREEN}已重启。${RESET}" || echo -e "${RED}重启失败。${RESET}"; sleep 2 ;;
            5) nexus_uninstall ;;
            0) return ;;
            *) echo "输入无效"; sleep 1 ;;
        esac
    done
}
