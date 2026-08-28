# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 11. 安装 F2B 防护盾
# ==========================================
install_f2b() {
    check_supported_os >/dev/null 2>&1 || return 1
    clear
    echo -e "=================================================="
    echo -e "${GREEN}        Fail2Ban (F2B) SSH 安全防护盾${RESET}"
    echo -e "=================================================="
    echo -e "说明：开启后可拦截黑客暴力破解 VPS 密码的恶意行为。"
    echo -e "--------------------------------------------------"
    read -p "请输入允许输错的最大次数 (回车默认 3): " f2b_retry
    f2b_retry=${f2b_retry:-3}
    [[ "$f2b_retry" =~ ^[1-9][0-9]*$ ]] || f2b_retry=3

    read -p "请输入封禁时长 (如 30d, 24h, 60m。回车默认 30d): " f2b_time
    f2b_time=${f2b_time:-30d}
    [[ "$f2b_time" =~ ^[1-9][0-9]*(s|m|h|d|w)$ ]] || f2b_time=30d

    echo -e "\n${YELLOW}正在为您安装 Fail2Ban 组件...${RESET}"
    if ! DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null 2>&1 || \
       ! DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y fail2ban >/dev/null 2>&1; then
        echo -e "${RED}[失败] Fail2Ban 软件包安装失败，未修改现有配置。${RESET}"
        sleep 2
        return 1
    fi

    local f2b_backend="auto"
    local f2b_logpath="logpath = /var/log/auth.log"
    local f2b_config="/etc/fail2ban/jail.d/argo-rr-sshd.local"
    local f2b_tmp=""
    local f2b_backup=""
    if [ ! -f /var/log/auth.log ]; then
        f2b_backend="systemd"
        f2b_logpath=""
    fi

    mkdir -p /etc/fail2ban/jail.d || return 1
    f2b_tmp=$(mktemp /etc/fail2ban/jail.d/.argo-rr-sshd.local.XXXXXX) || return 1
    if [ -f "$f2b_config" ]; then
        f2b_backup=$(mktemp /tmp/argo-rr-fail2ban.XXXXXX) || { rm -f "$f2b_tmp"; return 1; }
        cp -p "$f2b_config" "$f2b_backup" || { rm -f "$f2b_tmp" "$f2b_backup"; return 1; }
    fi
    if ! cat > "$f2b_tmp" <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
backend = ${f2b_backend}
${f2b_logpath}
maxretry = ${f2b_retry}
bantime = ${f2b_time}
findtime = 600
EOF
    then
        rm -f "$f2b_tmp" "$f2b_backup"
        return 1
    fi
    chmod 644 "$f2b_tmp" || { rm -f "$f2b_tmp" "$f2b_backup"; return 1; }
    mv -f "$f2b_tmp" "$f2b_config" || { rm -f "$f2b_tmp" "$f2b_backup"; return 1; }

    if ! fail2ban-client -t >/dev/null 2>&1 || \
       ! systemctl enable fail2ban >/dev/null 2>&1 || \
       ! systemctl restart fail2ban >/dev/null 2>&1 || \
       ! systemctl is-active --quiet fail2ban; then
        if [ -n "$f2b_backup" ] && [ -f "$f2b_backup" ]; then
            cp -p "$f2b_backup" "$f2b_config" >/dev/null 2>&1 || true
        else
            rm -f "$f2b_config"
        fi
        systemctl restart fail2ban >/dev/null 2>&1 || true
        rm -f "$f2b_backup"
        echo -e "${RED}[失败] Fail2Ban 配置自检或启动失败，已恢复修改前状态。${RESET}"
        sleep 2
        return 1
    fi
    rm -f "$f2b_backup"

    echo -e "\n=================================================="
    echo -e "${GREEN}[成功] F2B 防护盾已激活并生效！${RESET}"
    echo -e "当前安全规则：${YELLOW}SSH 密码错误 ${f2b_retry} 次，直接封禁黑客 IP ${f2b_time}${RESET}"
    echo -e "=================================================="
    read -p "按回车键返回主菜单..."
}

# ==========================================

# 修复已有节点（不重置任何配置）
_install_repair_existing() {
    echo -e "${YELLOW}检测到已有节点配置，本次执行修复/迁移，不会重置 UUID、密钥、域名或任何端口。${RESET}"
    install_deps || return 1
    migrate_config_schema || return 1
    load_config_with_defaults || return 1
    local repair_any_protocol=false
    if any_node_protocol_enabled; then
        repair_any_protocol=true
    fi
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ]; then
        install_cloudflared || return 1
    fi
    if [ "$repair_any_protocol" = true ]; then
        ensure_singbox_core || return 1
        generate_certs_and_keys || return 1
        build_singbox_config || return 1
        setup_systemd || return 1
    fi
    load_config_with_defaults || return 1
    open_firewall
    [ "$VL_ENABLED" = "true" ] && open_protocol_firewall "$VL_PORT" tcp
    [ "$HY2_ENABLED" = "true" ] && open_protocol_firewall "$HY2_PORT" udp
    [ "$TU5_ENABLED" = "true" ] && open_protocol_firewall "$TU5_PORT" udp
    [ "$AN_ENABLED" = "true" ] && open_protocol_firewall "$AN_PORT" tcp
    # NAIVE-SUPPORT
    if [ "$NAIVE_ENABLED" = "true" ] && [ -n "$NAIVE_PORT" ] && [ "$NAIVE_PORT" != "0" ]; then
        [ "${NAIVE_MODE:-h2}" != h3 ] && open_protocol_firewall "$NAIVE_PORT" tcp
        [ "${NAIVE_MODE:-h2}" != h2 ] && open_protocol_firewall "$NAIVE_PORT" udp
    fi
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_HOP_PORTS" ] && \
       ! install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1; then
        echo -e "${RED}[失败] 当前入口地址族无法恢复 HY2 跳跃规则；原配置未改动。${RESET}"
        return 1
    fi
    # NAIVE-SUPPORT：安装期申请 Let's Encrypt 真证书（证书就绪后 sing-box 才能起 naive 入站）
    if [ "$NAIVE_ENABLED" = "true" ]; then
        if ! ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL"; then
            echo -e "${YELLOW}[警告] NaiveProxy 证书申请未成功。节点其他协议不受影响；稍后可在协议开关中重新开启 naive 以重试。${RESET}"
        fi
    fi
    generate_node_and_sub || return 1
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && \
       ! expected_argo_tunnel_running; then
        start_argo_tunnel || true
    fi
    [ "$repair_any_protocol" = true ] && setup_health_monitor >/dev/null 2>&1 || true
    echo -e "${GREEN}[成功] 修复与兼容迁移完成，原节点信息全部保留。${RESET}"
    sleep 1
    show_info
    return
}


# 提示输入 UUID、优选域名、隧道模式
_install_prompt_identity() {
    local RAND_UUID=""
    RAND_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo -e "\n=================================================="
    echo -e "请输入您的 ${GREEN}用户ID (UUID)${RESET}"
    echo -e "格式范本：${CYAN}0fe4575e-644a-4b16-877d-0ddf493bc1d1${RESET}"
    echo -e "=================================================="
    read -p "请输入UUID (直接回车默认自动随机生成): " USER_UUID
    UUID=${USER_UUID:-$RAND_UUID}
    while ! is_valid_uuid "$UUID"; do
        echo -e "${RED}UUID 格式无效。${RESET}"
        read -p "请重新输入 UUID（回车自动生成）: " USER_UUID
        UUID=${USER_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    done

    CDN_IP="cloudflare-ech.com"
    local tunnel_choice=1
    if [ "$INSTALL_ARGO_SELECTED" = true ]; then
    echo -e "\n=================================================="
    echo -e "请选择初始 ${GREEN}优选IP/域名${RESET}："
    echo -e "  1. cloudflare-ech.com (${CYAN}直接敲回车默认此项${RESET})"
    echo -e "  2. www.visa.com.sg"
    echo -e "  3. www.wto.org"
    echo -e "  4. www.web.com"
    echo -e "  5. 手动输入"
    echo -e "=================================================="
    read -p "请输入选项或直接粘贴优选域名: " init_cdn_choice

    case "$init_cdn_choice" in
        1|"") CDN_IP="cloudflare-ech.com" ;;
        2) CDN_IP="www.visa.com.sg" ;;
        3) CDN_IP="www.wto.org" ;;
        4) CDN_IP="www.web.com" ;;
        5) read -p "请输入自定义地址: " CDN_IP ;;
        *) CDN_IP="$init_cdn_choice" ;;
    esac
    if ! is_valid_host_or_ip "$CDN_IP"; then
        echo -e "${RED}优选 IP/域名格式无效，安装中止。${RESET}"
        return 1
    fi

    echo -e "\n=================================================="
    echo -e "${YELLOW}⚠️  重要说明：关于 Argo 隧道的选择${RESET}"
    echo -e "=================================================="
    echo -e "  1. 使用 ${GREEN}临时隧道${RESET} (直接回车默认)"
    echo -e "  2. 使用 ${CYAN}固定隧道${RESET} (需拥有 Cloudflare Token)"
    echo -e "=================================================="
    read -p "请选择隧道模式 [1-2]: " tunnel_choice
    tunnel_choice=${tunnel_choice:-1}
    case "$tunnel_choice" in
        1|2) ;;
        *)
            echo -e "${RED}隧道模式只能选择 1 或 2，安装中止。${RESET}"
            return 1
            ;;
    esac
    fi
    return 0
}

# 12. 卸载与清理
# ==========================================
uninstall_all() {
    local reinstall_url="https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/main/install.sh"
    local project_url="https://github.com/Xiaowu7z/RR-vps"
    echo -e "\n${RED}此操作会删除 rr、Sing-box、RR Nexus 数据库、节点配置、证书、订阅及本脚本防火墙规则。${RESET}"
    read -p "确认完全卸载请输入 y: " uninstall_confirm
    if [ "$uninstall_confirm" != "y" ] && [ "$uninstall_confirm" != "Y" ]; then
        echo -e "${YELLOW}已取消卸载，现有节点未改动。${RESET}"
        sleep 1
        return 0
    fi
    echo -e "\n${RED}正在完全卸载并清理残留...${RESET}"
    [ -f "$CONFIG_FILE" ] && load_config_with_defaults
    systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    systemctl stop argo-rr-health.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/argo-rr-health.timer /etc/systemd/system/argo-rr-health.service
    systemctl disable --now rr-nexus >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rr-nexus.service
    systemctl disable --now rr-update-recovery.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/rr-update-recovery.service /usr/local/sbin/rr-update-recover
    declare -F nexus_remove_public_proxy >/dev/null 2>&1 && nexus_remove_public_proxy
    stop_singbox_instances >/dev/null 2>&1 || true
    systemctl disable sing-box 2>/dev/null
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload 2>/dev/null
    stop_quick_argo_tunnel
    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
        systemctl disable --now cloudflared >/dev/null 2>&1 || true
        cloudflared service uninstall >/dev/null 2>&1 || true
    fi

    [ -n "${HY2_PORT:-}" ] && remove_hop_ports "$HY2_PORT" HY2 "${HY2_HOP_PORTS:-}"
    [ -n "${TU5_PORT:-}" ] && remove_hop_ports "$TU5_PORT" TU5 "${TU5_HOP_PORTS:-}"
    [ -n "${PORT:-}" ] && close_protocol_firewall "$PORT" tcp
    [ -n "${SUB_PORT:-}" ] && close_protocol_firewall "$SUB_PORT" tcp
    [ -n "${VL_PORT:-}" ] && close_protocol_firewall "$VL_PORT" tcp
    [ -n "${HY2_PORT:-}" ] && close_protocol_firewall "$HY2_PORT" udp
    [ -n "${TU5_PORT:-}" ] && close_protocol_firewall "$TU5_PORT" udp
    [ -n "${AN_PORT:-}" ] && close_protocol_firewall "$AN_PORT" tcp
    [ -n "${NAIVE_PORT:-}" ] && close_protocol_firewall "$NAIVE_PORT" tcp
    [ -n "${NAIVE_PORT:-}" ] && close_protocol_firewall "$NAIVE_PORT" udp

    if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
        (crontab -l 2>/dev/null | grep -v "auto_update_sub.py") | crontab -
    fi
    rm -f /usr/local/bin/auto_update_sub.py
    rm -f /etc/letsencrypt/renewal-hooks/deploy/rr-naive-cert.sh
    rm -f /etc/nginx/sites-enabled/rr-naive-acme.conf /etc/nginx/sites-available/rr-naive-acme.conf
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    if [ -f /etc/fail2ban/jail.d/argo-rr-sshd.local ]; then
        rm -f /etc/fail2ban/jail.d/argo-rr-sshd.local
        fail2ban-client -t >/dev/null 2>&1 && \
            systemctl restart fail2ban >/dev/null 2>&1 || true
    fi

    stop_subscription_servers >/dev/null 2>&1 || true

    # 可疑的 /tmp 订阅根绝不以 root 身份递归删除；保留现场并提示人工检查。
    if ensure_subscription_root; then
        rm -rf -- "$SUB_ROOT"
    else
        echo -e "${YELLOW}[警告] ${SUB_ROOT} 未通过安全检查，卸载未删除该路径。${RESET}" >&2
    fi
    rm -rf /etc/sing-box /etc/argo_vmess.conf /etc/rr-nexus /etc/rr-naive /etc/rr-cloudflared \
        /etc/rr-update /var/lib/rr-nexus /var/lib/rr-update /var/lib/rr-backup /var/www/rr-nexus-certbot \
        "$RR_LIB_DIR" /usr/local/bin/rr /usr/local/bin/sing-box /var/log/auto_update_sub.log
    rm -f /etc/sysctl.d/99-argo-rr.conf "$ARGO_PID_FILE" "$ARGO_LOG_FILE" \
        /tmp/sub_server.pid /tmp/sub_server.bind /tmp/argo_rr_cloudflared.pid /tmp/argo.log
    echo -e "${GREEN}清理完毕，欢迎随时再次使用 RR-vps！${RESET}"
    echo -e "${CYAN}项目地址 / Project:${RESET} ${project_url}"
    echo -e "${YELLOW}重新安装 / Reinstall:${RESET}"
    echo "bash <(curl -fsSL ${reinstall_url})"
    echo ""
    exit 0
}

# ==========================================
# 13. 安装主流程
# ==========================================
select_initial_protocols() {
    INSTALL_VM_ENABLED=false
    INSTALL_VM_TLS_ENABLED=false
    INSTALL_ARGO_SELECTED=false
    INSTALL_VL_ENABLED=false
    INSTALL_HY2_ENABLED=false
    INSTALL_TU5_ENABLED=false
    INSTALL_AN_ENABLED=false
    # NAIVE-SUPPORT
    INSTALL_NAIVE_ENABLED=false
    INSTALL_ANY_PROTOCOL=false

    local selection_input=""
    local vm_tls_selected=false
    local argo_selected=false
    local invalid=false
    local -a selections=()
    local item=""

    while true; do
        clear
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}                   RR-vps 首次安装 · 协议多选${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " 请选择本次需要安装的节点协议，可多选，例如：${GREEN}1,2,4${RESET}"
        echo -e " 直接回车不会安装任何协议；Cloudflared 只会在选择 Argo 后安装。"
        echo ""
        echo -e "  ${PURPLE}1.${RESET} VLESS Reality Vision   ${CYAN}TCP直连 / 优化线路推荐${RESET}"
        echo -e "  ${PURPLE}2.${RESET} Hysteria2              ${CYAN}UDP高速 / 支持端口跳跃${RESET}"
        echo -e "  ${PURPLE}3.${RESET} TUIC v5                ${CYAN}UDP低延迟${RESET}"
        echo -e "  ${PURPLE}4.${RESET} AnyTLS                 ${CYAN}TCP稳定 / UDP受限线路${RESET}"
        echo -e "  ${PURPLE}5.${RESET} VMess-WS + TLS         ${CYAN}公网直连，不经过 Argo${RESET}"
        echo -e "  ${PURPLE}6.${RESET} VMess-WS + Argo        ${YELLOW}按需安装 Cloudflared${RESET}"
        echo -e "  ${PURPLE}7.${RESET} 安装全部协议           ${CYAN}随后选择 VMess 工作模式${RESET}"
        # NAIVE-SUPPORT
        echo -e "  ${PURPLE}8.${RESET} NaiveProxy H2/H3        ${CYAN}TCP+QUIC 双栈 / 需域名真证书${RESET}"
        echo -e "  ${PURPLE}0.${RESET} 仅初始化管理框架       ${CYAN}以后在选项 9 开启协议${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请输入协议编号: " selection_input
        if [ -z "$selection_input" ]; then
            echo -e "${YELLOW}未选择协议。请输入 0 仅初始化，或输入需要安装的协议编号。${RESET}"
            sleep 2
            continue
        fi

        selection_input="${selection_input//，/,}"
        selection_input="${selection_input//,/ }"
        read -r -a selections <<< "$selection_input"
        invalid=false
        vm_tls_selected=false
        argo_selected=false
        INSTALL_VM_ENABLED=false
        INSTALL_VM_TLS_ENABLED=false
        INSTALL_ARGO_SELECTED=false
        INSTALL_VL_ENABLED=false
        INSTALL_HY2_ENABLED=false
        INSTALL_TU5_ENABLED=false
        INSTALL_AN_ENABLED=false
        # NAIVE-SUPPORT
        INSTALL_NAIVE_ENABLED=false

        if [ "${#selections[@]}" -eq 0 ]; then
            invalid=true
        fi
        for item in "${selections[@]}"; do
            case "$item" in
                0)
                    if [ "${#selections[@]}" -ne 1 ]; then invalid=true; fi
                    ;;
                1) INSTALL_VL_ENABLED=true ;;
                2) INSTALL_HY2_ENABLED=true ;;
                3) INSTALL_TU5_ENABLED=true ;;
                4) INSTALL_AN_ENABLED=true ;;
                # NAIVE-SUPPORT
                8) INSTALL_NAIVE_ENABLED=true ;;
                5) vm_tls_selected=true ;;
                6) argo_selected=true ;;
                7)
                    if [ "${#selections[@]}" -ne 1 ]; then invalid=true; fi
                    ;;
                *) invalid=true ;;
            esac
        done
        if [ "$vm_tls_selected" = true ] && [ "$argo_selected" = true ]; then
            echo -e "${RED}VMess TLS 直连与 Argo 共用同一个 VMess 入站，不能同时选择 5 和 6。${RESET}"
            invalid=true
        fi
        if [ "$invalid" = true ]; then
            echo -e "${RED}协议选择无效，请按示例重新输入。${RESET}"
            sleep 2
            continue
        fi

        if [ "${selections[0]}" = "7" ]; then
            INSTALL_VL_ENABLED=true
            INSTALL_HY2_ENABLED=true
            INSTALL_TU5_ENABLED=true
            INSTALL_AN_ENABLED=true
            INSTALL_NAIVE_ENABLED=true
            while true; do
                echo ""
                echo -e "全部协议中的 VMess 请选择一种工作模式："
                echo -e "  1. ${GREEN}TLS 公网直连${RESET}"
                echo -e "  2. ${CYAN}Cloudflare Argo${RESET}"
                read -p "请选择 [1-2，必须选择]: " item
                case "$item" in
                    1) vm_tls_selected=true; break ;;
                    2) argo_selected=true; break ;;
                    *) echo -e "${RED}请输入 1 或 2。${RESET}" ;;
                esac
            done
        fi

        if [ "$vm_tls_selected" = true ]; then
            INSTALL_VM_ENABLED=true
            INSTALL_VM_TLS_ENABLED=true
        elif [ "$argo_selected" = true ]; then
            INSTALL_VM_ENABLED=true
            INSTALL_VM_TLS_ENABLED=false
            INSTALL_ARGO_SELECTED=true
        fi

        if [ "$INSTALL_VM_ENABLED" = true ] || [ "$INSTALL_VL_ENABLED" = true ] || \
           [ "$INSTALL_HY2_ENABLED" = true ] || [ "$INSTALL_TU5_ENABLED" = true ] || \
           [ "$INSTALL_AN_ENABLED" = true ] || [ "$INSTALL_NAIVE_ENABLED" = true ]; then
            INSTALL_ANY_PROTOCOL=true
        fi
        return 0
    done
}

initial_port_available() {
    local candidate="$1"
    local transport="$2"
    local allocated=""
    is_valid_port "$candidate" || return 1

    if [ "$transport" = "tcp" ]; then
        for allocated in "${PORT:-0}" "${SUB_PORT:-0}" "${VL_PORT:-0}" "${AN_PORT:-0}"; do
            [ "$allocated" != "0" ] && [ "$candidate" = "$allocated" ] && return 1
        done
        if [ "${INSTALL_NAIVE_ENABLED:-false}" = true ] && [ "${NAIVE_MODE:-h2}" != h3 ] && \
           [ "${NAIVE_PORT:-0}" != 0 ] && [ "$candidate" = "$NAIVE_PORT" ]; then
            return 1
        fi
        tcp_port_in_use "$candidate" && return 1
    elif [ "$transport" = "udp" ]; then
        for allocated in "${HY2_PORT:-0}" "${TU5_PORT:-0}"; do
            [ "$allocated" != "0" ] && [ "$candidate" = "$allocated" ] && return 1
        done
        if [ "${INSTALL_NAIVE_ENABLED:-false}" = true ] && [ "${NAIVE_MODE:-h2}" != h2 ] && \
           [ "${NAIVE_PORT:-0}" != 0 ] && [ "$candidate" = "$NAIVE_PORT" ]; then
            return 1
        fi
        udp_port_in_use "$candidate" && return 1
    else
        return 1
    fi

    # The port is valid, not already allocated by this install, and not in use.
    # Without an explicit success status, the failed "port in use" probe above
    # becomes this function's return value and the random-port loop never exits.
    return 0
}

prompt_initial_port() {
    local output_var="$1"
    local label="$2"
    local transport="$3"
    local random_port=""
    local entered_port=""

    while true; do
        random_port=$((RANDOM % 39001 + 10000))
        initial_port_available "$random_port" "$transport" && break
    done
    while true; do
        read -p "请设置 ${label} 端口（${transport^^}，回车随机 ${random_port}）: " entered_port
        entered_port="${entered_port:-$random_port}"
        if initial_port_available "$entered_port" "$transport"; then
            printf -v "$output_var" '%s' "$entered_port"
            return 0
        fi
        echo -e "${RED}端口须在 1-65535、未被占用，并且不能与已选协议端口冲突。${RESET}"
    done
}

prompt_initial_naive_port() {
    local candidate=443 random_port="" entered_port=""
    while true; do
        if { [ "$NAIVE_MODE" = h3 ] || initial_port_available "$candidate" tcp; } && \
           { [ "$NAIVE_MODE" = h2 ] || initial_port_available "$candidate" udp; }; then
            break
        fi
        candidate=$((RANDOM % 39001 + 10000))
    done
    random_port="$candidate"
    while true; do
        read -r -p "请设置 NaiveProxy 端口（H2/H3 共用，回车 ${random_port}）: " entered_port
        entered_port="${entered_port:-$random_port}"
        if { [ "$NAIVE_MODE" = h3 ] || initial_port_available "$entered_port" tcp; } && \
           { [ "$NAIVE_MODE" = h2 ] || initial_port_available "$entered_port" udp; }; then
            NAIVE_PORT="$entered_port"
            return 0
        fi
        echo -e "${RED}端口与已选协议或系统进程冲突。${RESET}"
    done
}

prompt_initial_hy2_hop() {
    HY2_HOP_PORTS=""
    HY2_HOP_INTERVAL="30s"
    local enable_hop=""
    local hop_spec=""
    local hop_interval=""
    read -p "是否立即为 Hysteria2 启用 UDP 端口跳跃？[y/N]: " enable_hop
    case "$enable_hop" in
        y|Y)
            while true; do
                read -p "请输入跳跃范围（例如 20000:30000）: " hop_spec
                if is_valid_hop_spec "$hop_spec"; then
                    HY2_HOP_PORTS="$hop_spec"
                    break
                fi
                echo -e "${RED}范围无效，必须是 1-65535 内的 起始端口:结束端口。${RESET}"
            done
            read -p "请输入客户端跳跃间隔（5s-24h，回车 30s）: " hop_interval
            hop_interval="${hop_interval:-30s}"
            if is_valid_hop_interval "$hop_interval"; then
                HY2_HOP_INTERVAL="$hop_interval"
            else
                echo -e "${YELLOW}间隔格式无效，已使用 30s。${RESET}"
            fi
            ;;
    esac
}

install_main() {
    check_supported_os || return 1
    if [ -f "$CONFIG_FILE" ]; then
        load_config_with_defaults || return 1
        if [ "$INSTALL_COMPLETE" != "true" ]; then
            local incomplete_backup="${CONFIG_FILE}.incomplete.$(date +%Y%m%d%H%M%S)"
            if ! mv "$CONFIG_FILE" "$incomplete_backup"; then
                echo -e "${RED}[失败] 无法备份上次未完成安装的配置，已停止操作。${RESET}"
                return 1
            fi
            echo -e "${YELLOW}检测到上次首次安装未完成，将重新进入安装向导；旧输入已备份到 ${incomplete_backup}。${RESET}"
        fi
    fi
    if [ -f "$CONFIG_FILE" ]; then
        _install_repair_existing
        return
    fi

    select_initial_protocols || return 1
    install_deps || return 1
    if [ "$INSTALL_ARGO_SELECTED" = true ]; then
        install_cloudflared || return 1
    fi

    local USER_PORT=""
    PORT=0
    SUB_PORT=0
    VL_PORT=0
    HY2_PORT=0
    TU5_PORT=0
    AN_PORT=0
    NAIVE_PORT=0
    NAIVE_MODE=h2
    NAIVE_QUIC_CC=bbr
    HY2_HOP_PORTS=""
    HY2_HOP_INTERVAL="30s"
    TU5_HOP_PORTS=""

    if [ "$INSTALL_VM_ENABLED" = true ]; then
        if [ "$INSTALL_VM_TLS_ENABLED" = true ]; then
            prompt_initial_port PORT "VMess-WS + TLS" tcp || return 1
        else
            prompt_initial_port PORT "VMess/Argo 本地源站" tcp || return 1
        fi
    fi

    ARGO_EDGE_PORT=443
    if [ "$INSTALL_ARGO_SELECTED" = true ]; then
        read -p "Argo 客户端连接 Cloudflare 的边缘端口（不占本机；443/2053/2083/2087/2096/8443，回车443）: " USER_PORT
        [ -n "$USER_PORT" ] && ARGO_EDGE_PORT="$USER_PORT"
        while ! is_cloudflare_tls_port "$ARGO_EDGE_PORT"; do
            echo -e "${RED}请输入 Cloudflare 支持的 HTTPS 端口。${RESET}"
            read -p "请重新输入 Argo 边缘端口: " ARGO_EDGE_PORT
        done
    fi

    prompt_initial_port SUB_PORT "本地订阅服务" tcp || return 1
    if [ "$INSTALL_VL_ENABLED" = true ]; then prompt_initial_port VL_PORT "VLESS Reality Vision" tcp || return 1; fi
    if [ "$INSTALL_AN_ENABLED" = true ]; then prompt_initial_port AN_PORT "AnyTLS" tcp || return 1; fi
    # NAIVE-SUPPORT：NaiveProxy 需独立域名 + Let's Encrypt 真证书。
    if [ "$INSTALL_NAIVE_ENABLED" = true ]; then
        echo -e "${CYAN}Naive 传输：1) H2/TCP  2) H3/QUIC  3) H2+H3 双栈（推荐）${RESET}"
        read -r -p "请选择 [1-3，回车 3]: " USER_PORT
        case "$USER_PORT" in 1) NAIVE_MODE=h2 ;; 2) NAIVE_MODE=h3 ;; *) NAIVE_MODE=both ;; esac
        NAIVE_QUIC_CC=bbr
        prompt_initial_naive_port || return 1
        read -p "NaiveProxy 域名（必须已解析到本机，例如 naive.example.com）: " NAIVE_DOMAIN
        while [ -z "$NAIVE_DOMAIN" ] || ! is_valid_domain "$NAIVE_DOMAIN" 2>/dev/null; do
            [ -z "$NAIVE_DOMAIN" ] && echo -e "${RED}域名不能为空。${RESET}"
            read -p "请重新输入 NaiveProxy 域名: " NAIVE_DOMAIN
        done
        NAIVE_USER="np_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
        NAIVE_PASS="$(head -c 24 /dev/urandom | base64 | tr -d '\n/+= ' | head -c 20)"
        [ -n "$NAIVE_USER" ] || NAIVE_USER="np_user"
        [ -n "$NAIVE_PASS" ] || NAIVE_PASS="changeme"
    fi
    if [ "$INSTALL_HY2_ENABLED" = true ]; then prompt_initial_port HY2_PORT "Hysteria2" udp || return 1; fi
    if [ "$INSTALL_TU5_ENABLED" = true ]; then prompt_initial_port TU5_PORT "TUIC v5" udp || return 1; fi
    if [ "$INSTALL_HY2_ENABLED" = true ]; then prompt_initial_hy2_hop || return 1; fi
    SUB_PUBLIC_PORT_IPV4="$SUB_PORT"
    SUB_PUBLIC_PORT_IPV6="$SUB_PORT"

_install_prompt_identity || return 1

    mkdir -p /etc/sing-box
    umask 077
    local config_target="$CONFIG_FILE"
    local config_candidate=""
    local config_write_ok=true
    config_candidate=$(mktemp /etc/.argo_vmess.conf.XXXXXX) || return 1
    CONFIG_FILE="$config_candidate"
    : > "$CONFIG_FILE" || config_write_ok=false
    # 标记必须最先写入；后续任一步失败，重跑时都不会把半成品当成旧节点。
    safe_sed INSTALL_COMPLETE false || config_write_ok=false
    safe_sed PORT "$PORT" || config_write_ok=false
    safe_sed ARGO_EDGE_PORT "$ARGO_EDGE_PORT" || config_write_ok=false
    safe_sed SUB_PORT "$SUB_PORT" || config_write_ok=false
    safe_sed SUB_PUBLIC_PORT_IPV4 "$SUB_PUBLIC_PORT_IPV4" || config_write_ok=false
    safe_sed SUB_PUBLIC_PORT_IPV6 "$SUB_PUBLIC_PORT_IPV6" || config_write_ok=false
    safe_sed UUID "$UUID" || config_write_ok=false
    safe_sed CDN_IP "$CDN_IP" || config_write_ok=false
    safe_sed ARGO_DOMAIN "" || config_write_ok=false
    safe_sed TUNNEL_MODE "$tunnel_choice" || config_write_ok=false
    safe_sed VM_TLS_ENABLED "$INSTALL_VM_TLS_ENABLED" || config_write_ok=false
    safe_sed VM_PREVIOUS_PORT "" || config_write_ok=false
    safe_sed VL_ENABLED "$INSTALL_VL_ENABLED" || config_write_ok=false
    safe_sed VL_PORT "$VL_PORT" || config_write_ok=false
    safe_sed HY2_ENABLED "$INSTALL_HY2_ENABLED" || config_write_ok=false
    safe_sed HY2_PORT "$HY2_PORT" || config_write_ok=false
    safe_sed HY2_HOP_PORTS "$HY2_HOP_PORTS" || config_write_ok=false
    safe_sed HY2_HOP_INTERVAL "$HY2_HOP_INTERVAL" || config_write_ok=false
    safe_sed TU5_ENABLED "$INSTALL_TU5_ENABLED" || config_write_ok=false
    safe_sed TU5_PORT "$TU5_PORT" || config_write_ok=false
    safe_sed TU5_HOP_PORTS "$TU5_HOP_PORTS" || config_write_ok=false
    safe_sed AN_ENABLED "$INSTALL_AN_ENABLED" || config_write_ok=false
    safe_sed AN_PORT "$AN_PORT" || config_write_ok=false
    # NAIVE-SUPPORT
    safe_sed NAIVE_ENABLED "$INSTALL_NAIVE_ENABLED" || config_write_ok=false
    safe_sed NAIVE_PORT "${NAIVE_PORT:-443}" || config_write_ok=false
    safe_sed NAIVE_USER "${NAIVE_USER:-}" || config_write_ok=false
    safe_sed NAIVE_PASS "${NAIVE_PASS:-}" || config_write_ok=false
    safe_sed NAIVE_DOMAIN "${NAIVE_DOMAIN:-}" || config_write_ok=false
    safe_sed NAIVE_MODE "${NAIVE_MODE:-h2}" || config_write_ok=false
    safe_sed NAIVE_QUIC_CC "${NAIVE_QUIC_CC:-bbr}" || config_write_ok=false
    safe_sed CLASH_ENABLED false || config_write_ok=false
    safe_sed VM_ENABLED "$INSTALL_VM_ENABLED" || config_write_ok=false
    safe_sed ENTRY_IP_MODE auto || config_write_ok=false
    safe_sed OUTBOUND_IP_MODE auto || config_write_ok=false
    safe_sed ENTRY_IPV4_ADDRESS "" || config_write_ok=false
    safe_sed ENTRY_IPV6_ADDRESS "" || config_write_ok=false
    safe_sed PRIVATE_KEY "" || config_write_ok=false
    safe_sed PUBLIC_KEY "" || config_write_ok=false
    safe_sed SHORT_ID "" || config_write_ok=false
    safe_sed CERT_SHA256 "" || config_write_ok=false
    safe_sed SINGBOX_AUTO_RESTART true || config_write_ok=false
    safe_sed CONFIG_VERSION "$CONFIG_SCHEMA_VERSION" || config_write_ok=false
    if [ "$config_write_ok" != true ] || ! chmod 600 "$config_candidate" || \
       ! mv -f "$config_candidate" "$config_target"; then
        CONFIG_FILE="$config_target"
        rm -f "$config_candidate"
        echo -e "${RED}[失败] 无法原子写入首次配置，系统未留下半成品。${RESET}"
        return 1
    fi
    CONFIG_FILE="$config_target"

    # LXD/NAT66 中 curl 检测到的是宿主机出口地址；必须先取得面板绑定地址，
    # 否则纯 IPv6 容器会在 Argo 域名写入订阅时因没有可用入站地址而失败。
    load_config_with_defaults || return 1
    detect_public_ips
    if [ "$IPV6_NAT66_DETECTED" = true ]; then
        local install_public_ipv6=""
        local use_ipv6_now=""
        local nat_ipv6_saved=false
        echo -e "\n${YELLOW}检测到 LXD/NAT66 容器：${RESET}"
        echo -e " 容器内网 IPv6：${CYAN}${LOCAL_IPV6_ULA}${RESET}"
        echo -e " 宿主机出口 IPv6：${CYAN}${EGRESS_IPV6:-未检测到}${RESET}（不能写入节点）"
        read -p "请输入服务商面板绑定的公网 IPv6（回车稍后在 12→6 设置）: " install_public_ipv6
        install_public_ipv6="${install_public_ipv6#[}"
        install_public_ipv6="${install_public_ipv6%]}"
        if [ -n "$install_public_ipv6" ]; then
            if is_global_ip_version "$install_public_ipv6" 6; then
                safe_sed ENTRY_IPV6_ADDRESS "$install_public_ipv6" || return 1
                nat_ipv6_saved=true
                read -p "立即让直连节点和订阅使用这个 IPv6？[Y/n]: " use_ipv6_now
                case "$use_ipv6_now" in
                    n|N) ;;
                    *) safe_sed ENTRY_IP_MODE ipv6 || return 1 ;;
                esac
            else
                echo -e "${YELLOW}[提示] 地址无效；纯 IPv6 服务器需重跑安装并填写正确地址。${RESET}"
            fi
        fi
        if [ -z "$PUBLIC_IPV4" ] && [ "$nat_ipv6_saved" != true ]; then
            echo -e "${RED}[停止] 当前没有 IPv4 入站，也没有有效的面板公网 IPv6，无法生成可连接的节点。${RESET}"
            return 1
        fi
    fi

    if [ "$INSTALL_ANY_PROTOCOL" = true ]; then
        ensure_singbox_core || { echo -e "${RED}内核安装失败，安装中止。${RESET}"; return 1; }
        generate_certs_and_keys || { echo -e "${RED}证书/密钥生成失败，安装中止${RESET}"; return 1; }
        if [ "$INSTALL_NAIVE_ENABLED" = true ]; then
            ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL" || {
                echo -e "${RED}NaiveProxy 真证书申请失败，安装已停止；其他协议配置保留为未完成状态。${RESET}"
                return 1
            }
        fi
        build_singbox_config || return 1
        setup_systemd || return 1
    fi
    if [ "$INSTALL_ARGO_SELECTED" = true ]; then
        echo -e "\n${YELLOW}正在拉起 Argo 隧道...${RESET}"
        if [ "$tunnel_choice" = "2" ]; then
        local CF_TOKEN=""
        read -r -s -p "请输入 Cloudflare Tunnel Token（输入不回显）: " CF_TOKEN
        echo
        read -p "请输入该固定隧道绑定的自定义域名 (如 test.com): " ARGO_DOMAIN
        if [ -z "$CF_TOKEN" ] || ! is_valid_host_or_ip "$ARGO_DOMAIN"; then
            echo -e "${RED}Token 或固定隧道域名无效，安装中止。${RESET}"
            return 1
        fi
        stop_quick_argo_tunnel
        if systemctl cat cloudflared >/dev/null 2>&1; then
            echo -e "${YELLOW}检测到系统已有 cloudflared 服务；替换会影响该服务当前承载的隧道。${RESET}"
            read -p "确认由本脚本替换现有 cloudflared 服务？请输入 REPLACE: " replace_cf
            if [ "$replace_cf" != "REPLACE" ]; then
                echo -e "${RED}未获得替换确认，安装已安全中止，现有 cloudflared 未改动。${RESET}"
                return 1
            fi
            cloudflared service uninstall >/dev/null 2>&1 || return 1
        fi
        install -d -m 700 "$(dirname "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}")" || return 1
        (umask 077; printf '%s\n' "$CF_TOKEN" > "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}.tmp") || return 1
        mv -f "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}.tmp" \
            "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" || return 1
        if ! cloudflared service install "$CF_TOKEN" >/dev/null 2>&1; then
            rm -f "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
            echo -e "${RED}固定隧道服务安装失败。${RESET}"
            return 1
        fi
        systemctl enable --now cloudflared >/dev/null 2>&1 || return 1
        safe_sed ARGO_DOMAIN "$ARGO_DOMAIN" || return 1
        echo -e "${YELLOW}请确认 Cloudflare 面板服务地址为 http://localhost:${PORT}。${RESET}"
        else
            if ! launch_quick_argo_tunnel; then
                echo -e "${RED}Argo 临时隧道启动失败，安装中止。${RESET}"
                return 1
            fi
        fi
    fi

    open_firewall
    [ "$INSTALL_VL_ENABLED" = true ] && open_protocol_firewall "$VL_PORT" tcp
    [ "$INSTALL_HY2_ENABLED" = true ] && open_protocol_firewall "$HY2_PORT" udp
    [ "$INSTALL_TU5_ENABLED" = true ] && open_protocol_firewall "$TU5_PORT" udp
    [ "$INSTALL_AN_ENABLED" = true ] && open_protocol_firewall "$AN_PORT" tcp
    if [ "$INSTALL_NAIVE_ENABLED" = true ]; then
        [ "$NAIVE_MODE" != h3 ] && open_protocol_firewall "$NAIVE_PORT" tcp
        [ "$NAIVE_MODE" != h2 ] && open_protocol_firewall "$NAIVE_PORT" udp
    fi
    if [ "$INSTALL_HY2_ENABLED" = true ] && [ -n "$HY2_HOP_PORTS" ]; then
        if ! install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS"; then
            echo -e "${RED}Hysteria2 端口跳跃规则安装失败，安装已停止。${RESET}"
            return 1
        fi
    fi
    generate_node_and_sub || return 1
    safe_sed INSTALL_COMPLETE true || return 1
    if [ "$INSTALL_ANY_PROTOCOL" = true ]; then
        setup_health_monitor >/dev/null 2>&1 || \
            echo -e "${YELLOW}[提示] 定时健康检查未能启用，节点本身已正常安装。${RESET}"
    fi

    if [ "$INSTALL_ANY_PROTOCOL" = true ]; then
        echo -e "${GREEN}安装完成！仅已选择的协议被启用，节点与订阅已经同步生成。${RESET}"
    else
        echo -e "${GREEN}管理框架初始化完成，当前没有开启任何节点协议。${RESET}"
    fi
    [ "$INSTALL_ARGO_SELECTED" = true ] || \
        echo -e "${CYAN}本次未选择 Argo，因此未安装 Cloudflared，也没有占用 Argo 本地端口。${RESET}"
    echo -e "${YELLOW}以后可在主菜单选择 9 随时增加、关闭或修改协议。${RESET}"
    sleep 1
    show_info
}

# ==========================================
# Sing-box 控制面板
