# shellcheck shell=bash
# RR-vps 热更新兼容保险层。
# 本文件不参与发布 manifest；由最新 install.sh 在每次安装/升级时写入
# /usr/local/lib/rr/modules/61-update-guard.sh，并在 60-update.sh 之后加载。
# 设计原则：这里永远不解析远程 manifest 的文件路径/类型，也不校验 bundle
# 成员结构。它只判断“远程清单字节是否变化”，然后把真正的安全校验、
# 下载、事务安装和回滚交给当次最新 bootstrap install.sh。

RR_UPDATE_GUARD_VERSION="2"

rr_update_guard_pause() {
    local prompt="${1:-按回车键返回...}"
    if [ -t 0 ] && [ -t 1 ]; then
        read -r -p "$prompt" _ || true
    fi
}

rr_update_guard_alert() {
    declare -F rr_emit_alert >/dev/null 2>&1 || return 0
    rr_emit_alert update_failed critical "RR-vps 更新失败" "$1" \
        "update_failed:$(date -u '+%Y%m%d%H')" --interval 300
}

rr_update_guard_download() {
    local source_url="$1"
    local target_file="$2"
    local timeout_seconds="${3:-10}"
    local cache_buster=""
    local relative_path=""
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local api_base="${RR_API_BASE:-https://api.github.com/repos/${repository}/contents}"
    local cdn_base="${RR_CDN_BASE:-https://cdn.jsdelivr.net/gh/${repository}@${branch}}"

    cache_buster=$(date +%s)
    case "$source_url" in
        "${raw_base}/"*) relative_path="${source_url#"${raw_base}/"}" ;;
    esac

    if [ -n "${RR_GITHUB_MIRROR:-}" ]; then
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
                "${api_base}/${relative_path}?ref=${branch}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 180 \
                "${cdn_base}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout_seconds" --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ -n "$relative_path" ]; then
            wget -q --timeout="$timeout_seconds" --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${api_base}/${relative_path}?ref=${branch}&t=${cache_buster}" && return 0
            wget -4 -q --timeout="$timeout_seconds" --tries=2 \
                -O "$target_file" "${cdn_base}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        return 1
    fi
    return 1
}

# 主菜单状态检查只做“远程 manifest 与本地 manifest 是否相同”的字节级比较。
# 不读取文件路径，因此未来新增模块/Python/静态资源不会让旧客户端误判清单无效。
check_update() {
    local remote_manifest=""
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local local_manifest="${RR_LOCAL_MANIFEST:-${RR_LIB_DIR:-/usr/local/lib/rr}/manifest.sha256}"
    local manifest_url="${RR_MANIFEST_URL:-${raw_base}/manifest.sha256}"

    UPDATE_AVAILABLE=false
    UPDATE_CHECK_STATE="failed"
    UPDATE_CHECK_ERROR=""
    SCRIPT_VER_STATUS="${YELLOW:-}检查失败（网络不可用）${RESET:-}"

    remote_manifest=$(mktemp /tmp/rr-update-guard-manifest.XXXXXX) || {
        UPDATE_CHECK_ERROR="无法创建临时文件"
        return 0
    }
    if ! rr_update_guard_download "$manifest_url" "$remote_manifest" 3 || [ ! -s "$remote_manifest" ]; then
        UPDATE_CHECK_ERROR="GitHub Raw、API 与 CDN 均不可达"
        SCRIPT_VER_STATUS="${YELLOW:-}检查失败（下载链路不可用）${RESET:-}"
        rm -f "$remote_manifest"
        return 0
    fi

    if [ -s "$local_manifest" ] && cmp -s "$remote_manifest" "$local_manifest"; then
        UPDATE_CHECK_STATE="latest"
        SCRIPT_VER_STATUS="${GREEN:-}已是最新${RESET:-}"
    else
        UPDATE_AVAILABLE=true
        UPDATE_CHECK_STATE="available"
        SCRIPT_VER_STATUS="${RED:-}有新版本${RESET:-}"
    fi
    rm -f "$remote_manifest"
}

rr_update_guard_prepare_bootstrap() {
    local target_file="$1"
    local repository="${RR_REPOSITORY:-Xiaowu7z/RR-vps}"
    local branch="${RR_BRANCH:-main}"
    local raw_base="${RR_RAW_BASE:-https://raw.githubusercontent.com/${repository}/refs/heads/${branch}}"
    local bootstrap_url="${RR_BOOTSTRAP_URL:-${raw_base}/install.sh}"

    rr_update_guard_download "$bootstrap_url" "$target_file" 10 && \
        [ -s "$target_file" ] && \
        [ "$(stat -c %s "$target_file" 2>/dev/null || echo 0)" -le 262144 ] && \
        bash -n "$target_file" 2>/dev/null && \
        grep -q '^RR_BOOTSTRAP_VERSION=' "$target_file" && \
        grep -q 'RR_REPOSITORY="Xiaowu7z/RR-vps"' "$target_file"
}

# 8 号热更新的唯一职责：获取“此刻最新”的 bootstrap，再由 bootstrap 决定
# 当前发布清单/文件类型/Bundle 如何验证和安装。保险层本身不维护发布白名单。
do_update() {
    local bootstrap_tmp=""
    local preflight_tmp=""

    # 上次更新如果被断电/SIGKILL 中断，先由独立恢复器收敛到旧版。
    if [ -x /usr/local/sbin/rr-update-recover ]; then
        /usr/local/sbin/rr-update-recover recover || {
            echo -e "${RED:-}[失败] 上次更新事务未能完整恢复，已停止新更新。${RESET:-}"
            return 1
        }
    fi
    preflight_tmp=$(mktemp /tmp/rr-update-preflight.XXXXXX) || return 1
    if [ -x /usr/local/bin/rr ] && ! /usr/local/bin/rr --update-preflight >"$preflight_tmp" 2>/dev/null; then
        echo -e "${RED:-}[失败] 更新预检未通过，当前节点未改动。${RESET:-}"
        cat "$preflight_tmp" 2>/dev/null || true
        rr_update_guard_alert "更新预检未通过，当前节点未改动。"
        rm -f "$preflight_tmp"
        rr_update_guard_pause
        return 1
    fi
    rm -f "$preflight_tmp"

    echo -e "\n${YELLOW:-}检查 RR-vps 远程更新...${RESET:-}"
    check_update
    if [ "${UPDATE_CHECK_STATE:-failed}" = "latest" ]; then
        echo -e "${GREEN:-}当前已是最新版本，无需更新。${RESET:-}"
        rr_update_guard_pause
        return 0
    fi
    if [ "${UPDATE_CHECK_STATE:-failed}" = "failed" ]; then
        echo -e "${YELLOW:-}[提示] 状态检查失败：${UPDATE_CHECK_ERROR:-未知原因}。将直接尝试获取最新安全更新程序；获取失败则不会改动当前节点。${RESET:-}"
    else
        echo -e "${YELLOW:-}发现发布内容变化，正在获取最新安全更新程序...${RESET:-}"
    fi

    bootstrap_tmp=$(mktemp /tmp/rr-bootstrap-guard.XXXXXX) || {
        echo -e "${RED:-}[失败] 无法创建更新临时文件，当前节点未改动。${RESET:-}"
        rr_update_guard_pause
        return 1
    }
    if ! rr_update_guard_prepare_bootstrap "$bootstrap_tmp"; then
        rm -f "$bootstrap_tmp"
        echo -e "${RED:-}[失败] 最新更新程序下载或完整性检查失败，当前节点未改动。${RESET:-}"
        rr_update_guard_alert "安全引导器下载或完整性检查失败，当前节点未改动。"
        rr_update_guard_pause
        return 1
    fi
    chmod 700 "$bootstrap_tmp"

    echo -e "${YELLOW:-}正在执行带完整备份、校验与自动回滚保护的热更新...${RESET:-}"
    if bash "$bootstrap_tmp" --upgrade; then
        rm -f "$bootstrap_tmp"
        echo -e "${GREEN:-}[成功] RR-vps 热更新完成。${RESET:-}"
        echo -e "${CYAN:-}原 UUID、密钥、域名、节点端口、订阅端口及 IPv4/IPv6 设置均按安装器事务规则保留。${RESET:-}"
        if [ -t 0 ] && [ -t 1 ]; then
            read -r -p "按回车键退出并重新执行 rr..." _ || true
        fi
        exit 0
    fi

    rm -f "$bootstrap_tmp"
    echo -e "${RED:-}[失败] 热更新未完成；最新安装程序已按事务规则回滚，当前节点保持升级前状态。${RESET:-}"
    rr_update_guard_alert "热更新事务失败，已执行自动回滚；请运行 rr doctor。"
    rr_update_guard_pause
    return 1
}
