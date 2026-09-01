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
    local repair_any_protocol=false firewall_status=0
    if rr_firewall_fail_closed_quarantine_active; then
        rr_firewall_repair_fail_closed_quarantine || firewall_status=$?
        if [ "$firewall_status" -ne 0 ]; then
            echo -e "${RED}[失败] 防火墙持久隔离未能经精确修复，公网运行面保持停止。${RESET}" >&2
            return "$firewall_status"
        fi
    fi
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
    open_configured_firewall || firewall_status=$?
    if [ "$firewall_status" -ne 0 ]; then
        case "$firewall_status" in
            1|10)
                echo -e "${RED}[失败] 防火墙修复失败，已证明 live 规则保持原态；未报告修复成功。${RESET}" >&2
                ;;
            2)
                echo -e "${RED}[严重] 防火墙修复状态不确定，Sing-box 已停止并验证 inactive。${RESET}" >&2
                ;;
            *)
                echo -e "${RED}[紧急] 防火墙修复状态不确定，且无法验证 Sing-box 已停止。${RESET}" >&2
                ;;
        esac
        return "$firewall_status"
    fi
    # NAIVE-SUPPORT：安装期申请 Let's Encrypt 真证书（证书就绪后 sing-box 才能起 naive 入站）
    if [ "$NAIVE_ENABLED" = "true" ]; then
        if ! ensure_naive_certificate "$NAIVE_DOMAIN" "$LE_EMAIL"; then
            echo -e "${RED}[失败] NaiveProxy 证书或自动续签运行面未就绪；修复流程已停止，不能把已启用的 NaiveProxy 报告为修复成功。${RESET}" >&2
            return 1
        fi
    fi
    generate_node_and_sub || return 1
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && \
       ! expected_argo_tunnel_running; then
        start_argo_tunnel || return 1
        expected_argo_tunnel_running || return 1
    fi
    if [ "$repair_any_protocol" = true ]; then
        if ! setup_health_monitor >/dev/null 2>&1 || \
           ! systemctl is-enabled --quiet argo-rr-health.timer || \
           ! systemctl is-active --quiet argo-rr-health.timer; then
            echo -e "${RED}[失败] 健康监控 timer 未能启用并验证 active；未报告修复成功。${RESET}" >&2
            return 1
        fi
    fi
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
declare -g RR_UNINSTALL_RECOVERY_HELPER_SHA256=""
declare -g RR_UNINSTALL_EXTERNAL_HELPER_SHA256=""
declare -g RR_UNINSTALL_RUNTIME_MANIFEST_SHA256=""
declare -g RR_UNINSTALL_UPDATE_GUARD_SHA256=""
declare -g RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED=false

rr_uninstall_fixed_absolute_path_is_safe() {
    local path="$1"
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    [ "$path" != / ] && [ "${path%/}" = "$path" ] || return 1
    case "/${path#/}/" in
        *//*|*/./*|*/../*) return 1 ;;
    esac
}

rr_uninstall_path_ancestors_are_trusted() {
    local path="$1" directory="" canonical="" metadata=""
    local owner="" group="" mode="" mode_value=0 parent=""
    rr_uninstall_fixed_absolute_path_is_safe "$path" || return 1
    directory=$(dirname -- "$path") || return 1
    while :; do
        [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
        canonical=$(readlink -f -- "$directory" 2>/dev/null) || return 1
        [ "$canonical" = "$directory" ] || return 1
        metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
        IFS=: read -r owner group mode <<< "$metadata"
        [ "$owner" = 0 ] && [ "$group" = 0 ] || return 1
        [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        [ $((mode_value & 06000)) -eq 0 ] || return 1
        if [ $((mode_value & 00022)) -ne 0 ] && \
           [ $((mode_value & 01000)) -eq 0 ]; then
            return 1
        fi
        [ "$directory" = / ] && break
        parent=$(dirname -- "$directory") || return 1
        [ "$parent" != "$directory" ] || return 1
        directory="$parent"
    done
}

rr_uninstall_regular_file_is_exact() {
    local target="$1" expected_mode="$2" canonical="" metadata=""
    rr_uninstall_fixed_absolute_path_is_safe "$target" || return 1
    rr_uninstall_path_ancestors_are_trusted "$target" || return 1
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    canonical=$(readlink -f -- "$target" 2>/dev/null) || return 1
    [ "$canonical" = "$target" ] || return 1
    metadata=$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null) || return 1
    [ "$metadata" = "0:0:${expected_mode}:1" ]
}

rr_uninstall_manifest_entry_digest() {
    local manifest="$1" requested="$2"
    LC_ALL=C awk -v requested="$requested" '
        NF != 2 { invalid = 1; next }
        length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { invalid = 1; next }
        seen[$2]++ { invalid = 1; next }
        $2 == "rr" { launcher = 1; allowed = 1 }
        $2 == "scripts/naive-cert-hook.sh" { naive_hook = 1; allowed = 1 }
        $2 == "scripts/update-recover.sh" { recovery = 1; allowed = 1 }
        $2 == "scripts/update-external-state.py" { external_state = 1; allowed = 1 }
        $2 ~ /^modules\/[0-9][0-9A-Za-z_-]*\.sh$/ { modules++; allowed = 1 }
        $2 == "nexus/rr_nexus.py" { nexus_app = 1; allowed = 1 }
        $2 == "nexus/sub_server.py" { nexus_sub = 1; allowed = 1 }
        $2 ~ /^nexus\/rr_nexus_lib\/[A-Za-z0-9._-]+\.py$/ {
            nexus_python++; allowed = 1
        }
        $2 ~ /^nexus\/static\/[A-Za-z0-9._-]+\.(html|css|js)$/ {
            nexus_assets++; allowed = 1
        }
        !allowed { invalid = 1 }
        $2 == requested { requested_digest = $1; requested_count++ }
        { allowed = 0 }
        END {
            if (invalid || !launcher || !naive_hook || !recovery ||
                !external_state || modules < 2 || !nexus_app || !nexus_sub ||
                nexus_assets < 3 || requested_count != 1) exit 1
            print requested_digest
        }
    ' "$manifest"
}

rr_uninstall_runtime_manifest_entry_is_owned() {
    local relative="$1" target="$2" expected_mode="$3"
    local manifest="${RR_LIB_DIR}/manifest.sha256" expected_target=""
    local manifest_identity_before="" manifest_identity_after=""
    local target_identity_before="" target_identity_after=""
    local manifest_digest="" expected_digest="" actual_digest=""
    rr_uninstall_fixed_absolute_path_is_safe "$RR_LIB_DIR" || return 1
    rr_uninstall_fixed_absolute_path_is_safe "${RR_LAUNCHER:-/usr/local/bin/rr}" || \
        return 1
    case "$relative:$expected_mode" in
        rr:755)
            expected_target="${RR_LAUNCHER:-/usr/local/bin/rr}"
            ;;
        scripts/*.sh:755|scripts/*.py:755|nexus/*.py:755|\
        nexus/rr_nexus_lib/*.py:755|modules/*.sh:644|\
        nexus/static/*.html:644|nexus/static/*.css:644|\
        nexus/static/*.js:644)
            expected_target="${RR_LIB_DIR}/${relative}"
            ;;
        *) return 1 ;;
    esac
    [ "$target" = "$expected_target" ] || return 1
    rr_uninstall_regular_file_is_exact "$manifest" 644 || return 1
    [ "$(stat -c %s -- "$manifest" 2>/dev/null || printf 0)" -le 1048576 ] || \
        return 1
    manifest_identity_before=$(stat -c '%d:%i:%u:%g:%a:%h:%s' -- \
        "$manifest" 2>/dev/null) || return 1
    manifest_digest=$(sha256sum -- "$manifest" 2>/dev/null | \
        awk '{print $1}') || return 1
    [[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ]; then
        [[ "$RR_UNINSTALL_RUNTIME_MANIFEST_SHA256" =~ ^[0-9a-f]{64}$ ]] && \
            [ "$manifest_digest" = "$RR_UNINSTALL_RUNTIME_MANIFEST_SHA256" ] || \
            return 1
    fi
    expected_digest=$(rr_uninstall_manifest_entry_digest \
        "$manifest" "$relative") || return 1
    [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    manifest_identity_after=$(stat -c '%d:%i:%u:%g:%a:%h:%s' -- \
        "$manifest" 2>/dev/null) || return 1
    [ "$manifest_identity_before" = "$manifest_identity_after" ] || return 1

    rr_uninstall_regular_file_is_exact "$target" "$expected_mode" || return 1
    target_identity_before=$(stat -c '%d:%i:%u:%g:%a:%h:%s' -- \
        "$target" 2>/dev/null) || return 1
    actual_digest=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') || \
        return 1
    target_identity_after=$(stat -c '%d:%i:%u:%g:%a:%h:%s' -- \
        "$target" 2>/dev/null) || return 1
    [ "$target_identity_before" = "$target_identity_after" ] && \
        [ "$actual_digest" = "$expected_digest" ]
}

rr_uninstall_update_guard_digest() {
    local output_name="$1"
    local guard="${RR_LIB_DIR}/modules/61-update-guard.sh" digest=""
    printf -v "$output_name" '%s' ''
    if [ ! -e "$guard" ] && [ ! -L "$guard" ]; then
        return 0
    fi
    rr_uninstall_regular_file_is_exact "$guard" 644 || return 1
    [ "$(stat -c %s -- "$guard" 2>/dev/null || printf 65537)" -le 65536 ] || \
        return 1
    bash -n "$guard" 2>/dev/null || return 1
    grep -q '^RR_UPDATE_GUARD_VERSION=' "$guard" || return 1
    grep -q '^do_update() {' "$guard" || return 1
    grep -q '^check_update() {' "$guard" || return 1
    if grep -Eq 'rr_manifest_is_valid|rr_bundle_(archive|tree)_is_valid|tar[[:space:]].*rr-bundle' \
            "$guard"; then
        return 1
    fi
    digest=$(sha256sum -- "$guard" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "$output_name" '%s' "$digest"
}

rr_uninstall_runtime_inventory_is_exact() {
    local manifest="${RR_LIB_DIR}/manifest.sha256" digest="" relative=""
    local path="" directory="" guard="${RR_LIB_DIR}/modules/61-update-guard.sh"
    local base="" filename="" pycache_parent="" pycache_base="" pycache_tag=""
    local metadata="" inventory_file="" inventory_failed=false pycache_match=false
    local _rr_pycache_owner="" _rr_pycache_group="" _rr_pycache_mode=""
    local -A expected_files=() expected_directories=() seen_paths=()
    local -A allowed_pycache_directories=() python_source_bases=()
    rr_uninstall_regular_file_is_exact "$manifest" 644 || return 1
    expected_files["$manifest"]=1
    while read -r digest relative; do
        [ -n "$digest" ] && [ -n "$relative" ] || return 1
        [ "$relative" != rr ] || continue
        path="${RR_LIB_DIR}/${relative}"
        rr_uninstall_fixed_absolute_path_is_safe "$path" || return 1
        [ -z "${expected_files[$path]+set}" ] || return 1
        expected_files["$path"]=1
        directory=$(dirname -- "$path") || return 1
        case "$relative" in
            scripts/*.py|nexus/*.py|nexus/rr_nexus_lib/*.py)
                base=$(basename -- "$relative" .py) || return 1
                python_source_bases["$directory/$base"]=1
                allowed_pycache_directories["$directory/__pycache__"]=1
                ;;
        esac
        while [ "$directory" != "$RR_LIB_DIR" ]; do
            rr_uninstall_fixed_absolute_path_is_safe "$directory" || return 1
            expected_directories["$directory"]=1
            directory=$(dirname -- "$directory") || return 1
        done
    done < "$manifest"
    if [ -e "$guard" ] || [ -L "$guard" ]; then
        expected_files["$guard"]=1
        expected_directories["$(dirname -- "$guard")"]=1
    fi
    inventory_file=$(mktemp /tmp/rr-uninstall-inventory.XXXXXX) || return 1
    chmod 600 "$inventory_file" || { rm -f -- "$inventory_file"; return 1; }
    if ! find "$RR_LIB_DIR" -mindepth 1 -print0 > "$inventory_file"; then
        rm -f -- "$inventory_file"
        return 1
    fi
    while IFS= read -r -d '' path; do
        if [ -n "${seen_paths[$path]+set}" ]; then
            inventory_failed=true
            continue
        fi
        seen_paths["$path"]=1
        if [ -L "$path" ]; then
            inventory_failed=true
        elif [ -f "$path" ]; then
            if [ -n "${expected_files[$path]+set}" ]; then
                :
            else
                directory=$(dirname -- "$path") || {
                    inventory_failed=true
                    continue
                }
                if [ -z "${allowed_pycache_directories[$directory]+set}" ]; then
                    inventory_failed=true
                    continue
                fi
                filename=$(basename -- "$path") || {
                    inventory_failed=true
                    continue
                }
                pycache_parent=$(dirname -- "$directory") || {
                    inventory_failed=true
                    continue
                }
                pycache_match=false
                for base in "${!python_source_bases[@]}"; do
                    [ "$(dirname -- "$base")" = "$pycache_parent" ] || continue
                    pycache_base=$(basename -- "$base") || continue
                    pycache_tag="${filename#"${pycache_base}.cpython-"}"
                    if [ "$pycache_tag" != "$filename" ] && \
                       [[ "$pycache_tag" =~ ^[0-9]{2,3}(\.opt-[12])?\.pyc$ ]]; then
                        pycache_match=true
                        break
                    fi
                done
                if [ "$pycache_match" != true ] || \
                   { ! rr_uninstall_regular_file_is_exact "$path" 600 && \
                     ! rr_uninstall_regular_file_is_exact "$path" 644; } || \
                   [ "$(stat -c %s -- "$path" 2>/dev/null || printf 16777217)" \
                     -gt 16777216 ]; then
                    inventory_failed=true
                fi
            fi
        elif [ -d "$path" ]; then
            if [ -n "${expected_directories[$path]+set}" ]; then
                :
            elif [ -n "${allowed_pycache_directories[$path]+set}" ]; then
                metadata=$(stat -c '%u:%g:%a' -- "$path" 2>/dev/null) || {
                    inventory_failed=true
                    continue
                }
                IFS=: read -r _rr_pycache_owner _rr_pycache_group \
                    _rr_pycache_mode <<< "$metadata"
                if [ "$_rr_pycache_owner" != 0 ] || \
                   [ "$_rr_pycache_group" != 0 ]; then
                    inventory_failed=true
                else
                    case "$_rr_pycache_mode" in
                        700|755) ;;
                        *) inventory_failed=true ;;
                    esac
                fi
            else
                inventory_failed=true
            fi
        else
            inventory_failed=true
        fi
    done < "$inventory_file"
    rm -f -- "$inventory_file" || return 1
    [ "$inventory_failed" = false ] || return 1
    for path in "${!expected_files[@]}"; do
        [ -n "${seen_paths[$path]+set}" ] || return 1
    done
    for path in "${!expected_directories[@]}"; do
        [ -n "${seen_paths[$path]+set}" ] || return 1
    done
}

rr_uninstall_runtime_tree_is_owned() {
    local manifest="${RR_LIB_DIR}/manifest.sha256" digest="" relative=""
    local target="" expected_mode="" count=0 guard_digest=""
    rr_uninstall_regular_file_is_exact "$manifest" 644 || return 1
    while read -r digest relative; do
        [ -n "$digest" ] && [ -n "$relative" ] || return 1
        case "$relative" in
            rr)
                target="${RR_LAUNCHER:-/usr/local/bin/rr}"
                expected_mode=755
                ;;
            scripts/*.sh|scripts/*.py|nexus/*.py|nexus/rr_nexus_lib/*.py)
                target="${RR_LIB_DIR}/${relative}"
                expected_mode=755
                ;;
            modules/*.sh|nexus/static/*.html|nexus/static/*.css|\
            nexus/static/*.js)
                target="${RR_LIB_DIR}/${relative}"
                expected_mode=644
                ;;
            *) return 1 ;;
        esac
        rr_uninstall_runtime_manifest_entry_is_owned \
            "$relative" "$target" "$expected_mode" || return 1
        count=$((count + 1))
    done < "$manifest"
    [ "$count" -ge 11 ] || return 1
    rr_uninstall_update_guard_digest guard_digest || return 1
    if [ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ]; then
        [ "$guard_digest" = "$RR_UNINSTALL_UPDATE_GUARD_SHA256" ] || return 1
    fi
    rr_uninstall_runtime_inventory_is_exact
}

rr_uninstall_deployed_helper_digest() {
    local relative="$1" target="$2" output_name="$3" source=""
    local digest=""
    printf -v "$output_name" '%s' ''
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    source="${RR_LIB_DIR}/${relative}"
    rr_uninstall_runtime_manifest_entry_is_owned \
        "$relative" "$source" 755 || return 1
    rr_uninstall_regular_file_is_exact "$target" 755 || return 1
    cmp -s -- "$target" "$source" || return 1
    digest=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf -v "$output_name" '%s' "$digest"
}

rr_uninstall_capture_runtime_ownership() {
    local recovery_target="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"
    local external_target="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
    local manifest="${RR_LIB_DIR}/manifest.sha256"
    local recovery_digest="" external_digest="" manifest_digest=""
    local update_guard_digest=""
    RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED=false
    RR_UNINSTALL_RECOVERY_HELPER_SHA256=""
    RR_UNINSTALL_EXTERNAL_HELPER_SHA256=""
    RR_UNINSTALL_RUNTIME_MANIFEST_SHA256=""
    RR_UNINSTALL_UPDATE_GUARD_SHA256=""
    rr_uninstall_fixed_absolute_path_is_safe "$recovery_target" || return 1
    rr_uninstall_fixed_absolute_path_is_safe "$external_target" || return 1
    [ "$recovery_target" != "$external_target" ] || return 1
    rr_uninstall_runtime_tree_is_owned || return 1
    rr_uninstall_deployed_helper_digest scripts/update-recover.sh \
        "$recovery_target" recovery_digest || return 1
    rr_uninstall_deployed_helper_digest scripts/update-external-state.py \
        "$external_target" external_digest || return 1
    rr_uninstall_update_guard_digest update_guard_digest || return 1
    manifest_digest=$(sha256sum -- "$manifest" 2>/dev/null | \
        awk '{print $1}') || return 1
    [[ "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    RR_UNINSTALL_RECOVERY_HELPER_SHA256="$recovery_digest"
    RR_UNINSTALL_EXTERNAL_HELPER_SHA256="$external_digest"
    RR_UNINSTALL_RUNTIME_MANIFEST_SHA256="$manifest_digest"
    RR_UNINSTALL_UPDATE_GUARD_SHA256="$update_guard_digest"
    RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED=true
}

rr_uninstall_runtime_ownership_is_unchanged() {
    local recovery_target="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"
    local external_target="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
    local recovery_digest="" external_digest=""
    [ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ] || return 1
    rr_uninstall_runtime_tree_is_owned || return 1
    rr_uninstall_deployed_helper_digest scripts/update-recover.sh \
        "$recovery_target" recovery_digest || return 1
    rr_uninstall_deployed_helper_digest scripts/update-external-state.py \
        "$external_target" external_digest || return 1
    [ "$recovery_digest" = "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" ] && \
        [ "$external_digest" = "$RR_UNINSTALL_EXTERNAL_HELPER_SHA256" ]
}

rr_uninstall_captured_helper_is_unchanged_or_absent() {
    local target="$1" expected_digest="$2" actual_digest=""
    rr_uninstall_fixed_absolute_path_is_safe "$target" || return 1
    if [ -z "$expected_digest" ]; then
        [ ! -e "$target" ] && [ ! -L "$target" ]
        return
    fi
    [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    rr_uninstall_regular_file_is_exact "$target" 755 || return 1
    actual_digest=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') || \
        return 1
    [ "$actual_digest" = "$expected_digest" ]
}

rr_uninstall_remove_captured_runtime_helpers() {
    local recovery_target="${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}"
    local external_target="${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}"
    local recovery_parent="" external_parent=""
    [ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ] || return 1
    rr_uninstall_captured_helper_is_unchanged_or_absent \
        "$recovery_target" "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" || return 1
    rr_uninstall_captured_helper_is_unchanged_or_absent \
        "$external_target" "$RR_UNINSTALL_EXTERNAL_HELPER_SHA256" || return 1
    if [ -n "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" ]; then
        unlink -- "$recovery_target" || return 1
    fi
    if [ -n "$RR_UNINSTALL_EXTERNAL_HELPER_SHA256" ]; then
        unlink -- "$external_target" || return 1
    fi
    recovery_parent=$(dirname -- "$recovery_target") || return 1
    external_parent=$(dirname -- "$external_target") || return 1
    sync -f "$recovery_parent" || return 1
    [ "$external_parent" = "$recovery_parent" ] || \
        sync -f "$external_parent" || return 1
    [ ! -e "$recovery_target" ] && [ ! -L "$recovery_target" ] && \
        [ ! -e "$external_target" ] && [ ! -L "$external_target" ]
}

rr_uninstall_render_subscription_quarantine_unit() {
    local marker="${RR_QUARANTINE_FILE:-/var/lib/rr-update/subscription-quarantine}"
    local guard_state="${RR_QUARANTINE_GUARD_STATE:-/var/lib/rr-quarantine/guard-state}"
    local guard_self="${RR_QUARANTINE_GUARD_SELF:-/usr/local/libexec/rr-vps/subscription-quarantine-guard}"
    rr_uninstall_fixed_absolute_path_is_safe "$marker" || return 1
    rr_uninstall_fixed_absolute_path_is_safe "$guard_state" || return 1
    rr_uninstall_fixed_absolute_path_is_safe "$guard_self" || return 1
    cat <<EOF
[Unit]
Description=RR-vps unsafe rollback subscription quarantine
After=local-fs.target
Before=argo-rr-health.service
ConditionPathExists=|${marker}
ConditionPathExists=|${guard_state}

[Service]
Type=notify
NotifyAccess=all
ExecStart=${guard_self} quarantine-guard
Restart=on-failure
RestartSec=1
TimeoutStartSec=15
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
}

rr_uninstall_quarantine_state_file_is_owned() {
    local state_file="$1" line="" key="" value=""
    local seen_format=0 seen_state=0 seen_version=0 seen_port=0 seen_resume=0
    local line_count=0
    rr_uninstall_regular_file_is_exact "$state_file" 600 || return 1
    [ "$(stat -c %s -- "$state_file" 2>/dev/null || printf 513)" -le 512 ] || \
        return 1
    while IFS= read -r line; do
        line_count=$((line_count + 1))
        key="${line%%=*}"
        value="${line#*=}"
        [ "$key" != "$line" ] || return 1
        case "$key" in
            format)
                [ "$seen_format" -eq 0 ] && [ "$value" = 1 ] || return 1
                seen_format=1
                ;;
            state)
                [ "$seen_state" -eq 0 ] || return 1
                case "$value" in quarantined|degraded) ;; *) return 1 ;; esac
                seen_state=1
                ;;
            target_version)
                [ "$seen_version" -eq 0 ] || return 1
                if [ "$value" != unknown ]; then
                    [[ "$value" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || \
                        return 1
                fi
                seen_version=1
                ;;
            port)
                [ "$seen_port" -eq 0 ] && [[ "$value" =~ ^[0-9]+$ ]] || \
                    return 1
                [ "$value" = 0 ] || \
                    { [ "$((10#$value))" -ge 1 ] && \
                      [ "$((10#$value))" -le 65535 ]; } || return 1
                seen_port=1
                ;;
            resume_subscription)
                [ "$seen_resume" -eq 0 ] || return 1
                case "$value" in 0|1) ;; *) return 1 ;; esac
                seen_resume=1
                ;;
            *) return 1 ;;
        esac
    done < "$state_file"
    [ "$line_count" -eq 5 ] && [ "$seen_format" -eq 1 ] && \
        [ "$seen_state" -eq 1 ] && [ "$seen_version" -eq 1 ] && \
        [ "$seen_port" -eq 1 ] && [ "$seen_resume" -eq 1 ]
}

rr_uninstall_subscription_quarantine_artifacts_are_owned() {
    local marker="${RR_QUARANTINE_FILE:-/var/lib/rr-update/subscription-quarantine}"
    local unit="${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}"
    local ready="${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}"
    local guard_state="${RR_QUARANTINE_GUARD_STATE:-/var/lib/rr-quarantine/guard-state}"
    local guard_self="${RR_QUARANTINE_GUARD_SELF:-/usr/local/libexec/rr-vps/subscription-quarantine-guard}"
    local artifact="" expected_digest="" actual_digest="" i=0 j=0
    local load_state="" fragment_path="" drop_in_paths="" ready_digest=""
    local -a artifacts=("$marker" "$unit" "$ready" "$guard_state" "$guard_self")
    for ((i = 0; i < ${#artifacts[@]}; i++)); do
        artifact="${artifacts[$i]}"
        rr_uninstall_fixed_absolute_path_is_safe "$artifact" || return 1
        for ((j = i + 1; j < ${#artifacts[@]}; j++)); do
            [ "$artifact" != "${artifacts[$j]}" ] || return 1
        done
    done
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        rr_uninstall_quarantine_state_file_is_owned "$marker" || return 1
    fi
    if [ -e "$guard_state" ] || [ -L "$guard_state" ]; then
        rr_uninstall_quarantine_state_file_is_owned "$guard_state" || return 1
    fi
    if { [ -e "$marker" ] || [ -L "$marker" ]; } && \
       { [ -e "$guard_state" ] || [ -L "$guard_state" ]; }; then
        cmp -s -- "$marker" "$guard_state" || return 1
    fi
    if [ -e "$ready" ] || [ -L "$ready" ]; then
        rr_uninstall_regular_file_is_exact "$ready" 600 || return 1
        ready_digest=$(sha256sum -- "$ready" 2>/dev/null | awk '{print $1}') || \
            return 1
        expected_digest=$(printf 'ready\n' | sha256sum | awk '{print $1}') || \
            return 1
        [ "$ready_digest" = "$expected_digest" ] || return 1
    fi
    if [ -e "$guard_self" ] || [ -L "$guard_self" ]; then
        rr_uninstall_regular_file_is_exact "$guard_self" 700 || return 1
        expected_digest="$RR_UNINSTALL_RECOVERY_HELPER_SHA256"
        [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || return 1
        actual_digest=$(sha256sum -- "$guard_self" 2>/dev/null | \
            awk '{print $1}') || return 1
        [ "$actual_digest" = "$expected_digest" ] || return 1
    fi
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        rr_uninstall_regular_file_is_exact "$unit" 644 || return 1
        expected_digest=$(rr_uninstall_render_subscription_quarantine_unit | \
            sha256sum | awk '{print $1}') || return 1
        actual_digest=$(sha256sum -- "$unit" 2>/dev/null | awk '{print $1}') || \
            return 1
        [ "$actual_digest" = "$expected_digest" ] || return 1
    fi
    load_state=$(systemctl show -p LoadState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    fragment_path=$(systemctl show -p FragmentPath --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    drop_in_paths=$(systemctl show -p DropInPaths --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 1
    if [ -e "$unit" ] || [ -L "$unit" ]; then
        [ "$load_state" = loaded ] && [ "$fragment_path" = "$unit" ] && \
            [ -z "${drop_in_paths//[[:space:]]/}" ]
    else
        [ "$load_state" = not-found ] && \
            [ -z "${fragment_path//[[:space:]]/}" ] && \
            [ -z "${drop_in_paths//[[:space:]]/}" ]
    fi
}

_uninstall_quarantine_present() {
    local marker="${1:-${RR_QUARANTINE_FILE:-/var/lib/rr-update/subscription-quarantine}}"
    local unit="${2:-${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}}"
    local ready="${3:-${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}}"
    local guard_state="${RR_QUARANTINE_GUARD_STATE:-/var/lib/rr-quarantine/guard-state}"
    local guard_self="${RR_QUARANTINE_GUARD_SELF:-/usr/local/libexec/rr-vps/subscription-quarantine-guard}"
    local artifact="" firewall_backend="" firewall_rules=""
    local load_state="" active_state="" unit_file_state=""

    for artifact in "$marker" "$unit" "$ready" "$guard_state" "$guard_self"; do
        if [ -e "$artifact" ] || [ -L "$artifact" ]; then
            return 0
        fi
    done
    load_state=$(systemctl show --property=LoadState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 0
    active_state=$(systemctl show --property=ActiveState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 0
    unit_file_state=$(systemctl show --property=UnitFileState --value \
        rr-subscription-quarantine.service 2>/dev/null) || return 0
    if [ "$load_state" = not-found ] && [ -z "$unit_file_state" ]; then
        unit_file_state=not-found
    fi
    if [ "$load_state:$active_state:$unit_file_state" = \
        not-found:inactive:not-found ]; then
        :
    else
        return 0
    fi
    # A previous affected uninstall may have removed the marker while leaving
    # the exact raw-table rule behind. Detect it, but never broadly flush or
    # infer a port from unrelated firewall state.
    for firewall_backend in iptables ip6tables; do
        command -v "$firewall_backend" >/dev/null 2>&1 || continue
        if ! firewall_rules=$("$firewall_backend" -w 5 -t raw -S PREROUTING 2>/dev/null); then
            # Unknown firewall state is still quarantine evidence. Failing
            # open here could delete the only trusted recovery helper while
            # an orphan DROP rule remains installed.
            return 0
        fi
        if [[ "$firewall_rules" == *'rr-vps unsafe rollback subscription quarantine'* ]]; then
            return 0
        fi
    done
    return 1
}

_uninstall_recovery_helper_is_trusted() {
    local helper="$1" helper_dir="" canonical="" current="" parent=""
    local metadata="" owner="" group="" mode="" links="" digest=""
    local runtime_source="${RR_LIB_DIR}/scripts/update-recover.sh"
    local dir_owner="" dir_group="" dir_mode=""
    [ -f "$helper" ] && [ ! -L "$helper" ] && [ -x "$helper" ] || return 1
    canonical=$(readlink -f -- "$helper" 2>/dev/null) || return 1
    [ "$canonical" = "$helper" ] || return 1
    helper_dir=$(dirname -- "$helper") || return 1
    [ -d "$helper_dir" ] && [ ! -L "$helper_dir" ] || return 1
    metadata=$(stat -c '%u %g %a %h' -- "$helper" 2>/dev/null) || return 1
    read -r owner group mode links <<< "$metadata"
    [ "$owner" = 0 ] && [ "$group" = 0 ] && [ "$links" = 1 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ "$mode" = 755 ] || return 1
    current="$helper_dir"
    while :; do
        [ -d "$current" ] && [ ! -L "$current" ] || return 1
        metadata=$(stat -c '%u %g %a' -- "$current" 2>/dev/null) || return 1
        read -r dir_owner dir_group dir_mode <<< "$metadata"
        [ "$dir_owner" = 0 ] && [ "$dir_group" = 0 ] || return 1
        [[ "$dir_mode" =~ ^[0-7]{3,4}$ ]] || return 1
        if [ $((8#$dir_mode & 0022)) -ne 0 ] && \
           [ $((8#$dir_mode & 01000)) -eq 0 ]; then
            return 1
        fi
        [ "$current" = / ] && break
        parent=$(dirname -- "$current") || return 1
        [ "$parent" != "$current" ] || return 1
        current="$parent"
    done
    digest=$(sha256sum -- "$helper" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [ -e "$runtime_source" ] || [ -L "$runtime_source" ]; then
        rr_uninstall_runtime_manifest_entry_is_owned \
            scripts/update-recover.sh "$runtime_source" 755 || return 1
        cmp -s -- "$helper" "$runtime_source" || return 1
        RR_UNINSTALL_RECOVERY_HELPER_SHA256="$digest"
        return 0
    fi
    [ "$RR_UNINSTALL_RUNTIME_OWNERSHIP_CAPTURED" = true ] && \
        [[ "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" =~ ^[0-9a-f]{64}$ ]] && \
        [ "$digest" = "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" ]
}

_uninstall_clear_subscription_quarantine() {
    local helper="${1:-${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}}"
    local marker="${2:-${RR_QUARANTINE_FILE:-/var/lib/rr-update/subscription-quarantine}}"
    local unit="${3:-${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}}"
    local ready="${4:-${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}}"

    _uninstall_quarantine_present "$marker" "$unit" "$ready" || return 0
    if ! _uninstall_recovery_helper_is_trusted "$helper"; then
        echo -e "${RED}[失败] 检测到订阅隔离仍在生效，但恢复程序不可信；为避免留下端口或防火墙残留，已中止卸载。${RESET}" >&2
        return 1
    fi
    if ! rr_uninstall_subscription_quarantine_artifacts_are_owned; then
        echo -e "${RED}[失败] 订阅隔离 Unit 或独立 guard 与 RR 精确内容不符；未执行任何停止或删除。${RESET}" >&2
        return 1
    fi
    if ! RR_UPDATE_LOCK_HELD=1 "$helper" clear-quarantine; then
        echo -e "${RED}[失败] 无法安全解除旧版订阅隔离；未继续删除恢复程序和事务证据。${RESET}" >&2
        return 1
    fi
    if _uninstall_quarantine_present "$marker" "$unit" "$ready"; then
        echo -e "${RED}[失败] 订阅隔离清理后仍有残留；未继续卸载，请先运行 rr-update-recover status 诊断。${RESET}" >&2
        return 1
    fi
    return 0
}

_uninstall_acquire_existing_legacy_lock() {
    local lock_file="$1" output_name="$2" lock_dir="" canonical="" metadata=""
    local owner="" group="" mode="" links="" path_identity="" fd_identity="" candidate_fd=""
    local shell_pid="${BASHPID:-$$}" fd_path=""
    printf -v "$output_name" '%s' ''
    if [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        return 0
    fi
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    lock_dir=$(dirname -- "$lock_file") || return 1
    [ -d "$lock_dir" ] && [ ! -L "$lock_dir" ] || return 1
    canonical=$(readlink -f -- "$lock_dir" 2>/dev/null) || return 1
    [ "$canonical" = "$lock_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$lock_dir" 2>/dev/null)" = 0:0 ] || return 1
    metadata=$(stat -c '%u %g %a %h' -- "$lock_file" 2>/dev/null) || return 1
    read -r owner group mode links <<< "$metadata"
    [ "$owner" = 0 ] && [ "$group" = 0 ] && [ "$links" = 1 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 07133)) -eq 0 ] || return 1
    exec {candidate_fd}<"$lock_file" || return 1
    fd_path="/proc/$shell_pid/fd/$candidate_fd"
    [ -e "$fd_path" ] || fd_path="/dev/fd/$candidate_fd"
    path_identity=$(stat -c '%d:%i:%u:%g:%a:%h' -- "$lock_file" 2>/dev/null) || {
        exec {candidate_fd}>&-
        return 1
    }
    fd_identity=$(stat -Lc '%d:%i:%u:%g:%a:%h' -- "$fd_path" 2>/dev/null) || {
        exec {candidate_fd}>&-
        return 1
    }
    if [ "$path_identity" != "$fd_identity" ] ||
       [[ "$fd_identity" != *:0:0:*:1 ]] || ! flock -n "$candidate_fd"; then
        exec {candidate_fd}>&-
        return 1
    fi
    printf -v "$output_name" '%s' "$candidate_fd"
}

_uninstall_health_unit_is_safely_stopped() {
    local unit="$1" unit_path="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}/$1"
    local load_state="" active_state="" unit_file_state=""
    if [ -e "$unit_path" ] || [ -L "$unit_path" ]; then
        systemctl stop "$unit" >/dev/null 2>&1 || return 1
        systemctl disable "$unit" >/dev/null 2>&1 || return 1
    fi
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || return 1
    active_state=$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null) || return 1
    unit_file_state=$(systemctl show --property=UnitFileState --value "$unit" 2>/dev/null) || return 1
    if [ "$load_state" = not-found ] && [ -z "$unit_file_state" ]; then
        unit_file_state=not-found
    fi
    case "$load_state:$active_state:$unit_file_state" in
        loaded:inactive:disabled|loaded:inactive:static|\
        loaded:failed:disabled|loaded:failed:static|\
        masked:inactive:masked|masked:failed:masked|\
        not-found:inactive:not-found) ;;
        *) return 1 ;;
    esac
}

_uninstall_subscription_restart_paths_are_absent() {
    local runtime="${1:-$RR_LIB_DIR}"
    local launcher="${2:-/usr/local/bin/rr}"
    local systemd_dir="${3:-${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}}"
    local restart_helper="${4:-/usr/local/bin/auto_update_sub.py}"
    local path=""
    for path in "$runtime" "$launcher" \
        "$systemd_dir/argo-rr-health.timer" \
        "$systemd_dir/argo-rr-health.service" "$restart_helper"; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    done
}

_uninstall_release_subscription_quarantine() {
    local helper="${1:-${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}}"
    local marker="${2:-${RR_QUARANTINE_FILE:-/var/lib/rr-update/subscription-quarantine}}"
    local unit="${3:-${RR_QUARANTINE_UNIT:-/etc/systemd/system/rr-subscription-quarantine.service}}"
    local ready="${4:-${RR_QUARANTINE_READY:-/run/rr-subscription-quarantine.ready}}"
    local runtime="${5:-$RR_LIB_DIR}"
    local launcher="${6:-/usr/local/bin/rr}"
    local systemd_dir="${7:-${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}}"
    local restart_helper="${8:-/usr/local/bin/auto_update_sub.py}"

    # These unlinks span /usr, /etc and /var.  Flush them before releasing the
    # last subscription barrier, then re-read every restart path after stopping
    # processes so a concurrent recreation cannot pass on stale evidence.
    sync || return 1
    _uninstall_subscription_restart_paths_are_absent \
        "$runtime" "$launcher" "$systemd_dir" "$restart_helper" || return 1
    _uninstall_health_unit_is_safely_stopped argo-rr-health.timer || return 1
    _uninstall_health_unit_is_safely_stopped argo-rr-health.service || return 1
    stop_subscription_servers >/dev/null 2>&1 || return 1
    subscription_server_running && return 1
    _uninstall_subscription_restart_paths_are_absent \
        "$runtime" "$launcher" "$systemd_dir" "$restart_helper" || return 1
    _uninstall_clear_subscription_quarantine "$helper" "$marker" "$unit" "$ready"
}

rr_uninstall_firewall_snapshots_match_after_clear() {
    local original_root="$1" current_root="$2"
    local original="$1/firewall" current="$2/firewall"
    local backend="" table="" expected_state="" current_state=""
    rr_restore_require_firewall_snapshot_v2 "$original_root" || return 1
    rr_restore_require_firewall_snapshot_v2 "$current_root" || return 1
    cmp -s "$original/ufw.state" "$current/ufw.state" || return 1
    expected_state=$(cat -- "$original/ufw.state" 2>/dev/null) || return 1
    case "$expected_state" in
        active)
            [ -f "$current/ufw.rules" ] && [ ! -s "$current/ufw.rules" ] && \
                [ -f "$current/ufw.ordered" ] && \
                [ ! -s "$current/ufw.ordered" ] || return 1
            cmp -s "$original/ufw.unmanaged" "$current/ufw.unmanaged" || return 1
            ;;
        inactive)
            [ -f "$current/ufw.inactive.managed" ] && \
                [ ! -s "$current/ufw.inactive.managed" ] || return 1
            cmp -s "$original/ufw.inactive.unmanaged" \
                "$current/ufw.inactive.unmanaged" || return 1
            cmp -s "$original/ufw.inactive.cleared" \
                "$current/ufw.inactive.rules" || return 1
            ;;
        absent) ;;
        *) return 1 ;;
    esac
    for backend in iptables ip6tables; do
        cmp -s "$original/${backend}.state" "$current/${backend}.state" || \
            return 1
        current_state=$(cat -- "$current/${backend}.state" 2>/dev/null) || \
            return 1
        case "$current_state" in
            absent) continue ;;
            readable) ;;
            *) return 1 ;;
        esac
        for table in filter nat; do
            [ -f "$current/${backend}.${table}.rules" ] && \
                [ ! -s "$current/${backend}.${table}.rules" ] || return 1
            cmp -s "$original/${backend}.${table}.unmanaged" \
                "$current/${backend}.${table}.unmanaged" || return 1
            cmp -s "$original/${backend}.${table}.unmanaged.raw" \
                "$current/${backend}.${table}.unmanaged.raw" || return 1
        done
    done
}

rr_uninstall_prepare_inactive_ufw_evidence() {
    local root="$1" snapshot="$1/firewall" state=""
    state=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    [ "$state" = inactive ] || return 0
    python3 - "$snapshot/ufw.inactive.rules" \
        "$snapshot/ufw.inactive.ordered" \
        "$snapshot/ufw.inactive.cleared" "$FIREWALL_COMMENT" \
        "$FIREWALL_BLOCK_COMMENT" <<'PY' || return 1
import re
import shlex
import sys

source, ordered_path, cleared_path, allow_comment, block_comment = sys.argv[1:]
managed = {allow_comment: "allow", block_comment: "deny"}
ordered = []
cleared = []
position = 0
keys = set()
for raw in open(source, encoding="utf-8"):
    line = raw.rstrip("\n")
    try:
        tokens = shlex.split(line)
    except ValueError:
        raise SystemExit(1)
    if not tokens or tokens[0] != "ufw":
        cleared.append(line)
        continue
    position += 1
    try:
        comment = tokens[tokens.index("comment") + 1]
    except (ValueError, IndexError):
        comment = None
    if comment not in managed:
        cleared.append(line)
        continue
    if (len(tokens) != 5 or tokens[1] != managed[comment]
            or tokens[3:] != ["comment", comment]
            or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
            or int(tokens[2].split("/", 1)[0]) > 65535
            or tokens[2] in keys):
        raise SystemExit(1)
    keys.add(tokens[2])
    ordered.append(f"{position}\t{line}")
for path, lines in ((ordered_path, ordered), (cleared_path, cleared)):
    with open(path, "w", encoding="utf-8") as output:
        for line in lines:
            output.write(line + "\n")
PY
    chmod 600 "$snapshot/ufw.inactive.ordered" \
        "$snapshot/ufw.inactive.cleared" || return 1
    sync -f "$snapshot/ufw.inactive.ordered" || return 1
    sync -f "$snapshot/ufw.inactive.cleared"
}

rr_uninstall_capture_firewall_snapshot() {
    local root="$1"
    RR_UNINSTALL_CAPTURE_INACTIVE_UFW=1 \
        rr_restore_capture_firewall_snapshot "$root" || return 1
    rr_uninstall_prepare_inactive_ufw_evidence "$root"
}

rr_uninstall_inactive_ufw_program_matches() {
    local snapshot="$1" expected="$2" current="" state=""
    state=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    [ "$state" = inactive ] || return 0
    rr_restore_firewall_ufw_state state || return 1
    [ "$state" = inactive ] || return 1
    current=$(mktemp "$snapshot/.uninstall-ufw-current.XXXXXX") || return 1
    if ! LC_ALL=C ufw show added > "$current" 2>/dev/null || \
       ! cmp -s "$expected" "$current"; then
        rm -f -- "$current"
        return 1
    fi
    rm -f -- "$current"
}

rr_uninstall_run_inactive_ufw_saved_rule() {
    local operation="$1" line="$2" position="${3:-}" state=""
    local -a arguments=()
    rr_firewall_writer_gate_is_held || return 1
    rr_restore_firewall_ufw_state state || return 1
    [ "$state" = inactive ] || return 1
    mapfile -d '' -t arguments < <(
        python3 - "$FIREWALL_COMMENT" "$FIREWALL_BLOCK_COMMENT" "$line" <<'PY'
import re
import shlex
import sys

allow_comment, block_comment, line = sys.argv[1:]
managed = {allow_comment: "allow", block_comment: "deny"}
try:
    tokens = shlex.split(line)
except ValueError:
    raise SystemExit(1)
if (len(tokens) != 5 or tokens[0] != "ufw"
        or tokens[1] not in {"allow", "deny"}
        or tokens[3] != "comment" or tokens[4] not in managed
        or tokens[1] != managed[tokens[4]]
        or re.fullmatch(r"[1-9][0-9]{0,4}/(?:tcp|udp)", tokens[2]) is None
        or int(tokens[2].split("/", 1)[0]) > 65535):
    raise SystemExit(1)
for token in tokens:
    sys.stdout.buffer.write(token.encode() + b"\0")
PY
    )
    [ "${#arguments[@]}" -eq 5 ] && [ "${arguments[0]}" = ufw ] || return 1
    case "$operation" in
        delete) ufw delete "${arguments[@]:1}" >/dev/null 2>&1 ;;
        insert)
            [[ "$position" =~ ^[1-9][0-9]*$ ]] || return 1
            ufw insert "$position" "${arguments[@]:1}" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

rr_uninstall_clear_inactive_ufw_rules() {
    local root="$1" snapshot="$1/firewall" line="" position="" rule=""
    local state="" index=0
    local -a ordered=()
    state=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    [ "$state" = inactive ] || return 0
    rr_uninstall_inactive_ufw_program_matches "$snapshot" \
        "$snapshot/ufw.inactive.rules" || return 1
    # Delete from the end so earlier recorded positions remain meaningful for
    # exact rollback if a later command fails.
    mapfile -t ordered < "$snapshot/ufw.inactive.ordered" || return 1
    for ((index=${#ordered[@]} - 1; index>=0; index--)); do
        line="${ordered[index]}"
        IFS=$'\t' read -r position rule <<< "$line"
        rr_uninstall_run_inactive_ufw_saved_rule delete "$rule" || return 1
    done
    rr_uninstall_inactive_ufw_program_matches "$snapshot" \
        "$snapshot/ufw.inactive.cleared"
}

rr_uninstall_restore_inactive_ufw_rules() {
    local root="$1" snapshot="$1/firewall" line="" position="" rule=""
    local state="" current="" current_managed=""
    state=$(cat -- "$snapshot/ufw.state" 2>/dev/null) || return 1
    [ "$state" = inactive ] || return 0
    rr_restore_firewall_ufw_state state || return 1
    [ "$state" = inactive ] || return 1
    current=$(mktemp "$snapshot/.uninstall-ufw-restore.XXXXXX") || return 1
    current_managed=$(mktemp "$snapshot/.uninstall-ufw-managed.XXXXXX") || {
        rm -f -- "$current"
        return 1
    }
    if ! LC_ALL=C ufw show added > "$current" 2>/dev/null || \
       ! rr_restore_filter_ufw_rules "$current" "$current_managed" managed strict; then
        rm -f -- "$current" "$current_managed"
        return 1
    fi
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        rr_uninstall_run_inactive_ufw_saved_rule delete "$rule" || {
            rm -f -- "$current" "$current_managed"
            return 1
        }
    done < "$current_managed"
    rm -f -- "$current" "$current_managed"
    while IFS=$'\t' read -r position rule; do
        [ -n "$position" ] && [ -n "$rule" ] || return 1
        rr_uninstall_run_inactive_ufw_saved_rule insert "$rule" "$position" || \
            return 1
    done < "$snapshot/ufw.inactive.ordered"
    rr_uninstall_inactive_ufw_program_matches "$snapshot" \
        "$snapshot/ufw.inactive.rules"
}

rr_uninstall_clear_managed_firewall_transaction_locked() {
    local evidence="$1" snapshot="$1/firewall" cleared="$1/cleared"
    local persisted="$1/persisted" raw_required=false raw_state=0
    local mutation_started=false failed=false
    rr_firewall_lock_is_held || return 1
    rr_uninstall_capture_firewall_snapshot "$evidence" || return 1
    rr_restore_verify_firewall_pre_mutation_snapshot "$evidence" || return 1
    rr_uninstall_inactive_ufw_program_matches "$snapshot" \
        "$snapshot/ufw.inactive.rules" || return 1
    if rr_restore_firewall_snapshot_has_managed_raw_rules "$snapshot"; then
        raw_required=true
    else
        raw_state=$?
        [ "$raw_state" -eq 1 ] || return 1
    fi
    if [ "$raw_required" = true ] && \
       ! rr_firewall_persistence_backend_available; then
        printf '%s\n' \
            '卸载需清理 raw/NAT RR 规则，但缺少受支持的持久化后端；尚未写入。' >&2
        return 1
    fi

    mutation_started=true
    rr_uninstall_clear_inactive_ufw_rules "$evidence" || failed=true
    RR_RESTORE_FIREWALL_NEEDS_PERSIST="$raw_required" \
        rr_restore_clear_managed_firewall "$snapshot" || failed=true
    if [ "$failed" = false ]; then
        rr_uninstall_capture_firewall_snapshot "$cleared" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_uninstall_firewall_snapshots_match_after_clear \
            "$evidence" "$cleared" || failed=true
    fi
    if [ "$failed" = false ] && [ "$raw_required" = true ]; then
        save_firewall || failed=true
    fi
    # A successful save is followed by another exact live capture.  This
    # proves the persistence command itself did not rewrite an unmanaged rule
    # before credentials/configuration can be deleted.
    if [ "$failed" = false ]; then
        rr_uninstall_capture_firewall_snapshot "$persisted" || failed=true
    fi
    if [ "$failed" = false ]; then
        rr_uninstall_firewall_snapshots_match_after_clear \
            "$evidence" "$persisted" || failed=true
    fi
    [ "$failed" = true ] || return 0

    if [ "$mutation_started" = true ]; then
        if ! rr_restore_restore_firewall_snapshot "$evidence"; then
            printf '卸载防火墙清理失败，且原态精确回滚失败；证据保留在 %s。\n' \
                "$evidence" >&2
            return 2
        fi
        rr_uninstall_restore_inactive_ufw_rules "$evidence" || return 2
        rr_restore_verify_firewall_snapshot "$evidence" || return 2
        rr_restore_verify_ufw_program_exact "$snapshot" || return 2
        rr_uninstall_inactive_ufw_program_matches "$snapshot" \
            "$snapshot/ufw.inactive.rules" || return 2
    fi
    return 1
}

rr_uninstall_evidence_root_is_safe() {
    local evidence="$1" parent="${RR_UNINSTALL_EVIDENCE_DIR:-/var/lib/rr-uninstall}"
    [ "$(dirname -- "$evidence")" = "$parent" ] && \
        [[ "$(basename -- "$evidence")" = firewall.* ]] || return 1
    [ -d "$parent" ] && [ ! -L "$parent" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ -d "$evidence" ] && [ ! -L "$evidence" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$evidence" 2>/dev/null)" = 0:0:700 ]
}

RR_UNINSTALL_FIREWALL_EVIDENCE=""
rr_uninstall_clear_managed_firewall_transaction() {
    local parent="${RR_UNINSTALL_EVIDENCE_DIR:-/var/lib/rr-uninstall}"
    local evidence="" result=0 release_failed=false
    local started_here=false arm_status=0 finish_status=0
    local RR_FIREWALL_QUARANTINE_WRITER=0
    if [ -e "$parent" ] || [ -L "$parent" ]; then
        [ -d "$parent" ] && [ ! -L "$parent" ] && \
            [ "$(stat -c '%u:%g:%a' -- "$parent" 2>/dev/null)" = 0:0:700 ] || \
            return 1
    else
        install -d -o 0 -g 0 -m 700 -- "$parent" || return 1
    fi
    evidence=$(mktemp -d "$parent/firewall.XXXXXX") || return 1
    chmod 700 "$evidence" || return 1
    rr_uninstall_evidence_root_is_safe "$evidence" || return 1
    RR_UNINSTALL_FIREWALL_EVIDENCE="$evidence"
    rr_firewall_lock_acquire || return 1
    if rr_firewall_load_fail_closed_quarantine; then
        RR_FIREWALL_QUARANTINE_WRITER=1
    elif ! rr_firewall_writer_gate_is_held; then
        if rr_firewall_inflight_begin_locked; then
            started_here=true
        else
            arm_status=$?
            rr_firewall_lock_release || true
            [ "$arm_status" -ge 2 ] && return 2
            return 1
        fi
    fi
    rr_uninstall_clear_managed_firewall_transaction_locked "$evidence" || result=$?
    if [ "$started_here" = true ]; then
        if [ "$result" -eq 0 ] || [ "$result" -eq 1 ]; then
            rr_firewall_inflight_finish_locked || finish_status=$?
            [ "$finish_status" -eq 0 ] || result=2
        else
            rr_firewall_inflight_is_owned && \
                rr_firewall_promote_inflight_locked >/dev/null 2>&1 || true
            result=2
        fi
    fi
    rr_firewall_lock_release || release_failed=true
    if [ "$release_failed" = true ]; then
        result=2
    fi
    if [ "$result" -eq 2 ]; then
        printf '防火墙卸载事务状态不确定；已保留证据 %s。\n' \
            "$evidence" >&2
        return 2
    fi
    if ! rm -rf -- "$evidence" || ! sync -f "$parent"; then
        printf '防火墙卸载证据清理失败；已保留配置并拒绝报告成功：%s\n' \
            "$evidence" >&2
        return 1
    fi
    RR_UNINSTALL_FIREWALL_EVIDENCE=""
    rmdir -- "$parent" >/dev/null 2>&1 || true
    return "$result"
}

rr_uninstall_fixed_cloudflared_evidence_is_trusted() {
    local config="${CONFIG_FILE:-/etc/argo_vmess.conf}"
    local token="${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
    local token_dir="" metadata="" owner="" group="" links="" mode="" size=""
    local value="" lines=0
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 1
    [ -f "$config" ] && [ ! -L "$config" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$config" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<< "$metadata"
    [ "$owner:$group:$links" = 0:0:1 ] || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || \
        return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 1

    token_dir=$(dirname -- "$token") || return 1
    [ -d "$token_dir" ] && [ ! -L "$token_dir" ] && \
        [ "$(stat -c '%u:%g:%a' -- "$token_dir" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    [ -f "$token" ] && [ ! -L "$token" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$token" 2>/dev/null) || return 1
    IFS=: read -r owner group links mode size <<< "$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:600 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 1 ] && \
        [ "$size" -le 4097 ] || return 1
    lines=$(wc -l < "$token" 2>/dev/null) || return 1
    [ "$lines" -eq 1 ] || return 1
    IFS= read -r value < "$token" || return 1
    [ -n "$value" ] && [ "${#value}" -le 4096 ] && \
        [[ "$value" != *[[:space:]]* ]]
}

rr_uninstall_render_fixed_cloudflared_service() {
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

rr_uninstall_fixed_cloudflared_unit_is_owned() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local cloudflared_bin="" canonical="" fragment="" dropins="" metadata=""
    local owner="" group="" links="" mode="" size=""
    rr_uninstall_fixed_cloudflared_evidence_is_trusted || return 1
    [ -f "$service_file" ] && [ ! -L "$service_file" ] || return 1
    canonical=$(readlink -f -- "$service_file" 2>/dev/null) || return 1
    [ "$canonical" = "$service_file" ] || return 1
    metadata=$(stat -c '%u:%g:%h:%a:%s' -- "$service_file" 2>/dev/null) || \
        return 1
    IFS=: read -r owner group links mode size <<< "$metadata"
    [ "$owner:$group:$links:$mode" = 0:0:1:644 ] || return 1
    [[ "$size" =~ ^[0-9]+$ ]] && [ "$size" -gt 0 ] && \
        [ "$size" -le 1048576 ] || return 1
    cloudflared_bin=$(command -v cloudflared 2>/dev/null) || return 1
    cloudflared_bin=$(readlink -f -- "$cloudflared_bin" 2>/dev/null) || return 1
    [[ "$cloudflared_bin" = /* && "$cloudflared_bin" != *[[:space:]]* ]] || \
        return 1
    cmp -s -- "$service_file" \
        <(rr_uninstall_render_fixed_cloudflared_service "$cloudflared_bin") || \
        return 1
    fragment=$(systemctl show --property=FragmentPath --value \
        cloudflared.service 2>/dev/null) || return 1
    dropins=$(systemctl show --property=DropInPaths --value \
        cloudflared.service 2>/dev/null) || return 1
    [ "$fragment" = "$service_file" ] && [ -z "$dropins" ]
}

rr_uninstall_remove_owned_fixed_cloudflared() {
    local service_file="${RR_CLOUDFLARED_SERVICE_FILE:-/etc/systemd/system/cloudflared.service}"
    local load_state=""
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 0
    rr_uninstall_fixed_cloudflared_evidence_is_trusted || {
        printf '%s\n' \
            '固定 Cloudflared 的 RR 配置或 Token 证据不可信；未停止或删除任何 Cloudflared 服务。' >&2
        return 1
    }
    if [ ! -e "$service_file" ] && [ ! -L "$service_file" ]; then
        rr_restore_unit_load_state_read cloudflared.service load_state || return 1
        [ "$load_state" = not-found ] && \
            rr_restore_unit_activity_matches cloudflared.service inactive
        return $?
    fi
    rr_uninstall_fixed_cloudflared_unit_is_owned || {
        printf '%s\n' \
            'Cloudflared 有效 Unit 与 RR 生成形状不一致；为避免误伤第三方服务，卸载已停止。' >&2
        return 1
    }
    systemctl stop cloudflared.service >/dev/null 2>&1 || return 1
    rr_restore_unit_activity_matches cloudflared.service inactive || return 1
    systemctl disable cloudflared.service >/dev/null 2>&1 || return 1
    rr_restore_unit_file_state_matches cloudflared.service disabled || return 1
    rm -f -- "$service_file" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    rr_restore_unit_load_state_read cloudflared.service load_state || return 1
    [ "$load_state" = not-found ] && \
        rr_restore_unit_activity_matches cloudflared.service inactive && \
        rr_restore_unit_file_state_matches cloudflared.service disabled
}

rr_uninstall_stop_owned_argo_runtime() {
    local retry=0
    if [ "${TUNNEL_MODE:-1}" = 2 ]; then
        rr_uninstall_remove_owned_fixed_cloudflared
        return $?
    fi
    stop_quick_argo_tunnel || return 1
    while [ "$retry" -lt 20 ] && quick_argo_running; do
        sleep 0.1
        retry=$((retry + 1))
    done
    ! quick_argo_running
}

rr_uninstall_firewall_quarantine_artifacts_are_owned() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local systemd_root="${RR_FIREWALL_SYSTEMD_DIR:-/etc/systemd/system}"
    local managed_name=zzzzz-rr-firewall-quarantine.conf
    local guard_script="${RR_FIREWALL_GUARD_SCRIPT:-/usr/local/sbin/rr-firewall-quarantine-guard}"
    local unit="" target="" metadata="" renderer=""
    local -a units=(sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service)
    rr_firewall_load_fail_closed_quarantine || return 1
    for unit in "${units[@]}"; do
        target="$systemd_root/${unit}.d/$managed_name"
        [ -f "$target" ] && [ ! -L "$target" ] || return 1
        metadata=$(stat -c '%u:%g:%h:%a' -- "$target" 2>/dev/null) || return 1
        [ "$metadata" = 0:0:1:644 ] || return 1
        cmp -s -- "$target" <(printf \
            '[Service]\nExecCondition=/usr/bin/test ! -e %s\nExecCondition=/usr/bin/test ! -L %s\n' \
            "$marker" "$marker") || return 1
    done
    [ "$(stat -c '%u:%g:%h:%a' -- "$guard_script" 2>/dev/null)" = \
        0:0:1:700 ] || return 1
    cmp -s -- "$guard_script" <(rr_firewall_render_quarantine_guard_script) || \
        return 1
    for unit in service path timer; do
        target="$systemd_root/rr-firewall-quarantine-guard.${unit}"
        [ "$(stat -c '%u:%g:%h:%a' -- "$target" 2>/dev/null)" = \
            0:0:1:644 ] || return 1
        case "$unit" in
            service) renderer=rr_firewall_render_quarantine_guard_service ;;
            path) renderer=rr_firewall_render_quarantine_guard_path ;;
            timer) renderer=rr_firewall_render_quarantine_guard_timer ;;
        esac
        cmp -s -- "$target" <("$renderer") || return 1
    done
}

rr_uninstall_remove_firewall_quarantine_artifacts() {
    local directory="${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}"
    local marker="${RR_FIREWALL_QUARANTINE_FILE:-${directory}/firewall-quarantine}"
    local systemd_root="${RR_FIREWALL_SYSTEMD_DIR:-/etc/systemd/system}"
    local managed_name=zzzzz-rr-firewall-quarantine.conf
    local guard_script="${RR_FIREWALL_GUARD_SCRIPT:-/usr/local/sbin/rr-firewall-quarantine-guard}"
    local unit="" directory_path="" target="" paths="" stale=""
    local -a units=(sing-box.service rr-nexus.service rr-subscription.service \
        argo-rr-health.service)
    rr_uninstall_firewall_quarantine_artifacts_are_owned || return 1
    rr_firewall_deactivate_quarantine_retry || return 1
    # Remove evidence first.  A crash before the marker unlink leaves every
    # gate closed and merely requires manual repair; it can never reuse stale
    # evidence as a new transaction snapshot.
    rm -rf -- "$directory/firewall-evidence" || return 1
    for stale in "$directory"/.firewall-evidence-stale.* \
        "$directory"/.firewall-evidence-repaired.*; do
        [ -e "$stale" ] || [ -L "$stale" ] || continue
        [[ "$(basename -- "$stale")" = .firewall-evidence-stale.* || \
           "$(basename -- "$stale")" = .firewall-evidence-repaired.* ]] || \
            return 1
        rm -rf -- "$stale" || return 1
    done
    sync -f "$directory" || return 1
    rm -f -- "$marker" || return 1
    sync -f "$directory" || return 1
    for unit in "${units[@]}"; do
        directory_path="$systemd_root/${unit}.d"
        target="$directory_path/$managed_name"
        rm -f -- "$target" || return 1
        sync -f "$directory_path" || return 1
        rmdir -- "$directory_path" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ] && \
        [ ! -e "$directory/firewall-evidence" ] && \
        [ ! -L "$directory/firewall-evidence" ] || return 1
    for unit in "${units[@]}"; do
        target="$systemd_root/${unit}.d/$managed_name"
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
        paths=$(systemctl show --property=DropInPaths --value \
            "$unit" 2>/dev/null) || return 1
        case " $paths " in *" $target "*) return 1 ;; esac
    done
    systemctl disable --now rr-firewall-quarantine-guard.path \
        >/dev/null 2>&1 || return 1
    systemctl is-active --quiet rr-firewall-quarantine-guard.path && return 1
    systemctl is-enabled --quiet rr-firewall-quarantine-guard.path && return 1
    rm -f -- "$systemd_root/rr-firewall-quarantine-guard.service" \
        "$systemd_root/rr-firewall-quarantine-guard.path" \
        "$systemd_root/rr-firewall-quarantine-guard.timer" \
        "$guard_script" || return 1
    sync -f "$systemd_root" || return 1
    sync -f "$(dirname -- "$guard_script")" || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    for unit in service path timer; do
        target="$systemd_root/rr-firewall-quarantine-guard.${unit}"
        [ ! -e "$target" ] && [ ! -L "$target" ] || return 1
    done
    [ ! -e "$guard_script" ] && [ ! -L "$guard_script" ]
}

rr_uninstall_abort_fail_closed() {
    local context="$1" stop_status=0
    rr_firewall_fail_closed_stop_nodes "$context" || stop_status=$?
    [ "$stop_status" -ge 2 ] || stop_status=3
    return "$stop_status"
}

rr_uninstall_certificate_reload_pending_is_owned() {
    local directory="${RR_CERT_RELOAD_PENDING_DIR:-/var/lib/rr-vps/cert-reload-pending}"
    local entry="" consumer=""
    local -a entries=()
    if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
        return 0
    fi
    declare -F rr_certificate_reload_directory_is_exact >/dev/null 2>&1 && \
        declare -F rr_certificate_reload_marker_read >/dev/null 2>&1 || return 1
    rr_certificate_reload_directory_is_exact "$directory" || return 1
    (
        shopt -s dotglob nullglob
        entries=("$directory"/*)
        for entry in "${entries[@]}"; do
            case "$entry" in
                "$directory/naive.pending") consumer=naive ;;
                "$directory/subscription.pending") consumer=subscription ;;
                "$directory/nexus.pending") consumer=nexus ;;
                *) exit 1 ;;
            esac
            rr_certificate_reload_marker_read "$entry" "$consumer" || exit 1
        done
    )
}

rr_uninstall_remove_owned_certificate_reload_pending() {
    local directory="${RR_CERT_RELOAD_PENDING_DIR:-/var/lib/rr-vps/cert-reload-pending}"
    local parent="" consumer="" marker=""
    if [ ! -e "$directory" ] && [ ! -L "$directory" ]; then
        return 0
    fi
    rr_uninstall_certificate_reload_pending_is_owned || return 1
    for consumer in naive subscription nexus; do
        marker="$directory/${consumer}.pending"
        [ -e "$marker" ] || [ -L "$marker" ] || continue
        rr_certificate_reload_marker_read "$marker" "$consumer" || return 1
        rm -f -- "$marker" || return 1
        sync -f "$directory" || return 1
    done
    rr_uninstall_certificate_reload_pending_is_owned || return 1
    rmdir -- "$directory" || return 1
    parent=$(dirname -- "$directory") || return 1
    sync -f "$parent" || return 1
    [ ! -e "$directory" ] && [ ! -L "$directory" ]
}

rr_uninstall_certificate_hook_directory_is_safe() {
    local directory="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local logical="" resolved="" metadata=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    logical=$(realpath -ms -- "$directory" 2>/dev/null) || return 1
    resolved=$(readlink -e -- "$directory" 2>/dev/null) || return 1
    [ "$directory" = "$logical" ] && [ "$logical" = "$resolved" ] || return 1
    metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || return 1
    case "$metadata" in 0:0:700|0:0:755) return 0 ;; *) return 1 ;; esac
}

rr_uninstall_runtime_certificate_hook_source_is_owned() {
    local source="${RR_RUNTIME_DIR:-/usr/local/lib/rr}/scripts/naive-cert-hook.sh"
    [ -f "$source" ] && [ ! -L "$source" ] && [ -s "$source" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$source" 2>/dev/null)" = 0:0:755:1 ] || \
        return 1
    bash -n "$source" >/dev/null 2>&1 || return 1
    RR_UNINSTALL_CERT_HOOK_SOURCE_SHA256=$(sha256sum -- "$source" 2>/dev/null | \
        awk '{print $1}') || return 1
    [[ "$RR_UNINSTALL_CERT_HOOK_SOURCE_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
        return 1
    case "$RR_UNINSTALL_CERT_HOOK_SOURCE_SHA256" in
        # Exact generic RR deploy-hook releases: current multi-consumer hook,
        # the earlier 7.2.0 hooks, and the 7.1.0 hook. Requiring this immutable
        # anchor prevents two identically tampered files from vouching for one
        # another merely because their dynamic hashes still match.
        f908141e58c8f9abce04c6190072ef878dac768bbd8ba8b100f561847ce7c7ff|\
        8ac94f81afc303961f4db4f5a3fb2112546b1a1f518f1aca5d0c5cc8eac86201|\
        2c1a37523913e0c5f50ffc20348b257f7fc8bac5c6204bc158bf44baa05fd86d|\
        61540febb8728180eb585d7788eedd63d742603652ed520d7c6fec2ef64cfc04)
            return 0
            ;;
        *) return 1 ;;
    esac
}

rr_uninstall_current_certificate_hook_is_owned() {
    local directory="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local hook="$directory/rr-certificates.sh" hook_hash=""
    rr_uninstall_certificate_hook_directory_is_safe || return 1
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || \
        return 1
    rr_uninstall_runtime_certificate_hook_source_is_owned || return 1
    [ -f "$hook" ] && [ ! -L "$hook" ] && [ -s "$hook" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$hook" 2>/dev/null)" = 0:0:700:1 ] || \
        return 1
    bash -n "$hook" >/dev/null 2>&1 || return 1
    hook_hash=$(sha256sum -- "$hook" 2>/dev/null | awk '{print $1}') || return 1
    [[ "$hook_hash" =~ ^[0-9a-f]{64}$ ]] && \
        [ "$hook_hash" = "$RR_UNINSTALL_CERT_HOOK_SOURCE_SHA256" ] && \
        cmp -s -- "$hook" \
            "${RR_RUNTIME_DIR:-/usr/local/lib/rr}/scripts/naive-cert-hook.sh"
}

rr_uninstall_legacy_certificate_hook_is_owned() {
    local directory="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local hook="$directory/rr-naive-cert.sh" hook_hash=""
    rr_uninstall_certificate_hook_directory_is_safe || return 1
    [ -f "$hook" ] && [ ! -L "$hook" ] && [ -s "$hook" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$hook" 2>/dev/null)" = 0:0:700:1 ] || \
        return 1
    bash -n "$hook" >/dev/null 2>&1 || return 1
    hook_hash=$(sha256sum -- "$hook" 2>/dev/null | awk '{print $1}') || return 1
    case "$hook_hash" in
        # RR-vps 6.6.x inline hook, followed by every generic RR deploy hook
        # known to have been installed under the legacy filename.
        360b767dae048b960794ab69a979ee9794619ee51166d7865e32febf75ff6fe4|\
        f908141e58c8f9abce04c6190072ef878dac768bbd8ba8b100f561847ce7c7ff|\
        8ac94f81afc303961f4db4f5a3fb2112546b1a1f518f1aca5d0c5cc8eac86201|\
        2c1a37523913e0c5f50ffc20348b257f7fc8bac5c6204bc158bf44baa05fd86d|\
        61540febb8728180eb585d7788eedd63d742603652ed520d7c6fec2ef64cfc04)
            return 0
            ;;
        *) return 1 ;;
    esac
}

rr_uninstall_certificate_hooks_are_owned() {
    local directory="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local current="$directory/rr-certificates.sh" legacy="$directory/rr-naive-cert.sh"
    if [ ! -e "$current" ] && [ ! -L "$current" ] && \
       [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
        return 0
    fi
    rr_uninstall_certificate_hook_directory_is_safe || return 1
    if [ -e "$current" ] || [ -L "$current" ]; then
        rr_uninstall_current_certificate_hook_is_owned || return 1
    fi
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
        rr_uninstall_legacy_certificate_hook_is_owned || return 1
    fi
}

rr_uninstall_remove_owned_certificate_hooks() {
    local directory="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local current="$directory/rr-certificates.sh" legacy="$directory/rr-naive-cert.sh"
    rr_uninstall_certificate_hooks_are_owned || return 1
    if [ -e "$current" ] || [ -L "$current" ]; then
        rr_uninstall_current_certificate_hook_is_owned || return 1
        rm -f -- "$current" || return 1
        sync -f "$directory" || return 1
    fi
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
        rr_uninstall_legacy_certificate_hook_is_owned || return 1
        rm -f -- "$legacy" || return 1
        sync -f "$directory" || return 1
    fi
    [ ! -e "$current" ] && [ ! -L "$current" ] && \
        [ ! -e "$legacy" ] && [ ! -L "$legacy" ]
}

# Prove the effective identity of an IP-ACME unit before a full uninstall is
# allowed to stop it.  Merely finding the RR marker in the on-disk fragment is
# insufficient: an untrusted drop-in can add ExecStop= and turn `systemctl
# stop` itself into a side effect.  A missing fragment is accepted only when
# systemd also proves that no stale/generated unit with the same name remains.
rr_uninstall_ip_acme_parent_chain_is_safe() {
    local path="${1:-}" parent="" logical="" resolved="" current=""
    local metadata="" owner="" group="" mode="" mode_value=0 next=""
    [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    parent=$(dirname -- "$path") || return 1

    # A fixed final name may legitimately be absent after an interrupted
    # uninstall.  Still authenticate its nearest existing ancestor: skipping
    # an absent final item would also skip an already-present intermediate
    # symlink or writable directory later traversed by the broad remover.
    while [ ! -e "$parent" ] && [ ! -L "$parent" ]; do
        next=$(dirname -- "$parent") || return 1
        [ "$next" != "$parent" ] || return 1
        parent="$next"
    done
    [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
    logical=$(realpath -ms -- "$parent" 2>/dev/null) || return 1
    resolved=$(readlink -e -- "$parent" 2>/dev/null) || return 1
    [ "$parent" = "$logical" ] && [ "$logical" = "$resolved" ] || return 1

    # `readlink -e` proves that no component is a symlink.  Check ownership and
    # writability component-by-component as well: a group/world-writable
    # ancestor could otherwise be exchanged after the final item's exact hash
    # was authenticated but before unlink/rmdir follows the same textual path.
    current="$parent"
    while :; do
        [ -d "$current" ] && [ ! -L "$current" ] || return 1
        metadata=$(stat -c '%u:%g:%a' -- "$current" 2>/dev/null) || return 1
        IFS=: read -r owner group mode <<< "$metadata"
        [ "$owner" = 0 ] && [ "$group" = 0 ] && \
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
        mode_value=$((8#$mode))
        (( (mode_value & 8#022) == 0 )) || return 1
        [ "$current" != / ] || break
        next=$(dirname -- "$current") || return 1
        [ "$next" != "$current" ] || return 1
        current="$next"
    done
}

rr_uninstall_ip_acme_existing_parent_chains_are_safe() {
    local path=""
    [ "$#" -gt 0 ] || return 1
    for path in "$@"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
        rr_uninstall_ip_acme_parent_chain_is_safe "$path" || return 1
    done
}

rr_uninstall_ip_acme_unit_is_safe() {
    local unit_file="${1:-}" kind="${2:-}" unit_name="${3:-}"
    local load_state="" active_state="" unit_file_state=""
    local fragment_path="" dropin_paths=""
    case "$kind:$unit_name" in
        service:rr-nexus-ip-acme.service|timer:rr-nexus-ip-acme.timer) ;;
        *) return 1 ;;
    esac
    [[ "$unit_file" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    load_state=$(systemctl show "$unit_name" -p LoadState --value \
        2>/dev/null) || return 1
    active_state=$(systemctl show "$unit_name" -p ActiveState --value \
        2>/dev/null) || return 1
    unit_file_state=$(systemctl show "$unit_name" -p UnitFileState --value \
        2>/dev/null) || return 1
    fragment_path=$(systemctl show "$unit_name" -p FragmentPath --value \
        2>/dev/null) || return 1
    dropin_paths=$(systemctl show "$unit_name" -p DropInPaths --value \
        2>/dev/null) || return 1
    [ -n "$unit_file_state" ] || unit_file_state=not-found

    if [ ! -e "$unit_file" ] && [ ! -L "$unit_file" ]; then
        [ "$load_state:$active_state:$unit_file_state" = \
            not-found:inactive:not-found ] && \
            [ -z "$fragment_path" ] && [ -z "$dropin_paths" ]
        return $?
    fi
    declare -F nexus_ip_acme_unit_is_current >/dev/null 2>&1 || return 1
    nexus_ip_acme_unit_is_current "$unit_file" "$kind" || return 1
    [ -z "$dropin_paths" ] || return 1
    case "$load_state" in
        loaded)
            [ "$fragment_path" = "$unit_file" ] || return 1
            case "$kind:$unit_file_state" in
                service:static|timer:enabled|timer:disabled) ;;
                *) return 1 ;;
            esac
            ;;
        not-found)
            # A crash between writing the exact fragment and daemon-reload is
            # safe to clean: systemd proves it cannot currently be active.
            [ "$active_state" = inactive ] && [ -z "$fragment_path" ] && \
                [ "$unit_file_state" = not-found ] || return 1
            ;;
        *) return 1 ;;
    esac
}

rr_uninstall_ip_acme_unit_is_absent() {
    local unit_name="${1:-}" load_state="" active_state=""
    local unit_file_state="" fragment_path="" dropin_paths=""
    case "$unit_name" in
        rr-nexus-ip-acme.service|rr-nexus-ip-acme.timer) ;;
        *) return 1 ;;
    esac
    load_state=$(systemctl show "$unit_name" -p LoadState --value \
        2>/dev/null) || return 1
    active_state=$(systemctl show "$unit_name" -p ActiveState --value \
        2>/dev/null) || return 1
    unit_file_state=$(systemctl show "$unit_name" -p UnitFileState --value \
        2>/dev/null) || return 1
    fragment_path=$(systemctl show "$unit_name" -p FragmentPath --value \
        2>/dev/null) || return 1
    dropin_paths=$(systemctl show "$unit_name" -p DropInPaths --value \
        2>/dev/null) || return 1
    [ -n "$unit_file_state" ] || unit_file_state=not-found
    [ "$load_state:$active_state:$unit_file_state" = \
        not-found:inactive:not-found ] && \
        [ -z "$fragment_path" ] && [ -z "$dropin_paths" ]
}

# Render the domain-panel vhosts byte-for-byte as module 85 publishes them.
# These are pure renderers: full uninstall must never invoke the mutating
# module-85 writers merely to decide whether a fixed filename is RR-owned.
rr_uninstall_emit_nexus_domain_http_site() {
    local domain="${1:-}" webroot="${2:-}" legacy="${3:-false}"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] && \
        [ "$domain" = "${domain,,}" ] || return 1
    case "$legacy" in true|false) ;; *) return 1 ;; esac
    if [ "$legacy" = true ]; then
        webroot=/var/www/rr-nexus-certbot
    else
        [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
            [[ "/$webroot/" != *'/../'* && "/$webroot/" != *'/./'* && \
               "$webroot" != *//* ]] || return 1
    fi
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    client_max_body_size 32k;

EOF
    if [ "$legacy" = true ]; then
        cat <<EOF
    location /.well-known/acme-challenge/ {
        root ${webroot};
    }
EOF
    else
        cat <<EOF
    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }
EOF
    fi
    cat <<'EOF'

    location / {
        return 444;
    }
}
EOF
}

rr_uninstall_emit_nexus_domain_tls_site() {
    local domain="${1:-}" port="${2:-}" webroot="${3:-}"
    local legacy="${4:-false}"
    [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] && \
        [ "$domain" = "${domain,,}" ] || return 1
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] && \
        [ "$port" != 80 ] && [ "$port" != 7900 ] || return 1
    case "$legacy" in true|false) ;; *) return 1 ;; esac
    if [ "$legacy" = true ]; then
        webroot=/var/www/rr-nexus-certbot
    else
        [[ "$webroot" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
            [[ "/$webroot/" != *'/../'* && "/$webroot/" != *'/./'* && \
               "$webroot" != *//* ]] || return 1
    fi
    cat <<EOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name ${domain};
    client_max_body_size 32k;
    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    # 热更新时，已打开但未刷新的旧页面可能仍把订阅 token 放在
    # ?raw= 查询串。后端会拒绝它，但 Nginx 必须在转发前就停止记录。
    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    location = /api/login {
        limit_req zone=rr_nexus_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
EOF
    if [ "$legacy" = true ]; then
        cat <<EOF
    location /.well-known/acme-challenge/ {
        root ${webroot};
    }
EOF
    else
        cat <<EOF
    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }
EOF
    fi
    cat <<EOF
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
    location / {
        return 301 https://\$host:${port}\$request_uri;
    }
}
EOF
}

# Render the only two IP-panel vhosts that module 85 can publish.  Full
# uninstall uses this as byte-for-byte ownership evidence before calling the
# generic proxy remover, whose filename-based cleanup must never be allowed to
# unlink a third-party same-name Nginx site.
rr_uninstall_emit_nexus_ip_site() {
    local port="${1:-}" cert_file="${2:-}" key_file="${3:-}"
    local certificate_mode="${4:-}" legacy="${5:-false}"
    local subscription_location_block=""
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$port" -le 65535 ] && \
        [ "$port" != 80 ] && [ "$port" != 7900 ] || return 1
    [[ "$cert_file" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
        [[ "$key_file" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    case "$legacy" in true|false) ;; *) return 1 ;; esac
    case "$certificate_mode" in
        acme-ip-shortlived|pending-acme-ip)
            [ "$legacy" = false ] || return 1
            subscription_location_block=$(cat <<'NGXSUB'
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
NGXSUB
            ) || return 1
            ;;
        legacy-self-signed)
            if [ "$legacy" = true ]; then
                subscription_location_block=$(cat <<'NGXSUB'
    # IP 模式使用自签证书，不能作为订阅客户端的可信入口。即使调用方
    # 知道设备 token，也必须在代理层拒绝，且不能把 token 写入日志。
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
NGXSUB
                ) || return 1
            else
                subscription_location_block=$(cat <<'NGXSUB'
    # Legacy self-signed IP mode is panel-only.  Tokens are never forwarded.
    location = /sub {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }

    location ^~ /sub/ {
        access_log off;
        error_log /dev/null crit;
        return 404;
    }
NGXSUB
                ) || return 1
            fi
            ;;
        *) return 1 ;;
    esac
    cat <<NGXEOF
limit_req_zone \$binary_remote_addr zone=rr_nexus_ip_login:10m rate=10r/m;

server {
    listen ${port} ssl;
    listen [::]:${port} ssl;
    server_name _;
    client_max_body_size 32k;
    ssl_certificate ${cert_file};
    ssl_certificate_key ${key_file};
    ssl_protocols TLSv1.2 TLSv1.3;

${subscription_location_block}

    location ~ ^/api/(devices/[^/]+/qr|remote/qr)/?$ {
        access_log off;
        error_log /dev/null crit;
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    location = /api/login {
        limit_req zone=rr_nexus_ip_login burst=5 nodelay;
        proxy_pass http://127.0.0.1:7900;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }

    location / {
        proxy_pass http://127.0.0.1:7900;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout 65s;
    }
}
NGXEOF
}

rr_uninstall_nexus_rendered_site_pair_is_safe() {
    local site="${1:-}" enabled="${2:-}" renderer="${3:-}"
    local expected_content="" expected="" actual="" target=""
    shift 3 || return 1
    for _rr_proxy_site_path in "$site" "$enabled"; do
        [[ "$_rr_proxy_site_path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    done
    case "$renderer" in
        rr_uninstall_emit_nexus_domain_http_site|rr_uninstall_emit_nexus_domain_tls_site|rr_uninstall_emit_nexus_ip_site) ;;
        *) return 1 ;;
    esac
    expected_content=$("$renderer" "$@") || return 1
    expected=$(printf '%s\n' "$expected_content" | sha256sum | awk '{print $1}') || \
        return 1
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    if [ -e "$site" ] || [ -L "$site" ]; then
        [ -f "$site" ] && [ ! -L "$site" ] || return 1
        [ "$(stat -c '%u:%g:%a:%h' -- "$site" 2>/dev/null)" = \
            0:0:644:1 ] || return 1
        actual=$(sha256sum -- "$site" 2>/dev/null | awk '{print $1}') || \
            return 1
        [ "$actual" = "$expected" ] || return 1
    fi
    if [ -e "$enabled" ] || [ -L "$enabled" ]; then
        [ -L "$enabled" ] || return 1
        [ "$(stat -c '%u:%g:%a:%h' -- "$enabled" 2>/dev/null)" = \
            0:0:777:1 ] || \
            return 1
        target=$(readlink -- "$enabled" 2>/dev/null) || return 1
        [ "$target" = "$site" ] || return 1
    fi
}

rr_uninstall_nexus_ip_site_is_safe() {
    local site="${1:-}" enabled="${2:-}" port="${3:-}"
    local cert_file="${4:-}" key_file="${5:-}" certificate_mode="${6:-}"
    [[ "$cert_file" =~ ^/[A-Za-z0-9_./-]+$ ]] && \
        [[ "$key_file" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    if rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
        rr_uninstall_emit_nexus_ip_site "$port" "$cert_file" "$key_file" \
            "$certificate_mode" false; then
        return 0
    fi
    # 7.1 self-signed sites differ only in their explanatory deny comment.
    # Accept that known renderer only when an actual site needs attribution;
    # a link-only crash state is already handled by the current exact target.
    [ "$certificate_mode" = legacy-self-signed ] && \
        { [ -e "$site" ] || [ -L "$site" ]; } || return 1
    rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
        rr_uninstall_emit_nexus_ip_site "$port" "$cert_file" "$key_file" \
        legacy-self-signed true
}

rr_uninstall_nexus_domain_http_site_is_safe() {
    local site="${1:-}" enabled="${2:-}" domain="${3:-}" webroot="${4:-}"
    if rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
            rr_uninstall_emit_nexus_domain_http_site "$domain" "$webroot" \
            false; then
        return 0
    fi
    [ -e "$site" ] || [ -L "$site" ] || return 1
    rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
        rr_uninstall_emit_nexus_domain_http_site "$domain" "$webroot" true
}

rr_uninstall_nexus_domain_tls_site_is_safe() {
    local site="${1:-}" enabled="${2:-}" domain="${3:-}" port="${4:-}"
    local webroot="${5:-}"
    if rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
            rr_uninstall_emit_nexus_domain_tls_site "$domain" "$port" \
            "$webroot" false; then
        return 0
    fi
    [ -e "$site" ] || [ -L "$site" ] || return 1
    rr_uninstall_nexus_rendered_site_pair_is_safe "$site" "$enabled" \
        rr_uninstall_emit_nexus_domain_tls_site "$domain" "$port" \
        "$webroot" true
}

rr_uninstall_nexus_proxy_paths_are_absent() {
    local path=""
    [ "$#" -gt 0 ] || return 1
    for path in "$@"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
        [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    done
}

# Authenticate every path that nexus_remove_public_proxy() will unlink.  Its
# implementation is intentionally a broad filename cleanup API, so callers
# must supply the ownership boundary.  `ip-intent` permits a safe retry of an
# older public->local transition only when the durable intent reproduces the
# exact former IP vhost; an unrelated local/absent configuration owns none of
# these names.
rr_uninstall_nexus_proxy_set_is_safe() {
    local authority="${1:-}" address="${2:-}" port="${3:-}"
    local certificate_mode="${4:-}" available_dir="${5:-}"
    local enabled_dir="${6:-}" base_site="${7:-}" cert_file="${8:-}"
    local key_file="${9:-}" webroot="${10:-}"
    local domain_enabled="$enabled_dir/rr-nexus.conf"
    local port_enabled="$enabled_dir/rr-nexus-port.conf"
    local ip_site="$available_dir/rr-nexus-ip.conf"
    local ip_enabled="$enabled_dir/rr-nexus-ip.conf"
    local port_site="${base_site}.port"
    for _rr_proxy_path in "$available_dir" "$enabled_dir" "$base_site" \
        "$domain_enabled" "$port_site" "$port_enabled" "$ip_site" \
        "$ip_enabled"; do
        [[ "$_rr_proxy_path" =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
    done
    case "$authority" in
        absent)
            rr_uninstall_nexus_proxy_paths_are_absent \
                "$base_site" "$domain_enabled" "$port_site" "$port_enabled" \
                "$ip_site" "$ip_enabled"
            ;;
        ip|ip-intent)
            rr_uninstall_nexus_proxy_paths_are_absent \
                "$base_site" "$domain_enabled" "$port_site" "$port_enabled" && \
                rr_uninstall_nexus_ip_site_is_safe "$ip_site" "$ip_enabled" \
                    "$port" "$cert_file" "$key_file" "$certificate_mode"
            ;;
        domain)
            rr_uninstall_nexus_proxy_paths_are_absent "$ip_site" "$ip_enabled" && \
                rr_uninstall_nexus_domain_http_site_is_safe \
                    "$base_site" "$domain_enabled" "$address" "$webroot" && \
                rr_uninstall_nexus_domain_tls_site_is_safe \
                    "$port_site" "$port_enabled" "$address" "$port" \
                    "$webroot"
            ;;
        *) return 1 ;;
    esac
}

uninstall_all() {
    local result=0
    echo -e "\n${RED}此操作会删除 rr、Sing-box、RR Nexus 数据库、节点配置、证书、订阅及本脚本防火墙规则。${RESET}"
    read -p "确认完全卸载请输入 y: " uninstall_confirm
    if [ "$uninstall_confirm" != "y" ] && [ "$uninstall_confirm" != "Y" ]; then
        echo -e "${YELLOW}已取消卸载，现有节点未改动。${RESET}"
        sleep 1
        return 0
    fi
    echo -e "\n${RED}正在完全卸载并清理残留...${RESET}"
    rr_run_with_update_locks direct 0 uninstall_all_locked || result=$?
    case "$result" in
        0) exit 0 ;;
        75)
            echo -e "${RED}[失败] 更新、恢复、备份或健康修复正在运行，已拒绝并发卸载。${RESET}" >&2
            return 1
            ;;
        76)
            echo -e "${RED}[失败] 共享事务锁或旧版兼容锁不安全，已拒绝卸载。${RESET}" >&2
            return 1
            ;;
        *) return "$result" ;;
    esac
}

uninstall_all_locked() {
    local reinstall_url="https://github.com/Xiaowu7z/RR-vps/releases/latest/download/install.sh"
    local project_url="https://github.com/Xiaowu7z/RR-vps"
    local legacy_restore_lock_file="${RR_LEGACY_RESTORE_LOCK_FILE:-/run/lock/rr-restore-live.lock}"
    local legacy_restore_lock_fd="" firewall_status=0 stop_status=0
    local restore_gate_unit=""
    local ip_acme_present=false ip_acme_address="" ip_acme_email=""
    local ip_acme_nexus_address="" ip_acme_certificate_mode=""
    local ip_acme_nexus_mode="" ip_acme_nexus_port=""
    local ip_acme_expected_site="" ip_acme_actual_site="" ip_acme_link_target=""
    local ip_acme_state_root="${NEXUS_IP_ACME_STATE_ROOT:-/var/lib/rr-nexus/ip-acme}"
    local ip_acme_webroot="${NEXUS_IP_ACME_WEBROOT:-/var/www/rr-nexus-ip-acme}"
    local ip_acme_service_file="${NEXUS_IP_ACME_SERVICE_FILE:-/etc/systemd/system/rr-nexus-ip-acme.service}"
    local ip_acme_timer_file="${NEXUS_IP_ACME_TIMER_FILE:-/etc/systemd/system/rr-nexus-ip-acme.timer}"
    local ip_acme_nginx_available="${NEXUS_IP_ACME_NGINX_AVAILABLE:-/etc/nginx/sites-available/rr-nexus-ip-acme-http.conf}"
    local ip_acme_nginx_enabled="${NEXUS_IP_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-nexus-ip-acme-http.conf}"
    local ip_acme_lego_bin="${NEXUS_IP_ACME_LEGO_BIN:-/usr/local/lib/rr-vps/lego}"
    local ip_acme_lego_marker="${NEXUS_IP_ACME_LEGO_MARKER:-/usr/local/lib/rr-vps/lego.install}"
    local ip_cert_file="${NEXUS_IP_ACME_LIVE_CERT:-/etc/rr-nexus/certs/ip.crt}"
    local ip_key_file="${NEXUS_IP_ACME_LIVE_KEY:-/etc/rr-nexus/certs/ip.key}"
    local ip_pending_file="${NEXUS_IP_ACME_PENDING:-/etc/rr-nexus/certs/.ip-cert-pending}"
    local ip_gate_script="${NEXUS_IP_CERT_GATE_SCRIPT:-/usr/local/lib/rr-vps/nexus-ip-cert-gate}"
    local ip_gate_dropin="${NEXUS_IP_CERT_GATE_DROPIN:-/etc/systemd/system/nginx.service.d/zzzzzz-rr-nexus-ip-cert-gate.conf}"
    local ip_proxy_available_dir="${NEXUS_NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
    local ip_proxy_enabled_dir="${NEXUS_NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
    local ip_proxy_site="" ip_proxy_enabled="" ip_proxy_is_ip=false
    local ip_proxy_authority=absent ip_proxy_domain=""
    local ip_proxy_webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    local ip_proxy_intent="" ip_proxy_intent_address=""
    local ip_proxy_intent_port="" ip_proxy_intent_mode=""
    local ip_proxy_config_present=false
    local ip_cert_dir="" ip_cert_pair_present=false ip_cert_cleanup_needed=false
    local ip_acme_preflight_status=0
    local -a ip_acme_owned_artifacts=()
    local -a ip_proxy_retired_paths=()
    ip_proxy_site="$ip_proxy_available_dir/rr-nexus-ip.conf"
    ip_proxy_enabled="$ip_proxy_enabled_dir/rr-nexus-ip.conf"
    ip_proxy_retired_paths=(
        "$ip_proxy_enabled_dir/rr-nexus.conf"
        "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}"
        "$ip_proxy_enabled_dir/rr-nexus-port.conf"
        "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}.port"
    )
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] && \
        load_config_with_defaults || {
        echo -e "${RED}[失败] 主配置缺失或不可信，无法证明 RR 资产归属；未执行卸载。${RESET}" >&2
        return 1
    }
    # The outer supervisor already owns new then legacy-update locks. Keep the
    # old restore-live compatibility inode too when it exists, without creating
    # or changing it.
    if ! _uninstall_acquire_existing_legacy_lock \
            "$legacy_restore_lock_file" legacy_restore_lock_fd; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 检测到旧版更新或恢复事务仍在运行，已拒绝并发卸载。${RESET}" >&2
        return 1
    fi
    # Bind every runtime deletion and both fixed recovery-helper paths to the
    # installed manifest before publishing the first crash gate.  Later checks
    # use these hashes after the runtime itself has been durably removed.
    if ! rr_uninstall_capture_runtime_ownership; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] RR 运行时、manifest 或独立恢复程序的路径/元数据/哈希不匹配；完整卸载尚未开始。${RESET}" >&2
        return 2
    fi
    if _uninstall_quarantine_present; then
        if ! _uninstall_recovery_helper_is_trusted \
                "${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}" || \
           ! rr_uninstall_subscription_quarantine_artifacts_are_owned; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] 旧订阅隔离证据、Unit 或独立 guard 不属于已验证的 RR 运行时；完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
    fi
    # Refuse before the crash gate or any other destructive operation when a
    # Certbot hook at an RR filename cannot be proven byte-for-byte RR-owned.
    # Leaving an unowned hook untouched is safer than deleting a third-party
    # integration, while aborting the whole uninstall avoids leaving a hook
    # that points at a runtime removed later in this function.
    if ! rr_uninstall_certificate_hooks_are_owned; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] Certbot deploy hook 与当前或历史 RR 精确内容/哈希/元数据不符；按第三方或篡改文件保留，完整卸载尚未开始。请先移走同名 hook 后重试。${RESET}" >&2
        return 2
    fi
    # IP-ACME-PREFLIGHT-BEGIN
    # Prove every fixed-path IP-ACME artifact before the crash gate performs
    # the first destructive operation.  The module-86 uninstall is itself
    # fail-closed, but this complete preflight also prevents a later foreign
    # HTTP-01 site, unit, store, binary, live pair, pending marker or Nginx
    # gate from turning a full uninstall into a partially applied one.
    ip_acme_owned_artifacts=(
        "$ip_acme_state_root" "$ip_acme_webroot"
        "$ip_acme_service_file" "$ip_acme_timer_file"
        "$ip_acme_nginx_available" "$ip_acme_nginx_enabled"
        "$ip_acme_lego_bin" "$ip_acme_lego_marker"
    )
    for _rr_ip_acme_path in "${ip_acme_owned_artifacts[@]}" \
        "$ip_cert_file" "$ip_key_file" "$ip_pending_file" \
        "$ip_gate_script" "$ip_gate_dropin" \
        "$ip_proxy_site" "$ip_proxy_enabled" \
        "${ip_proxy_retired_paths[@]}"; do
        [[ "$_rr_ip_acme_path" =~ ^/[A-Za-z0-9_./-]+$ ]] || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] IP ACME 卸载路径不是可证明的绝对固定路径；完整卸载尚未开始。${RESET}" >&2
            return 2
        }
    done
    if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
            "${ip_acme_owned_artifacts[@]}" \
            "$ip_cert_file" "$ip_key_file" "$ip_pending_file" \
            "$ip_gate_script" "$ip_gate_dropin" \
            "$ip_proxy_site" "$ip_proxy_enabled" \
            "${ip_proxy_retired_paths[@]}" \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}"; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] IP ACME 固定资产的父目录链包含符号链接、非 root 目录或可写目录；完整卸载尚未开始。${RESET}" >&2
        return 2
    fi
    ip_cert_dir=$(dirname -- "$ip_cert_file") || return 2
    [ "$(dirname -- "$ip_key_file")" = "$ip_cert_dir" ] && \
        [ "$(dirname -- "$ip_pending_file")" = "$ip_cert_dir" ] || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] IP 证书、私钥与 pending 标记不在同一受管目录；完整卸载尚未开始。${RESET}" >&2
        return 2
    }

    if [ -e "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] || \
       [ -L "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ]; then
        ip_proxy_config_present=true
        [ -f "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] && \
            [ ! -L "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" ] && \
            [ "$(stat -c '%u:%g:%a:%h' -- \
                "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null)" = \
                0:0:600:1 ] || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] Nexus 配置不是 RR 自有的 root:root 0600 常规文件；完整卸载尚未开始。${RESET}" >&2
            return 2
        }
        ip_acme_certificate_mode=$(jq -r '.certificate_mode // "legacy-self-signed"' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return 2
        }
        ip_acme_nexus_mode=$(jq -r '.mode // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return 2
        }
        ip_acme_nexus_port=$(jq -r '.public_port // empty' \
            "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return 2
        }
        ip_acme_nexus_address=$(jq -r '
            if (.domain // "") == "ip" or (.domain // "") == ""
            then (.ssh_host // "") else .domain end
        ' "${NEXUS_CONFIG_FILE:-/etc/rr-nexus/nexus.json}" 2>/dev/null) || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return 2
        }
        ip_acme_nexus_address="${ip_acme_nexus_address#[}"
        ip_acme_nexus_address="${ip_acme_nexus_address%]}"
        if declare -F nexus_ip_acme_normalize_address >/dev/null 2>&1 && \
           nexus_ip_acme_normalize_address "$ip_acme_nexus_address" \
                >/dev/null 2>&1; then
            ip_proxy_is_ip=true
        fi
        case "$ip_acme_nexus_mode" in
            local)
                ip_proxy_authority=absent
                ;;
            public)
                [[ "$ip_acme_nexus_port" =~ ^[1-9][0-9]{0,4}$ ]] && \
                    [ "$ip_acme_nexus_port" -le 65535 ] && \
                    [ "$ip_acme_nexus_port" != 80 ] && \
                    [ "$ip_acme_nexus_port" != 7900 ] || \
                    ip_acme_preflight_status=1
                if [ "$ip_proxy_is_ip" = true ]; then
                    case "$ip_acme_certificate_mode" in
                        acme-ip-shortlived|pending-acme-ip|legacy-self-signed)
                            ip_proxy_authority=ip
                            ip_proxy_domain="$ip_acme_nexus_address"
                            ;;
                        *) ip_acme_preflight_status=1 ;;
                    esac
                elif [[ "$ip_acme_nexus_address" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] && \
                     [ "$ip_acme_nexus_address" = \
                       "${ip_acme_nexus_address,,}" ]; then
                    ip_proxy_authority=domain
                    ip_proxy_domain="$ip_acme_nexus_address"
                else
                    ip_acme_preflight_status=1
                fi
                ;;
            *) ip_acme_preflight_status=1 ;;
        esac
        case "$ip_acme_certificate_mode" in
            acme-ip-shortlived|pending-acme-ip) ip_acme_present=true ;;
        esac
    fi

    # A durable uninstall intent is the only authority that can explain a
    # still-exact IP vhost after an older public->local transition was killed.
    # Without it, local or absent Nexus configuration owns none of the six
    # filenames and every collision must be preserved.
    if [ "$ip_proxy_authority" = absent ]; then
        if declare -F nexus_ip_acme_uninstall_intent_path >/dev/null 2>&1; then
            ip_proxy_intent=$(nexus_ip_acme_uninstall_intent_path) || \
                ip_acme_preflight_status=1
        else
            ip_proxy_intent="${NEXUS_DATA_DIR:-/var/lib/rr-nexus}/ip-acme-uninstall-intent.json"
        fi
        if [ -n "$ip_proxy_intent" ] && \
           { [ -e "$ip_proxy_intent" ] || [ -L "$ip_proxy_intent" ]; }; then
            if { [ "$ip_proxy_config_present" = false ] || \
                 [ "$ip_acme_nexus_mode" = local ]; } && \
               declare -F nexus_ip_acme_uninstall_intent_is_safe \
                    >/dev/null 2>&1 && \
               nexus_ip_acme_uninstall_intent_is_safe "$ip_proxy_intent"; then
                ip_proxy_intent_address=$(jq -r '.domain' \
                    "$ip_proxy_intent" 2>/dev/null) || ip_acme_preflight_status=1
                ip_proxy_intent_port=$(jq -r '.public_port' \
                    "$ip_proxy_intent" 2>/dev/null) || ip_acme_preflight_status=1
                ip_proxy_intent_mode=$(jq -r '.certificate_mode' \
                    "$ip_proxy_intent" 2>/dev/null) || ip_acme_preflight_status=1
                if [ "$ip_acme_preflight_status" -eq 0 ]; then
                    ip_proxy_authority=ip-intent
                    ip_proxy_domain="$ip_proxy_intent_address"
                    ip_acme_nexus_port="$ip_proxy_intent_port"
                    ip_acme_certificate_mode="$ip_proxy_intent_mode"
                fi
            fi
        fi
    fi
    for _rr_ip_acme_path in "${ip_acme_owned_artifacts[@]}"; do
        if [ -e "$_rr_ip_acme_path" ] || [ -L "$_rr_ip_acme_path" ]; then
            ip_acme_present=true
        fi
    done
    for _rr_ip_cert_path in "$ip_cert_file" "$ip_key_file" \
        "$ip_pending_file" "$ip_gate_script" "$ip_gate_dropin"; do
        if [ -e "$_rr_ip_cert_path" ] || [ -L "$_rr_ip_cert_path" ]; then
            ip_cert_cleanup_needed=true
        fi
    done

    if [ "$ip_acme_present" = true ]; then
        for _rr_ip_acme_function in nexus_ip_acme_uninstall \
            nexus_ip_acme_state_tree_is_owned nexus_ip_acme_read_config \
            nexus_ip_acme_unit_is_current nexus_ip_acme_webroot_is_safe \
            nexus_ip_acme_path_is_mountpoint \
            nexus_ip_acme_nginx_http_site_is_owned \
            nexus_ip_acme_emit_nginx_http_site \
            nexus_ip_acme_lego_marker_is_current \
            nexus_ip_acme_normalize_address; do
            declare -F "$_rr_ip_acme_function" >/dev/null 2>&1 || \
                ip_acme_preflight_status=1
        done
        if [ "$ip_acme_preflight_status" -eq 0 ]; then
            if [ -e "$ip_acme_state_root" ] || [ -L "$ip_acme_state_root" ]; then
                if ! nexus_ip_acme_state_tree_is_owned || \
                   nexus_ip_acme_path_is_mountpoint "$ip_acme_state_root" || \
                   ! nexus_ip_acme_read_config ip_acme_address ip_acme_email; then
                    ip_acme_preflight_status=1
                fi
            fi
            if [ -n "$ip_acme_nexus_address" ] && \
               { [ "$ip_acme_certificate_mode" = acme-ip-shortlived ] || \
                 [ "$ip_acme_certificate_mode" = pending-acme-ip ]; }; then
                local _rr_normalized_ip_acme_address=""
                if ! nexus_ip_acme_normalize_address "$ip_acme_nexus_address" \
                        _rr_normalized_ip_acme_address || \
                   [[ -n "$ip_acme_address" && \
                      "$ip_acme_address" != "$_rr_normalized_ip_acme_address" ]]; then
                    ip_acme_preflight_status=1
                else
                    ip_acme_nexus_address="$_rr_normalized_ip_acme_address"
                fi
            fi
            [ -n "$ip_acme_address" ] || ip_acme_address="$ip_acme_nexus_address"

            if [ -e "$ip_acme_webroot" ] || [ -L "$ip_acme_webroot" ]; then
                if ! nexus_ip_acme_webroot_is_safe || \
                   nexus_ip_acme_path_is_mountpoint "$ip_acme_webroot"; then
                    ip_acme_preflight_status=1
                fi
            fi
            if [ -e "$ip_acme_nginx_available" ] || \
               [ -L "$ip_acme_nginx_available" ]; then
                if [ -z "$ip_acme_address" ] || \
                   ! nexus_ip_acme_nginx_http_site_is_owned || \
                   ! ip_acme_expected_site=$(nexus_ip_acme_emit_nginx_http_site \
                        "$ip_acme_address" | sha256sum | awk '{print $1}') || \
                   ! ip_acme_actual_site=$(sha256sum -- \
                        "$ip_acme_nginx_available" | awk '{print $1}') || \
                   [ "$ip_acme_expected_site" != "$ip_acme_actual_site" ]; then
                    ip_acme_preflight_status=1
                fi
            fi
            if [ -e "$ip_acme_nginx_enabled" ] || \
               [ -L "$ip_acme_nginx_enabled" ]; then
                if [ ! -L "$ip_acme_nginx_enabled" ] || \
                   ! ip_acme_link_target=$(readlink -- \
                        "$ip_acme_nginx_enabled") || \
                   [ "$ip_acme_link_target" != "$ip_acme_nginx_available" ] || \
                   [ ! -f "$ip_acme_nginx_available" ] || \
                   [ -L "$ip_acme_nginx_available" ]; then
                    ip_acme_preflight_status=1
                fi
            fi
            if [ -e "$ip_acme_lego_bin" ] || [ -L "$ip_acme_lego_bin" ] || \
               [ -e "$ip_acme_lego_marker" ] || [ -L "$ip_acme_lego_marker" ]; then
                nexus_ip_acme_lego_marker_is_current || \
                    ip_acme_preflight_status=1
            fi
        fi
        if [ "$ip_acme_preflight_status" -ne 0 ]; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] IP ACME unit、HTTP-01 站点、账户库、webroot 或 lego 所有权无法完整证明；外来资产已保留，完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
    fi

    # Query systemd even when both fixed fragments are absent.  A unit can
    # remain loaded after its fragment was removed, and skipping that state
    # would leave a renewal process armed while the Nexus account tree is
    # deleted below.  Loaded units are accepted only with the exact current
    # fragment and no effective drop-ins.
    rr_uninstall_ip_acme_unit_is_safe "$ip_acme_service_file" service \
        rr-nexus-ip-acme.service || ip_acme_preflight_status=1
    rr_uninstall_ip_acme_unit_is_safe "$ip_acme_timer_file" timer \
        rr-nexus-ip-acme.timer || ip_acme_preflight_status=1
    if [ "$ip_acme_preflight_status" -ne 0 ]; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] IP ACME systemd unit、有效 Drop-in 或所有权状态无法完整证明；完整卸载尚未开始。${RESET}" >&2
        return 2
    fi

    # The generic remover authenticates no content of its own.  Prove all six
    # fixed paths against the exact public mode (or durable IP-uninstall
    # intent) before the crash gate. Local/absent state has no filename
    # authority and therefore accepts only six absent paths.
    if ! rr_uninstall_nexus_proxy_set_is_safe "$ip_proxy_authority" \
            "$ip_proxy_domain" "$ip_acme_nexus_port" \
            "$ip_acme_certificate_mode" "$ip_proxy_available_dir" \
            "$ip_proxy_enabled_dir" \
            "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}" \
            "$ip_cert_file" "$ip_key_file" "$ip_proxy_webroot"; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[安全拒绝] Nexus Nginx 六个固定代理路径无法按当前模式或可信卸载意图逐字节证明；外来同名文件已保留，完整卸载尚未开始。${RESET}" >&2
        return 2
    fi

    if [ -e "$ip_cert_file" ] || [ -L "$ip_cert_file" ] || \
       [ -e "$ip_key_file" ] || [ -L "$ip_key_file" ]; then
        if [ -z "$ip_acme_address" ]; then
            ip_acme_address="$ip_acme_nexus_address"
        fi
        if ! declare -F nexus_ip_certificate_pair_is_ready >/dev/null 2>&1 || \
           [ -z "$ip_acme_address" ] || \
           ! nexus_ip_certificate_pair_is_ready "$ip_cert_file" \
                "$ip_key_file" "$ip_acme_address"; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] IP live 证书/私钥不是匹配受管地址的 RR 常规文件；可疑 pair 已保留，完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
        ip_cert_pair_present=true
    fi
    if [ -e "$ip_pending_file" ] || [ -L "$ip_pending_file" ]; then
        if ! declare -F nexus_ip_certificate_pending_is_trusted >/dev/null 2>&1 || \
           ! nexus_ip_certificate_pending_is_trusted "$ip_pending_file"; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] IP 证书 pending 标记不可信；可疑文件已保留，完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
    fi
    if [ -e "$ip_gate_script" ] || [ -L "$ip_gate_script" ]; then
        if ! declare -F nexus_ip_certificate_gate_script_is_current >/dev/null 2>&1 || \
           ! nexus_ip_certificate_gate_script_is_current "$ip_gate_script"; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] Nginx IP 证书 gate 程序不属于当前 RR；外来文件已保留，完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
    fi
    if [ -e "$ip_gate_dropin" ] || [ -L "$ip_gate_dropin" ]; then
        if ! declare -F nexus_ip_certificate_gate_dropin_is_current >/dev/null 2>&1 || \
           ! nexus_ip_certificate_gate_dropin_is_current "$ip_gate_dropin" \
                "$ip_gate_script" "$ip_cert_file" "$ip_key_file" \
                "$ip_pending_file"; then
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            echo -e "${RED}[安全拒绝] Nginx IP 证书 gate Drop-in 不属于当前 RR；外来 Drop-in 已保留，完整卸载尚未开始。${RESET}" >&2
            return 2
        fi
    fi
    # IP-ACME-PREFLIGHT-END
    # Establish a durable crash/reboot gate before the first destructive
    # operation.  It captures the pre-uninstall firewall/config evidence,
    # disables every RR restart path, stops public runtimes, and proves them
    # inactive.  Cloudflared is handled separately only when strict RR
    # ownership evidence succeeds.
    if ! rr_firewall_stop_nodes_on_indeterminate_commit; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[紧急] 无法建立并验证卸载隔离；配置和凭据均保留。${RESET}" >&2
        return 3
    fi
    if ! rr_uninstall_firewall_quarantine_artifacts_are_owned; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 防火墙隔离证据或 Drop-in 不可信；配置、凭据和服务文件均保留。${RESET}" >&2
        return 2
    fi
    if ! rr_uninstall_certificate_reload_pending_is_owned; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 证书 reload pending 证据不可信；配置、证书与服务文件均保留。${RESET}" >&2
        return 2
    fi
    if ! rr_uninstall_stop_owned_argo_runtime; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 无法证明受管隧道 inactive/disabled/removed；Token 与配置均保留，第三方 Cloudflared 未触碰。${RESET}" >&2
        return 2
    fi
    rr_uninstall_clear_managed_firewall_transaction || firewall_status=$?
    if [ "$firewall_status" -ne 0 ]; then
        rr_uninstall_abort_fail_closed \
            '完整卸载未能证明 RR filter/NAT/UFW 命名空间已精确清理' || \
            stop_status=$?
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return "$stop_status"
    fi

    # IP-ACME-TEARDOWN-BEGIN
    # Keep the live pair in place while module 86 removes the HTTP-01 site and
    # may reload Nginx.  Its exact uninstall first disarms renewal, removes the
    # owned static units, challenge site/link, webroot, pinned lego binary and
    # account stores.  No broad Nexus directory deletion is allowed to stand
    # in for these ownership checks.
    if [ "$ip_acme_present" = true ]; then
        if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "${ip_acme_owned_artifacts[@]}" \
                "$ip_cert_file" "$ip_key_file" "$ip_pending_file" \
                "$ip_gate_script" "$ip_gate_dropin" \
                "$ip_proxy_site" "$ip_proxy_enabled" \
                "${ip_proxy_retired_paths[@]}"; then
            rr_uninstall_abort_fail_closed \
                'IP ACME 固定资产父目录在删除边界发生变化' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
        if ! nexus_ip_acme_uninstall; then
            rr_uninstall_abort_fail_closed \
                'IP ACME 续签、HTTP-01 站点或账户库无法按所有权精确卸载' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
        for _rr_ip_acme_path in "${ip_acme_owned_artifacts[@]}"; do
            if [ -e "$_rr_ip_acme_path" ] || [ -L "$_rr_ip_acme_path" ]; then
                rr_uninstall_abort_fail_closed \
                    'IP ACME 精确卸载返回后仍有自有 artifact 残留' || \
                    stop_status=$?
                [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
                return "$stop_status"
            fi
        done
        for _rr_ip_acme_unit_name in rr-nexus-ip-acme.timer \
            rr-nexus-ip-acme.service; do
            if ! rr_uninstall_ip_acme_unit_is_absent \
                    "$_rr_ip_acme_unit_name"; then
                rr_uninstall_abort_fail_closed \
                    'IP ACME 卸载后 unit 并非 inactive/disabled/not-found，或仍有有效 Fragment/Drop-in' || \
                    stop_status=$?
                [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
                return "$stop_status"
            fi
        done
    fi

    # The public TLS proxy must stop referencing the pair before removing its
    # gate or either live file.  This caller re-proves every fixed proxy path
    # immediately before the broad module-85 remover, so a foreign same-name
    # site is preserved and the full uninstall fails closed.
    if declare -F nexus_remove_public_proxy >/dev/null 2>&1; then
        if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "$ip_proxy_site" "$ip_proxy_enabled" \
                "${ip_proxy_retired_paths[@]}" || \
           ! rr_uninstall_nexus_proxy_set_is_safe "$ip_proxy_authority" \
                "$ip_proxy_domain" "$ip_acme_nexus_port" \
                "$ip_acme_certificate_mode" "$ip_proxy_available_dir" \
                "$ip_proxy_enabled_dir" \
                "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}" \
                "$ip_cert_file" "$ip_key_file" "$ip_proxy_webroot"; then
            rr_uninstall_abort_fail_closed \
                'Nexus 公网代理父目录或精确内容在删除边界发生变化' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
        if ! nexus_remove_public_proxy; then
            rr_uninstall_abort_fail_closed 'RR Nexus 公网代理清理失败' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
        if ! rr_uninstall_nexus_proxy_paths_are_absent \
                "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}" \
                "$ip_proxy_enabled_dir/rr-nexus.conf" \
                "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}.port" \
                "$ip_proxy_enabled_dir/rr-nexus-port.conf" \
                "$ip_proxy_site" "$ip_proxy_enabled"; then
            rr_uninstall_abort_fail_closed \
                'RR Nexus 公网代理删除后仍有固定路径 artifact' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    elif ! rr_uninstall_nexus_proxy_paths_are_absent \
            "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}" \
            "$ip_proxy_enabled_dir/rr-nexus.conf" \
            "${NEXUS_NGINX_SITE:-$ip_proxy_available_dir/rr-nexus.conf}.port" \
            "$ip_proxy_enabled_dir/rr-nexus-port.conf" \
            "$ip_proxy_site" "$ip_proxy_enabled"; then
        rr_uninstall_abort_fail_closed \
            '当前运行时缺少 Nexus 公网代理精确撤回接口' || stop_status=$?
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return "$stop_status"
    fi

    firewall_status=0
    if declare -F nexus_remove_ip_certificate_gate >/dev/null 2>&1; then
        if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "$ip_gate_script" "$ip_gate_dropin"; then
            firewall_status=2
        else
            nexus_remove_ip_certificate_gate "$ip_cert_file" "$ip_key_file" \
                "$ip_pending_file" || firewall_status=$?
        fi
    elif [ "$ip_cert_cleanup_needed" = true ]; then
        firewall_status=2
    fi
    if [ "$firewall_status" -ne 0 ]; then
        rr_uninstall_abort_fail_closed \
            'RR Nexus IP 证书崩溃门不可信或无法精确移除' || stop_status=$?
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return "$stop_status"
    fi
    if [ -e "$ip_gate_script" ] || [ -L "$ip_gate_script" ] || \
       [ -e "$ip_gate_dropin" ] || [ -L "$ip_gate_dropin" ]; then
        rr_uninstall_abort_fail_closed \
            'RR Nexus IP 证书 gate 删除后仍有固定路径 artifact' || \
            stop_status=$?
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return "$stop_status"
    fi

    if [ -e "$ip_cert_file" ] || [ -L "$ip_cert_file" ] || \
       [ -e "$ip_key_file" ] || [ -L "$ip_key_file" ]; then
        if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "$ip_cert_file" "$ip_key_file" || \
           [ "$ip_cert_pair_present" != true ] || \
           ! nexus_ip_certificate_pair_is_ready "$ip_cert_file" \
                "$ip_key_file" "$ip_acme_address" || \
           ! unlink "$ip_key_file" 2>/dev/null || \
           ! sync -f "$ip_cert_dir" || \
           ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "$ip_cert_file" "$ip_key_file" || \
           ! unlink "$ip_cert_file" 2>/dev/null || \
           ! sync -f "$ip_cert_dir"; then
            rr_uninstall_abort_fail_closed \
                'IP live 证书 pair 在删除边界发生变化或无法持久化移除' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    fi
    if [ -e "$ip_pending_file" ] || [ -L "$ip_pending_file" ]; then
        if ! rr_uninstall_ip_acme_existing_parent_chains_are_safe \
                "$ip_pending_file" || \
           ! nexus_ip_certificate_pending_is_trusted "$ip_pending_file" || \
           ! unlink "$ip_pending_file" 2>/dev/null || \
           ! sync -f "$ip_cert_dir"; then
            rr_uninstall_abort_fail_closed \
                'IP 证书 pending 标记在删除边界发生变化或无法精确移除' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    fi
    for _rr_ip_cert_path in "$ip_cert_file" "$ip_key_file" \
        "$ip_pending_file" "$ip_gate_script" "$ip_gate_dropin"; do
        if [ -e "$_rr_ip_cert_path" ] || [ -L "$_rr_ip_cert_path" ]; then
            rr_uninstall_abort_fail_closed \
                'IP ACME live pair、pending 或 gate 未完整消失' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    done
    # IP-ACME-TEARDOWN-END

    if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
        if ! (crontab -l 2>/dev/null | grep -v "auto_update_sub.py") | \
            crontab -; then
            rr_uninstall_abort_fail_closed '订阅定时任务清理失败' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    fi
    rm -f /usr/local/bin/auto_update_sub.py
    if ! rr_uninstall_remove_owned_certificate_hooks; then
        rr_uninstall_abort_fail_closed \
            'Certbot deploy hook 在删除边界发生变化；可疑文件已保留且卸载停止' || \
            stop_status=$?
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return "$stop_status"
    fi
    rm -f /etc/nginx/sites-enabled/rr-naive-acme.conf /etc/nginx/sites-available/rr-naive-acme.conf
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        if ! systemctl reload nginx >/dev/null 2>&1; then
            rr_uninstall_abort_fail_closed 'Naive ACME 站点移除后 Nginx 重载失败' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
    fi
    if [ -f /etc/fail2ban/jail.d/argo-rr-sshd.local ]; then
        local f2b_uninstall_backup="" f2b_was_active=false
        systemctl is-active --quiet fail2ban && f2b_was_active=true
        f2b_uninstall_backup=$(mktemp /tmp/rr-fail2ban-uninstall.XXXXXX) || {
            rr_uninstall_abort_fail_closed 'Fail2Ban 配置清理快照失败' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        }
        if ! cp -p -- /etc/fail2ban/jail.d/argo-rr-sshd.local \
                "$f2b_uninstall_backup" || \
           ! rm -f -- /etc/fail2ban/jail.d/argo-rr-sshd.local || \
           ! fail2ban-client -t >/dev/null 2>&1 || \
           { [ "$f2b_was_active" = true ] && \
             { ! systemctl restart fail2ban >/dev/null 2>&1 || \
               ! systemctl is-active --quiet fail2ban; }; }; then
            cp -p -- "$f2b_uninstall_backup" \
                /etc/fail2ban/jail.d/argo-rr-sshd.local >/dev/null 2>&1 || true
            [ "$f2b_was_active" != true ] || \
                systemctl restart fail2ban >/dev/null 2>&1 || true
            rm -f -- "$f2b_uninstall_backup"
            rr_uninstall_abort_fail_closed \
                'Fail2Ban 配置移除后未能验证新配置与运行态' || stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        fi
        rm -f -- "$f2b_uninstall_backup" || {
            rr_uninstall_abort_fail_closed 'Fail2Ban 清理证据回收失败' || \
                stop_status=$?
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return "$stop_status"
        }
    fi

    stop_subscription_servers >/dev/null 2>&1 || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }
    subscription_server_running && {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }

    rm -f /etc/systemd/system/argo-rr-health.timer \
        /etc/systemd/system/argo-rr-health.service \
        /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/sing-box.service \
        /etc/systemd/system/rr-subscription.service || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }
    for restore_gate_unit in sing-box.service rr-nexus.service rr-subscription.service \
        cloudflared.service nginx.service argo-rr-health.service; do
        rm -f "/etc/systemd/system/${restore_gate_unit}.d/40-rr-restore-gate.conf" \
            "/etc/systemd/system/${restore_gate_unit}.d/zzzz-rr-restore-gate.conf" || {
            [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
            return 2
        }
        rmdir "/etc/systemd/system/${restore_gate_unit}.d" >/dev/null 2>&1 || true
    done
    systemctl daemon-reload >/dev/null 2>&1 || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }

    if ! rr_uninstall_runtime_ownership_is_unchanged; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] RR 运行时或独立恢复程序在卸载边界发生变化；隔离保持，未删除可疑运行时。${RESET}" >&2
        return 2
    fi
    rm -rf "$RR_LIB_DIR" "${RR_LAUNCHER:-/usr/local/bin/rr}" \
        /usr/local/bin/sing-box /var/log/auto_update_sub.log || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }
    rm -f /etc/sysctl.d/99-argo-rr.conf "$ARGO_PID_FILE" "$ARGO_LOG_FILE" \
        /tmp/sub_server.pid /tmp/sub_server.bind /tmp/argo_rr_cloudflared.pid /tmp/argo.log
    # Keep the quarantine until the old launcher/runtime and every health
    # restart path are durably absent. A SIGKILL before this point therefore
    # still reboots into the guard instead of exposing the legacy subscription.
    if ! _uninstall_release_subscription_quarantine; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 旧运行时已停止，但订阅隔离尚未安全解除；恢复程序和证据已保留。${RESET}" >&2
        return 1
    fi
    # Keep the subscription root present until the final process proof above.
    # The matcher can authenticate an already-deleted cwd by its exact procfs
    # suffix plus st_nlink=0, but avoiding that state here removes needless
    # ambiguity and remains a useful defense against cleanup races.
    if ensure_subscription_root; then
        rm -rf -- "$SUB_ROOT"
    else
        echo -e "${YELLOW}[警告] ${SUB_ROOT} 未通过安全检查，卸载未删除该路径。${RESET}" >&2
    fi
    if ! rr_uninstall_captured_helper_is_unchanged_or_absent \
            "${RR_RECOVERY_SELF:-/usr/local/sbin/rr-update-recover}" \
            "$RR_UNINSTALL_RECOVERY_HELPER_SHA256" || \
       ! rr_uninstall_captured_helper_is_unchanged_or_absent \
            "${RR_UPDATE_EXTERNAL_HELPER:-/usr/local/sbin/rr-update-external-state}" \
            "$RR_UNINSTALL_EXTERNAL_HELPER_SHA256"; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 独立恢复程序在运行时删除后发生变化；恢复 Unit 与可疑程序均保留。${RESET}" >&2
        return 2
    fi
    rm -f /etc/systemd/system/rr-update-recovery.service \
        /etc/systemd/system/rr-restore-recovery.service \
        /etc/systemd/system/rr-restore-watchdog.service || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }
    if ! rr_uninstall_remove_captured_runtime_helpers; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 独立恢复程序无法按捕获哈希精确移除；事务证据已保留。${RESET}" >&2
        return 2
    fi
    rm -rf -- /var/lib/rr-update
    systemctl daemon-reload >/dev/null 2>&1 || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 2
    }
    # Only after every RR restart path and unit is gone may the durable
    # firewall marker/drop-ins be removed.  Credentials and the main config
    # remain available until this proof completes.
    if ! rr_uninstall_remove_firewall_quarantine_artifacts; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 防火墙规则已清理，但隔离证据无法安全解除；主配置与 Token 保留。${RESET}" >&2
        return 2
    fi
    if ! rr_uninstall_remove_owned_certificate_reload_pending; then
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        echo -e "${RED}[失败] 证书 reload pending 证据无法精确清理；主配置与证书保留。${RESET}" >&2
        return 2
    fi
    rm -rf -- /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update \
        /var/lib/rr-nexus /var/lib/rr-backup /var/www/rr-nexus-certbot || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 1
    }
    rm -rf -- /etc/rr-cloudflared || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 1
    }
    rm -f -- "$CONFIG_FILE" || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 1
    }
    sync || {
        [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
        return 1
    }
    rm -f /run/rr-vps/restore-live /run/rr-vps/restore-watch-request \
        /run/rr-vps/update-maintenance \
        /run/rr-vps/locks/restore-live.lock /run/rr-vps/locks/firewall.lock \
        /run/rr-vps/locks/nexus-sync.lock /run/rr-vps/locks/nexus-security.lock \
        /run/lock/rr-vps-nexus-sync.lock /run/lock/rr-nexus-security.lock
    rmdir /run/rr-vps/locks /run/rr-vps >/dev/null 2>&1 || true
    [ -z "$legacy_restore_lock_fd" ] || exec {legacy_restore_lock_fd}>&-
    echo -e "${GREEN}清理完毕，欢迎随时再次使用 RR-vps！${RESET}"
    echo -e "${CYAN}项目地址 / Project:${RESET} ${project_url}"
    echo -e "${YELLOW}重新安装 / Reinstall:${RESET}"
    echo "bash <(curl -fsSL ${reinstall_url})"
    echo ""
    return 0
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
    SUB_ACCESS_MODE=local
    SUB_DOMAIN=""
    if [ "$INSTALL_NAIVE_ENABLED" = true ]; then
        SUB_ACCESS_MODE=https
        SUB_DOMAIN="$NAIVE_DOMAIN"
    fi
    SUB_TOKEN=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))') || return 1
    [[ "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{32}$ ]] || return 1

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
    safe_sed SUB_ACCESS_MODE "$SUB_ACCESS_MODE" || config_write_ok=false
    safe_sed SUB_DOMAIN "$SUB_DOMAIN" || config_write_ok=false
    safe_sed SUB_TOKEN "$SUB_TOKEN" || config_write_ok=false
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
        if ! ensure_fixed_argo_service >/dev/null 2>&1; then
            rm -f "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}"
            echo -e "${RED}固定隧道服务安装失败。${RESET}"
            return 1
        fi
        safe_sed ARGO_DOMAIN "$ARGO_DOMAIN" || return 1
        echo -e "${YELLOW}请确认 Cloudflare 面板服务地址为 http://localhost:${PORT}。${RESET}"
        else
            if ! launch_quick_argo_tunnel; then
                echo -e "${RED}Argo 临时隧道启动失败，安装中止。${RESET}"
                return 1
            fi
        fi
    fi

    local firewall_status=0
    open_configured_firewall || firewall_status=$?
    if [ "$firewall_status" -ne 0 ]; then
        case "$firewall_status" in
            1|10)
                echo -e "${RED}防火墙或端口跳跃事务失败，已证明保持原态；安装已停止。${RESET}" >&2
                ;;
            2)
                echo -e "${RED}[严重] 防火墙事务状态不确定，Sing-box 已停止并验证 inactive。${RESET}" >&2
                ;;
            *)
                echo -e "${RED}[紧急] 防火墙事务状态不确定，且无法验证 Sing-box 已停止。${RESET}" >&2
                ;;
        esac
        return "$firewall_status"
    fi
    generate_node_and_sub || return 1
    if [ "$INSTALL_ANY_PROTOCOL" = true ]; then
        if ! setup_health_monitor >/dev/null 2>&1 || \
           ! rr_health_monitor_units_are_current; then
            echo -e "${RED}[失败] 健康监控单元未能原子发布并验证；安装未标记完成。${RESET}" >&2
            return 1
        fi
    fi
    safe_sed INSTALL_COMPLETE true || return 1

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
