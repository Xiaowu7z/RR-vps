# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
# 端口检测辅助函数
# ==========================================
gen_random_port() {
    local p
    local proto_type="${1:-any}"
    load_config_with_defaults || return 1
    while true; do
        p=$((RANDOM % 39001 + 10000))
        if [ "$p" != "$PORT" ] && [ "$p" != "$SUB_PORT" ] && [ "$p" != "$VL_PORT" ] && [ "$p" != "$HY2_PORT" ] && [ "$p" != "$TU5_PORT" ] && [ "$p" != "$AN_PORT" ]; then
            case "$proto_type" in
                tcp) tcp_port_in_use "$p" && continue ;;
                udp) udp_port_in_use "$p" && continue ;;
                *) { tcp_port_in_use "$p" || udp_port_in_use "$p"; } && continue ;;
            esac
            echo "$p"
            return
        fi
    done
}

validate_node_port() {
    local new_port="$1"
    local proto_type="$2"
    local owner="$3"
    local current_port="${4:-0}"
    load_config_with_defaults || return 1

    if ! is_valid_port "$new_port"; then
        echo -e "${RED}[拒绝变更] 节点端口必须是 1-65535 的整数。${RESET}"
        return 1
    fi
    [ "$new_port" = "$current_port" ] && return 0

    local pair=""
    local key=""
    local value=""
    if [ "$proto_type" = "tcp" ]; then
        # NAIVE-SUPPORT：naive 端口也参与 TCP 冲突检测
        for pair in "PORT:$PORT" "SUB_PORT:$SUB_PORT" "VL_PORT:$VL_PORT" "AN_PORT:$AN_PORT" "NAIVE_PORT:$NAIVE_PORT"; do
            key="${pair%%:*}"
            value="${pair#*:}"
            if [ "$key" != "$owner" ] && [ "$value" != "0" ] && [ "$new_port" = "$value" ]; then
                echo -e "${RED}[拒绝变更] TCP 端口 ${new_port} 已分配给 ${key}。${RESET}"
                return 1
            fi
        done
        if tcp_port_in_use "$new_port"; then
            echo -e "${RED}[拒绝变更] TCP 端口 ${new_port} 已被其他进程占用。${RESET}"
            return 1
        fi
        # Naive H3 与 H2 共用端口；在事务落盘前同时验证 UDP 侧。
        if [ "$owner" = "NAIVE_PORT" ] && [ "${NAIVE_MODE:-h2}" != "h2" ]; then
            for pair in "HY2_PORT:$HY2_PORT" "TU5_PORT:$TU5_PORT"; do
                key="${pair%%:*}"
                value="${pair#*:}"
                if [ "$value" != "0" ] && [ "$new_port" = "$value" ]; then
                    echo -e "${RED}[拒绝变更] UDP 端口 ${new_port} 已分配给 ${key}。${RESET}"
                    return 1
                fi
            done
            if udp_port_in_use "$new_port"; then
                echo -e "${RED}[拒绝变更] UDP 端口 ${new_port} 已被其他进程占用。${RESET}"
                return 1
            fi
        fi
    elif [ "$proto_type" = "udp" ]; then
        for pair in "HY2_PORT:$HY2_PORT" "TU5_PORT:$TU5_PORT"; do
            key="${pair%%:*}"
            value="${pair#*:}"
            if [ "$key" != "$owner" ] && [ "$value" != "0" ] && [ "$new_port" = "$value" ]; then
                echo -e "${RED}[拒绝变更] UDP 端口 ${new_port} 已分配给 ${key}。${RESET}"
                return 1
            fi
        done
        if udp_port_in_use "$new_port"; then
            echo -e "${RED}[拒绝变更] UDP 端口 ${new_port} 已被其他进程占用。${RESET}"
            return 1
        fi
    else
        return 1
    fi
}

# ==========================================
# 4. 订阅生成 (含多协议)
# ==========================================
generate_node_and_sub() {
    load_config_with_defaults || return 1
    ensure_subscription_root || return 1
    # T9：证书缺失时自动重建（保持节点可起、订阅可再生成），失败则拒绝继续。
    ensure_tls_certificates || return 1
    validate_subscription_crypto_material || return 1
    if ! is_valid_uuid "$UUID"; then
        echo -e "${RED}[错误] 配置中的 UUID 无效，拒绝生成订阅路径。${RESET}" >&2
        return 1
    fi
    select_entry_ip || return 1

    local SERVER_IP="$ENTRY_IP_URI"
    local SERVER_IP_RAW="$ENTRY_IP_RAW"
    local SUB_PATH_DIR="${SUB_ROOT}/${UUID}"
    mkdir -p -- "$SUB_PATH_DIR"
    chmod 700 "$SUB_ROOT" "$SUB_PATH_DIR" 2>/dev/null || true

    local all_links=""

    # Vmess-ws 链接 (VM_ENABLED控制)
    if [ "$VM_ENABLED" != "false" ]; then
        if [ "$VM_TLS_ENABLED" = "true" ]; then
            local VMESS_JSON=$(jq -n -c \
              --arg v "2" \
              --arg ps "Vmess-TLS-$CDN_IP" \
              --arg add "$SERVER_IP_RAW" \
              --arg port "$PORT" \
              --arg id "$UUID" \
              --arg aid "0" \
              --arg scy "auto" \
              --arg net "ws" \
              --arg type "" \
              --arg host "www.bing.com" \
              --arg path "/${UUID}-vm" \
              --arg tls "tls" \
              --arg sni "www.bing.com" \
              --arg fp "chrome" \
              --arg alpn "" \
              '{v: $v, ps: $ps, add: $add, port: $port, id: $id, aid: $aid, scy: $scy, net: $net, type: $type, host: $host, path: $path, tls: $tls, sni: $sni, fp: $fp, alpn: $alpn, allowInsecure: "1", insecure: "1"}')
        else
            local VMESS_JSON=$(jq -n -c \
              --arg v "2" \
              --arg ps "Argo优选-$CDN_IP" \
              --arg add "$CDN_IP" \
              --arg port "$ARGO_EDGE_PORT" \
              --arg id "$UUID" \
              --arg aid "0" \
              --arg scy "auto" \
              --arg net "ws" \
              --arg type "" \
              --arg host "$ARGO_DOMAIN" \
              --arg path "/${UUID}-vm" \
              --arg tls "tls" \
              --arg sni "$ARGO_DOMAIN" \
              --arg fp "chrome" \
              --arg alpn "" \
              '{v: $v, ps: $ps, add: $add, port: $port, id: $id, aid: $aid, scy: $scy, net: $net, type: $type, host: $host, path: $path, tls: $tls, sni: $sni, fp: $fp, alpn: $alpn}')
        fi
        local VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"
        all_links="$VMESS_LINK"
    fi

    # Vless-reality
    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        local vl_link="vless://${UUID}@${SERVER_IP}:${VL_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#VL-REALITY-${HOSTNAME:-node}"
        if [ -z "$all_links" ]; then
            all_links="$vl_link"
        else
            all_links="$all_links"$'\n'"$vl_link"
        fi
    fi

    # Hysteria2
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        local hy2_hop=$(get_hop_ports "$HY2_PORT")
        local hy2_extra=""
        [ -n "$hy2_hop" ] && hy2_extra="&mport=$(printf '%s' "$hy2_hop" | tr ':' '-')"
        local hy2_link="hysteria2://${UUID}@${SERVER_IP}:${HY2_PORT}?security=tls&alpn=h3&insecure=1&sni=www.bing.com&pinSHA256=${CERT_SHA256}&obfs=salamander&obfs-password=${UUID}${hy2_extra}#HY2-${HOSTNAME:-node}"
        if [ -z "$all_links" ]; then
            all_links="$hy2_link"
        else
            all_links="$all_links"$'\n'"$hy2_link"
        fi
    fi

    # Tuic5
    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        # NekoBox 的 TUIC URI 解析器使用 allow_insecure；同时保留 insecure
        # 兼容其他客户端。两者并存时，各客户端会忽略不认识的参数。
        local tu5_link="tuic://${UUID}:${UUID}@${SERVER_IP}:${TU5_PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&insecure=1&allow_insecure=1&zero_rtt_handshake=true#TU5-${HOSTNAME:-node}"
        if [ -z "$all_links" ]; then
            all_links="$tu5_link"
        else
            all_links="$all_links"$'\n'"$tu5_link"
        fi
    fi

    # Anytls
    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        local an_link="anytls://${UUID}@${SERVER_IP}:${AN_PORT}?sni=www.bing.com&insecure=1#ANYTLS-${HOSTNAME:-node}"
        if [ -z "$all_links" ]; then
            all_links="$an_link"
        else
            all_links="$all_links"$'\n'"$an_link"
        fi
    fi

    # NAIVE-SUPPORT: H2 使用 naive+https，H3 使用 naive+quic。
    if [ "$NAIVE_ENABLED" = "true" ] && [ -n "$NAIVE_PORT" ] && [ "$NAIVE_PORT" != "0" ]; then
        local naive_link=""
        if [ "${NAIVE_MODE:-h2}" != "h3" ]; then
            naive_link="naive+https://${NAIVE_USER}:${NAIVE_PASS}@${NAIVE_DOMAIN}:${NAIVE_PORT}#RR-Naive-H2"
            all_links="${all_links:+$all_links$'\n'}$naive_link"
        fi
        if [ "${NAIVE_MODE:-h2}" != "h2" ]; then
            naive_link="naive+quic://${NAIVE_USER}:${NAIVE_PASS}@${NAIVE_DOMAIN}:${NAIVE_PORT}?congestion_control=${NAIVE_QUIC_CC:-bbr}#RR-Naive-H3"
            all_links="${all_links:+$all_links$'\n'}$naive_link"
        fi
    fi

    local sub_tmp=""
    local encoded_tmp=""
    sub_tmp=$(mktemp "$SUB_PATH_DIR/.jhsub.txt.XXXXXX") || return 1
    encoded_tmp=$(mktemp "$SUB_PATH_DIR/.jhsub_encoded.txt.XXXXXX") || { rm -f "$sub_tmp"; return 1; }
    printf '%s\n' "$all_links" > "$sub_tmp"
    printf '%s' "$all_links" | base64 -w 0 > "$encoded_tmp"
    chmod 600 "$sub_tmp" "$encoded_tmp" 2>/dev/null || true
    mv -f "$sub_tmp" "$SUB_PATH_DIR/jhsub.txt"
    mv -f "$encoded_tmp" "$SUB_PATH_DIR/jhsub_encoded.txt"
    # sing-box 官方客户端：一条完整配置包含所有已启用且受支持的协议。
    generate_client_json "$SERVER_IP_RAW" || return 1
    # 旧版面板曾发布单独 VL Reality 地址；继续生成以保证已订阅用户热更后不断链，
    # 新面板不再把它作为 sing-box 官方主入口展示。
    generate_client_json "$SERVER_IP_RAW" vless 2>/dev/null || true
    # 其他软件：一个软件一条订阅（内容按兼容性裁剪）
    generate_client_split_subs

    # 当 Clash Meta 开关开启时，自动生成 Clash YAML 订阅
    if [ "$CLASH_ENABLED" = "true" ]; then
        generate_clash_yaml "$SERVER_IP_RAW" || return 1
        generate_clash_client_copies || return 1
    else
        rm -f "$SUB_PATH_DIR/clash_meta.yaml" "$SUB_PATH_DIR/client-mihomo.yaml" \
            "$SUB_PATH_DIR/client-clash-verge.yaml" "$SUB_PATH_DIR/client-flclash.yaml"
    fi
    # 所有目标文件写入完成后再原子刷新短地址；旧 UUID 长路径继续保留兼容。
    create_short_subscription_alias || return 1

    # 启动订阅 HTTP 服务
    start_subscription_server || return 1

    # 触发自动更新 Python 脚本
    if crontab -l 2>/dev/null | grep -q "auto_update_sub.py"; then
        if [ -f "/usr/local/bin/auto_update_sub.py" ]; then
            python3 /usr/local/bin/auto_update_sub.py || \
                echo -e "${YELLOW}[警告] 自动优选订阅更新失败，基础订阅仍已生成。${RESET}" >&2
        fi
    fi
    # Nexus 面板设备订阅同步刷新（未安装面板或未加载模块时跳过）
    if command -v generate_nexus_device_subscriptions >/dev/null 2>&1; then
        # 已安装 Nexus 时个人订阅属于本次刷新事务的一部分；失败必须向上
        # 返回，让配置变更/热更新回滚，不能留下节点已更新而二维码仍指向旧内容。
        generate_nexus_device_subscriptions || return 1
    fi
    return 0
}

subscription_short_token() {
    local user_id="$1"
    is_valid_uuid "$user_id" || return 1
    [ "$user_id" = "${UUID:-}" ] || return 1
    [[ "${SUB_TOKEN:-}" =~ ^[A-Za-z0-9_-]{32}$ ]] || return 1
    printf '%s\n' "$SUB_TOKEN"
}

create_short_subscription_alias() {
    local token=""
    local route=""
    local target=""
    local existing_link=""
    token=$(subscription_short_token "$UUID") || return 1
    [[ "$token" =~ ^[A-Za-z0-9_-]{32}$ ]] || return 1
    # SimpleHTTPServer serves index.html instead of exposing directory listings.
    : > "$SUB_ROOT/index.html" || return 1
    chmod 600 "$SUB_ROOT/index.html" || return 1
    while read -r route target; do
        install -d -m 700 "$SUB_ROOT/$route" || return 1
        : > "$SUB_ROOT/$route/index.html" || return 1
        chmod 600 "$SUB_ROOT/$route/index.html" || return 1
        if [ -f "$SUB_ROOT/${UUID}/${target}" ]; then
            ln -sfn "../${UUID}/${target}" "$SUB_ROOT/${route}/${token}" || return 1
        else
            rm -f "$SUB_ROOT/${route}/${token}"
        fi
        for existing_link in "$SUB_ROOT"/"$route"/*; do
            [ -L "$existing_link" ] || continue
            [ "$(basename "$existing_link")" = "$token" ] || rm -f "$existing_link"
        done
    done <<'EOF'
s jhsub_encoded.txt
r jhsub.txt
c client.json
m clash_meta.yaml
cv client-vl.json
mm client-mihomo.yaml
vg client-clash-verge.yaml
fc client-flclash.yaml
sv client-v2rayn.txt
sg client-v2rayng.txt
sr client-sr.txt
sn client-nekobox.txt
EOF
    return 0
}

subscription_short_route() {
    case "${1:-encoded}" in
        encoded|jhsub_encoded.txt) printf 's' ;;
        raw|jhsub.txt) printf 'r' ;;
        client|client.json) printf 'c' ;;
        clash|clash_meta.yaml) printf 'm' ;;
        client-vl.json|vl) printf 'cv' ;;
        client-mihomo.yaml|mihomo) printf 'mm' ;;
        client-clash-verge.yaml|clash-verge) printf 'vg' ;;
        client-flclash.yaml|flclash) printf 'fc' ;;
        client-v2rayn.txt) printf 'sv' ;;
        client-v2rayng.txt) printf 'sg' ;;
        client-sr.txt) printf 'sr' ;;
        client-nekobox.txt) printf 'sn' ;;
        *) return 1 ;;
    esac
}

# 客户端内置国内域名直连列表（sing-box 客户端配置零下载依赖，启动必成）
# 完整列表可自行增补；未命中的国内域名走代理仍可访问，仅速度略降
RR_CN_DOMAINS='".cn",".com.cn",".net.cn",".org.cn",".gov.cn",".edu.cn","qq.com","wechat.com","weixin.qq.com","tencent.com","taobao.com","tmall.com","alipay.com","alicdn.com","aliyun.com","jd.com","360buyimg.com","baidu.com","bilibili.com","bilivideo.com","163.com","126.com","weibo.com","weibo.cn","zhihu.com","meituan.com","douyin.com","bytedance.com","toutiao.com","xiaomi.com","mi.com","miui.com","huawei.com","vivo.com.cn","oppo.com","ctrip.com","sogou.com","smzdm.com","dangdang.com","csdn.net","cnblogs.com","gitee.com","youku.com","iqiyi.com","douban.com","ximalaya.com","zhimg.com","sina.com.cn","sina.cn"'

build_short_subscription_url() {
    local server_ip="$1"
    local public_port="$2"
    local user_id="$3"
    local format="${4:-encoded}"
    local token=""
    local route=""
    [[ "$server_ip$public_port$user_id$format" != *$'\n'* && \
       "$server_ip$public_port$user_id$format" != *$'\r'* ]] || return 1
    is_valid_port "$public_port" || return 1
    token=$(subscription_short_token "$user_id") || return 1
    route=$(subscription_short_route "$format") || return 1
    local scheme="" url_host="" url_port=""
    if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
        is_valid_domain "${SUB_DOMAIN:-}" || return 1
        scheme=https
        url_host="$SUB_DOMAIN"
        url_port="$public_port"
    else
        scheme=http
        url_host=127.0.0.1
        url_port="${SUB_PORT:-$public_port}"
        is_valid_port "$url_port" || return 1
    fi
    printf '%s://%s:%s/%s/%s' "$scheme" "$url_host" "$url_port" "$route" "$token"
}

build_subscription_url() {
    local server_ip="$1"
    local public_port="$2"
    local user_id="$3"
    local file_name="$4"
    case "$file_name" in
        jhsub.txt|jhsub_encoded.txt|client.json|clash_meta.yaml|client-mihomo.yaml|client-clash-verge.yaml|client-flclash.yaml) ;;
        *) return 1 ;;
    esac
    [[ "$server_ip$public_port$user_id" != *$'\n'* && \
       "$server_ip$public_port$user_id" != *$'\r'* ]] || return 1
    is_valid_port "$public_port" || return 1
    is_valid_uuid "$user_id" || return 1
    local scheme="" url_host="" url_port=""
    if [ "${SUB_ACCESS_MODE:-local}" = https ]; then
        is_valid_domain "${SUB_DOMAIN:-}" || return 1
        scheme=https
        url_host="$SUB_DOMAIN"
        url_port="$public_port"
    else
        scheme=http
        url_host=127.0.0.1
        url_port="${SUB_PORT:-$public_port}"
        is_valid_port "$url_port" || return 1
    fi
    printf '%s://%s:%s/%s/%s' "$scheme" "$url_host" "$url_port" "$user_id" "$file_name"
}

# ==========================================
# 生成多协议客户端 JSON (SFA/SFI/SFW 可导入)
# ==========================================

# ==========================================
# 按客户端拆分的订阅（一个软件一条地址）
# ==========================================
generate_client_split_subs() {
    # 基于 jhsub.txt 按客户端兼容性裁剪生成
    local SUB_PATH_DIR="${RR_SUB_OUTPUT_DIR:-${SUB_ROOT}/${UUID}}"
    local src="${SUB_PATH_DIR}/jhsub.txt"
    [ -f "$src" ] || return 0
    local content=""
    content=$(cat "$src")
    # 五哥定：除 sing-box 单独 VL 外，其他软件全部全协议（base64 订阅格式）
    local full_b64=""
    full_b64=$(printf '%s\n' "$content" | base64 -w0)
    printf '%s' "$full_b64" > "${SUB_PATH_DIR}/client-v2rayn.txt" 2>/dev/null
    cp -f "${SUB_PATH_DIR}/client-v2rayn.txt" "${SUB_PATH_DIR}/client-v2rayng.txt" 2>/dev/null
    cp -f "${SUB_PATH_DIR}/client-v2rayn.txt" "${SUB_PATH_DIR}/client-sr.txt" 2>/dev/null
    cp -f "${SUB_PATH_DIR}/client-v2rayn.txt" "${SUB_PATH_DIR}/client-nekobox.txt" 2>/dev/null
    return 0
}

generate_client_json() {
    load_config_with_defaults || return 1
    local SERVER_IP="$1"
    if [ -z "$SERVER_IP" ]; then
        select_entry_ip || return 1
        SERVER_IP="$ENTRY_IP_RAW"
    fi
    # 单协议模式（$2）：vmess/vless/hy2/tuic5/anytls/naive；空 = 全协议
    local PROTO_FILTER="${2:-}"
    local file_suffix=""
    case "$PROTO_FILTER" in
        vmess) file_suffix="-vm" ;;
        vless) file_suffix="-vl" ;;
        hy2) file_suffix="-hy2" ;;
        tuic5) file_suffix="-tu5" ;;
        anytls) file_suffix="-an" ;;
        naive) file_suffix="-naive" ;;
    esac
    # 个人订阅使用与管理员备注无关的稳定随机别名。修改面板备注时，
    # 客户端节点名称不会变化，也不会把管理备注泄露到订阅中。
    local hostname="${RR_CLIENT_NAME_OVERRIDE:-${HOSTNAME:-node}}"
    # 设备订阅复用：RR_CLIENT_UUID_OVERRIDE 覆盖节点凭据，RR_SUB_OUTPUT_DIR 覆盖输出目录
    local uuid_val="${RR_CLIENT_UUID_OVERRIDE:-$UUID}"
    local SUB_PATH_DIR="${RR_SUB_OUTPUT_DIR:-${SUB_ROOT}/${uuid_val}}"

    # 主动心跳（HB_ENABLED=true 时注入；默认关闭不注入，兼容旧客户端）
    # TCP 保活字段（Dial Fields，sing-box 客户端 1.13+ 合法）。
    # UDP 协议（hysteria2/TUIC）不注入：1.13 内核内置 QUIC keepalive / heartbeat；
    # 显式 QUIC 保活字段是 1.14+ 才支持，注入会被 1.13 客户端拒绝加载。
    local hb_tcp_field=""
    if [ "$HB_ENABLED" = "true" ]; then
        local hb_sec="${HB_INTERVAL:-30}"
        case "$hb_sec" in
            *[!0-9]*|"") hb_sec=30 ;;
        esac
        [ "$hb_sec" -ge 1 ] 2>/dev/null || hb_sec=30
        [ "$hb_sec" -le 3600 ] 2>/dev/null || hb_sec=3600
        hb_tcp_field='"tcp_keep_alive":"'"$hb_sec"'s","tcp_keep_alive_interval":"'"$hb_sec"'s",'
    fi

    local outbounds_json='"outbounds":['
    local first=true
    local tags=""

    append_client_tag() {
        local tag="$1"
        [ -n "$tags" ] && tags+=','
        tags+='"'"$tag"'"'
    }

    # Vmess (VM_ENABLED控制)
    if [ "$VM_ENABLED" != "false" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        append_client_tag "vmess-${hostname}"
        if [ "$VM_TLS_ENABLED" = "true" ]; then
            outbounds_json+='{"type":"vmess","tag":"vmess-'"$hostname"'","server":"'"$SERVER_IP"'","server_port":'"$PORT"',"uuid":"'"$uuid_val"'","security":"auto","packet_encoding":"packetaddr",'"$hb_tcp_field"'"tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"type":"ws","path":"/'"${UUID}"'-vm"}}'
        else
            outbounds_json+='{"type":"vmess","tag":"vmess-'"$hostname"'","server":"'"$CDN_IP"'","server_port":'"$ARGO_EDGE_PORT"',"uuid":"'"$uuid_val"'","security":"auto","packet_encoding":"packetaddr",'"$hb_tcp_field"'"tls":{"enabled":true,"server_name":"'"$ARGO_DOMAIN"'","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"type":"ws","path":"/'"${UUID}"'-vm","max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":["'"$ARGO_DOMAIN"'"]}}}'
            # Argo 优选副节点 outbound（自动优选 worker 解析的 CNAME 落盘文件）
            if [ -s /tmp/sub_server/preferred_cnames.txt ]; then
                local pref_add="" pref_idx=1
                while IFS= read -r pref_add; do
                    [ -n "$pref_add" ] || continue
                    outbounds_json+=',{"type":"vmess","tag":"vmess-pref'"$pref_idx"'-'"$hostname"'","server":"'"$pref_add"'","server_port":'"$ARGO_EDGE_PORT"',"uuid":"'"$uuid_val"'","security":"auto","packet_encoding":"packetaddr",'"$hb_tcp_field"'"tls":{"enabled":true,"server_name":"'"$ARGO_DOMAIN"'","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"type":"ws","path":"/'"${UUID}"'-vm","max_early_data":2048,"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":["'"$ARGO_DOMAIN"'"]}}}'
                    append_client_tag "vmess-pref${pref_idx}-${hostname}"
                    pref_idx=$((pref_idx + 1))
                done < /tmp/sub_server/preferred_cnames.txt
            fi
        fi
    fi

    # Vless
    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        append_client_tag "vless-${hostname}"
        outbounds_json+='{"type":"vless","tag":"vless-'"$hostname"'","server":"'"$SERVER_IP"'","server_port":'"$VL_PORT"',"uuid":"'"$uuid_val"'","flow":"xtls-rprx-vision",'"$hb_tcp_field"'"tls":{"enabled":true,"server_name":"apple.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"'"$PUBLIC_KEY"'","short_id":"'"$SHORT_ID"'"}}}'
    fi

    # Hysteria2
    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        append_client_tag "hy2-${hostname}"
        local hy2_hop_ports=""
        local hy2_port_fields=""
        local hy2_ports_json=""
        hy2_hop_ports=$(get_hop_ports "$HY2_PORT")
        if [ -n "$hy2_hop_ports" ]; then
            # server_ports 只接受范围字符串；单端口需规范化为 "40000:40000"。
            hy2_ports_json=$(printf '%s' "$hy2_hop_ports" | jq -R -c \
                'split(",") | map(if test(":") then . else . + ":" + . end)')
            hy2_port_fields='"server_ports":'"$hy2_ports_json"',"hop_interval":"'"$HY2_HOP_INTERVAL"'"'
        else
            hy2_port_fields='"server_port":'"$HY2_PORT"
        fi
        outbounds_json+='{"type":"hysteria2","tag":"hy2-'"$hostname"'","server":"'"$SERVER_IP"'",'"$hy2_port_fields"',"password":"'"$uuid_val"'","obfs":{"type":"salamander","password":"'"$UUID"'"},"tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}'
    fi

    # Tuic5
    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        append_client_tag "tuic5-${hostname}"
        outbounds_json+='{"type":"tuic","tag":"tuic5-'"$hostname"'","server":"'"$SERVER_IP"'","server_port":'"$TU5_PORT"',"uuid":"'"$uuid_val"'","password":"'"$uuid_val"'","congestion_control":"bbr","zero_rtt_handshake":true,"udp_relay_mode":"native","tls":{"enabled":true,"server_name":"www.bing.com","insecure":true,"alpn":["h3"]}}'
    fi

    # Anytls
    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        append_client_tag "anytls-${hostname}"
        outbounds_json+='{"type":"anytls","tag":"anytls-'"$hostname"'","server":"'"$SERVER_IP"'","server_port":'"$AN_PORT"',"password":"'"$uuid_val"'",'"$hb_tcp_field"'"tls":{"enabled":true,"server_name":"www.bing.com","insecure":true}}'
    fi

    # NAIVE-SUPPORT: H2/H3 各自生成出站，双栈时可独立切换。
    # 设备订阅通过 RR_NAIVE_USER_OVERRIDE/RR_NAIVE_PASS_OVERRIDE 注入独立凭据，流量按 username 精确归属
    if [ "$NAIVE_ENABLED" = "true" ] && [ -n "$NAIVE_PORT" ] && [ "$NAIVE_PORT" != "0" ]; then
        local naive_ou="${RR_NAIVE_USER_OVERRIDE:-$NAIVE_USER}"
        local naive_op="${RR_NAIVE_PASS_OVERRIDE:-$NAIVE_PASS}"
        if [ "${NAIVE_MODE:-h2}" != "h3" ]; then
            if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
            append_client_tag "naive-h2-${hostname}"
            outbounds_json+='{"type":"naive","tag":"naive-h2-'"$hostname"'","server":"'"$NAIVE_DOMAIN"'","server_port":'"$NAIVE_PORT"',"username":"'"$naive_ou"'","password":"'"$naive_op"'","tls":{"enabled":true,"server_name":"'"$NAIVE_DOMAIN"'"}}'
        fi
        if [ "${NAIVE_MODE:-h2}" != "h2" ]; then
            if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
            append_client_tag "naive-h3-${hostname}"
            outbounds_json+='{"type":"naive","tag":"naive-h3-'"$hostname"'","server":"'"$NAIVE_DOMAIN"'","server_port":'"$NAIVE_PORT"',"username":"'"$naive_ou"'","password":"'"$naive_op"'","quic":true,"quic_congestion_control":"'"${NAIVE_QUIC_CC:-bbr}"'","tls":{"enabled":true,"server_name":"'"$NAIVE_DOMAIN"'"}}'
        fi
    fi

    # Selector / URLTest 覆盖全部已生成节点，包括 Argo 优选副节点与 Naive。
    if [ -n "$tags" ]; then
        if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
        outbounds_json+='{"tag":"proxy","type":"selector","default":"auto","outbounds":["auto",'"$tags"']},{"tag":"auto","type":"urltest","outbounds":['"$tags"'],"url":"http://www.gstatic.com/generate_204","interval":"10m","tolerance":50}'
    fi
    if [ "$first" = true ]; then first=false; else outbounds_json+=','; fi
    outbounds_json+='{"type":"direct","tag":"direct"}'

    outbounds_json+=']'

    local client_final="proxy"
    local remote_dns_detour='"detour":"proxy"'
    if [ -z "$tags" ]; then
        client_final="direct"
        remote_dns_detour='"detour":"direct"'
    fi
    # 代理服务器地址可能是域名（固定 Argo/Naive）。若这里使用经 proxy
    # detour 的 remote DoH，会形成“先连代理才能解析代理域名”的自举闭环。
    # 客户端普通 DNS 仍由 dns.final=remote 处理；这里只让出站服务器域名的
    # 首次解析使用 local，符合 sing-box shared dial fields 的语义。
    local full_json='{"dns":{"servers":[{"type":"https","tag":"remote","server":"1.1.1.1","path":"/dns-query","tls":{"enabled":true,"server_name":"cloudflare-dns.com"},'"$remote_dns_detour"'},{"type":"udp","tag":"local","server":"223.5.5.5"}],"final":"remote"},"inbounds":[{"type":"tun","tag":"tun-in","address":["172.19.0.1/30","fd00::1/126"],"auto_route":true,"strict_route":true}],'"$outbounds_json"',"route":{"rules":[{"inbound":"tun-in","action":"sniff"},{"protocol":"dns","action":"hijack-dns"},{"domain_suffix":['$RR_CN_DOMAINS'],"action":"route","outbound":"direct"},{"ip_is_private":true,"action":"route","outbound":"direct"}],"default_domain_resolver":"local","final":"'"$client_final"'"}}'

    local SUB_PATH_DIR="${RR_SUB_OUTPUT_DIR:-${SUB_ROOT}/${uuid_val}}"
    mkdir -p "$SUB_PATH_DIR"
    local client_tmp=""
    client_tmp=$(mktemp "$SUB_PATH_DIR/.client.json.XXXXXX") || return 1
    printf '%s\n' "$full_json" > "$client_tmp"
    # 单协议模式：jq 提取目标协议 outbound + direct，final 指向该协议
    if [ -n "$PROTO_FILTER" ]; then
        local proto_tag="${PROTO_FILTER}-${hostname}"
        if ! jq -e ".outbounds[] | select(.tag == \"$proto_tag\")" "$client_tmp" >/dev/null 2>&1; then
            rm -f "$client_tmp"
            echo -e "${RED}[错误] 单协议 $PROTO_FILTER 不在订阅中（未启用或无端口），跳过生成。${RESET}" >&2
            return 1
        fi
        jq --arg t "$proto_tag" '{dns: (.dns | .servers |= map(if (.detour // "") == "proxy" then .detour = $t else . end)), inbounds: .inbounds, outbounds: [.outbounds[] | select(.tag == $t or .tag == "direct")], route: (.route | .final = $t)}' "$client_tmp" > "$client_tmp.single" 2>/dev/null || { rm -f "$client_tmp" "$client_tmp.single"; return 1; }
        mv -f "$client_tmp.single" "$client_tmp"
    fi
    if ! jq empty "$client_tmp" >/dev/null 2>&1; then
        rm -f "$client_tmp"
        echo -e "${RED}[错误] 客户端 JSON 生成失败，保留原订阅文件。${RESET}" >&2
        return 1
    fi
    chmod 600 "$client_tmp" 2>/dev/null || true
    mv -f "$client_tmp" "$SUB_PATH_DIR/client${file_suffix}.json"
}

# ==========================================
# 生成 Clash Meta 专属 YAML 订阅文件
# ==========================================
generate_clash_yaml() {
    load_config_with_defaults || return 1
    local SERVER_IP="$1"
    if [ -z "$SERVER_IP" ]; then
        select_entry_ip || return 1
        SERVER_IP="$ENTRY_IP_RAW"
    fi
    local uuid_val="${RR_CLIENT_UUID_OVERRIDE:-$UUID}"
    local SUB_PATH_DIR="${RR_SUB_OUTPUT_DIR:-${SUB_ROOT}/${uuid_val}}"
    mkdir -p "$SUB_PATH_DIR"
    local yaml_file=""
    yaml_file=$(mktemp "$SUB_PATH_DIR/.clash_meta.yaml.XXXXXX") || return 1
    local hostname="${RR_CLIENT_NAME_OVERRIDE:-${HOSTNAME:-node}}"
    local clash_ipv6=false
    is_ip_version "$SERVER_IP" 6 && clash_ipv6=true
    local proxy_names=""
    local proxy_name=""
    # 默认选中第一个可用协议（兼容性优先：VMess > VL > HY2 > TU5 > ANYTLS）
    local clash_default_node=""
    # mihomo 的 TCP Keep Alive 是顶层通用配置，不是单个 proxy 字段。
    # 写进节点块时部分前端会静默忽略，部分前端会拒绝整份配置。
    local clash_keepalive=""
    if [ "$HB_ENABLED" = "true" ]; then
        local hb_sec="${HB_INTERVAL:-30}"
        case "$hb_sec" in
            *[!0-9]*|"") hb_sec=30 ;;
        esac
        [ "$hb_sec" -ge 1 ] 2>/dev/null || hb_sec=30
        [ "$hb_sec" -le 3600 ] 2>/dev/null || hb_sec=3600
        clash_keepalive="keep-alive-idle: $hb_sec"$'\n'"keep-alive-interval: $hb_sec"
    fi

    cat > "$yaml_file" <<EOF
port: 7890
socks-port: 7891
allow-lan: true
mode: rule
log-level: info
ipv6: $clash_ipv6
global-client-fingerprint: chrome
$clash_keepalive

dns:
  enable: true
  listen: 0.0.0.0:1053
  ipv6: $clash_ipv6
  enhanced-mode: redir-host
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter:
    - "*.lan"
    - "*.local"
    - "localhost.ptlogin2.qq.com"
    - "*.msftconnecttest.com"
    - "*.msftncsi.com"
    - "time.*.com"
    - "time.*.apple.com"
    - "*.ntp.org"
    - "ntp.*.com"
    - "*.srv.nintendo.net"
    - "*.stun.playstation.net"
    - "*.qq.com"
    - "*.qpic.cn"
    - "*.tencent.com"
    - "*.weixin.qq.com"
    - "*.wechat.com"
    - "*.music.126.net"
    - "*.music.163.com"
    - "*.126.net"
    - "*.163.com"
    - "*.miui.com"
    - "*.xiaomi.com"
    - "*.taobao.com"
    - "*.alicdn.com"
    - "*.tmall.com"
    - "*.jd.com"
    - "*.360buyimg.com"
    - "*.baidu.com"
    - "*.bilibili.com"
    - "*.bilivideo.com"
    - "+.nflxvideo.net"
    - "+.media.dssott.com"
  nameserver:
    - https://doh.pub/dns-query
    - https://dns.alidns.com/dns-query
    - 223.5.5.5
  fallback:
    - https://cloudflare-dns.com/dns-query
    - tls://8.8.8.8:853
  fallback-filter:
    geoip: true
    geoip-code: CN
    ipcidr:
      - 240.0.0.0/4
      - 0.0.0.0/32
      - 127.0.0.1/32

proxies:
EOF

    # NAIVE-SUPPORT: Clash(Meta) 原生不支持 naive 协议，此处不输出 naive 节点；
    # naive 用户请改用 sing-box 客户端 JSON（client.json）或订阅链接中的 naive+https:// 条目。

    if [ "$VM_ENABLED" != "false" ]; then
        proxy_name="VMESS-${hostname}"
        [ -z "$clash_default_node" ] && clash_default_node="    default-selected: \"$proxy_name\""
        proxy_names+="      - \"${proxy_name}\""$'\n'
        if [ "$VM_TLS_ENABLED" = "true" ]; then
            cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: vmess
    server: "$SERVER_IP"
    port: $PORT
    uuid: "$uuid_val"
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: www.bing.com
    skip-cert-verify: true
    network: ws
    ws-opts:
      path: "/${UUID}-vm"
EOF
        else
            cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: vmess
    server: "$CDN_IP"
    port: $ARGO_EDGE_PORT
    uuid: "$uuid_val"
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: "$ARGO_DOMAIN"
    network: ws
    ws-opts:
      path: "/${UUID}-vm"
      headers:
        Host: "$ARGO_DOMAIN"
EOF
            # Argo 优选副节点 proxies（自动优选 worker 解析的 CNAME 落盘文件）
            if [ -s /tmp/sub_server/preferred_cnames.txt ]; then
                local pref_add="" pref_idx=1
                while IFS= read -r pref_add; do
                    [ -n "$pref_add" ] || continue
                    proxy_name="VMESS-PREF${pref_idx}-${hostname}"
                    proxy_names+="      - \"${proxy_name}\""$'\n'
                    cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: vmess
    server: "$pref_add"
    port: $ARGO_EDGE_PORT
    uuid: "$uuid_val"
    alterId: 0
    cipher: auto
    udp: true
    tls: true
    servername: "$ARGO_DOMAIN"
    network: ws
    ws-opts:
      path: "/${UUID}-vm"
      headers:
        Host: "$ARGO_DOMAIN"
EOF
                    pref_idx=$((pref_idx + 1))
                done < /tmp/sub_server/preferred_cnames.txt
            fi
        fi
    fi

    if [ "$VL_ENABLED" = "true" ] && [ -n "$VL_PORT" ] && [ "$VL_PORT" != "0" ]; then
        proxy_name="VL-REALITY-$hostname"
        [ -z "$clash_default_node" ] && clash_default_node="    default-selected: \"$proxy_name\""
        proxy_names+="      - \"${proxy_name}\""$'\n'
        cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: vless
    server: "$SERVER_IP"
    port: $VL_PORT
    uuid: $uuid_val
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: apple.com
    reality-opts:
      public-key: $PUBLIC_KEY
      short-id: $SHORT_ID
    client-fingerprint: chrome
EOF
    fi

    if [ "$HY2_ENABLED" = "true" ] && [ -n "$HY2_PORT" ] && [ "$HY2_PORT" != "0" ]; then
        proxy_name="HY2-$hostname"
        [ -z "$clash_default_node" ] && clash_default_node="    default-selected: \"$proxy_name\""
        proxy_names+="      - \"${proxy_name}\""$'\n'
        local hy2_hop=""
        local hy2_clash_ports=""
        local hy2_hop_seconds="30"
        hy2_hop=$(get_hop_ports "$HY2_PORT")
        [ -n "$hy2_hop" ] && hy2_clash_ports=$(printf '%s' "$hy2_hop" | tr ':' '-')
        hy2_hop_seconds=$(duration_to_seconds "$HY2_HOP_INTERVAL" 2>/dev/null) || hy2_hop_seconds="30"
        cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: hysteria2
    server: "$SERVER_IP"
    port: $HY2_PORT
EOF
        if [ -n "$hy2_clash_ports" ]; then
            cat >> "$yaml_file" <<EOF
    ports: "$hy2_clash_ports"
    hop-interval: $hy2_hop_seconds
EOF
        fi
        cat >> "$yaml_file" <<EOF
    password: "$uuid_val"
    obfs: salamander
    obfs-password: "$UUID"
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3
EOF
    fi

    if [ "$TU5_ENABLED" = "true" ] && [ -n "$TU5_PORT" ] && [ "$TU5_PORT" != "0" ]; then
        proxy_name="TU5-$hostname"
        [ -z "$clash_default_node" ] && clash_default_node="    default-selected: \"$proxy_name\""
        proxy_names+="      - \"${proxy_name}\""$'\n'
        cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: tuic
    server: "$SERVER_IP"
    port: $TU5_PORT
    uuid: "$uuid_val"
    password: "$uuid_val"
    udp-relay-mode: native
    congestion-controller: bbr
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3
EOF
    fi

    if [ "$AN_ENABLED" = "true" ] && [ -n "$AN_PORT" ] && [ "$AN_PORT" != "0" ]; then
        proxy_name="ANYTLS-$hostname"
        [ -z "$clash_default_node" ] && clash_default_node="    default-selected: \"$proxy_name\""
        proxy_names+="      - \"${proxy_name}\""$'\n'
        cat >> "$yaml_file" <<EOF
  - name: "$proxy_name"
    type: anytls
    server: "$SERVER_IP"
    port: $AN_PORT
    password: "$uuid_val"
    client-fingerprint: chrome
    udp: true
    idle-session-check-interval: 30
    idle-session-timeout: 30
    sni: www.bing.com
    skip-cert-verify: true
EOF
    fi

    cat >> "$yaml_file" <<EOF

proxy-groups:
  - name: 🚀 节点选择
    type: select
    proxies:
$proxy_names      - DIRECT
$clash_default_node

rules:
  - DST-PORT,5222,🚀 节点选择
  - IP-CIDR,91.108.56.0/22,🚀 节点选择
  - IP-CIDR,149.154.160.0/20,🚀 节点选择
  - GEOIP,CN,DIRECT
  - MATCH,🚀 节点选择
EOF
    chmod 600 "$yaml_file" 2>/dev/null || true
    mv -f "$yaml_file" "$SUB_PATH_DIR/clash_meta.yaml"
}

# mihomo、Clash Verge 与 FlClash 使用同一 mihomo 配置语法，但分别发布
# 独立文件，便于面板为每个软件提供独立地址/二维码并单独排障。
generate_clash_client_copies() {
    local SUB_PATH_DIR="${RR_SUB_OUTPUT_DIR:-${SUB_ROOT}/${RR_CLIENT_UUID_OVERRIDE:-$UUID}}"
    local source_file="${SUB_PATH_DIR}/clash_meta.yaml"
    local target_name=""
    local target_tmp=""
    [ -s "$source_file" ] || return 1
    for target_name in client-mihomo.yaml client-clash-verge.yaml client-flclash.yaml; do
        target_tmp=$(mktemp "$SUB_PATH_DIR/.${target_name}.XXXXXX") || return 1
        if ! install -m 600 "$source_file" "$target_tmp"; then
            rm -f "$target_tmp"
            return 1
        fi
        mv -f "$target_tmp" "$SUB_PATH_DIR/$target_name" || { rm -f "$target_tmp"; return 1; }
    done
}

# ==========================================
# Clash Meta 订阅开关函数
# ==========================================
toggle_clash_meta() {
    load_config_with_defaults || return 1
    clear
    if [ "$CLASH_ENABLED" = "true" ]; then
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "Clash Meta 专属订阅 - 当前状态: ${GREEN}已开启${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 关闭 Clash Meta 订阅生成"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub
        case "$sub" in
            1)
                apply_config_transaction "关闭 Clash Meta 订阅" "CLASH_ENABLED" "false"
                sleep 2
                ;;
            0) return ;;
        esac
    else
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "Clash Meta 专属订阅 - 当前状态: ${RED}未开启${RESET}"
        echo -e "${CYAN}==================================================${RESET}"
        echo -e "  1. 开启 Clash Meta 订阅生成"
        echo -e "  0. 返回"
        read -p "请选择操作: " sub
        case "$sub" in
            1)
                if apply_config_transaction "开启 Clash Meta 订阅" "CLASH_ENABLED" "true"; then
                    select_entry_ip || { sleep 2; return; }
                    local clash_url=""
                    clash_url=$(build_short_subscription_url "$ENTRY_IP_RAW" "$SUB_URL_PORT" "$UUID" clash) || {
                        echo -e "${RED}[错误] 无法生成安全订阅地址。${RESET}" >&2
                        sleep 2
                        return
                    }
                    echo -e "${CYAN}==================================================${RESET}"
                    echo -e "Clash Meta 订阅地址:"
                    echo -e "${WHITE}${clash_url}${RESET}"
                    echo -e "${CYAN}==================================================${RESET}"
                fi
                sleep 3
                ;;
            0) return ;;
        esac
    fi
}

# ==========================================
# Argo/Vmess 节点开关函数
