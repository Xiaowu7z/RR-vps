# shellcheck shell=bash
# 模块化更新、迁移与健康检查。

rr_download_file() {
    local source_url="$1"
    local target_file="$2"
    local timeout_seconds="${3:-10}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 2 --connect-timeout "$timeout_seconds" --max-time 120 \
            "${source_url}?t=$(date +%s)" -o "$target_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$timeout_seconds" --tries=3 \
            -O "$target_file" "${source_url}?t=$(date +%s)"
    else
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
        { exit 1 }
        END {
            if (!launcher || modules < 2) exit 1
            if (!nexus_app || nexus_assets != 3) exit 1
        }
    ' "$manifest_file"
}

# H16/T12：健康自愈失败不得静默——写 /var/log/rr-health.log + syslog（logger）。
# 供 ensure_runtime_health 在内核重装失败、孤立进程发现等场景记录，面板同步提示。
RR_HEALTH_LOG="/var/log/rr-health.log"
rr_health_log() {
    local message="${1:-}"
    [ -n "$message" ] || return 0
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$message" >> "$RR_HEALTH_LOG" 2>/dev/null || true
    logger -t rr-health "$message" 2>/dev/null || true
}

    check_update() {
    local remote_manifest=""
    # H15：三态检查——available 有新 / latest 已最新 / failed 检查失败（网络不可用）。
    # 默认置 failed 并显示"检查失败"，下载/校验任一失败时保持该态，绝不误报"已是最新"。
    UPDATE_AVAILABLE=false
    UPDATE_CHECK_STATE="failed"
    SCRIPT_VER_STATUS="${YELLOW}检查失败（网络不可用）${RESET}"
    remote_manifest=$(mktemp /tmp/rr-manifest-check.XXXXXX) || return 0
    if ! rr_download_file "$RR_MANIFEST_URL" "$remote_manifest" 3 || \
       ! rr_manifest_is_valid "$remote_manifest"; then
        rm -f "$remote_manifest"
        return 0
    fi

    if [ ! -s "$RR_LOCAL_MANIFEST" ] || \
       [ "$(sha256sum "$remote_manifest" | awk '{print $1}')" != \
         "$(sha256sum "$RR_LOCAL_MANIFEST" 2>/dev/null | awk '{print $1}')" ]; then
        UPDATE_AVAILABLE=true
        UPDATE_CHECK_STATE="available"
        SCRIPT_VER_STATUS="${RED}有新版本${RESET}"
    else
        UPDATE_AVAILABLE=false
        UPDATE_CHECK_STATE="latest"
        SCRIPT_VER_STATUS="${GREEN}已是最新${RESET}"
    fi
    rm -f "$remote_manifest"
}

post_update_migrate() {
    # 热更新前置：停止旧服务避免端口冲突
    local nexus_was_running=false
    systemctl is-active --quiet rr-nexus && nexus_was_running=true
    systemctl stop sing-box 2>/dev/null || true
    systemctl stop rr-subscription 2>/dev/null || true
    systemctl stop rr-nexus 2>/dev/null || true
    pkill -f "subscription_server.py" 2>/dev/null || true
    sleep 1
    check_supported_os >/dev/null 2>&1 || return 1
    [ -f "$CONFIG_FILE" ] || return 0
    migrate_config_schema || return 1
    load_config_with_defaults || return 1

    # A failed first-install candidate intentionally contains empty keys and
    # no runnable service.  Updating the script must still succeed so the user
    # can re-enter option 1 with the fixed installer; do not treat that
    # candidate as a live node to migrate or restart.
    # (6.6.8: 收紧判定——迁移后的活节点机器 INSTALL_COMPLETE=false 但节点启用，
    # 必须照常重启，否则高速热更后节点无人拉起)
    if [ "$INSTALL_COMPLETE" != "true" ] && ! any_node_protocol_enabled; then
        return 0
    fi

    local current_version=""
    if any_node_protocol_enabled; then
        current_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
        if [ -z "$current_version" ]; then
            install_singbox || return 1
        elif ! version_ge "$current_version" "$MIN_SINGBOX_VERSION"; then
            # 下载失败时仍保留旧核心；只要现有协议配置能通过校验，脚本更新可以继续。
            install_singbox >/dev/null 2>&1 || true
        fi

        if [ ! -f /etc/systemd/system/sing-box.service ]; then
            build_singbox_config || return 1
            setup_systemd || return 1
            generate_node_and_sub || return 1
        else
            ensure_singbox_service_guards
            sync_runtime_state || return 1
        fi
    else
        stop_singbox_instances >/dev/null 2>&1 || true
        generate_node_and_sub || return 1
    fi

    if crontab -l 2>/dev/null | grep -q 'auto_update_sub.py'; then
        write_auto_update_worker || return 1
        python3 /usr/local/bin/auto_update_sub.py >/dev/null 2>&1 || return 1
    fi

    load_config_with_defaults || return 1
    if any_node_protocol_enabled && [ "$SINGBOX_AUTO_RESTART" = "true" ] && ! managed_singbox_running; then
        restart_singbox || return 1
    fi
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && \
       ! expected_argo_tunnel_running; then
        start_argo_tunnel >/dev/null 2>&1 || true
    fi
    if any_node_protocol_enabled; then
        setup_health_monitor >/dev/null 2>&1 || true
    else
        systemctl disable --now argo-rr-health.timer >/dev/null 2>&1 || true
    fi
    if [ -f "$NEXUS_SERVICE_FILE" ]; then
        nexus_install_dependencies || return 1
        nexus_migrate_runtime_config || return 1
        nexus_enable_traffic_engine || return 1
        ensure_nexus_service_guards
        RR_NEXUS_CONFIG="$NEXUS_CONFIG_FILE" python3 "$NEXUS_APP" --check || return 1
        systemctl daemon-reload >/dev/null 2>&1 || return 1
        systemctl restart rr-nexus >/dev/null 2>&1 || return 1
    fi
    return 0
}

ensure_runtime_health() {
    [ "$HEALTH_CHECK_DONE" = false ] || return 0
    HEALTH_CHECK_DONE=true
    [ -f "$CONFIG_FILE" ] || return 0
    migrate_config_schema >/dev/null 2>&1 || return 0
    load_config_with_defaults || return 0
    # 首次安装尚未完成时不介入，避免定时器与安装向导争抢端口或隧道。
    # (T10 C 系发现：迁移后的活节点机器 INSTALL_COMPLETE=false 但节点启用，
    #  健康定时器必须介入，否则该机器无自动恢复；仅"无节点协议"时保持旁路)
    [ "$INSTALL_COMPLETE" = "true" ] || ! any_node_protocol_enabled || return 0
    if ! any_node_protocol_enabled; then
        managed_singbox_running && stop_singbox_instances >/dev/null 2>&1 || true
        return 0
    fi
    ensure_singbox_service_guards
    # T4：为已部署机器幂等补齐 rr-nexus 单元的 StartLimit + 损坏数据库防重启。
    [ -f "$NEXUS_SERVICE_FILE" ] && ensure_nexus_service_guards

    # H6：sing-box 单元 active 时若存在脱离 unit cgroup 的受管进程，只记录与提示
    # 绝不自动清理（可能是用户手动运行的进程，清理有风险）。
    SB_ORPHAN_DETECTED=false
    if [ -f /etc/systemd/system/sing-box.service ] && systemctl is-active --quiet sing-box; then
        local orphan_pids=""
        orphan_pids=$(singbox_orphan_pids | tr '\n' ' ')
        if [ -n "$orphan_pids" ]; then
            SB_ORPHAN_DETECTED=true
            rr_health_log "发现脱离 systemd 的孤立 sing-box 进程（PID:${orphan_pids}），仅提示未清理；如非人为启动可到菜单 11→2 处理"
        fi
    fi

    # 只在受管内核缺失/损坏时修复；正常内核不做周期升级，避免无意义重启在线节点。
    local health_core_version=""
    SB_CORE_MISSING=false
    health_core_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    if [ "$SINGBOX_AUTO_RESTART" = "true" ] && [ -z "$health_core_version" ]; then
        # H16：内核缺失自愈失败不得静默——写健康日志并在面板显示提示字段。
        if ! install_singbox >/dev/null 2>&1; then
            SB_CORE_MISSING=true
            rr_health_log "Sing-box 内核缺失且自动重装失败（可能网络不可用），节点未拉起；网络恢复后执行 rr 或菜单 11→7 重试"
        fi
        health_core_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    fi

    if [ "$SINGBOX_AUTO_RESTART" = "true" ] && [ -n "$health_core_version" ] && \
       ! systemctl is-active --quiet sing-box; then
        if "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            restart_singbox >/dev/null 2>&1 || true
        fi
    fi

    if managed_singbox_running && [ "$VM_ENABLED" != "false" ] && \
       [ "$VM_TLS_ENABLED" != "true" ] && ! expected_argo_tunnel_running; then
        start_argo_tunnel >/dev/null 2>&1 || true
    fi

    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_HOP_PORTS" ]; then
        install_hop_rules HY2 "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1 || true
    fi

    # 设备到期和额度状态可能在无人操作时变化；定时同步只会在用户列表
    # 实际变化时重启 Sing-box，平时不会打断在线节点。
    if declare -F timeout 15 sync_nexus_devices 2>/dev/null || true >/dev/null 2>&1 && \
       [ -f "${NEXUS_DB_FILE:-/nonexistent}" ]; then
        timeout 15 sync_nexus_devices 2>/dev/null || true >/dev/null 2>&1 || true
    fi

    local sub_pid=""
    [ -f "$SUB_PID_FILE" ] && sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    if ! is_subscription_pid "$sub_pid" || \
       [ ! -s "${SUB_ROOT}/${UUID}/jhsub.txt" ] || \
       [ ! -s "${SUB_ROOT}/${UUID}/client.json" ]; then
        # 订阅自愈加超时保护：重建含公网入口探测，网络异常时不能拖垮
        # 整个健康检查链（此前实测一次网络抖动把链条卡住导致订阅迟迟未拉起）。
        timeout 90 generate_node_and_sub >/dev/null 2>&1 || true
    fi
    return 0
}


do_update() {
    echo -e "\n${YELLOW}检查 RR-vps 远程版本...${RESET}"
    # check_update 失败时不会重置该变量，先归零避免残留 true 误判"有更新"。
    UPDATE_AVAILABLE=false

    # ============================================================
    # 第一步：bundle 高速直更（绕过 CDN manifest 缓存）
    # 先解压到临时目录做完整校验，全部通过才交换进正式目录。
    # ============================================================
    local bundle_url="${RR_RAW_BASE}/rr-bundle.tar.gz"
    local bundle_tmp=""
    bundle_tmp=$(mktemp /tmp/rr-bundle-update.XXXXXX) || true
    local bundle_stage=""
    bundle_stage=$(mktemp -d /tmp/rr-bundle-stage.XXXXXX) || true
    local bundle_backup=""
    local member_count=0
    local remote_ver=""
    local local_ver="${SCRIPT_VERSION:-0}"

    if [ -n "$bundle_tmp" ] && [ -n "$bundle_stage" ] && \
       curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
           -o "$bundle_tmp" "${bundle_url}?t=$(date +%s)" 2>/dev/null && \
       [ -s "$bundle_tmp" ] && \
       tar -xzf "$bundle_tmp" -C "$bundle_stage" 2>/dev/null; then
        # --- 完整性校验：成员数 + 关键文件 + 语法 + 版本合法 ---
        member_count=$(find "$bundle_stage" -type f | wc -l)
        remote_ver=$(grep -o '^SCRIPT_VERSION="[0-9][0-9.]*"' \
            "$bundle_stage/rr-bundle/modules/00-runtime.sh" 2>/dev/null | head -1 | cut -d'"' -f2)
        if [ "$member_count" -ge 22 ] && \
           [ -s "$bundle_stage/rr-bundle/rr" ] && \
           [ -s "$bundle_stage/rr-bundle/install.sh" ] && \
           [ -s "$bundle_stage/rr-bundle/manifest.sha256" ] && \
           [ -s "$bundle_stage/rr-bundle/modules/00-runtime.sh" ] && \
           bash -n "$bundle_stage/rr-bundle/rr" 2>/dev/null && \
           [ -n "$remote_ver" ] && \
           { [ "$local_ver" = "0" ] || { [ "$remote_ver" != "$local_ver" ] && version_ge "$remote_ver" "$local_ver"; }; }; then
            # --- 原子交换 + 回滚保护 ---
            # rr 有双份：$RR_LIB_DIR/rr（模块目录内）与 $RR_LAUNCHER（入口脚本），两处同步更新。
            bundle_backup=$(mktemp -d /tmp/rr-backup.XXXXXX) || true
            if [ -n "$bundle_backup" ] && \
               cp -a "$RR_LAUNCHER" "$bundle_backup/rr-launcher" 2>/dev/null && \
               mv "$RR_LIB_DIR" "$bundle_backup/rr-old" 2>/dev/null && \
               cp -a "$bundle_stage/rr-bundle" "$RR_LIB_DIR" 2>/dev/null && \
               cp -a "$bundle_stage/rr-bundle/rr" "$RR_LAUNCHER" 2>/dev/null && \
               chmod 755 "$RR_LIB_DIR/rr" "$RR_LAUNCHER" 2>/dev/null && \
               bash -n "$RR_LIB_DIR/rr" 2>/dev/null && \
               bash -n "$RR_LAUNCHER" 2>/dev/null && \
               migrate_config_schema; then
                # 运行时尽力刷新（失败只警告，不回滚——文件已成功落地）：
                # 1) 订阅文件重新生成（热更后立即拉订阅就能拿到新配置）
                # 2) 自动订阅 worker 更新（若用户已开启自动优选订阅）
                if ! generate_node_and_sub >/dev/null 2>&1; then
                    echo -e "${YELLOW}[提示] 订阅文件刷新失败，重新执行 rr 后会自动重试。${RESET}"
                fi
                if crontab -l 2>/dev/null | grep -q 'auto_update_sub.py'; then
                    write_auto_update_worker >/dev/null 2>&1 || true
                    python3 /usr/local/bin/auto_update_sub.py >/dev/null 2>&1 || true
                fi
                echo -e "${GREEN}[成功] 高速热更完成（已校验 bundle 完整性并迁移配置）。${RESET}"
                # 拉起新版本运行组件：守护/校验 sing-box、重启新版面板（rr-nexus），
                # 使远程升级后无需任何人工操作即进入新版本。
                post_update_migrate >/dev/null 2>&1 || true
                echo -e "${CYAN}服务已自动恢复，面板已切换至新版本。${RESET}"
                rm -f "$bundle_tmp" && rm -rf "$bundle_stage" "$bundle_backup"
                # 不能依赖 read 的返回值决定是否退出：非交互环境下 read 失败会
                # fall-through 到下方回滚块，把刚更新好的文件删光。
                read -rp "按回车键退出..." || true
                exit 0
            fi
            # 回滚：新目录/新 launcher 校验失败时恢复原文件（双份都恢复）
            rm -rf "$RR_LIB_DIR" 2>/dev/null
            if [ -d "$bundle_backup/rr-old" ] && mv "$bundle_backup/rr-old" "$RR_LIB_DIR" 2>/dev/null && \
               [ -s "$bundle_backup/rr-launcher" ] && mv "$bundle_backup/rr-launcher" "$RR_LAUNCHER" 2>/dev/null; then
                echo -e "${YELLOW}[警告] bundle 校验失败，已回滚原模块。${RESET}"
            else
                echo -e "${RED}[严重] 热更失败且回滚异常，建议重新安装。${RESET}"
                rm -rf "$bundle_tmp" "$bundle_stage" "$bundle_backup" 2>/dev/null
                read -p "按回车键返回..."
                return 1
            fi
        fi
    fi
    rm -f "$bundle_tmp" 2>/dev/null
    rm -rf "$bundle_stage" "$bundle_backup" 2>/dev/null

    # H3：远程 bundle 版本低于本地时显式提示降级已被拦截（此前静默跳过）。
    if [ -n "$remote_ver" ] && [ "$local_ver" != "0" ] && [ "$remote_ver" != "$local_ver" ] && \
       ! version_ge "$remote_ver" "$local_ver"; then
        echo -e "${YELLOW}[提示] 已阻止降级：远程版本 ${remote_ver} 低于本地版本 ${local_ver}。${RESET}"
    fi

    # ============================================================
    # 第二步：manifest 比对 + bootstrap 全量升级（原兜底路径）
    # ============================================================
    check_update
    if [ "${UPDATE_CHECK_STATE:-latest}" = "failed" ]; then
        echo -e "${YELLOW}[提示] 版本检查失败（网络不可用），本次未执行更新，当前节点未改动。${RESET}"
        read -p "按回车键返回..." || true
        return 1
    fi
    if [ "$UPDATE_AVAILABLE" != true ]; then
        echo -e "${GREEN}当前已是最新版本，无需更新。${RESET}"
        read -p "按回车键返回..."
        return 0
    fi

    local bootstrap_tmp=""
    # 直接下载最新安装器（带时间戳绕过 CDN 缓存）。
    # 旧实现优先提取 payload 里的 install.sh，但 bundle 内 install.sh 的
    # bundle hash 行必然差一版（自引用），会导致高速模式永远不命中。
    bootstrap_tmp=$(mktemp /tmp/rr-bootstrap-update.XXXXXX) || return 1
    if ! rr_download_file "$RR_BOOTSTRAP_URL" "$bootstrap_tmp" 10 || \
       [ ! -s "$bootstrap_tmp" ] || \
       ! bash -n "$bootstrap_tmp" 2>/dev/null || \
       ! grep -q '^RR_BOOTSTRAP_VERSION=' "$bootstrap_tmp" || \
       ! grep -q 'Xiaowu7z/RR-vps' "$bootstrap_tmp"; then
        rm -f "$bootstrap_tmp"
        echo -e "${RED}[失败] 更新程序下载或完整性检查失败，当前节点未改动。${RESET}"
        read -p "按回车键返回..." || true
        return 1
    fi
    [ -s "$bootstrap_tmp" ] || { rm -f "$bootstrap_tmp"; echo -e "${RED}[失败] 更新程序不可用。${RESET}"; read -p "按回车键返回..."; return 1; }
    chmod 700 "$bootstrap_tmp"

    echo -e "${YELLOW}发现新版本，正在执行带回滚保护的模块化热更新...${RESET}"
    if bash "$bootstrap_tmp" --upgrade; then
        rm -f "$bootstrap_tmp"
        echo -e "${GREEN}[成功] RR-vps 已更新到最新版本。${RESET}"
        echo -e "${CYAN}原 UUID、密钥、域名、节点端口、订阅端口及 IPv4/IPv6 设置均已保留。${RESET}"
        echo -e "${YELLOW}请重新执行 rr 进入新版本面板。${RESET}"
        read -p "按回车键退出..."
        exit 0
    fi

    rm -f "$bootstrap_tmp"
    echo -e "${RED}[失败] 热更新没有完成，安装程序已回滚原模块和运行数据。${RESET}"
    read -p "按回车键返回..."
    return 1
}
