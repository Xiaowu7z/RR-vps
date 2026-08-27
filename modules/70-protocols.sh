# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 5. 协议管理子菜单
# ==========================================
protocol_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 1 进行完整安装！${RESET}"
        sleep 2
        return
    fi

    while true; do
        clear
        check_protocol_status || return 1
        load_config_with_defaults || return 1
        HB_DISPLAY="${RED}已关闭${RESET}"
        [ "$HB_ENABLED" = "true" ] && HB_DISPLAY="${GREEN}已开启 ${HB_INTERVAL}s${RESET}"

        if [ "$VM_ENABLED" = "false" ]; then
            VM_TLS_DISPLAY="${RED}未开启${RESET}"
        elif [ "$VM_TLS_ENABLED" = "true" ]; then
            VM_TLS_DISPLAY="${GREEN}TLS直连 ${PORT}/TCP${RESET}"
        else
            VM_TLS_DISPLAY="${CYAN}Argo 本地${PORT} / 边缘${ARGO_EDGE_PORT}${RESET}"
        fi

        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              协议节点管理 (单独开关/配置)${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " 说明：每种节点均可单独开关或修改端口；变更成功后订阅立即刷新。"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo ""
        echo -e "  ${PURPLE}1.${RESET} Vless-reality  状态: $VL_STATUS"
        echo -e "  ${PURPLE}2.${RESET} Hysteria2      状态: $HY2_STATUS"
        echo -e "  ${PURPLE}3.${RESET} Tuic5          状态: $TU5_STATUS"
        echo -e "  ${PURPLE}4.${RESET} Anytls         状态: $AN_STATUS"
        echo -e "  ${PURPLE}5.${RESET} Vmess-ws/Argo  模式与端口: $VM_TLS_DISPLAY"
        echo -e "  ${PURPLE}6.${RESET} Hysteria2 端口跳跃管理 (分享链接/Sing-box/Clash 同步)"
        echo -e "  ${PURPLE}7.${RESET} ${GREEN}一键开启全部附加协议${RESET}"
        echo -e "  ${PURPLE}8.${RESET} ${RED}一键关闭全部附加协议${RESET}"
        echo -e "  ${PURPLE}9.${RESET} Clash Meta 订阅 状态: $CLASH_STATUS"
        echo -e "  ${PURPLE}10.${RESET} Argo/Vmess 开关 状态: $VM_STATUS"
        echo -e "  ${PURPLE}11.${RESET} 主动心跳模式 状态: $HB_DISPLAY"
        # NAIVE-SUPPORT
        echo -e "  ${PURPLE}12.${RESET} NaiveProxy       状态: $NAIVE_STATUS"
        echo -e "  ${PURPLE}0.${RESET} 返回主菜单"
        echo ""
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请输入数字选择操作 [0-10]: " proto_choice

        case "$proto_choice" in
            1) toggle_single_protocol "VL" "Vless-reality" "tcp" ;;
            2) toggle_single_protocol "HY2" "Hysteria2" "udp" ;;
            3) toggle_single_protocol "TU5" "Tuic5" "udp" ;;
            4) toggle_single_protocol "AN" "Anytls" "tcp" ;;
            5) toggle_vmess_tls ;;
            6) hop_ports_menu ;;
            7) enable_all_protocols ;;
            8) disable_all_protocols ;;
            9) toggle_clash_meta ;;
            10) toggle_argo ;;
            11) heartbeat_menu ;;
            # NAIVE-SUPPORT
            12) toggle_naive ;;
            0) return ;;
            *) echo "输入无效，请重新选择"; sleep 1 ;;
        esac
    done
}

# NAIVE-SUPPORT：NaiveProxy 开关（开启前必须域名+Let's Encrypt 真证书就绪）
toggle_naive() {
    if ! ensure_singbox_core; then
        echo -e "${RED}Sing-box 内核不可用，未修改节点。${RESET}"
        sleep 2
        return
    fi
    load_config_with_defaults || return 1
    if [ "$NAIVE_ENABLED" = "true" ]; then
        local old_naive_port="$NAIVE_PORT"
        toggle_single_protocol "NAIVE" "NaiveProxy" "tcp"
        load_config_with_defaults || return 1
        close_protocol_firewall "$old_naive_port" udp
        if [ "$NAIVE_ENABLED" = "true" ]; then
            case "$NAIVE_MODE" in
                h2) close_protocol_firewall "$NAIVE_PORT" udp ;;
                h3) close_protocol_firewall "$NAIVE_PORT" tcp; open_protocol_firewall "$NAIVE_PORT" udp ;;
                both) open_protocol_firewall "$NAIVE_PORT" tcp; open_protocol_firewall "$NAIVE_PORT" udp ;;
            esac
        fi
        save_firewall
        return
    fi
    echo ""
    echo -e "${CYAN}传输模式：1) HTTP/2 TCP  2) HTTP/3 QUIC  3) H2+H3 双栈（推荐）${RESET}"
    local naive_mode_choice=""
    read -r -p "请选择 [1-3，回车默认 3]: " naive_mode_choice
    case "$naive_mode_choice" in
        1) NAIVE_MODE=h2 ;;
        2) NAIVE_MODE=h3 ;;
        *) NAIVE_MODE=both ;;
    esac
    safe_sed NAIVE_MODE "$NAIVE_MODE" || return 1
    if [ "$NAIVE_MODE" != h2 ]; then
        echo -e "${CYAN}QUIC 拥塞控制：1) BBR（推荐）  2) Cubic  3) New Reno${RESET}"
        read -r -p "请选择 [1-3，回车默认 1]: " naive_mode_choice
        case "$naive_mode_choice" in
            2) NAIVE_QUIC_CC=cubic ;;
            3) NAIVE_QUIC_CC=reno ;;
            *) NAIVE_QUIC_CC=bbr ;;
        esac
        safe_sed NAIVE_QUIC_CC "$NAIVE_QUIC_CC" || return 1
    fi
    # 开启：先确认域名（真证书必需）
    if [ -z "$NAIVE_DOMAIN" ]; then
        echo ""
        echo -e "${YELLOW}NaiveProxy 需要独立域名（Let's Encrypt 真证书，不支持自签）。${RESET}"
        read -p "请输入已解析到本机的域名（如 naive.example.com，回车取消）: " NAIVE_DOMAIN
        if [ -z "$NAIVE_DOMAIN" ]; then
            echo -e "${YELLOW}已取消。${RESET}"
            sleep 1
            return
        fi
        while ! printf '%s' "$NAIVE_DOMAIN" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'; do
            echo -e "${RED}域名格式无效。${RESET}"
            read -p "请重新输入域名: " NAIVE_DOMAIN
        done
        safe_sed NAIVE_DOMAIN "$NAIVE_DOMAIN" || return 1
    fi
    if [ -z "$NAIVE_USER" ] || [ -z "$NAIVE_PASS" ]; then
        NAIVE_USER="np_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
        NAIVE_PASS="$(head -c 24 /dev/urandom | base64 | tr -d '\n/+= ' | head -c 20)"
        safe_sed NAIVE_USER "$NAIVE_USER"
        safe_sed NAIVE_PASS "$NAIVE_PASS"
    fi
    # NAIVE-SUPPORT：443 被面板 nginx 占用时提示改用其他端口（隐蔽性仍是标准 TLS 端口优先）
    if [ "${NAIVE_PORT:-443}" = "443" ] && ss -tlnp 2>/dev/null | grep -q ':443 '; then
        echo -e "${YELLOW}[提示] 检测到 443 端口已被占用（面板 nginx 等）。NaiveProxy 将改用随机空闲端口（8443/2053 等标准 TLS 端口优先）。${RESET}"
        local naive_new_port=""
        for naive_candidate in 8443 2053 2083 2087 2096; do
            if ! ss -tlnp 2>/dev/null | grep -q ":${naive_candidate} "; then
                naive_new_port="$naive_candidate"
                break
            fi
        done
        [ -z "$naive_new_port" ] && naive_new_port=$(gen_random_port tcp)
        safe_sed NAIVE_PORT "$naive_new_port" || return 1
        load_config_with_defaults || return 1
        echo -e "${GREEN}[提示] NaiveProxy 端口已设为 ${naive_new_port}。${RESET}"
    fi
    echo -e "${YELLOW}正在申请/同步 Let's Encrypt 真证书（${NAIVE_DOMAIN}）……${RESET}"
    if ! ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL"; then
        echo -e "${RED}证书未就绪，NaiveProxy 未开启。请确认域名解析与 80 端口可用后重试。${RESET}"
        sleep 3
        return
    fi
    toggle_single_protocol "NAIVE" "NaiveProxy" "tcp"
    load_config_with_defaults || return 1
    if [ "$NAIVE_ENABLED" = "true" ]; then
        case "$NAIVE_MODE" in
            h2) close_protocol_firewall "$NAIVE_PORT" udp ;;
            h3) close_protocol_firewall "$NAIVE_PORT" tcp; open_protocol_firewall "$NAIVE_PORT" udp ;;
            both) open_protocol_firewall "$NAIVE_PORT" tcp; open_protocol_firewall "$NAIVE_PORT" udp ;;
        esac
        save_firewall
    fi
}

# 主动心跳模式：给客户端订阅注入保活参数（TCP keepalive + QUIC idle）。
heartbeat_menu() {
    while true; do
        clear
        load_config_with_defaults || return 1
        local hb_state="${RED}已关闭${RESET}"
        [ "$HB_ENABLED" = "true" ] && hb_state="${GREEN}已开启 · 间隔 ${HB_INTERVAL} 秒${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "${PURPLE}             主动心跳模式 (客户端保活)${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  当前状态: $hb_state"
        echo ""
        echo -e "  作用：给客户端订阅注入保活参数，锁屏/挂起后恢复"
        echo -e "        网络通道时秒级重连，空闲连接不被运营商掐断。"
        echo -e "  流量代价：极小（每用户每天几十 KB 级）。"
        echo -e "  生效范围：client.json 完整配置与 Clash Meta 订阅；"
        echo -e "            建议客户端 sing-box 内核 1.13+。"
        echo ""
        echo -e "  ${PURPLE}1.${RESET} 省电档 ${WHITE}600 秒${RESET}（10 分钟）"
        echo -e "  ${PURPLE}2.${RESET} 均衡档 ${WHITE}120 秒${RESET}（2 分钟，推荐）"
        echo -e "  ${PURPLE}3.${RESET} 极速档 ${WHITE}30 秒${RESET}"
        echo -e "  ${PURPLE}4.${RESET} 爆炸档 ${WHITE}10 秒${RESET}"
        echo -e "  ${PURPLE}5.${RESET} 自定义间隔（1-3600 秒）"
        echo -e "  ${RED}0.${RESET} 关闭心跳"
        echo -e "  ${CYAN}9.${RESET} 返回协议管理"
        echo ""
        read -p "请选择 [0-5, 9 返回]: " hb_choice
        case "$hb_choice" in
            1) hb_apply "600" ;;
            2) hb_apply "120" ;;
            3) hb_apply "30" ;;
            4) hb_apply "10" ;;
            5)
                read -p "请输入心跳间隔秒数 (1-3600): " hb_custom
                case "$hb_custom" in
                    *[!0-9]*|"")
                        echo -e "${RED}无效输入，请输入纯数字。${RESET}"
                        sleep 2
                        continue
                        ;;
                esac
                if [ "$hb_custom" -lt 1 ] || [ "$hb_custom" -gt 3600 ]; then
                    echo -e "${RED}超出范围 (1-3600 秒)。${RESET}"
                    sleep 2
                    continue
                fi
                hb_apply "$hb_custom"
                ;;
            0) hb_apply "0" ;;
            9) return ;;
            *) echo -e "${RED}无效输入。${RESET}"; sleep 1 ;;
        esac
    done
}

hb_apply() {
    local interval="$1"
    if [ "$interval" = "0" ]; then
        if apply_config_transaction "关闭主动心跳" "HB_ENABLED" "false"; then
            echo -e "${GREEN}主动心跳已关闭。${RESET}"
        else
            echo -e "${RED}配置保存失败。${RESET}"
        fi
    else
        if apply_config_transaction "开启主动心跳 ${interval}s" "HB_ENABLED" "true" "HB_INTERVAL" "$interval"; then
            echo -e "${GREEN}主动心跳已开启：间隔 ${interval} 秒。用户刷新订阅即生效。${RESET}"
        else
            echo -e "${RED}配置保存失败。${RESET}"
        fi
    fi
    sleep 3
}


toggle_single_protocol() {
    local proto="$1"
    local proto_name="$2"
    local proto_type="$3"
    local port_var="${proto}_PORT"
    local enabled_var="${proto}_ENABLED"
    local hop_var="${proto}_HOP_PORTS"
    local new_port=""

    if ! ensure_singbox_core; then
        echo -e "${RED}Sing-box 内核不可用，未修改节点。${RESET}"
        sleep 2
        return
    fi
    load_config_with_defaults || return 1
    local current_port="${!port_var}"
    local current_enabled="${!enabled_var}"
    local current_hop_spec=""
    if [ "$proto" = "HY2" ] || [ "$proto" = "TU5" ]; then
        current_hop_spec="${!hop_var}"
    fi

    if [ "$current_enabled" = "true" ] && [ -n "$current_port" ] && [ "$current_port" != "0" ]; then
        clear
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "${proto_name} - 当前状态: ${GREEN}已开启${RESET}  端口: ${YELLOW}$current_port${RESET} (${proto_type})"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 关闭此协议"
        echo -e "  2. 更改端口"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub_choice

        case "$sub_choice" in
            1)
                if apply_config_transaction "关闭 ${proto_name}" "$enabled_var" "false"; then
                    if [ "$proto" = "HY2" ] || [ "$proto" = "TU5" ]; then
                        remove_hop_ports "$current_port" "$proto" "$current_hop_spec"
                        save_firewall
                    fi
                    close_protocol_firewall "$current_port" "$proto_type"
                fi
                sleep 2
                ;;
            2)
                read -p "请输入新端口 (1-65535，回车随机): " new_port
                if [ -z "$new_port" ]; then
                    new_port=$(gen_random_port "$proto_type")
                fi
                if validate_node_port "$new_port" "$proto_type" "$port_var" "$current_port"; then
                    if [ "$proto" = "HY2" ] || [ "$proto" = "TU5" ]; then
                        echo -e "${YELLOW}主端口变化时会清除旧跳跃规则，避免订阅指向错误端口。${RESET}"
                        if apply_config_transaction "修改 ${proto_name} 端口" \
                            "$port_var" "$new_port" "${proto}_HOP_PORTS" ""; then
                            remove_hop_ports "$current_port" "$proto" "$current_hop_spec"
                            save_firewall
                            close_protocol_firewall "$current_port" "$proto_type"
                            open_protocol_firewall "$new_port" "$proto_type"
                        fi
                    elif apply_config_transaction "修改 ${proto_name} 端口" "$port_var" "$new_port"; then
                        close_protocol_firewall "$current_port" "$proto_type"
                        open_protocol_firewall "$new_port" "$proto_type"
                    fi
                fi
                sleep 2
                ;;
            0) return ;;
        esac
    else
        clear
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "${proto_name} - 当前状态: ${RED}未开启${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 开启此协议 (将自动分配/指定端口)"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub_choice

        case "$sub_choice" in
            1)
                generate_certs_and_keys || { echo -e "${RED}证书/密钥生成失败，无法开启${RESET}"; sleep 2; return; }
                load_config_with_defaults || return 1
                read -p "请输入端口 (1-65535，回车自动随机): " new_port
                if [ -z "$new_port" ]; then
                    new_port=$(gen_random_port "$proto_type")
                fi
                if validate_node_port "$new_port" "$proto_type" "$port_var" 0 && \
                   apply_config_transaction "开启 ${proto_name}" "$port_var" "$new_port" "$enabled_var" "true"; then
                    if ! ensure_node_service_running; then
                        apply_config_transaction "回滚未启动的 ${proto_name}" "$enabled_var" "false" >/dev/null 2>&1 || true
                        echo -e "${RED}[失败] 节点服务创建失败，本次开启已回滚。${RESET}"
                        sleep 2
                        return 1
                    fi
                    open_protocol_firewall "$new_port" "$proto_type"
                    load_config_with_defaults || return 1
                    if [ "$proto" = "HY2" ] && [ -n "$HY2_HOP_PORTS" ]; then
                        if ! install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1; then
                            apply_config_transaction "清除无法恢复的 HY2 跳跃配置" \
                                "HY2_HOP_PORTS" "" >/dev/null 2>&1 || true
                            echo -e "${YELLOW}[提示] 当前系统无法恢复跳跃规则，已清除跳跃范围；HY2 主端口仍可正常使用。${RESET}"
                        fi
                    fi
                fi
                sleep 2
                ;;
            0) return ;;
        esac
    fi
}

is_quick_argo_pid() {
    local pid="${1:-}"
    local cmdline=""
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    # 无法核对命令行时按“非本脚本进程”处理，避免误停系统中的其他 cloudflared。
    [ -r "/proc/${pid}/cmdline" ] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
    [[ "$cmdline" == *"cloudflared tunnel --url http://127.0.0.1:"* || \
       "$cmdline" == *"cloudflared tunnel --url http://localhost:"* ]]
}

is_managed_quick_argo_pid() {
    local pid="$1"
    local cmdline=""
    is_quick_argo_pid "$pid" || return 1
    [ -r "/proc/${pid}/cmdline" ] || return 1
    cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
    [[ "$cmdline" == *"--url http://127.0.0.1:${PORT}"* || \
       "$cmdline" == *"--url http://localhost:${PORT}"* || \
       ( -n "${VM_PREVIOUS_PORT:-}" && \
         ( "$cmdline" == *"--url http://127.0.0.1:${VM_PREVIOUS_PORT}"* || \
           "$cmdline" == *"--url http://localhost:${VM_PREVIOUS_PORT}"* ) ) ]]
}

quick_argo_pids() {
    local pid=""
    local tracked_pid=""
    [ -f "$ARGO_PID_FILE" ] && tracked_pid=$(cat "$ARGO_PID_FILE" 2>/dev/null)
    if is_managed_quick_argo_pid "$tracked_pid"; then
        printf '%s\n' "$tracked_pid"
    fi
    while IFS= read -r pid; do
        [ "$pid" = "$tracked_pid" ] && continue
        is_managed_quick_argo_pid "$pid" && printf '%s\n' "$pid"
    done < <(pgrep -x cloudflared 2>/dev/null || true)
}

quick_argo_running() {
    quick_argo_pids | grep -q .
}

expected_argo_tunnel_running() {
    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
        systemctl is-active --quiet cloudflared
    else
        quick_argo_running
    fi
}

stop_quick_argo_tunnel() {
    local pid=""
    while IFS= read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done < <(quick_argo_pids)
    rm -f "$ARGO_PID_FILE"
}

launch_quick_argo_tunnel() {
    load_config_with_defaults || return 1
    install_cloudflared || return 1
    local log_file=""
    local new_pid=""
    local old_pid=""
    local count=0
    local new_domain=""
    local old_domain="$ARGO_DOMAIN"
    local -a old_pids=()
    log_file=$(mktemp /tmp/argo-rr.XXXXXX.log) || return 1
    while IFS= read -r old_pid; do old_pids+=("$old_pid"); done < <(quick_argo_pids)

    nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" --edge-ip-version auto --protocol http2 \
        > "$log_file" 2>&1 &
    new_pid=$!
    while [ "$count" -lt 30 ]; do
        sleep 1
        new_domain=$(grep -oE 'https://[a-zA-Z0-9.-]+\.trycloudflare\.com' "$log_file" | head -n 1 | sed 's|https://||')
        [ -n "$new_domain" ] && break
        kill -0 "$new_pid" 2>/dev/null || break
        count=$((count + 1))
    done
    if [ -z "$new_domain" ]; then
        kill -TERM "$new_pid" 2>/dev/null || true
        echo -e "${RED}[失败] Argo 临时隧道未取得域名，旧隧道与旧订阅保持运行。${RESET}"
        tail -n 10 "$log_file" 2>/dev/null || true
        rm -f "$log_file"
        return 1
    fi

    ARGO_DOMAIN="$new_domain"
    if [ -f "$CONFIG_FILE" ] && \
       ! apply_config_transaction "切换 Argo 临时隧道域名" "ARGO_DOMAIN" "$new_domain"; then
        ARGO_DOMAIN="$old_domain"
        kill -TERM "$new_pid" 2>/dev/null || true
        rm -f "$log_file"
        echo -e "${RED}[失败] 新 Argo 域名的订阅生成失败，旧隧道继续服务。${RESET}"
        return 1
    fi

    printf '%s\n' "$new_pid" > "$ARGO_PID_FILE"
    for old_pid in "${old_pids[@]}"; do
        [ "$old_pid" = "$new_pid" ] || kill -TERM "$old_pid" 2>/dev/null || true
    done
    cp -f "$log_file" /tmp/argo.log 2>/dev/null || true
    rm -f "$log_file"
    echo -e "${GREEN}[成功] Argo 临时隧道已切换：${new_domain}${RESET}"
    if [ -n "$old_domain" ] && [ "$old_domain" != "$new_domain" ]; then
        rr_emit_alert argo_domain_changed warning "Argo 临时域名已变化" \
            "旧域名 ${old_domain} 已切换为 ${new_domain}，设备订阅已同步刷新。" \
            "argo_domain_changed:${new_domain}" --interval 0
    fi
    return 0
}

rotate_quick_argo_origin_port() {
    local old_port="$1"
    local new_port="$2"

    # 第一阶段同时监听新旧端口，因此旧隧道在新隧道拿到域名前始终可用。
    if ! apply_config_transaction "预热新的 Argo 本地源站端口" \
        "PORT" "$new_port" "VM_PREVIOUS_PORT" "$old_port"; then
        return 1
    fi

    if ! launch_quick_argo_tunnel; then
        apply_config_transaction "回滚 Argo 本地源站端口" \
            "PORT" "$old_port" "VM_PREVIOUS_PORT" "" >/dev/null 2>&1 || true
        return 1
    fi

    if ! apply_config_transaction "完成 Argo 本地源站端口切换" "VM_PREVIOUS_PORT" ""; then
        echo -e "${YELLOW}[提示] 新端口与新隧道均已可用，但旧回环监听暂时保留；再次修改端口时会自动覆盖。${RESET}"
    fi
    return 0
}

rr_cloudflared_service_token() {
    systemctl cat cloudflared 2>/dev/null | awk '
        /^[[:space:]]*ExecStart=/ {
            for (i=1; i<=NF; i++) {
                if ($i == "--token" && i < NF) { print $(i+1); exit }
                if ($i ~ /^--token=/) { sub(/^--token=/, "", $i); print $i; exit }
            }
        }
    '
}

ensure_fixed_argo_service() {
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local desired_token=""
    if systemctl cat cloudflared >/dev/null 2>&1; then
        systemctl enable --now cloudflared >/dev/null 2>&1 || return 1
        systemctl is-active --quiet cloudflared
        return $?
    else
        [ -r "$token_file" ] || return 1
        IFS= read -r desired_token < "$token_file" || return 1
        [ -n "$desired_token" ] && [[ "$desired_token" != *[[:space:]]* ]] || return 1
        cloudflared service install "$desired_token" >/dev/null 2>&1 || return 1
    fi
    systemctl enable --now cloudflared >/dev/null 2>&1 || return 1
    systemctl is-active --quiet cloudflared
}

start_argo_tunnel() {
    load_config_with_defaults || return 1
    if [ "$VM_ENABLED" = "false" ] || [ "$VM_TLS_ENABLED" = "true" ]; then
        stop_quick_argo_tunnel
        return 0
    fi
    install_cloudflared || return 1
    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
        ensure_fixed_argo_service
    else
        launch_quick_argo_tunnel
    fi
}

toggle_vmess_tls() {
    ensure_singbox_core || { sleep 2; return; }
    load_config_with_defaults || return 1
    if [ "$VM_ENABLED" = "false" ]; then
        clear
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "VMess-ws 当前: ${RED}未开启${RESET}"
        echo -e "  1. 开启 VMess-WS + TLS 公网直连"
        echo -e "  0. 返回（如需 Argo，请选择协议菜单 10）"
        echo -e "${CYAN}==================================================${RESET}"
        local enable_choice=""
        read -p "请选择操作: " enable_choice
        [ "$enable_choice" = "1" ] || return 0
        generate_certs_and_keys || return 1
        load_config_with_defaults || return 1
        local enable_port="$PORT"
        if ! is_valid_port "$enable_port"; then
            read -p "请输入 VMess TLS 直连端口（回车随机）: " enable_port
            [ -z "$enable_port" ] && enable_port=$(gen_random_port tcp)
        fi
        if ! validate_node_port "$enable_port" tcp PORT 0; then
            sleep 2
            return 1
        fi
        if apply_config_transaction "开启 VMess TLS 直连" \
            "PORT" "$enable_port" "VM_TLS_ENABLED" "true" "VM_ENABLED" "true"; then
            if ! ensure_node_service_running; then
                apply_config_transaction "回滚未启动的 VMess TLS" "VM_ENABLED" "false" >/dev/null 2>&1 || true
                echo -e "${RED}[失败] Sing-box 服务未能启动，本次开启已回滚。${RESET}"
                sleep 2
                return 1
            fi
            open_protocol_firewall "$enable_port" tcp
        fi
        sleep 2
        return 0
    fi
    local direct_listen="::"
    [ "$ENTRY_IP_MODE" = "ipv4" ] && direct_listen="0.0.0.0"
    local direct_listen_display="$direct_listen"
    [ "$direct_listen" = "::" ] && direct_listen_display="[::]"
    clear
    echo -e "${CYAN}==================================================${RESET}"
    if [ "$VM_TLS_ENABLED" = "true" ]; then
        echo -e "Vmess-ws 当前: ${GREEN}TLS直连模式${RESET}"
        echo -e "服务端监听: ${YELLOW}${direct_listen_display}:${PORT}/TCP${RESET}"
    else
        echo -e "Vmess-ws 当前: ${CYAN}Argo隧道模式${RESET}"
        echo -e "本地源站: ${YELLOW}127.0.0.1:${PORT}/TCP${RESET}（不占公网端口）"
        echo -e "Cloudflare 边缘端口: ${YELLOW}${ARGO_EDGE_PORT}/TCP${RESET}"
    fi
    echo -e "${CYAN}==================================================${RESET}"
    echo -e "  1. 切换 Argo / TLS直连模式"
    echo -e "  2. 修改 Vmess/Argo 本地监听端口"
    echo -e "  3. 修改 Argo 边缘 HTTPS 端口"
    echo -e "  0. 返回"
    read -p "请选择操作: " sub
    case "$sub" in
        1)
            if [ "$VM_TLS_ENABLED" = "true" ]; then
                if apply_config_transaction "切换为 Argo 隧道模式" "VM_TLS_ENABLED" "false"; then
                    close_protocol_firewall "$PORT" tcp
                    start_argo_tunnel || echo -e "${RED}[警告] Argo 隧道启动失败，Vmess 本地源站仍正常。${RESET}"
                fi
            else
                generate_certs_and_keys || return
                if apply_config_transaction "切换为 Vmess TLS 直连模式" "VM_TLS_ENABLED" "true"; then
                    stop_quick_argo_tunnel
                    open_protocol_firewall "$PORT" tcp
                    # 依赖联动：TLS 直连模式下优选副节点（Argo CNAME）不生效，清理残留
                    rm -f /tmp/sub_server/preferred_cnames.txt 2>/dev/null || true
                    if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
                        echo -e "${YELLOW}[提示] 自动优选副节点仅在 Argo 模式生效，已清理当前副节点。${RESET}"
                    fi
                fi
            fi
            ;;
        2)
            local old_port="$PORT"
            local new_port=""
            read -p "请输入新的本地端口 (1-65535，回车随机): " new_port
            [ -z "$new_port" ] && new_port=$(gen_random_port tcp)
            if validate_node_port "$new_port" tcp PORT "$old_port"; then
                if [ "$VM_ENABLED" != "false" ] && [ "${TUNNEL_MODE:-1}" = "2" ] && [ "$VM_TLS_ENABLED" != "true" ]; then
                    if apply_config_transaction "预热固定 Argo 的新本地端口" \
                        "PORT" "$new_port" "VM_PREVIOUS_PORT" "$old_port"; then
                        echo -e "${GREEN}新旧本地端口现已同时可用，当前隧道不会掉线。${RESET}"
                        echo -e "${YELLOW}请把 Cloudflare 面板服务地址改为 http://localhost:${new_port}。${RESET}"
                        read -p "面板修改完成后请输入 DONE（否则保留双端口）: " fixed_confirm
                        if [ "$fixed_confirm" = "DONE" ]; then
                            apply_config_transaction "完成固定 Argo 本地端口切换" "VM_PREVIOUS_PORT" "" || true
                        else
                            echo -e "${YELLOW}已保留旧回环端口 ${old_port} 作为回退；节点仍可用。${RESET}"
                        fi
                    fi
                elif [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && [ "${TUNNEL_MODE:-1}" != "2" ]; then
                    rotate_quick_argo_origin_port "$old_port" "$new_port" || \
                        echo -e "${RED}[失败] 新隧道未就绪，已恢复旧端口与旧节点。${RESET}"
                elif apply_config_transaction "修改 Vmess 本地端口" "PORT" "$new_port"; then
                    [ "$VM_TLS_ENABLED" = "true" ] && {
                        close_protocol_firewall "$old_port" tcp
                        open_protocol_firewall "$new_port" tcp
                    }
                fi
            fi
            ;;
        3)
            local new_edge_port=""
            echo -e "可选 HTTPS 端口：443、2053、2083、2087、2096、8443"
            read -p "请输入新的 Argo 边缘端口: " new_edge_port
            if is_cloudflare_tls_port "$new_edge_port"; then
                apply_config_transaction "修改 Argo 边缘端口" "ARGO_EDGE_PORT" "$new_edge_port"
            else
                echo -e "${RED}该端口不在 Cloudflare 官方 HTTPS 代理端口列表中。${RESET}"
            fi
            ;;
        0) return ;;
    esac
    sleep 2
}

hop_ports_menu() {
    load_config_with_defaults || return 1
    while true; do
        clear
        local hy2_hop=$(get_hop_ports "$HY2_PORT")
        [ -z "$hy2_hop" ] && hy2_hop="(未设置)"

        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              Hysteria2 端口跳跃管理${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " 说明：按 Hysteria 官方方式，把跳跃 UDP 端口重定向到主端口。"
        echo -e " Tuic5 没有通用的客户端端口跳跃字段，因此不生成误导配置。"
        echo -e " 原始分享链接采用兼容字段；自定义间隔请优先导入 Sing-box/Clash 配置文件。"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo ""
        if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
            echo -e "  ${PURPLE}1.${RESET} Hysteria2 (主端口: $HY2_PORT)  跳跃端口: ${GREEN}$hy2_hop${RESET}"
        else
            echo -e "  ${PURPLE}1.${RESET} Hysteria2 - ${RED}未开启${RESET}"
        fi
        echo -e "  ${PURPLE}0.${RESET} 返回"
        echo ""
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请选择 [0-1]: " hop_choice

        case "$hop_choice" in
            1) manage_hop "HY2" "$HY2_PORT" "$HY2_ENABLED" ;;
            0) return ;;
            *) echo "输入无效"; sleep 1 ;;
        esac
    done
}

manage_hop() {
    local label="$1"
    local main_port="$2"
    local enabled="$3"
    if [ "$enabled" != "true" ] || [ -z "$main_port" ] || [ "$main_port" = "0" ]; then
        echo -e "${RED}该协议未开启，请先开启后再设置端口跳跃${RESET}"
        sleep 2
        return
    fi
    clear
    echo -e "${CYAN}==================================================${RESET}"
    echo -e "${label} 端口跳跃管理 (主端口: $main_port UDP)"
    echo -e " 当前跳跃端口: ${GREEN}$(get_hop_ports "$main_port")${RESET}"
    [ "$label" = "HY2" ] && echo -e " 当前跳跃间隔: ${GREEN}${HY2_HOP_INTERVAL:-30s}${RESET}"
    echo -e "${CYAN}==================================================${RESET}"
    echo -e "  1. 设置/替换跳跃端口 (如 20000:30000,40000)"
    if [ "$label" = "HY2" ]; then
        echo -e "  2. 修改 HY2 跳跃间隔 (如 30s)"
    fi
    echo -e "  3. 清除所有跳跃端口"
    echo -e "  4. 修改主端口"
    echo -e "  0. 返回"
    read -p "请选择: " sub
    case "$sub" in
        1)
            local new_spec=""
            read -p "输入端口或范围，多个用逗号分隔: " new_spec
            new_spec=$(printf '%s' "$new_spec" | tr -d '[:space:]')
            if [ -z "$new_spec" ] || ! is_valid_hop_spec "$new_spec"; then
                echo -e "${RED}格式错误；端口须在 1000-65535，范围格式为 小端口:大端口。${RESET}"
            else
                apply_hop_configuration "$label" "$main_port" "$new_spec" "${HY2_HOP_INTERVAL:-30s}"
            fi
            sleep 2
            ;;
        2)
            if [ "$label" != "HY2" ]; then
                echo -e "${RED}该选项仅适用于 Hysteria2。${RESET}"
            else
                local new_interval=""
                read -p "输入跳跃间隔 (5s-24h，回车保持 ${HY2_HOP_INTERVAL:-30s}): " new_interval
                new_interval="${new_interval:-${HY2_HOP_INTERVAL:-30s}}"
                if ! is_valid_hop_interval "$new_interval"; then
                    echo -e "${RED}时间格式或范围错误，例如 30s、1m；允许 5s-24h。${RESET}"
                else
                    apply_hop_configuration "$label" "$main_port" "$(get_hop_ports "$main_port")" "$new_interval"
                fi
            fi
            sleep 2
            ;;
        3)
            apply_hop_configuration "$label" "$main_port" "" "${HY2_HOP_INTERVAL:-30s}"
            sleep 2
            ;;
        4)
            local new_main=""
            read -p "输入新的主端口 (1-65535，回车取消): " new_main
            new_main=$(printf '%s' "$new_main" | tr -d '[:space:]')
            if [ -z "$new_main" ]; then
                echo -e "${YELLOW}已取消。${RESET}"
            elif ! validate_node_port "$new_main" udp "$label" "$main_port"; then
                :
            else
                # 主端口变化时清除旧跳跃规则，避免订阅指向错误端口；apply_config_transaction 会自动刷新全部订阅
                local current_hop_spec=""
                current_hop_spec=$(get_hop_ports "$main_port")
                if apply_config_transaction "修改 ${label} 主端口" "${label}_PORT" "$new_main" "${label}_HOP_PORTS" ""; then
                    remove_hop_ports "$main_port" "$label" "$current_hop_spec"
                    save_firewall
                    close_protocol_firewall "$main_port" udp
                    open_protocol_firewall "$new_main" udp
                    echo -e "${GREEN}[成功] 主端口已修改为 ${new_main}，跳跃规则已清除，订阅已同步。${RESET}"
                    main_port="$new_main"
                fi
            fi
            sleep 2
            ;;
        0) return ;;
    esac
}

get_hop_ports_from_firewall() {
    local port="$1"
    local command_name=""
    is_valid_port "$port" || return 0
    {
        for command_name in iptables ip6tables; do
            command -v "$command_name" >/dev/null 2>&1 || continue
            "$command_name" -w 5 -t nat -S PREROUTING 2>/dev/null || true
        done
    } | awk -v p="$port" '
        /-p udp/ && /--dport/ {
            dport=""
            matched=0
            for (i=1; i<=NF; i++) {
                if ($i == "--dport" && i < NF) dport=$(i+1)
                if ($i == "--to-ports" && i < NF && $(i+1) == p) matched=1
                if ($i == "--to-destination" && i < NF && $(i+1) ~ (":" p "$") ) matched=1
            }
            if (matched && dport != "") print dport
        }
    ' | awk '!seen[$0]++' | tr '\n' ',' | sed 's/,$//'
}

get_hop_ports() {
    local port="$1"
    if [ "$port" = "${HY2_PORT:-0}" ] && [ -n "${HY2_HOP_PORTS:-}" ]; then
        printf '%s\n' "$HY2_HOP_PORTS"
    elif [ "$port" = "${TU5_PORT:-0}" ] && [ -n "${TU5_HOP_PORTS:-}" ]; then
        printf '%s\n' "$TU5_HOP_PORTS"
    else
        get_hop_ports_from_firewall "$port"
    fi
}

remove_hop_ports() {
    local main_port="$1"
    local label="$2"
    local spec_list="$3"
    local command_name=""
    local spec=""
    local removed_tagged=false
    local -a specs=()
    is_valid_port "$main_port" || return 0
    [ -n "$label" ] && [ -n "$spec_list" ] || return 0
    IFS=',' read -r -a specs <<< "$spec_list"

    for command_name in iptables ip6tables; do
        command -v "$command_name" >/dev/null 2>&1 || continue
        for spec in "${specs[@]}"; do
            removed_tagged=false
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j REDIRECT \
                --to-ports "$main_port" >/dev/null 2>&1; do
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -m comment --comment "argo-rr-${label}" -j REDIRECT \
                    --to-ports "$main_port" >/dev/null 2>&1 || break
                removed_tagged=true
            done
            # 兼容 6.0.0 之前使用 DNAT 的脚本规则，更新后只精确清理本脚本标签项。
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j DNAT \
                --to-destination ":${main_port}" >/dev/null 2>&1; do
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -m comment --comment "argo-rr-${label}" -j DNAT \
                    --to-destination ":${main_port}" >/dev/null 2>&1 || break
                removed_tagged=true
            done
            # 仅在没有带标签规则时清理一条完全匹配的旧版规则；绝不按目标端口批量删用户规则。
            if [ "$removed_tagged" = false ] && \
               "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                    -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1; then
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 || true
            fi
            if [ "$removed_tagged" = false ] && \
               "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                    -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1; then
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1 || true
            fi
        done
    done
}

add_hop_rule() {
    local command_name="$1"
    local spec="$2"
    local main_port="$3"
    local label="$4"
    command -v "$command_name" >/dev/null 2>&1 || return 1
    "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
        -m comment --comment "argo-rr-${label}" -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 && return 0
    "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
        -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 && return 0
    # 已存在的旧版 DNAT 规则仍然有效；不重复叠加，后续修改/清除时会精确迁移掉。
    "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
        -m comment --comment "argo-rr-${label}" -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1 && return 0
    "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
        -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1 && return 0
    "$command_name" -w 5 -t nat -A PREROUTING -p udp --dport "$spec" \
        -m comment --comment "argo-rr-${label}" -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 && return 0
    "$command_name" -w 5 -t nat -A PREROUTING -p udp --dport "$spec" \
        -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1
}

install_hop_rules() {
    local label="$1"
    local main_port="$2"
    local spec_list="$3"
    local spec=""
    local required_command=""
    local required_ok=true
    local -a specs=()
    [ -z "$spec_list" ] && return 0
    is_valid_port "$main_port" || return 1
    is_valid_hop_spec "$spec_list" || return 1

    case "${ENTRY_IP_MODE:-auto}" in
        ipv4) required_command="iptables" ;;
        ipv6) required_command="ip6tables" ;;
        *)
            if select_entry_ip >/dev/null 2>&1 && is_ip_version "$ENTRY_IP_RAW" 6; then
                required_command="ip6tables"
            else
                required_command="iptables"
            fi
            ;;
    esac
    command -v "$required_command" >/dev/null 2>&1 || return 1

    IFS=',' read -r -a specs <<< "$spec_list"
    for spec in "${specs[@]}"; do
        if [ "$required_command" = "iptables" ]; then
            add_hop_rule iptables "$spec" "$main_port" "$label" || required_ok=false
            add_hop_rule ip6tables "$spec" "$main_port" "$label" >/dev/null 2>&1 || true
        else
            add_hop_rule ip6tables "$spec" "$main_port" "$label" || required_ok=false
            add_hop_rule iptables "$spec" "$main_port" "$label" >/dev/null 2>&1 || true
        fi
    done
    [ "$required_ok" = true ]
}

apply_hop_configuration() {
    local label="$1"
    local main_port="$2"
    local new_spec="$3"
    local new_interval="$4"
    local key="${label}_HOP_PORTS"
    local old_spec=""
    local config_backup=""

    load_config_with_defaults || return 1
    old_spec=$(get_hop_ports "$main_port")
    is_valid_hop_spec "$new_spec" || return 1
    is_valid_hop_interval "$new_interval" || return 1
    validate_hop_spec_availability "$new_spec" "$main_port" || return 1
    config_backup=$(mktemp /tmp/argo_vmess.conf.XXXXXX) || return 1
    cp -p "$CONFIG_FILE" "$config_backup" || { rm -f "$config_backup"; return 1; }

    remove_hop_ports "$main_port" "$label" "$old_spec"
    if [ -n "$new_spec" ] && ! install_hop_rules "$label" "$main_port" "$new_spec"; then
        remove_hop_ports "$main_port" "$label" "$new_spec"
        [ -n "$old_spec" ] && install_hop_rules "$label" "$main_port" "$old_spec" >/dev/null 2>&1 || true
        rm -f "$config_backup"
        echo -e "${RED}[失败] 当前入口地址族无法写入 UDP NAT 转发规则，原跳跃配置未改动。${RESET}"
        return 1
    fi

    local -a hop_updates=("$key" "$new_spec")
    [ "$label" = "HY2" ] && hop_updates+=("HY2_HOP_INTERVAL" "$new_interval")
    if ! apply_config_transaction "更新 ${label} 端口跳跃" "${hop_updates[@]}"; then
        cp -p "$config_backup" "$CONFIG_FILE" >/dev/null 2>&1 || true
        remove_hop_ports "$main_port" "$label" "$new_spec"
        [ -n "$old_spec" ] && install_hop_rules "$label" "$main_port" "$old_spec" >/dev/null 2>&1 || true
        save_firewall
        rm -f "$config_backup"
        echo -e "${RED}[失败] 新跳跃配置未能完整生效，防火墙与订阅均已恢复。${RESET}"
        return 1
    fi

    save_firewall
    rm -f "$config_backup"
    if [ -n "$new_spec" ]; then
        echo -e "${GREEN}[成功] ${label} 跳跃端口已实时写入防火墙、分享链接、Sing-box/Clash 订阅。${RESET}"
        echo -e "${YELLOW}NAT 服务器还需在服务商面板映射同一 UDP 端口/范围。${RESET}"
    else
        echo -e "${GREEN}[成功] ${label} 跳跃端口已清除，订阅已实时刷新。${RESET}"
    fi
}

enable_all_protocols() {
    ensure_singbox_core || { sleep 2; return; }
    load_config_with_defaults || return 1
    generate_certs_and_keys || { echo -e "${RED}证书/密钥生成失败${RESET}"; sleep 2; return; }
    load_config_with_defaults || return 1

    local -a updates=()
    local -A allocated_tcp=()
    local -A allocated_udp=()
    local existing_port=""
    for existing_port in "$PORT" "$SUB_PORT" "$VL_PORT" "$AN_PORT"; do
        is_valid_port "$existing_port" && allocated_tcp["$existing_port"]=1
    done
    for existing_port in "$HY2_PORT" "$TU5_PORT"; do
        is_valid_port "$existing_port" && allocated_udp["$existing_port"]=1
    done

    for proto in VL HY2 TU5 AN; do
        local port_var="${proto}_PORT"
        local enabled_var="${proto}_ENABLED"
        local current_port="${!port_var}"
        if [ -z "$current_port" ] || [ "$current_port" = "0" ]; then
            local port_type="tcp"
            [ "$proto" = "HY2" ] || [ "$proto" = "TU5" ] && port_type="udp"
            local new_port=""
            while true; do
                new_port=$(gen_random_port "$port_type")
                if [ "$port_type" = "tcp" ]; then
                    [ -z "${allocated_tcp[$new_port]:-}" ] && { allocated_tcp["$new_port"]=1; break; }
                else
                    [ -z "${allocated_udp[$new_port]:-}" ] && { allocated_udp["$new_port"]=1; break; }
                fi
            done
            updates+=("$port_var" "$new_port")
        fi
        updates+=("$enabled_var" "true")
    done

    if apply_config_transaction "开启全部附加协议" "${updates[@]}"; then
        if ! ensure_node_service_running; then
            apply_config_transaction "回滚未启动的附加协议" \
                "VL_ENABLED" "false" "HY2_ENABLED" "false" \
                "TU5_ENABLED" "false" "AN_ENABLED" "false" >/dev/null 2>&1 || true
            echo -e "${RED}[失败] Sing-box 服务未能启动，本次批量开启已回滚。${RESET}"
            sleep 2
            return 1
        fi
        open_protocol_firewall "$VL_PORT" tcp
        open_protocol_firewall "$HY2_PORT" udp
        open_protocol_firewall "$TU5_PORT" udp
        open_protocol_firewall "$AN_PORT" tcp
        if [ -n "$HY2_HOP_PORTS" ] && \
           ! install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1; then
            apply_config_transaction "清除无法恢复的 HY2 跳跃配置" \
                "HY2_HOP_PORTS" "" >/dev/null 2>&1 || true
            echo -e "${YELLOW}[提示] 当前系统无法恢复跳跃规则，已保留 HY2 主端口并清除跳跃范围。${RESET}"
        fi
        save_firewall
    fi
    sleep 2
}

disable_all_protocols() {
    load_config_with_defaults || return 1
    local old_vl="$VL_PORT"
    local old_hy2="$HY2_PORT"
    local old_tu5="$TU5_PORT"
    local old_an="$AN_PORT"
    local old_hy2_hops="$HY2_HOP_PORTS"
    local old_tu5_hops="$TU5_HOP_PORTS"
    if apply_config_transaction "关闭全部附加协议" \
        "VL_ENABLED" "false" "HY2_ENABLED" "false" \
        "TU5_ENABLED" "false" "AN_ENABLED" "false" \
        "NAIVE_ENABLED" "false"; then
        remove_hop_ports "$old_hy2" HY2 "$old_hy2_hops"
        remove_hop_ports "$old_tu5" TU5 "$old_tu5_hops"
        close_protocol_firewall "$old_vl" tcp
        close_protocol_firewall "$old_hy2" udp
        close_protocol_firewall "$old_tu5" udp
        close_protocol_firewall "$old_an" tcp
        # NAIVE-SUPPORT
        close_protocol_firewall "$NAIVE_PORT" tcp
        close_protocol_firewall "$NAIVE_PORT" udp
    fi
    sleep 2
}
