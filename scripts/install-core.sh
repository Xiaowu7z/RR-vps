#!/bin/bash

# shellcheck disable=SC2034 # Contract marker consumed by repository validation.
RR_BOOTSTRAP_VERSION="1"
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
ROLLBACK_FAILED=false
RR_TX_ROOT="/var/lib/rr-update"
RR_ACTIVE_TX="${RR_TX_ROOT}/active"
TX_DIR=""
KEEP_TRANSACTION=false
UPDATE_LOCK_FD=""

rr_error() {
    echo "[RR-vps] $*" >&2
}

rr_test_fault() {
    # CI-only fault injection.  Two explicit gates prevent an accidental user
    # environment variable from ever interrupting a real update.
    local phase="$1"
    [ "${RR_TEST_FAULTS:-0}" = 1 ] || return 0
    if [ "${RR_TEST_CRASH_PHASE:-}" = "$phase" ]; then
        kill -KILL $$
    fi
    [ "${RR_TEST_FAIL_PHASE:-}" != "$phase" ]
}

rr_download() {
    local source_url="$1"
    local target_file="$2"
    local cache_buster=""
    local relative_path=""
    local official_manifest="${3:-false}"

    cache_buster=$(date +%s)
    case "$source_url" in
        "${RR_RAW_BASE}/"*) relative_path="${source_url#"${RR_RAW_BASE}/"}" ;;
    esac

    if [ "$official_manifest" != true ] && [ -n "$RR_GITHUB_MIRROR" ]; then
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
            "${source_url}?t=${cache_buster}" -o "$target_file" 2>/dev/null && return 0
        if [ -n "$relative_path" ]; then
            curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
                -H "Accept: application/vnd.github.raw+json" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
            curl -4 -fsSL --retry 2 --connect-timeout 10 --max-time 180 \
                "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" \
                -o "$target_file" 2>/dev/null && return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 \
            -O "$target_file" "${source_url}?t=${cache_buster}" && return 0
        if [ -n "$relative_path" ]; then
            wget -q --timeout=15 --tries=2 \
                --header="Accept: application/vnd.github.raw+json" \
                -O "$target_file" \
                "${RR_API_BASE}/${relative_path}?ref=${RR_SOURCE_REF}&t=${cache_buster}" && return 0
            wget -4 -q --timeout=15 --tries=2 \
                -O "$target_file" "${RR_CDN_BASE}/${relative_path}?t=${cache_buster}" && return 0
        fi
    else
        rr_error "缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
    rr_error "无法从 GitHub Raw、GitHub API 或 CDN 下载：${relative_path:-$source_url}"
    return 1
}

rr_manifest_is_valid() {
    local manifest_file="$1"
    [ -s "$manifest_file" ] || return 1
    awk '
        NF != 2 { exit 1 }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
        seen[$2]++ { exit 1 }
        $2 == "rr" { launcher = 1; next }
        $2 == "scripts/naive-cert-hook.sh" { naive_hook = 1; next }
        $2 == "scripts/update-recover.sh" { recovery = 1; next }
        $2 ~ /^modules\/[0-9][0-9A-Za-z_-]*\.sh$/ { modules++; next }
        $2 == "nexus/rr_nexus.py" { nexus_app = 1; next }
        $2 == "nexus/sub_server.py" { nexus_sub = 1; next }
        $2 ~ /^nexus\/rr_nexus_lib\/[A-Za-z0-9._-]+\.py$/ { nexus_python++; next }
        $2 ~ /^nexus\/static\/[A-Za-z0-9._-]+\.(html|css|js)$/ { nexus_assets++; next }
        { exit 1 }
        END {
            if (!launcher || !naive_hook || !recovery || modules < 2) exit 1
            if (!nexus_app || !nexus_sub || nexus_assets < 3) exit 1
        }
    ' "$manifest_file"
}

rr_bundle_archive_is_safe() {
    local archive_file="$1"
    [ -s "$archive_file" ] || return 1
    # The runtime payload is normally below 1 MiB. Refuse unexpectedly large
    # downloads and any archive member outside the exact release namespace.
    [ "$(stat -c %s "$archive_file" 2>/dev/null || echo 0)" -le 52428800 ] || return 1
    tar -tzf "$archive_file" 2>/dev/null | awk '
        !/^rr-bundle\/(manifest\.sha256|rr|scripts\/(naive-cert-hook|update-recover)\.sh|modules\/[0-9][0-9A-Za-z_-]*\.sh|nexus\/[A-Za-z0-9._-]+\.py|nexus\/rr_nexus_lib\/[A-Za-z0-9._-]+\.py|nexus\/static\/[A-Za-z0-9._-]+\.(html|css|js))$/ { exit 1 }
        seen[$0]++ { exit 1 }
        END { if (NR < 2) exit 1 }
    '
}

rr_bundle_tree_is_valid() {
    local bundle_root="$1"
    local manifest_file="$bundle_root/manifest.sha256"
    local expected_count=0
    local actual_count=0
    local shell_file=""

    rr_manifest_is_valid "$manifest_file" || return 1
    if find "$bundle_root" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
        return 1
    fi
    expected_count=$(( $(awk 'END { print NR + 0 }' "$manifest_file") + 1 ))
    actual_count=$(find "$bundle_root" -type f | wc -l)
    [ "$actual_count" -eq "$expected_count" ] || return 1
    (cd "$bundle_root" && sha256sum -c manifest.sha256 >/dev/null 2>&1) || return 1
    bash -n "$bundle_root/rr" || return 1
    for shell_file in "$bundle_root"/modules/*.sh; do
        [ -f "$shell_file" ] || return 1
        bash -n "$shell_file" || return 1
    done
    bash -n "$bundle_root/scripts/naive-cert-hook.sh" || return 1
    bash -n "$bundle_root/scripts/update-recover.sh" || return 1
    local python_file=""
    while IFS= read -r python_file; do
        python3 -m py_compile "$python_file" || return 1
    done < <(find "$bundle_root/nexus" -type f -name '*.py' -print | LC_ALL=C sort)
}

rr_version_ge() {
    [ "$1" = "$2" ] || \
        [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n 1)" = "$1" ]
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

    for required_command in bash awk sed grep wc head sha256sum install mktemp cp mv rm mkdir dirname basename systemctl python3 tar find stat cmp pgrep pkill sort tail flock; do
        command -v "$required_command" >/dev/null 2>&1 || {
            rr_error "系统缺少必要命令：${required_command}"
            return 1
        }
    done
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        rr_error "系统缺少 curl/wget，无法下载 RR-vps。"
        return 1
    fi
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
    local source_uid=""
    if [ -L "$source_dir" ]; then
        rr_error "拒绝备份符号链接目录：${source_dir}"
        return 1
    fi
    if [ -d "$source_dir" ]; then
        source_uid=$(stat -c '%u' -- "$source_dir" 2>/dev/null) || return 1
        if [ "$source_uid" != 0 ]; then
            rr_error "拒绝备份非 root 所有的运行目录：${source_dir}"
            return 1
        fi
        cp -a "$source_dir" "$BACKUP_DIR/$backup_name" || return 1
        : > "$BACKUP_DIR/had_${backup_name}"
    fi
}

rr_backup_sqlite() {
    local source_db="$1"
    local backup_name="$2"
    [ -e "$source_db" ] || return 0
    if ! python3 - "$source_db" "$BACKUP_DIR/$backup_name" <<'PY'
import sqlite3
import sys

source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=10)
target = sqlite3.connect(sys.argv[2])
try:
    source.backup(target)
finally:
    target.close()
    source.close()
PY
    then
        rm -f "$BACKUP_DIR/$backup_name"
        return 1
    fi
    : > "$BACKUP_DIR/had_${backup_name}"
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
        return 1
    else
        rm -f "$target_file" || return 1
    fi
    return 0
}

rr_restore_dir() {
    local backup_name="$1"
    local target_dir="$2"
    rm -rf "$target_dir" || return 1
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        if [ -L "$BACKUP_DIR/$backup_name" ] || [ ! -d "$BACKUP_DIR/$backup_name" ]; then
            rr_error "拒绝恢复不安全的目录备份：${backup_name}"
            return 1
        fi
        mkdir -p "$(dirname "$target_dir")" || return 1
        cp -a "$BACKUP_DIR/$backup_name" "$target_dir" || return 1
    fi
    return 0
}

rr_restore_sqlite() {
    local backup_name="$1"
    local target_db="$2"
    rm -f "$target_db" "${target_db}-wal" "${target_db}-shm" || return 1
    if [ -f "$BACKUP_DIR/had_${backup_name}" ]; then
        mkdir -p "$(dirname "$target_db")" || return 1
        install -m 600 "$BACKUP_DIR/$backup_name" "$target_db" || return 1
    fi
    return 0
}

rr_write_phase() {
    local phase="$1" temporary=""
    [ -n "$TX_DIR" ] || return 1
    temporary="$TX_DIR/.phase.$$"
    printf '%s\n' "$phase" > "$temporary" && mv -f "$temporary" "$TX_DIR/phase"
}

rr_prepare_recovery_runtime() {
    local recovery_source="$PAYLOAD_DIR/scripts/update-recover.sh"
    local recovery_target="/usr/local/sbin/rr-update-recover"
    local recovery_tmp=""
    [ -s "$recovery_source" ] && bash -n "$recovery_source" || return 1
    mkdir -p /usr/local/sbin /etc/systemd/system "$RR_TX_ROOT/transactions" || return 1
    chmod 700 "$RR_TX_ROOT"
    recovery_tmp=$(mktemp /usr/local/sbin/.rr-update-recover.XXXXXX) || return 1
    install -m 755 "$recovery_source" "$recovery_tmp" && mv -f "$recovery_tmp" "$recovery_target" || {
        rm -f "$recovery_tmp"
        return 1
    }
    cat > /etc/systemd/system/rr-update-recovery.service <<'EOF'
[Unit]
Description=RR-vps interrupted update recovery
DefaultDependencies=no
After=local-fs.target
Before=network.target
ConditionPathExists=/var/lib/rr-update/active

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/rr-update-recover recover

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable rr-update-recovery.service >/dev/null 2>&1 || return 1
}

rr_discard_previous_transaction() {
    local previous="" phase=""
    [ -r "$RR_ACTIVE_TX" ] || return 0
    previous=$(head -n 1 "$RR_ACTIVE_TX" 2>/dev/null)
    case "$previous" in "$RR_TX_ROOT"/transactions/*) ;; *) return 1 ;; esac
    [ -d "$previous" ] || { rm -f "$RR_ACTIVE_TX"; return 0; }
    phase=$(head -n 1 "$previous/phase" 2>/dev/null || true)
    case "$phase" in
        committed|rolled_back|aborted)
            rm -rf -- "$previous" || return 1
            rm -f "$RR_ACTIVE_TX"
            ;;
        *)
            /usr/local/sbin/rr-update-recover recover || return 1
            ;;
    esac
}

rr_prune_stale_transactions() {
    local transaction="" phase="" active=""
    [ -r "$RR_ACTIVE_TX" ] && active=$(head -n 1 "$RR_ACTIVE_TX" 2>/dev/null || true)
    while IFS= read -r transaction; do
        [ "$transaction" = "$active" ] && continue
        case "$transaction" in "$RR_TX_ROOT"/transactions/*) ;; *) continue ;; esac
        phase=$(head -n 1 "$transaction/phase" 2>/dev/null || true)
        case "$phase" in rolled_back|aborted) rm -rf -- "$transaction" || return 1 ;; esac
    done < <(find "$RR_TX_ROOT/transactions" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | LC_ALL=C sort)
}

rr_snapshot_runtime() {
    rr_prepare_recovery_runtime || return 1
    rr_discard_previous_transaction || return 1
    rr_prune_stale_transactions || return 1
    TX_DIR="$RR_TX_ROOT/transactions/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
    BACKUP_DIR="$TX_DIR/backup"
    mkdir -p "$BACKUP_DIR" || return 1
    chmod 700 "$TX_DIR" "$BACKUP_DIR"
    printf '%s\n' "$TX_DIR" > "${RR_ACTIVE_TX}.tmp.$$" || return 1
    mv -f "${RR_ACTIVE_TX}.tmp.$$" "$RR_ACTIVE_TX" || return 1
    rr_write_phase snapshotting || return 1

    rr_backup_file "$RR_LAUNCHER" rr_launcher || return 1
    rr_backup_file /etc/argo_vmess.conf argo_vmess.conf || return 1
    rr_backup_file /etc/sing-box/config.json singbox_config.json || return 1
    rr_backup_file /etc/sing-box/cert.pem singbox_cert.pem || return 1
    rr_backup_file /etc/sing-box/private.key singbox_private.key || return 1
    rr_backup_file /usr/local/bin/sing-box singbox_binary || return 1
    rr_backup_file /etc/systemd/system/sing-box.service singbox.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.service health.service || return 1
    rr_backup_file /etc/systemd/system/argo-rr-health.timer health.timer || return 1
    rr_backup_file /usr/local/bin/auto_update_sub.py auto_update_sub.py || return 1
    rr_backup_file /etc/rr-nexus/nexus.json nexus.json || return 1
    rr_backup_file /etc/systemd/system/rr-nexus.service nexus.service || return 1
    rr_backup_file /etc/rr-update/channel update_channel || return 1
    rr_backup_file /var/lib/rr-nexus/remote.key remote.key || return 1
    rr_backup_dir /etc/rr-naive rr-naive || return 1
    rr_backup_sqlite /var/lib/rr-nexus/nexus.db nexus.db || return 1
    rr_backup_dir /tmp/sub_server sub_server || return 1

    systemctl is-active --quiet sing-box 2>/dev/null && : > "$BACKUP_DIR/singbox_was_running"
    systemctl is-active --quiet rr-nexus 2>/dev/null && : > "$BACKUP_DIR/nexus_was_running"
    pgrep -f 'subscription_server\.py' >/dev/null 2>&1 && \
        : > "$BACKUP_DIR/subscription_was_running"
    pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1 && : > "$BACKUP_DIR/argo_was_running"
    systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && \
        : > "$BACKUP_DIR/health_timer_was_enabled"

    # Service state probes are optional metadata. A fresh server has none of
    # these units yet, so their non-zero status must not turn a valid empty
    # snapshot into a failed update backup.
    [ -e "$RR_LIB_DIR" ] || : > "$BACKUP_DIR/runtime_did_not_exist"
    rr_write_phase prepared
}

rr_rollback() {
    [ "$TRANSACTION_ACTIVE" = true ] || return 0
    TRANSACTION_ACTIVE=false
    local rollback_failed=false
    rr_error "新版本校验失败，正在恢复升级前状态……"

    systemctl stop sing-box rr-nexus >/dev/null 2>&1 || true
    pkill -f 'subscription_server\.py' >/dev/null 2>&1 || true

    # OLD_RUNTIME becomes authoritative as soon as the live directory is moved.
    # A catchable failure can occur before RUNTIME_REPLACED flips to true (for
    # example a failed candidate move), so keying restoration only on that flag
    # would discard the sole old runtime during cleanup.
    if [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ]; then
        if { [ ! -e "$RR_LIB_DIR" ] || rm -rf "$RR_LIB_DIR"; } && \
           mv "$OLD_RUNTIME" "$RR_LIB_DIR"; then
            OLD_RUNTIME=""
        else
            rollback_failed=true
        fi
    elif [ "$RUNTIME_REPLACED" = true ]; then
        rm -rf "$RR_LIB_DIR" || rollback_failed=true
    fi
    RUNTIME_REPLACED=false

    rr_restore_file rr_launcher "$RR_LAUNCHER" || rollback_failed=true
    rr_restore_file argo_vmess.conf /etc/argo_vmess.conf || rollback_failed=true
    rr_restore_file singbox_config.json /etc/sing-box/config.json || rollback_failed=true
    rr_restore_file singbox_cert.pem /etc/sing-box/cert.pem || rollback_failed=true
    rr_restore_file singbox_private.key /etc/sing-box/private.key || rollback_failed=true
    rr_restore_file singbox_binary /usr/local/bin/sing-box || rollback_failed=true
    rr_restore_file singbox.service /etc/systemd/system/sing-box.service || rollback_failed=true
    rr_restore_file health.service /etc/systemd/system/argo-rr-health.service || rollback_failed=true
    rr_restore_file health.timer /etc/systemd/system/argo-rr-health.timer || rollback_failed=true
    rr_restore_file auto_update_sub.py /usr/local/bin/auto_update_sub.py || rollback_failed=true
    rr_restore_file nexus.json /etc/rr-nexus/nexus.json || rollback_failed=true
    rr_restore_file nexus.service /etc/systemd/system/rr-nexus.service || rollback_failed=true
    rr_restore_file update_channel /etc/rr-update/channel || rollback_failed=true
    rr_restore_file remote.key /var/lib/rr-nexus/remote.key || rollback_failed=true
    rr_restore_dir rr-naive /etc/rr-naive || rollback_failed=true
    rr_restore_sqlite nexus.db /var/lib/rr-nexus/nexus.db || rollback_failed=true
    rr_restore_dir sub_server /tmp/sub_server || rollback_failed=true

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
    else
        systemctl stop rr-nexus >/dev/null 2>&1 || true
    fi
    if [ -f "$BACKUP_DIR/subscription_was_running" ] && [ -x "$RR_LAUNCHER" ]; then
        "$RR_LAUNCHER" --health-check >/dev/null 2>&1 || \
            rr_error "警告：旧版订阅服务未能自动恢复，请执行 rr 重试。"
    fi
    if [ "$rollback_failed" = true ]; then
        ROLLBACK_FAILED=true
        rr_error "严重：回滚未完整完成；现场备份将保留在 ${BACKUP_DIR}，请勿删除。"
        [ -n "$OLD_RUNTIME" ] && rr_error "旧运行目录仍保留在 ${OLD_RUNTIME}。"
        return 1
    fi
    rr_write_phase rolled_back >/dev/null 2>&1 || true
    rm -f "$RR_ACTIVE_TX"
    if [ -f "$BACKUP_DIR/runtime_did_not_exist" ]; then
        systemctl disable rr-update-recovery.service >/dev/null 2>&1 || true
        rm -f -- /etc/systemd/system/rr-update-recovery.service /usr/local/sbin/rr-update-recover
        systemctl daemon-reload >/dev/null 2>&1 || true
        rm -rf -- "$RR_TX_ROOT"
    fi
    rr_error "回滚完成：原 rr、配置、内核、Nexus 数据库和订阅已恢复。"
    return 0
}

rr_cleanup() {
    local result="${1:-0}"
    if [ "$result" -ne 0 ] && [ "$TRANSACTION_ACTIVE" = true ]; then
        rr_rollback || result=1
    fi
    [ -n "$STAGE_ROOT" ] && rm -rf "$STAGE_ROOT"
    [ -n "$NEW_RUNTIME" ] && [ -e "$NEW_RUNTIME" ] && rm -rf "$NEW_RUNTIME"
    [ -n "$NEW_LAUNCHER" ] && [ -e "$NEW_LAUNCHER" ] && rm -f "$NEW_LAUNCHER"
    if [ "$ROLLBACK_FAILED" != true ] && [ "$KEEP_TRANSACTION" != true ]; then
        [ -n "$OLD_RUNTIME" ] && [ -e "$OLD_RUNTIME" ] && rm -rf "$OLD_RUNTIME"
        [ -n "$BACKUP_DIR" ] && rm -rf "$BACKUP_DIR"
        [ -n "$TX_DIR" ] && [ -d "$TX_DIR" ] && rm -rf "$TX_DIR"
        [ -n "$TX_DIR" ] && [ "$(head -n 1 "$RR_ACTIVE_TX" 2>/dev/null || true)" = "$TX_DIR" ] && rm -f "$RR_ACTIVE_TX"
    fi
    return "$result"
}

rr_fetch_release() {
    STAGE_ROOT=$(mktemp -d /tmp/rr-release.XXXXXX) || return 1
    PAYLOAD_DIR="$STAGE_ROOT/payload"
    mkdir -p "$PAYLOAD_DIR/modules"

    echo "[RR-vps] 正在下载发布清单……"
    local actual=""
    local bundle_ready=false
    if [ -n "${RR_BUNDLE_FILE:-}" ] && [ -r "$RR_BUNDLE_FILE" ]; then
        cp -p -- "$RR_BUNDLE_FILE" "$STAGE_ROOT/rr-bundle.tar.gz" 2>/dev/null && \
            bundle_ready=true
    elif rr_download "${RR_RAW_BASE}/rr-bundle.tar.gz" \
        "$STAGE_ROOT/rr-bundle.tar.gz" 2>/dev/null; then
        bundle_ready=true
    fi
    if [ "$bundle_ready" = true ]; then
        actual=$(sha256sum "$STAGE_ROOT/rr-bundle.tar.gz" | awk '{print $1}')
        if [ "$actual" = "e5f882810c405c4f79ac8ba73bffd0c3ce2b97bdc6583b21492f3f45e19f79a4" ] && \
           rr_bundle_archive_is_safe "$STAGE_ROOT/rr-bundle.tar.gz" && \
           tar --no-same-owner --no-same-permissions -xzf \
               "$STAGE_ROOT/rr-bundle.tar.gz" -C "$PAYLOAD_DIR" \
               --strip-components=1 2>/dev/null && \
           rr_bundle_tree_is_valid "$PAYLOAD_DIR"; then
            cp "$PAYLOAD_DIR/manifest.sha256" "$STAGE_ROOT/manifest.sha256" || return 1
            echo "[RR-vps] ✓ 高速模式加载完成（外层与内部 SHA256 均已校验）"
            return 0
        fi
    fi

    echo "[RR-vps] ⚡ 高速模式未命中，切换逐文件下载……"
    rm -rf "$PAYLOAD_DIR"
    mkdir -p "$PAYLOAD_DIR/modules"
    # manifest 是逐文件下载的信任锚；镜像只能搬运随后按官方哈希校验的文件，
    # 不能提供或替换这份锚点。
    rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" true || return 1
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
        rr_download "$RR_MANIFEST_URL" "$STAGE_ROOT/manifest.sha256" true || return 1
        rr_manifest_is_valid "$STAGE_ROOT/manifest.sha256" || { rr_error "远程发布清单格式无效。"; return 1; }
        while read -r _ relative_path; do
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
        local python_file=""
        while IFS= read -r python_file; do
            python3 -m py_compile "$python_file" || return 1
        done < <(find "$PAYLOAD_DIR/nexus" -type f -name '*.py' -print | LC_ALL=C sort)
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
    local release_version=""
    local installed_version=""
    release_version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"/\1/p' \
        "$PAYLOAD_DIR/modules/00-runtime.sh" | head -n 1)
    [[ "$release_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        rr_error "发布包版本号无效，拒绝安装。"
        return 1
    }
    if [ "$RR_MODE" = "--upgrade" ] && \
       [ -r "$RR_LIB_DIR/modules/00-runtime.sh" ]; then
        installed_version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"/\1/p' \
            "$RR_LIB_DIR/modules/00-runtime.sh" | head -n 1)
        if [[ "$installed_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
           ! rr_version_ge "$release_version" "$installed_version"; then
            rr_error "已阻止降级：发布包 ${release_version} 低于已安装版本 ${installed_version}。"
            return 1
        fi
    fi

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
    if [ -n "${RR_GUARD_FILE:-}" ]; then
        [ -s "$RR_GUARD_FILE" ] && bash -n "$RR_GUARD_FILE" && \
            grep -q '^RR_UPDATE_GUARD_VERSION=' "$RR_GUARD_FILE" && \
            grep -q '^do_update() {' "$RR_GUARD_FILE" || return 1
        install -m 644 "$RR_GUARD_FILE" "$NEW_RUNTIME/modules/61-update-guard.sh" || return 1
    fi
    install -d -m 755 "$NEW_RUNTIME/scripts"
    install -m 755 "$PAYLOAD_DIR/scripts/naive-cert-hook.sh" \
        "$NEW_RUNTIME/scripts/naive-cert-hook.sh" || return 1
    install -m 755 "$PAYLOAD_DIR/scripts/update-recover.sh" \
        "$NEW_RUNTIME/scripts/update-recover.sh" || return 1
    if [ -f "$PAYLOAD_DIR/nexus/rr_nexus.py" ]; then
        # Nexus 后端与前端均以已校验的 manifest 为唯一来源。允许安全地
        # 拆分 Python/JS/CSS 模块，不再需要同步维护安装器文件白名单。
        local relative_path=""
        while read -r _ relative_path; do
            case "$relative_path" in
                nexus/rr_nexus.py|nexus/sub_server.py|nexus/rr_nexus_lib/*.py)
                    [ -f "$PAYLOAD_DIR/$relative_path" ] || return 1
                    install -d -m 755 "$NEW_RUNTIME/$(dirname "$relative_path")" || return 1
                    install -m 755 "$PAYLOAD_DIR/$relative_path" \
                        "$NEW_RUNTIME/$relative_path" || return 1
                    ;;
                nexus/static/*.html|nexus/static/*.css|nexus/static/*.js)
                    [ -f "$PAYLOAD_DIR/$relative_path" ] || return 1
                    install -d -m 755 "$NEW_RUNTIME/$(dirname "$relative_path")" || return 1
                    install -m 644 "$PAYLOAD_DIR/$relative_path" \
                        "$NEW_RUNTIME/$relative_path" || return 1
                    ;;
            esac
        done < "$STAGE_ROOT/manifest.sha256"
    fi
    NEW_LAUNCHER=$(mktemp /usr/local/bin/.rr.new.XXXXXX) || return 1
    install -m 755 "$PAYLOAD_DIR/rr" "$NEW_LAUNCHER" || return 1

    TRANSACTION_ACTIVE=true
    rr_write_phase switching || return 1
    if [ -e "$RR_LIB_DIR" ]; then
        OLD_RUNTIME="$TX_DIR/old-runtime"
        if ! mv "$RR_LIB_DIR" "$OLD_RUNTIME"; then
            TRANSACTION_ACTIVE=false
            return 1
        fi
        rr_test_fault old_runtime_moved || return 1
    fi
    RUNTIME_REPLACED=true
    mv "$NEW_RUNTIME" "$RR_LIB_DIR" || return 1
    NEW_RUNTIME=""
    rr_write_phase runtime_swapped || return 1
    rr_test_fault runtime_swapped || return 1
    mv "$NEW_LAUNCHER" "$RR_LAUNCHER" || return 1
    NEW_LAUNCHER=""

    rr_write_phase migrating || return 1
    if ! RR_UPDATE_TRANSACTION=1 \
        RR_UPDATE_SINGBOX_WAS_RUNNING="$([ -f "$BACKUP_DIR/singbox_was_running" ] && printf true || printf false)" \
        RR_UPDATE_NEXUS_WAS_RUNNING="$([ -f "$BACKUP_DIR/nexus_was_running" ] && printf true || printf false)" \
        RR_UPDATE_SUBSCRIPTION_WAS_RUNNING="$([ -f "$BACKUP_DIR/subscription_was_running" ] && printf true || printf false)" \
        RR_UPDATE_ARGO_WAS_RUNNING="$([ -f "$BACKUP_DIR/argo_was_running" ] && printf true || printf false)" \
        RR_UPDATE_HEALTH_TIMER_WAS_ENABLED="$([ -f "$BACKUP_DIR/health_timer_was_enabled" ] && printf true || printf false)" \
        "$RR_LAUNCHER" --post-update; then
        rr_rollback
        return 1
    fi
    rr_test_fault migrated || return 1

    if ! rr_write_phase committed; then
        rr_rollback
        return 1
    fi
    TRANSACTION_ACTIVE=false
    KEEP_TRANSACTION=true
    return 0
}

case "$RR_MODE" in
    install|--upgrade) ;;
    *)
        rr_error "未知参数：${RR_MODE}"
        exit 2
        ;;
esac

trap 'rr_cleanup "$?"' EXIT
trap 'exit 130' INT TERM HUP

rr_check_system || exit 1
mkdir -p /run/lock || exit 1
exec {UPDATE_LOCK_FD}>/run/lock/rr-update.lock || exit 1
if ! flock -n "$UPDATE_LOCK_FD"; then
    rr_error "另一个安装/更新任务正在运行，本次未改动系统。"
    exit 1
fi
rr_fetch_release || exit 1
rr_install_release || exit 1

if [ "$RR_MODE" = "--upgrade" ]; then
    # --post-update 已完成迁移与服务恢复；这里不得再用 || true 掩盖失败，
    # 也不得把用户原本停用的服务无条件拉起。
    echo "[RR-vps] 模块化热更新完成。"
    exit 0
fi
echo "[RR-vps] 安装/迁移完成，原有节点配置（如有）已保留。"
rr_cleanup 0
trap - EXIT
if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec "$RR_LAUNCHER" </dev/tty >/dev/tty
fi
echo "请输入 rr 打开管理面板。"
