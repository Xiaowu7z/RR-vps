# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
toggle_argo() {
    load_config_with_defaults || return 1
    clear
    if [ "$VM_ENABLED" = "false" ]; then
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "Argo/Vmess 节点 - 当前状态: ${RED}已关闭${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 开启 Argo/Vmess 节点"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub
        case "$sub" in
            1)
                local argo_port="$PORT"
                if ! ensure_singbox_core; then
                    echo -e "${RED}Sing-box 内核不可用，Argo/Vmess 未开启。${RESET}"
                    sleep 2
                    return 1
                fi
                if ! is_valid_port "$argo_port"; then
                    read -p "请输入 Vmess/Argo 本地源站端口（回车随机）: " argo_port
                    [ -z "$argo_port" ] && argo_port=$(gen_random_port tcp)
                    if ! validate_node_port "$argo_port" tcp PORT 0; then
                        sleep 2
                        return
                    fi
                fi
                if ! install_cloudflared; then
                    echo -e "${RED}Cloudflared 安装失败，Argo/Vmess 未开启。${RESET}"
                    sleep 2
                    return
                fi
                if apply_config_transaction "开启 Argo/Vmess 节点" \
                    "PORT" "$argo_port" "VM_TLS_ENABLED" "false" "VM_ENABLED" "true"; then
                    if ! ensure_node_service_running; then
                        apply_config_transaction "回滚未启动的 Argo/Vmess" "VM_ENABLED" "false" >/dev/null 2>&1 || true
                        echo -e "${RED}[失败] Sing-box 服务未能启动，Argo/Vmess 已回滚为关闭。${RESET}"
                        sleep 2
                        return 1
                    fi
                    start_argo_tunnel || echo -e "${RED}[警告] Vmess 已开启，但 Argo 隧道暂未连上。${RESET}"
                fi
                sleep 2
                ;;
            0) return ;;
        esac
    else
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "Argo/Vmess 节点 - 当前状态: ${GREEN}已开启${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 关闭 Argo/Vmess 节点 (保留 VL/HY2/TU5/AN)"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub
        case "$sub" in
            1)
                if apply_config_transaction "关闭 Argo/Vmess 节点" "VM_ENABLED" "false"; then
                    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
                        systemctl stop cloudflared >/dev/null 2>&1 || true
                    else
                        stop_quick_argo_tunnel
                    fi
                    # 依赖联动：关闭 Argo 后清理优选 CNAME 残留（重开时由 worker 重新抓取）
                    rm -f /tmp/sub_server/preferred_cnames.txt 2>/dev/null || true
                fi
                sleep 2
                ;;
            0) return ;;
        esac
    fi
}

# ==========================================
# 进程存活状态检测函数
# ==========================================
check_status() {
    if managed_singbox_running; then
        SB_STATUS="${GREEN}运行中${RESET}"
        if [ "${SB_ORPHAN_DETECTED:-false}" = "true" ]; then
            SB_STATUS="${GREEN}运行中${RESET}（${YELLOW}发现脱离 systemd 的孤立进程，未清理${RESET}）"
        fi
    elif [ "${SB_CORE_MISSING:-false}" = "true" ]; then
        SB_STATUS="${RED}未运行（内核缺失，自动重装失败，详见 /var/log/rr-health.log）${RESET}"
    else
        SB_STATUS="${RED}未运行${RESET}"
    fi

    if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
        AUTO_STATUS="${GREEN}开启${RESET}"
    else
        AUTO_STATUS="${RED}关闭${RESET}"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        if ! load_config_with_defaults; then
            CF_STATUS="${RED}配置错误${RESET}"
            IP_ENTRY_STATUS="配置错误"
            IP_OUTBOUND_STATUS="配置错误"
            return 1
        fi
        if [ "$VM_ENABLED" = "false" ] || [ "$VM_TLS_ENABLED" = "true" ]; then
            CF_STATUS="${CYAN}无需运行${RESET}"
        elif expected_argo_tunnel_running; then
            CF_STATUS="${GREEN}运行中${RESET}"
        else
            CF_STATUS="${RED}未运行${RESET}"
        fi
        IP_ENTRY_STATUS=$(entry_mode_label "$ENTRY_IP_MODE")
        IP_OUTBOUND_STATUS=$(outbound_mode_label "$OUTBOUND_IP_MODE")
    else
        CF_STATUS="${RED}未配置${RESET}"
        IP_ENTRY_STATUS="未配置"
        IP_OUTBOUND_STATUS="未配置"
    fi
}

# ==========================================
# 协议状态检测
# ==========================================
check_protocol_status() {
    load_config_with_defaults || return 1

    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        VL_STATUS="${GREEN}已开启 (${VL_PORT} TCP)${RESET}"
    else
        VL_STATUS="${RED}未开启${RESET}"
    fi

    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        HY2_STATUS="${GREEN}已开启 (${HY2_PORT} UDP)${RESET}"
    else
        HY2_STATUS="${RED}未开启${RESET}"
    fi

    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        TU5_STATUS="${GREEN}已开启 (${TU5_PORT} UDP)${RESET}"
    else
        TU5_STATUS="${RED}未开启${RESET}"
    fi

    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        AN_STATUS="${GREEN}已开启 (${AN_PORT} TCP)${RESET}"
    else
        AN_STATUS="${RED}未开启${RESET}"
    fi

    # NAIVE-SUPPORT
    if [ "$NAIVE_ENABLED" = "true" ] && [ -n "$NAIVE_PORT" ] && [ "$NAIVE_PORT" != "0" ]; then
        if [ -f /etc/rr-naive/fullchain.pem ]; then
            NAIVE_STATUS="${GREEN}已开启 (${NAIVE_PORT} TCP)${RESET}"
        else
            NAIVE_STATUS="${YELLOW}已配置·证书缺失${RESET}"
        fi
    else
        NAIVE_STATUS="${RED}未开启${RESET}"
    fi

    if [ "$CLASH_ENABLED" = "true" ]; then
        CLASH_STATUS="${GREEN}已开启${RESET}"
    else
        CLASH_STATUS="${RED}未开启${RESET}"
    fi

    if [ "$VM_ENABLED" = "false" ]; then
        VM_STATUS="${RED}已关闭${RESET}"
    else
        VM_STATUS="${GREEN}已开启${RESET}"
    fi
}

# ==========================================
# 脚本更新检测 (SHA256 比对)
