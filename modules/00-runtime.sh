# shellcheck shell=bash
# RR-vps 运行时常量。此文件必须最先加载。

PURPLE="\033[1;35m"
CYAN="\033[1;36m"
GREEN="\033[32m"
YELLOW="\033[1;33m"
RED="\033[31m"
WHITE="\033[1;37m"
RESET="\033[0m"

RR_REPOSITORY="Xiaowu7z/RR-vps"
RR_UPDATE_CHANNEL_FILE="/etc/rr-update/channel"
RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"
RR_GITHUB_MIRROR="${RR_GITHUB_MIRROR:-}"

rr_refresh_update_channel_constants() {
    RR_UPDATE_CHANNEL="stable"
    if [ -r "$RR_UPDATE_CHANNEL_FILE" ]; then
        case "$(tr -d '[:space:]' < "$RR_UPDATE_CHANNEL_FILE")" in
            beta) RR_UPDATE_CHANNEL="beta" ;;
        esac
    fi
    RR_BRANCH="main"
    [ "$RR_UPDATE_CHANNEL" = beta ] && RR_BRANCH="beta"
    if [ "$RR_UPDATE_CHANNEL" = beta ]; then
        RR_RAW_BASE="https://raw.githubusercontent.com/${RR_REPOSITORY}/refs/heads/beta"
        RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@beta"
    else
        # Stable 只消费 CI 发布完成后的 Release 资产，绝不抢跑 main 分支。
        RR_RAW_BASE="https://github.com/${RR_REPOSITORY}/releases/latest/download"
        RR_CDN_BASE=""
    fi
    RR_BOOTSTRAP_URL="${RR_RAW_BASE}/install.sh"
    RR_MANIFEST_URL="${RR_RAW_BASE}/manifest.sha256"
}

rr_refresh_update_channel_constants
SCRIPT_VERSION="7.1.1"
RR_LIB_DIR="/usr/local/lib/rr"
RR_LOCAL_MANIFEST="${RR_LIB_DIR}/manifest.sha256"
RR_LAUNCHER="/usr/local/bin/rr"

CONFIG_FILE="/etc/argo_vmess.conf"
OS_RELEASE_FILE="/etc/os-release"
# PID/状态文件不能放在全局可写的 /tmp；否则本地低权限用户可预置符号链接，
# 诱导 root 启动流程覆盖任意文件。/run 本身仅 root 可写，且重启后自动清空。
SUB_PID_FILE="/run/rr-vps-subscription.pid"
SUB_BIND_STATE_FILE="/run/rr-vps-subscription.bind"
SUB_ROOT="/tmp/sub_server"
ARGO_PID_FILE="/run/rr-vps-argo-cloudflared.pid"
ARGO_LOG_FILE="/var/log/rr-argo.log"
RR_CF_TOKEN_FILE="/etc/rr-cloudflared/token"
FIREWALL_COMMENT="argo-rr-managed"
FIREWALL_BLOCK_COMMENT="argo-rr-managed-block"
CONFIG_SCHEMA_VERSION="9"
MIN_SINGBOX_VERSION="1.12.0"
SINGBOX_BIN="/usr/local/bin/sing-box"
UPDATE_AVAILABLE=false
UPDATE_CHECK_STATE="latest"    # H15 三态：latest / available / failed
UPDATE_CHECK_ERROR=""
SCRIPT_VER_STATUS="${GREEN}v${SCRIPT_VERSION}（最新）${RESET}"
SINGBOX_CONFIG_CHANGED=false
HEALTH_CHECK_DONE=false
SB_CORE_MISSING=false          # H16：内核缺失且自动重装失败（面板提示）
SB_ORPHAN_DETECTED=false       # H6：发现脱离 systemd 的孤立进程（面板提示）

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${RED}请使用 root 用户运行本脚本。${RESET}"
    return 1 2>/dev/null || exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64) SYS_ARCH="amd64" ;;
    aarch64|arm64) SYS_ARCH="arm64" ;;
    *)
        echo -e "${RED}当前脚本不支持您的系统架构: $ARCH${RESET}"
        return 1 2>/dev/null || exit 1
        ;;
esac
