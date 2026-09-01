# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 3. 安装并配置 Sing-box 内核
# ==========================================
RR_SINGBOX_TLS_PAIR_PENDING_FILE="${RR_SINGBOX_TLS_PAIR_PENDING_FILE:-/etc/sing-box/.pair-pending}"
RR_NAIVE_CERT_PAIR_PENDING_FILE="${RR_NAIVE_CERT_PAIR_PENDING_FILE:-/etc/rr-naive/.pair-pending}"
RR_CERTIFICATE_PAIR_PENDING_VALUE="rr-certificate-pair-pending-v1"

rr_certificate_pair_pending_is_exact() {
    local marker="$1" expected_size=$(( ${#RR_CERTIFICATE_PAIR_PENDING_VALUE} + 1 ))
    local -a lines=()
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h:%s' -- "$marker" 2>/dev/null)" = \
        "0:0:600:1:${expected_size}" ] || return 1
    mapfile -t lines < "$marker" || return 1
    [ "${#lines[@]}" -eq 1 ] && \
        [ "${lines[0]}" = "$RR_CERTIFICATE_PAIR_PENDING_VALUE" ]
}

rr_certificate_pair_pending_publish() {
    local marker="$1" directory="" temporary=""
    directory=$(dirname -- "$marker") || return 1
    install -d -o 0 -g 0 -m 700 -- "$directory" || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null)" = 0:0:700 ] || return 1
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        rr_certificate_pair_pending_is_exact "$marker"
        return $?
    fi
    temporary=$(mktemp "$directory/.pair-pending.XXXXXX") || return 1
    if ! printf '%s\n' "$RR_CERTIFICATE_PAIR_PENDING_VALUE" > "$temporary" || \
       ! chown 0:0 "$temporary" || ! chmod 600 "$temporary" || \
       ! sync -f "$temporary" || ! mv -f -- "$temporary" "$marker" || \
       ! sync -f "$directory" || ! rr_certificate_pair_pending_is_exact "$marker"; then
        rm -f -- "$temporary"
        return 1
    fi
}

rr_certificate_pair_pending_clear() {
    local marker="$1" directory=""
    rr_certificate_pair_pending_is_exact "$marker" || return 1
    directory=$(dirname -- "$marker") || return 1
    rm -f -- "$marker" || return 1
    sync -f "$directory" || return 1
    [ ! -e "$marker" ] && [ ! -L "$marker" ]
}

rr_certificate_private_key_pair_matches() {
    local certificate="$1" private_key="$2" cert_public="" key_public=""
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    openssl x509 -in "$certificate" -noout >/dev/null 2>&1 || return 1
    openssl pkey -in "$private_key" -check -noout -passin pass: \
        >/dev/null 2>&1 || return 1
    cert_public=$(openssl x509 -in "$certificate" -pubkey -noout 2>/dev/null | \
        sha256sum | awk '{print $1}') || return 1
    key_public=$(openssl pkey -in "$private_key" -pubout 2>/dev/null | \
        sha256sum | awk '{print $1}') || return 1
    [[ "$cert_public" =~ ^[0-9a-f]{64}$ ]] && [ "$cert_public" = "$key_public" ]
}

rr_publish_certificate_pair() {
    local certificate_source="$1" key_source="$2" certificate_target="$3"
    local key_target="$4" marker="$5" validator="$6" directory=""
    shift 6
    directory=$(dirname -- "$certificate_target") || return 1
    [ "$(dirname -- "$key_target")" = "$directory" ] || return 1
    [ "$(dirname -- "$marker")" = "$directory" ] || return 1
    "$validator" "$certificate_source" "$key_source" "$@" || return 1
    sync -f "$certificate_source" && sync -f "$key_source" || return 1
    rr_certificate_pair_pending_publish "$marker" || return 1
    mv -f -- "$key_source" "$key_target" || return 1
    sync -f "$directory" || return 1
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CERT_PAIR_FAIL_AFTER_FIRST:-0}" = 1 ]; then
        return 1
    fi
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_CERT_PAIR_CRASH_AFTER_FIRST:-0}" = 1 ]; then
        kill -KILL "$$"
    fi
    mv -f -- "$certificate_source" "$certificate_target" || return 1
    sync -f "$directory" || return 1
    "$validator" "$certificate_target" "$key_target" "$@" || return 1
    rr_certificate_pair_pending_clear "$marker"
}

rr_singbox_certificate_start_gate_for_paths() {
    local self_certificate="$1" self_key="$2" self_marker="$3"
    local naive_certificate="$4" naive_key="$5" naive_marker="$6" marker=""
    for marker in "$self_marker" "$naive_marker"; do
        [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 78
    done
    if [ -e "$self_certificate" ] || [ -L "$self_certificate" ] || \
       [ -e "$self_key" ] || [ -L "$self_key" ]; then
        rr_certificate_private_key_pair_matches \
            "$self_certificate" "$self_key" || return 78
    fi
    if [ -e "$naive_certificate" ] || [ -L "$naive_certificate" ] || \
       [ -e "$naive_key" ] || [ -L "$naive_key" ]; then
        rr_certificate_private_key_pair_matches \
            "$naive_certificate" "$naive_key" || return 78
    fi
    return 0
}

rr_singbox_certificate_start_gate() {
    rr_singbox_certificate_start_gate_for_paths \
        /etc/sing-box/cert.pem /etc/sing-box/private.key \
        /etc/sing-box/.pair-pending \
        /etc/rr-naive/fullchain.pem /etc/rr-naive/privkey.pem \
        /etc/rr-naive/.pair-pending
}

rr_publish_regular_file_atomic() {
    local source="$1" target="$2" target_mode="$3"
    local directory="" base="" temporary="" backup="" mode="" fault=""
    local target_existed=false
    [ -f "$source" ] && [ ! -L "$source" ] || return 1
    [[ "$target" = /* && "$target" != *[[:space:]]* ]] || return 1
    directory=$(dirname -- "$target") || return 1
    base=$(basename -- "$target") || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] && \
        [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c %a -- "$directory" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] && [ $((8#$mode & 8#022)) -eq 0 ] || \
        return 1
    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] && \
            [ "$(stat -c '%u:%g:%h' -- "$target" 2>/dev/null)" = 0:0:1 ] || \
            return 1
        target_existed=true
    fi
    if [ "${RR_TEST_FAULTS:-0}" = 1 ]; then
        fault="${RR_TEST_ATOMIC_PUBLISH_FAULT:-}"
        case "$fault" in ""|copy|file-fsync|rename|dir-fsync) ;; *) return 1 ;; esac
    fi
    if [ "$target_existed" = true ]; then
        backup=$(mktemp "$directory/.${base}.rr-rollback.XXXXXX") || return 1
        if ! cp -p -- "$target" "$backup" || ! sync -f "$backup"; then
            rm -f -- "$backup"
            return 1
        fi
    fi
    temporary=$(mktemp "$directory/.${base}.rr-publish.XXXXXX") || {
        rm -f -- "$backup"
        return 1
    }
    if [ "$fault" = copy ] || \
       ! install -o 0 -g 0 -m "$target_mode" -- "$source" "$temporary" || \
       [ "$fault" = file-fsync ] || ! sync -f "$temporary" || \
       [ "$fault" = rename ] || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary" "$backup"
        return 1
    fi
    if [ "$fault" = dir-fsync ] || ! sync -f "$directory"; then
        if [ "$target_existed" = true ]; then
            mv -f -- "$backup" "$target" || return 2
            backup=""
        else
            unlink -- "$target" || return 2
        fi
        sync -f "$directory" || return 2
        return 1
    fi
    if ! [ -f "$target" ] || [ -L "$target" ] || \
       [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" != \
         "0:0:${target_mode}:1" ] || ! cmp -s -- "$source" "$target"; then
        if [ "$target_existed" = true ]; then
            mv -f -- "$backup" "$target" || return 2
            backup=""
        else
            unlink -- "$target" || return 2
        fi
        sync -f "$directory" || return 2
        return 2
    fi
    if [ -n "$backup" ]; then
        rm -f -- "$backup" || return 2
        sync -f "$directory" >/dev/null 2>&1 || true
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = \
          "0:0:${target_mode}:1" ] && cmp -s -- "$source" "$target"
}

rr_remove_regular_file_atomic() {
    local target="$1" expected_sha="${2:-}" directory="" actual_sha=""
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%h' -- "$target" 2>/dev/null)" = 0:0:1 ] || \
        return 1
    [[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual_sha=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') || \
        return 1
    [ "$actual_sha" = "$expected_sha" ] || return 1
    directory=$(dirname -- "$target") || return 1
    unlink -- "$target" || return 1
    sync -f "$directory"
}

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
    local published_binary_sha=""
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
        cp -p "$SINGBOX_BIN" "$old_binary" && sync -f "$old_binary" || \
            { rm -rf "$sb_tmp_dir"; return 1; }
    fi
    if [ -f /etc/sing-box/config.json ]; then
        old_config="$sb_tmp_dir/config.json.previous"
        cp -p /etc/sing-box/config.json "$old_config" && \
            sync -f "$old_config" || { rm -rf "$sb_tmp_dir"; return 1; }
    fi
    # 内核升级只停/重启 systemd 管理的 sing-box 服务；绝不主动清理或杀死
    # 非 systemd 的手动进程（替换二进制不影响已运行进程——旧 inode 继续承载
    # 流量，新配置由后续 systemd 服务接管）。
    systemctl is-active --quiet sing-box 2>/dev/null && was_running=true

    rr_publish_regular_file_atomic "$candidate" "$SINGBOX_BIN" 755 || \
        { rm -rf "$sb_tmp_dir"; return 1; }
    published_binary_sha=$(sha256sum -- "$SINGBOX_BIN" | awk '{print $1}') || \
        { rm -rf "$sb_tmp_dir"; return 1; }

    # 旧进程继续提供流量；新内核先生成并自检配置，成功后才做一次快速重启。
    if [ "$validate_current_config" = true ]; then
        if ! build_singbox_config; then
            if [ -n "$old_binary" ]; then
                rr_restore_transaction_file_atomic "$old_binary" "$SINGBOX_BIN" || \
                    { rm -rf "$sb_tmp_dir"; return 1; }
            else
                rr_remove_regular_file_atomic "$SINGBOX_BIN" \
                    "$published_binary_sha" || { rm -rf "$sb_tmp_dir"; return 1; }
            fi
            if [ -n "$old_config" ]; then
                rr_restore_transaction_file_atomic "$old_config" \
                    /etc/sing-box/config.json || { rm -rf "$sb_tmp_dir"; return 1; }
            else
                rr_remove_regular_file_atomic /etc/sing-box/config.json \
                    "${SINGBOX_CONFIG_PUBLISHED_SHA256:-}" || \
                    { rm -rf "$sb_tmp_dir"; return 1; }
            fi
            rm -rf "$sb_tmp_dir"
            echo -e "${RED}[失败] 新内核与当前节点配置不兼容，已保留旧内核和运行配置。${RESET}"
            return 1
        fi
        if [ "$was_running" = true ] && ! restart_singbox_systemd_only; then
            if [ -n "$old_binary" ]; then
                rr_restore_transaction_file_atomic "$old_binary" "$SINGBOX_BIN" || \
                    { rm -rf "$sb_tmp_dir"; return 1; }
            else
                rr_remove_regular_file_atomic "$SINGBOX_BIN" \
                    "$published_binary_sha" || { rm -rf "$sb_tmp_dir"; return 1; }
            fi
            if [ -n "$old_config" ]; then
                rr_restore_transaction_file_atomic "$old_config" \
                    /etc/sing-box/config.json || { rm -rf "$sb_tmp_dir"; return 1; }
            else
                rr_remove_regular_file_atomic /etc/sing-box/config.json \
                    "${SINGBOX_CONFIG_PUBLISHED_SHA256:-}" || \
                    { rm -rf "$sb_tmp_dir"; return 1; }
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

rr_render_singbox_systemd_unit() {
    cat <<'EOF'
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
ExecStartPre=/usr/local/bin/rr --singbox-certificate-gate
ExecStartPre=/usr/local/bin/sing-box check -c /etc/sing-box/config.json
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartPreventExitStatus=78
RestartSec=2
TimeoutStopSec=10
KillMode=mixed
LimitNOFILE=1048576
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
}

rr_render_singbox_systemd_unit_legacy_710() {
    cat <<'EOF'
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
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=2
TimeoutStopSec=10
KillMode=mixed
LimitNOFILE=1048576
UMask=0077
[Install]
WantedBy=multi-user.target
EOF
}

write_singbox_systemd_unit() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local unit_tmp="" unit_dir=""
    rr_singbox_service_is_owned_or_absent || return 1
    unit_dir=$(dirname -- "$service_file") || return 1
    install -d -o 0 -g 0 -m 755 "$unit_dir" || return 1
    [ -d "$unit_dir" ] && [ ! -L "$unit_dir" ] || return 1
    [ "$(stat -c '%u:%g' -- "$unit_dir" 2>/dev/null)" = 0:0 ] || return 1
    unit_tmp=$(mktemp "$unit_dir/.sing-box.service.XXXXXX") || return 1
    if ! rr_render_singbox_systemd_unit > "$unit_tmp"
    then
        rm -f "$unit_tmp"
        return 1
    fi
    chown 0:0 "$unit_tmp" && chmod 644 "$unit_tmp" && \
        sync -f "$unit_tmp" && mv -f -- "$unit_tmp" "$service_file" && \
        sync -f "$unit_dir" || { rm -f -- "$unit_tmp"; return 1; }
    [ -f "$service_file" ] && [ ! -L "$service_file" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$service_file" 2>/dev/null)" = \
            0:0:644:1 ] && \
        cmp -s -- "$service_file" <(rr_render_singbox_systemd_unit)
}

rr_singbox_service_guards_are_effective() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local unit="sing-box.service" load_state="" fragment="" exec_start_pre=""
    local exec_start="" exec_reload="" interval="" burst="" restart=""
    local restart_prevent="" user="" working_directory="" dynamic_user=""
    local private_network="" root_directory="" root_image="" conditions="" asserts=""
    local dropin_paths="" exec_condition="" value=""
    local restore_present=false firewall_present=false
    local -a rr_singbox_gate_lines=()
    local systemd_root="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}"
    local restore_name="${RR_RESTORE_GATE_DROPIN_NAME:-zzzz-rr-restore-gate.conf}"
    local firewall_name="${RR_RESTORE_FIREWALL_GATE_DROPIN_NAME:-zzzzz-rr-firewall-quarantine.conf}"
    local restore_dropin="$systemd_root/sing-box.service.d/$restore_name"
    local firewall_dropin="$systemd_root/sing-box.service.d/$firewall_name"
    local restore_argv="/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate"
    local firewall_marker="/var/lib/rr-vps/firewall-quarantine"
    load_state=$(systemctl show --property=LoadState --value "$unit" 2>/dev/null) || return 1
    [ "$load_state" = loaded ] || return 1
    fragment=$(systemctl show --property=FragmentPath --value "$unit" 2>/dev/null) || return 1
    [ "$fragment" = "$service_file" ] || return 1
    [ -f "$service_file" ] && [ ! -L "$service_file" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$service_file" 2>/dev/null)" = \
            0:0:644:1 ] || return 1
    cmp -s -- "$service_file" <(rr_render_singbox_systemd_unit) || return 1
    exec_start_pre=$(systemctl show --property=ExecStartPre --value "$unit" 2>/dev/null) || return 1
    python3 - "$exec_start_pre" <<'PY' || return 1
import re
import sys

raw = sys.argv[1]
records = []
for encoded in re.findall(r"\{([^{}]*)\}", raw):
    fields = {}
    for item in encoded.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        if key.strip() in fields:
            raise SystemExit(1)
        fields[key.strip()] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
expected = [
    ("/usr/local/bin/rr", "/usr/local/bin/rr --singbox-certificate-gate", "no"),
    (
        "/usr/local/bin/sing-box",
        "/usr/local/bin/sing-box check -c /etc/sing-box/config.json",
        "no",
    ),
]
if (
    records != expected
    or raw.count("{") != 2
    or raw.count("path=") != 2
    or raw.count("argv[]=") != 2
):
    raise SystemExit(1)
PY
    exec_start=$(systemctl show --property=ExecStart --value "$unit" 2>/dev/null) || return 1
    exec_reload=$(systemctl show --property=ExecReload --value "$unit" 2>/dev/null) || return 1
    python3 - "$exec_start" "$exec_reload" <<'PY' || return 1
import re
import sys


def one_record(raw):
    encoded = re.findall(r"\{([^{}]*)\}", raw)
    if len(encoded) != 1 or raw.count("{") != 1 or raw.count("}") != 1:
        raise SystemExit(1)
    fields = {}
    for item in encoded[0].split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    return fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors")


if one_record(sys.argv[1]) != (
    "/usr/local/bin/sing-box",
    "/usr/local/bin/sing-box run -c /etc/sing-box/config.json",
    "no",
):
    raise SystemExit(1)
if one_record(sys.argv[2]) != (
    "/bin/kill",
    "/bin/kill -HUP $MAINPID",
    "no",
):
    raise SystemExit(1)
PY
    user=$(systemctl show --property=User --value "$unit" 2>/dev/null) || return 1
    working_directory=$(systemctl show --property=WorkingDirectory --value \
        "$unit" 2>/dev/null) || return 1
    dynamic_user=$(systemctl show --property=DynamicUser --value "$unit" 2>/dev/null) || return 1
    private_network=$(systemctl show --property=PrivateNetwork --value \
        "$unit" 2>/dev/null) || return 1
    root_directory=$(systemctl show --property=RootDirectory --value \
        "$unit" 2>/dev/null) || return 1
    root_image=$(systemctl show --property=RootImage --value "$unit" 2>/dev/null) || return 1
    conditions=$(systemctl show --property=Conditions --value "$unit" 2>/dev/null) || return 1
    asserts=$(systemctl show --property=Asserts --value "$unit" 2>/dev/null) || return 1
    [ "$user" = root ] && [ "$working_directory" = /etc/sing-box ] && \
        [ "$dynamic_user" = no ] && [ "$private_network" = no ] && \
        [ -z "$root_directory" ] && [ -z "$root_image" ] && \
        [ -z "$conditions" ] && [ -z "$asserts" ] || return 1
    dropin_paths=$(systemctl show --property=DropInPaths --value "$unit" 2>/dev/null) || return 1
    python3 - "$dropin_paths" "$restore_dropin" "$firewall_dropin" <<'PY' || return 1
import os
import sys

raw, restore, firewall = sys.argv[1:]
paths = raw.split()
if len(paths) != len(set(paths)) or paths not in ([], [restore], [firewall], [restore, firewall]):
    raise SystemExit(1)
if any(not path.startswith("/") or os.path.normpath(path) != path for path in paths):
    raise SystemExit(1)
PY
    case " $dropin_paths " in *" $restore_dropin "*) restore_present=true ;; esac
    case " $dropin_paths " in *" $firewall_dropin "*) firewall_present=true ;; esac
    if [ "$restore_present" = true ]; then
        [ -f "$restore_dropin" ] && [ ! -L "$restore_dropin" ] && \
            [ "$(stat -c '%u:%g:%a:%h' -- "$restore_dropin" 2>/dev/null)" = \
                0:0:644:1 ] || return 1
        mapfile -t rr_singbox_gate_lines < "$restore_dropin" || return 1
        [ "${#rr_singbox_gate_lines[@]}" -eq 2 ] && \
            [ "${rr_singbox_gate_lines[0]}" = '[Service]' ] && \
            [ "${rr_singbox_gate_lines[1]}" = \
                "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'" ] || return 1
    fi
    if [ "$firewall_present" = true ]; then
        [ -f "$firewall_dropin" ] && [ ! -L "$firewall_dropin" ] && \
            [ "$(stat -c '%u:%g:%a:%h' -- "$firewall_dropin" 2>/dev/null)" = \
                0:0:644:1 ] || return 1
        mapfile -t rr_singbox_gate_lines < "$firewall_dropin" || return 1
        [ "${#rr_singbox_gate_lines[@]}" -eq 3 ] && \
            [ "${rr_singbox_gate_lines[0]}" = '[Service]' ] && \
            [ "${rr_singbox_gate_lines[1]}" = \
                'ExecCondition=/usr/bin/test ! -e /var/lib/rr-vps/firewall-quarantine' ] && \
            [ "${rr_singbox_gate_lines[2]}" = \
                'ExecCondition=/usr/bin/test ! -L /var/lib/rr-vps/firewall-quarantine' ] || return 1
    fi
    exec_condition=$(systemctl show --property=ExecCondition --value \
        "$unit" 2>/dev/null) || return 1
    python3 - "$exec_condition" "$restore_present" "$restore_argv" \
        "$firewall_present" "$firewall_marker" <<'PY' || return 1
import re
import sys

raw, restore_present, restore_argv, firewall_present, marker = sys.argv[1:]
records = []
for encoded in re.findall(r"\{([^{}]*)\}", raw):
    fields = {}
    for item in encoded.split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append((fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors")))
expected = []
if restore_present == "true":
    expected.append(("/bin/sh", restore_argv, "no"))
if firewall_present == "true":
    expected.extend(
        [
            ("/usr/bin/test", f"/usr/bin/test ! -e {marker}", "no"),
            ("/usr/bin/test", f"/usr/bin/test ! -L {marker}", "no"),
        ]
    )
if records != expected or raw.count("{") != len(expected) or raw.count("}") != len(expected):
    raise SystemExit(1)
PY
    interval=$(systemctl show --property=StartLimitIntervalUSec --value \
        "$unit" 2>/dev/null) || return 1
    case "$interval" in 1min|60s|60000000|60000000us) ;; *) return 1 ;; esac
    burst=$(systemctl show --property=StartLimitBurst --value "$unit" 2>/dev/null) || return 1
    [ "$burst" = 5 ] || return 1
    restart=$(systemctl show --property=Restart --value "$unit" 2>/dev/null) || return 1
    [ "$restart" = on-failure ] || return 1
    restart_prevent=$(systemctl show --property=RestartPreventExitStatus --value \
        "$unit" 2>/dev/null) || return 1
    [ "$restart_prevent" = 78 ] || return 1
    rr_singbox_effective_control_hooks_are_empty || return 1
    if declare -F rr_firewall_effective_marker_view_is_safe \
        >/dev/null 2>&1; then
        rr_firewall_effective_marker_view_is_safe sing-box.service || return 1
    else
        value=$(systemctl show --property=SystemCallFilter --value \
            sing-box.service 2>/dev/null) || return 1
        [ "$value" = '~' ] || return 1
    fi
}

rr_singbox_effective_control_hooks_are_empty() {
    local property="" value=""
    for property in ExecStartPost ExecStop ExecStopPost; do
        value=$(systemctl show --property="$property" --value \
            sing-box.service 2>/dev/null) || return 1
        rr_health_effective_exec_vector_is_exact "$value" || return 1
    done
}

rr_singbox_legacy_service_is_owned() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local load_state="" fragment="" dropins="" exec_start="" exec_pre=""
    local exec_reload="" exec_condition="" value="" property=""
    [ -f "$service_file" ] && [ ! -L "$service_file" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$service_file" 2>/dev/null)" = \
          0:0:644:1 ] && \
        cmp -s -- "$service_file" \
            <(rr_render_singbox_systemd_unit_legacy_710) || return 1
    load_state=$(systemctl show --property=LoadState --value \
        sing-box.service 2>/dev/null) || return 1
    fragment=$(systemctl show --property=FragmentPath --value \
        sing-box.service 2>/dev/null) || return 1
    [ "$load_state" = loaded ] && [ "$fragment" = "$service_file" ] || return 1
    dropins=$(systemctl show --property=DropInPaths --value \
        sing-box.service 2>/dev/null) || return 1
    if [ -n "$dropins" ]; then
        declare -F rr_restore_effective_conditions_are_managed \
            >/dev/null 2>&1 || return 1
        rr_restore_effective_conditions_are_managed sing-box.service || return 1
    else
        exec_condition=$(systemctl show --property=ExecCondition --value \
            sing-box.service 2>/dev/null) || return 1
        rr_health_effective_exec_vector_is_exact "$exec_condition" || return 1
    fi
    exec_start=$(systemctl show --property=ExecStart --value \
        sing-box.service 2>/dev/null) || return 1
    exec_pre=$(systemctl show --property=ExecStartPre --value \
        sing-box.service 2>/dev/null) || return 1
    exec_reload=$(systemctl show --property=ExecReload --value \
        sing-box.service 2>/dev/null) || return 1
    rr_health_effective_exec_vector_is_exact "$exec_start" \
        /usr/local/bin/sing-box \
        '/usr/local/bin/sing-box run -c /etc/sing-box/config.json' || return 1
    rr_health_effective_exec_vector_is_exact "$exec_pre" \
        /usr/local/bin/sing-box \
        '/usr/local/bin/sing-box check -c /etc/sing-box/config.json' || return 1
    rr_health_effective_exec_vector_is_exact "$exec_reload" /bin/kill \
        '/bin/kill -HUP $MAINPID' || return 1
    rr_singbox_effective_control_hooks_are_empty || return 1
    for property in User Group; do
        value=$(systemctl show --property="$property" --value \
            sing-box.service 2>/dev/null) || return 1
        case "$value" in ""|root) ;; *) return 1 ;; esac
    done
    value=$(systemctl show --property=WorkingDirectory --value \
        sing-box.service 2>/dev/null) || return 1
    [ "$value" = /etc/sing-box ] || return 1
    for property in DynamicUser PrivateUsers PrivateMounts PrivateNetwork; do
        value=$(systemctl show --property="$property" --value \
            sing-box.service 2>/dev/null) || return 1
        [ "$value" = no ] || return 1
    done
    if declare -F rr_firewall_effective_marker_view_is_safe \
        >/dev/null 2>&1; then
        rr_firewall_effective_marker_view_is_safe sing-box.service || return 1
    else
        for property in RootDirectory RootImage Environment EnvironmentFiles \
            PAMName; do
            value=$(systemctl show --property="$property" --value \
                sing-box.service 2>/dev/null) || return 1
            [ -z "$value" ] || return 1
        done
        value=$(systemctl show --property=SystemCallFilter --value \
            sing-box.service 2>/dev/null) || return 1
        [ "$value" = '~' ] || return 1
    fi
    value=$(systemctl show --property=StartLimitIntervalUSec --value \
        sing-box.service 2>/dev/null) || return 1
    case "$value" in 1min|60s|60000000|60000000us) ;; *) return 1 ;; esac
    value=$(systemctl show --property=StartLimitBurst --value \
        sing-box.service 2>/dev/null) || return 1
    [ "$value" = 5 ] || return 1
    value=$(systemctl show --property=RestartPreventExitStatus --value \
        sing-box.service 2>/dev/null) || return 1
    [[ "$value" =~ ^[[:space:]{}]*$ ]]
}

rr_singbox_service_is_owned_or_absent() {
    local service_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local dropin_dir="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}/sing-box.service.d"
    local load_state="" fragment="" dropins=""
    if [ -e "$service_file" ] || [ -L "$service_file" ]; then
        if cmp -s -- "$service_file" <(rr_render_singbox_systemd_unit); then
            rr_singbox_service_guards_are_effective
        else
            rr_singbox_legacy_service_is_owned
        fi
        return
    fi
    if [ -e "$dropin_dir" ] || [ -L "$dropin_dir" ]; then
        [ -d "$dropin_dir" ] && [ ! -L "$dropin_dir" ] && \
            [ -z "$(find "$dropin_dir" -mindepth 1 -maxdepth 1 -print -quit \
                2>/dev/null)" ] || return 1
    fi
    load_state=$(systemctl show --property=LoadState --value \
        sing-box.service 2>/dev/null) || return 1
    fragment=$(systemctl show --property=FragmentPath --value \
        sing-box.service 2>/dev/null) || return 1
    dropins=$(systemctl show --property=DropInPaths --value \
        sing-box.service 2>/dev/null) || return 1
    [ "$load_state" = not-found ] && [ -z "$fragment" ] && [ -z "$dropins" ]
}

setup_systemd() {
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝启动 Sing-box。${RESET}" >&2
        return 1
    fi
    write_singbox_systemd_unit || return 1
    systemctl daemon-reload || return 1
    rr_singbox_service_guards_are_effective || return 1
    rr_singbox_service_guards_are_effective || return 1
    systemctl enable sing-box >/dev/null 2>&1 || return 1
    restart_singbox
}

ensure_node_service_running() {
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝启动 Sing-box。${RESET}" >&2
        return 1
    fi
    load_config_with_defaults || return 1
    any_node_protocol_enabled || return 0
    if [ ! -f /etc/systemd/system/sing-box.service ]; then
        setup_systemd
    elif ! managed_singbox_running; then
        restart_singbox
    fi
}

rr_render_health_monitor_service() {
    cat <<'EOF'
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
}

rr_render_health_monitor_timer() {
    cat <<'EOF'
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
}

rr_health_unit_parent_is_safe() {
    local directory="$1" mode=""
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    [ "$(stat -c '%u:%g' -- "$directory" 2>/dev/null)" = 0:0 ] || return 1
    mode=$(stat -c %a -- "$directory" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

rr_health_unit_target_is_safe_or_absent() {
    local target="$1" mode=""
    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi
    [ -f "$target" ] && [ ! -L "$target" ] || return 1
    [ "$(stat -c '%u:%g:%h' -- "$target" 2>/dev/null)" = 0:0:1 ] || return 1
    mode=$(stat -c %a -- "$target" 2>/dev/null) || return 1
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    [ $((8#$mode & 8#022)) -eq 0 ]
}

rr_health_monitor_unit_files_are_current() {
    local service_file="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
    local timer_file="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
    local service_parent="" timer_parent=""
    [ "$(stat -c '%u:%g:%h:%a' -- "$service_file" 2>/dev/null)" = \
        0:0:1:644 ] || return 1
    [ "$(stat -c '%u:%g:%h:%a' -- "$timer_file" 2>/dev/null)" = \
        0:0:1:644 ] || return 1
    [ ! -L "$service_file" ] && [ ! -L "$timer_file" ] || return 1
    [ "$(readlink -f -- "$service_file" 2>/dev/null)" = "$service_file" ] && \
        [ "$(readlink -f -- "$timer_file" 2>/dev/null)" = "$timer_file" ] || \
        return 1
    service_parent=$(dirname -- "$service_file") || return 1
    timer_parent=$(dirname -- "$timer_file") || return 1
    rr_health_unit_parent_is_safe "$service_parent" && \
        rr_health_unit_parent_is_safe "$timer_parent" || return 1
    cmp -s -- "$service_file" <(rr_render_health_monitor_service) || return 1
    cmp -s -- "$timer_file" <(rr_render_health_monitor_timer)
}

rr_health_effective_exec_vector_is_exact() {
    local raw="$1"
    shift
    [ $(( $# % 2 )) -eq 0 ] || return 1
    python3 - "$raw" "$@" <<'PY'
import re
import sys

raw = sys.argv[1]
spec = sys.argv[2:]
expected = [(spec[i], spec[i + 1], "no") for i in range(0, len(spec), 2)]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if residual.strip():
    raise SystemExit(1)
records = []
for match in matches:
    fields = {}
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(1)
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    records.append(
        (fields.get("path"), fields.get("argv[]"), fields.get("ignore_errors"))
    )
if records != expected:
    raise SystemExit(1)
for key in ("path=", "argv[]=", "ignore_errors="):
    if raw.count(key) != len(expected):
        raise SystemExit(1)
PY
}

rr_health_dropin_file_is_exact() {
    local kind="$1" target="$2" marker=""
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = \
          0:0:644:1 ] || return 1
    [ "$(readlink -f -- "$target" 2>/dev/null)" = "$target" ] || return 1
    case "$kind" in
        restore)
            cmp -s -- "$target" <(printf '%s\n' '[Service]' \
                "ExecCondition=/bin/sh -c '[ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate'")
            ;;
        firewall)
            marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
            cmp -s -- "$target" <(printf '%s\n' '[Service]' \
                "ExecCondition=/usr/bin/test ! -e $marker" \
                "ExecCondition=/usr/bin/test ! -L $marker")
            ;;
        *) return 1 ;;
    esac
}

rr_health_effective_dropins_are_exact() {
    local root="${RR_RESTORE_SYSTEMD_DIR:-/etc/systemd/system}"
    local directory="$root/argo-rr-health.service.d" entry=""
    local restore="$directory/${RR_RESTORE_GATE_DROPIN_NAME:-zzzz-rr-restore-gate.conf}"
    local firewall="$directory/${RR_FIREWALL_GATE_DROPIN_NAME:-zzzzz-rr-firewall-quarantine.conf}"
    local raw="" expected=""
    local -a entries=()
    if [ -e "$directory" ] || [ -L "$directory" ]; then
        [ -d "$directory" ] && [ ! -L "$directory" ] && \
            rr_health_unit_parent_is_safe "$directory" || return 1
        while IFS= read -r -d '' entry; do
            entries+=("$entry")
        done < <(find "$directory" -mindepth 1 -maxdepth 1 -print0 \
            2>/dev/null | sort -z)
        for entry in "${entries[@]}"; do
            case "$entry" in
                "$restore") rr_health_dropin_file_is_exact restore "$entry" || return 1 ;;
                "$firewall") rr_health_dropin_file_is_exact firewall "$entry" || return 1 ;;
                *) return 1 ;;
            esac
        done
    fi
    [ ! -e "$restore" ] && [ ! -L "$restore" ] || expected="$restore"
    if [ -e "$firewall" ] || [ -L "$firewall" ]; then
        [ -z "$expected" ] || expected+=" "
        expected+="$firewall"
    fi
    raw=$(systemctl show --property=DropInPaths --value \
        argo-rr-health.service 2>/dev/null) || return 1
    [ "$raw" = "$expected" ] || return 1
    printf '%s\n' "$expected"
}

rr_health_effective_namespace_is_exact() {
    local unit=argo-rr-health.service version_line="" systemd_version=""
    local property="" value="" root_ephemeral=no
    version_line=$(systemctl --version 2>/dev/null | head -n 1) || return 1
    [[ "$version_line" =~ ^systemd[[:space:]]+([0-9]+)([[:space:]]|$) ]] || \
        return 1
    systemd_version="${BASH_REMATCH[1]}"
    for property in User Group; do
        value=$(systemctl show --property="$property" --value "$unit" \
            2>/dev/null) || return 1
        case "$value" in ""|root) ;; *) return 1 ;; esac
    done
    value=$(systemctl show --property=WorkingDirectory --value "$unit" \
        2>/dev/null) || return 1
    case "$value" in ""|/) ;; *) return 1 ;; esac
    for property in DynamicUser PrivateUsers PrivateMounts PrivateNetwork; do
        value=$(systemctl show --property="$property" --value "$unit" \
            2>/dev/null) || return 1
        [ "$value" = no ] || return 1
    done
    for property in RootDirectory RootImage MountImages ExtensionImages \
        ExtensionDirectories TemporaryFileSystem BindPaths BindReadOnlyPaths \
        InaccessiblePaths JoinsNamespaceOf ReadOnlyPaths ReadWritePaths \
        Environment EnvironmentFiles PassEnvironment UnsetEnvironment PAMName; do
        value=$(systemctl show --property="$property" --value "$unit" \
            2>/dev/null) || return 1
        [ -z "$value" ] || return 1
    done
    value=$(systemctl show --property=SystemCallFilter --value "$unit" \
        2>/dev/null) || return 1
    [ "$value" = '~' ] || return 1
    if [ "$systemd_version" -ge 254 ]; then
        root_ephemeral=$(systemctl show --property=RootEphemeral --value "$unit" \
            2>/dev/null) || return 1
    fi
    [ "$root_ephemeral" = no ] || return 1
    value=$(systemctl show --property=ProtectHome --value "$unit" \
        2>/dev/null) || return 1
    [ "$value" = no ] || return 1
    value=$(systemctl show --property=ProtectSystem --value "$unit" \
        2>/dev/null) || return 1
    [ "$value" = no ] || return 1
}

rr_health_effective_conditions_are_exact() {
    local raw="" asserts=""
    raw=$(systemctl show --property=Conditions --value \
        argo-rr-health.service 2>/dev/null) || return 1
    asserts=$(systemctl show --property=Asserts --value \
        argo-rr-health.service 2>/dev/null) || return 1
    [ -z "$asserts" ] || return 1
    python3 - "$raw" <<'PY'
import re
import sys

raw = sys.argv[1]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if residual.strip() or len(matches) != 2:
    raise SystemExit(1)
paths = []
for match in matches:
    fields = {}
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(1)
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    path = fields.get("parameter", fields.get("path"))
    if path is None:
        raise SystemExit(1)
    paths.append(path)
if paths != ["/etc/argo_vmess.conf", "/usr/local/bin/rr"]:
    raise SystemExit(1)
PY
}

rr_health_timer_schedule_is_exact() {
    local raw="" calendar="" randomized="" timer_unit=""
    timer_unit=$(systemctl show --property=Unit --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ "$timer_unit" = argo-rr-health.service ] || return 1
    raw=$(systemctl show --property=TimersMonotonic --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    calendar=$(systemctl show --property=TimersCalendar --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ -z "$calendar" ] || return 1
    python3 - "$raw" <<'PY' || return 1
import re
import sys

raw = sys.argv[1]
matches = list(re.finditer(r"\{([^{}]*)\}", raw))
residual = raw
for match in reversed(matches):
    residual = residual[:match.start()] + residual[match.end():]
if residual.strip() or len(matches) != 2:
    raise SystemExit(1)
schedule = []
for match in matches:
    fields = {}
    for item in match.group(1).split(";"):
        item = item.strip()
        if not item or "=" not in item:
            continue
        key, value = item.split("=", 1)
        key = key.strip()
        if key in fields:
            raise SystemExit(1)
        fields[key] = value.strip()
    keys = [
        key for key in fields
        if key in {"OnBootSec", "OnBootUSec", "OnUnitActiveSec", "OnUnitActiveUSec",
                   "OnActiveSec", "OnActiveUSec", "OnStartupSec", "OnStartupUSec",
                   "OnUnitInactiveSec", "OnUnitInactiveUSec"}
    ]
    if len(keys) != 1:
        raise SystemExit(1)
    schedule.append((keys[0].replace("USec", "Sec"), fields[keys[0]]))
accepted_30 = {"30s", "30sec", "30000000us", "30000000"}
accepted_5m = {"5min", "5m", "300s", "300000000us", "300000000"}
if schedule[0][0] != "OnBootSec" or schedule[0][1] not in accepted_30:
    raise SystemExit(1)
if schedule[1][0] != "OnUnitActiveSec" or schedule[1][1] not in accepted_5m:
    raise SystemExit(1)
PY
    randomized=$(systemctl show --property=RandomizedDelayUSec --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    case "$randomized" in 15s|15sec|15000000us|15000000) ;; *) return 1 ;; esac
}

rr_health_restore_published_unit() {
    local target="$1" backup="$2" existed="$3" parent=""
    parent=$(dirname -- "$target") || return 1
    if [ "$existed" = true ]; then
        [ -f "$backup" ] && [ ! -L "$backup" ] || return 1
        mv -f -- "$backup" "$target" || return 1
    else
        rm -f -- "$target" || return 1
    fi
    sync -f "$parent"
}

write_health_monitor_units() {
    local service_file="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
    local timer_file="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
    local service_parent="" timer_parent="" service_tmp="" timer_tmp=""
    local service_backup="" timer_backup="" service_existed=false
    local timer_existed=false published_service=false published_timer=false
    local failed=false rollback_failed=false cleanup_path=""
    service_parent=$(dirname -- "$service_file") || return 1
    timer_parent=$(dirname -- "$timer_file") || return 1
    install -d -o 0 -g 0 -m 755 -- "$service_parent" "$timer_parent" || return 1
    rr_health_unit_parent_is_safe "$service_parent" || return 1
    rr_health_unit_parent_is_safe "$timer_parent" || return 1
    rr_health_unit_target_is_safe_or_absent "$service_file" || return 1
    rr_health_unit_target_is_safe_or_absent "$timer_file" || return 1
    service_tmp=$(mktemp "$service_parent/.argo-rr-health.service.XXXXXX") || return 1
    timer_tmp=$(mktemp "$timer_parent/.argo-rr-health.timer.XXXXXX") || {
        rm -f -- "$service_tmp"
        return 1
    }
    if ! rr_render_health_monitor_service > "$service_tmp" || \
       ! rr_render_health_monitor_timer > "$timer_tmp" || \
       ! chown 0:0 -- "$service_tmp" "$timer_tmp" || \
       ! chmod 644 -- "$service_tmp" "$timer_tmp" || \
       ! sync -f "$service_tmp" || ! sync -f "$timer_tmp"; then
        rm -f -- "$service_tmp" "$timer_tmp"
        return 1
    fi
    if [ -e "$service_file" ]; then
        service_existed=true
        service_backup=$(mktemp "$service_parent/.argo-rr-health.service.backup.XXXXXX") || \
            failed=true
        [ "$failed" = true ] || \
            cp -p -- "$service_file" "$service_backup" || failed=true
        [ "$failed" = true ] || sync -f "$service_backup" || failed=true
    fi
    if [ "$failed" = false ] && [ -e "$timer_file" ]; then
        timer_existed=true
        timer_backup=$(mktemp "$timer_parent/.argo-rr-health.timer.backup.XXXXXX") || \
            failed=true
        [ "$failed" = true ] || cp -p -- "$timer_file" "$timer_backup" || failed=true
        [ "$failed" = true ] || sync -f "$timer_backup" || failed=true
    fi
    if [ "$failed" = false ]; then
        mv -f -- "$service_tmp" "$service_file" || failed=true
        if [ "$failed" = false ]; then
            service_tmp=""
            published_service=true
            sync -f "$service_parent" || failed=true
        fi
    fi
    if [ "$failed" = false ]; then
        mv -f -- "$timer_tmp" "$timer_file" || failed=true
        if [ "$failed" = false ]; then
            timer_tmp=""
            published_timer=true
            sync -f "$timer_parent" || failed=true
        fi
    fi
    if [ "$failed" = false ]; then
        rr_health_monitor_unit_files_are_current || failed=true
    fi
    if [ "$failed" = true ]; then
        if [ "$published_timer" = true ]; then
            rr_health_restore_published_unit "$timer_file" "$timer_backup" \
                "$timer_existed" || rollback_failed=true
            timer_backup=""
        fi
        if [ "$published_service" = true ]; then
            rr_health_restore_published_unit "$service_file" "$service_backup" \
                "$service_existed" || rollback_failed=true
            service_backup=""
        fi
        for cleanup_path in "$service_tmp" "$timer_tmp" "$service_backup" \
            "$timer_backup"; do
            [ -n "$cleanup_path" ] || continue
            rm -f -- "$cleanup_path" || true
        done
        [ "$rollback_failed" = false ] || return 2
        return 1
    fi
    for cleanup_path in "$service_backup" "$timer_backup"; do
        [ -n "$cleanup_path" ] || continue
        rm -f -- "$cleanup_path" || return 1
    done
    sync -f "$service_parent" || return 1
    [ "$timer_parent" = "$service_parent" ] || sync -f "$timer_parent" || return 1
    return 0
}

rr_health_monitor_unit_definitions_are_current() {
    local service_file="${RR_HEALTH_SERVICE_FILE:-/etc/systemd/system/argo-rr-health.service}"
    local timer_file="${RR_HEALTH_TIMER_FILE:-/etc/systemd/system/argo-rr-health.timer}"
    local service_load="" timer_load="" service_fragment="" timer_fragment=""
    local timer_dropins="" exec_start="" exec_start_pre="" exec_reload=""
    local exec_condition="" expected_dropins="" marker=""
    local property="" value=""
    local -a condition_spec=()
    rr_health_monitor_unit_files_are_current || return 1
    service_load=$(systemctl show --property=LoadState --value \
        argo-rr-health.service 2>/dev/null) || return 1
    timer_load=$(systemctl show --property=LoadState --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ "$service_load" = loaded ] && [ "$timer_load" = loaded ] || return 1
    service_fragment=$(systemctl show --property=FragmentPath --value \
        argo-rr-health.service 2>/dev/null) || return 1
    timer_fragment=$(systemctl show --property=FragmentPath --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ "$service_fragment" = "$service_file" ] && \
        [ "$timer_fragment" = "$timer_file" ] || return 1
    timer_dropins=$(systemctl show --property=DropInPaths --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ -z "$timer_dropins" ] || return 1
    expected_dropins=$(rr_health_effective_dropins_are_exact) || return 1
    exec_start=$(systemctl show --property=ExecStart --value \
        argo-rr-health.service 2>/dev/null) || return 1
    rr_health_effective_exec_vector_is_exact "$exec_start" /usr/local/bin/rr \
        '/usr/local/bin/rr --health-check' || return 1
    exec_start_pre=$(systemctl show --property=ExecStartPre --value \
        argo-rr-health.service 2>/dev/null) || return 1
    exec_reload=$(systemctl show --property=ExecReload --value \
        argo-rr-health.service 2>/dev/null) || return 1
    rr_health_effective_exec_vector_is_exact "$exec_start_pre" || return 1
    rr_health_effective_exec_vector_is_exact "$exec_reload" || return 1
    for property in ExecStartPost ExecStop ExecStopPost; do
        value=$(systemctl show --property="$property" --value \
            argo-rr-health.service 2>/dev/null) || return 1
        rr_health_effective_exec_vector_is_exact "$value" || return 1
    done
    if [[ " $expected_dropins " == \
          *"/${RR_RESTORE_GATE_DROPIN_NAME:-zzzz-rr-restore-gate.conf} "* ]]; then
        condition_spec+=(/bin/sh \
            '/bin/sh -c [ ! -e /var/lib/rr-backup/active ] && [ ! -L /var/lib/rr-backup/active ] || exec /usr/bin/timeout 15s /usr/local/bin/rr --restore-service-gate')
    fi
    if [[ " $expected_dropins " == \
          *"/${RR_FIREWALL_GATE_DROPIN_NAME:-zzzzz-rr-firewall-quarantine.conf} "* ]]; then
        marker="${RR_FIREWALL_QUARANTINE_FILE:-${RR_FIREWALL_QUARANTINE_DIR:-/var/lib/rr-vps}/firewall-quarantine}"
        condition_spec+=(/usr/bin/test "/usr/bin/test ! -e $marker" \
            /usr/bin/test "/usr/bin/test ! -L $marker")
    fi
    exec_condition=$(systemctl show --property=ExecCondition --value \
        argo-rr-health.service 2>/dev/null) || return 1
    rr_health_effective_exec_vector_is_exact "$exec_condition" \
        "${condition_spec[@]}" || return 1
    rr_health_effective_conditions_are_exact || return 1
    rr_health_effective_namespace_is_exact || return 1
    value=$(systemctl show --property=Conditions --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ -z "$value" ] || return 1
    value=$(systemctl show --property=Asserts --value \
        argo-rr-health.timer 2>/dev/null) || return 1
    [ -z "$value" ] || return 1
    rr_health_timer_schedule_is_exact
}

rr_health_monitor_units_are_current() {
    rr_health_monitor_unit_definitions_are_current || return 1
    systemctl is-enabled --quiet argo-rr-health.timer || return 1
    systemctl is-active --quiet argo-rr-health.timer
}

setup_health_monitor() {
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝启用健康重启。${RESET}" >&2
        return 1
    fi
    write_health_monitor_units || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    rr_health_monitor_unit_definitions_are_current || return 1
    systemctl enable --now argo-rr-health.timer >/dev/null 2>&1 || return 1
    rr_health_monitor_units_are_current
}

# ==========================================
# 生成证书与 Reality 密钥 (一次性)
# ==========================================
# T9：TLS 证书文件缺失时自动重建自签证书，保持节点可起（绝不静默降级）。
# 有节点协议启用且 cert.pem/private.key 任一缺失/为空时调用 generate_certs_and_keys
# 重建（幂等：文件完整时零开销直接返回）。重建失败则返回 1，让调用方拒绝生成
# 引用缺失证书的无效配置/订阅。
ensure_tls_certificates() {
    if rr_certificate_private_key_pair_matches \
        /etc/sing-box/cert.pem /etc/sing-box/private.key && \
       [ ! -e "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" ] && \
       [ ! -L "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" ]; then
        return 0
    fi
    any_node_protocol_enabled || return 0
    echo -e "${YELLOW}[警告] 检测到 TLS 证书文件缺失，正在自动重建自签证书（客户端订阅的 pinSHA256 会变化，需重新获取订阅）。${RESET}" >&2
    generate_certs_and_keys >/dev/null 2>&1 || return 1
    return 0
}

generate_certs_and_keys() {
    load_config_with_defaults || return 1
    install -d -o 0 -g 0 -m 700 /etc/sing-box || return 1

    if rr_certificate_private_key_pair_matches \
        /etc/sing-box/cert.pem /etc/sing-box/private.key; then
        if [ -e "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" ] || \
           [ -L "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" ]; then
            rr_certificate_pair_pending_clear \
                "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" || return 1
        fi
    fi

    if ! rr_certificate_private_key_pair_matches \
        /etc/sing-box/cert.pem /etc/sing-box/private.key; then
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
        chmod 600 "$cert_tmp_dir/private.key" "$cert_tmp_dir/cert.pem" || {
            rm -rf "$cert_tmp_dir"
            return 1
        }
        rr_publish_certificate_pair \
            "$cert_tmp_dir/cert.pem" "$cert_tmp_dir/private.key" \
            /etc/sing-box/cert.pem /etc/sing-box/private.key \
            "$RR_SINGBOX_TLS_PAIR_PENDING_FILE" \
            rr_certificate_private_key_pair_matches || {
                rm -rf "$cert_tmp_dir"
                return 1
            }
        rm -rf "$cert_tmp_dir"
        echo -e "${GREEN}[成功] 自签证书已生成 (SHA256: $CERT_SHA256)${RESET}"
    fi

    # Always derive the published pin from the certificate currently served.
    # This repairs empty/stale hashes without rotating the certificate.
    if ! rr_certificate_private_key_pair_matches \
        /etc/sing-box/cert.pem /etc/sing-box/private.key; then
        echo -e "${RED}[失败] TLS 证书或私钥损坏，拒绝生成无效节点。${RESET}"
        return 1
    fi
    CERT_SHA256=$(openssl x509 -in /etc/sing-box/cert.pem -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [[ ! "$CERT_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
        echo -e "${RED}[失败] 无法计算 TLS 证书 SHA256，拒绝生成无效节点。${RESET}"
        return 1
    fi
    safe_sed "CERT_SHA256" "$CERT_SHA256" || return 1

    local reality_material_valid=false derived_existing_public=""
    if [[ "$PRIVATE_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
       [[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
       [[ "$SHORT_ID" =~ ^[0-9a-fA-F]{8}$ ]]; then
        derived_existing_public=$(rr_reality_public_from_private "$PRIVATE_KEY" 2>/dev/null) || true
        [ "$derived_existing_public" = "$PUBLIC_KEY" ] && reality_material_valid=true
    fi
    if [ "$reality_material_valid" != true ]; then
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
rr_reality_public_from_private() {
    local private_key="$1" temporary="" private_der="" public_der="" result=""
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    temporary=$(mktemp -d /tmp/rr-reality-derive.XXXXXX) || return 1
    private_der="$temporary/private.der"
    public_der="$temporary/public.der"
    if ! RR_REALITY_PRIVATE_INPUT="$private_key" python3 - "$private_der" <<'PY'
import base64
import os
import pathlib

raw = os.environ.get("RR_REALITY_PRIVATE_INPUT", "")
try:
    decoded = base64.urlsafe_b64decode(raw + "=")
except Exception:
    raise SystemExit(1)
if len(decoded) != 32:
    raise SystemExit(1)
path = pathlib.Path(__import__("sys").argv[1])
path.write_bytes(bytes.fromhex("302e020100300506032b656e04220420") + decoded)
PY
    then
        rm -rf -- "$temporary"
        return 1
    fi
    chmod 600 "$private_der" || { rm -rf -- "$temporary"; return 1; }
    openssl pkey -inform DER -in "$private_der" -pubout -outform DER \
        -out "$public_der" >/dev/null 2>&1 || {
            rm -rf -- "$temporary"
            return 1
        }
    result=$(python3 - "$public_der" <<'PY'
import base64
import pathlib
import sys

value = pathlib.Path(sys.argv[1]).read_bytes()
prefix = bytes.fromhex("302a300506032b656e032100")
if len(value) != len(prefix) + 32 or not value.startswith(prefix):
    raise SystemExit(1)
print(base64.urlsafe_b64encode(value[len(prefix):]).decode("ascii").rstrip("="))
PY
    ) || { rm -rf -- "$temporary"; return 1; }
    rm -rf -- "$temporary"
    [[ "$result" =~ ^[A-Za-z0-9_-]{43}$ ]] || return 1
    printf '%s\n' "$result"
}

rr_publish_reality_key_triplet() {
    local private_key="$1" public_key="$2" short_id="$3"
    local derived="" config_dir="" temporary="" encoded_private=""
    local encoded_public="" encoded_short=""
    [[ "$private_key" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
        [[ "$public_key" =~ ^[A-Za-z0-9_-]{43}$ ]] && \
        [[ "$short_id" =~ ^[0-9a-fA-F]{8}$ ]] || return 1
    derived=$(rr_reality_public_from_private "$private_key") || return 1
    [ "$derived" = "$public_key" ] || return 1
    [ -f "$CONFIG_FILE" ] && [ ! -L "$CONFIG_FILE" ] || return 1
    config_dir=$(dirname -- "$CONFIG_FILE") || return 1
    [ -d "$config_dir" ] && [ ! -L "$config_dir" ] || return 1
    temporary=$(mktemp "$config_dir/.rr-reality-triplet.XXXXXX") || return 1
    printf -v encoded_private '%q' "$private_key"
    printf -v encoded_public '%q' "$public_key"
    printf -v encoded_short '%q' "$short_id"
    if ! RR_REALITY_PRIVATE_ENCODED="$encoded_private" \
         RR_REALITY_PUBLIC_ENCODED="$encoded_public" \
         RR_REALITY_SHORT_ENCODED="$encoded_short" \
         python3 - "$CONFIG_FILE" "$temporary" <<'PY'
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
values = {
    "PRIVATE_KEY": os.environ["RR_REALITY_PRIVATE_ENCODED"],
    "PUBLIC_KEY": os.environ["RR_REALITY_PUBLIC_ENCODED"],
    "SHORT_ID": os.environ["RR_REALITY_SHORT_ENCODED"],
}
counts = {key: 0 for key in values}
output = []
for raw in source.read_text(encoding="utf-8").splitlines():
    key = raw.split("=", 1)[0] if "=" in raw else ""
    if key in values:
        counts[key] += 1
        if counts[key] > 1:
            raise SystemExit("duplicate Reality setting")
        output.append(f"{key}={values[key]}")
    else:
        output.append(raw)
for key in ("PRIVATE_KEY", "PUBLIC_KEY", "SHORT_ID"):
    if counts[key] == 0:
        output.append(f"{key}={values[key]}")
target.write_text("\n".join(output) + "\n", encoding="utf-8")
PY
    then
        rm -f -- "$temporary"
        return 1
    fi
    chown 0:0 "$temporary" && chmod 600 "$temporary" && \
        sync -f "$temporary" || { rm -f -- "$temporary"; return 1; }
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_REALITY_FAIL_BEFORE_COMMIT:-0}" = 1 ]; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ "${RR_TEST_FAULTS:-0}" = 1 ] && \
       [ "${RR_TEST_REALITY_CRASH_BEFORE_COMMIT:-0}" = 1 ]; then
        kill -KILL "$$"
    fi
    mv -f -- "$temporary" "$CONFIG_FILE" && sync -f "$config_dir" || {
        rm -f -- "$temporary"
        return 1
    }
    PRIVATE_KEY="$private_key"
    PUBLIC_KEY="$public_key"
    SHORT_ID="$short_id"
    derived=$(rr_reality_public_from_private "$PRIVATE_KEY") || return 1
    [ "$derived" = "$PUBLIC_KEY" ]
}

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
    local derived_public=""
    derived_public=$(rr_reality_public_from_private "$PRIVATE_KEY") || return 1
    [ "$derived_public" = "$PUBLIC_KEY" ] || {
        echo -e "${RED}Reality 密钥生成结果不匹配，原配置未改动${RESET}"
        return 1
    }
    rr_publish_reality_key_triplet \
        "$PRIVATE_KEY" "$PUBLIC_KEY" "$SHORT_ID" || return 1
    echo -e "${GREEN}[成功] Reality 密钥已重新生成${RESET}"
    return 0
}

validate_subscription_crypto_material() {
    if [ "${VL_ENABLED:-false}" = "true" ]; then
        if [[ ! "${PUBLIC_KEY:-}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
           [[ ! "${PRIVATE_KEY:-}" =~ ^[A-Za-z0-9_-]{43}$ ]] || \
           [[ ! "${SHORT_ID:-}" =~ ^[0-9a-fA-F]{8}$ ]] || \
           [ "$(rr_reality_public_from_private "$PRIVATE_KEY" 2>/dev/null)" != \
             "$PUBLIC_KEY" ]; then
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
    SINGBOX_CONFIG_PUBLISHED_SHA256=""

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

    if [ -e /etc/sing-box/config.json ] || \
       [ -L /etc/sing-box/config.json ]; then
        rr_publish_regular_file_atomic /etc/sing-box/config.json \
            /etc/sing-box/config.json.bak 600 || {
            rm -f -- "$tmp_config"
            return 1
        }
    fi
    if ! rr_publish_regular_file_atomic "$tmp_config" \
        /etc/sing-box/config.json 600; then
        rm -f -- "$tmp_config"
        return 1
    fi
    rm -f -- "$tmp_config" || return 1
    SINGBOX_CONFIG_PUBLISHED_SHA256=$(sha256sum -- \
        /etc/sing-box/config.json 2>/dev/null | awk '{print $1}') || return 1
    [[ "$SINGBOX_CONFIG_PUBLISHED_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    SINGBOX_CONFIG_CHANGED=true
}

ensure_singbox_service_guards() {
    local unit_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    [ ! -e "$unit_file" ] && [ ! -L "$unit_file" ] && return 0
    [ -f "$unit_file" ] && [ ! -L "$unit_file" ] || return 1
    # The unit is entirely RR-managed.  Re-emitting one exact fragment avoids
    # a sequence of in-place sed edits that can be interrupted after only some
    # guards have landed.  Effective manager properties are re-proved after
    # daemon-reload, so an overriding drop-in cannot hide a partial repair.
    write_singbox_systemd_unit || return 1
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    rr_singbox_service_guards_are_effective
}

stop_singbox_instances() {
    # 先停止 systemd 单元，避免 Restart=on-failure 在清理旧进程时再次拉起。
    if [ -f /etc/systemd/system/sing-box.service ] && \
       rr_singbox_service_guards_are_effective; then
        rr_singbox_service_guards_are_effective || return 1
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

rr_singbox_service_generation() {
    local main_pid="" invocation_id=""
    main_pid=$(systemctl show --property=MainPID --value \
        sing-box.service 2>/dev/null) || return 1
    invocation_id=$(systemctl show --property=InvocationID --value \
        sing-box.service 2>/dev/null) || return 1
    [[ "$main_pid" =~ ^[0-9]+$ ]] || return 1
    case "$invocation_id" in
        "") invocation_id=- ;;
        *) [[ "$invocation_id" =~ ^[0-9a-fA-F]{32}$ ]] || return 1 ;;
    esac
    printf '%s %s\n' "$main_pid" "$invocation_id"
}

rr_singbox_wait_for_new_generation() {
    local previous_pid="$1" previous_invocation="$2"
    local generation="" current_pid="" current_invocation="" retry=0
    while [ "$retry" -lt 20 ]; do
        if systemctl is-active --quiet sing-box.service; then
            generation=$(rr_singbox_service_generation) || generation=""
            if [ -n "$generation" ]; then
                read -r current_pid current_invocation <<<"$generation"
                if [ "$current_pid" -gt 1 ] 2>/dev/null && \
                   [ "$current_pid" != "$previous_pid" ] && \
                   [ "$current_invocation" != - ] && \
                   [ "$current_invocation" != 00000000000000000000000000000000 ] && \
                   [ "$current_invocation" != "$previous_invocation" ]; then
                    return 0
                fi
            fi
        fi
        sleep 0.25
        retry=$((retry + 1))
    done
    return 1
}

restart_singbox() {
    local unit_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝重启 Sing-box。${RESET}" >&2
        return 1
    fi
    ensure_singbox_service_guards || return 1

    if ! "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        echo -e "${RED}[警告] Sing-box 配置校验失败，未重启现有节点。${RESET}"
        return 1
    fi

    if [ -f "$unit_file" ]; then
        local was_active=false
        local main_pid="" previous_invocation="" generation=""
        local pid=""
        systemctl is-active --quiet sing-box && was_active=true
        generation=$(rr_singbox_service_generation) || return 1
        read -r main_pid previous_invocation <<<"$generation"
        if [ "$was_active" = true ]; then
            [ "$main_pid" -gt 1 ] 2>/dev/null && \
                [ "$previous_invocation" != - ] && \
                [ "$previous_invocation" != 00000000000000000000000000000000 ] || \
                return 1
        fi

        # 清理旧版菜单遗留的孤立实例，但不触碰正在承载流量的 systemd 主进程。
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            if [ "$pid" != "$main_pid" ]; then
                kill -TERM "$pid" 2>/dev/null || true
            fi
        done < <(managed_singbox_pids)

        rr_singbox_service_guards_are_effective || return 1
        systemctl reset-failed sing-box >/dev/null 2>&1 || true
        if [ "$was_active" = true ]; then
            rr_singbox_service_guards_are_effective || return 1
            systemctl restart sing-box >/dev/null 2>&1 || {
                echo -e "${RED}[警告] systemd 拒绝重启 Sing-box；旧实例状态不代表新配置已加载。${RESET}" >&2
                return 1
            }
        else
            stop_singbox_instances >/dev/null 2>&1 || return 1
            rr_singbox_service_guards_are_effective || return 1
            systemctl start sing-box >/dev/null 2>&1 || {
                echo -e "${RED}[警告] systemd 无法启动 Sing-box。${RESET}" >&2
                return 1
            }
        fi
        if ! rr_singbox_wait_for_new_generation "$main_pid" "$previous_invocation"; then
            echo -e "${RED}[警告] Sing-box 未进入新的 systemd invocation；拒绝把旧 active 状态误报为成功。${RESET}" >&2
            return 1
        fi
    else
        stop_singbox_instances >/dev/null 2>&1 || true
        (
            rr_close_inherited_firewall_lock_fd || exit 1
            exec nohup "$SINGBOX_BIN" run -c /etc/sing-box/config.json
        ) > /dev/null 2>&1 &
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
    local unit_file="${RR_SINGBOX_SERVICE_FILE:-/etc/systemd/system/sing-box.service}"
    local generation="" previous_pid="" previous_invocation=""
    if rr_firewall_fail_closed_quarantine_active; then
        echo -e "${RED}[安全拒绝] 防火墙隔离尚未经精确修复，拒绝重启 Sing-box。${RESET}" >&2
        return 1
    fi
    ensure_singbox_service_guards || return 1
    if [ ! -f "$unit_file" ]; then
        echo -e "${YELLOW}[警告] 未检测到 systemd 单元，跳过服务重启；手动运行的 sing-box 进程不会被触碰。${RESET}"
        return 0
    fi
    generation=$(rr_singbox_service_generation) || return 1
    read -r previous_pid previous_invocation <<<"$generation"
    rr_singbox_service_guards_are_effective || return 1
    systemctl restart sing-box >/dev/null 2>&1 || return 1
    rr_singbox_wait_for_new_generation "$previous_pid" "$previous_invocation"
}

rr_restore_transaction_file_atomic() {
    local snapshot="${1:-}" target="${2:-}" directory="" base=""
    local snapshot_metadata="" target_metadata="" temporary_metadata=""
    local snapshot_directory="" snapshot_directory_metadata=""
    local directory_metadata="" owner="" group="" mode="" links=""
    local directory_owner="" directory_group="" directory_mode=""
    local temporary="" fault="" directory_sync_failed=false

    [ -n "$snapshot" ] && [ -n "$target" ] || return 1
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || return 1
    snapshot_metadata=$(stat -c '%u:%g:%a:%h' -- "$snapshot" 2>/dev/null) || \
        return 1
    IFS=: read -r owner group mode links <<<"$snapshot_metadata"
    [ "$owner:$group:$links" = 0:0:1 ] && [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    snapshot_directory=$(dirname -- "$snapshot") || return 1
    [ -d "$snapshot_directory" ] && [ ! -L "$snapshot_directory" ] || return 1
    snapshot_directory_metadata=$(
        stat -c '%u:%g:%a' -- "$snapshot_directory" 2>/dev/null
    ) || return 1
    IFS=: read -r directory_owner directory_group directory_mode \
        <<<"$snapshot_directory_metadata"
    [ "$directory_owner:$directory_group" = 0:0 ] && \
        [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$directory_mode & 8#022)) -eq 0 ] || return 1

    directory=$(dirname -- "$target") || return 1
    base=$(basename -- "$target") || return 1
    [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
    directory_metadata=$(stat -c '%u:%g:%a' -- "$directory" 2>/dev/null) || \
        return 1
    IFS=: read -r directory_owner directory_group directory_mode \
        <<<"$directory_metadata"
    [ "$directory_owner:$directory_group" = 0:0 ] && \
        [[ "$directory_mode" =~ ^[0-7]{3,4}$ ]] && \
        [ $((8#$directory_mode & 8#022)) -eq 0 ] || return 1

    if [ -e "$target" ] || [ -L "$target" ]; then
        [ -f "$target" ] && [ ! -L "$target" ] || return 1
        target_metadata=$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null) || \
            return 1
        IFS=: read -r owner group mode links <<<"$target_metadata"
        [ "$owner:$group:$links" = 0:0:1 ] && \
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] && \
            [ $((8#$mode & 8#022)) -eq 0 ] || return 1
    fi

    if [ "${RR_TEST_FAULTS:-0}" = 1 ]; then
        fault="${RR_TEST_CONFIG_RESTORE_FAULT:-}"
        case "$fault" in
            ""|copy|file-fsync|rename|dir-fsync) ;;
            *) return 1 ;;
        esac
    fi

    temporary=$(mktemp "$directory/.${base}.rr-restore.XXXXXX") || return 1
    if [ "$fault" = copy ] || ! cp -p -- "$snapshot" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    temporary_metadata=$(stat -c '%u:%g:%a:%h' -- "$temporary" 2>/dev/null) || {
        rm -f -- "$temporary"
        return 1
    }
    if [ "$temporary_metadata" != "$snapshot_metadata" ] || \
       ! cmp -s -- "$snapshot" "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ "$fault" = file-fsync ] || ! sync -f "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if [ "$fault" = rename ] || ! mv -f -- "$temporary" "$target"; then
        rm -f -- "$temporary"
        return 1
    fi

    if [ "$fault" = dir-fsync ] || ! sync -f "$directory"; then
        directory_sync_failed=true
    fi
    [ -f "$target" ] && [ ! -L "$target" ] && \
        [ "$(stat -c '%u:%g:%a:%h' -- "$target" 2>/dev/null)" = \
            "$snapshot_metadata" ] && cmp -s -- "$snapshot" "$target" || return 1
    [ "$directory_sync_failed" = false ]
}

restore_config_transaction_snapshot() {
    local tx_dir="$1"
    local old_uuid="$2"
    local was_running="$3"
    local restart_required="$4"
    local restore_failed=false

    ensure_subscription_root || return 1

    rr_restore_transaction_file_atomic \
        "$tx_dir/argo_vmess.conf" "$CONFIG_FILE" || return 1
    if [ -f "$tx_dir/had_runtime_config" ]; then
        rr_restore_transaction_file_atomic \
            "$tx_dir/config.json" /etc/sing-box/config.json || return 1
    else
        rm -f /etc/sing-box/config.json
    fi
    if [ -f "$tx_dir/had_worker" ]; then
        rr_restore_transaction_file_atomic \
            "$tx_dir/auto_update_sub.py" /usr/local/bin/auto_update_sub.py || return 1
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
            if rr_restore_transaction_file_atomic \
                "$tx_dir/argo_vmess.conf" "$CONFIG_FILE"; then
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
    local was_running=false hop_label="" hop_enabled=false hop_port=""
    local hop_specs="" hop_status=0
    managed_singbox_running && was_running=true

    if ! build_singbox_config; then
        return 1
    fi
    if [ "$SINGBOX_CONFIG_CHANGED" = true ] && [ "$was_running" = true ]; then
        restart_singbox || return 1
    fi
    for hop_label in HY2 TU5; do
        case "$hop_label" in
            HY2)
                hop_enabled="${HY2_ENABLED:-false}"
                hop_port="${HY2_PORT:-}"
                hop_specs="${HY2_HOP_PORTS:-}"
                ;;
            TU5)
                hop_enabled="${TU5_ENABLED:-false}"
                hop_port="${TU5_PORT:-}"
                hop_specs="${TU5_HOP_PORTS:-}"
                ;;
        esac
        [ "$hop_enabled" = true ] && [ -n "$hop_specs" ] || continue
        if [ "${RR_UPDATE_TRANSACTION:-0}" = 1 ]; then
            rr_validate_hop_rules "$hop_label" "$hop_port" "$hop_specs" \
                >/dev/null 2>&1 || {
                echo -e "${RED}[错误] ${hop_label} 跳跃规则只读检查失败，热更新未修改防火墙。${RESET}" >&2
                return 1
            }
        else
            hop_status=0
            install_hop_rules "$hop_label" "$hop_port" "$hop_specs" \
                >/dev/null 2>&1 || hop_status=$?
            case "$hop_status" in
                0) ;;
                1)
                    echo -e "${RED}[错误] ${hop_label} 跳跃规则无法应用，已证明防火墙保持原态。${RESET}" >&2
                    return 1
                    ;;
                2)
                    echo -e "${RED}[严重] ${hop_label} 跳跃规则补偿不完整，Sing-box 已停止并验证 inactive。${RESET}" >&2
                    return 2
                    ;;
                3|*)
                    echo -e "${RED}[紧急] ${hop_label} 跳跃规则补偿不完整，且无法验证 Sing-box 已停止。${RESET}" >&2
                    return 3
                    ;;
            esac
        fi
    done
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
    rr_firewall_hop_program_first_match_is_safe "$label" "$main_port" \
        "$spec_list" post
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
    local had_enabled=false firewall_status=0

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
    open_protocol_firewall 80 tcp || firewall_status=$?
    [ "$firewall_status" -eq 0 ] || return "$firewall_status"
    return 0
}

naive_certificate_pair_valid() {
    local certificate="$1" private_key="$2" domain="$3"
    [ -s "$certificate" ] && [ -s "$private_key" ] || return 1
    certificate_identity_matches "$certificate" "$domain" || return 1
    openssl x509 -in "$certificate" -noout -checkend 604800 >/dev/null 2>&1 || return 1
    certificate_private_key_matches "$certificate" "$private_key" || return 1
    certificate_chain_is_trusted "$certificate"
}

sync_naive_certificate_pair() {
    local source_dir="$1" target_dir="$2" domain="$3" cert_tmp="" key_tmp=""
    local marker=""
    naive_certificate_pair_valid "$source_dir/fullchain.pem" "$source_dir/privkey.pem" "$domain" || return 1
    install -d -m 700 "$target_dir" || return 1
    cert_tmp=$(mktemp "$target_dir/.fullchain.XXXXXX") || return 1
    key_tmp=$(mktemp "$target_dir/.privkey.XXXXXX") || { rm -f "$cert_tmp"; return 1; }
    install -m 600 "$source_dir/fullchain.pem" "$cert_tmp" && \
        install -m 600 "$source_dir/privkey.pem" "$key_tmp" || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    # Certbot atomically rotates four live symlinks, but the two reads above
    # are necessarily separate.  Validate the captured temporary pair before
    # either destination name is replaced, so a cross-generation read cannot
    # publish a mismatched pair.  Each final rename is atomic and no daemon is
    # reloaded until both names have committed.
    naive_certificate_pair_valid "$cert_tmp" "$key_tmp" "$domain" || {
        rm -f "$cert_tmp" "$key_tmp"
        return 1
    }
    marker="$target_dir/.pair-pending"
    rr_publish_certificate_pair "$cert_tmp" "$key_tmp" \
        "$target_dir/fullchain.pem" "$target_dir/privkey.pem" "$marker" \
        naive_certificate_pair_valid "$domain" || {
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
        rr_certbot_webroot_lineage_is_renewable "$naive_domain" || {
            echo -e "${RED}[失败] 热更新候选要求目标机已有结构完整的生产 Webroot lineage。${RESET}" >&2
            return 1
        }
        rr_certbot_renewal_runtime_is_ready "$naive_domain" || {
            echo -e "${RED}[失败] 热更新候选要求 Certbot 定时器及该域名的本机 ACME HTTP 路由就绪。${RESET}" >&2
            return 1
        }
        install -d -m 700 "$naive_cert_dir" || return 1
        sync_naive_certificate_pair "${le_live_root}/${naive_domain}" \
            "$naive_cert_dir" "$naive_domain" || return 1
        if [ "${RR_PORTABLE_RESTORE:-0}" = 1 ]; then
            rr_certificate_deploy_hook_is_current || {
                echo -e "${RED}[失败] Portable restore 要求目标机已有可信且当前版本的证书续签钩子。${RESET}" >&2
                return 1
            }
        else
            deploy_naive_cert_hook || return 1
        fi
        return 0
    fi
    install -d -m 700 "$naive_cert_dir" || return 1

    # Webroot 模式不仅需要目录，还必须在签发及续签时有真实 HTTP 服务。
    # 首装阶段 Sing-box/Nexus 尚未启动，因此先安全配置 Nginx 并放行 80。
    prepare_naive_acme_webroot "$naive_domain" || return 1

    # 仅复用 SAN、有效期和私钥都匹配的在线 lineage。Portable restore
    # 带来的叶子证书没有目标机续签配置，必须在这里重新建立 lineage。
    if naive_certificate_pair_valid "${le_live_root}/${naive_domain}/fullchain.pem" \
        "${le_live_root}/${naive_domain}/privkey.pem" "$naive_domain" && \
       rr_certbot_webroot_lineage_is_renewable "$naive_domain"; then
        rr_enable_certbot_renewal_runtime "$naive_domain" || {
            echo -e "${RED}[失败] certbot.timer 或该域名的本机 ACME HTTP 路由未就绪；未强制续签现有有效证书。${RESET}" >&2
            return 1
        }
        sync_naive_certificate_pair "${le_live_root}/${naive_domain}" "$naive_cert_dir" "$naive_domain" || return 1
        deploy_naive_cert_hook || return 1
        return 0
    fi

    # 6.6.15：root umask 077（DMIT 模板等）会让目录 700/文件 600，
    # nginx(www-data) 读不了挑战文件 → LE 403。显式 chmod + umask 022。
    echo -e "${YELLOW}正在为 ${naive_domain} 申请 Let’s Encrypt 真证书……${RESET}"
    if ! (umask 022 && certbot certonly --webroot -w "$webroot" -d "$naive_domain" \
        --cert-name "$naive_domain" \
        -m "$le_email" --agree-tos --non-interactive --quiet --force-renewal 2>/dev/null); then
        echo -e "${RED}[失败] 证书申请失败：请确认 ${naive_domain} 已解析到本机公网 IP、80 端口可访问；如日志提示邮箱被拒（invalid email），请在 /etc/argo_vmess.conf 添加 LE_EMAIL=你的邮箱 后重试。${RESET}" >&2
        return 1
    fi
    naive_certificate_pair_valid "${le_live_root}/${naive_domain}/fullchain.pem" \
        "${le_live_root}/${naive_domain}/privkey.pem" "$naive_domain" || return 1
    rr_certbot_webroot_lineage_is_renewable "$naive_domain" || return 1
    rr_enable_certbot_renewal_runtime "$naive_domain" || {
        echo -e "${RED}[失败] certbot.timer 或该域名的本机 ACME HTTP 路由未就绪，拒绝把证书报告为可自动续签。${RESET}" >&2
        return 1
    }
    sync_naive_certificate_pair "${le_live_root}/${naive_domain}" "$naive_cert_dir" "$naive_domain" || return 1
    deploy_naive_cert_hook || return 1
    echo -e "${GREEN}[成功] NaiveProxy Let’s Encrypt 真证书已就绪（/etc/rr-naive/）。${RESET}"
    return 0
}

rr_certificate_deploy_hook_is_current() {
    # Portable restore 的候选迁移只能读取全局 ACME 状态。严格确认部署钩子
    # 已由目标机预先安装，不能在事务中创建、替换或清理任何全局文件。
    local hook_dir="${RR_LE_RENEW_HOOK_DIR:-/etc/letsencrypt/renewal-hooks/deploy}"
    local hook_source="${RR_RUNTIME_DIR:-/usr/local/lib/rr}/scripts/naive-cert-hook.sh"
    local hook_file="${hook_dir}/rr-certificates.sh"
    local legacy_hook="${hook_dir}/rr-naive-cert.sh"

    [ -f "$hook_source" ] && [ ! -L "$hook_source" ] && [ -s "$hook_source" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$hook_source" 2>/dev/null)" = 0:0:755:1 ] || return 1
    bash -n "$hook_source" >/dev/null 2>&1 || return 1
    [ -d "$hook_dir" ] && [ ! -L "$hook_dir" ] || return 1
    [ "$(stat -c '%u:%g:%a' -- "$hook_dir" 2>/dev/null)" = 0:0:700 ] || return 1
    [ -f "$hook_file" ] && [ ! -L "$hook_file" ] && [ -s "$hook_file" ] || return 1
    [ "$(stat -c '%u:%g:%a:%h' -- "$hook_file" 2>/dev/null)" = 0:0:700:1 ] || return 1
    bash -n "$hook_file" >/dev/null 2>&1 || return 1
    cmp -s -- "$hook_source" "$hook_file" || return 1
    [ ! -e "$legacy_hook" ] && [ ! -L "$legacy_hook" ]
}

naive_cert_hook_is_current() {
    # Compatibility wrapper for callers/tests introduced before the shared
    # NaiveProxy + subscription TLS hook gained its generic validator name.
    rr_certificate_deploy_hook_is_current
}

deploy_naive_cert_hook() {
    # certbot renew 后的通用 deploy 钩子：同步 NaiveProxy 证书，并在
    # 同一 lineage 也承载订阅 HTTPS 时安全刷新订阅进程。
    local naive_domain="${1:-$NAIVE_DOMAIN}"
    [ -n "$naive_domain" ] || return 0
    rr_install_certificate_deploy_hook
}
