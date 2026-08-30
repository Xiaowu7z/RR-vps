# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 3. 安装并配置 Sing-box 内核
# ==========================================
install_singbox() {
    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        printf '%s\n' '[安全拒绝] 热更新候选迁移不得下载或替换 Sing-box 内核。' >&2
        return 1
    fi
    echo -e "\n${YELLOW}正在下载并部署 Sing-box 核心 ($SYS_ARCH)...${RESET}"
    local sb_tmp_dir=""
    local sb_tag=""
    local sb_version=""
    local archive=""
    local extracted=""
    local candidate=""
    local release_json=""
    local asset_name=""
    local asset_url=""
    local expected_digest=""
    local actual_digest=""
    local old_binary=""
    local old_config=""
    local installed_version=""
    local was_running=false
    local validate_current_config=false
    local rr_core_dir=""
    local rr_core_version=""
    local rr_core_ok=false

    # A fresh install writes an INSTALL_COMPLETE=false candidate before the
    # core is downloaded.  It deliberately has empty certificate/Reality
    # fields until the core is available, so it must not be validated as if it
    # were an already-running node.  Completed installations retain the old
    # build/check/restart rollback path.
    if [ -f "$CONFIG_FILE" ]; then
        load_config_with_defaults || return 1
        [ "$INSTALL_COMPLETE" = "true" ] && validate_current_config=true
    fi

    sb_tmp_dir=$(mktemp -d /tmp/rr-sing-box.XXXXXX) || return 1
    release_json="$sb_tmp_dir/release.json"
    if ! curl -fsSL --retry 2 --connect-timeout 8 --max-time 30 \
        -H 'Accept: application/vnd.github+json' -H 'User-Agent: RR-vps' \
        -o "$release_json" https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null; then
        echo -e "${RED}[失败] 无法取得 Sing-box 正式版元数据，现有内核未改动。${RESET}"
        rm -rf "$sb_tmp_dir"
        return 1
    fi
    sb_tag=$(jq -r '.tag_name // empty' "$release_json")
    if [[ ! "$sb_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
        echo -e "${RED}[失败] 无法取得 Sing-box 最新正式版版本号，现有内核未改动。${RESET}"
        rm -rf "$sb_tmp_dir"
        return 1
    fi

    sb_version="${sb_tag#v}"
    installed_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    if [ "$installed_version" = "$sb_version" ] && [ -x "$SINGBOX_BIN" ] && \
       "$SINGBOX_BIN" version 2>/dev/null | grep -qw 'with_v2ray_api'; then
        rm -rf "$sb_tmp_dir"
        echo -e "${GREEN}[内核] Sing-box 正式版 ${sb_version} 已是最新，无需重启节点。${RESET}"
        return 0
    fi
    archive="$sb_tmp_dir/sing-box.tar.gz"
    asset_name="sing-box-${sb_version}-linux-${SYS_ARCH}.tar.gz"
    asset_url=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' "$release_json" | head -n 1)
    expected_digest=$(jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | (.digest // "")' "$release_json" | head -n 1)
    expected_digest="${expected_digest#sha256:}"
    # 优先使用 rr-nexus-core 固定 release：它同时提供 SHA256SUMS 与
    # BUILD_INFO，避免旧的版本化自建资产只能靠版本字符串进行弱校验。
    rr_core_dir="$sb_tmp_dir/rr-core"
    mkdir -p "$rr_core_dir"
    if declare -F nexus_download_traffic_core >/dev/null 2>&1 && \
       nexus_download_traffic_core "$rr_core_dir" >/dev/null 2>&1; then
        rr_core_version=$(get_singbox_version "$rr_core_dir/sing-box" 2>/dev/null || true)
        if [ "$rr_core_version" = "$sb_version" ]; then
            mv "$rr_core_dir/sing-box" "$sb_tmp_dir/sing-box"
            rr_core_ok=true
        fi
    fi
    candidate="$sb_tmp_dir/sing-box"
    if [ "$rr_core_ok" != true ]; then
        echo -e "${YELLOW}[提示] 官方构建不含流量统计标签（with_v2ray_api），面板流量统计不可用。${RESET}"
        if [[ ! "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]] || [[ ! "$asset_url" =~ ^https://github\.com/SagerNet/sing-box/releases/download/ ]]; then
            echo -e "${RED}[失败] 正式版安装包缺少可信 SHA256 元数据，现有内核未改动。${RESET}"
            rm -rf "$sb_tmp_dir"
            return 1
        fi
        extracted="sing-box-${sb_version}-linux-${SYS_ARCH}/sing-box"
        if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 -o "$archive" "$asset_url"; then
            echo -e "${RED}[失败] Sing-box 下载失败，现有内核未改动。${RESET}"
            rm -rf "$sb_tmp_dir"
            return 1
        fi
        actual_digest=$(sha256sum "$archive" | awk '{print $1}')
        if [ "${actual_digest,,}" != "${expected_digest,,}" ]; then
            echo -e "${RED}[失败] Sing-box 安装包 SHA256 校验不一致，现有内核未改动。${RESET}"
            rm -rf "$sb_tmp_dir"
            return 1
        fi
        if ! tar -tzf "$archive" "$extracted" >/dev/null 2>&1 || \
           ! tar --no-same-owner --no-same-permissions -xzf \
               "$archive" -C "$sb_tmp_dir" "$extracted" 2>/dev/null; then
            echo -e "${RED}[失败] Sing-box 压缩包不完整，现有内核未改动。${RESET}"
            rm -rf "$sb_tmp_dir"
            return 1
        fi
        mv "$sb_tmp_dir/$extracted" "$candidate"
    fi
    chmod 755 "$candidate"
    if [ "$(get_singbox_version "$candidate")" != "$sb_version" ]; then
        echo -e "${RED}[失败] Sing-box 内核版本校验失败，现有内核未改动。${RESET}"
        rm -rf "$sb_tmp_dir"
        return 1
    fi
    # 自建构建必须带流量统计标签，否则回退官方构建同样缺统计
    if [ "$rr_core_ok" = true ] && ! "$candidate" version 2>/dev/null | grep -qw 'with_v2ray_api'; then
        echo -e "${RED}[失败] 自建内核缺少 with_v2ray_api 标签，现有内核未改动。${RESET}"
        rm -rf "$sb_tmp_dir"
        return 1
    fi

    mkdir -p /etc/sing-box
    if [ -x "$SINGBOX_BIN" ]; then
        old_binary="$sb_tmp_dir/sing-box.previous"
        cp -p "$SINGBOX_BIN" "$old_binary" || { rm -rf "$sb_tmp_dir"; return 1; }
    fi
    if [ -f /etc/sing-box/config.json ]; then
        old_config="$sb_tmp_dir/config.json.previous"
        cp -p /etc/sing-box/config.json "$old_config" || { rm -rf "$sb_tmp_dir"; return 1; }
    fi
    # 内核升级只停/重启 systemd 管理的 sing-box 服务；绝不主动清理或杀死
    # 非 systemd 的手动进程（替换二进制不影响已运行进程——旧 inode 继续承载
    # 流量，新配置由后续 systemd 服务接管）。
    systemctl is-active --quiet sing-box 2>/dev/null && was_running=true

    install -m 755 "$candidate" "${SINGBOX_BIN}.new" || { rm -rf "$sb_tmp_dir"; return 1; }
    mv -f "${SINGBOX_BIN}.new" "$SINGBOX_BIN"

    # 旧进程继续提供流量；新内核先生成并自检配置，成功后才做一次快速重启。
    if [ "$validate_current_config" = true ]; then
        if ! build_singbox_config; then
            if [ -n "$old_binary" ]; then
                install -m 755 "$old_binary" "$SINGBOX_BIN"
            else
                rm -f "$SINGBOX_BIN"
            fi
            if [ -n "$old_config" ]; then
                cp -p "$old_config" /etc/sing-box/config.json
            else
                rm -f /etc/sing-box/config.json
            fi
            rm -rf "$sb_tmp_dir"
            echo -e "${RED}[失败] 新内核与当前节点配置不兼容，已保留旧内核和运行配置。${RESET}"
            return 1
        fi
        if [ "$was_running" = true ] && ! restart_singbox_systemd_only; then
            if [ -n "$old_binary" ]; then
                install -m 755 "$old_binary" "$SINGBOX_BIN"
            else
                rm -f "$SINGBOX_BIN"
            fi
            if [ -n "$old_config" ]; then
                cp -p "$old_config" /etc/sing-box/config.json
            else
                rm -f /etc/sing-box/config.json
            fi
            # 回滚后同样只通过 systemd 拉起旧内核，绝不触碰手动进程。
            restart_singbox_systemd_only >/dev/null 2>&1 || true
            rm -rf "$sb_tmp_dir"
            echo -e "${RED}[失败] 新内核启动校验失败，已自动回滚旧内核。${RESET}"
            return 1
        fi
    fi

    rm -rf "$sb_tmp_dir"
    echo -e "${GREEN}[成功] Sing-box 正式版 ${sb_version} 已就绪。${RESET}"
}

ensure_singbox_core() {
    local current_version=""
    # systemd 固定使用脚本自管路径，不能因系统另有 /usr/bin/sing-box 就误判已安装。
    current_version=$(get_singbox_version "$SINGBOX_BIN" 2>/dev/null || true)
    if [ -z "$current_version" ]; then
        install_singbox
        return $?
    fi
    if ! version_ge "$current_version" "$MIN_SINGBOX_VERSION"; then
        echo -e "${YELLOW}[内核] 当前 ${current_version} 低于完整五协议最低版本 ${MIN_SINGBOX_VERSION}，尝试无损升级。${RESET}"
        install_singbox
        return $?
    fi
    # 版本已达标但内核缺流量统计标签（官方 1.12+ 构建不含 with_v2ray_api）
    # 且仓库已有同版本自建构建时，无损替换为带统计内核。
    if ! "$SINGBOX_BIN" version 2>/dev/null | grep -qw 'with_v2ray_api'; then
        local available_core_version=""
        if declare -F nexus_traffic_core_version >/dev/null 2>&1; then
            available_core_version=$(nexus_traffic_core_version 2>/dev/null || true)
        fi
        if [ "$available_core_version" = "$current_version" ]; then
            echo -e "${YELLOW}[内核] 官方构建缺少流量统计标签，升级为自建带统计构建。${RESET}"
            install_singbox
            return $?
        fi
    fi
    return 0
}

write_singbox_systemd_unit() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local unit_tmp=""
    install -d -m 755 "$(dirname "$service_file")" || return 1
    unit_tmp=$(mktemp "$(dirname "$service_file")/.sing-box.service.XXXXXX") || return 1
    if ! cat > "$unit_tmp" <<EOF
[Unit]
Description=Sing-box service managed by RR-vps
Wants=network-online.target
After=network-online.target nss-lookup.target
StartLimitIntervalSec=60
StartLimitBurst=5
[Service]
Type=simple
User=root
WorkingDirectory=/etc/sing-box
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
KillMode=mixed
LimitNOFILE=1048576
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
    then
        rm -f "$unit_tmp"
        return 1
    fi
    chmod 644 "$unit_tmp" || { rm -f "$unit_tmp"; return 1; }
    mv -f "$unit_tmp" "$service_file" || { rm -f "$unit_tmp"; return 1; }
}

setup_systemd() {
    write_singbox_systemd_unit || return 1
    systemctl daemon-reload || return 1
    systemctl enable sing-box >/dev/null 2>&1 || return 1
    restart_singbox
}

ensure_node_service_running() {
    load_config_with_defaults || return 1
    any_node_protocol_enabled || return 0
    if [ ! -f /etc/systemd/system/sing-box.service ]; then
        setup_systemd
    elif ! managed_singbox_running; then
        restart_singbox
    fi
}

write_health_monitor_units() {
    local health_service_file="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
    local health_timer_file="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
    local service_tmp=""
    local timer_tmp=""
    install -d -m 755 "$(dirname "$health_service_file")" \
        "$(dirname "$health_timer_file")" || return 1
    service_tmp=$(mktemp "$(dirname "$health_service_file")/.argo-rr-health.service.XXXXXX") || return 1
    timer_tmp=$(mktemp "$(dirname "$health_timer_file")/.argo-rr-health.timer.XXXXXX") || {
        rm -f "$service_tmp"
        return 1
    }
    if ! cat > "$service_tmp" <<EOF
[Unit]
Description=RR-vps runtime health check
Wants=network-online.target
After=network-online.target sing-box.service
ConditionPathExists=/etc/argo_vmess.conf
ConditionFileIsExecutable=/usr/local/bin/rr

[Service]
Type=oneshot
ExecStart=/usr/local/bin/rr --health-check
TimeoutStartSec=180
Nice=10
EOF
    then
        rm -f "$service_tmp" "$timer_tmp"
        return 1
    fi

    if ! cat > "$timer_tmp" <<EOF
[Unit]
Description=Check RR-vps runtime every five minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
RandomizedDelaySec=15s
Unit=argo-rr-health.service

[Install]
WantedBy=timers.target
EOF
    then
        rm -f "$service_tmp" "$timer_tmp"
        return 1
    fi
    chmod 644 "$service_tmp" "$timer_tmp" || {
        rm -f "$service_tmp" "$timer_tmp"
        return 1
    }
    mv -f "$service_tmp" "$health_service_file" || {
        rm -f "$service_tmp" "$timer_tmp"
        return 1
    }
    mv -f "$timer_tmp" "$health_timer_file" || {
        rm -f "$timer_tmp"
        return 1
    }
}

setup_health_monitor() {
    write_health_monitor_units || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    systemctl enable --now argo-rr-health.timer >/dev/null 2>&1 || return 1
    return 0
}

# ==========================================
# 生成证书与 Reality 密钥 (一次性)
# ==========================================
# T9：TLS 证书文件缺失时自动重建自签证书，保持节点可起（绝不静默降级）。
# 有节点协议启用且 cert.pem/private.key 任一缺失/为空时调用 generate_certs_and_keys
# 重建（幂等：文件完整时零开销直接返回）。重建失败则返回 1，让调用方拒绝生成
# 引用缺失证书的无效配置/订阅。
ensure_tls_certificates() {
    if [ -s /etc/sing-box/cert.pem ] && [ -s /etc/sing-box/private.key ]; then
        return 0
    fi
    any_node_protocol_enabled || return 0
    echo -e "${YELLOW}[警告] 检测到 TLS 证书文件缺失，正在自动重建自签证书（客户端订阅的 pinSHA256 会变化，需重新获取订阅）。${RESET}" >&2
    generate_certs_and_keys >/dev/null 2>&1 || return 1
    return 0
}

generate_certs_and_keys() {
    load_config_with_defaults || return 1
    mkdir -p /etc/sing-box

    if [ ! -s "/etc/sing-box/cert.pem" ] || [ ! -s "/etc/sing-box/private.key" ]; then
        echo -e "${YELLOW}正在生成自签证书 (bing.com)...${RESET}"
        local cert_tmp_dir=""
        cert_tmp_dir=$(mktemp -d /tmp/rr-cert.XXXXXX) || return 1
        if ! openssl ecparam -genkey -name prime256v1 -out "$cert_tmp_dir/private.key" 2>/dev/null || \
           ! openssl req -new -x509 -days 36500 -key "$cert_tmp_dir/private.key" \
                -out "$cert_tmp_dir/cert.pem" -subj "/CN=www.bing.com" 2>/dev/null || \
           ! openssl x509 -in "$cert_tmp_dir/cert.pem" -noout >/dev/null 2>&1; then
            rm -rf "$cert_tmp_dir"
            echo -e "${RED}[失败] TLS 证书生成或校验失败，原证书未改动。${RESET}"
            return 1
        fi
        CERT_SHA256=$(openssl x509 -in "$cert_tmp_dir/cert.pem" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
        if [[ ! "$CERT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
            rm -rf "$cert_tmp_dir"
            return 1
        fi
        install -m 600 "$cert_tmp_dir/private.key" /etc/sing-box/private.key || { rm -rf "$cert_tmp_dir"; return 1; }
        install -m 600 "$cert_tmp_dir/cert.pem" /etc/sing-box/cert.pem || { rm -rf "$cert_tmp_dir"; return 1; }
        rm -rf "$cert_tmp_dir"
        echo -e "${GREEN}[成功] 自签证书已生成 (SHA256: $CERT_SHA256)${RESET}"
    fi

    # Always derive the published pin from the certificate currently served.
    # This repairs empty/stale hashes without rotating the certificate.
    if ! openssl x509 -in /etc/sing-box/cert.pem -noout >/dev/null 2>&1 || \
       ! openssl pkey -in /etc/sing-box/private.key -noout >/dev/null 2>&1; then
        echo -e "${RED}[失败] TLS 证书或私钥损坏，拒绝生成无效节点。${RESET}"
        return 1
    fi
    CERT_SHA256=$(openssl x509 -in /etc/sing-box/cert.pem -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [[ ! "$CERT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo -e "${RED}[失败] 无法计算 TLS 证书 SHA256，拒绝生成无效节点。${RESET}"
        return 1
    fi
    safe_sed "CERT_SHA256" "$CERT_SHA256" || return 1

    if [[ ! "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
       [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
       [[ ! "$SHORT_ID" =~ ^[0-9a-fA-F]{8}$ ]]; then
        # A completed installation with partial Reality material may already
        # have clients using its private key.  Never rotate it silently during
        # repair/update; only an unfinished first install may replace it.
        # 例外（B1 P0）：掩码值（旧版把掩码写进配置）必须强制轮换——
        # 客户端不可能持有掩码形式的真实密钥。
        if [ "${INSTALL_COMPLETE:-true}" = "true" ] && \
           { [ -n "$PRIVATE_KEY" ] || [ -n "$PUBLIC_KEY" ] || [ -n "$SHORT_ID" ]; } && \
           ! is_masked_credential "${PRIVATE_KEY:-}" && \
           ! is_masked_credential "${PUBLIC_KEY:-}" && \
           ! is_masked_credential "${SHORT_ID:-}"; then
            echo -e "${RED}[失败] 已完成安装的 Reality 密钥不完整；为保护现有客户端，未自动轮换。${RESET}"
            return 1
        fi
        rotate_reality_keypair || return 1
    fi
    return 0
}

# ==========================================
# 重新生成 Reality 密钥对（B1 P0：掩码凭据修复 / 损坏密钥恢复）
# 与 generate_certs_and_keys 不同：不触碰 TLS 证书，只轮换密钥三件套，
# 供 ensure_credential_integrity 检测到掩码/损坏 Reality 材料时调用。
# ==========================================
rotate_reality_keypair() {
    if [ ! -x "$SINGBOX_BIN" ]; then
        echo -e "${RED}Sing-box 核心未安装，无法生成 Reality 密钥${RESET}"
        return 1
    fi
    echo -e "${YELLOW}正在重新生成 Vless-Reality 密钥对...${RESET}"
    local key_pair=""
    key_pair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null) || return 1
    PRIVATE_KEY=$(echo "$key_pair" | awk '/PrivateKey/ {print $2}' | tr -d '"')
    PUBLIC_KEY=$(echo "$key_pair" | awk '/PublicKey/ {print $2}' | tr -d '"')
    SHORT_ID=$("$SINGBOX_BIN" generate rand --hex 4 2>/dev/null | tr -d '\n')
    if [[ ! "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
       [[ ! "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
       [[ ! "$SHORT_ID" =~ ^[0-9a-fA-F]{8}$ ]]; then
        echo -e "${RED}Reality 密钥生成失败，请确保 sing-box 版本 >= 1.8${RESET}"
        return 1
    fi
    safe_sed "PRIVATE_KEY" "$PRIVATE_KEY" || return 1
    safe_sed "PUBLIC_KEY" "$PUBLIC_KEY" || return 1
    safe_sed "SHORT_ID" "$SHORT_ID" || return 1
    echo -e "${GREEN}[成功] Reality 密钥已重新生成${RESET}"
    return 0
}

validate_subscription_crypto_material() {
    if [ "${VL_ENABLED:-false}" = "true" ]; then
        if [[ ! "${PUBLIC_KEY:-}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
           [[ ! "${SHORT_ID:-}" =~ ^[0-9a-fA-F]{8}$ ]]; then
            echo -e "${RED}[错误] Reality 公钥或 Short ID 缺失，拒绝输出不可用的 VLESS 节点。${RESET}" >&2
            return 1
        fi
    fi
    if [ "${HY2_ENABLED:-false}" = "true" ] && \
       [[ ! "${CERT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
        # 证书 SHA256 缺失时降级处理：跳过 HY2 节点生成并明确告知用户，
        # 其余协议正常落地，绝不因单协议缺证书材料而整体判拒回滚。
        echo -e "${YELLOW}[警告] TLS 证书 SHA256 缺失，Hysteria2 已自动停用（其余协议不受影响）。修复证书后可在协议开关（菜单 9→2）中重新开启。${RESET}" >&2
        HY2_ENABLED=false
        [ -f "$CONFIG_FILE" ] && safe_sed "HY2_ENABLED" "false" || true
    fi
    return 0
}

# ==========================================
# 动态构建 Sing-box 配置
# ==========================================
build_singbox_config() {
    load_config_with_defaults || return 1
    # T9：证书文件缺失时自动重建自签证书（否则 VM-TLS/HY2/TU5/AnyTLS 入站引用
    # 缺失证书，sing-box check 失败 → 节点无法启动）。重建失败则拒绝出配置。
    ensure_tls_certificates || return 1
    # B1 P0：任何掩码/无效凭据在进入生成流程前必须重生成真值并回写，
    # 保证生成的 sing-box 配置与订阅永不含掩码值（幂等，真值只回写一次）。
    ensure_credential_integrity || return 1
    SINGBOX_CONFIG_CHANGED=false

    local vm_users='[{"name":"legacy","uuid":"'"$UUID"'","alterId":0}]'
    local vl_users='[{"name":"legacy","uuid":"'"$UUID"'","flow":"xtls-rprx-vision"}]'
    local hy2_users='[{"name":"legacy","password":"'"$UUID"'"}]'
    local tuic_users='[{"name":"legacy","uuid":"'"$UUID"'","password":"'"$UUID"'"}]'
    local anytls_users='[{"name":"legacy","password":"'"$UUID"'"}]'
    if declare -F nexus_protocol_users >/dev/null 2>&1; then
        vm_users=$(nexus_protocol_users vmess "$UUID") || return 1
        vl_users=$(nexus_protocol_users vless "$UUID") || return 1
        hy2_users=$(nexus_protocol_users hysteria2 "$UUID") || return 1
        tuic_users=$(nexus_protocol_users tuic "$UUID") || return 1
        anytls_users=$(nexus_protocol_users anytls "$UUID") || return 1
    fi
    local users_json=""
    for users_json in "$vm_users" "$vl_users" "$hy2_users" "$tuic_users" "$anytls_users"; do
        if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<< "$users_json"; then
            echo -e "${RED}[错误] RR Nexus 用户数据无效，拒绝覆盖当前节点配置。${RESET}" >&2
            return 1
        fi
    done

    local core_version=""
    core_version=$(get_singbox_version)
    if [ -z "$core_version" ]; then
        echo -e "${RED}[错误] 无法读取 sing-box 内核版本，已取消重建配置。${RESET}"
        return 1
    fi

    local modern_route=false
    version_ge "$core_version" "1.11.0" && modern_route=true

    if [ "$AN_ENABLED" = "true" ] && ! version_ge "$core_version" "1.12.0"; then
        echo -e "${RED}[错误] AnyTLS 需要 sing-box 1.12.0 或更高版本（当前 ${core_version}）。${RESET}"
        return 1
    fi

    # NAIVE-SUPPORT
    if [ "$NAIVE_ENABLED" = "true" ] && ! version_ge "$core_version" "1.13.0"; then
        echo -e "${RED}[错误] NaiveProxy 需要 sing-box 1.13.0 或更高版本，当前 ${core_version}。请先升级内核。${RESET}" >&2
        return 1
    fi

    local listen_address="::"
    [ "$ENTRY_IP_MODE" = "ipv4" ] && listen_address="0.0.0.0"

    local legacy_sniff_fields=""
    if [ "$modern_route" != true ]; then
        legacy_sniff_fields=',"sniff":true,"sniff_override_destination":true'
    fi

    local dns_json=""
    local direct_strategy=""
    local resolve_rule=""
    local family_guard=""
    local route_domain_resolver=""
    local nexus_stats_json=""

    if [ "$OUTBOUND_IP_MODE" != "auto" ]; then
        if [ "$modern_route" = true ]; then
            if version_ge "$core_version" "1.12.0"; then
                dns_json='"dns":{"servers":[{"type":"local","tag":"local"}],"final":"local"},'
                route_domain_resolver=',"default_domain_resolver":{"server":"local","strategy":"'"$OUTBOUND_IP_MODE"'"}'
            else
                # sing-box 1.11 使用旧 DNS server 格式；1.12+ 使用 type=local。
                dns_json='"dns":{"servers":[{"address":"local","tag":"local"}],"final":"local"},'
            fi
            resolve_rule=',{"action":"resolve","server":"local","strategy":"'"$OUTBOUND_IP_MODE"'"}'
            case "$OUTBOUND_IP_MODE" in
                ipv4_only) family_guard=',{"ip_version":6,"action":"reject"}' ;;
                ipv6_only) family_guard=',{"ip_version":4,"action":"reject"}' ;;
            esac
        else
            # 兼容 1.10.x：沿用 dial field；仅模式再拒绝相反地址族的 IP 直连。
            direct_strategy=',"domain_strategy":"'"$OUTBOUND_IP_MODE"'"'
            case "$OUTBOUND_IP_MODE" in
                ipv4_only) family_guard=',{"ip_version":6,"outbound":"block"}' ;;
                ipv6_only) family_guard=',{"ip_version":4,"outbound":"block"}' ;;
            esac
        fi
    fi

    if declare -F nexus_core_supports_traffic >/dev/null 2>&1 && \
       [ -r "${NEXUS_CONFIG_FILE:-/nonexistent}" ] && nexus_core_supports_traffic; then
        local stats_port=""
        local stats_users=""
        stats_port=$(nexus_stats_port) || return 1
        stats_users=$(nexus_traffic_user_names) || return 1
        if ! jq -e 'type == "array" and all(.[]; test("^dev_[a-f0-9]{12}$"))' \
            >/dev/null 2>&1 <<< "$stats_users"; then
            echo -e "${RED}[错误] RR Nexus 流量统计用户名单无效。${RESET}" >&2
            return 1
        fi
        nexus_stats_json=$(jq -nc --arg listen "127.0.0.1:${stats_port}" \
            --argjson users "$stats_users" \
            '{v2ray_api:{listen:$listen,stats:{enabled:true,users:$users}}}') || return 1
    fi

    local json='{"log":{"level":"error"},'"$dns_json"'"inbounds":['
    local first=true

    # Vmess-ws (VM_ENABLED控制开关)
    if [ "$VM_ENABLED" != "false" ]; then
        if [ "$VM_TLS_ENABLED" = "true" ]; then
            json+='{"type":"vmess","tag":"vmess-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$PORT"',"users":'"$vm_users"',"transport":{"type":"ws","path":"/'"${UUID}"'-vm","max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"},"tls":{"enabled":true,"server_name":"www.bing.com","certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/private.key"}}'
        else
            json+='{"type":"vmess","tag":"vmess-in"'"$legacy_sniff_fields"',"listen":"127.0.0.1","listen_port":'"$PORT"',"users":'"$vm_users"',"transport":{"type":"ws","path":"/'"${UUID}"'-vm","max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}}'
        fi
        first=false
    fi

    # 快速/固定 Argo 更换本地源站端口时，短暂保留旧监听，确保隧道切换期间不断流。
    # 该兼容监听只绑定回环地址，完成切换后会由事务自动清除。
    if [ "$VM_ENABLED" != "false" ] && [ "$VM_TLS_ENABLED" != "true" ] && \
       is_valid_port "$VM_PREVIOUS_PORT" && [ "$VM_PREVIOUS_PORT" != "$PORT" ]; then
        json+=',{"type":"vmess","tag":"vmess-in-previous"'"$legacy_sniff_fields"',"listen":"127.0.0.1","listen_port":'"$VM_PREVIOUS_PORT"',"users":'"$vm_users"',"transport":{"type":"ws","path":"/'"${UUID}"'-vm","max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol"}}'
    fi

    # Vless-reality
    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        if [ -z "$PRIVATE_KEY" ] || [ -z "$SHORT_ID" ]; then
            echo -e "${RED}[错误] Vless-reality 密钥缺失，请重新生成${RESET}"
            return 1
        fi
        if [ "$first" = true ]; then first=false; else json+=','; fi
        json+='{"type":"vless","tag":"vless-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$VL_PORT"',"users":'"$vl_users"',"tls":{"enabled":true,"server_name":"apple.com","reality":{"enabled":true,"handshake":{"server":"apple.com","server_port":443},"private_key":"'"$PRIVATE_KEY"'","short_id":["'"$SHORT_ID"'"]}}}'
    fi

    # Hysteria2（端口跳跃由防火墙转发至此主端口，服务端仍只监听一个端口）
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        if [ ! -s /etc/sing-box/cert.pem ] || [ ! -s /etc/sing-box/private.key ]; then
            echo -e "${YELLOW}[警告] TLS 证书缺失（/etc/sing-box/），已跳过 Hysteria2 入站（其余协议不受影响）。${RESET}" >&2
        else
            if [ "$first" = true ]; then first=false; else json+=','; fi
            if version_ge "$core_version" "1.11.0"; then
                json+='{"type":"hysteria2","tag":"hy2-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$HY2_PORT"',"users":'"$hy2_users"',"ignore_client_bandwidth":false,"obfs":{"type":"salamander","password":"'"$UUID"'"},"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/private.key"}}'
            else
                json+='{"type":"hysteria2","tag":"hy2-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$HY2_PORT"',"users":'"$hy2_users"',"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/private.key"}}'
            fi
        fi
    fi

    # Tuic5
    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else json+=','; fi
        json+='{"type":"tuic","tag":"tuic5-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$TU5_PORT"',"users":'"$tuic_users"',"congestion_control":"bbr","zero_rtt_handshake":true,"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/private.key"}}'
    fi

    # Anytls
    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else json+=','; fi
        json+='{"type":"anytls","tag":"anytls-in"'"$legacy_sniff_fields"',"listen":"'"$listen_address"'","listen_port":'"$AN_PORT"',"users":'"$anytls_users"',"tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert.pem","key_path":"/etc/sing-box/private.key"}}'
    fi

    # NAIVE-SUPPORT：sing-box 1.13+ 原生 Naive HTTP/2(TCP) / HTTP/3(QUIC)。
    # 用户数组 = 主凭据 + 每活跃设备独立凭据（username=设备ID，密码=无状态复算），
    # 使 v2ray_api 按 username 统计流量可精确归属到设备。
    if [ "$NAIVE_ENABLED" = "true" ] && [ -n "$NAIVE_PORT" ] && [ "$NAIVE_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else json+=','; fi
        if [ -f /etc/rr-naive/fullchain.pem ] && [ -f /etc/rr-naive/privkey.pem ]; then
            local naive_users_json="[{\"username\":\"$NAIVE_USER\",\"password\":\"$NAIVE_PASS\"}"
            local ndev_id=""
            if declare -F nexus_traffic_user_names >/dev/null 2>&1; then
                for ndev_id in $(nexus_traffic_user_names 2>/dev/null | jq -r '.[]?' 2>/dev/null); do
                    local ndev_pw=""
                    ndev_pw=$(nexus_device_naive_password "$ndev_id" 2>/dev/null) || continue
                    [ -n "$ndev_pw" ] && naive_users_json+=",{\"username\":\"$ndev_id\",\"password\":\"$ndev_pw\"}"
                done
            fi
            naive_users_json+="]"
            local naive_transport_json=""
            case "${NAIVE_MODE:-h2}" in
                h2) naive_transport_json=',"network":"tcp"' ;;
                h3) printf -v naive_transport_json ',"network":"udp","quic_congestion_control":"%s"' "${NAIVE_QUIC_CC:-bbr}" ;;
                *) printf -v naive_transport_json ',"quic_congestion_control":"%s"' "${NAIVE_QUIC_CC:-bbr}" ;;
            esac
            json+='{"type":"naive","tag":"naive-in","listen":"'"$listen_address"'","listen_port":'"$NAIVE_PORT"',"users":'
            json+="$naive_users_json$naive_transport_json"
            json+=',"tls":{"enabled":true,"certificate_path":"/etc/rr-naive/fullchain.pem","key_path":"/etc/rr-naive/privkey.pem"}}'
        else
            echo -e "${YELLOW}[提示] NaiveProxy 证书缺失（/etc/rr-naive/），已跳过 naive 入站。请运行证书申请后重新生成配置。${RESET}" >&2
        fi
    fi

    if [ "$modern_route" = true ]; then
        json+='],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"action":"sniff"},{"protocol":["quic","stun"],"action":"reject"}'"$resolve_rule$family_guard"',{"action":"route","outbound":"direct","network":["tcp","udp"]}],"final":"direct"'"$route_domain_resolver"'}'
    else
        json+='],"outbounds":[{"type":"direct","tag":"direct"'"$direct_strategy"'},{"type":"block","tag":"block"}],"route":{"rules":[{"protocol":["quic","stun"],"outbound":"block"}'"$family_guard"',{"outbound":"direct","network":"udp,tcp"}],"final":"direct"}'
    fi
    [ -n "$nexus_stats_json" ] && json+=',"experimental":'"$nexus_stats_json"
    json+='}'

    mkdir -p /etc/sing-box
    local tmp_config=""
    tmp_config=$(mktemp /etc/sing-box/config.json.tmp.XXXXXX) || return 1
    printf '%s\n' "$json" > "$tmp_config"

    if ! jq empty "$tmp_config" 2>/dev/null; then
        echo -e "${RED}[错误] 新 sing-box 配置 JSON 不合法，原配置未改动。${RESET}"
        rm -f "$tmp_config"
        return 1
    fi

    local check_output=""
    if ! check_output=$("$SINGBOX_BIN" check -c "$tmp_config" 2>&1); then
        echo -e "${RED}[错误] sing-box 拒绝新配置，原配置未改动：${RESET}"
        echo "$check_output"
        rm -f "$tmp_config"
        return 1
    fi

    if [ -f /etc/sing-box/config.json ] && cmp -s "$tmp_config" /etc/sing-box/config.json; then
        rm -f "$tmp_config"
        return 0
    fi

    [ -f /etc/sing-box/config.json ] && cp -p /etc/sing-box/config.json /etc/sing-box/config.json.bak
    mv "$tmp_config" /etc/sing-box/config.json
    chmod 600 /etc/sing-box/config.json 2>/dev/null || true
    SINGBOX_CONFIG_CHANGED=true
}

ensure_singbox_service_guards() {
    local unit_file="/etc/systemd/system/sing-box.service"
    [ -f "$unit_file" ] || return 0

    local changed=false
    if ! grep -q '^StartLimitIntervalSec=' "$unit_file" 2>/dev/null; then
        sed -i '/^\[Unit\]$/a StartLimitIntervalSec=60' "$unit_file"
        changed=true
    fi
    if ! grep -q '^StartLimitBurst=' "$unit_file" 2>/dev/null; then
        sed -i '/^StartLimitIntervalSec=/a StartLimitBurst=5' "$unit_file"
        changed=true
    fi
    if ! grep -q '^Wants=.*network-online.target' "$unit_file" 2>/dev/null; then
        sed -i '/^\[Unit\]$/a Wants=network-online.target' "$unit_file"
        changed=true
    fi
    if ! grep -q '^After=.*network-online.target' "$unit_file" 2>/dev/null; then
        sed -i '/^Wants=network-online.target/a After=network-online.target nss-lookup.target' "$unit_file"
        changed=true
    fi
    if ! grep -q '^ExecStartPre=/usr/local/bin/sing-box check ' "$unit_file" 2>/dev/null; then
        sed -i '/^ExecStart=/i ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json' "$unit_file"
        changed=true
    fi
    if grep -q '^RestartSec=10$' "$unit_file" 2>/dev/null; then
        sed -i 's/^RestartSec=10$/RestartSec=2/' "$unit_file"
        changed=true
    fi
    if grep -q '^Restart=always$' "$unit_file" 2>/dev/null; then
        sed -i 's/^Restart=always$/Restart=on-failure/' "$unit_file"
        changed=true
    elif ! grep -q '^Restart=' "$unit_file" 2>/dev/null; then
        sed -i '/^ExecStart=/a Restart=on-failure' "$unit_file"
        changed=true
    fi
    if ! grep -q '^RestartSec=' "$unit_file" 2>/dev/null; then
        sed -i '/^Restart=/a RestartSec=2' "$unit_file"
        changed=true
    fi
    if ! grep -q '^TimeoutStopSec=' "$unit_file" 2>/dev/null; then
        sed -i '/^RestartSec=/a TimeoutStopSec=10' "$unit_file"
        changed=true
    fi
    if ! grep -q '^KillMode=' "$unit_file" 2>/dev/null; then
        sed -i '/^TimeoutStopSec=/a KillMode=mixed' "$unit_file"
        changed=true
    fi
    if ! grep -q '^LimitNOFILE=' "$unit_file" 2>/dev/null; then
        sed -i '/^KillMode=/a LimitNOFILE=1048576' "$unit_file"
        changed=true
    fi
    if ! grep -q '^UMask=' "$unit_file" 2>/dev/null; then
        sed -i '/^LimitNOFILE=/a UMask=0077' "$unit_file"
        changed=true
    fi
    [ "$changed" = true ] && systemctl daemon-reload >/dev/null 2>&1
    return 0
}

stop_singbox_instances() {
    # 先停止 systemd 单元，避免 Restart=on-failure 在清理旧进程时再次拉起。
    if [ -f /etc/systemd/system/sing-box.service ]; then
        systemctl stop sing-box >/dev/null 2>&1 || true
    fi

    # 清理由旧版控制菜单 nohup 启动、已脱离 systemd 管理的同名进程。
    local pid=""
    while IFS= read -r pid; do
        kill -TERM "$pid" 2>/dev/null || true
    done < <(managed_singbox_pids)
    sleep 1
    while IFS= read -r pid; do
        kill -KILL "$pid" 2>/dev/null || true
    done < <(managed_singbox_pids)

    ! managed_singbox_running
}

restart_singbox() {
    ensure_singbox_service_guards

    if ! "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        echo -e "${RED}[警告] Sing-box 配置校验失败，未重启现有节点。${RESET}"
        return 1
    fi

    if [ -f /etc/systemd/system/sing-box.service ]; then
        local was_active=false
        local main_pid=""
        local pid=""
        local retry=0
        systemctl is-active --quiet sing-box && was_active=true
        main_pid=$(systemctl show sing-box -p MainPID --value 2>/dev/null)

        # 清理旧版菜单遗留的孤立实例，但不触碰正在承载流量的 systemd 主进程。
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            if [ "$pid" != "$main_pid" ]; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done < <(managed_singbox_pids)

        systemctl reset-failed sing-box >/dev/null 2>&1 || true
        if [ "$was_active" = true ]; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        else
            stop_singbox_instances >/dev/null 2>&1 || true
            systemctl start sing-box >/dev/null 2>&1 || true
        fi

        while [ "$retry" -lt 20 ] && ! systemctl is-active --quiet sing-box; do
            sleep 0.25
            retry=$((retry + 1))
        done
        if ! systemctl is-active --quiet sing-box; then
            # 端口仍被旧孤立进程占用时，执行一次受控清理后重试。
            stop_singbox_instances >/dev/null 2>&1 || true
            systemctl reset-failed sing-box >/dev/null 2>&1 || true
            systemctl start sing-box >/dev/null 2>&1 || true
            sleep 1
            if ! systemctl is-active --quiet sing-box; then
                echo -e "${RED}[警告] Sing-box 启动后退出，请查看：journalctl -u sing-box -n 50 --no-pager${RESET}"
                return 1
            fi
        fi
    else
        stop_singbox_instances >/dev/null 2>&1 || true
        nohup "$SINGBOX_BIN" run -c /etc/sing-box/config.json > /dev/null 2>&1 &
        sleep 1
        if ! managed_singbox_running; then
            echo -e "${RED}[警告] Sing-box 启动失败！请检查配置: cat /etc/sing-box/config.json${RESET}"
            return 1
        fi
    fi

    return 0
}

# 内核升级专用：只通过 systemd 重启 sing-box 服务，绝不清理或杀死非 systemd
# 的手动进程（如用户手动跑的 sing-box）。替换二进制不影响已运行进程，
# 新配置由 systemd 服务接管；无 systemd 单元时仅提示并跳过。
restart_singbox_systemd_only() {
    ensure_singbox_service_guards
    if [ ! -f /etc/systemd/system/sing-box.service ]; then
        echo -e "${YELLOW}[警告] 未检测到 systemd 单元，跳过服务重启；手动运行的 sing-box 进程不会被触碰。${RESET}"
        return 0
    fi
    systemctl restart sing-box >/dev/null 2>&1
}

restore_config_transaction_snapshot() {
    local tx_dir="$1"
    local old_uuid="$2"
    local was_running="$3"
    local restart_required="$4"
    local restore_failed=false

    ensure_subscription_root || return 1

    cp -p "$tx_dir/argo_vmess.conf" "$CONFIG_FILE" || return 1
    if [ -f "$tx_dir/had_runtime_config" ]; then
        cp -p "$tx_dir/config.json" /etc/sing-box/config.json || return 1
    else
        rm -f /etc/sing-box/config.json
    fi
    if [ -f "$tx_dir/had_worker" ]; then
        cp -p "$tx_dir/auto_update_sub.py" /usr/local/bin/auto_update_sub.py || return 1
    else
        rm -f /usr/local/bin/auto_update_sub.py
    fi
    if is_valid_uuid "$old_uuid"; then
        if [ -f "$tx_dir/had_subscription" ]; then
            rm -rf "${SUB_ROOT:?}/${old_uuid}"
            cp -a "$tx_dir/subscription" "${SUB_ROOT}/${old_uuid}" || return 1
        else
            rm -rf "${SUB_ROOT:?}/${old_uuid}"
        fi
    fi

    load_config_with_defaults || return 1
    if [ "$restart_required" = true ] && [ "$was_running" = true ]; then
        restart_singbox >/dev/null 2>&1 || restore_failed=true
    fi
    # 只恢复事务开始前确实在运行的订阅服务，不擅自启动用户原本已停止的监听。
    if [ -f "$tx_dir/sub_was_running" ]; then
        if select_entry_ip >/dev/null 2>&1; then
            start_subscription_server >/dev/null 2>&1 || restore_failed=true
        else
            restore_failed=true
        fi
    else
        local current_sub_pid=""
        [ -f "$SUB_PID_FILE" ] && current_sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
        if is_subscription_pid "$current_sub_pid"; then
            kill "$current_sub_pid" >/dev/null 2>&1 || true
        fi
        rm -f "$SUB_PID_FILE" "$SUB_BIND_STATE_FILE"
    fi
    [ "$restore_failed" = false ]
}

apply_config_transaction() {
    local description="$1"
    shift
    [ -f "$CONFIG_FILE" ] || return 1
    [ $(( $# % 2 )) -eq 0 ] || return 1

    local tx_dir=""
    local key=""
    local value=""
    local was_running=false
    local config_changed=false
    local old_uuid=""
    tx_dir=$(mktemp -d /tmp/rr-config-tx.XXXXXX) || return 1
    cp -p "$CONFIG_FILE" "$tx_dir/argo_vmess.conf" || { rm -rf "$tx_dir"; return 1; }
    if ! load_config_with_defaults; then
        rm -rf "$tx_dir"
        return 1
    fi
    ensure_subscription_root || { rm -rf "$tx_dir"; return 1; }
    old_uuid="$UUID"
    if [ -f /etc/sing-box/config.json ]; then
        cp -p /etc/sing-box/config.json "$tx_dir/config.json" || { rm -rf "$tx_dir"; return 1; }
        : > "$tx_dir/had_runtime_config"
    fi
    if [ -f /usr/local/bin/auto_update_sub.py ]; then
        cp -p /usr/local/bin/auto_update_sub.py "$tx_dir/auto_update_sub.py" || { rm -rf "$tx_dir"; return 1; }
        : > "$tx_dir/had_worker"
    fi
    if is_valid_uuid "$old_uuid" && [ -d "${SUB_ROOT}/${old_uuid}" ]; then
        cp -a "${SUB_ROOT}/${old_uuid}" "$tx_dir/subscription" || { rm -rf "$tx_dir"; return 1; }
        : > "$tx_dir/had_subscription"
    fi
    local old_sub_pid=""
    [ -f "$SUB_PID_FILE" ] && old_sub_pid=$(cat "$SUB_PID_FILE" 2>/dev/null)
    is_subscription_pid "$old_sub_pid" && : > "$tx_dir/sub_was_running"
    managed_singbox_running && was_running=true

    while [ "$#" -gt 0 ]; do
        key="$1"
        value="$2"
        shift 2
        if ! safe_sed "$key" "$value"; then
            if cp -p "$tx_dir/argo_vmess.conf" "$CONFIG_FILE"; then
                rm -rf "$tx_dir"
            else
                echo -e "${RED}[严重] 配置回滚失败，备份保留在 ${tx_dir}。${RESET}" >&2
            fi
            return 1
        fi
    done
    if ! load_config_with_defaults; then
        if restore_config_transaction_snapshot "$tx_dir" "$old_uuid" "$was_running" false >/dev/null 2>&1; then
            rm -rf "$tx_dir"
        else
            echo -e "${RED}[严重] 配置回滚不完整，备份保留在 ${tx_dir}。${RESET}" >&2
        fi
        return 1
    fi

    if ! build_singbox_config; then
        if restore_config_transaction_snapshot "$tx_dir" "$old_uuid" "$was_running" false >/dev/null 2>&1; then
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] ${description}未通过内核配置校验，原配置和节点均未改动。${RESET}"
        else
            echo -e "${RED}[严重] ${description}失败且回滚不完整，备份保留在 ${tx_dir}。${RESET}" >&2
        fi
        return 1
    fi
    [ "$SINGBOX_CONFIG_CHANGED" = true ] && config_changed=true

    if [ "$config_changed" = true ] && [ "$was_running" = true ]; then
        if any_node_protocol_enabled; then
            if ! restart_singbox; then
                if restore_config_transaction_snapshot "$tx_dir" "$old_uuid" "$was_running" true >/dev/null 2>&1; then
                    rm -rf "$tx_dir"
                    echo -e "${RED}[失败] ${description}启动失败，已恢复原节点并重新拉起。${RESET}"
                else
                    echo -e "${RED}[严重] ${description}启动失败且回滚不完整，备份保留在 ${tx_dir}。${RESET}" >&2
                fi
                return 1
            fi
        else
            stop_singbox_instances >/dev/null 2>&1 || true
        fi
    fi

    if crontab -l 2>/dev/null | grep -q 'auto_update_sub.py'; then
        if ! write_auto_update_worker; then
            if restore_config_transaction_snapshot "$tx_dir" "$old_uuid" "$was_running" "$config_changed" >/dev/null 2>&1; then
                rm -rf "$tx_dir"
                echo -e "${RED}[失败] 自动订阅程序刷新失败，${description}已完整回滚。${RESET}"
            else
                echo -e "${RED}[严重] 自动订阅刷新失败且回滚不完整，备份保留在 ${tx_dir}。${RESET}" >&2
            fi
            return 1
        fi
    fi
    if ! generate_node_and_sub; then
        if restore_config_transaction_snapshot "$tx_dir" "$old_uuid" "$was_running" "$config_changed" >/dev/null 2>&1; then
            rm -rf "$tx_dir"
            echo -e "${RED}[失败] ${description}的订阅刷新失败，已完整回滚。${RESET}"
        else
            echo -e "${RED}[严重] ${description}订阅刷新失败且回滚不完整，备份保留在 ${tx_dir}。${RESET}" >&2
        fi
        return 1
    fi

    rm -rf "$tx_dir"
    load_config_with_defaults || return 1
    echo -e "${GREEN}[成功] ${description}已生效，节点与全部订阅文件已实时刷新。${RESET}"
    return 0
}

sync_runtime_state() {
    [ -f "$CONFIG_FILE" ] || return 1
    migrate_config_schema || return 1
    load_config_with_defaults || return 1
    local was_running=false
    managed_singbox_running && was_running=true

    if ! build_singbox_config; then
        return 1
    fi
    if [ "$SINGBOX_CONFIG_CHANGED" = true ] && [ "$was_running" = true ]; then
        restart_singbox || return 1
    fi
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_HOP_PORTS" ]; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            rr_validate_hop_rules "HY2" "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1 || {
                echo -e "${RED}[错误] HY2 跳跃规则只读检查失败，热更新未修改防火墙。${RESET}" >&2
                return 1
            }
        elif ! install_hop_rules "HY2" "$HY2_PORT" "$HY2_HOP_PORTS" >/dev/null 2>&1; then
            echo -e "${RED}[错误] HY2 跳跃规则无法应用到当前入口地址族，运行状态未同步。${RESET}" >&2
            return 1
        fi
    fi
    generate_node_and_sub || return 1
    return 0
}

# Read-side equivalent of install_hop_rules for an uncommitted release
# candidate.  Existing tagged and legacy rules are accepted, but nothing is
# appended, removed or persisted.
rr_validate_hop_rules() {
    local label="$1" main_port="$2" spec_list="$3"
    local required_command="" spec="" found=false
    local -a specs=()
    [ -z "$spec_list" ] && return 0
    is_valid_port "$main_port" && is_valid_hop_spec "$spec_list" || return 1
    case "${ENTRY_IP_MODE:-auto}" in
        ipv4) required_command=iptables ;;
        ipv6) required_command=ip6tables ;;
        *)
            if select_entry_ip >/dev/null 2>&1 && is_ip_version "$ENTRY_IP_RAW" 6; then
                required_command=ip6tables
            else
                required_command=iptables
            fi
            ;;
    esac
    command -v "$required_command" >/dev/null 2>&1 || return 1
    IFS=',' read -r -a specs <<< "$spec_list"
    for spec in "${specs[@]}"; do
        found=false
        "$required_command" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
            -m comment --comment "argo-rr-${label}" -j REDIRECT \
            --to-ports "$main_port" >/dev/null 2>&1 && found=true
        [ "$found" = true ] || \
            "$required_command" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -j REDIRECT --to-ports "$main_port" >/dev/null 2>&1 && found=true
        [ "$found" = true ] || \
            "$required_command" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -m comment --comment "argo-rr-${label}" -j DNAT \
                --to-destination ":${main_port}" >/dev/null 2>&1 && found=true
        [ "$found" = true ] || \
            "$required_command" -w 5 -t nat -C PREROUTING -p udp --dport "$spec" \
                -j DNAT --to-destination ":${main_port}" >/dev/null 2>&1 && found=true
        [ "$found" = true ] || return 1
    done
}

# NAIVE-SUPPORT：Let’s Encrypt 真证书申请与续签（NaiveProxy 专用）
naive_acme_port_80_is_safe() {
    # 未占用可直接启动 Nginx；已占用时只接受确实由 Nginx 监听的情形。
    # 不能仅用 pgrep 判断，因为 Nginx 可能只监听其他端口，而 80 实际由
    # Apache/Caddy 等用户服务占用。
    ! tcp_port_in_use 80 && return 0
    command -v ss >/dev/null 2>&1 || return 1
    ss -H -ltnp 'sport = :80' 2>/dev/null | grep -q '"nginx"'
}

restore_naive_acme_nginx_state() {
    local site="$1"
    local enabled="$2"
    local site_backup="$3"
    local had_site="$4"
    local had_enabled="$5"
    local old_enabled_target="$6"
    if [ "$had_site" = true ]; then
        cp -p "$site_backup" "$site" || return 1
    else
        rm -f "$site"
    fi
    if [ "$had_enabled" = true ]; then
        ln -sfn "$old_enabled_target" "$enabled" || return 1
    else
        rm -f "$enabled"
    fi
    if command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    return 0
}

prepare_naive_acme_webroot() {
    local naive_domain="$1"
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    local site="${RR_NAIVE_ACME_NGINX_SITE:-/etc/nginx/sites-available/rr-naive-acme.conf}"
    local enabled="${RR_NAIVE_ACME_NGINX_ENABLED:-/etc/nginx/sites-enabled/rr-naive-acme.conf}"
    local site_tmp=""
    local site_backup=""
    local old_enabled_target=""
    local had_site=false
    local had_enabled=false

    is_valid_domain "$naive_domain" || {
        echo -e "${RED}[失败] NaiveProxy 域名格式无效。${RESET}" >&2
        return 1
    }
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v nginx >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            echo -e "${RED}[失败] 热更新候选缺少 Nginx/Certbot；未运行 apt 安装。${RESET}" >&2
            return 1
        fi
        apt-get install -y nginx certbot >/dev/null 2>&1 || {
            echo -e "${RED}[失败] Nginx 或 certbot 安装失败。${RESET}" >&2
            return 1
        }
    fi
    if ! naive_acme_port_80_is_safe; then
        echo -e "${RED}[拒绝] 80 端口已被非 Nginx 程序占用；未终止该程序，也未覆盖其配置。${RESET}" >&2
        return 1
    fi

    mkdir -p "$webroot/.well-known/acme-challenge" "$(dirname "$site")" "$(dirname "$enabled")" || return 1
    # 某些 VPS 模板以 root umask 077 预建 /var/www（700）。即使 Webroot
    # 本身是 755，Nginx 也无法穿过父目录并会把 try_files 的 EACCES 表现
    # 成 404。仅增加父目录 execute 位（可穿越），不开放目录读取/列表。
    chmod a+x "$(dirname "$webroot")" || return 1
    chmod 755 "$webroot" "$webroot/.well-known" "$webroot/.well-known/acme-challenge" || return 1
    [ ! -L "$site" ] || {
        echo -e "${RED}[拒绝] NaiveProxy Nginx 站点文件是符号链接，未覆盖。${RESET}" >&2
        return 1
    }
    if [ -e "$enabled" ] && [ ! -L "$enabled" ]; then
        echo -e "${RED}[拒绝] NaiveProxy Nginx 启用项不是符号链接，未覆盖。${RESET}" >&2
        return 1
    fi
    if [ -f "$site" ]; then
        had_site=true
        site_backup=$(mktemp /tmp/rr-naive-acme-site.XXXXXX) || return 1
        cp -p "$site" "$site_backup" || { rm -f "$site_backup"; return 1; }
    fi
    if [ -L "$enabled" ]; then
        had_enabled=true
        old_enabled_target=$(readlink "$enabled") || { rm -f "$site_backup"; return 1; }
    fi

    site_tmp=$(mktemp "$(dirname "$site")/.rr-naive-acme.XXXXXX") || { rm -f "$site_backup"; return 1; }
    if ! cat > "$site_tmp" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${naive_domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        try_files \$uri =404;
    }

    location / {
        return 404;
    }
}
EOF
    then
        rm -f "$site_tmp" "$site_backup"
        return 1
    fi
    chmod 644 "$site_tmp" || { rm -f "$site_tmp" "$site_backup"; return 1; }
    mv -f "$site_tmp" "$site" || { rm -f "$site_tmp" "$site_backup"; return 1; }
    if ! ln -sfn "$site" "$enabled"; then
        restore_naive_acme_nginx_state "$site" "$enabled" "$site_backup" \
            "$had_site" "$had_enabled" "$old_enabled_target" || true
        rm -f "$site_backup"
        return 1
    fi

    if ! nginx -t >/dev/null 2>&1; then
        restore_naive_acme_nginx_state "$site" "$enabled" "$site_backup" \
            "$had_site" "$had_enabled" "$old_enabled_target" || true
        rm -f "$site_backup"
        echo -e "${RED}[失败] Nginx 配置检查失败，NaiveProxy ACME 站点已回滚。${RESET}" >&2
        return 1
    fi
    if systemctl is-active --quiet nginx 2>/dev/null; then
        systemctl reload nginx >/dev/null 2>&1 || {
            echo -e "${RED}[失败] Nginx 无法重新加载 NaiveProxy ACME 站点。${RESET}" >&2
            restore_naive_acme_nginx_state "$site" "$enabled" "$site_backup" \
                "$had_site" "$had_enabled" "$old_enabled_target" || true
            rm -f "$site_backup"
            return 1
        }
    else
        systemctl enable --now nginx >/dev/null 2>&1 || {
            echo -e "${RED}[失败] Nginx 无法启动，不能进行 NaiveProxy 域名验证。${RESET}" >&2
            restore_naive_acme_nginx_state "$site" "$enabled" "$site_backup" \
                "$had_site" "$had_enabled" "$old_enabled_target" || true
            rm -f "$site_backup"
            return 1
        }
    fi
    rm -f "$site_backup"
    open_protocol_firewall 80 tcp || return 1
    return 0
}

naive_certificate_pair_valid() {
    local certificate="$1" private_key="$2" domain="$3"
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    certificate_identity_matches "$certificate" "$domain" || return 1
    openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    certificate_private_key_matches "$certificate" "$private_key"
}

sync_naive_certificate_pair() {
    local source_dir="$1" target_dir="$2" domain="$3" cert_tmp="" key_tmp=""
    naive_certificate_pair_valid "$source_dir/fullchain.pem" "$source_dir/privkey.pem" "$domain" || return 1
    install -d -m 700 "$target_dir" || return 1
    cert_tmp=$(mktemp "$target_dir/.fullchain.XXXXXX") || return 1
    key_tmp=$(mktemp "$target_dir/.privkey.XXXXXX") || { rm -f "$cert_tmp"; return 1; }
    install -m 600 "$source_dir/fullchain.pem" "$cert_tmp" && \
        install -m 600 "$source_dir/privkey.pem" "$key_tmp" && \
        mv -f "$key_tmp" "$target_dir/privkey.pem" && \
        mv -f "$cert_tmp" "$target_dir/fullchain.pem" || {
            rm -f "$cert_tmp" "$key_tmp"
            return 1
        }
}

ensure_naive_certificate() {
    # 返回 0=证书就绪；非 0=失败。真证书，不允许自签。
    local naive_domain="${1:-$NAIVE_DOMAIN}"
    local le_email="${2:-${LE_EMAIL:-}}"
    local le_live_root="${RR_LE_LIVE_ROOT:-/etc/letsencrypt/live}"
    local naive_cert_dir="${RR_NAIVE_CERT_DIR:-/etc/rr-naive}"
    local webroot="${RR_NAIVE_ACME_WEBROOT:-/var/www/rr-nexus-certbot}"
    [ -n "$naive_domain" ] || { echo -e "${RED}[失败] 未设置 NaiveProxy 域名。${RESET}" >&2; return 1; }
    is_valid_domain "$naive_domain" || { echo -e "${RED}[失败] NaiveProxy 域名格式无效。${RESET}" >&2; return 1; }
    # LE 拒绝 example.com 邮箱；未配置时从已校验域名派生合法邮箱。
    [ -n "$le_email" ] || le_email="admin@${naive_domain}"

    if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
        if ! naive_certificate_pair_valid \
            "${le_live_root}/${naive_domain}/fullchain.pem" \
            "${le_live_root}/${naive_domain}/privkey.pem" "$naive_domain"; then
            echo -e "${RED}[失败] 热更新候选不会签发或续签 NaiveProxy 证书。${RESET}" >&2
            return 1
        fi
        install -d -m 700 "$naive_cert_dir" || return 1
        sync_naive_certificate_pair "${le_live_root}/${naive_domain}" \
            "$naive_cert_dir" "$naive_domain" || return 1
        deploy_naive_cert_hook
        return $?
    fi
    install -d -m 700 "$naive_cert_dir" || return 1

    # Webroot 模式不仅需要目录，还必须在签发及续签时有真实 HTTP 服务。
    # 首装阶段 Sing-box/Nexus 尚未启动，因此先安全配置 Nginx 并放行 80。
    prepare_naive_acme_webroot "$naive_domain" || return 1

    # 仅复用 SAN、有效期和私钥都匹配的在线 lineage。Portable restore
    # 带来的叶子证书没有目标机续签配置，必须在这里重新建立 lineage。
    if naive_certificate_pair_valid "${le_live_root}/${naive_domain}/fullchain.pem" \
        "${le_live_root}/${naive_domain}/privkey.pem" "$naive_domain"; then
        sync_naive_certificate_pair "${le_live_root}/${naive_domain}" "$naive_cert_dir" "$naive_domain" || return 1
        deploy_naive_cert_hook
        return 0
    fi

    # 6.6.15：root umask 077（DMIT 模板等）会让目录 700/文件 600，
    # nginx(www-data) 读不了挑战文件 → LE 403。显式 chmod + umask 022。
    echo -e "${YELLOW}正在为 ${naive_domain} 申请 Let’s Encrypt 真证书……${RESET}"
    if ! (umask 022 && certbot certonly --webroot -w "$webroot" -d "$naive_domain" \
        -m "$le_email" --agree-tos --non-interactive --quiet --force-renewal 2>/dev/null); then
        echo -e "${RED}[失败] 证书申请失败：请确认 ${naive_domain} 已解析到本机公网 IP、80 端口可访问；如日志提示邮箱被拒（invalid email），请在 /etc/argo_vmess.conf 添加 LE_EMAIL=你的邮箱 后重试。${RESET}" >&2
        return 1
    fi
    sync_naive_certificate_pair "${le_live_root}/${naive_domain}" "$naive_cert_dir" "$naive_domain" || return 1
    deploy_naive_cert_hook
    echo -e "${GREEN}[成功] NaiveProxy Let’s Encrypt 真证书已就绪（/etc/rr-naive/）。${RESET}"
    return 0
}

deploy_naive_cert_hook() {
    # certbot renew 后的通用 deploy 钩子：同步 NaiveProxy 证书，并在
    # 同一 lineage 也承载订阅 HTTPS 时安全刷新订阅进程。
    local naive_domain="${1:-$NAIVE_DOMAIN}"
    [ -n "$naive_domain" ] || return 0
    local hook_dir="/etc/letsencrypt/renewal-hooks/deploy"
    local hook_source="${RR_RUNTIME_DIR:-/usr/local/lib/rr}/scripts/naive-cert-hook.sh"
    mkdir -p "$hook_dir"
    local hook_file="${hook_dir}/rr-certificates.sh"
    [ -s "$hook_source" ] && bash -n "$hook_source" || return 1
    install -d -m 700 "$hook_dir" || return 1
    install -m 700 "$hook_source" "$hook_file" || return 1
    rm -f "${hook_dir}/rr-naive-cert.sh"
    return 0
}
