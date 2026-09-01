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
    local old_naive_port="$NAIVE_PORT"
    local desired_naive_port="$NAIVE_PORT"
    local desired_naive_mode="$NAIVE_MODE"
    local desired_naive_quic_cc="$NAIVE_QUIC_CC"
    local desired_naive_domain="$NAIVE_DOMAIN"
    local desired_naive_user="$NAIVE_USER"
    local desired_naive_pass="$NAIVE_PASS"
    local naive_mode_choice=""
    if [ "$NAIVE_ENABLED" = "true" ]; then
        local -a naive_disable_operations=(
            "protocol|closed|${old_naive_port}|tcp"
            "protocol|closed|${old_naive_port}|udp")
        local -a naive_disable_updates=(NAIVE_ENABLED false)
        local acme_needed_status=0
        if rr_firewall_acme_http_tuple_needed_after_updates \
            naive_disable_updates; then
            naive_disable_operations+=("protocol|open|80|tcp")
        else
            acme_needed_status=$?
            case "$acme_needed_status" in
                1) naive_disable_operations+=("protocol|closed|80|tcp") ;;
                *) return 1 ;;
            esac
        fi
        apply_config_firewall_batch "关闭 NaiveProxy" preserve \
            naive_disable_operations naive_disable_updates || return 1
        return 0
    fi
    echo ""
    echo -e "${CYAN}传输模式：1) HTTP/2 TCP  2) HTTP/3 QUIC  3) H2+H3 双栈（推荐）${RESET}"
    read -r -p "请选择 [1-3，回车默认 3]: " naive_mode_choice
    case "$naive_mode_choice" in
        1) desired_naive_mode=h2 ;;
        2) desired_naive_mode=h3 ;;
        *) desired_naive_mode=both ;;
    esac
    if [ "$desired_naive_mode" != h2 ]; then
        echo -e "${CYAN}QUIC 拥塞控制：1) BBR（推荐）  2) Cubic  3) New Reno${RESET}"
        read -r -p "请选择 [1-3，回车默认 1]: " naive_mode_choice
        case "$naive_mode_choice" in
            2) desired_naive_quic_cc=cubic ;;
            3) desired_naive_quic_cc=reno ;;
            *) desired_naive_quic_cc=bbr ;;
        esac
    fi
    # 开启：先确认域名（真证书必需）
    if [ -z "$desired_naive_domain" ]; then
        echo ""
        echo -e "${YELLOW}NaiveProxy 需要独立域名（Let's Encrypt 真证书，不支持自签）。${RESET}"
        read -p "请输入已解析到本机的域名（如 naive.example.com，回车取消）: " desired_naive_domain
        if [ -z "$desired_naive_domain" ]; then
            echo -e "${YELLOW}已取消。${RESET}"
            sleep 1
            return
        fi
        while ! printf '%s' "$desired_naive_domain" | grep -qE '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$'; do
            echo -e "${RED}域名格式无效。${RESET}"
            read -p "请重新输入域名: " desired_naive_domain
        done
    fi
    if [ -z "$desired_naive_user" ] || [ -z "$desired_naive_pass" ]; then
        desired_naive_user="np_$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 8)"
        desired_naive_pass="$(head -c 24 /dev/urandom | base64 | tr -d '\n/+= ' | head -c 20)"
    fi
    # NAIVE-SUPPORT：443 被面板 nginx 占用时提示改用其他端口（隐蔽性仍是标准 TLS 端口优先）
    if [ "${desired_naive_port:-443}" = "443" ] && \
       { ss -tlnp 2>/dev/null | grep -q ':443 ' || \
         { [ "$desired_naive_mode" != h2 ] && \
           ss -ulnp 2>/dev/null | grep -q ':443 '; }; }; then
        echo -e "${YELLOW}[提示] 检测到 443 端口已被占用（面板 nginx 等）。NaiveProxy 将改用随机空闲端口（8443/2053 等标准 TLS 端口优先）。${RESET}"
        local naive_new_port=""
        for naive_candidate in 8443 2053 2083 2087 2096; do
            if ! ss -tlnp 2>/dev/null | grep -q ":${naive_candidate} " && \
               { [ "$desired_naive_mode" = h2 ] || \
                 ! ss -ulnp 2>/dev/null | grep -q ":${naive_candidate} "; }; then
                naive_new_port="$naive_candidate"
                break
            fi
        done
        [ -z "$naive_new_port" ] && naive_new_port=$(gen_random_port tcp)
        desired_naive_port="$naive_new_port"
        echo -e "${GREEN}[提示] NaiveProxy 端口已设为 ${naive_new_port}。${RESET}"
    fi
    case "$desired_naive_mode" in
        h2)
            validate_node_port "$desired_naive_port" tcp NAIVE_PORT \
                "$old_naive_port" || return 1
            ;;
        h3)
            validate_node_port "$desired_naive_port" udp NAIVE_PORT \
                "$old_naive_port" || return 1
            ;;
        both)
            validate_node_port "$desired_naive_port" tcp NAIVE_PORT \
                "$old_naive_port" || return 1
            validate_node_port "$desired_naive_port" udp NAIVE_PORT \
                "$old_naive_port" || return 1
            ;;
        *) return 1 ;;
    esac
    local naive_http_was_open=false naive_http_created=false
    local naive_http_status=0 naive_batch_status=0
    local -a naive_old_updates=()
    rr_validate_protocol_firewall 80 tcp open && naive_http_was_open=true
    echo -e "${YELLOW}正在申请/同步 Let's Encrypt 真证书（${desired_naive_domain}）……${RESET}"
    if ! NAIVE_DOMAIN="$desired_naive_domain" \
        ensure_naive_certificate "$desired_naive_domain" "$LE_EMAIL"; then
        if [ "$naive_http_was_open" = false ] && \
           rr_validate_protocol_firewall 80 tcp open; then
            if rr_firewall_acme_http_tuple_needed_after_updates \
                naive_old_updates; then
                :
            else
                naive_http_status=$?
                if [ "$naive_http_status" -eq 1 ]; then
                    close_protocol_firewall 80 tcp || naive_http_status=$?
                fi
                if [ "$naive_http_status" -ge 2 ]; then
                    rr_firewall_fail_closed_stop_nodes \
                        'Naive 证书失败后 TCP/80 补偿状态不确定' || true
                fi
            fi
        fi
        echo -e "${RED}证书未就绪，NaiveProxy 未开启。请确认域名解析与 80 端口可用后重试。${RESET}"
        sleep 3
        return 1
    fi
    if [ "$naive_http_was_open" = false ]; then
        rr_validate_protocol_firewall 80 tcp open || {
            rr_firewall_fail_closed_stop_nodes \
                'Naive 证书就绪后无法证明 TCP/80 防火墙状态' || true
            return 1
        }
        naive_http_created=true
    fi
    local -a naive_enable_operations=(
        "protocol|closed|${old_naive_port}|tcp"
        "protocol|closed|${old_naive_port}|udp"
        "protocol|closed|${desired_naive_port}|tcp"
        "protocol|closed|${desired_naive_port}|udp")
    case "$desired_naive_mode" in
        h2) naive_enable_operations+=("protocol|open|${desired_naive_port}|tcp") ;;
        h3) naive_enable_operations+=("protocol|open|${desired_naive_port}|udp") ;;
        both)
            naive_enable_operations+=(
                "protocol|open|${desired_naive_port}|tcp"
                "protocol|open|${desired_naive_port}|udp")
            ;;
    esac
    naive_enable_operations+=("protocol|open|80|tcp")
    local -a naive_enable_updates=(
        NAIVE_PORT "$desired_naive_port"
        NAIVE_MODE "$desired_naive_mode"
        NAIVE_QUIC_CC "$desired_naive_quic_cc"
        NAIVE_DOMAIN "$desired_naive_domain"
        NAIVE_USER "$desired_naive_user"
        NAIVE_PASS "$desired_naive_pass"
        NAIVE_ENABLED true)
    apply_config_firewall_batch "开启 NaiveProxy" ensure-running \
        naive_enable_operations naive_enable_updates || naive_batch_status=$?
    if [ "$naive_batch_status" -ne 0 ] && [ "$naive_http_created" = true ] && \
       ! rr_firewall_fail_closed_quarantine_active; then
        naive_http_status=0
        if rr_firewall_acme_http_tuple_needed_after_updates naive_old_updates; then
            :
        else
            naive_http_status=$?
            if [ "$naive_http_status" -eq 1 ]; then
                close_protocol_firewall 80 tcp || naive_http_status=$?
            fi
        fi
        if [ "$naive_http_status" -ge 2 ]; then
            rr_firewall_fail_closed_stop_nodes \
                'Naive 开启回滚后 TCP/80 补偿状态不确定' || true
        fi
    fi
    return "$naive_batch_status"
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
                local -a disable_operations=() disable_updates=("$enabled_var" "false")
                if { [ "$proto" = HY2 ] || [ "$proto" = TU5 ]; } && \
                   [ -n "$current_hop_spec" ]; then
                    disable_operations+=(
                        "hop|${proto}|${current_port}|${current_hop_spec}|")
                fi
                disable_operations+=(
                    "protocol|closed|${current_port}|${proto_type}")
                if ! apply_config_firewall_batch "关闭 ${proto_name}" preserve \
                    disable_operations disable_updates; then
                    sleep 2
                    return 1
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
                        if ! apply_hop_main_port_configuration "$proto" \
                            "$current_port" "$new_port" "$current_hop_spec"; then
                            sleep 2
                            return 1
                        fi
                    else
                        local -a port_operations=(
                            "protocol|closed|${current_port}|${proto_type}"
                            "protocol|open|${new_port}|${proto_type}")
                        local -a port_updates=("$port_var" "$new_port")
                        if ! apply_config_firewall_batch \
                            "修改 ${proto_name} 端口" preserve \
                            port_operations port_updates; then
                            sleep 2
                            return 1
                        fi
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
                if validate_node_port "$new_port" "$proto_type" "$port_var" 0; then
                    local -a enable_operations=() enable_updates=(
                        "$port_var" "$new_port" "$enabled_var" "true")
                    if { [ "$proto" = HY2 ] || [ "$proto" = TU5 ]; } && \
                       [ -n "$current_hop_spec" ]; then
                        enable_operations+=(
                            "hop|${proto}|${new_port}||${current_hop_spec}")
                    fi
                    enable_operations+=(
                        "protocol|open|${new_port}|${proto_type}")
                    if ! apply_config_firewall_batch "开启 ${proto_name}" \
                        ensure-running enable_operations enable_updates; then
                        sleep 2
                        return 1
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
        # ActiveState alone is not ownership: a third-party cloudflared unit
        # can be active beside a stale RR token.  Status, doctor, health,
        # update and restore callers may treat success as authority to skip the
        # strict start/migration path, so bind the observation to the exact
        # current RR unit and effective systemd identity first.
        rr_fixed_argo_service_is_owned || return 1
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

rr_stop_all_argo_tunnels_for_menu() {
    local retry=0 pid=""
    # A fixed-mode menu transaction must be side-effect free when the shared
    # service is absent, legacy or foreign.  Prove the current RR identity
    # before even cleaning up an RR quick-process remnant.
    if [ "${TUNNEL_MODE:-1}" = 2 ]; then
        rr_fixed_argo_service_is_owned || return 1
    fi
    stop_quick_argo_tunnel || return 1
    while [ "$retry" -lt 20 ] && quick_argo_running; do
        sleep 0.1
        retry=$((retry + 1))
    done
    if quick_argo_running; then
        while IFS= read -r pid; do
            kill -KILL "$pid" 2>/dev/null || true
        done < <(quick_argo_pids)
        sleep 0.1
    fi
    quick_argo_running && return 1
    if [ "${TUNNEL_MODE:-1}" = 2 ]; then
        # Re-prove ownership at the action point.  A service observed inactive
        # earlier may have been replaced and started by an administrator while
        # the surrounding menu transaction was preparing its other changes.
        # Legacy units are intentionally not stoppable until the strict start
        # path has migrated them to the current RR identity.
        rr_fixed_argo_service_is_owned || return 1
        systemctl stop cloudflared >/dev/null 2>&1 || return 1
        ! systemctl is-active --quiet cloudflared
    fi
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

    (
        rr_close_inherited_firewall_lock_fd || exit 1
        exec nohup cloudflared tunnel --url "http://127.0.0.1:${PORT}" \
            --edge-ip-version auto --protocol http2
    ) > "$log_file" 2>&1 &
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
    cp -f "$log_file" "$ARGO_LOG_FILE" 2>/dev/null || true
    chmod 600 "$ARGO_LOG_FILE" 2>/dev/null || true
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

rr_cloudflared_token_value_is_valid() {
    local value="${1:-}"
    [ -n "$value" ] && [ "${#value}" -le 4096 ] && \
        [[ "$value" =~ ^[A-Za-z0-9._~+/=-]+$ ]]
}

rr_cloudflared_directory_is_safe() {
    local directory="$1" required_mode="${2:-}" canonical="" metadata=""
    local owner="" group="" mode=""
    [[ "$directory" = /* && "$directory" != *[[:space:]]* ]] || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
    [ "$canonical" = "$directory" ] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
    IFS=: read -r owner group mode <<<"$metadata"
    [ "$owner:$group" = 0:0 ] || return 1
    if [ -n "$required_mode" ]; then
        [ "$mode" = "$required_mode" ] || return 1
    else
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
            [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    fi
}

rr_cloudflared_token_file_is_safe() {
    local token_file="${1:-${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}}"
    local token_dir="" canonical="" metadata="" value=""
    local owner="" group="" links="" mode="" size="" lines=""
    [[ "$token_file" = /* && "$token_file" != *[[:space:]]* ]] || return 1
    token_dir=$(dirname -- "$token_file") || return 1
    rr_cloudflared_directory_is_safe "$token_dir" 700 || return 1
    [ -f "$token_file" ] && [ ! -L "$token_file" ] || return 1
    canonical=$(readlink -f -- "$token_file" 2>/dev/null) || return 1
    [ "$canonical" = "$token_file" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$token_file" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<<"$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1 ] && \
        [ "$size" -le 4097 ] || return 1
    lines=$(wc -l < "$token_file" 2>/dev/null) || return 1
    [ "$lines" -eq 1 ] || return 1
    IFS= read -r value < "$token_file" || return 1
    rr_cloudflared_token_value_is_valid "$value" || return 1
    [ "$size" -eq $(( ${#value} + 1 )) ]
}

rr_cloudflared_binary_path() {
    local candidate="${1:-}" configured="${RR_CLOUDFLARED_BIN:-}"
    local configured_canonical="" canonical="" metadata=""
    local owner="" group="" mode="" links=""
    [ -n "$configured" ] || configured=$(command -v cloudflared 2>/dev/null) || return 1
    configured_canonical=$(readlink -f -- "$configured" 2>/dev/null) || return 1
    [ -n "$candidate" ] || candidate="$configured_canonical"
    canonical=$(readlink -f -- "$candidate" 2>/dev/null) || return 1
    [ "$canonical" = "$configured_canonical" ] && [ "$candidate" = "$canonical" ] || return 1
    [[ "$canonical" = /* && "$canonical" != *[[:space:]]* ]] || return 1
    [ -f "$canonical" ] && [ ! -L "$canonical" ] && [ -x "$canonical" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$canonical" 2>/dev/null) || return 1
    IFS=: read -r owner group mode links <<<"$metadata"
    [ "$owner:$group" = 0:0 ] && [[ "$links" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    printf '%s\n' "$canonical"
}

rr_cloudflared_preinstall_binary_path_is_expected() {
    local candidate="${1:-}" configured="${RR_CLOUDFLARED_BIN:-}"
    local discovered="" expected="" canonical=""
    [[ "$candidate" = /* && "$candidate" != *[[:space:]]* ]] || return 1
    canonical=$(readlink -f -- "$candidate" 2>/dev/null) || return 1
    # Current RR units always store the canonical executable path.  Requiring
    # the same shape before installation prevents an exact-looking unit from
    # redirecting authority to a different package or local executable.
    [ "$candidate" = "$canonical" ] || return 1
    if [ -n "$configured" ]; then
        [[ "$configured" = /* && "$configured" != *[[:space:]]* ]] || return 1
        expected=$(readlink -f -- "$configured" 2>/dev/null) || return 1
    else
        discovered=$(type -P cloudflared 2>/dev/null || true)
        if [ -n "$discovered" ]; then
            expected=$(readlink -f -- "$discovered" 2>/dev/null) || return 1
        else
            # The verified Debian package used by install_cloudflared owns this
            # path.  It is the only missing-binary identity that can be proven
            # before package installation when no explicit test/restore path
            # was configured.
            expected=/usr/bin/cloudflared
        fi
    fi
    [ "$candidate" = "$expected" ]
}

rr_render_fixed_argo_service() {
    local cloudflared_bin="$1"
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    cat <<EOF
[Unit]
Description=RR-vps Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=${token_file}

[Service]
Type=simple
DynamicUser=no
User=root
Group=root
LoadCredential=rr-tunnel-token:${token_file}
ExecStart=${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
UMask=0077
NoNewPrivileges=yes
PrivateUsers=no
PrivateMounts=no
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
}

rr_render_previous_fixed_argo_service() {
    # Exact 7.2 release-candidate shape retained only as a finite migration
    # source.  Its DynamicUser identity cannot observe the root-visible
    # firewall quarantine marker, so it is never considered runnable/current.
    local cloudflared_bin="$1"
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    cat <<EOF
[Unit]
Description=RR-vps Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
ConditionFileNotEmpty=${token_file}

[Service]
Type=simple
DynamicUser=yes
LoadCredential=rr-tunnel-token:${token_file}
ExecStart=${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token
Restart=on-failure
RestartSec=5s
TimeoutStopSec=30s
UMask=0077
NoNewPrivileges=yes
PrivateDevices=yes
PrivateTmp=yes
ProtectClock=yes
ProtectControlGroups=yes
ProtectHome=yes
ProtectKernelLogs=yes
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
}

rr_fixed_argo_service_exec_binary() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin=""
    cloudflared_bin=$(python3 - "$service_file" <<'PY'
import re
import sys

try:
    text = open(sys.argv[1], "rb").read().decode("ascii")
except (OSError, UnicodeDecodeError):
    raise SystemExit(1)
matches = re.findall(
    r"(?m)^ExecStart=(/[^\s]+) --no-autoupdate tunnel run "
    r"--token-file %d/rr-tunnel-token$",
    text,
)
if len(matches) != 1:
    raise SystemExit(1)
print(matches[0])
PY
    ) || return 1
    rr_cloudflared_preinstall_binary_path_is_expected "$cloudflared_bin" || return 1
    printf '%s\n' "$cloudflared_bin"
}

rr_fixed_argo_preinstall_service_binary() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin=""
    rr_cloudflared_token_file_is_safe || return 1
    rr_cloudflared_service_file_is_safe "$service_file" || return 1
    cloudflared_bin=$(rr_fixed_argo_service_exec_binary) || return 1
    cmp -s -- "$service_file" <(rr_render_fixed_argo_service "$cloudflared_bin") || return 1
    printf '%s\n' "$cloudflared_bin"
}

rr_previous_fixed_argo_preinstall_service_binary() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin=""
    rr_cloudflared_token_file_is_safe || return 1
    rr_cloudflared_service_file_is_safe "$service_file" || return 1
    cloudflared_bin=$(rr_fixed_argo_service_exec_binary) || return 1
    cmp -s -- "$service_file" \
        <(rr_render_previous_fixed_argo_service "$cloudflared_bin") || return 1
    printf '%s\n' "$cloudflared_bin"
}

rr_cloudflared_service_file_is_safe() {
    local service_file="${1:-${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}}"
    local allowed_modes="${2:-644}" service_dir="" canonical="" metadata=""
    local owner="" group="" links="" mode="" size=""
    [[ "$service_file" = /* && "$service_file" != *[[:space:]]* ]] || return 1
    service_dir=$(dirname -- "$service_file") || return 1
    rr_cloudflared_directory_is_safe "$service_dir" || return 1
    [ -f "$service_file" ] && [ ! -L "$service_file" ] || return 1
    canonical=$(readlink -f -- "$service_file" 2>/dev/null) || return 1
    [ "$canonical" = "$service_file" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$service_file" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<<"$metadata"
    [ "$owner:$group:$links" = 0:0:1 ] || return 1
    case " $allowed_modes " in *" $mode "*) ;; *) return 1 ;; esac
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ]
}

rr_cloudflared_show() {
    local property="$1"
    systemctl show --property="$property" --value cloudflared.service 2>/dev/null
}

rr_cloudflared_exec_record_is_exact() {
    local record="$1" expected_path="$2" expected_argv="$3"
    printf '%s\0%s\0%s\0' "$record" "$expected_path" "$expected_argv" | \
        python3 -c '
import sys

parts = sys.stdin.buffer.read().split(b"\0")
if len(parts) != 4 or parts[-1] != b"":
    raise SystemExit(1)
raw, expected_path, expected_argv = (part.decode("utf-8") for part in parts[:3])
if raw.count("{") != 1 or raw.count("}") != 1:
    raise SystemExit(1)
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < start or raw[:start].strip() or raw[end + 1:].strip():
    raise SystemExit(1)
fields = {}
for item in raw[start + 1:end].split(";"):
    item = item.strip()
    if not item:
        continue
    if "=" not in item:
        raise SystemExit(1)
    key, value = (part.strip() for part in item.split("=", 1))
    if key in fields:
        raise SystemExit(1)
    fields[key] = value
if (
    fields.get("path") != expected_path
    or fields.get("argv[]") != expected_argv
    or fields.get("ignore_errors") != "no"
):
    raise SystemExit(1)
'
}

rr_cloudflared_restore_gate_is_exact() {
    local dropin="$1" dropin_dir="" canonical="" expected_line=""
    local -a lines=()
    expected_line="ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'"
    dropin_dir=$(dirname -- "$dropin") || return 1
    rr_cloudflared_directory_is_safe "$dropin_dir" || return 1
    [ -f "$dropin" ] && [ ! -L "$dropin" ] || return 1
    canonical=$(readlink -f -- "$dropin" 2>/dev/null) || return 1
    [ "$canonical" = "$dropin" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$dropin" 2>/dev/null)" = 0:0:644:1 ] || return 1
    mapfile -t lines < "$dropin" || return 1
    [ "${#lines[@]}" -eq 2 ] && [ "${lines[0]}" = '[Service]' ] && \
        [ "${lines[1]}" = "$expected_line" ]
}

rr_cloudflared_effective_dropins_are_exact() {
    local dropins="" condition="" restore_dir="" restore_name="" restore_dropin=""
    local expected_argv=""
    dropins=$(rr_cloudflared_show DropInPaths) || return 1
    condition=$(rr_cloudflared_show ExecCondition) || return 1
    if [ -z "$dropins" ]; then
        [ -z "$condition" ]
        return
    fi
    restore_dir="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}"
    restore_name="${RR_RESTORE_GATE_DROPIN_NAME:-zzzz-rr-restore-gate.conf}"
    restore_dropin="${restore_dir}/cloudflared.service.d/${restore_name}"
    [ "$dropins" = "$restore_dropin" ] || return 1
    rr_cloudflared_restore_gate_is_exact "$restore_dropin" || return 1
    expected_argv='/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'
    rr_cloudflared_exec_record_is_exact "$condition" /bin/sh "$expected_argv"
}

rr_cloudflared_effective_identity_is_exact() {
    local expected_type="$1" expected_dynamic_user="$2" cloudflared_bin="$3"
    local expected_argv="$4" service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local load_state="" fragment="" exec_start="" value=""
    load_state=$(rr_cloudflared_show LoadState) || return 1
    fragment=$(rr_cloudflared_show FragmentPath) || return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$service_file" ] || return 1
    exec_start=$(rr_cloudflared_show ExecStart) || return 1
    rr_cloudflared_exec_record_is_exact "$exec_start" \
        "$cloudflared_bin" "$expected_argv" || return 1
    local property=""
    for property in ExecStartPre ExecStartPost ExecReload ExecStop ExecStopPost; do
        value=$(rr_cloudflared_show "$property") || return 1
        [ -z "$value" ] || return 1
    done
    value=$(rr_cloudflared_show Type) || return 1
    [ "$value" = "$expected_type" ] || return 1
    value=$(rr_cloudflared_show DynamicUser) || return 1
    [ "$value" = "$expected_dynamic_user" ] || return 1
    value=$(rr_cloudflared_show User) || return 1
    if [ "$expected_dynamic_user" = yes ]; then
        case "$value" in ""|cloudflared) ;; *) return 1 ;; esac
    else
        case "$value" in ""|root) ;; *) return 1 ;; esac
    fi
    value=$(rr_cloudflared_show Group) || return 1
    if [ "$expected_dynamic_user" = yes ]; then
        case "$value" in ""|cloudflared) ;; *) return 1 ;; esac
    else
        case "$value" in ""|root) ;; *) return 1 ;; esac
    fi
    value=$(rr_cloudflared_show WorkingDirectory) || return 1
    case "$value" in ""|/) ;; *) return 1 ;; esac
    value=$(rr_cloudflared_show PrivateNetwork) || return 1
    [ "$value" = no ] || return 1
    for property in PrivateUsers PrivateMounts; do
        value=$(rr_cloudflared_show "$property") || return 1
        [ "$value" = no ] || return 1
    done
    value=$(rr_cloudflared_show PrivateTmp) || return 1
    if [ "$expected_type" = simple ]; then
        [ "$value" = yes ] || return 1
    else
        [ "$value" = no ] || return 1
    fi
    value=$(rr_cloudflared_show ProtectHome) || return 1
    if [ "$expected_type" = simple ]; then
        [ "$value" = yes ] || return 1
    else
        [ "$value" = no ] || return 1
    fi
    value=$(rr_cloudflared_show ProtectSystem) || return 1
    if [ "$expected_type" = simple ]; then
        [ "$value" = strict ] || return 1
    else
        [ "$value" = no ] || return 1
    fi
    value=$(rr_cloudflared_show RootEphemeral) || return 1
    case "$value" in ""|no) ;; *) return 1 ;; esac
    # These effective properties can hide/remap the root-visible firewall
    # quarantine marker, inject executable state, or make its stat(2) probe
    # falsely report absence.  Exact unit bytes are insufficient because a
    # transient/runtime drop-in can change the compiled identity.
    for property in RootDirectory RootImage MountImages ExtensionImages \
        ExtensionDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths \
        InaccessiblePaths JoinsNamespaceOf ReadOnlyPaths ReadWritePaths \
        Environment EnvironmentFiles PassEnvironment PAMName; do
        value=$(rr_cloudflared_show "$property") || return 1
        [ -z "$value" ] || return 1
    done
    value=$(rr_cloudflared_show SystemCallFilter) || return 1
    [ "$value" = '~' ] || return 1
    # SystemCallErrorNumber's unset sentinel differs across systemd versions,
    # but it has no execution semantics while SystemCallFilter is the exact
    # default above.  The query must remain readable so an incomplete effective
    # view still fails shut.
    rr_cloudflared_show SystemCallErrorNumber >/dev/null || return 1
    rr_cloudflared_effective_dropins_are_exact
}

rr_fixed_argo_service_file_is_owned() {
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin=""
    rr_cloudflared_token_file_is_safe "$token_file" || return 1
    rr_cloudflared_service_file_is_safe "$service_file" || return 1
    cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
    cmp -s -- "$service_file" <(rr_render_fixed_argo_service "$cloudflared_bin")
}

rr_fixed_argo_service_is_owned() {
    local cloudflared_bin="" expected_argv=""
    rr_fixed_argo_service_file_is_owned || return 1
    cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
    expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
    rr_cloudflared_effective_identity_is_exact simple no \
        "$cloudflared_bin" "$expected_argv"
}

rr_previous_fixed_argo_service_file_is_owned() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin=""
    rr_cloudflared_token_file_is_safe || return 1
    rr_cloudflared_service_file_is_safe "$service_file" || return 1
    cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
    cmp -s -- "$service_file" \
        <(rr_render_previous_fixed_argo_service "$cloudflared_bin")
}

rr_previous_fixed_argo_service_is_exact() {
    local cloudflared_bin="" expected_argv=""
    rr_previous_fixed_argo_service_file_is_owned || return 1
    cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
    expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
    rr_cloudflared_effective_identity_is_exact simple yes \
        "$cloudflared_bin" "$expected_argv"
}

rr_cloudflared_effective_service_is_absent() {
    local load_state="" fragment="" dropins=""
    load_state=$(rr_cloudflared_show LoadState) || return 1
    fragment=$(rr_cloudflared_show FragmentPath) || return 1
    dropins=$(rr_cloudflared_show DropInPaths) || return 1
    [ "$load_state" = not-found ] && [ -z "$fragment" ] && [ -z "$dropins" ]
}

rr_cloudflared_service_is_absent() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    [ ! -e "$service_file" ] && [ ! -L "$service_file" ] || return 1
    rr_cloudflared_directory_is_safe "$(dirname -- "$service_file")" || return 1
    rr_cloudflared_effective_service_is_absent
}

rr_parse_legacy_cloudflared_service() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local legacy_token_file="${RR_LEGACY_CLOUDFLARED_TOKEN_FILE:-/etc/cloudflared/token}"
    [[ "$legacy_token_file" = /* && "$legacy_token_file" != *[[:space:]]* ]] || return 1
    # cloudflared requests 0644, but fresh RR 7.1 retained umask 077 while
    # invoking the upstream generator, producing a root-only 0600 unit.
    rr_cloudflared_service_file_is_safe "$service_file" '600 644' || return 1
    python3 - "$service_file" "$legacy_token_file" <<'PY'
import re
import sys

try:
    raw = open(sys.argv[1], "rb").read()
    text = raw.decode("ascii")
except (OSError, UnicodeDecodeError):
    raise SystemExit(1)
legacy_token_file = sys.argv[2]
common_prefix = (
    "[Unit]\n"
    "Description={description}\n"
    "After=network-online.target\n"
    "Wants=network-online.target\n\n"
    "[Service]\n"
    "TimeoutStartSec={timeout}\n"
    "Type=notify\n"
)
common_suffix = (
    "\nRestart=on-failure\n"
    "RestartSec=5s\n\n"
    "[Install]\n"
    "WantedBy=multi-user.target\n"
)
inline_shapes = {
    ("cloudflared", "0"),
    ("cloudflared", "15"),
    ("Cloudflare Tunnel client", "15"),
}
for description, timeout in inline_shapes:
    prefix = common_prefix.format(description=description, timeout=timeout)
    pattern = re.compile(
        re.escape(prefix)
        + r"ExecStart=(/[^\s]+) --no-autoupdate tunnel run --token ([A-Za-z0-9._~+/=\-]{1,4096})"
        + re.escape(common_suffix)
        + r"\Z"
    )
    match = pattern.fullmatch(text)
    if match is not None:
        print("inline")
        print(match.group(1))
        print(match.group(2))
        raise SystemExit(0)

# cloudflared 2026.7.3+ moved the dashboard token to this fixed root-only
# file.  RR 7.1.0 shipped while this was the upstream latest template.
prefix = common_prefix.format(
    description="Cloudflare Tunnel client", timeout="15"
)
pattern = re.compile(
    re.escape(prefix)
    + r"ExecStart=(/[^\s]+) --no-autoupdate tunnel run --token-file "
    + re.escape(legacy_token_file)
    + re.escape(common_suffix)
    + r"\Z"
)
match = pattern.fullmatch(text)
if match is None:
    raise SystemExit(1)
print("token-file")
print(match.group(1))
print(legacy_token_file)
PY
}

rr_cloudflared_legacy_token_file_is_safe() {
    local token_file="${1:-${RR_LEGACY_CLOUDFLARED_TOKEN_FILE:-/etc/cloudflared/token}}"
    local token_dir="" canonical="" metadata="" value="" size="" directory_mode=""
    [[ "$token_file" = /* && "$token_file" != *[[:space:]]* ]] || return 1
    token_dir=$(dirname -- "$token_file") || return 1
    rr_cloudflared_directory_is_safe "$token_dir" || return 1
    directory_mode=$(stat -c %a -- "$token_dir" 2>/dev/null) || return 1
    # Upstream requests 0755, but RR 7.1 intentionally retained umask 077
    # across installation, so its fresh cloudflared directory is 0700.
    case "$directory_mode" in 700|755) ;; *) return 1 ;; esac
    [ -f "$token_file" ] && [ ! -L "$token_file" ] || return 1
    canonical=$(readlink -f -- "$token_file" 2>/dev/null) || return 1
    [ "$canonical" = "$token_file" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$token_file" 2>/dev/null) || return 1
    [ "${metadata%:*}" = 0:0:1:600 ] || return 1
    size="${metadata##*:}"
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 4096 ] || return 1
    value=$(<"$token_file") || return 1
    rr_cloudflared_token_value_is_valid "$value" || return 1
    [ "$size" -eq "${#value}" ]
}

rr_cloudflared_effective_legacy_identity_is_exact() {
    local legacy_kind="$1" cloudflared_bin="$2" token="$3" expected_argv=""
    local legacy_token_file="${RR_LEGACY_CLOUDFLARED_TOKEN_FILE:-/etc/cloudflared/token}"
    local observed=""
    rr_cloudflared_token_value_is_valid "$token" || return 1
    case "$legacy_kind" in
        inline)
            expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token ${token}"
            ;;
        token-file)
            rr_cloudflared_legacy_token_file_is_safe "$legacy_token_file" || return 1
            observed=$(<"$legacy_token_file") || return 1
            [ "$observed" = "$token" ] || return 1
            expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file ${legacy_token_file}"
            ;;
        *) return 1 ;;
    esac
    rr_cloudflared_effective_identity_is_exact notify no \
        "$cloudflared_bin" "$expected_argv"
}

rr_cloudflared_effective_legacy_is_exact() {
    local legacy_kind="$1" cloudflared_bin="$2" token="$3"
    [ "$(rr_cloudflared_binary_path "$cloudflared_bin")" = "$cloudflared_bin" ] || return 1
    rr_cloudflared_effective_legacy_identity_is_exact \
        "$legacy_kind" "$cloudflared_bin" "$token"
}

rr_cloudflared_effective_legacy_any_is_exact() {
    local cloudflared_bin="$1" token="$2"
    rr_cloudflared_effective_legacy_is_exact \
        inline "$cloudflared_bin" "$token" || \
        rr_cloudflared_effective_legacy_is_exact \
            token-file "$cloudflared_bin" "$token"
}

rr_cloudflared_effective_legacy_identity_any_is_exact() {
    local cloudflared_bin="$1" token="$2"
    rr_cloudflared_effective_legacy_identity_is_exact \
        inline "$cloudflared_bin" "$token" || \
        rr_cloudflared_effective_legacy_identity_is_exact \
            token-file "$cloudflared_bin" "$token"
}

rr_cloudflared_service_token() {
    # RR 7.1 and earlier delegated service generation to cloudflared.  Accept
    # only the finite official systemd templates RR could have generated, plus
    # their exact effective identity; merely finding --token is not ownership.
    local fields="" legacy_kind="" cloudflared_bin="" token_or_file="" token=""
    local -a parsed=()
    fields=$(rr_parse_legacy_cloudflared_service) || return 1
    mapfile -t parsed <<<"$fields"
    [ "${#parsed[@]}" -eq 3 ] || return 1
    legacy_kind="${parsed[0]}"
    cloudflared_bin="${parsed[1]}"
    token_or_file="${parsed[2]}"
    case "$legacy_kind" in
        inline) token="$token_or_file" ;;
        token-file)
            [ "$token_or_file" = \
                "${RR_LEGACY_CLOUDFLARED_TOKEN_FILE:-/etc/cloudflared/token}" ] || return 1
            rr_cloudflared_legacy_token_file_is_safe "$token_or_file" || return 1
            token=$(<"$token_or_file") || return 1
            ;;
        *) return 1 ;;
    esac
    rr_cloudflared_token_value_is_valid "$token" || return 1
    rr_cloudflared_effective_legacy_is_exact \
        "$legacy_kind" "$cloudflared_bin" "$token" || return 1
    printf '%s\n' "$token"
}

rr_fixed_argo_start_classification() {
    # This classifier is deliberately read-only.  start_argo_tunnel must call
    # it before install_cloudflared because the verified installer still
    # downloads and invokes dpkg, mutating the executable shared by every
    # cloudflared service on the host.  Only a fully absent service, the exact
    # current RR identity (including its two staged reload boundaries), or the
    # finite RR 7.1 legacy identity may authorize that mutation.
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local desired_token="" fields="" legacy_kind="" cloudflared_bin=""
    local token_or_file="" legacy_token="" expected_argv=""
    local -a parsed=()

    if rr_cloudflared_service_is_absent; then
        rr_cloudflared_token_file_is_safe "$token_file" || return 1
        printf '%s\n' absent
        return 0
    fi

    if rr_cloudflared_token_file_is_safe "$token_file"; then
        IFS= read -r desired_token < "$token_file" || return 1
        rr_cloudflared_token_value_is_valid "$desired_token" || return 1
        if cloudflared_bin=$(rr_fixed_argo_preinstall_service_binary); then
            expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
            if rr_cloudflared_effective_identity_is_exact simple no \
                "$cloudflared_bin" "$expected_argv" || \
               rr_cloudflared_effective_service_is_absent || \
               rr_cloudflared_effective_identity_is_exact simple yes \
                "$cloudflared_bin" "$expected_argv" || \
               rr_cloudflared_effective_legacy_identity_any_is_exact \
                "$cloudflared_bin" "$desired_token"; then
                printf '%s\n' current
                return 0
            fi
            return 1
        fi
        if cloudflared_bin=$(rr_previous_fixed_argo_preinstall_service_binary); then
            expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
            rr_cloudflared_effective_identity_is_exact simple yes \
                "$cloudflared_bin" "$expected_argv" || return 1
            printf '%s\n' legacy
            return 0
        fi
    elif [ -e "$token_file" ] || [ -L "$token_file" ]; then
        return 1
    fi

    fields=$(rr_parse_legacy_cloudflared_service) || return 1
    mapfile -t parsed <<<"$fields"
    [ "${#parsed[@]}" -eq 3 ] || return 1
    legacy_kind="${parsed[0]}"
    cloudflared_bin="${parsed[1]}"
    token_or_file="${parsed[2]}"
    rr_cloudflared_preinstall_binary_path_is_expected "$cloudflared_bin" || return 1
    case "$legacy_kind" in
        inline)
            legacy_token="$token_or_file"
            ;;
        token-file)
            [ "$token_or_file" = \
                "${RR_LEGACY_CLOUDFLARED_TOKEN_FILE:-/etc/cloudflared/token}" ] || return 1
            rr_cloudflared_legacy_token_file_is_safe "$token_or_file" || return 1
            legacy_token=$(<"$token_or_file") || return 1
            ;;
        *) return 1 ;;
    esac
    rr_cloudflared_token_value_is_valid "$legacy_token" || return 1
    if [ -e "$token_file" ] || [ -L "$token_file" ]; then
        rr_cloudflared_token_file_is_safe "$token_file" || return 1
        IFS= read -r desired_token < "$token_file" || return 1
        [ "$desired_token" = "$legacy_token" ] || return 1
    fi
    rr_cloudflared_effective_legacy_identity_is_exact \
        "$legacy_kind" "$cloudflared_bin" "$legacy_token" || return 1
    printf '%s\n' legacy
}

rr_create_fixed_argo_token() {
    local desired_token="$1" token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local token_dir="" parent_dir="" temporary="" observed=""
    rr_cloudflared_token_value_is_valid "$desired_token" || return 1
    [ ! -e "$token_file" ] && [ ! -L "$token_file" ] || return 1
    [ "$(rr_cloudflared_service_token)" = "$desired_token" ] || return 1
    token_dir=$(dirname -- "$token_file") || return 1
    if [ ! -e "$token_dir" ] && [ ! -L "$token_dir" ]; then
        parent_dir=$(dirname -- "$token_dir") || return 1
        rr_cloudflared_directory_is_safe "$parent_dir" || return 1
        install -d -o 0 -g 0 -m 700 -- "$token_dir" || return 1
    fi
    rr_cloudflared_directory_is_safe "$token_dir" 700 || return 1
    [ "$(rr_cloudflared_service_token)" = "$desired_token" ] || return 1
    temporary=$(mktemp "$token_dir/.token.XXXXXX") || return 1
    if ! chown 0:0 -- "$temporary" || ! chmod 600 -- "$temporary" || \
       ! printf '%s\n' "$desired_token" > "$temporary" || \
       ! sync -f "$temporary" || \
       [ "$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null)" != 0:0:600:1 ] || \
       ! mv -T -- "$temporary" "$token_file"; then
        rm -f -- "$temporary"
        return 1
    fi
    sync -f "$token_dir" || return 1
    rr_cloudflared_token_file_is_safe "$token_file" || return 1
    IFS= read -r observed < "$token_file" || return 1
    [ "$observed" = "$desired_token" ]
}

rr_write_fixed_argo_service() {
    local authorized_state="${1:-}" expected_legacy_token="${2:-}"
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local service_dir="" service_tmp="" cloudflared_bin="" observed_token=""
    local expected_argv=""
    cloudflared_token_file_supported || return 1
    rr_cloudflared_token_file_is_safe || return 1
    service_dir=$(dirname -- "$service_file") || return 1
    rr_cloudflared_directory_is_safe "$service_dir" || return 1
    cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
    case "$authorized_state" in
        absent)
            rr_cloudflared_service_is_absent || return 1
            ;;
        current)
            # The exact current service needs no inode or timestamp churn.
            rr_fixed_argo_service_is_owned
            return
            ;;
        current-staged-absent)
            rr_fixed_argo_service_file_is_owned || return 1
            rr_cloudflared_effective_service_is_absent || return 1
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            rr_fixed_argo_service_is_owned
            return
            ;;
        current-staged-legacy)
            rr_cloudflared_token_value_is_valid "$expected_legacy_token" || return 1
            rr_fixed_argo_service_file_is_owned || return 1
            expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
            rr_cloudflared_effective_legacy_any_is_exact \
                "$cloudflared_bin" "$expected_legacy_token" || \
                rr_cloudflared_effective_identity_is_exact simple yes \
                    "$cloudflared_bin" "$expected_argv" || return 1
            systemctl daemon-reload >/dev/null 2>&1 || return 1
            rr_fixed_argo_service_is_owned
            return
            ;;
        previous-current)
            rr_cloudflared_token_value_is_valid "$expected_legacy_token" || return 1
            rr_previous_fixed_argo_service_is_exact || return 1
            ;;
        legacy)
            rr_cloudflared_token_value_is_valid "$expected_legacy_token" || return 1
            observed_token=$(rr_cloudflared_service_token) || return 1
            [ "$observed_token" = "$expected_legacy_token" ] || return 1
            ;;
        *) return 1 ;;
    esac
    service_tmp=$(mktemp "$service_dir/.cloudflared.service.XXXXXX") || return 1
    if ! rr_render_fixed_argo_service "$cloudflared_bin" > "$service_tmp" || \
       ! chown 0:0 -- "$service_tmp" || ! chmod 644 -- "$service_tmp" || \
       ! sync -f "$service_tmp" || \
       [ "$(stat -c '%u:%g:%a:%h' -- "$service_tmp" 2>/dev/null)" != 0:0:644:1 ] || \
       ! mv -T -- "$service_tmp" "$service_file"; then
        rm -f -- "$service_tmp"
        return 1
    fi
    sync -f "$service_dir" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    rr_fixed_argo_service_is_owned
}

ensure_fixed_argo_service() {
    local token_file="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local desired_token="" legacy_token="" authorized_state="" cloudflared_bin=""
    local expected_argv=""
    if [ -e "$token_file" ] || [ -L "$token_file" ]; then
        rr_cloudflared_token_file_is_safe "$token_file" || return 1
        IFS= read -r desired_token < "$token_file" || return 1
        rr_cloudflared_token_value_is_valid "$desired_token" || return 1
        if rr_cloudflared_service_is_absent; then
            authorized_state=absent
        elif rr_fixed_argo_service_is_owned; then
            authorized_state=current
        elif rr_fixed_argo_service_file_is_owned; then
            # Recover the two crash-safe publication boundaries: the exact RR
            # unit reached disk but systemd still has either no unit or the
            # strictly proven legacy unit with the same token in memory.
            if rr_cloudflared_effective_service_is_absent; then
                authorized_state=current-staged-absent
            else
                cloudflared_bin=$(rr_cloudflared_binary_path) || return 1
                expected_argv="${cloudflared_bin} --no-autoupdate tunnel run --token-file %d/rr-tunnel-token"
                rr_cloudflared_effective_legacy_any_is_exact \
                    "$cloudflared_bin" "$desired_token" || \
                    rr_cloudflared_effective_identity_is_exact simple yes \
                        "$cloudflared_bin" "$expected_argv" || return 1
                authorized_state=current-staged-legacy
            fi
        elif rr_previous_fixed_argo_service_is_exact; then
            # Migrate the finite DynamicUser release-candidate shape.  It is
            # exact RR evidence but cannot be reported healthy or stopped as
            # current because it cannot observe the root quarantine marker.
            authorized_state=previous-current
        elif legacy_token=$(rr_cloudflared_service_token) && \
             [ "$legacy_token" = "$desired_token" ]; then
            # This is the normal RR 7.1 installer shape: RR already persisted
            # the same token before cloudflared rendered its official unit.
            authorized_state=legacy
        else
            # A token mismatch or any non-exact unit is ambiguous.  Preserve
            # both byte-for-byte and require intervention.
            return 1
        fi
    else
        # One-time no-token migration.  The strict reader proves both the
        # official legacy bytes and systemd's effective service identity.
        desired_token=$(rr_cloudflared_service_token) || return 1
        rr_cloudflared_token_value_is_valid "$desired_token" || return 1
        authorized_state=legacy
        [ "$(rr_cloudflared_service_token)" = "$desired_token" ] || return 1
        rr_create_fixed_argo_token "$desired_token" || return 1
    fi
    rr_write_fixed_argo_service "$authorized_state" "$desired_token" || return 1
    # Re-prove the exact on-disk and effective identity immediately before the
    # only state-changing activation call.
    rr_fixed_argo_service_is_owned || return 1
    systemctl enable --now cloudflared >/dev/null 2>&1 || return 1
    systemctl is-active --quiet cloudflared
}

start_argo_tunnel() {
    local fixed_classification=""
    load_config_with_defaults || return 1
    if [ "$VM_ENABLED" = "false" ] || [ "$VM_TLS_ENABLED" = "true" ]; then
        stop_quick_argo_tunnel
        return 0
    fi
    if [ "${TUNNEL_MODE:-1}" = "2" ]; then
        # Classify the shared service before a missing/old binary can trigger
        # the downloader and dpkg.  Re-run the same read-only proof after the
        # installer, then let ensure_fixed_argo_service perform its own
        # action-point proofs before every token, unit and systemd mutation.
        fixed_classification=$(rr_fixed_argo_start_classification) || return 1
        case "$fixed_classification" in absent|current|legacy) ;; *) return 1 ;; esac
        install_cloudflared || return 1
        fixed_classification=$(rr_fixed_argo_start_classification) || return 1
        case "$fixed_classification" in absent|current|legacy) ;; *) return 1 ;; esac
        ensure_fixed_argo_service
    else
        install_cloudflared || return 1
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
        local -a vm_enable_operations=("protocol|open|${enable_port}|tcp")
        local -a vm_enable_updates=(
            PORT "$enable_port" VM_TLS_ENABLED true VM_ENABLED true)
        if ! apply_config_firewall_batch "开启 VMess TLS 直连" \
            ensure-running vm_enable_operations vm_enable_updates : \
            rr_stop_all_argo_tunnels_for_menu : \
            rr_stop_all_argo_tunnels_for_menu; then
            sleep 2
            return 1
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
                local -a argo_operations=("protocol|closed|${PORT}|tcp")
                local -a argo_updates=(VM_TLS_ENABLED false)
                if ! apply_config_firewall_batch "切换为 Argo 隧道模式" \
                    preserve argo_operations argo_updates : start_argo_tunnel \
                    rr_stop_all_argo_tunnels_for_menu \
                    rr_stop_all_argo_tunnels_for_menu; then
                    sleep 2
                    return 1
                fi
            else
                generate_certs_and_keys || return
                local -a tls_operations=("protocol|open|${PORT}|tcp")
                local -a tls_updates=(VM_TLS_ENABLED true)
                if ! apply_config_firewall_batch \
                    "切换为 Vmess TLS 直连模式" ensure-running \
                    tls_operations tls_updates : \
                    rr_stop_all_argo_tunnels_for_menu : \
                    rr_stop_all_argo_tunnels_for_menu; then
                    sleep 2
                    return 1
                fi
                # 依赖联动：TLS 直连模式下优选副节点（Argo CNAME）不生效，清理残留
                rm -f /tmp/sub_server/preferred_cnames.txt 2>/dev/null || true
                if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
                    echo -e "${YELLOW}[提示] 自动优选副节点仅在 Argo 模式生效，已清理当前副节点。${RESET}"
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
                elif [ "$VM_TLS_ENABLED" = "true" ]; then
                    local -a vm_port_operations=(
                        "protocol|closed|${old_port}|tcp"
                        "protocol|open|${new_port}|tcp")
                    local -a vm_port_updates=(PORT "$new_port")
                    if ! apply_config_firewall_batch \
                        "修改 Vmess 本地端口" preserve \
                        vm_port_operations vm_port_updates; then
                        sleep 2
                        return 1
                    fi
                elif ! apply_config_transaction \
                    "修改 Vmess 本地端口" "PORT" "$new_port"; then
                    sleep 2
                    return 1
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
                if apply_hop_main_port_configuration "$label" "$main_port" \
                    "$new_main" "$current_hop_spec"; then
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

rr_remove_hop_ports_locked() {
    local main_port="$1"
    local label="$2"
    local spec_list="$3"
    local command_name=""
    local spec=""
    local failed=false attempts=0
    local -a specs=()
    rr_firewall_writer_gate_is_held || return 1
    is_valid_port "$main_port" || return 0
    [ -n "$label" ] && [ -n "$spec_list" ] || return 0
    IFS=',' read -r -a specs <<< "$spec_list"

    for command_name in iptables ip6tables; do
        command -v "$command_name" >/dev/null 2>&1 || continue
        for spec in "${specs[@]}"; do
            attempts=0
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j REDIRECT \
                --to-ports "$main_port" >/dev/null 2>&1; do
                [ "$attempts" -lt 100 ] || { failed=true; break; }
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -m comment --comment "argo-rr-${label}" -j REDIRECT \
                    --to-ports "$main_port" >/dev/null 2>&1 || { failed=true; break; }
                attempts=$((attempts + 1))
            done
            # 兼容 6.0.0 之前使用 DNAT 的脚本规则，更新后只精确清理本脚本标签项。
            attempts=0
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j DNAT \
                --to-destination ":${main_port}" >/dev/null 2>&1; do
                [ "$attempts" -lt 100 ] || { failed=true; break; }
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -m comment --comment "argo-rr-${label}" -j DNAT \
                    --to-destination ":${main_port}" >/dev/null 2>&1 || { failed=true; break; }
                attempts=$((attempts + 1))
            done
            # Comment-free pre-6.0 tuples are part of the explicitly accepted
            # RR legacy namespace.  Remove every exact duplicate, even when a
            # tagged tuple also existed, so replacement verification cannot
            # leave a stale effective redirect behind.
            attempts=0
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1; do
                [ "$attempts" -lt 100 ] || { failed=true; break; }
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 || \
                    { failed=true; break; }
                attempts=$((attempts + 1))
            done
            attempts=0
            while "$command_name" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1; do
                [ "$attempts" -lt 100 ] || { failed=true; break; }
                "$command_name" -w 5 -t nat -D PREROUTING -p udp --dport "$spec" \
                    -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1 || \
                    { failed=true; break; }
                attempts=$((attempts + 1))
            done
        done
    done
    [ "$failed" = false ]
}

remove_hop_ports() {
    local main_port="$1" label="$2" spec_list="$3"
    local snapshot="" current="" current_tuple=""
    local failed=false tuple_seen=false mutation_started=false
    local stop_status=0 arm_status=0 finish_status=0
    is_valid_port "$main_port" || return 0
    [ -n "$label" ] && [ -n "$spec_list" ] || return 0
    is_valid_hop_spec "$spec_list" || return 1
    case "$label" in HY2|TU5) ;; *) return 1 ;; esac
    if rr_firewall_fail_closed_quarantine_active && \
       [ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" != 1 ]; then
        return 1
    fi
    rr_firewall_batch_is_active && return 1
    rr_firewall_lock_acquire || return 1
    if ! rr_firewall_persistence_backend_available; then
        printf '%s\n' '端口跳跃清理需要 netfilter 持久化后端；未修改 NAT 规则。' >&2
        if ! rr_firewall_lock_release; then
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃清理预检后的防火墙锁释放失败' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    snapshot=$(mktemp -d /tmp/rr-firewall-hop-remove.XXXXXX) || {
        if ! rr_firewall_lock_release; then
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃清理快照失败且防火墙锁释放失败' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    }
    chmod 700 "$snapshot" || failed=true
    if [ "$failed" = false ] && \
       ! rr_firewall_capture_hop_transaction "$snapshot" "$label" "$main_port" \
            "$spec_list"; then
        failed=true
    fi
    if [ "$failed" = false ]; then
        for current in "$snapshot"/*.nat.tuple; do
            [ -s "$current" ] && tuple_seen=true
        done
    fi
    if [ "$failed" = false ] && [ "$tuple_seen" = true ]; then
        if rr_firewall_inflight_begin_locked; then
            arm_status=0
        else
            arm_status=$?
            rm -rf "$snapshot"
            if [ "$arm_status" -ge 2 ]; then
                rr_firewall_inflight_is_owned && \
                    rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
                rr_firewall_lock_release || true
                rr_firewall_fail_closed_stop_nodes \
                    '端口跳跃清理在首个 writer 前无法证明持久隔离' || \
                    stop_status=$?
                return "$stop_status"
            fi
            rr_firewall_lock_release || return 1
            return 1
        fi
    fi
    if [ "$failed" = false ] && [ "$tuple_seen" = true ] && \
       ! rr_remove_hop_ports_locked "$main_port" "$label" "$spec_list"; then
        mutation_started=true
        failed=true
    elif [ "$failed" = false ] && [ "$tuple_seen" = true ]; then
        mutation_started=true
    fi
    current=""
    if [ "$failed" = false ] && [ "$tuple_seen" = true ]; then
        current=$(mktemp -d /tmp/rr-firewall-hop-remove.XXXXXX) || failed=true
        if [ "$failed" = false ] && \
           { ! rr_firewall_capture_hop_transaction "$current" "$label" \
                "$main_port" "$spec_list" || \
             ! rr_firewall_hop_transaction_seals_match "$snapshot" "$current"; }; then
            failed=true
        fi
        if [ "$failed" = false ]; then
            for current_tuple in "$current"/*.nat.tuple; do
                [ ! -s "$current_tuple" ] || failed=true
            done
        fi
    fi
    [ -z "$current" ] || rm -rf "$current"
    if [ "$failed" = true ]; then
        if [ "$mutation_started" = true ] && \
           ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
                "$main_port" "$spec_list"; then
            printf '%s\n' \
                '端口跳跃清理失败且 live 原态补偿失败；已进入持久隔离。' >&2
            rm -rf "$snapshot"
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃清理的 live 补偿无法证明' || stop_status=$?
            rr_firewall_lock_release || stop_status=3
            return "$stop_status"
        fi
        rm -rf "$snapshot"
        if rr_firewall_inflight_is_owned; then
            rr_firewall_inflight_finish_locked || finish_status=$?
            if [ "$finish_status" -ne 0 ]; then
                rr_firewall_lock_release || true
                rr_firewall_fail_closed_stop_nodes \
                    '端口跳跃清理补偿后无法安全清除 in-flight 隔离' || \
                    stop_status=$?
                return "$stop_status"
            fi
        fi
        if ! rr_firewall_lock_release; then
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃清理已补偿但防火墙锁释放失败' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    if [ "$tuple_seen" = true ] && ! save_firewall; then
        if ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
            "$main_port" "$spec_list"; then
            printf '%s\n' '端口跳跃持久化失败且 live 原态恢复失败；请立即人工检查。' >&2
            rm -rf "$snapshot"
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃首次持久化失败且 live 原态补偿失败' || stop_status=$?
            rr_firewall_lock_release || stop_status=3
            return "$stop_status"
        fi
        if ! save_firewall; then
            printf '%s\n' '端口跳跃原态二次持久化失败；请立即人工检查。' >&2
            rm -rf "$snapshot"
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃原态二次持久化失败' || stop_status=$?
            rr_firewall_lock_release || stop_status=3
            return "$stop_status"
        fi
        rm -rf "$snapshot"
        rr_firewall_inflight_finish_locked || finish_status=$?
        if [ "$finish_status" -ne 0 ]; then
            rr_firewall_lock_release || true
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃持久化补偿后无法安全清除 in-flight 隔离' || \
                stop_status=$?
            return "$stop_status"
        fi
        if ! rr_firewall_lock_release; then
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃持久化补偿完成但防火墙锁释放失败' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    rm -rf "$snapshot"
    if rr_firewall_inflight_is_owned; then
        rr_firewall_inflight_finish_locked || finish_status=$?
        if [ "$finish_status" -ne 0 ]; then
            rr_firewall_lock_release || true
            rr_firewall_fail_closed_stop_nodes \
                '端口跳跃清理提交后无法安全清除 in-flight 隔离' || \
                stop_status=$?
            return "$stop_status"
        fi
    fi
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '端口跳跃清理提交后防火墙锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return 0
}

add_hop_rule() {
    local command_name="$1"
    local spec="$2"
    local main_port="$3"
    local label="$4"
    rr_firewall_writer_gate_is_held || return 1
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

rr_install_hop_rules_locked() {
    local label="$1"
    local main_port="$2"
    local spec_list="$3"
    local spec=""
    local required_command=""
    local required_ok=true
    local -a specs=()
    rr_firewall_writer_gate_is_held || return 1
    rr_firewall_persistence_backend_available || return 1
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

rr_firewall_batch_replace_hop_rules() {
    local label="$1" main_port="$2" old_spec="$3" new_spec="$4"
    local all_specs="" snapshot="" current="" failed=false arm_status=0
    local ENTRY_IP_MODE="${ENTRY_IP_MODE:-auto}"
    rr_firewall_batch_is_active || return 1
    case "$label" in HY2|TU5) ;; *) return 1 ;; esac
    is_valid_port "$main_port" && is_valid_hop_spec "$old_spec" && \
        is_valid_hop_spec "$new_spec" || return 1
    [ "$old_spec" != "$new_spec" ] || return 0
    [ -n "$old_spec" ] || [ -n "$new_spec" ] || return 0
    rr_firewall_persistence_backend_available || {
        printf '%s\n' '端口跳跃替换需要 netfilter 持久化后端；未修改 NAT 规则。' >&2
        return 1
    }
    if [ "$ENTRY_IP_MODE" = auto ]; then
        if select_entry_ip >/dev/null 2>&1 && \
           is_ip_version "${ENTRY_IP_RAW:-}" 6; then
            ENTRY_IP_MODE=ipv6
        else
            ENTRY_IP_MODE=ipv4
        fi
    fi
    case "$ENTRY_IP_MODE" in ipv4|ipv6) ;; *) return 1 ;; esac
    if [ -n "$new_spec" ]; then
        declare -F rr_validate_hop_rules >/dev/null 2>&1 || return 1
        if ! rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
            "$new_spec" pre "$old_spec"; then
            printf '%s 端口跳跃替换与更早的 NAT 规则冲突；未修改规则。\n' \
                "$label" >&2
            return 1
        fi
    fi
    all_specs="$old_spec"
    if [ -n "$new_spec" ]; then
        [ -z "$all_specs" ] || all_specs+=,
        all_specs+="$new_spec"
    fi
    snapshot=$(mktemp -d "$RR_FIREWALL_BATCH_ROOT/hop-replace.XXXXXX") || return 1
    chmod 700 "$snapshot" || { rm -rf "$snapshot"; return 1; }
    if ! rr_firewall_capture_hop_transaction "$snapshot" "$label" \
        "$main_port" "$all_specs"; then
        rm -rf "$snapshot"
        return 1
    fi
    if rr_firewall_inflight_begin_locked; then
        arm_status=0
    else
        arm_status=$?
        rm -rf "$snapshot"
        [ "$arm_status" -ge 2 ] && return 2
        return 1
    fi
    if [ -n "$old_spec" ] && \
       ! rr_remove_hop_ports_locked "$main_port" "$label" "$old_spec"; then
        failed=true
    fi
    if [ "$failed" = false ] && [ -n "$new_spec" ] && \
       ! rr_install_hop_rules_locked "$label" "$main_port" "$new_spec"; then
        failed=true
    fi
    if [ "$failed" = false ] && [ -n "$new_spec" ] && \
       ! rr_validate_hop_rules "$label" "$main_port" "$new_spec"; then
        failed=true
    fi
    if [ "$failed" = false ] && [ -n "$new_spec" ] && \
       ! rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
            "$new_spec" post; then
        failed=true
    fi
    if [ "$failed" = false ]; then
        current=$(mktemp -d /tmp/rr-firewall-hop-replace.XXXXXX) || failed=true
        if [ "$failed" = false ] && \
           { ! rr_firewall_capture_hop_transaction "$current" "$label" \
                "$main_port" "$all_specs" || \
             ! rr_firewall_hop_transaction_seals_match "$snapshot" "$current" || \
             ! rr_firewall_hop_transaction_matches_specs "$current" "$new_spec"; }; then
            failed=true
        fi
        [ -z "$current" ] || rm -rf "$current"
        current=""
    fi
    if [ "$failed" = true ]; then
        if ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
            "$main_port" "$all_specs"; then
            printf '%s 端口跳跃替换失败且 live 原态补偿失败；请立即人工检查。\n' \
                "$label" >&2
            rm -rf "$snapshot"
            return 2
        fi
        rm -rf "$snapshot"
        return 1
    fi
    if ! rr_firewall_batch_record_hop "$snapshot" "$label" "$main_port" \
        "$all_specs"; then
        if ! rr_firewall_restore_hop_transaction "$snapshot" "$label" \
            "$main_port" "$all_specs"; then
            printf '%s 端口跳跃替换登记与补偿均失败；请立即人工检查。\n' \
                "$label" >&2
            rm -rf "$snapshot"
            return 2
        fi
        rm -rf "$snapshot"
        return 1
    fi
}

install_hop_rules() {
    local label="$1" main_port="$2" spec_list="$3"
    local operation_status=0 abort_status=0 commit_status=0 stop_status=0
    [ -z "$spec_list" ] && return 0
    # The batch owner publishes the v1 in-flight marker before its first NAT
    # writer.  Join that already-armed transaction before the public
    # quarantine guard below; the locked primitive independently requires the
    # owned writer gate, so an unrelated/orphan marker can never use this path.
    if rr_firewall_batch_is_active; then
        rr_install_hop_rules_locked "$label" "$main_port" "$spec_list"
        return $?
    fi
    if rr_firewall_fail_closed_quarantine_active && \
       [ "${RR_FIREWALL_QUARANTINE_REPAIR:-0}" != 1 ]; then
        printf '%s\n' \
            '防火墙持久隔离尚未修复；拒绝端口跳跃规则改写。' >&2
        return 1
    fi
    rr_firewall_batch_begin || return 1
    rr_firewall_batch_install_hop_rules "$label" "$main_port" "$spec_list" || \
        operation_status=$?
    if [ "$operation_status" -ne 0 ]; then
        rr_firewall_batch_abort || abort_status=$?
        if [ "$operation_status" -eq 2 ] || [ "$abort_status" -ne 0 ]; then
            rr_firewall_fail_closed_stop_nodes \
                "${label} 端口跳跃写入失败且无法证明 live 原态" || \
                stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    rr_firewall_batch_commit || commit_status=$?
    case "$commit_status" in
        0) return 0 ;;
        10) return 1 ;;
        11|12|*)
            rr_firewall_fail_closed_stop_nodes \
                "${label} 端口跳跃持久化状态不确定" || stop_status=$?
            return "$stop_status"
            ;;
    esac
}

# Menu operations must not publish a config/service change and then treat a
# failed firewall mutation as a warning.  Stage records are deliberately
# data-only so every caller shares the same lock, persistence preflight,
# compensation, and commit-status policy:
#   protocol|open|PORT|tcp
#   protocol|closed|PORT|udp
#   hop|HY2|MAIN_PORT|OLD_SPEC|NEW_SPEC
rr_firewall_preflight_stage_operations() {
    local operations_name="$1"
    local -n operations_ref="$operations_name"
    local record="" kind="" first="" second="" third="" fourth="" extra=""
    local filter_mode="" filter_mode_seen=false raw_required=false
    local hy2_new="" tu5_new="" hy2_seen=false tu5_seen=false

    for record in "${operations_ref[@]}"; do
        IFS='|' read -r kind first second third fourth extra <<< "$record"
        [ -z "$extra" ] || return 1
        case "$kind" in
            protocol)
                case "$first" in open|closed) ;; *) return 1 ;; esac
                is_valid_port "$second" || return 1
                case "$third" in tcp|udp) ;; *) return 1 ;; esac
                [ -z "$fourth" ] || return 1
                if [ "$filter_mode_seen" = false ]; then
                    rr_firewall_filter_authority_mode filter_mode || return 1
                    filter_mode_seen=true
                    case "$filter_mode" in
                        dual|netfilter) raw_required=true ;;
                        ufw) ;;
                        *) return 1 ;;
                    esac
                fi
                ;;
            hop)
                case "$first" in HY2|TU5) ;; *) return 1 ;; esac
                is_valid_port "$second" && is_valid_hop_spec "$third" && \
                    is_valid_hop_spec "$fourth" || return 1
                case "$first" in
                    HY2)
                        [ "$hy2_seen" = false ] || return 1
                        hy2_seen=true
                        hy2_new="$fourth"
                        ;;
                    TU5)
                        [ "$tu5_seen" = false ] || return 1
                        tu5_seen=true
                        tu5_new="$fourth"
                        ;;
                esac
                raw_required=true
                ;;
            *) return 1 ;;
        esac
    done

    if [ "$raw_required" = true ] && \
       ! rr_firewall_persistence_backend_available; then
        printf '%s\n' \
            '本次菜单操作需要持久化 raw/NAT 规则，但系统没有受支持的后端；未修改防火墙或配置。' >&2
        return 1
    fi
    if [ "$hy2_seen" = true ] && [ "$tu5_seen" = true ] && \
       [ -n "$hy2_new" ] && [ -n "$tu5_new" ] && \
       ! rr_firewall_hop_spec_lists_are_disjoint "$hy2_new" "$tu5_new"; then
        printf '%s\n' \
            'HY2 与 TU5 的目标跳跃范围重叠；未修改防火墙或配置。' >&2
        return 1
    fi

    # Prove every desired NAT program before the first UFW/netfilter writer.
    # The old spec is ignored only as the exact tuple being atomically
    # replaced; all other earlier PREROUTING rules remain blockers.
    for record in "${operations_ref[@]}"; do
        IFS='|' read -r kind first second third fourth extra <<< "$record"
        [ "$kind" = hop ] && [ -n "$fourth" ] || continue
        rr_firewall_hop_program_first_match_is_safe "$first" "$second" \
            "$fourth" pre "$third" || {
            printf '%s 目标跳跃范围被更早的 NAT 规则遮蔽；未修改防火墙或配置。\n' \
                "$first" >&2
            return 1
        }
    done
}

rr_firewall_future_config_value() {
    local key="$1" updates_name="$2" output_name="$3" index=0
    local -n updates_ref="$updates_name"
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && \
        [[ "$output_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    for ((index=0; index<${#updates_ref[@]}; index+=2)); do
        if [ "${updates_ref[index]}" = "$key" ]; then
            printf -v "$output_name" '%s' "${updates_ref[index + 1]}"
            return 0
        fi
    done
    printf -v "$output_name" '%s' "${!key-}"
}

rr_firewall_acme_http_tuple_needed_after_updates() {
    local updates_name="$1" enabled="" domain="" access_mode=""
    local nexus_mode="" nexus_domain="" nexus_certificate_mode=""
    local domain_is_ip=false
    rr_firewall_future_config_value NAIVE_ENABLED "$updates_name" enabled || \
        return 2
    rr_firewall_future_config_value NAIVE_DOMAIN "$updates_name" domain || \
        return 2
    if [ "$enabled" = true ]; then
        is_valid_domain "$domain" || return 2
        return 0
    fi
    rr_firewall_future_config_value SUB_ACCESS_MODE "$updates_name" \
        access_mode || return 2
    rr_firewall_future_config_value SUB_DOMAIN "$updates_name" domain || return 2
    if [ "$access_mode" = https ]; then
        is_valid_domain "$domain" || return 2
        return 0
    fi
    if [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ]; then
        nexus_mode=$(jq -r '.mode // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || \
            return 2
        case "$nexus_mode" in
            local) ;;
            public)
                nexus_domain=$(jq -r '.domain // empty' \
                    "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" \
                    2>/dev/null) || return 2
                is_ip_version "$nexus_domain" 4 && domain_is_ip=true
                is_ip_version "$nexus_domain" 6 && domain_is_ip=true
                if [ "$domain_is_ip" = true ]; then
                    nexus_certificate_mode=$(jq -r \
                        '.certificate_mode // "legacy-self-signed"' \
                        "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" \
                        2>/dev/null) || return 2
                    case "$nexus_certificate_mode" in
                        acme-ip-shortlived|pending-acme-ip)
                            is_global_ip_version "$nexus_domain" 4 || \
                                is_global_ip_version "$nexus_domain" 6 || return 2
                            return 0
                            ;;
                        legacy-self-signed) ;;
                        *) return 2 ;;
                    esac
                else
                    is_valid_domain "$nexus_domain" || return 2
                    return 0
                fi
                ;;
            *) return 2 ;;
        esac
    fi
    return 1
}

rr_firewall_protocol_tuple_needed_after_updates() {
    local proto_port="$1" proto_type="$2" updates_name="$3"
    local prefix="" enabled="" port="" mode="" access_mode=""
    local nexus_mode="" nexus_port=""
    is_valid_port "$proto_port" || return 2
    case "$proto_type" in tcp|udp) ;; *) return 2 ;; esac

    # RR never owns SSH reachability, but a legacy/shared protocol tuple must
    # not be converted to an RR DROP when it aliases the administrative port.
    if [ "$proto_type" = tcp ] && \
       [ "$proto_port" = "${SSH_PORT:-22}" ]; then
        return 0
    fi
    if [ "$proto_type" = tcp ] && [ "$proto_port" = 80 ]; then
        rr_firewall_acme_http_tuple_needed_after_updates "$updates_name"
        return $?
    fi

    for prefix in VL HY2 TU5 AN; do
        rr_firewall_future_config_value "${prefix}_ENABLED" "$updates_name" \
            enabled || return 2
        rr_firewall_future_config_value "${prefix}_PORT" "$updates_name" \
            port || return 2
        [ "$enabled" = true ] || continue
        case "$prefix" in VL|AN) mode=tcp ;; HY2|TU5) mode=udp ;; esac
        [ "$port" = "$proto_port" ] && [ "$mode" = "$proto_type" ] && return 0
    done

    rr_firewall_future_config_value VM_ENABLED "$updates_name" enabled || return 2
    rr_firewall_future_config_value VM_TLS_ENABLED "$updates_name" mode || return 2
    rr_firewall_future_config_value PORT "$updates_name" port || return 2
    if [ "$enabled" = true ] && [ "$mode" = true ] && \
       [ "$port" = "$proto_port" ] && [ "$proto_type" = tcp ]; then
        return 0
    fi

    rr_firewall_future_config_value NAIVE_ENABLED "$updates_name" enabled || return 2
    rr_firewall_future_config_value NAIVE_PORT "$updates_name" port || return 2
    rr_firewall_future_config_value NAIVE_MODE "$updates_name" mode || return 2
    if [ "$enabled" = true ] && [ "$port" = "$proto_port" ]; then
        case "${mode}:${proto_type}" in
            h2:tcp|h3:udp|both:tcp|both:udp) return 0 ;;
            h2:*|h3:*|both:*) ;;
            *) return 2 ;;
        esac
    fi

    rr_firewall_future_config_value SUB_ACCESS_MODE "$updates_name" \
        access_mode || return 2
    rr_firewall_future_config_value SUB_PORT "$updates_name" port || return 2
    if [ "$access_mode" = https ] && [ "$port" = "$proto_port" ] && \
       [ "$proto_type" = tcp ]; then
        return 0
    fi

    if [ -r "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ]; then
        nexus_mode=$(jq -r '.mode // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 2
        if [ "$nexus_mode" = public ]; then
            nexus_port=$(jq -r '.public_port // empty' \
                "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || return 2
            is_valid_port "$nexus_port" || return 2
            [ "$nexus_port" = "$proto_port" ] && [ "$proto_type" = tcp ] && return 0
        fi
    fi
    return 1
}

rr_firewall_normalize_stage_operations() {
    local input_name="$1" updates_name="$2" output_name="$3"
    local -n input_ref="$input_name"
    local -n output_ref="$output_name"
    local record="" kind="" first="" second="" third="" fourth="" extra=""
    local tuple="" desired_state="" tuple_port="" tuple_type="" needed_state=0
    local -a hop_records=() tuple_order=()
    local -A tuple_seen=() tuple_desired=()
    output_ref=()
    for record in "${input_ref[@]}"; do
        IFS='|' read -r kind first second third fourth extra <<< "$record"
        case "$kind" in
            hop) hop_records+=("$record") ;;
            protocol)
                tuple="${second}|${third}"
                if [ -z "${tuple_seen[$tuple]:-}" ]; then
                    tuple_seen["$tuple"]=1
                    tuple_order+=("$tuple")
                    tuple_desired["$tuple"]="$first"
                elif [ "$first" = open ]; then
                    tuple_desired["$tuple"]=open
                fi
                ;;
            *) return 1 ;;
        esac
    done
    # NAT validation and replacement always run before the first filter writer.
    output_ref+=("${hop_records[@]}")
    for tuple in "${tuple_order[@]}"; do
        IFS='|' read -r tuple_port tuple_type <<< "$tuple"
        desired_state="${tuple_desired[$tuple]}"
        if rr_firewall_protocol_tuple_needed_after_updates "$tuple_port" \
            "$tuple_type" "$updates_name"; then
            desired_state=open
        else
            needed_state=$?
            [ "$needed_state" -eq 1 ] || return 1
            # A stage vector may close an obsolete/shared tuple, but it may
            # never create a durable allow that no post-update RR consumer
            # authorizes.
            [ "$desired_state" = closed ] || return 1
        fi
        output_ref+=("protocol|${desired_state}|${tuple_port}|${tuple_type}")
    done
}

rr_firewall_apply_stage_operations() {
    local operations_name="$1"
    local -n operations_ref="$operations_name"
    local record="" kind="" first="" second="" third="" fourth="" extra=""
    local operation_status=0
    rr_firewall_batch_is_active || return 1
    for record in "${operations_ref[@]}"; do
        IFS='|' read -r kind first second third fourth extra <<< "$record"
        case "$kind" in
            protocol)
                case "$first" in
                    open)
                        open_protocol_firewall "$second" "$third" || \
                            operation_status=$?
                        ;;
                    closed)
                        close_protocol_firewall "$second" "$third" || \
                            operation_status=$?
                        ;;
                    *) return 1 ;;
                esac
                [ "$operation_status" -eq 0 ] || return "$operation_status"
                ;;
            hop)
                rr_firewall_batch_replace_hop_rules "$first" "$second" \
                    "$third" "$fourth" || operation_status=$?
                [ "$operation_status" -eq 0 ] || return "$operation_status"
                ;;
            *) return 1 ;;
        esac
    done
}

rr_firewall_run_menu_callback() {
    local callback="${1:-}"
    [ -n "$callback" ] && [ "$callback" != : ] || return 0
    [[ "$callback" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || return 1
    declare -F "$callback" >/dev/null 2>&1 || return 1
    "$callback"
}

rr_firewall_config_values_match() {
    local expected_name="$1" index=0 key="" expected=""
    local -n expected_ref="$expected_name"
    [ $(( ${#expected_ref[@]} % 2 )) -eq 0 ] || return 1
    load_config_with_defaults || return 1
    for ((index=0; index<${#expected_ref[@]}; index+=2)); do
        key="${expected_ref[index]}"
        expected="${expected_ref[index + 1]}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
        [ "${!key-}" = "$expected" ] || return 1
    done
}

rr_firewall_restore_menu_service_state() {
    local was_running="$1" subscription_was_running="$2" failed=false
    case "$was_running" in
        true)
            ensure_node_service_running >/dev/null 2>&1 || failed=true
            managed_singbox_running || failed=true
            ;;
        false)
            stop_singbox_instances >/dev/null 2>&1 || failed=true
            managed_singbox_running && failed=true
            ;;
        *) failed=true ;;
    esac
    case "$subscription_was_running" in
        true)
            start_subscription_server >/dev/null 2>&1 || failed=true
            subscription_server_running || failed=true
            ;;
        false)
            stop_subscription_servers >/dev/null 2>&1 || failed=true
            subscription_server_running && failed=true
            ;;
        *) failed=true ;;
    esac
    [ "$failed" = false ]
}

apply_config_firewall_batch() {
    local result=0 stop_status=0
    rr_firewall_lock_acquire || return 1
    apply_config_firewall_batch_locked "$@" || result=$?
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '菜单防火墙事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

apply_config_firewall_batch_locked() {
    local description="$1" service_policy="$2" operations_name="$3"
    local updates_name="$4" precommit_callback="${5:-:}"
    local success_callback="${6:-:}" cleanup_callback="${7:-:}"
    local indeterminate_cleanup_callback="${8:-$cleanup_callback}"
    local -n updates_ref="$updates_name"
    local -a old_updates=() normalized_operations=()
    local key="" value="" commit_status=0 stage_status=0
    local config_applied=false cleanup_failed=false rollback_failed=false
    local abort_failed=false readiness_failed=false
    local service_was_running=false subscription_was_running=false
    local service_restore_failed=false stop_status=0 quiesce_failed=false
    local inflight_finish_status=0
    local RR_FIREWALL_BATCH_DEFER_INFLIGHT_FINISH=1
    local -A captured_keys=()

    rr_firewall_lock_is_held || return 1
    if rr_firewall_fail_closed_quarantine_active; then
        printf '%s\n' \
            '防火墙持久隔离尚未修复；菜单不得改写配置或规则。' >&2
        return 1
    fi
    case "$service_policy" in ensure-running|preserve) ;; *) return 1 ;; esac
    [ $(( ${#updates_ref[@]} % 2 )) -eq 0 ] && \
        [ "${#updates_ref[@]}" -gt 0 ] || return 1
    load_config_with_defaults || return 1
    managed_singbox_running && service_was_running=true
    subscription_server_running && subscription_was_running=true
    while [ "${#updates_ref[@]}" -gt "${#old_updates[@]}" ]; do
        key="${updates_ref[${#old_updates[@]}]}"
        [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || return 1
        [ -z "${captured_keys[$key]:-}" ] || return 1
        captured_keys["$key"]=1
        value="${!key-}"
        old_updates+=("$key" "$value")
    done

    rr_firewall_normalize_stage_operations "$operations_name" "$updates_name" \
        normalized_operations || return 1
    rr_firewall_batch_begin || return 1
    rr_firewall_preflight_stage_operations normalized_operations || \
        stage_status=$?
    if [ "$stage_status" -eq 0 ]; then
        rr_firewall_apply_stage_operations normalized_operations || \
            stage_status=$?
    fi
    if [ "$stage_status" -ne 0 ]; then
        rr_firewall_batch_abort || abort_failed=true
        if [ "$stage_status" -ge 2 ] || [ "$abort_failed" = true ]; then
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_fail_closed_stop_nodes \
                '菜单防火墙预提交失败且 live 原态补偿失败' || stop_status=$?
            return "$stop_status"
        fi
        if rr_firewall_inflight_is_owned; then
            rr_firewall_inflight_finish_locked || inflight_finish_status=$?
            if [ "$inflight_finish_status" -ne 0 ]; then
                rr_firewall_fail_closed_stop_nodes \
                    '菜单防火墙预提交补偿后无法安全清除 in-flight 隔离' || \
                    stop_status=$?
                return "$stop_status"
            fi
        fi
        return 1
    fi
    if ! apply_config_transaction "$description" "${updates_ref[@]}"; then
        # apply_config_transaction promises its own rollback but has no
        # distinct "rollback incomplete" status.  Fail closed, compensate the
        # staged firewall, and independently prove every old key before
        # restoring the exact pre-menu service-running state.
        rr_firewall_quiesce_menu_runtimes || quiesce_failed=true
        rr_firewall_batch_abort || abort_failed=true
        rr_firewall_config_values_match old_updates || rollback_failed=true
        if [ "$abort_failed" = false ] && [ "$rollback_failed" = false ] && \
           [ "$quiesce_failed" = false ]; then
            if rr_firewall_inflight_is_owned; then
                rr_firewall_inflight_finish_locked || inflight_finish_status=$?
                [ "$inflight_finish_status" -eq 0 ] || service_restore_failed=true
            fi
        else
            service_restore_failed=true
        fi
        if [ "$service_restore_failed" = false ]; then
            rr_firewall_restore_menu_service_state "$service_was_running" \
                "$subscription_was_running" || \
                service_restore_failed=true
        fi
        if [ "$abort_failed" = true ] || [ "$rollback_failed" = true ] || \
           [ "$service_restore_failed" = true ]; then
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_fail_closed_stop_nodes \
                '配置提交失败且无法证明完整原态' || stop_status=$?
            return "$stop_status"
        fi
        return 1
    fi
    config_applied=true

    if rr_firewall_batch_commit; then commit_status=0; else commit_status=$?; fi
    case "$commit_status" in
        0)
            inflight_finish_status=0
            if rr_firewall_inflight_is_owned; then
                rr_firewall_inflight_finish_locked || inflight_finish_status=$?
            fi
            if [ "$inflight_finish_status" -ne 0 ]; then
                rr_firewall_batch_cleanup >/dev/null 2>&1 || true
                rr_firewall_fail_closed_stop_nodes \
                    '防火墙与配置已提交，但 in-flight 隔离无法安全解除' || \
                    stop_status=$?
                return "$stop_status"
            fi
            if [ "$service_policy" = ensure-running ] && \
               ! ensure_node_service_running; then
                readiness_failed=true
            fi
            if [ "$readiness_failed" = false ] && \
               ! rr_firewall_run_menu_callback "$precommit_callback"; then
                readiness_failed=true
            fi
            if [ "$readiness_failed" = true ]; then
                if ! rr_firewall_inflight_begin_locked; then
                    rollback_failed=true
                fi
                rr_firewall_run_menu_callback "$cleanup_callback" || \
                    cleanup_failed=true
                if [ "$rollback_failed" = false ] && \
                   ! apply_config_transaction "回滚 ${description}" \
                        "${old_updates[@]}" >/dev/null 2>&1; then
                    rollback_failed=true
                fi
                if [ "$rollback_failed" = false ] && \
                   ! rr_firewall_batch_rollback_operations; then
                    rollback_failed=true
                fi
                if [ "$rollback_failed" = false ] && \
                   [ "${RR_FIREWALL_BATCH_NEEDS_PERSIST:-false}" = true ] && \
                   ! save_firewall; then
                    rollback_failed=true
                fi
                rr_firewall_config_values_match old_updates || \
                    rollback_failed=true
                if [ "$rollback_failed" = false ] && \
                   [ "$cleanup_failed" = false ]; then
                    inflight_finish_status=0
                    rr_firewall_inflight_finish_locked || \
                        inflight_finish_status=$?
                    [ "$inflight_finish_status" -eq 0 ] || \
                        service_restore_failed=true
                else
                    service_restore_failed=true
                    rr_firewall_inflight_is_owned && \
                        rr_firewall_promote_inflight_locked \
                            >/dev/null 2>&1 || true
                fi
                rr_firewall_batch_cleanup || abort_failed=true
                if [ "$service_restore_failed" = false ] && \
                   [ "$abort_failed" = false ]; then
                    rr_firewall_restore_menu_service_state \
                        "$service_was_running" "$subscription_was_running" || \
                        service_restore_failed=true
                fi
                if [ "$cleanup_failed" = true ] || \
                   [ "$rollback_failed" = true ] || \
                   [ "$abort_failed" = true ] || \
                   [ "$service_restore_failed" = true ]; then
                    rr_firewall_fail_closed_stop_nodes \
                        '服务就绪检查失败且原态补偿不完整' || stop_status=$?
                    return "$stop_status"
                fi
                printf '%s\n' \
                    '[失败] 服务未就绪，防火墙与配置已恢复原态。' >&2
                return 1
            fi
            if ! rr_firewall_batch_cleanup; then
                rr_firewall_fail_closed_stop_nodes \
                    '防火墙与配置已提交，但批事务证据或锁清理失败' || \
                    stop_status=$?
                return "$stop_status"
            fi
            if ! rr_firewall_run_menu_callback "$success_callback"; then
                rr_firewall_run_menu_callback \
                    "$indeterminate_cleanup_callback" || true
                rr_firewall_fail_closed_stop_nodes \
                    '防火墙与配置已提交，但后置服务切换失败' || stop_status=$?
                return "$stop_status"
            fi
            return 0
            ;;
        10)
            quiesce_failed=false
            rr_firewall_quiesce_menu_runtimes || quiesce_failed=true
            rr_firewall_run_menu_callback "$cleanup_callback" || cleanup_failed=true
            if [ "$config_applied" = true ] && \
               ! apply_config_transaction "回滚 ${description}" \
                    "${old_updates[@]}" >/dev/null 2>&1; then
                rollback_failed=true
            fi
            rr_firewall_config_values_match old_updates || rollback_failed=true
            if [ "$rollback_failed" = false ] && \
               [ "$quiesce_failed" = false ] && [ "$cleanup_failed" = false ]; then
                inflight_finish_status=0
                if rr_firewall_inflight_is_owned; then
                    rr_firewall_inflight_finish_locked || inflight_finish_status=$?
                    [ "$inflight_finish_status" -eq 0 ] || \
                        service_restore_failed=true
                fi
            else
                service_restore_failed=true
                rr_firewall_inflight_is_owned && \
                    rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            fi
            rr_firewall_batch_cleanup || abort_failed=true
            if [ "$service_restore_failed" = false ] && \
               [ "$abort_failed" = false ]; then
                rr_firewall_restore_menu_service_state "$service_was_running" \
                    "$subscription_was_running" || \
                    service_restore_failed=true
            fi
            if [ "$cleanup_failed" = true ] || [ "$rollback_failed" = true ] || \
               [ "$abort_failed" = true ] || [ "$service_restore_failed" = true ]; then
                rr_firewall_inflight_is_owned && \
                    rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
                rr_firewall_fail_closed_stop_nodes \
                    '防火墙已恢复原态，但配置或外部服务补偿失败' || stop_status=$?
                return "$stop_status"
            else
                printf '%s\n' \
                    '[失败] 防火墙持久化失败，防火墙与配置已恢复原态。' >&2
            fi
            return 1
            ;;
        11|12|*)
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            rr_firewall_run_menu_callback \
                "$indeterminate_cleanup_callback" || true
            rr_firewall_fail_closed_stop_nodes \
                '防火墙提交状态不确定；已保留新配置' || stop_status=$?
            return "$stop_status"
            ;;
    esac
}

apply_hop_main_port_configuration() {
    local result=0 stop_status=0
    rr_firewall_lock_acquire || return 1
    apply_hop_main_port_configuration_locked "$@" || result=$?
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '主端口事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

apply_hop_main_port_configuration_locked() {
    local label="$1" old_port="$2" new_port="$3" old_spec="${4:-}"
    local expected_port=""
    local -a new_updates=() port_operations=()
    case "$label" in HY2|TU5) ;; *) return 1 ;; esac
    is_valid_port "$old_port" && is_valid_port "$new_port" && \
        [ "$old_port" != "$new_port" ] && is_valid_hop_spec "$old_spec" || return 1
    load_config_with_defaults || return 1
    case "$label" in
        HY2) expected_port="${HY2_PORT:-}" ;;
        TU5) expected_port="${TU5_PORT:-}" ;;
    esac
    [ "$expected_port" = "$old_port" ] || return 1
    new_updates=("${label}_PORT" "$new_port" "${label}_HOP_PORTS" "")
    [ -z "$old_spec" ] || port_operations+=(
        "hop|${label}|${old_port}|${old_spec}|")
    port_operations=(
        "${port_operations[@]}"
        "protocol|closed|${old_port}|udp"
        "protocol|open|${new_port}|udp")
    apply_config_firewall_batch_locked "修改 ${label} 主端口" preserve \
        port_operations new_updates || return $?
    echo -e "${GREEN}[成功] 主端口已修改为 ${new_port}，跳跃规则已清除，订阅已同步。${RESET}"
}

apply_hop_configuration() {
    local result=0 stop_status=0
    rr_firewall_lock_acquire || return 1
    apply_hop_configuration_locked "$@" || result=$?
    if ! rr_firewall_lock_release; then
        rr_firewall_fail_closed_stop_nodes \
            '端口跳跃事务锁释放失败' || stop_status=$?
        return "$stop_status"
    fi
    return "$result"
}

apply_hop_configuration_locked() {
    local label="$1"
    local main_port="$2"
    local new_spec="$3"
    local new_interval="$4"
    local key="${label}_HOP_PORTS"
    local old_spec=""
    local -a hop_updates=() hop_operations=()

    load_config_with_defaults || return 1
    old_spec=$(get_hop_ports "$main_port")
    is_valid_hop_spec "$new_spec" || return 1
    is_valid_hop_interval "$new_interval" || return 1
    validate_hop_spec_availability "$new_spec" "$main_port" || return 1
    hop_updates=("$key" "$new_spec")
    [ "$label" = "HY2" ] && hop_updates+=("HY2_HOP_INTERVAL" "$new_interval")

    # An interval-only change has no firewall mutation or raw persistence
    # requirement.  All spec replacements use one batch so the old tuples are
    # never durably removed before the new state and config are ready.
    [ "$old_spec" = "$new_spec" ] || hop_operations+=(
        "hop|${label}|${main_port}|${old_spec}|${new_spec}")
    apply_config_firewall_batch_locked "更新 ${label} 端口跳跃" preserve \
        hop_operations hop_updates || return $?
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
    local -a operations=()
    local -A allocated_tcp=()
    local -A allocated_udp=()
    local -A desired_ports=()
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
            desired_ports["$proto"]="$new_port"
        else
            desired_ports["$proto"]="$current_port"
        fi
        updates+=("$enabled_var" "true")
    done

    [ -z "$HY2_HOP_PORTS" ] || operations+=(
        "hop|HY2|${desired_ports[HY2]}||${HY2_HOP_PORTS}")
    [ -z "$TU5_HOP_PORTS" ] || operations+=(
        "hop|TU5|${desired_ports[TU5]}||${TU5_HOP_PORTS}")
    operations+=(
        "protocol|open|${desired_ports[VL]}|tcp"
        "protocol|open|${desired_ports[HY2]}|udp"
        "protocol|open|${desired_ports[TU5]}|udp"
        "protocol|open|${desired_ports[AN]}|tcp")
    if ! apply_config_firewall_batch "开启全部附加协议" ensure-running \
        operations updates; then
        sleep 2
        return 1
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
    local -a disable_all_operations=()
    local -a disable_all_updates=(
        VL_ENABLED false HY2_ENABLED false TU5_ENABLED false
        AN_ENABLED false NAIVE_ENABLED false)
    [ -z "$old_hy2_hops" ] || disable_all_operations+=(
        "hop|HY2|${old_hy2}|${old_hy2_hops}|")
    [ -z "$old_tu5_hops" ] || disable_all_operations+=(
        "hop|TU5|${old_tu5}|${old_tu5_hops}|")
    is_valid_port "$old_vl" && disable_all_operations+=(
        "protocol|closed|${old_vl}|tcp")
    is_valid_port "$old_hy2" && disable_all_operations+=(
        "protocol|closed|${old_hy2}|udp")
    is_valid_port "$old_tu5" && disable_all_operations+=(
        "protocol|closed|${old_tu5}|udp")
    is_valid_port "$old_an" && disable_all_operations+=(
        "protocol|closed|${old_an}|tcp")
    if is_valid_port "$NAIVE_PORT"; then
        disable_all_operations+=(
            "protocol|closed|${NAIVE_PORT}|tcp"
            "protocol|closed|${NAIVE_PORT}|udp")
    fi
    if ! apply_config_firewall_batch "关闭全部附加协议" preserve \
        disable_all_operations disable_all_updates; then
        sleep 2
        return 1
    fi
    sleep 2
}
