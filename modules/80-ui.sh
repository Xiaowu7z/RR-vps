# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 6. 端口总览
# ==========================================
show_ports() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 1 进行安装！${RESET}"
        sleep 2
        return
    fi
    load_config_with_defaults || return 1

    echo ""
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${WHITE}  协议                    端口        传输层   防火墙放行命令${RESET}"
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${RESET}"

    # Vmess：关闭时不显示占位端口；Argo 模式仅为本地源站，不需要公网放行。
    if [ "$VM_ENABLED" = "false" ]; then
        printf "  %-22s %-10s %-7s %s\n" "Vmess-ws" "---" "TCP" "(未开启)"
    elif [ "$VM_TLS_ENABLED" = "true" ]; then
        printf "  %-22s %-10s %-7s iptables -I INPUT -p tcp --dport %s -j ACCEPT\n" "Vmess-ws (TLS直连)" "$PORT" "TCP" "$PORT"
    else
        printf "  %-22s %-10s %-7s %s\n" "Vmess/Argo本地源站" "$PORT" "TCP" "(127.0.0.1，无需放行)"
        printf "  %-22s %-10s %-7s %s\n" "Argo边缘地址" "$ARGO_EDGE_PORT" "TCP" "(Cloudflare 端口，不占本机)"
    fi

    # VL
    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        printf "  %-22s %-10s %-7s iptables -I INPUT -p tcp --dport %s -j ACCEPT\n" "Vless-reality" "$VL_PORT" "TCP" "$VL_PORT"
    else
        printf "  %-22s %-10s %-7s %s\n" "Vless-reality" "---" "TCP" "(未开启)"
    fi

    # HY2
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        local hy2_hop=$(get_hop_ports "$HY2_PORT")
        if [ -n "$hy2_hop" ]; then
            printf "  %-22s %-10s %-7s iptables -I INPUT -p udp --dport %s -j ACCEPT\n" "Hysteria2" "$HY2_PORT" "UDP" "$HY2_PORT"
            printf "  %-22s %-10s %-7s %s\n" "  ↳ 跳跃端口" "$hy2_hop" "UDP" "(防火墙重定向 → $HY2_PORT)"
        else
            printf "  %-22s %-10s %-7s iptables -I INPUT -p udp --dport %s -j ACCEPT\n" "Hysteria2" "$HY2_PORT" "UDP" "$HY2_PORT"
        fi
    else
        printf "  %-22s %-10s %-7s %s\n" "Hysteria2" "---" "UDP" "(未开启)"
    fi

    # TU5
    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        local tu5_hop=$(get_hop_ports "$TU5_PORT")
        if [ -n "$tu5_hop" ]; then
            printf "  %-22s %-10s %-7s iptables -I INPUT -p udp --dport %s -j ACCEPT\n" "Tuic5" "$TU5_PORT" "UDP" "$TU5_PORT"
            printf "  %-22s %-10s %-7s %s\n" "  ↳ 跳跃端口" "$tu5_hop" "UDP" "(防火墙重定向 → $TU5_PORT)"
        else
            printf "  %-22s %-10s %-7s iptables -I INPUT -p udp --dport %s -j ACCEPT\n" "Tuic5" "$TU5_PORT" "UDP" "$TU5_PORT"
        fi
    else
        printf "  %-22s %-10s %-7s %s\n" "Tuic5" "---" "UDP" "(未开启)"
    fi

    # AN
    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        printf "  %-22s %-10s %-7s iptables -I INPUT -p tcp --dport %s -j ACCEPT\n" "Anytls" "$AN_PORT" "TCP" "$AN_PORT"
    else
        printf "  %-22s %-10s %-7s %s\n" "Anytls" "---" "TCP" "(未开启)"
    fi

    if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
        # 公网 HTTPS 才需要开放本机监听；公网端口可能是 NAT 映射端口。
        printf "  %-22s %-10s %-7s iptables -I INPUT -p tcp --dport %s -j ACCEPT\n" "订阅 HTTPS" "$SUB_PORT" "TCP" "$SUB_PORT"
        if [ "$SUB_PUBLIC_PORT_IPV4" != "$SUB_PORT" ]; then
            printf "  %-22s %-10s %-7s %s\n" "订阅地址(IPv4)" "$SUB_PUBLIC_PORT_IPV4" "TCP" "(NAT 映射 → 本地 $SUB_PORT)"
        fi
        if [ "$SUB_PUBLIC_PORT_IPV6" != "$SUB_PORT" ]; then
            printf "  %-22s %-10s %-7s %s\n" "订阅地址(IPv6)" "$SUB_PUBLIC_PORT_IPV6" "TCP" "(公网 → 本地 $SUB_PORT)"
        fi
    else
        printf "  %-22s %-10s %-7s %s\n" "订阅服务" "$SUB_PORT" "TCP" "(仅 127.0.0.1，不开放防火墙)"
    fi

    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${RESET}"
    echo -e "${WHITE}  当前系统实际监听（含占用进程）${RESET}"
    echo -e "${CYAN}──────────────────────────────────────────────────────────────────${RESET}"
    if command -v ss >/dev/null 2>&1; then
        ss -H -lntup 2>/dev/null | sort -k1,1 -k5,5V || true
    else
        echo "  ss 命令不可用"
    fi
    echo -e "${CYAN}══════════════════════════════════════════════════════════════════${RESET}"
    echo ""
    read -p "按回车键返回主菜单..."
}

# ==========================================
# 7. 显示节点信息
# ==========================================
render_terminal_qr() {
    local payload="${1:-}"
    local label="${2:-二维码}"
    [ -n "$payload" ] || return 1
    command -v qrencode >/dev/null 2>&1 || return 0

    echo -e "${YELLOW}${label}（可截图后从客户端相册导入）：${RESET}"
    # M 级纠错 + QR 标准 4 模块静区提升 SSH 截图/相册识别率。显式传 --，
    # 防止任何分享内容被 qrencode 当作命令行参数解析。
    if ! qrencode -t ANSIUTF8 -l M -m 4 -- "$payload" 2>/dev/null; then
        echo -e "${YELLOW}[警告] ${label}生成失败，请直接复制上方链接。${RESET}" >&2
        return 1
    fi
    return 0
}

show_info() {
    clear
    load_config_with_defaults || return 1
    if ! generate_node_and_sub; then
        echo -e "${RED}节点与订阅生成失败，原有配置未改动。${RESET}"
        read -p "按回车键返回主菜单..."
        return
    fi
    local SERVER_IP="$ENTRY_IP_URI"
    local raw_sub_url=""
    local encoded_sub_url=""
    local client_config_url=""
    local short_sub_url=""
    raw_sub_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" raw) || return 1
    encoded_sub_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" encoded) || return 1
    client_config_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client) || return 1
    sub_v2rayn_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client-v2rayn.txt) || true
    sub_v2rayng_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client-v2rayng.txt) || true
    sub_sr_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client-sr.txt) || true
    sub_nekobox_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client-nekobox.txt) || true
    sub_singbox_vl_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" client-vl.json) || true
    short_sub_url="$encoded_sub_url"

    echo -e "${CYAN}=================================================================================${RESET}"
    echo -e "${GREEN}                    当前节点信息与订阅链接${RESET}"
    echo -e "${CYAN}=================================================================================${RESET}"
    if [ "$VM_ENABLED" = "false" ]; then
        echo -e " Vmess节点 : ${RED}未开启${RESET} | 订阅: ${YELLOW}$SUB_PORT → $SUB_URL_PORT${RESET}"
    else
        echo -e " Vmess本地端口: ${YELLOW}$PORT${RESET} | Argo边缘端口: ${YELLOW}$ARGO_EDGE_PORT${RESET} | 订阅: ${YELLOW}$SUB_PORT → $SUB_URL_PORT${RESET}"
        if [ "$VM_TLS_ENABLED" = "true" ]; then
            echo -e " Vmess模式: ${GREEN}TLS直连${RESET}"
        else
            echo -e " 固定节点: ${GREEN}$CDN_IP${RESET}"
            echo -e " Vmess模式: ${CYAN}Argo隧道${RESET}"
            echo -e " Argo域名: ${CYAN}$ARGO_DOMAIN${RESET}"
        fi
    fi
    echo -e " 用户ID  : $UUID"
    echo -e " 入口模式: ${CYAN}$(entry_mode_label "$ENTRY_IP_MODE")${RESET} (${ENTRY_IP_RAW}，${ENTRY_IP_SOURCE})"
    echo -e " 出口模式: ${CYAN}$(outbound_mode_label "$OUTBOUND_IP_MODE")${RESET}"
    echo ""
    echo -e "${CYAN}--- 协议状态总览 ---${RESET}"
    check_protocol_status
    echo -e " Vmess-ws/Argo : $VM_STATUS"
    [ "$VL_ENABLED"  = "true" ] && echo -e " Vless-reality : $VL_STATUS"
    [ "$HY2_ENABLED" = "true" ] && echo -e " Hysteria2     : $HY2_STATUS"
    [ "$TU5_ENABLED" = "true" ] && echo -e " Tuic5         : $TU5_STATUS"
    [ "$AN_ENABLED"  = "true" ] && echo -e " Anytls        : $AN_STATUS"
    # NAIVE-SUPPORT
    [ "$NAIVE_ENABLED" = "true" ] && echo -e " NaiveProxy    : $NAIVE_STATUS"

    echo ""
    echo -e "${CYAN}--- 订阅地址（按客户端选择对应地址） ---${RESET}"
    if [ "${SUB_ACCESS_MODE:-local}" = local ]; then
        echo -e "${YELLOW}[本地安全模式] 以下 127.0.0.1 地址只能经 SSH 端口转发使用：${RESET}"
        echo -e "${WHITE}ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@${ENTRY_IP_RAW}${RESET}"
        echo -e "${YELLOW}保持隧道连接后，再在同一台电脑或手机客户端添加订阅。服务器不会公开明文订阅端口。${RESET}"
    else
        echo -e "${GREEN}[HTTPS] 订阅由可信域名 ${SUB_DOMAIN} 加密提供；不要忽略证书错误。${RESET}"
    fi
    local clash_sub_url=""
    if [ "$CLASH_ENABLED" = "true" ]; then
        clash_sub_url=$(build_short_subscription_url "$SERVER_IP" "$SUB_URL_PORT" "$UUID" clash) || true
    fi
    if [ -n "$clash_sub_url" ]; then
        printf ' 1. Clash Meta / Clash Verge / FlClash : \033[1;36m%s\033[0m\n' "$clash_sub_url"
    else
        echo -e " 1. Clash Meta / Clash Verge / FlClash : ${YELLOW}需先在协议菜单开启 Clash Meta 订阅${RESET}"
    fi
    printf ' 2. v2rayN (Windows, 全协议) : \033[1;36m%s\033[0m\n' "$sub_v2rayn_url"
    printf ' 3. v2rayNG (安卓, 全协议) : \033[1;36m%s\033[0m\n' "$sub_v2rayng_url"
    printf ' 4. Shadowrocket (iOS, 全协议) : \033[1;36m%s\033[0m\n' "$sub_sr_url"
    printf ' 5. NekoBox (全协议) : \033[1;36m%s\033[0m\n' "$sub_nekobox_url"
    printf ' 6. sing-box 官方 (SFA/SFI/SFW, 单独VL-Reality) : \033[1;36m%s\033[0m\n' "$sub_singbox_vl_url"
    printf ' 7. 手动复制（通用原文）: \033[1;36m%s\033[0m\n' "$raw_sub_url"
    printf ' 8. 通用订阅（全协议, 兼容旧客户端）: \033[1;36m%s\033[0m\n' "$encoded_sub_url"
    echo -e "${YELLOW}以上均为手机 SSH 可复制短地址；原 UUID 长地址继续保留兼容，但不再显示。${RESET}"
    if command -v qrencode >/dev/null 2>&1; then
        render_terminal_qr "$short_sub_url" "通用 Base64 订阅二维码" || true
    fi
    echo ""
    echo -e "${CYAN}--- 各协议独立节点链接 ---${RESET}"

    local sub_content=$(cat "${SUB_ROOT}/${UUID}/jhsub.txt" 2>/dev/null)
    if [ -n "$sub_content" ]; then
        echo "$sub_content" | while IFS= read -r line; do
            if [ -n "$line" ]; then
                echo ""
                echo -e "${GREEN}$line${RESET}"
                if command -v qrencode >/dev/null 2>&1; then
                    local qr_protocol="节点"
                    case "$line" in
                        vmess://*) qr_protocol="VMess 节点" ;;
                        vless://*) qr_protocol="VLESS Reality 节点" ;;
                        hysteria2://*) qr_protocol="Hysteria2 节点" ;;
                        tuic://*) qr_protocol="TUIC 节点" ;;
                        anytls://*) qr_protocol="AnyTLS 节点" ;;
                        naive+https://*) qr_protocol="NaiveProxy H2 节点" ;;
                        naive+quic://*) qr_protocol="NaiveProxy H3 节点" ;;
                    esac
                    echo ""
                    render_terminal_qr "$line" "$qr_protocol" || true
                fi
            fi
        done
    fi
    echo ""
    echo -e "${CYAN}=================================================================================${RESET}"
    read -p "按回车键返回主菜单..."
}

# ==========================================
# 8. 更换 CDN
# ==========================================
change_cdn() {
    load_config_with_defaults || return 1
    echo -e "\n=================================================="
    echo -e "当前优选 IP/域名: ${YELLOW}$CDN_IP${RESET}"
    echo -e "=================================================="
    echo -e "请选择新的 优选IP/域名："
    echo -e "  1. cloudflare-ech.com"
    echo -e "  2. www.visa.com.sg"
    echo -e "  3. www.wto.org"
    echo -e "  4. www.web.com"
    echo -e "  5. 手动输入"
    echo -e "  0. 返回主菜单"
    echo -e "=================================================="
    read -p "请输入选项或直接粘贴优选域名: " cdn_choice

    local NEW_CDN=""
    case "$cdn_choice" in
        0) return ;;
        1) NEW_CDN="cloudflare-ech.com" ;;
        2) NEW_CDN="www.visa.com.sg" ;;
        3) NEW_CDN="www.wto.org" ;;
        4) NEW_CDN="www.web.com" ;;
        5) read -p "请输入自定义地址: " NEW_CDN ;;
        *) NEW_CDN="$cdn_choice" ;;
    esac

    if [ -n "$NEW_CDN" ]; then
        NEW_CDN=$(printf '%s' "$NEW_CDN" | tr -d '[:space:]')
        if ! is_valid_host_or_ip "$NEW_CDN"; then
            echo -e "${RED}[拒绝变更] 请输入有效的 IP 或域名。${RESET}"
            sleep 2
            return
        fi
        apply_config_transaction "更换优选地址为 ${NEW_CDN}" "CDN_IP" "$NEW_CDN"
        sleep 2
    fi
}

# ==========================================
# 9. 刷新 Argo 隧道域名
# ==========================================
refresh_argo() {
    load_config_with_defaults || return 1
    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
        echo -e "${YELLOW}当前为固定隧道模式，无需刷新。${RESET}"
        sleep 2
        return
    fi
    if [ "$VM_ENABLED" = "false" ] || [ "$VM_TLS_ENABLED" = "true" ]; then
        echo -e "${YELLOW}当前 Vmess/Argo 未启用，或正在使用 TLS 直连模式。${RESET}"
        sleep 2
        return
    fi

    echo -e "${YELLOW}正在并行建立新临时隧道；成功前旧隧道继续承载流量...${RESET}"
    launch_quick_argo_tunnel
    sleep 2
}

# ==========================================
# 10. 自动优选更新订阅
