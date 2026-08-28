# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
sb_control_menu() {
    if [ ! -x "$SINGBOX_BIN" ]; then
        echo -e "${RED}Sing-box 核心未安装，请先执行选项 1${RESET}"
        sleep 2
        return
    fi

    while true; do
        clear
        load_config_with_defaults || return 1
        local sb_running="否"
        if [ -f /etc/systemd/system/sing-box.service ]; then
            if systemctl is-active --quiet sing-box; then
                sb_running="${GREEN}是（systemd 管理）${RESET}"
            elif managed_singbox_running; then
                sb_running="${RED}异常（发现脱离 systemd 的孤立进程）${RESET}"
            else
                sb_running="${RED}否${RESET}"
            fi
        elif managed_singbox_running; then
            sb_running="${GREEN}是（独立进程）${RESET}"
        else
            sb_running="${RED}否${RESET}"
        fi

        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              Sing-box 核心控制面板${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " 运行状态: $sb_running"
        echo -e " 版本信息: $("$SINGBOX_BIN" version 2>/dev/null | head -1)"
        echo -e " 配置路径: /etc/sing-box/config.json"
        echo -e " 自动拉起: $([ "$SINGBOX_AUTO_RESTART" = "true" ] && echo "${GREEN}开启${RESET}" || echo "${YELLOW}关闭${RESET}")"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "  ${PURPLE}1.${RESET} 启动 Sing-box"
        echo -e "  ${PURPLE}2.${RESET} 停止 Sing-box"
        echo -e "  ${PURPLE}3.${RESET} 重启 Sing-box"
        echo -e "  ${PURPLE}4.${RESET} 查看最近日志 (50行)"
        echo -e "  ${PURPLE}5.${RESET} 实时日志跟踪 (Ctrl+C 退出)"
        echo -e "  ${PURPLE}6.${RESET} 验证配置文件语法"
        echo -e "  ${PURPLE}7.${RESET} 检查并升级 Sing-box 最新正式版内核"
        echo -e "  ${PURPLE}8.${RESET} 切换自动检测/故障拉起"
        echo -e "  ${PURPLE}0.${RESET} 返回主菜单"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请选择操作 [0-8]: " sb_choice

        case "$sb_choice" in
            1)
                if [ -f /etc/systemd/system/sing-box.service ] && systemctl is-active --quiet sing-box; then
                    echo -e "${YELLOW}Sing-box 已由 systemd 正常管理并运行${RESET}"
                elif [ ! -f /etc/systemd/system/sing-box.service ] && managed_singbox_running; then
                    echo -e "${YELLOW}Sing-box 独立进程已在运行中${RESET}"
                elif ! "$SINGBOX_BIN" check -c /etc/sing-box/config.json 2>&1; then
                    echo -e "${RED}[失败] 配置文件校验未通过，未启动服务${RESET}"
                else
                    if restart_singbox; then
                        safe_sed SINGBOX_AUTO_RESTART true
                        echo -e "${GREEN}[成功] Sing-box 已启动${RESET}"
                    else
                        echo -e "${RED}[失败] Sing-box 启动失败，请选择 4 查看日志${RESET}"
                    fi
                fi
                sleep 2
                ;;
            2)
                if stop_singbox_instances; then
                    safe_sed SINGBOX_AUTO_RESTART false
                    systemctl reset-failed sing-box >/dev/null 2>&1 || true
                    echo -e "${GREEN}[成功] Sing-box 及孤立进程均已停止${RESET}"
                else
                    echo -e "${RED}[失败] 仍检测到 Sing-box 进程，请选择 4 查看详情${RESET}"
                fi
                sleep 2
                ;;
            3)
                if ! build_singbox_config; then
                    echo -e "${RED}[失败] 配置重建/校验失败，原配置与进程保持不变${RESET}"
                elif restart_singbox; then
                    safe_sed SINGBOX_AUTO_RESTART true
                    echo -e "${GREEN}[成功] Sing-box 已重启${RESET}"
                else
                    local rollback_ok=false
                    if [ -f /etc/sing-box/config.json.bak ]; then
                        cp -p /etc/sing-box/config.json.bak /etc/sing-box/config.json
                        restart_singbox >/dev/null 2>&1 && rollback_ok=true
                    fi
                    if [ "$rollback_ok" = true ]; then
                        echo -e "${RED}[失败] 新配置启动失败，已恢复并启动修改前配置${RESET}"
                    else
                        echo -e "${RED}[失败] Sing-box 重启失败，请选择 4 查看日志${RESET}"
                    fi
                fi
                sleep 2
                ;;
            4)
                clear
                echo -e "${YELLOW}最近 50 行日志:${RESET}"
                echo ""
                if [ -f /etc/systemd/system/sing-box.service ]; then
                    journalctl -u sing-box -n 50 --no-pager 2>/dev/null || echo "(systemd 日志不可用)"
                fi
                echo ""
                echo -e "${CYAN}配置文件验证:${RESET}"
                "$SINGBOX_BIN" check -c /etc/sing-box/config.json 2>&1 || true
                echo ""
                if { [ -f /etc/systemd/system/sing-box.service ] && systemctl is-active --quiet sing-box; } || \
                   managed_singbox_running; then
                    echo -e "${YELLOW}检测到 Sing-box 已在运行，为避免重复绑定端口，跳过第二实例启动测试。${RESET}"
                    managed_singbox_pids | while IFS= read -r managed_pid; do
                        ps -p "$managed_pid" -o pid=,args= 2>/dev/null || true
                    done
                else
                    echo -e "${CYAN}服务未运行，执行 3 秒前台启动测试:${RESET}"
                    timeout 3 "$SINGBOX_BIN" run -c /etc/sing-box/config.json 2>&1 || true
                fi
                echo ""
                read -p "按回车键返回..."
                ;;
            5)
                clear
                echo -e "${GREEN}实时日志 (Ctrl+C 退出):${RESET}"
                if [ -f /etc/systemd/system/sing-box.service ]; then
                    journalctl -u sing-box -f --no-pager 2>/dev/null
                else
                    echo "(systemd 不可用)"
                    read -p "按回车键返回..."
                fi
                ;;
            6)
                echo ""
                if "$SINGBOX_BIN" check -c /etc/sing-box/config.json 2>&1; then
                    echo -e "${GREEN}[通过] 配置文件语法正确${RESET}"
                else
                    echo -e "${RED}[失败] 配置文件有错误，详见上方输出${RESET}"
                fi
                echo ""
                read -p "按回车键返回..."
                ;;
            7)
                echo -e "${YELLOW}将下载最新正式版，先校验当前配置，启动失败会自动回滚旧内核。${RESET}"
                if install_singbox; then
                    generate_node_and_sub >/dev/null 2>&1 || true
                fi
                read -p "按回车键返回..."
                ;;
            8)
                if [ "$SINGBOX_AUTO_RESTART" = "true" ]; then
                    safe_sed SINGBOX_AUTO_RESTART false
                    echo -e "${YELLOW}已关闭 rr 启动时的自动拉起；systemd 崩溃恢复仍保留。${RESET}"
                else
                    safe_sed SINGBOX_AUTO_RESTART true
                    restart_singbox || true
                    echo -e "${GREEN}已开启自动检测与故障拉起。${RESET}"
                fi
                sleep 2
                ;;
            0) return ;;
            *) echo "输入无效"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 订阅端口独立管理
# ==========================================
set_subscription_bind_address() {
    local state_bind=""
    if [ "${SUB_ACCESS_MODE:-local}" = local ]; then
        SUB_BIND_ADDRESS="127.0.0.1"
        return 0
    fi
    if [ -f "$SUB_BIND_STATE_FILE" ]; then
        state_bind=$(awk -F'|' 'NF >= 2 {print $2; exit}' "$SUB_BIND_STATE_FILE" 2>/dev/null)
    fi

    case "${ENTRY_IP_MODE:-auto}" in
        ipv4) SUB_BIND_ADDRESS="0.0.0.0" ;;
        ipv6) SUB_BIND_ADDRESS="::" ;;
        *)
            if [ "$state_bind" = "0.0.0.0" ] || [ "$state_bind" = "::" ]; then
                SUB_BIND_ADDRESS="$state_bind"
            elif command -v ip >/dev/null 2>&1 && ip -4 route show default 2>/dev/null | grep -q .; then
                SUB_BIND_ADDRESS="0.0.0.0"
            else
                SUB_BIND_ADDRESS="::"
            fi
            ;;
    esac
}

apply_subscription_ports() {
    local new_local_port="$1"
    local new_ipv4_public_port="$2"
    local new_ipv6_public_port="$3"

    load_config_with_defaults || return 1
    local old_local_port="$SUB_PORT"
    local old_ipv4_public_port="$SUB_PUBLIC_PORT_IPV4"
    local old_ipv6_public_port="$SUB_PUBLIC_PORT_IPV6"

    if ! is_valid_port "$new_local_port" || \
       ! is_valid_port "$new_ipv4_public_port" || \
       ! is_valid_port "$new_ipv6_public_port"; then
        echo -e "${RED}[拒绝变更] 端口必须是 1-65535 的整数。${RESET}"
        return 1
    fi

    # 订阅服务是 TCP HTTP 服务，不能占用现有的 TCP 节点监听端口。
    local reserved_port=""
    for reserved_port in "$PORT" "$VL_PORT" "$AN_PORT"; do
        if [ -n "$reserved_port" ] && [ "$reserved_port" != "0" ] && [ "$new_local_port" = "$reserved_port" ]; then
            echo -e "${RED}[拒绝变更] 本地端口 $new_local_port 已分配给 TCP 节点，不能用于订阅服务。${RESET}"
            return 1
        fi
    done

    if [ "$new_local_port" != "$old_local_port" ] && tcp_port_in_use "$new_local_port"; then
        echo -e "${RED}[拒绝变更] 本地 TCP 端口 $new_local_port 已被其他程序占用。${RESET}"
        echo -e "${YELLOW}可执行：ss -lntp | grep ':${new_local_port}' 查看占用程序。${RESET}"
        return 1
    fi

    if [ "$new_local_port" = "$old_local_port" ] && \
       [ "$new_ipv4_public_port" = "$old_ipv4_public_port" ] && \
       [ "$new_ipv6_public_port" = "$old_ipv6_public_port" ]; then
        echo -e "${YELLOW}端口没有变化，无需修改。${RESET}"
        return 0
    fi

    if ! apply_config_transaction "修改订阅端口" \
        "SUB_PORT" "$new_local_port" \
        "SUB_PUBLIC_PORT_IPV4" "$new_ipv4_public_port" \
        "SUB_PUBLIC_PORT_IPV6" "$new_ipv6_public_port"; then
        return 1
    fi
    if [ "$new_local_port" != "$old_local_port" ]; then
        close_protocol_firewall "$old_local_port" tcp || return 1
        if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
            open_protocol_firewall "$new_local_port" tcp || return 1
        else
            # Secure local mode must remain unreachable off-host even after a
            # port change or an upgrade from the legacy public HTTP listener.
            close_protocol_firewall "$new_local_port" tcp || return 1
        fi
    fi

    echo -e "${GREEN}[同步] 订阅服务、订阅地址与全部配置文件已使用新端口。${RESET}"
    echo -e " 本地监听：${CYAN}${new_local_port}/TCP${RESET}"
    echo -e " IPv4 地址：${CYAN}${new_ipv4_public_port}/TCP${RESET}"
    echo -e " IPv6 地址：${CYAN}${new_ipv6_public_port}/TCP${RESET}"
    if [ "$new_local_port" != "$new_ipv4_public_port" ]; then
        echo -e " IPv4 NAT ：${YELLOW}公网 ${new_ipv4_public_port} → 本地 ${new_local_port}${RESET}"
    fi
}

subscription_port_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 1 进行安装！${RESET}"
        sleep 2
        return
    fi

    while true; do
        load_config_with_defaults || return 1
        clear
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              订阅端口独立管理${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
            echo -e " 访问模式：${GREEN}可信域名 HTTPS（${SUB_DOMAIN}）${RESET}"
            echo -e " 本地 HTTPS 监听端口：${YELLOW}${SUB_PORT}/TCP${RESET}"
            echo -e " IPv4 订阅公网端口：${YELLOW}${SUB_PUBLIC_PORT_IPV4}/TCP${RESET}"
            echo -e " IPv6 订阅公网端口：${YELLOW}${SUB_PUBLIC_PORT_IPV6}/TCP${RESET}"
        else
            echo -e " 访问模式：${YELLOW}仅本机 HTTP + SSH 隧道（不开放公网）${RESET}"
            echo -e " 回环监听端口：${YELLOW}${SUB_PORT}/TCP${RESET}"
            echo -e " 使用方式：${WHITE}ssh -N -L ${SUB_PORT}:127.0.0.1:${SUB_PORT} root@服务器${RESET}"
        fi
        if [ "$SUB_PORT" != "$SUB_PUBLIC_PORT_IPV4" ]; then
            echo -e " 当前 IPv4 NAT 映射：${GREEN}公网 ${SUB_PUBLIC_PORT_IPV4} → 本地 ${SUB_PORT}${RESET}"
        fi
        echo -e "${CYAN}---------------------------------------------------------------------------------${RESET}"
        echo -e "  ${PURPLE}1.${RESET} 普通服务器：本地、IPv4、IPv6 端口同时修改"
        echo -e "  ${PURPLE}2.${RESET} NAT 服务器：设置本地端口和 IPv4 公网映射端口"
        echo -e "  ${PURPLE}3.${RESET} 只修改本地/IPv6端口（IPv4 NAT 映射保持不变）"
        echo -e "  ${PURPLE}4.${RESET} 只修改 IPv4 订阅公网端口（本地服务不重启）"
        echo -e "  ${PURPLE}0.${RESET} 返回主菜单"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请选择 [0-4]: " sub_port_choice

        local new_local_port="$SUB_PORT"
        local new_ipv4_public_port="$SUB_PUBLIC_PORT_IPV4"
        local new_ipv6_public_port="$SUB_PUBLIC_PORT_IPV6"
        local input_port=""
        case "$sub_port_choice" in
            1)
                read -p "请输入新的订阅端口 (1-65535，回车取消): " input_port
                [ -z "$input_port" ] && continue
                new_local_port="$input_port"
                new_ipv4_public_port="$input_port"
                new_ipv6_public_port="$input_port"
                ;;
            2)
                echo -e "${YELLOW}请先在服务商面板建立 TCP 映射，例如：公网 52341 → 本地 18080。${RESET}"
                read -p "本地监听端口 (当前 $SUB_PORT，回车保持): " input_port
                if [ -n "$input_port" ]; then
                    new_local_port="$input_port"
                    # 独立 IPv6 没有 NAT，端口必须跟随本地监听端口。
                    new_ipv6_public_port="$input_port"
                fi
                read -p "IPv4 公网映射端口 (当前 $SUB_PUBLIC_PORT_IPV4，回车保持): " input_port
                [ -n "$input_port" ] && new_ipv4_public_port="$input_port"
                ;;
            3)
                read -p "请输入新的本地监听端口 (1-65535，回车取消): " input_port
                [ -z "$input_port" ] && continue
                new_local_port="$input_port"
                new_ipv6_public_port="$input_port"
                ;;
            4)
                read -p "请输入 IPv4 订阅使用的公网映射端口 (1-65535，回车取消): " input_port
                [ -z "$input_port" ] && continue
                new_ipv4_public_port="$input_port"
                ;;
            0) return ;;
            *) echo -e "${RED}输入无效，请重新选择。${RESET}"; sleep 1; continue ;;
        esac

        apply_subscription_ports "$new_local_port" "$new_ipv4_public_port" "$new_ipv6_public_port"
        read -p "按回车键继续..."
    done
}

# ==========================================
# IPv4 / IPv6 入口与出口管理
# ==========================================
apply_entry_address_override() {
    local family="$1"
    local new_address="$2"
    local key=""
    local old_address=""

    new_address=$(printf '%s' "$new_address" | tr -d '[:space:]')
    new_address="${new_address#[}"
    new_address="${new_address%]}"
    new_address="${new_address%%/*}"

    load_config_with_defaults || return 1
    case "$family" in
        4)
            key="ENTRY_IPV4_ADDRESS"
            old_address="$ENTRY_IPV4_ADDRESS"
            ;;
        6)
            key="ENTRY_IPV6_ADDRESS"
            old_address="$ENTRY_IPV6_ADDRESS"
            ;;
        *) return 1 ;;
    esac

    if [ -n "$new_address" ] && ! is_global_ip_version "$new_address" "$family"; then
        echo -e "${RED}[拒绝变更] 请输入有效的公网 IPv${family} 地址，不能填写内网或保留地址。${RESET}"
        return 1
    fi
    if [ "$new_address" = "$old_address" ]; then
        echo -e "${YELLOW}地址没有变化，无需修改。${RESET}"
        return 0
    fi

    if ! apply_config_transaction "更新 IPv${family} 公网入口地址" "$key" "$new_address"; then
        return 1
    fi
    if [ -n "$new_address" ]; then
        echo -e "${GREEN}[成功] IPv${family} 公网入口地址已设为：${new_address}${RESET}"
        if { [ "$family" = "6" ] && [ "$ENTRY_IP_MODE" != "ipv6" ]; } || \
           { [ "$family" = "4" ] && [ "$ENTRY_IP_MODE" != "ipv4" ]; }; then
            echo -e "${YELLOW}[提示] 地址已保存；若要订阅立即选用它，请在菜单 12 → 1 切换对应入口族。${RESET}"
        fi
    else
        echo -e "${GREEN}[成功] 已清除 IPv${family} 手动入口地址，恢复自动检测。${RESET}"
    fi
    echo -e "${CYAN}服务端仍监听通配地址，不会把 LXD 容器绑定到不存在的公网地址。${RESET}"
}

entry_address_menu() {
    while true; do
        load_config_with_defaults || return 1
        detect_public_ips
        clear
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              公网入口地址管理（LXD / NAT 专用）${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " IPv4 手动入口：${YELLOW}${ENTRY_IPV4_ADDRESS:-未设置}${RESET}"
        echo -e " IPv6 手动入口：${YELLOW}${ENTRY_IPV6_ADDRESS:-未设置}${RESET}"
        echo -e " IPv6 网卡公网：${GREEN}${LOCAL_IPV6_GLOBAL:-未检测到}${RESET}"
        echo -e " IPv6 容器内网：${YELLOW}${LOCAL_IPV6_ULA:-未检测到}${RESET}"
        echo -e " IPv6 外出地址：${CYAN}${EGRESS_IPV6:-未检测到}${RESET}（不能在 LXD/NAT66 环境中当作入站地址）"
        echo -e "${CYAN}---------------------------------------------------------------------------------${RESET}"
        echo -e "  ${PURPLE}1.${RESET} 设置 IPv4 公网入口地址"
        echo -e "  ${PURPLE}2.${RESET} 设置 IPv6 公网入口地址（服务商面板绑定地址）"
        echo -e "  ${PURPLE}3.${RESET} 清除 IPv4 手动入口地址"
        echo -e "  ${PURPLE}4.${RESET} 清除 IPv6 手动入口地址"
        echo -e "  ${PURPLE}0.${RESET} 返回"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请选择 [0-4]: " address_choice
        local input_address=""
        case "$address_choice" in
            1)
                read -p "请输入服务商面板显示的公网 IPv4: " input_address
                [ -n "$input_address" ] && apply_entry_address_override 4 "$input_address"
                ;;
            2)
                read -p "请输入服务商面板绑定的公网 IPv6（不要填 fd00/fd42 内网地址）: " input_address
                [ -n "$input_address" ] && apply_entry_address_override 6 "$input_address"
                ;;
            3) apply_entry_address_override 4 "" ;;
            4) apply_entry_address_override 6 "" ;;
            0) return ;;
            *) echo -e "${RED}输入无效。${RESET}" ;;
        esac
        read -p "按回车键继续..."
    done
}

apply_ip_preferences() {
    local new_entry="$1"
    local new_outbound="$2"

    case "$new_entry" in
        auto|ipv4|ipv6) ;;
        *) echo -e "${RED}入口模式参数无效。${RESET}"; return 1 ;;
    esac
    case "$new_outbound" in
        auto|prefer_ipv4|prefer_ipv6|ipv4_only|ipv6_only) ;;
        *) echo -e "${RED}出口模式参数无效。${RESET}"; return 1 ;;
    esac

    detect_public_ips
    if [ "$new_entry" = "ipv4" ] && [ -z "$PUBLIC_IPV4" ]; then
        echo -e "${RED}[拒绝变更] 当前未检测到公网 IPv4。${RESET}"
        return 1
    fi
    if [ "$new_entry" = "ipv6" ] && [ -z "$PUBLIC_IPV6" ]; then
        if [ "$IPV6_NAT66_DETECTED" = true ]; then
            echo -e "${RED}[拒绝变更] 检测到 LXD/NAT66，${EGRESS_IPV6:-未知} 只是宿主机出口 IPv6。${RESET}"
            echo -e "${YELLOW}请先进入 12 → 6，填写服务商面板绑定的公网 IPv6。${RESET}"
        else
            echo -e "${RED}[拒绝变更] 当前未检测到公网 IPv6。${RESET}"
        fi
        return 1
    fi
    if [[ "$new_outbound" =~ ^(prefer_ipv4|ipv4_only)$ ]] && [ -z "$EGRESS_IPV4" ]; then
        echo -e "${RED}[拒绝变更] 当前未检测到可用 IPv4 出口。${RESET}"
        return 1
    fi
    if [[ "$new_outbound" =~ ^(prefer_ipv6|ipv6_only)$ ]] && [ -z "$EGRESS_IPV6" ]; then
        echo -e "${RED}[拒绝变更] 当前未检测到可用 IPv6 出口。${RESET}"
        return 1
    fi

    local core_version=""
    core_version=$(get_singbox_version)
    if [ -z "$core_version" ]; then
        echo -e "${RED}[拒绝变更] 无法读取 sing-box 内核版本。${RESET}"
        return 1
    fi

    if ! apply_config_transaction "切换 IPv4/IPv6 入口与出口模式" \
        "ENTRY_IP_MODE" "$new_entry" "OUTBOUND_IP_MODE" "$new_outbound"; then
        return 1
    fi

    load_config_with_defaults || return 1
    echo -e "  入口：${CYAN}$(entry_mode_label "$ENTRY_IP_MODE")${RESET}"
    echo -e "  出口：${CYAN}$(outbound_mode_label "$OUTBOUND_IP_MODE")${RESET}"
    echo -e "  内核：${CYAN}${core_version}${RESET}"
}

ip_stack_menu() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 1 进行安装！${RESET}"
        sleep 2
        return
    fi
    if [ ! -x "$SINGBOX_BIN" ]; then
        echo -e "${RED}Sing-box 核心未安装，无法设置。${RESET}"
        sleep 2
        return
    fi

    while true; do
        load_config_with_defaults || return 1
        detect_public_ips
        local show_v4="${PUBLIC_IPV4:-未检测到}"
        local show_v6="${PUBLIC_IPV6:-未设置入站地址}"
        local core_version=""
        core_version=$(get_singbox_version)

        clear
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e "${PURPLE}              IPv4 / IPv6 入口与出口管理${RESET}"
        echo -e "${CYAN}=================================================================================${RESET}"
        echo -e " IPv4 入站: ${GREEN}${show_v4}${RESET} (${IPV4_ENTRY_SOURCE})"
        echo -e " IPv6 入站: ${GREEN}${show_v6}${RESET} (${IPV6_ENTRY_SOURCE})"
        echo -e " IPv6 出口: ${CYAN}${EGRESS_IPV6:-未检测到}${RESET}"
        [ -n "$LOCAL_IPV6_ULA" ] && echo -e " 容器 IPv6: ${YELLOW}${LOCAL_IPV6_ULA}${RESET} (ULA内网)"
        echo -e " Sing-box : ${GREEN}${core_version:-未知}${RESET}"
        echo -e " 当前入口 : ${YELLOW}$(entry_mode_label "$ENTRY_IP_MODE")${RESET}"
        echo -e " 当前出口 : ${YELLOW}$(outbound_mode_label "$OUTBOUND_IP_MODE")${RESET}"
        echo -e "${CYAN}---------------------------------------------------------------------------------${RESET}"
        echo -e " 入口决定直连节点/订阅写入哪个公网 IP；出口决定代理流量从哪种地址族访问目标。"
        echo -e " Argo 节点仍由 Cloudflare 域名接入，但其代理流量的服务器出口同样受出口设置控制。"
        echo -e "${CYAN}---------------------------------------------------------------------------------${RESET}"
        echo -e "  ${PURPLE}1.${RESET} 单独设置入口 IP（自动 / IPv4 / IPv6）"
        echo -e "  ${PURPLE}2.${RESET} 单独设置出口 IP（自动 / 优先 / 仅用）"
        echo -e "  ${PURPLE}3.${RESET} ${RED}严格 IPv6：IPv6 入口 + 仅 IPv6 出口（IPv4目标会断网）${RESET}"
        echo -e "  ${PURPLE}4.${RESET} 一键 IPv4：IPv4 入口 + 仅 IPv4 出口"
        echo -e "  ${PURPLE}5.${RESET} 恢复兼容默认：自动入口 + 系统自动出口"
        echo -e "  ${PURPLE}6.${RESET} 设置公网入口地址（LXD / NAT66 必用）"
        echo -e "  ${PURPLE}7.${RESET} ${GREEN}LXD推荐：IPv6入口 + IPv6优先、IPv4回退${RESET}"
        echo -e "  ${PURPLE}0.${RESET} 返回主菜单"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请选择 [0-7]: " ip_choice

        case "$ip_choice" in
            1)
                echo -e "\n  1. 自动入口（双栈时保持原脚本的 IPv4 配置输出）"
                echo -e "  2. 仅 IPv4 入口"
                echo -e "  3. 仅 IPv6 入口"
                echo -e "  0. 取消"
                read -p "请选择 [0-3]: " entry_choice
                case "$entry_choice" in
                    1) apply_ip_preferences "auto" "$OUTBOUND_IP_MODE" ;;
                    2) apply_ip_preferences "ipv4" "$OUTBOUND_IP_MODE" ;;
                    3) apply_ip_preferences "ipv6" "$OUTBOUND_IP_MODE" ;;
                    0) continue ;;
                    *) echo -e "${RED}输入无效${RESET}" ;;
                esac
                read -p "按回车键继续..."
                ;;
            2)
                echo -e "\n  1. 系统自动出口（原脚本行为）"
                echo -e "  2. IPv4 优先，失败回退 IPv6"
                echo -e "  3. IPv6 优先，失败回退 IPv4"
                echo -e "  4. 仅 IPv4 出口（拒绝 IPv6 目标）"
                echo -e "  5. 仅 IPv6 出口（拒绝 IPv4 目标）"
                echo -e "  0. 取消"
                read -p "请选择 [0-5]: " outbound_choice
                case "$outbound_choice" in
                    1) apply_ip_preferences "$ENTRY_IP_MODE" "auto" ;;
                    2) apply_ip_preferences "$ENTRY_IP_MODE" "prefer_ipv4" ;;
                    3) apply_ip_preferences "$ENTRY_IP_MODE" "prefer_ipv6" ;;
                    4) apply_ip_preferences "$ENTRY_IP_MODE" "ipv4_only" ;;
                    5) apply_ip_preferences "$ENTRY_IP_MODE" "ipv6_only" ;;
                    0) continue ;;
                    *) echo -e "${RED}输入无效${RESET}" ;;
                esac
                read -p "按回车键继续..."
                ;;
            3)
                echo -e "${RED}警告：严格仅 IPv6 会拒绝客户端传来的所有 IPv4 目标，可能出现节点可达但应用断网。${RESET}"
                read -p "确认启用严格模式？请输入 YES: " strict_confirm
                [ "$strict_confirm" = "YES" ] && apply_ip_preferences "ipv6" "ipv6_only"
                read -p "按回车键继续..."
                ;;
            4) apply_ip_preferences "ipv4" "ipv4_only"; read -p "按回车键继续..." ;;
            5) apply_ip_preferences "auto" "auto"; read -p "按回车键继续..." ;;
            6) entry_address_menu ;;
            7) apply_ip_preferences "ipv6" "prefer_ipv6"; read -p "按回车键继续..." ;;
            0) return ;;
            *) echo -e "${RED}输入无效，请重新选择${RESET}"; sleep 1 ;;
        esac
    done
}

# ==========================================
# 14. 终极主面板逻辑
# ==========================================
main_menu() {
    ensure_runtime_health
    while true; do
        check_update

        clear
        check_status

        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo -e "${PURPLE}       ░██████╗  ░██████╗ ${RESET}"
        echo -e "${PURPLE}       ░██╔══██╗ ░██╔══██╗${RESET}"
        echo -e "${PURPLE}       ░██████╔╝ ░██████╔╝${RESET}"
        echo -e "${PURPLE}       ░██╔══██╗ ░██╔══██╗${RESET}"
        echo -e "${PURPLE}       ░██║  ░██║░██║  ░██║${RESET}"
        echo -e "${PURPLE}       ░╚═╝  ░╚═╝░╚═╝  ░╚═╝${RESET}"
        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo -e " ${WHITE}RR-vps 多协议管理脚本 v${SCRIPT_VERSION}${RESET}"
        if [ -f "$CONFIG_FILE" ]; then
            echo -e " 面板状态: ${GREEN}已安装${RESET}  |  Sing-box: $SB_STATUS  |  Argo隧道: $CF_STATUS  |  自动优选: $AUTO_STATUS  |  脚本版本: $SCRIPT_VER_STATUS"
            echo -e " IP模式  : ${CYAN}${IP_ENTRY_STATUS}${RESET}  |  ${CYAN}${IP_OUTBOUND_STATUS}${RESET}"
            if command -v nexus_panel_url >/dev/null 2>&1 && nexus_is_installed 2>/dev/null; then
                local nexus_addr=""
                nexus_addr=$(nexus_panel_url 2>/dev/null) || true
                if [ -n "$nexus_addr" ]; then
                    echo -e " RR Nexus · 星枢管理面板地址: ${CYAN}${nexus_addr}${RESET}"
                fi
            fi
            if [ "${VM_ENABLED:-true}" != "false" ] && [ "${PORT:-0}" = "443" ] && [ "${VM_TLS_ENABLED:-false}" != "true" ]; then
                echo -e " ${YELLOW}兼容提示：旧配置仍在 127.0.0.1:443 运行；可到 9 → 5 → 2 无损改为其他本地端口。${RESET}"
            fi
        else
            echo -e " 面板状态: ${RED}未安装 (请选择 1 进行安装)${RESET}"
        fi
        if [ "$UPDATE_AVAILABLE" = true ]; then
            echo -e " ${YELLOW}═════════════════════════════════════════════════════════════════════════════════${RESET}"
            echo -e " ${RED}⚠  发现新版本！${RESET} 远程脚本已有更新，请选择 ${CYAN}8${RESET} 进行升级（配置信息不受影响）"
            echo -e " ${YELLOW}═════════════════════════════════════════════════════════════════════════════════${RESET}"
        fi
        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo -e " ${PURPLE}脚本快捷方式：rr${RESET}"
        echo -e "${CYAN}~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~${RESET}"
        echo ""
        echo -e "  ${PURPLE}1.${RESET} 首次安装（协议自由多选）/ 修复现有安装（配置绝不重置）"
        echo -e "  ${PURPLE}2.${RESET} 查看当前节点信息与订阅链接 (含二维码)"
        echo -e "  ${PURPLE}3.${RESET} 仅更换优选 IP/CDN 域名 (保留隧道)"
        echo -e "  ${PURPLE}4.${RESET} 仅刷新 Argo 临时隧道域名 (应对域名失效)"
        echo -e "  ${PURPLE}5.${RESET} 安装 Fail2Ban 防护盾 (防暴力破解)"
        echo -e "  ${PURPLE}6.${RESET} 完全卸载清理本脚本及后台服务"
        echo -e "  ${PURPLE}7.${RESET} 自动优选更新订阅 (${CYAN}当前状态: $AUTO_STATUS${RESET})"
        if [ "$UPDATE_AVAILABLE" = true ]; then
            echo -e "  ${PURPLE}8.${RESET} ${RED}更新脚本至最新版本（有新版本可用！）${RESET}"
        elif [ "${UPDATE_CHECK_STATE:-latest}" = "failed" ]; then
            echo -e "  ${PURPLE}8.${RESET} 检查并更新脚本至最新版本 ${YELLOW}（上次检查失败：网络不可用）${RESET}"
        else
            echo -e "  ${PURPLE}8.${RESET} 检查并更新脚本至最新版本"
        fi
        echo -e "  ${PURPLE}9.${RESET} 协议节点管理 (每种节点可单独改端口，HY2支持跳跃)"
        echo -e "  ${PURPLE}10.${RESET} 查看所有端口占用 (TCP/UDP 防火墙参考)"
        echo -e "  ${PURPLE}11.${RESET} Sing-box 控制 (启动/停止/重启/查看日志)"
        echo -e "  ${PURPLE}12.${RESET} IPv4 / IPv6 入口与出口管理 (可独立设置)"
        echo -e "  ${PURPLE}13.${RESET} 订阅端口独立管理 (支持 NAT 公网端口映射)"
        echo -e "  ${PURPLE}14.${RESET} RR Nexus · 星枢管理界面 (可选安装，本地/公网安全模式)"
        echo -e "  ${PURPLE}0.${RESET} 退出管理面板"
        echo -e "${CYAN}=================================================================================${RESET}"
        read -p "请输入数字选择操作 [0-14]: " menu_choice

        case "$menu_choice" in
            1) install_main ;;
            2) if [ -f "$CONFIG_FILE" ]; then show_info; else echo -e "${RED}请先选择 1 进行安装！${RESET}"; sleep 2; fi ;;
            3) if [ -f "$CONFIG_FILE" ]; then change_cdn; else echo -e "${RED}请先选择 1 进行安装！${RESET}"; sleep 2; fi ;;
            4) if [ -f "$CONFIG_FILE" ]; then refresh_argo; else echo -e "${RED}请先选择 1 进行安装！${RESET}"; sleep 2; fi ;;
            5) install_f2b ;;
            6) uninstall_all ;;
            7) toggle_auto_update ;;
            8) do_update ;;
            9) protocol_menu ;;
            10) show_ports ;;
            11) sb_control_menu ;;
            12) ip_stack_menu ;;
            13) subscription_port_menu ;;
            14) nexus_menu ;;
            0) clear; exit 0 ;;
            *) echo "输入无效，请重新选择"; sleep 1 ;;
        esac
    done
}
