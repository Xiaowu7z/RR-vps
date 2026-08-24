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
RR_BRANCH="main"
RR_RAW_BASE="https://raw.githubusercontent.com/${RR_REPOSITORY}/refs/heads/${RR_BRANCH}"
RR_API_BASE="https://api.github.com/repos/${RR_REPOSITORY}/contents"
RR_CDN_BASE="https://cdn.jsdelivr.net/gh/${RR_REPOSITORY}@${RR_BRANCH}"
RR_GITHUB_MIRROR="${RR_GITHUB_MIRROR:-}"
RR_BOOTSTRAP_URL="${RR_RAW_BASE}/install.sh"
SCRIPT_VERSION="7.0.2"
RR_MANIFEST_URL="${RR_RAW_BASE}/manifest.sha256"  # 干净URL+?t=防CDN旧缓存(2026-08)
RR_LIB_DIR="/usr/local/lib/rr"
RR_LOCAL_MANIFEST="${RR_LIB_DIR}/manifest.sha256"
RR_LAUNCHER="/usr/local/bin/rr"

CONFIG_FILE="/etc/argo_vmess.conf"
OS_RELEASE_FILE="/etc/os-release"
SUB_PID_FILE="/tmp/sub_server.pid"
SUB_BIND_STATE_FILE="/tmp/sub_server.bind"
SUB_ROOT="/tmp/sub_server"
ARGO_PID_FILE="/tmp/argo_rr_cloudflared.pid"
FIREWALL_COMMENT="argo-rr-managed"
FIREWALL_BLOCK_COMMENT="argo-rr-managed-block"
CONFIG_SCHEMA_VERSION="7"
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
