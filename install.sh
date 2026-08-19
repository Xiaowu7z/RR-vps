#!/bin/bash

RR_BOOTSTRAP_VERSION="1"
RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_BRANCH="main"
RR_RAW_BASE="https://raw.githubusercontent.com/${RR_REPOSITORY}/refs/heads/${RR_BRANCH}"
RR_MANIFEST_URL="${RR_RAW_BASE}/manifest.sha256"
RR_LIB_DIR="/usr/local/lib/rr"
RR_LAUNCHER="/usr/local/bin/rr"
RR_MODE="${1:-install}"

RR_GITHUB_MIRROR="${RR_GITHUB_MIRROR:-}"

STAGE_ROOT=""
PAYLOAD_DIR=""
BACKUP_DIR=""
NEW_RUNTIME=""
OLD_RUNTIME=""
NEW_LAUNCHER=""
RUNTIME_REPLACED=false
TRANSACTION_ACTIVE=false

rr_error() {
    echo "[RR-vps] $*" >&2
}

rr_download() {
    local source_url="$1"
    local target_file="$2"

    if [ -n "$RR_GITHUB_MIRROR" ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
                "${RR_GITHUB_MIRROR}${source_url}" -o "$target_file" 2>/dev/null && return 0
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 --tries=2 \
                -O "$target_file" "${RR_GITHUB_MIRROR}${source_url}" 2>/dev/null && return 0
        fi
    fi

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 \
            -H "Cache-Control: no-cache" -H "Pragma: no-cache" \
            "${source_url}?t=$(date +%s)" -o "$target_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 \
            -O "$target_file" "${source_url}?t=$(date +%s)"
    else
        rr_error "缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
}

rr_manifest_is_valid() {
    local manifest_file="$1"
    [ -s "$manifest_file" ] || return 1
    awk '
        NF != 2 { exit 1 }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        seen[$2]++ { exit 1 }
        $2 == "rr" { launcher = 1; next }
        $2 ~ /^modules\/[0-9][0-9A-Za-z_-]*\.sh$/ { modules++; next }
        $2 == "nexus/rr_nexus.py" { nexus_app = 1; next }
        $2 ~ /^nexus\/static\/(index\.html|app\.css|app\.js)$/ { nexus_assets++; next }
        $2 == "install.sh" { next }
        { exit 1 }
        END {
            if (!launcher || modules < 2) exit 1
            if (!nexus_app || nexus_assets != 3) exit 1
        }
    ' "$manifest_file"
}

rr_check_system() {
    [ "${EUID:-$(id -u)}" -eq 0 ] || {
        rr_error "请使用 root 用户运行安装命令。"
        return 1
    }
    [ -r /etc/os-release ] || {
        rr_error "无法识别操作系统。"
        return 1
    }

    local os_id=""
    local os_version=""
    os_id=$(awk -F= '$1 == "ID" {gsub(/"/, "", $2); print tolower($2); exit}' /etc/os-release)
    os_version=$(awk -F= '$1 == "VERSION_ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)
    case "$os_id" in
        debian)
            dpkg --compare-versions "${os_version:-0}" ge "12" || {
                rr_error "Debian ${os_version:-未知} 版本过旧，最低支持 Debian 12。"
                return 1
            }
            ;;
        ubuntu)
            dpkg --compare-versions "${os_version:-0}" ge "22.04" || {
                rr_error "Ubuntu ${os_version:-未知} 版本过旧，最低支持 Ubuntu 22.04。"
                return 1
            }
            ;;
        *)
            rr_error "当前仅正式支持 Debian 12+ 与 Ubuntu 22.04+。"
            return 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64) ;;
        *)
            rr_error "不支持的 CPU 架构：$(uname -m)"
            return 1
            ;;
    esac

    for required_command in bash awk sha256sum install mktemp cp mv rm mkdir dirname basename systemctl python3 jq curl; do
        command -v "$required_command" >/dev/null 2>&1 || {
            rr_error "系统缺少必要命令：${required_command}"
            return 1
        }
    done
}

rr_backup_file() {
    local source_file="$1"
    local backup_name="$2"
    if [ -e "$source_file" ]; then
        cp -p "$source_file" "$BACKUP_DIR/$backup_name" || return 1
        : > "$BACKUP_DIR/had_${backup_name}"
    fi
}

rr_backup_dir() {
    local source_dir="$1"
    local backup_name="$2"
    if [ -d "$source_dir" ]; then
        cp -a "$source_dir" "$BACKUP_DIR/$backup_name" || return 1
        : > "$BACKUP_DIR/had_${backup_name}"
    fi
}

rr_restore_file() {
    local backup_name="$1"
    local target_file="$2"
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        mkdir -p "$(dirname "$target_file")"
        # 运行中的二进制无法被原地覆盖（Text file busy）。
        # 先复制到同目录临时文件再原子替换目录项——运行进程保持旧 inode 不受影响。
        # 若仍失败（只读盘/权限等），记录警告并继续回滚其余文件，绝不中断回滚流程。
        local restore_tmp=""
        restore_tmp="$(dirname "$target_file")/.rr-restore.$$"
        if cp -p "$BACKUP_DIR/$backup_name" "$restore_tmp" 2>/dev/null && \
           mv -f "$restore_tmp" "$target_file" 2>/dev/null; then
            return 0
        fi
        rm -f "$restore_tmp"
        if cp -p "$BACKUP_DIR/$backup_name" "$target_file" 2>/dev/null; then
            return 0
        fi
        rr_error "警告：恢复 ${target_file} 失败（可能被运行中的进程占用），已跳过并继续回滚。"
    else
        rm -f "$target_file"
    fi
}

rr_restore_dir() {
    local backup_name="$1"
    local target_dir="$2"
    rm -rf "$target_dir"
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        mkdir -p "$(dirname "$target_dir")"
        cp -a "$BACKUP_DIR/$backup_name" "$target_dir"
    fi
}

rr_snapshot_runtime() {
    BACKUP_DIR=$(mktemp -d /tmp/rr-update-backup.XXXXXX) || return 1
    chmod 700 "$BACKUP_DIR"

    rr_backup_file "$RR_LAUNCHER" rr_launcher || return 1
    rr_backup_file /etc/argo_vmess.conf argo_vmess.conf || return 1
    rr_backup_file /etc/sing-box/config.json singbox_config.json || return 1
    rr_backup_file /usr/local/bin/sing-box singbox_binary || return 1
    rr_backup_file /etc/systemd/system/sing-box.service singbox.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.service health.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.timer health.timer || return 1
    rr_backup_file /usr/local/bin/auto_update_sub.py auto_update_sub.py || return 1
    rr_backup_dir /tmp/sub_server sub_server || return 1

    systemctl is-active --quiet sing-box 2>/dev/null && : > "$BACKUP_DIR/singbox_was_running"
    systemctl is-active --quiet rr-nexus 2>/dev/null && : > "$BACKUP_DIR/nexus_was_running"
    systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && \
        : > "$BACKUP_DIR/health_timer_was_enabled"

    # Service state probes are optional metadata. A fresh server has none of
    # these units yet, so their non-zero status must not turn a valid empty
    # snapshot into a failed update backup.
    return 0
}

rr_rollback() {
    [ "$TRANSACTION_ACTIVE" = true ] || return 0
    TRANSACTION_ACTIVE=false
    rr_error "新版本校验失败，正在恢复升级前状态……"

    if [ "$RUNTIME_REPLACED" = true ]; then
        if [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ]; then
            rm -rf "$RR_LIB_DIR"
            mv "$OLD_RUNTIME" "$RR_LIB_DIR"
            OLD_RUNTIME=""
        else
            rm -rf "$RR_LIB_DIR"
        fi
        RUNTIME_REPLACED=false
    fi

    rr_restore_file rr_launcher "$RR_LAUNCHER"
    rr_restore_file argo_vmess.conf /etc/argo_vmess.conf
    rr_restore_file singbox_config.json /etc/sing-box/config.json
    rr_restore_file singbox_binary /usr/local/bin/sing-box
    rr_restore_file singbox.service /etc/systemd/system/sing-box.service
    rr_restore_file health.service /etc/systemd/system/argo-rr-health.service
    rr_restore_file health.timer /etc/systemd/system/argo-rr-health.timer
    rr_restore_file auto_update_sub.py /usr/local/bin/auto_update_sub.py
    rr_restore_dir sub_server /tmp/sub_server

    systemctl daemon-reload >/dev/null 2>&1 || true
    if [ -f "$BACKUP_DIR/health_timer_was_enabled" ] && \
       [ -f /etc/systemd/system/argo-rr-health.timer ]; then
        systemctl enable --now argo-rr-health.timer >/dev/null 2>&1 || true
    else
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    if [ -f "$BACKUP_DIR/singbox_was_running" ] && \
       [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl restart sing-box >/dev/null 2>&1 || true
    else
        systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    if [ -f "$BACKUP_DIR/nexus_was_running" ] && \
       [ -f /etc/systemd/system/rr-nexus.service ]; then
        systemctl restart rr-nexus >/dev/null 2>&1 || true
    fi
    rr_error "回滚完成：原 rr、配置、内核和订阅已恢复。"
}

rr_cleanup() {
    local result=$?
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_ACTIVE" = true ]; then
        rr_rollback
    fi
    [ -n "$STAGE_ROOT" ] && rm -rf "$STAGE_ROOT"
    [ -n "$NEW_RUNTIME" ] && [ -e "$NEW_RUNTIME" ] && rm -rf "$NEW_RUNTIME"
    [ -n "$NEW_LAUNCHER" ] && [ -e "$NEW_LAUNCHER" ] && rm -f "$NEW_LAUNCHER"
    [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ] && rm -rf "$OLD_RUNTIME"
    [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
    return "$result"
}

rr_fetch_release() {
    STAGE_ROOT=$(mktemp -d /tmp/rr-release.XXXXXX) || return 1
    PAYLOAD_DIR="$STAGE_ROOT/payload"
    mkdir -p "$PAYLOAD_DIR/modules"

    echo "[RR-vps] 正在下载发布清单……"
rr_download "${RR_RAW_BASE}/rr-bundle.tar.gz" "$STAGE_ROOT/rr-bundle.tar.gz" 2>/dev/null && \
actual=$(sha256sum "$STAGE_ROOT/rr-bundle.tar.gz" | awk '{print $1}') && \
[ "$actual" = "e1ed65df9bfea9a934dccb44ea4bcf4ab6d272d3a476168b938b1a261b5640d2" ] && \
tar -xzf "$STAGE_ROOT/rr-bundle.tar.gz" -C "$PAYLOAD_DIR" --strip-components=1 2>/dev/null && \
cp "$PAYLOAD_DIR/manifest.sha256" "$STAGE_ROOT/manifest.sha256" && \
rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" && \
echo "[RR-vps] ✓ 高速模式加载完成" && \
cp "$PAYLOAD_DIR/install.sh" "$STAGE_ROOT/install.sh" 2>/dev/null && \
return 0

echo "[RR-vps] ⚡ 高速模式未命中，切换逐文件下载……"
    rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" || return 1
    rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" || {
        rr_error "远程发布清单格式无效。"
        return 1
    }

    local expected_hash=""
    local relative_path=""
    while read -r expected_hash relative_path; do
        mkdir -p "$PAYLOAD_DIR/$(dirname "$relative_path")"
        rr_download "${RR_RAW_BASE}/${relative_path}" "$PAYLOAD_DIR/$relative_path" || {
            rr_error "下载失败：${relative_path}"
            return 1
        }
    done < "$STAGE_ROOT/manifest.sha256"

    if ! (cd "$PAYLOAD_DIR" && sha256sum -c "$STAGE_ROOT/manifest.sha256" >/dev/null); then
        # CDN 边缘可能缓存旧版本文件：等待 10s 后强制刷新重试一次
        echo "[RR-vps] ⚠ 校验未通过（可能命中 CDN 旧缓存），10 秒后重试……"
        sleep 10
        rm -rf "$PAYLOAD_DIR"
        mkdir -p "$PAYLOAD_DIR"
        rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" || return 1
        rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" || { rr_error "远程发布清单格式无效。"; return 1; }
        while read -r expected_hash relative_path; do
            mkdir -p "$PAYLOAD_DIR/$(dirname "$relative_path")"
            rr_download "${RR_RAW_BASE}/${relative_path}" "$PAYLOAD_DIR/$relative_path" || {
                rr_error "重试下载失败：${relative_path}"
                return 1
            }
        done < "$STAGE_ROOT/manifest.sha256"
        if ! (cd "$PAYLOAD_DIR" && sha256sum -c "$STAGE_ROOT/manifest.sha256" >/dev/null); then
            rr_error "文件 SHA256 校验失败，拒绝安装。"
            return 1
        fi
    fi
    bash -n "$PAYLOAD_DIR/rr" || return 1
    local shell_file=""
    for shell_file in "$PAYLOAD_DIR"/modules/*.sh; do
        bash -n "$shell_file" || return 1
    done
    if [ -f "$PAYLOAD_DIR/nexus/rr_nexus.py" ]; then
        python3 -c 'compile(open("'"$PAYLOAD_DIR/nexus/rr_nexus.py"'", encoding="utf-8").read(), "rr_nexus.py", "exec")' || return 1
        [ -s "$PAYLOAD_DIR/nexus/static/index.html" ] && \
        [ -s "$PAYLOAD_DIR/nexus/static/app.css" ] && \
        [ -s "$PAYLOAD_DIR/nexus/static/app.js" ] || return 1
    fi
    if ! RR_VALIDATE_MODULE_DIR="$PAYLOAD_DIR/modules" bash -c '
        for module_file in "$RR_VALIDATE_MODULE_DIR"/*.sh; do source "$module_file" || exit 1; done
        declare -F main_menu >/dev/null &&
        declare -F install_main >/dev/null &&
        declare -F do_update >/dev/null &&
        declare -F generate_node_and_sub >/dev/null
    '; then
        rr_error "模块组合加载测试失败。"
        return 1
    fi
}

rr_install_release() {
    rr_snapshot_runtime || {
        rr_error "无法完整备份当前安装，已取消更新。"
        return 1
    }

    NEW_RUNTIME=$(mktemp -d /usr/local/lib/.rr-install.XXXXXX) || return 1
    install -d -m 755 "$NEW_RUNTIME/modules"
    install -m 644 "$STAGE_ROOT/manifest.sha256" "$NEW_RUNTIME/manifest.sha256"
    local module_file=""
    for module_file in "$PAYLOAD_DIR"/modules/*.sh; do
        install -m 644 "$module_file" "$NEW_RUNTIME/modules/$(basename "$module_file")" || return 1
    done
    if [ -f "$PAYLOAD_DIR/nexus/rr_nexus.py" ]; then
        install -d -m 755 "$NEW_RUNTIME/nexus/static" || return 1
        install -m 755 "$PAYLOAD_DIR/nexus/rr_nexus.py" "$NEW_RUNTIME/nexus/rr_nexus.py" || return 1
        install -m 644 "$PAYLOAD_DIR/nexus/static/index.html" "$NEW_RUNTIME/nexus/static/index.html" || return 1
        install -m 644 "$PAYLOAD_DIR/nexus/static/app.css" "$NEW_RUNTIME/nexus/static/app.css" || return 1
        install -m 644 "$PAYLOAD_DIR/nexus/static/app.js" "$NEW_RUNTIME/nexus/static/app.js" || return 1
    fi
    NEW_LAUNCHER=$(mktemp /usr/local/bin/.rr.new.XXXXXX) || return 1
    install -m 755 "$PAYLOAD_DIR/rr" "$NEW_LAUNCHER" || return 1

    TRANSACTION_ACTIVE=true
    if [ -e "$RR_LIB_DIR" ]; then
        OLD_RUNTIME="${RR_LIB_DIR}.previous.$$"
        if ! mv "$RR_LIB_DIR" "$OLD_RUNTIME"; then
            TRANSACTION_ACTIVE=false
            return 1
        fi
    fi
    RUNTIME_REPLACED=true
    mv "$NEW_RUNTIME" "$RR_LIB_DIR" || return 1
    NEW_RUNTIME=""
    mv "$NEW_LAUNCHER" "$RR_LAUNCHER" || return 1
    NEW_LAUNCHER=""

    if ! "$RR_LAUNCHER" --post-update; then
        rr_rollback
        return 1
    fi

    TRANSACTION_ACTIVE=false
    [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ] && rm -rf "$OLD_RUNTIME"
    OLD_RUNTIME=""
    return 0
}

case "$RR_MODE" in
    install|--upgrade) ;;
    *)
        rr_error "未知参数：${RR_MODE}"
        exit 2
        ;;
esac

trap rr_cleanup EXIT
trap 'exit 130' INT TERM HUP

#skip || exit 1
rr_fetch_release || exit 1
rr_install_release || exit 1

if [ "$RR_MODE" = "--upgrade" ]; then
    # 升级后必须把服务拉起来：旧实现 stop 后直接 exit，节点断连
    # 直到健康定时器兜底（1-5 分钟）。restart 对未运行服务报错也安全。
    echo "[RR-vps] 正在重启节点与面板服务……"
    systemctl restart sing-box 2>/dev/null || true
    systemctl restart rr-subscription 2>/dev/null || true
    systemctl restart rr-nexus 2>/dev/null || true
    sleep 1
    echo "[RR-vps] 模块化热更新完成。"
    exit 0
fi
echo "[RR-vps] 安装/迁移完成，原有节点配置（如有）已保留。"
rr_cleanup
trap - EXIT
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec "$RR_LAUNCHER" </dev/tty >/dev/tty
fi
echo "请输入 rr 打开管理面板。"
