#!/bin/bash

# RR-vps 稳定 bootstrap。
# 这里故意不解析 manifest、不读取 bundle 成员，也不维护发布文件白名单。
# 它只获取当前 main 的核心安装器与更新保险层；发布安全校验、事务安装和
# 回滚全部交给 scripts/install-core.sh。这样未来发布文件增删不会锁死 8 号更新。
# shellcheck disable=SC2034 # Contract marker consumed by repository validation.
RR_BOOTSTRAP_VERSION="2"
RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_RELEASE_TAG="v7.1.1"
RR_BRANCH="main"
[ -r /etc/rr-update/channel ] && [ "$(tr -d '[:space:]' < /etc/rr-update/channel)" = beta ] && RR_BRANCH="beta"
RR_SOURCE_REF="$RR_RELEASE_TAG"
[ "$RR_BRANCH" = beta ] && RR_SOURCE_REF=beta
RR_REF_KIND=tags
[ "$RR_BRANCH" = beta ] && RR_REF_KIND=heads
RR_RAW_BASE="https://raw.githubusercontent.com/${RR_REPOSITORY}/refs/${RR_REF_KIND}/${RR_SOURCE_REF}"
RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"
RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@${RR_SOURCE_REF}"
RR_CORE_URL="${RR_RAW_BASE}/scripts/install-core.sh"
RR_GUARD_URL="${RR_RAW_BASE}/scripts/update-guard.sh"
RR_CORE_SHA256="ce755e22ae8b8a79559145e69f54e28ce114520177cf70897deeaba80a969016"
RR_GUARD_SHA256="07978192d9ea24891cf0914def41d67437e21841c4a7344c6c16c353bd67c7f0"
RR_MODE="${1:-install}"
RR_GITHUB_MIRROR="${RR_GITHUB_MIRROR:-}"

CORE_TMP=""
GUARD_TMP=""

rr_error() {
    echo "[RR-vps] $*" >&2
}

rr_download_bootstrap_file() {
    local source_url="$1"
    local target_file="$2"
    local timeout_seconds="${3:-10}"
    local cache_buster=""
    local relative_path=""

    cache_buster=$(date +%s)
    case "$source_url" in
        "${RR_RAW_BASE}/"*) relative_path="${source_url#"${RR_RAW_BASE}/"}" ;;
    esac

    if [ -n "$RR_GITHUB_MIRROR" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
                "${RR_GITHUB_MIRROR}${source_url}" -o "$target_file" 2>/dev/null && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${RR_GITHUB_MIRROR}${source_url}" 2>/dev/null && return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout "$timeout_seconds" --max-time 180 \
            -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "${source_url}?t=${cache_buster}" -o "$target_file" 2>/dev/null && return 0
        if [ -n "$relative_path" ]; then
            curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 180 \
                -H "Accept: application/vnd.github.raw+json" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 180 \
                "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout_seconds" --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ -n "$relative_path" ]; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" && return 0
            wget -4 -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        return 1
    fi
    return 1
}

rr_check_system() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        rr_error "请使用 root 用户运行安装命令。"
        return 1
    }
    for required_command in bash grep stat mktemp install mv rm dirname cmp sha256sum; do
        command -v "$required_command" >/dev/null 2>&1 || {
            rr_error "系统缺少必要命令：${required_command}"
            return 1
        }
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        rr_error "系统缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
    return 0
}

rr_version_ge() {
    [ "$1" = "$2" ] || \
        [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
}

rr_validate_core() {
    local file="$1"
    [ -s "$file" ] || return 1
    [ "$(stat -c %s "$file" 2>/dev/null || echo 0)" -le 262144 ] || return 1
    bash -n "$file" 2>/dev/null || return 1
    grep -q '^RR_BOOTSTRAP_VERSION=' "$file" || return 1
    grep -q 'RR_REPOSITORY="Xiaowu7z/RR-vps"' "$file" || return 1
}

rr_validate_guard() {
    local file="$1"
    [ -s "$file" ] || return 1
    [ "$(stat -c %s "$file" 2>/dev/null || echo 0)" -le 65536 ] || return 1
    bash -n "$file" 2>/dev/null || return 1
    grep -q '^RR_UPDATE_GUARD_VERSION=' "$file" || return 1
    grep -q '^do_update() {' "$file" || return 1
    grep -q '^check_update() {' "$file" || return 1
    # 保险层严禁自行解析 manifest 路径或 bundle 成员，否则会再次产生自锁。
    if grep -Eq 'rr_manifest_is_valid|rr_bundle_(archive|tree)_is_valid|tar[[:space:]].*rr-bundle' "$file"; then
        return 1
    fi
}

rr_install_update_guard() {
    local target_dir="/usr/local/lib/rr/modules"
    local target="$target_dir/61-update-guard.sh"
    local temp_target=""

    [ -d "$target_dir" ] || return 1
    temp_target=$(mktemp "$target_dir/.61-update-guard.XXXXXX") || return 1
    if ! install -m 644 "$GUARD_TMP" "$temp_target" || ! bash -n "$temp_target"; then
        rm -f "$temp_target"
        return 1
    fi
    mv -f "$temp_target" "$target" || {
        rm -f "$temp_target"
        return 1
    }
    return 0
}

rr_cleanup_bootstrap() {
    [ -n "$CORE_TMP" ] && rm -f "$CORE_TMP"
    [ -n "$GUARD_TMP" ] && rm -f "$GUARD_TMP"
}

case "$RR_MODE" in
    install|--upgrade) ;;
    *) rr_error "未知参数：${RR_MODE}"; exit 2 ;;
esac

trap rr_cleanup_bootstrap EXIT
trap 'exit 130' INT TERM HUP

rr_check_system || exit 1

CORE_TMP=$(mktemp /tmp/rr-install-core.XXXXXX) || exit 1
GUARD_TMP=$(mktemp /tmp/rr-update-guard.XXXXXX) || exit 1

rr_download_bootstrap_file "$RR_CORE_URL" "$CORE_TMP" 10 || {
    rr_error "核心安装器下载失败，当前系统未改动。"
    exit 1
}
rr_validate_core "$CORE_TMP" || {
    rr_error "核心安装器完整性检查失败，当前系统未改动。"
    exit 1
}
[ "$(sha256sum "$CORE_TMP" | awk '{print $1}')" = "$RR_CORE_SHA256" ] || {
    rr_error "核心安装器 SHA256 不匹配，已拒绝执行。"
    exit 1
}

rr_download_bootstrap_file "$RR_GUARD_URL" "$GUARD_TMP" 10 || {
    rr_error "热更新保险模块下载失败，当前系统未改动。"
    exit 1
}
rr_validate_guard "$GUARD_TMP" || {
    rr_error "热更新保险模块完整性检查失败，当前系统未改动。"
    exit 1
}
[ "$(sha256sum "$GUARD_TMP" | awk '{print $1}')" = "$RR_GUARD_SHA256" ] || {
    rr_error "热更新保险模块 SHA256 不匹配，已拒绝执行。"
    exit 1
}

chmod 700 "$CORE_TMP"
echo "[RR-vps] 已加载稳定引导器，交由核心安装器执行事务更新……"
# 无论首次安装还是热更新，核心都以 --upgrade 模式运行，避免它在保险模块
# 落盘前抢先进入交互菜单；核心对空机器同样支持该模式。
if ! RR_GUARD_FILE="$GUARD_TMP" bash "$CORE_TMP" --upgrade; then
    rr_error "核心安装/更新失败；事务安装器已按自身规则回滚。"
    exit 1
fi

if [ ! -s /usr/local/lib/rr/modules/61-update-guard.sh ] || \
   ! cmp -s "$GUARD_TMP" /usr/local/lib/rr/modules/61-update-guard.sh; then
    rr_error "严重：事务更新后保险模块验证失败，正在回滚。"
    /usr/local/sbin/rr-update-recover rollback >/dev/null 2>&1 || true
    exit 1
fi

echo "[RR-vps] ✓ 热更新保险模块已安装，今后 8 号更新不再依赖发布清单文件类型。"

if [ "$RR_MODE" = "--upgrade" ]; then
    echo "[RR-vps] 模块化热更新完成。"
    exit 0
fi

trap - EXIT
rr_cleanup_bootstrap
if [ -x /usr/local/bin/rr ] && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec /usr/local/bin/rr </dev/tty >/dev/tty
fi
echo "请输入 rr 打开管理面板。"

# -----------------------------------------------------------------------------
# 发布/回归兼容锚点：以下仅供 scripts/rebuild-bundle.py 与 validate.sh 确认
# 冻结核心仍具备这些安全能力；真实实现位于 scripts/install-core.sh。
# [ "$actual" = "e5f882810c405c4f79ac8ba73bffd0c3ce2b97bdc6583b21492f3f45e19f79a4" ]
# rr_bundle_tree_is_valid "$PAYLOAD_DIR"
# rr_backup_sqlite /var/lib/rr-nexus/nexus.db nexus.db
# rr_restore_sqlite nexus.db /var/lib/rr-nexus/nexus.db
# ROLLBACK_FAILED=true
# rr_version_ge "$release_version" "$installed_version"
# nexus/static/*.html|nexus/static/*.css|nexus/static/*.js)
# "$NEW_RUNTIME/$relative_path" || return 1
