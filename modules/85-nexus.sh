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
NEXUS_CORE_RELEASE_REVISION=1
# Bootstrap trust anchor for the last audited traffic-core bytes published
# before immutable releases were enabled.  The mutable release metadata and
# its checksum file are deliberately not trusted: executable size and SHA-256
# are pinned in this product release.  A matching immutable current core
# always takes precedence when one exists.
NEXUS_CORE_PINNED_VERSION="1.13.19"
NEXUS_CORE_PINNED_RELEASE_TAG="rr-nexus-core-v1.13.19"
NEXUS_CORE_PINNED_PRODUCT_VERSION="7.1.1"
NEXUS_CORE_PINNED_FALLBACK_UPSTREAM_TAGS="v1.13.20 v1.13.21"
NEXUS_CORE_PINNED_SOURCE_COMMIT="b5ebaa1fc0f2b94256180b95468e73ef53caa27d"
NEXUS_CORE_PINNED_AUDIT_RUN="33071792235"
NEXUS_CORE_PINNED_AMD64_SIZE="20610257"
NEXUS_CORE_PINNED_AMD64_SHA256="9397dcd049cc1ff7f4fa26c29cc25791c7026e40897cc2072b85cd257b6338ad"
NEXUS_CORE_PINNED_ARM64_SIZE="18978144"
NEXUS_CORE_PINNED_ARM64_SHA256="28c8ed10d203fa77286d0a25deb0377aa33598c08c7b3de256c7d779529716f0"
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
    # 域名模式（真证书）；IP 直连（自签证书）
    if [ -n "$domain" ] && [ "$domain" != "ip" ] && [ "$domain_is_ip" = false ]; then
        if [ "${public_port:-443}" = "443" ]; then
            printf 'https://%s' "$domain"
        else
            printf 'https://%s:%s' "$domain" "${public_port:-443}"
        fi
    else
        local host=""
        host="${ssh_host:-$domain}"
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
    "$SINGBOX_BIN" version 2>/dev/null | grep -qw 'with_v2ray_api'
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
    [[ "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    version="${upstream_tag#v}"
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
        (.assets | type) == "array" and
        ([.assets[].name] | sort) == $assets and
        all(.assets[];
            (.name | type) == "string" and
            .browser_download_url == ($base + .name))
    ' "$release_file" >/dev/null || return 1
}

nexus_fetch_traffic_core_release() {
    local target_file="$1"
    local upstream_file="${target_file}.upstream"
    local upstream_tag=""
    local release_tag=""
    local http_code=""
    local curl_result=0
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$upstream_file" "$NEXUS_CORE_UPSTREAM_API" || return 1
    upstream_tag=$(jq -r '.tag_name // empty' "$upstream_file")
    [[ "$upstream_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
    release_tag="rr-nexus-core-${upstream_tag}-r${NEXUS_CORE_RELEASE_REVISION}"
    if http_code=$(curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 40 --write-out '%{http_code}' \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$target_file" "${NEXUS_CORE_RELEASE_API}/${release_tag}"); then
        curl_result=0
    else
        curl_result=$?
    fi
    if [ "$curl_result" -ne 0 ]; then
        rm -f "$target_file"
        # Only an authoritative absence of this exact, validated upstream
        # release may select the product-pinned bootstrap bytes.  Transport,
        # authorization, rate-limit and malformed-response failures stay
        # fail-closed instead of silently downgrading.
        [ "$curl_result" -eq 22 ] && [ "$http_code" = 404 ] && return 44
        return 1
    fi
    [ "$http_code" = 200 ] || { rm -f "$target_file"; return 1; }
    nexus_validate_traffic_core_release "$target_file" "$upstream_tag"
}

nexus_pinned_core_asset_field() {
    local architecture="$1"
    local field="$2"
    case "${architecture}:${field}" in
        amd64:size) printf '%s\n' "$NEXUS_CORE_PINNED_AMD64_SIZE" ;;
        amd64:sha256) printf '%s\n' "$NEXUS_CORE_PINNED_AMD64_SHA256" ;;
        arm64:size) printf '%s\n' "$NEXUS_CORE_PINNED_ARM64_SIZE" ;;
        arm64:sha256) printf '%s\n' "$NEXUS_CORE_PINNED_ARM64_SHA256" ;;
        *) return 1 ;;
    esac
}

nexus_validate_pinned_core_constants() {
    local architecture=""
    local expected_size=""
    local expected_sha256=""
    [[ "$NEXUS_CORE_PINNED_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [ "$NEXUS_CORE_PINNED_RELEASE_TAG" = \
        "rr-nexus-core-v${NEXUS_CORE_PINNED_VERSION}" ] || return 1
    version_ge "$NEXUS_CORE_PINNED_VERSION" "$MIN_SINGBOX_VERSION" || return 1
    [ "$NEXUS_CORE_PINNED_PRODUCT_VERSION" = "${SCRIPT_VERSION:-}" ] || return 1
    [ "$NEXUS_CORE_PINNED_FALLBACK_UPSTREAM_TAGS" = \
        "v1.13.20 v1.13.21" ] || return 1
    [[ "$NEXUS_CORE_PINNED_SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || return 1
    [[ "$NEXUS_CORE_PINNED_AUDIT_RUN" =~ ^[1-9][0-9]+$ ]] || return 1
    for architecture in amd64 arm64; do
        expected_size=$(nexus_pinned_core_asset_field "$architecture" size) || return 1
        expected_sha256=$(nexus_pinned_core_asset_field "$architecture" sha256) || return 1
        [[ "$expected_size" =~ ^[1-9][0-9]{0,8}$ ]] && \
            [ "$expected_size" -le 104857600 ] || return 1
        [[ "$expected_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
    done
}

nexus_pinned_core_fallback_allowed() {
    local upstream_file="$1"
    local upstream_tag=""
    [ -f "$upstream_file" ] && [ ! -L "$upstream_file" ] || return 1
    nexus_validate_pinned_core_constants || return 1
    upstream_tag=$(jq -r '.tag_name // empty' "$upstream_file" 2>/dev/null) || return 1
    case "$upstream_tag" in
        v1.13.20|v1.13.21) return 0 ;;
        *) return 1 ;;
    esac
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
            SING_BOX_VERSION|SING_BOX_TAG|SOURCE_COMMIT|RR_BUILDER_COMMIT|RR_CORE_RELEASE|BUILD_TAG|SOURCE) ;;
            *) return 1 ;;
        esac
        [ -z "${fields[$key]+present}" ] || return 1
        fields["$key"]="$value"
    done < "$build_info"

    [ "${#fields[@]}" -eq 7 ] || return 1
    [ "${fields[SING_BOX_VERSION]:-}" = "$expected_version" ] || return 1
    [ "${fields[SING_BOX_TAG]:-}" = "v${expected_version}" ] || return 1
    source_commit="${fields[SOURCE_COMMIT]:-}"
    [[ "$source_commit" =~ ^[0-9a-f]{40}$ ]] || return 1
    [ "${fields[RR_BUILDER_COMMIT]:-}" = "$expected_builder_commit" ] || return 1
    [ "${fields[RR_CORE_RELEASE]:-}" = "$expected_release" ] || return 1
    [ "${fields[BUILD_TAG]:-}" = with_v2ray_api ] || return 1
    [ "${fields[SOURCE]:-}" = \
        "https://github.com/SagerNet/sing-box/tree/v${expected_version}" ] || return 1
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
    local fetch_result=0
    work_dir=$(mktemp -d /tmp/rr-nexus-version.XXXXXX) || return 1
    release_json="$work_dir/release.json"
    build_info="$work_dir/BUILD_INFO"
    if nexus_fetch_traffic_core_release "$release_json"; then
        fetch_result=0
    else
        fetch_result=$?
        if [ "$fetch_result" -ne 44 ] || \
           ! nexus_pinned_core_fallback_allowed "${release_json}.upstream"; then
            rm -rf "$work_dir"
            return 1
        fi
        rm -rf "$work_dir"
        printf '%s\n' "$NEXUS_CORE_PINNED_VERSION"
        return 0
    fi
    release_tag=$(jq -r '.tag_name // empty' "$release_json")
    builder_commit=$(jq -r '.target_commitish // empty' "$release_json")
    source_tag=$(jq -r '.tag_name // empty' "${release_json}.upstream")
    version="${source_tag#v}"
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
    local expected_size=""
    local pinned_core=false
    local fetch_result=0

    local release_tag=""
    if nexus_fetch_traffic_core_release "$release_json"; then
        fetch_result=0
        release_tag=$(jq -r '.tag_name // empty' "$release_json")
        builder_commit=$(jq -r '.target_commitish // empty' "$release_json")
        source_tag=$(jq -r '.tag_name // empty' "${release_json}.upstream")
        version="${source_tag#v}"
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
    else
        fetch_result=$?
        # The current immutable core may lag a just-published upstream patch.
        # Fall back only to the executable bytes pinned above; never accept
        # checksum or provenance metadata from the mutable legacy release.
        [ "$fetch_result" -eq 44 ] && \
            nexus_pinned_core_fallback_allowed "${release_json}.upstream" || return 1
        rm -f "$release_json" "$checksums" "$build_info"
        pinned_core=true
        source_tag=$(jq -r '.tag_name // empty' "${release_json}.upstream") || return 1
        version="$NEXUS_CORE_PINNED_VERSION"
        release_tag="$NEXUS_CORE_PINNED_RELEASE_TAG"
        echo "[供应链] 上游 ${source_tag} 的不可变统计核心尚未发布；${SCRIPT_VERSION} 正在使用内置大小与 SHA-256 固定的 ${version} 审计核心。" >&2
        archive_name="rr-sing-box-${version}-linux-${SYS_ARCH}.tar.gz"
        archive_url="https://github.com/${RR_REPOSITORY}/releases/download/${release_tag}/${archive_name}"
        expected=$(nexus_pinned_core_asset_field "$SYS_ARCH" sha256) || return 1
        expected_size=$(nexus_pinned_core_asset_field "$SYS_ARCH" size) || return 1
    fi
    curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 10 --max-time 240 --max-filesize 104857600 \
        -o "$work_dir/$archive_name" "$archive_url" || return 1
    actual_size=$(stat -c %s "$work_dir/$archive_name" 2>/dev/null || echo 0)
    [ "$actual_size" -le 104857600 ] || return 1
    if [ "$pinned_core" = true ]; then
        [ "$actual_size" = "$expected_size" ] || return 1
    fi
    actual=$(sha256sum "$work_dir/$archive_name" | awk '{print $1}')
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] && [ "$actual" = "$expected" ] || return 1
    extracted="sing-box-${version}-linux-${SYS_ARCH}/sing-box"
    tar -tzf "$work_dir/$archive_name" "$extracted" >/dev/null 2>&1 || return 1
    tar --no-same-owner -xzf "$work_dir/$archive_name" -C "$work_dir" "$extracted" 2>/dev/null || return 1
    [ -f "$work_dir/$extracted" ] && [ ! -L "$work_dir/$extracted" ] && \
        [ "$(stat -c %h "$work_dir/$extracted" 2>/dev/null || echo 0)" -eq 1 ] || return 1
    install -m 755 "$work_dir/$extracted" "$work_dir/sing-box" || return 1
    "$work_dir/sing-box" version 2>/dev/null | grep -qw 'with_v2ray_api' || return 1
    actual_version=$(get_singbox_version "$work_dir/sing-box") || return 1
    [ "$actual_version" = "$version" ] || return 1
    version_ge "$actual_version" "$MIN_SINGBOX_VERSION" || return 1
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
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] 热更新候选缺少既有流量统计内核；未下载或替换 Sing-box。${RESET}" >&2
            return 1
        fi
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
    local snapshot=""
    local was_running=false
    local config_changed=false
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
    [ "$SINGBOX_CONFIG_CHANGED" = true ] && config_changed=true
    if [ "$SINGBOX_CONFIG_CHANGED" = true ] && [ "$was_running" = true ] && any_node_protocol_enabled; then
        if ! restart_singbox; then
            [ -s "$snapshot" ] && cp -p "$snapshot" /etc/sing-box/config.json
            restart_singbox >/dev/null 2>&1 || true
            rm -f "$snapshot"
            return 1
        fi
    fi
    if ! generate_nexus_device_subscriptions; then
        # A subscription-only failure must not bounce an unchanged node.  Only
        # roll back/restart when this transaction actually installed a new
        # Sing-box config (normally because the effective user list changed).
        if [ "$config_changed" = true ] && [ -s "$snapshot" ]; then
            cp -p "$snapshot" /etc/sing-box/config.json
            [ "$was_running" = true ] && restart_singbox >/dev/null 2>&1 || true
        fi
        rm -f "$snapshot"
        return 1
    fi
    rm -f "$snapshot"
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

nexus_write_config() {
    local mode="$1"        # local / public
    local domain="$2"      # domain or "ip"
    local user_port="$3"   # user-facing port
    local traffic_mode_val="${6:-both}"
    local backend_port=7900  # backend ALWAYS binds to 7900
    local stats_port="$4"
    local ssh_host="$5"
    local acme_email="${7:-}"

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
  "subscription_access_mode": "__SUB_ACCESS_MODE__",
  "subscription_domain": "__SUB_DOMAIN__",
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
    cfg="${cfg//__TRAFFIC_MODE__/$traffic_mode_val}"
    if [ -n "$acme_email" ]; then
        cfg=$(jq --arg acme_email "$acme_email" '.acme_email=$acme_email' <<<"$cfg") || return 1
    fi
    echo "$cfg" > "$NEXUS_CONFIG_FILE"
    chmod 600 "$NEXUS_CONFIG_FILE"
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

    tmp=$(mktemp /tmp/rr-nexus-endpoint.XXXXXX) || return 1
    if ! jq --arg ssh_host "$ENTRY_IP_RAW" --argjson sub_port "$SUB_URL_PORT" \
        --arg subscription_access_mode "${SUB_ACCESS_MODE:-local}" \
        --arg subscription_domain "${SUB_DOMAIN:-}" \
        '.ssh_host=$ssh_host | .sub_port=$sub_port |
         .subscription_access_mode=$subscription_access_mode |
         .subscription_domain=$subscription_domain' "$NEXUS_CONFIG_FILE" > "$tmp"; then
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
    local mode=""
    local domain=""
    local domain_is_ip=false
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
    tmp=$(mktemp /tmp/rr-nexus-migrate.XXXXXX) || return 1
    if [ "$mode" = public ] && { [ "$domain" = ip ] || [ "$domain_is_ip" = true ]; }; then
        domain="$ssh_host"
    fi
    if ! jq --argjson stats_port "$stats_port" --arg ssh_host "$ssh_host" --arg domain "$domain" --argjson sub_port "$sub_url_port" \
        --arg subscription_access_mode "${SUB_ACCESS_MODE:-local}" \
        --arg subscription_domain "${SUB_DOMAIN:-}" \
        --arg published_subscription_root "${SUB_ROOT}/nexus" \
        '.listen="127.0.0.1" | .port=7900 | .database="/var/lib/rr-nexus/nexus.db" |
         .subscription_root="/var/lib/rr-nexus/subscriptions" |
         .stats_port=$stats_port | .ssh_host=$ssh_host | .domain=$domain | .sub_port=$sub_port |
         .subscription_access_mode=$subscription_access_mode |
         .subscription_domain=$subscription_domain |
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
            cp -a -- "$path" "$transaction_dir/items/$index" || {
                rm -rf "$transaction_dir"
                return 1
            }
            managed_present[$index]=true
        fi
    done

    mv -f -- "$candidate" "$target" || transaction_ok=false
    if [ "$transaction_ok" = true ]; then
        rm -f -- "$enabled_link" || transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && [ -n "$obsolete_link" ]; then
        rm -f -- "$obsolete_link" || transaction_ok=false
    fi
    if [ "$transaction_ok" = true ]; then
        ln -sfnT "$target" "$enabled_link" || transaction_ok=false
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
    rm -f -- "$candidate"
    for path in "${managed_paths[@]}"; do
        rm -f -- "$path" || restore_ok=false
    done
    for index in "${!managed_paths[@]}"; do
        if [ "${managed_present[$index]}" = true ] && \
           ! cp -a -- "$transaction_dir/items/$index" "${managed_paths[$index]}"; then
            restore_ok=false
        fi
    done
    if [ "$nginx_was_active" = true ]; then
        nginx -t >/dev/null 2>&1 || restore_ok=false
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
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    tmp=$(mktemp "$nginx_available_dir/.rr-nexus.XXXXXX") || return 1
    if ! cat > "$tmp" <<EOF
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
    then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp"
    nexus_commit_nginx_candidate "$tmp" "$NEXUS_NGINX_SITE" \
        "$nginx_enabled_dir/rr-nexus.conf"
}

nexus_write_nginx_custom_port() {
    local domain="$1"
    local port="$2"
    local tmp=""
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
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
    location /.well-known/acme-challenge/ {
        root /var/www/rr-nexus-certbot;
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
    chmod 644 "$tmp"
    nexus_commit_nginx_candidate "$tmp" "${NEXUS_NGINX_SITE}.port" \
        "$nginx_enabled_dir/rr-nexus-port.conf" \
        "$nginx_enabled_dir/rr-nexus.conf"
}

nexus_enable_public_https() {
    local domain="$1"
    local email="$2"
    local port="$3"
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
    nexus_write_nginx_site "$domain" "$port" || return 1
    systemctl enable --now nginx >/dev/null 2>&1 || return 1
    open_protocol_firewall 80 tcp || return 1

    # 始终使用可审计的 webroot 签发，再由 RR 写入完整 TLS/HTTP 分离配置。
    # 不能使用 certbot --redirect：它生成的 server 级跳转可能把首次出现的
    # /sub/<token> 明文请求重定向并写日志，token 在跳转前就已经泄露。
    local webroot="/var/www/rr-nexus-certbot"
    mkdir -p "$webroot/.well-known/acme-challenge"
    chmod 755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge"
    if ! (umask 022 && certbot certonly --webroot -w "$webroot" -d "$domain" -m "$email" --agree-tos --non-interactive); then
        echo -e "${RED}[失败] Let's Encrypt 证书签发失败。请检查域名解析和 80 端口入站后重试。${RESET}"
        nexus_remove_public_proxy
        return 1
    fi
    rm -f /etc/nginx/sites-enabled/rr-nexus.conf
    if ! nexus_write_nginx_custom_port "$domain" "$port"; then
        echo -e "${RED}[失败] HTTPS 配置写入失败。${RESET}"
        nexus_remove_public_proxy
        return 1
    fi
    open_protocol_firewall "$port" tcp || return 1

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

nexus_enable_public_ip_https() {
    local address="$1"
    local port="$2"
    local nginx_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local nginx_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local cert_dir="${NEXUS_CERT_DIR:-/etc/rr-nexus/certs}"
    local cert_file="$cert_dir/ip.crt"
    local key_file="$cert_dir/ip.key"
    local site="$nginx_available_dir/rr-nexus-ip.conf"
    local site_tmp=""
    local cert_tmp=""
    local key_tmp=""
    local transaction_dir=""
    local transaction_ok=true
    local restore_ok=true
    local replace_cert=false
    local candidate_reload_attempted=false
    local nginx_was_active=false
    local nginx_was_enabled=false
    local path=""
    local index=0
    local -a managed_paths=()
    local -a managed_present=()
    is_ip_version "$address" 4 || is_ip_version "$address" 6 || return 1
    is_valid_port "$port" || return 1
    [ "$port" != 7900 ] || return 1

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
    fi
    if [ ! -s "$cert_file" ] || [ ! -s "$key_file" ] || \
       ! certificate_identity_matches "$cert_file" "$address" || \
       ! certificate_private_key_matches "$cert_file" "$key_file"; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
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
    if ! cat > "$site_tmp" <<NGXEOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_ip_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name _;
    client_max_body_size 32k;
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;

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
        limit_req zone=rr_nexus_ip_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
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
NGXEOF
    then
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
    fi
    chmod 644 "$site_tmp" || {
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        return 1
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
            if ! cp -a -- "$path" "$transaction_dir/items/$index"; then
                rm -rf "$transaction_dir"
                rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
                return 1
            fi
            managed_present[$index]=true
        fi
    done

    # Stage every file and link change before asking Nginx to load it.  Any
    # failed validation/service operation below restores this exact snapshot.
    if [ "$replace_cert" = true ]; then
        if mv -f "$key_tmp" "$key_file" && mv -f "$cert_tmp" "$cert_file"; then
            key_tmp=""
            cert_tmp=""
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            [ "$(stat -c %a "$key_file" 2>/dev/null)" = 600 ] && \
                [ "$(stat -c %a "$cert_file" 2>/dev/null)" = 644 ] || transaction_ok=false
        elif ! chmod 600 "$key_file" || ! chmod 644 "$cert_file"; then
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ]; then
        if mv -f "$site_tmp" "$site"; then
            site_tmp=""
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ] && \
       ! rm -f "$nginx_enabled_dir/rr-nexus.conf" \
           "$nginx_enabled_dir/rr-nexus-port.conf" \
           "$nginx_enabled_dir/rr-nexus-ip.conf"; then
        transaction_ok=false
    fi
    if [ "$transaction_ok" = true ] && \
       ! ln -sfnT "$site" "$nginx_enabled_dir/rr-nexus-ip.conf"; then
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
        if systemctl reload nginx >/dev/null 2>&1; then
            :
        else
            transaction_ok=false
        fi
    fi
    if [ "$transaction_ok" = true ] && ! open_protocol_firewall "$port" tcp; then
        transaction_ok=false
    fi

    if [ "$transaction_ok" != true ]; then
        rm -f "$site_tmp" "$cert_tmp" "$key_tmp"
        for path in "${managed_paths[@]}"; do
            if ! rm -f -- "$path"; then
                restore_ok=false
            fi
        done
        for index in "${!managed_paths[@]}"; do
            if [ "${managed_present[$index]}" = true ] && \
               ! cp -a -- "$transaction_dir/items/$index" "${managed_paths[$index]}"; then
                restore_ok=false
            fi
        done

        # Restore both dimensions of the original unit state.  Once a reload
        # was attempted its outcome can be ambiguous, so reload the restored
        # site (or restart as a last resort) before reporting the failure.
        if [ "$nginx_was_active" = true ]; then
            if ! systemctl is-active --quiet nginx >/dev/null 2>&1; then
                systemctl start nginx >/dev/null 2>&1 || restore_ok=false
            elif [ "$candidate_reload_attempted" = true ]; then
                systemctl reload nginx >/dev/null 2>&1 || \
                    systemctl restart nginx >/dev/null 2>&1 || restore_ok=false
            fi
        else
            systemctl stop nginx >/dev/null 2>&1 || restore_ok=false
        fi
        if [ "$nginx_was_enabled" = true ]; then
            systemctl enable nginx >/dev/null 2>&1 || restore_ok=false
        else
            systemctl disable nginx >/dev/null 2>&1 || restore_ok=false
        fi
        rm -rf "$transaction_dir"
        [ "$restore_ok" = true ] || \
            printf '%s\n' '[错误] Nexus Nginx 配置切换失败，且自动回滚未完整完成。' >&2
        return 1
    fi

    rm -rf "$transaction_dir"
    return 0
}

nexus_reconcile_public_proxy() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    local mode="" domain="" port="" acme_email="" domain_is_ip=false
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE") || return 1
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE") || return 1
    port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE") || return 1
    is_valid_port "$port" || return 1
    if [ "$mode" = local ]; then
        nexus_remove_public_proxy
        return 0
    fi
    [ "$mode" = public ] || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    if [ "$domain_is_ip" = true ]; then
        nexus_enable_public_ip_https "$domain" "$port"
        return $?
    fi
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] || return 1
    if [ -s "/etc/letsencrypt/live/${domain}/fullchain.pem" ] && \
       { [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ] || [ -s "$NEXUS_NGINX_SITE" ] || \
         [ -s "${NEXUS_NGINX_SITE}.port" ]; }; then
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
        nexus_write_nginx_custom_port "$domain" "$port" || return 1
        if [ "${RR_UPDATE_TRANSACTION:-0}" != 1 ]; then
            systemctl enable --now nginx >/dev/null 2>&1 || return 1
        fi
        open_protocol_firewall 80 tcp || return 1
        open_protocol_firewall "$port" tcp || return 1
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
    nexus_remove_public_proxy
    nexus_enable_public_https "$domain" "$acme_email" "$port"
}

nexus_public_proxy_health_check() {
    [ -r "$NEXUS_CONFIG_FILE" ] || return 0
    local mode="" domain="" port="" health_host="" domain_is_ip=false
    mode=$(jq -r '.mode // empty' "$NEXUS_CONFIG_FILE") || return 1
    [ "$mode" = public ] || return 0
    domain=$(jq -r '.domain // empty' "$NEXUS_CONFIG_FILE") || return 1
    port=$(jq -r '.public_port // empty' "$NEXUS_CONFIG_FILE") || return 1
    is_valid_port "$port" || return 1
    is_ip_version "$domain" 4 && domain_is_ip=true
    is_ip_version "$domain" 6 && domain_is_ip=true
    if [ "$domain_is_ip" = true ]; then
        certificate_identity_matches /etc/rr-nexus/certs/ip.crt "$domain" || return 1
        openssl x509 -in /etc/rr-nexus/certs/ip.crt -noout -checkend 604800 >/dev/null 2>&1 || return 1
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
        # IP mode intentionally uses a self-signed certificate.  Identity is
        # pinned immediately above against the certificate IP SAN; -k is never used for
        # a trusted domain certificate.
        curl -fkSs --connect-timeout 3 --max-time 8 \
            -H "Host: ${health_host}" "https://127.0.0.1:${port}/healthz" >/dev/null
    else
        curl -fSs --connect-timeout 3 --max-time 8 \
            --resolve "${domain}:${port}:127.0.0.1" \
            "https://${domain}:${port}/healthz" >/dev/null
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
            nexus_write_config public "${domain,,}" "$port" "$stats_port" "$ENTRY_IP_RAW" "$traffic_mode_val" "$email" || return 1
            nexus_enable_public_https "${domain,,}" "$email" "$port" || return 1
            ;;
                3)
            nexus_remove_public_proxy
            nexus_write_config public "$ENTRY_IP_RAW" "$port" "$stats_port" "$ENTRY_IP_RAW" "$traffic_mode_val" || return 1
            echo -e "${YELLOW}正在配置 IP 直连 HTTPS（自签证书）……${RESET}"
            nexus_enable_public_ip_https "$ENTRY_IP_RAW" "$port" || return 1
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
            test_url=$(nexus_panel_url)
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
            4) systemctl restart rr-nexus && echo -e "${GREEN}已重启。${RESET}" || echo -e "${RED}重启失败。${RESET}"; sleep 2 ;;
            5) nexus_uninstall ;;
            0) return ;;
            *) echo "输入无效"; sleep 1 ;;
        esac
    done
}
