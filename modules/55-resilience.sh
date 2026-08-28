# shellcheck shell=bash
# RR-vps 7.1 diagnostics, encrypted migration backups and update preflight.

RR_DIAGNOSTIC_DIR="/var/lib/rr/diagnostics"
RR_BACKUP_WORK_DIR="/var/lib/rr-backup"

rr_ensure_resilience_dependencies() {
    if python3 -c 'import cryptography' >/dev/null 2>&1 && command -v sqlite3 >/dev/null 2>&1; then
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 || return 1
    printf '首次使用加密迁移功能，正在补齐系统加密与 SQLite 组件…\n'
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 update -y >/dev/null && \
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 install -y \
            python3-cryptography sqlite3 >/dev/null
}

rr_emit_alert() {
    [ -r /var/lib/rr-nexus/nexus.db ] || return 0
    PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.notify_cli "$@" >/dev/null 2>&1 || true
}

rr_doctor_add() {
    local level="$1" id="$2" summary="$3" detail="${4:-}" suggestion="${5:-}"
    case "$level" in
        ok) RR_DOCTOR_OK=$((RR_DOCTOR_OK + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '✅ %s\n' "$summary" ;;
        warn) RR_DOCTOR_WARN=$((RR_DOCTOR_WARN + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '⚠️  %s\n' "$summary" ;;
        fail) RR_DOCTOR_FAIL=$((RR_DOCTOR_FAIL + 1)); [ "${RR_DOCTOR_JSON_ONLY:-false}" = true ] || printf '❌ %s\n' "$summary" ;;
        *) return 1 ;;
    esac
    if [ "${RR_DOCTOR_JSON_ONLY:-false}" != true ]; then
        [ -n "$detail" ] && printf '   %s\n' "$detail"
        [ -n "$suggestion" ] && printf '   建议：%s\n' "$suggestion"
    fi
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg level "$level" --arg id "$id" --arg summary "$summary" \
            --arg detail "$detail" --arg suggestion "$suggestion" \
            '{level:$level,id:$id,summary:$summary,detail:$detail,suggestion:$suggestion}' \
            >> "$RR_DOCTOR_EVENTS"
    fi
}

rr_doctor_redact() {
    local source="$1" target="$2"
    sed -E \
        -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+:[^/@[:space:]]+@#\1***:***@#g' \
        -e 's#([?&](token|key|secret|password|auth)=)[^&[:space:]"}]+#\1***#Ig' \
        -e 's#[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}#***-UUID-REDACTED***#g' \
        -e 's#([A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})#***-TOKEN-REDACTED***#g' \
        -e 's#(^|[^0-9])([0-9]{1,3}\.){3}[0-9]{1,3}([^0-9]|$)#\1***-IP-REDACTED***\3#g' \
        -e 's#([A-Za-z0-9-]+\.)+[A-Za-z]{2,}#***-DOMAIN-REDACTED***#g' \
        "$source" > "$target"
}

rr_doctor_firewall_state() {
    local port="$1" proto="$2" policy=""
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | head -n 1 | grep -qi active; then
        ufw status 2>/dev/null | grep -Eq "^[[:space:]]*${port}/${proto}[[:space:]]+ALLOW" && return 0
        return 1
    fi
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p "$proto" --dport "$port" -m comment \
            --comment "$FIREWALL_BLOCK_COMMENT" -j DROP >/dev/null 2>&1 && return 1
        iptables -C INPUT -p "$proto" --dport "$port" -m comment \
            --comment "$FIREWALL_COMMENT" -j ACCEPT >/dev/null 2>&1 && return 0
        policy=$(iptables -S INPUT 2>/dev/null | awk '$1=="-P" && $2=="INPUT" {print $3; exit}')
        [ "$policy" = ACCEPT ] && return 0
        return 1
    fi
    return 2
}

rr_doctor_check_endpoint() {
    local name="$1" port="$2" proto="$3" state=0
    if ! is_valid_port "$port"; then
        rr_doctor_add fail "port_${name}" "${name} 端口配置无效" "port=${port:-empty}" "在协议菜单重新设置端口"
        return
    fi
    case "$proto" in
        tcp) ss -H -ltn "sport = :$port" 2>/dev/null | grep -q LISTEN ;;
        udp) ss -H -lun "sport = :$port" 2>/dev/null | grep -qE 'UNCONN|ESTAB' ;;
        *) return ;;
    esac
    if [ "$?" -eq 0 ]; then
        rr_doctor_add ok "port_${name}" "${name} ${proto^^}/${port} 正在监听"
    else
        rr_doctor_add fail "port_${name}" "${name} ${proto^^}/${port} 未监听" "协议已启用但没有对应套接字" "查看 Sing-box 配置与服务日志"
    fi
    rr_doctor_firewall_state "$port" "$proto" || state=$?
    case "$state" in
        0) rr_doctor_add ok "firewall_${name}" "${name} ${proto^^}/${port} 防火墙允许" ;;
        1) rr_doctor_add fail "firewall_${name}" "${name} ${proto^^}/${port} 被防火墙阻止" "RR 放行规则不存在或存在拒绝规则" "执行 rr doctor --repair" ;;
        *) rr_doctor_add warn "firewall_${name}" "未检测到可识别的防火墙管理器" "端口监听正常，但无法确认云厂商安全组" "同时检查 VPS 控制台安全组" ;;
    esac
}

rr_doctor() {
    local repair=false report=false json_only=false arg=""
    for arg in "$@"; do
        case "$arg" in
            --repair) repair=true ;;
            --report) report=true ;;
            --json) json_only=true ;;
            *) printf '用法：rr doctor [--repair] [--report] [--json]\n' >&2; return 2 ;;
        esac
    done

    RR_DOCTOR_OK=0
    RR_DOCTOR_WARN=0
    RR_DOCTOR_FAIL=0
    RR_DOCTOR_JSON_ONLY="$json_only"
    RR_DOCTOR_EVENTS=$(mktemp /tmp/rr-doctor-events.XXXXXX) || return 1
    chmod 600 "$RR_DOCTOR_EVENTS"
    local started report_file="" free_kb="" cert_file="" cert_days="" db_result="" nodes_enabled=false
    started=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    [ "$json_only" = true ] || printf '\nRR-vps %s 一键体检\n%s\n' "$SCRIPT_VERSION" '────────────────────────────────────────'

    if check_supported_os >/dev/null 2>&1; then
        rr_doctor_add ok system "系统版本受支持" "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-unknown}")"
    else
        rr_doctor_add fail system "系统版本不受支持" "仅支持 Debian 12 / Ubuntu 22.04 / 24.04" "迁移到受支持系统后再更新"
    fi

    if getent ahosts github.com >/dev/null 2>&1; then
        rr_doctor_add ok dns "DNS 解析正常"
    else
        rr_doctor_add fail dns "DNS 无法解析 github.com" "更新与证书申请会失败" "检查 /etc/resolv.conf 与 VPS 网络"
    fi

    if command -v timedatectl >/dev/null 2>&1 && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
        rr_doctor_add ok clock "系统时间已同步"
    else
        rr_doctor_add warn clock "无法确认系统时间同步" "时间漂移会导致 TLS、TOTP 与更新校验异常" "启用 systemd-timesyncd 或 chrony"
    fi

    if load_config_with_defaults >/dev/null 2>&1; then
        rr_doctor_add ok config "RR 配置可读取" "schema=${CONFIG_VERSION:-unknown}"
        any_node_protocol_enabled && nodes_enabled=true
    else
        rr_doctor_add fail config "RR 配置读取失败" "$CONFIG_FILE" "从备份恢复配置或重新运行安装"
    fi

    detect_public_ips
    if [ -n "$PUBLIC_IPV4" ]; then
        rr_doctor_add ok public_ipv4 "公网 IPv4 入口可用" "$IPV4_ENTRY_SOURCE"
    else
        rr_doctor_add warn public_ipv4 "未检测到公网 IPv4" "纯 IPv6 机器可忽略"
    fi
    if [ -n "$PUBLIC_IPV6" ]; then
        rr_doctor_add ok public_ipv6 "公网 IPv6 入口可用" "$IPV6_ENTRY_SOURCE"
    elif [ "${IPV6_NAT66_DETECTED:-false}" = true ]; then
        rr_doctor_add warn public_ipv6 "检测到 NAT66，缺少手动公网 IPv6" "出口地址不能直接作为容器入口" "在入口设置中填写服务商映射地址"
    else
        rr_doctor_add warn public_ipv6 "未检测到公网 IPv6" "纯 IPv4 机器可忽略"
    fi

    if [ "$nodes_enabled" = true ]; then
      if [ -x "$SINGBOX_BIN" ] && [ -s /etc/sing-box/config.json ] && \
       "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
        rr_doctor_add ok singbox_config "Sing-box 配置语法正常"
    else
        rr_doctor_add fail singbox_config "Sing-box 配置校验失败" "配置不存在或核心拒绝加载" "运行 rr doctor --repair；仍失败时查看 journalctl -u sing-box"
    fi

    if systemctl is-active --quiet sing-box 2>/dev/null; then
        rr_doctor_add ok singbox_service "Sing-box 服务运行中"
    else
        rr_doctor_add fail singbox_service "Sing-box 服务未运行" "$(systemctl is-failed sing-box 2>/dev/null || true)" "查看 journalctl -u sing-box -n 80"
    fi

    [ "${VL_ENABLED:-false}" = true ] && rr_doctor_check_endpoint vless "$VL_PORT" tcp
    [ "${HY2_ENABLED:-false}" = true ] && rr_doctor_check_endpoint hysteria2 "$HY2_PORT" udp
    [ "${TU5_ENABLED:-false}" = true ] && rr_doctor_check_endpoint tuic "$TU5_PORT" udp
    [ "${AN_ENABLED:-false}" = true ] && rr_doctor_check_endpoint anytls "$AN_PORT" tcp
    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        [ "${NAIVE_MODE:-h2}" = h3 ] || rr_doctor_check_endpoint naive_h2 "$NAIVE_PORT" tcp
        [ "${NAIVE_MODE:-h2}" = h2 ] || rr_doctor_check_endpoint naive_h3 "$NAIVE_PORT" udp
    fi
    [ "${VM_ENABLED:-false}" = true ] && [ "${VM_TLS_ENABLED:-false}" = true ] && \
        rr_doctor_check_endpoint vmess_tls "$PORT" tcp
    if [ "${VM_ENABLED:-false}" = true ] && [ "${VM_TLS_ENABLED:-false}" != true ]; then
        if expected_argo_tunnel_running; then
            rr_doctor_add ok argo "Argo 隧道运行中" "$([ "${TUNNEL_MODE:-1}" = 2 ] && printf '固定隧道' || printf '快速隧道')"
        else
            rr_doctor_add fail argo "Argo 隧道未运行" "VMess-WS 源站已启用但隧道离线" "执行 rr doctor --repair"
        fi
    fi
    else
        rr_doctor_add warn singbox_service "当前没有启用节点协议" "管理框架保持待机，不要求 Sing-box 或订阅服务运行"
    fi

    if [ -r /etc/rr-nexus/nexus.json ]; then
        if [ -r /var/lib/rr-nexus/nexus.db ] && command -v sqlite3 >/dev/null 2>&1; then
            db_result=$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA quick_check;' 2>/dev/null || true)
            if [ "$db_result" = "ok" ]; then
                rr_doctor_add ok nexus_db "RR Nexus 数据库完整"
            else
                rr_doctor_add fail nexus_db "RR Nexus 数据库完整性异常" "${db_result:-无法读取}" "不要删除数据库；优先从加密备份恢复"
            fi
        else
            rr_doctor_add warn nexus_db "Nexus 尚未安装或数据库不存在"
        fi
        if systemctl is-active --quiet rr-nexus 2>/dev/null; then
            local nexus_port=""
            nexus_port=$(jq -r '.port // 7900' /etc/rr-nexus/nexus.json 2>/dev/null || printf 7900)
            if curl -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:${nexus_port}/healthz" >/dev/null 2>&1; then
                rr_doctor_add ok nexus_service "RR Nexus 服务与健康接口正常"
            else
                rr_doctor_add fail nexus_service "RR Nexus 进程存在但健康门禁失败" "http://127.0.0.1:${nexus_port}/healthz" "检查数据库与 journalctl -u rr-nexus"
            fi
        else
            rr_doctor_add fail nexus_service "RR Nexus 服务未运行" "面板 API 不可用" "查看 journalctl -u rr-nexus -n 80"
        fi
    else
        rr_doctor_add warn nexus "RR Nexus 未安装" "不影响节点协议"
    fi

    if [ "$nodes_enabled" = true ]; then
        rr_doctor_check_endpoint subscription "${SUB_PORT:-0}" tcp
        local subscription_root="${SUB_ROOT}/${UUID}" missing_subscriptions="" required_subscription=""
        for required_subscription in jhsub.txt jhsub_encoded.txt client.json; do
            [ -s "$subscription_root/$required_subscription" ] || missing_subscriptions+=" ${required_subscription}"
        done
        if [ "${CLASH_ENABLED:-false}" = true ]; then
            for required_subscription in clash_meta.yaml client-mihomo.yaml client-clash-verge.yaml client-flclash.yaml; do
                [ -s "$subscription_root/$required_subscription" ] || missing_subscriptions+=" ${required_subscription}"
            done
        fi
        if [ -z "$missing_subscriptions" ] && jq -e . "$subscription_root/client.json" >/dev/null 2>&1; then
            rr_doctor_add ok subscription_formats "订阅格式完整且 Sing-box 客户端 JSON 有效"
        else
            rr_doctor_add fail subscription_formats "订阅产物缺失或格式无效" "缺失:${missing_subscriptions:- client.json(JSON)}" "执行 rr doctor --repair"
        fi
    fi

    if [ "${NAIVE_ENABLED:-false}" = true ]; then
        cert_file=/etc/rr-naive/fullchain.pem
        if [ -s "$cert_file" ] && command -v openssl >/dev/null 2>&1; then
            if openssl x509 -checkend $((14 * 86400)) -noout -in "$cert_file" >/dev/null 2>&1; then
                rr_doctor_add ok naive_cert "NaiveProxy 真证书有效期充足"
            elif openssl x509 -checkend 0 -noout -in "$cert_file" >/dev/null 2>&1; then
                cert_days=$(python3 - "$cert_file" <<'PY' 2>/dev/null || true
import datetime, ssl, sys
value = ssl._ssl._test_decode_cert(sys.argv[1])["notAfter"]
end = datetime.datetime.strptime(value, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc)
print(max(0, int((end-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//86400)))
PY
)
                rr_doctor_add warn naive_cert "NaiveProxy 证书即将到期" "剩余约 ${cert_days:-14} 天" "检查 certbot renew 与续签钩子"
            else
                rr_doctor_add fail naive_cert "NaiveProxy 证书已过期" "$cert_file" "立即运行证书申请/续签"
            fi
        else
            rr_doctor_add fail naive_cert "NaiveProxy 已启用但证书缺失" "$cert_file" "在协议菜单重新申请 Let's Encrypt 证书"
        fi
    fi

    free_kb=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -ge 262144 ]; then
        rr_doctor_add ok disk "磁盘可用空间充足" "$((free_kb / 1024)) MiB 可用"
    else
        rr_doctor_add fail disk "磁盘空间不足" "更新至少需要 256 MiB 可用空间" "清理日志和无用安装包"
    fi

    if rr_download_file "$RR_MANIFEST_URL" "${RR_DOCTOR_EVENTS}.manifest" 5 && \
       rr_manifest_is_valid "${RR_DOCTOR_EVENTS}.manifest"; then
        rr_doctor_add ok update_source "${RR_UPDATE_CHANNEL:-stable} 更新源可用"
    else
        rr_doctor_add warn update_source "更新源暂不可用" "Raw/API/CDN 均已尝试" "检查 DNS、IPv4/IPv6 路由或稍后重试"
    fi
    rm -f "${RR_DOCTOR_EVENTS}.manifest"

    if [ "$repair" = true ]; then
        [ "$json_only" = true ] || printf '\n执行安全修复…\n'
        chmod 600 "$CONFIG_FILE" /etc/rr-nexus/nexus.json /var/lib/rr-nexus/nexus.db \
            /var/lib/rr-nexus/remote.key 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        if [ -x "$SINGBOX_BIN" ] && "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            systemctl restart sing-box >/dev/null 2>&1 || true
        fi
        if [ -r /etc/rr-nexus/nexus.json ]; then
            systemctl restart rr-nexus >/dev/null 2>&1 || true
        fi
        ensure_runtime_health >/dev/null 2>&1 || true
        if [ "$nodes_enabled" = true ]; then
        generate_node_and_sub >/dev/null 2>&1 || true
        open_firewall >/dev/null 2>&1 || true
        [ "${VL_ENABLED:-false}" = true ] && open_protocol_firewall "$VL_PORT" tcp
        [ "${HY2_ENABLED:-false}" = true ] && open_protocol_firewall "$HY2_PORT" udp
        [ "${TU5_ENABLED:-false}" = true ] && open_protocol_firewall "$TU5_PORT" udp
        [ "${AN_ENABLED:-false}" = true ] && open_protocol_firewall "$AN_PORT" tcp
        if [ "${NAIVE_ENABLED:-false}" = true ]; then
            [ "${NAIVE_MODE:-h2}" = h3 ] || open_protocol_firewall "$NAIVE_PORT" tcp
            [ "${NAIVE_MODE:-h2}" = h2 ] || open_protocol_firewall "$NAIVE_PORT" udp
        fi
        fi
        [ "$json_only" = true ] || printf '安全修复完成；请再次运行 rr doctor 验证。\n'
    fi

    if [ "$report" = true ]; then
        mkdir -p "$RR_DIAGNOSTIC_DIR"
        chmod 700 "$RR_DIAGNOSTIC_DIR"
        report_file="$RR_DIAGNOSTIC_DIR/rr-doctor-$(date -u '+%Y%m%d-%H%M%S').json"
    elif [ "$json_only" = true ]; then
        report_file=$(mktemp /tmp/rr-doctor-report.XXXXXX) || { rm -f "$RR_DOCTOR_EVENTS"; return 1; }
    fi
    if [ -n "$report_file" ] && command -v jq >/dev/null 2>&1; then
        jq -s --arg version "$SCRIPT_VERSION" --arg started "$started" \
            --arg channel "${RR_UPDATE_CHANNEL:-stable}" \
            --argjson ok "$RR_DOCTOR_OK" --argjson warn "$RR_DOCTOR_WARN" --argjson fail "$RR_DOCTOR_FAIL" \
            '{product:"RR-vps",version:$version,started_at:$started,update_channel:$channel,summary:{ok:$ok,warn:$warn,fail:$fail},checks:.}' \
            "$RR_DOCTOR_EVENTS" > "${report_file}.raw"
        rr_doctor_redact "${report_file}.raw" "$report_file"
        rm -f "${report_file}.raw"
        chmod 600 "$report_file"
    fi
    [ "$json_only" = true ] && [ -s "$report_file" ] && cat "$report_file"
    if [ "$json_only" != true ]; then
        printf '%s\n体检结果：%s 正常 · %s 警告 · %s 失败\n' '────────────────────────────────────────' "$RR_DOCTOR_OK" "$RR_DOCTOR_WARN" "$RR_DOCTOR_FAIL"
        [ "$report" = true ] && printf '脱敏报告：%s\n' "$report_file"
    fi
    [ "$report" = true ] || { [ -z "$report_file" ] || rm -f "$report_file"; }
    rm -f "$RR_DOCTOR_EVENTS"
    unset RR_DOCTOR_JSON_ONLY
    [ "$RR_DOCTOR_FAIL" -eq 0 ]
}

rr_backup_copy_path() {
    local source="$1" stage="$2" destination=""
    [ -e "$source" ] || return 0
    destination="$stage/rootfs${source}"
    mkdir -p "$(dirname "$destination")" || return 1
    cp -a -- "$source" "$destination"
}

rr_backup_sqlite_consistent() {
    local source="$1" target="$2"
    [ -e "$source" ] || return 0
    mkdir -p "$(dirname "$target")" || return 1
    python3 - "$source" "$target" <<'PY'
import sqlite3, sys
source = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=15)
target = sqlite3.connect(sys.argv[2])
try:
    source.backup(target)
    row = target.execute("PRAGMA quick_check").fetchone()
    if not row or row[0] != "ok":
        raise RuntimeError("backup quick_check failed")
finally:
    target.close(); source.close()
PY
}

rr_backup_fixed_argo_token() {
    local stage="$1" token="" target=""
    load_config_with_defaults >/dev/null 2>&1 || return 0
    [ "${TUNNEL_MODE:-1}" = 2 ] || return 0
    if [ -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        IFS= read -r token < "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" || return 1
        if [ -n "$token" ] && [[ "$token" != *[[:space:]]* ]]; then
            rr_backup_copy_path "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" "$stage"
            return $?
        fi
        token=""
    fi
    token=$(rr_cloudflared_service_token)
    if [ -z "$token" ] || [[ "$token" == *[[:space:]]* ]]; then
        printf '无法从当前固定 Argo 服务提取 Token，已拒绝生成不完整迁移备份。\n' >&2
        return 1
    fi
    target="$stage/rootfs/etc/rr-cloudflared/token"
    install -d -m 700 "$(dirname "$target")" || return 1
    (umask 077; printf '%s\n' "$token" > "$target")
}

rr_auto_update_cron_line() {
    printf '%s\n' '0 * * * * PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin /usr/bin/python3 /usr/local/bin/auto_update_sub.py >> /var/log/auto_update_sub.log 2>&1'
}

rr_backup_capture_crontab() {
    local destination="$1"
    local expected=""
    local rr_lines=""
    expected=$(rr_auto_update_cron_line)
    rr_lines=$(crontab -l 2>/dev/null | grep 'auto_update_sub\.py' || true)
    if [ -n "$rr_lines" ] && [ "$rr_lines" != "$expected" ]; then
        printf '检测到非标准 RR 自动更新 cron，已拒绝把可执行命令写入备份。\n' >&2
        return 1
    fi
    if [ -n "$rr_lines" ]; then
        printf '%s\n' "$expected" > "$destination"
    else
        : > "$destination"
    fi
}

rr_backup_create() {
    local output="${1:-}" stage="" archive="" relative="" sha="" now=""
    rr_ensure_resilience_dependencies || { printf '无法安装加密备份所需组件。\n' >&2; return 1; }
    now=$(date -u '+%Y%m%d-%H%M%S')
    [ -n "$output" ] || output="$(pwd)/rr-backup-${now}.rrbak"
    [ -d "$output" ] && output="${output%/}/rr-backup-${now}.rrbak"
    case "$output" in /*) ;; *) output="$(pwd)/$output" ;; esac
    mkdir -p "$RR_BACKUP_WORK_DIR" || return 1
    chmod 700 "$RR_BACKUP_WORK_DIR"
    stage=$(mktemp -d "$RR_BACKUP_WORK_DIR/create.XXXXXX") || return 1
    chmod 700 "$stage"
    archive="$stage/payload.tar.gz"

    rr_backup_copy_path /etc/argo_vmess.conf "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/sing-box "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-nexus "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-naive "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /etc/rr-update "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_fixed_argo_token "$stage" || { rm -rf "$stage"; return 1; }
    rr_backup_copy_path /var/lib/rr-nexus/remote.key "$stage" || { rm -rf "$stage"; return 1; }
    # Executable workers and systemd units are regenerated from the installed,
    # manifest-verified runtime after restore. They are never accepted from a
    # portable backup, otherwise importing an untrusted archive is root RCE.
    # cloudflared.service may be owned by another application. RR migrates its
    # tunnel settings, but deliberately never backs up or overwrites that global unit.
    rr_backup_sqlite_consistent /var/lib/rr-nexus/nexus.db "$stage/rootfs/var/lib/rr-nexus/nexus.db" || { rm -rf "$stage"; return 1; }

    mkdir -p "$stage/payload"
    mv "$stage/rootfs" "$stage/payload/rootfs"
    if find "$stage/payload/rootfs" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
        printf '备份源中包含不支持的链接或特殊文件，已拒绝生成。\n' >&2
        rm -rf "$stage"
        return 1
    fi
    rr_backup_capture_crontab "$stage/payload/crontab.txt" || { rm -rf "$stage"; return 1; }
    (
        cd "$stage/payload" || exit 1
        find rootfs -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > manifest.sha256
    ) || { rm -rf "$stage"; return 1; }
    sha=$(sha256sum "$stage/payload/manifest.sha256" | awk '{print $1}')
    jq -n --arg product RR-vps --arg version "$SCRIPT_VERSION" --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg arch "$SYS_ARCH" --arg manifest_sha256 "$sha" \
        '{format:1,product:$product,version:$version,created_at:$created,architecture:$arch,manifest_sha256:$manifest_sha256}' \
        > "$stage/payload/metadata.json" || { rm -rf "$stage"; return 1; }
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner --hard-dereference \
        -czf "$archive" -C "$stage" payload || { rm -rf "$stage"; return 1; }
    mkdir -p "$(dirname "$output")" || { rm -rf "$stage"; return 1; }
    if ! PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_crypto encrypt "$archive" "$output"; then
        rm -rf "$stage"
        return 1
    fi
    chmod 600 "$output"
    rm -rf "$stage"
    printf '加密备份已生成：%s\n' "$output"
    printf '请把文件与口令分开保存；遗失口令无法恢复。\n'
}

rr_restore_apply_tree() {
    local root="$1" source="" relative="" target="" temporary="" mode=""
    [ -d "$root/rootfs" ] || return 1
    while IFS= read -r -d '' source; do
        relative="${source#"$root/rootfs/"}"
        case "$relative" in
            etc/argo_vmess.conf|etc/sing-box/*|etc/rr-nexus/*|etc/rr-naive/*|etc/rr-update/*|etc/rr-cloudflared/*|\
            var/lib/rr-nexus/*) ;;
            *) printf '拒绝恢复不受支持路径：%s\n' "$relative" >&2; return 1 ;;
        esac
        target="/$relative"
        mkdir -p "$(dirname "$target")" || return 1
        temporary="$(dirname "$target")/.rr-restore.$$.tmp"
        # Never trust archived permission bits.  In particular, a crafted
        # backup must not be able to restore setuid/setgid files.
        case "$relative" in
            usr/local/bin/*.py) mode=755 ;;
            etc/systemd/system/*.service|etc/systemd/system/*.timer|etc/sing-box/*.pem|etc/rr-naive/*.pem) mode=644 ;;
            *) mode=600 ;;
        esac
        install -m "$mode" "$source" "$temporary" || return 1
        mv -f "$temporary" "$target" || return 1
    done < <(find "$root/rootfs" -type f -print0 | LC_ALL=C sort -z)
}

rr_restore_clear_managed_tree() {
    rm -rf -- /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared
    rm -f -- /etc/argo_vmess.conf /var/lib/rr-nexus/remote.key \
        /var/lib/rr-nexus/nexus.db /var/lib/rr-nexus/nexus.db-wal /var/lib/rr-nexus/nexus.db-shm \
        /usr/local/bin/auto_update_sub.py /etc/systemd/system/rr-nexus.service \
        /etc/systemd/system/sing-box.service /etc/systemd/system/argo-rr-health.service \
        /etc/systemd/system/argo-rr-health.timer
}

rr_restore_crontab() {
    local rr_entries="$1" temporary="" expected="" restored=""
    expected=$(rr_auto_update_cron_line)
    restored=$(cat "$rr_entries" 2>/dev/null || true)
    if [ -n "$restored" ] && [ "$restored" != "$expected" ]; then
        printf '拒绝恢复非标准 RR cron 命令。\n' >&2
        return 1
    fi
    temporary=$(mktemp /tmp/rr-crontab-restore.XXXXXX) || return 1
    crontab -l 2>/dev/null | grep -v 'auto_update_sub\.py' > "$temporary" || true
    [ -n "$restored" ] && printf '%s\n' "$expected" >> "$temporary"
    if [ -s "$temporary" ]; then
        crontab "$temporary"
    else
        crontab -r >/dev/null 2>&1 || true
    fi
    rm -f "$temporary"
}

rr_restore_regenerate_runtime_files() {
    # Portable backups contain data/config only. Recreate privileged units and
    # executable workers from the already verified local RR runtime.
    if [ -r "$NEXUS_CONFIG_FILE" ]; then
        nexus_write_service || return 1
    fi
    return 0
}

rr_restore_backup() {
    local input="${1:-}" stage="" archive="" rollback="" result=1 argo_prepare_ok=true
    [ -r "$input" ] || { printf '找不到备份文件：%s\n' "$input" >&2; return 2; }
    rr_ensure_resilience_dependencies || { printf '无法安装加密恢复所需组件。\n' >&2; return 1; }
    mkdir -p "$RR_BACKUP_WORK_DIR" || return 1
    stage=$(mktemp -d "$RR_BACKUP_WORK_DIR/restore.XXXXXX") || return 1
    chmod 700 "$stage"
    archive="$stage/payload.tar.gz"
    rollback="$stage/rollback"
    if ! PYTHONPATH="$RR_LIB_DIR/nexus" python3 -m rr_nexus_lib.backup_crypto decrypt "$input" "$archive"; then
        rm -rf "$stage"
        return 1
    fi
    if ! python3 - "$archive" "$stage" <<'PY'
import pathlib, sys, tarfile
archive, target = sys.argv[1:]
with tarfile.open(archive, "r:gz") as handle:
    members = handle.getmembers()
    if not members or len(members) > 10000:
        raise SystemExit("invalid backup member count")
    total_size = 0
    seen = set()
    for member in members:
        path = pathlib.PurePosixPath(member.name)
        canonical = path.as_posix()
        if member.isdir():
            canonical = canonical.rstrip("/")
        if (len(member.name) > 4096 or path.is_absolute() or ".." in path.parts
                or canonical != member.name.rstrip("/")
                or not (member.isdir() or member.isfile())):
            raise SystemExit(f"unsafe backup member: {member.name}")
        if canonical in seen:
            raise SystemExit(f"duplicate backup member: {member.name}")
        seen.add(canonical)
        if path.parts[0] != "payload":
            raise SystemExit(f"unexpected backup root: {member.name}")
        if member.isfile():
            total_size += member.size
            if total_size > 2 * 1024**3:
                raise SystemExit("backup expands beyond the 2 GiB safety limit")
    # Ubuntu 22.04 ships Python 3.10, where extractall(filter=...) is not
    # available.  Every member has already been restricted to regular files
    # and directories below payload/, so the portable call is safe here.
    handle.extractall(target)
PY
    then
        rm -rf "$stage"
        return 1
    fi
    [ -s "$stage/payload/metadata.json" ] && [ -s "$stage/payload/manifest.sha256" ] || { rm -rf "$stage"; return 1; }
    jq -e '.format == 1 and .product == "RR-vps"' "$stage/payload/metadata.json" >/dev/null || { rm -rf "$stage"; return 1; }
    [ "$(jq -r '.manifest_sha256 // empty' "$stage/payload/metadata.json")" = \
      "$(sha256sum "$stage/payload/manifest.sha256" | awk '{print $1}')" ] || { rm -rf "$stage"; return 1; }
    (cd "$stage/payload" && sha256sum -c manifest.sha256 >/dev/null) || { rm -rf "$stage"; return 1; }
    if [ -s "$stage/payload/rootfs/var/lib/rr-nexus/nexus.db" ]; then
        [ "$(sqlite3 "$stage/payload/rootfs/var/lib/rr-nexus/nexus.db" 'PRAGMA quick_check;' 2>/dev/null)" = ok ] || { rm -rf "$stage"; return 1; }
    fi
    if [ -s "$stage/payload/rootfs/etc/rr-cloudflared/token" ] && \
       systemctl cat cloudflared >/dev/null 2>&1 && \
       [ ! -r "${RR_CF_TOKEN_FILE:-/etc/rr-cloudflared/token}" ]; then
        printf '目标服务器已有非 RR 管理的 cloudflared 服务；为避免覆盖其他隧道，恢复已停止。\n' >&2
        rm -rf "$stage"
        return 1
    fi

    mkdir -p "$rollback/rootfs"
    for target in /etc/argo_vmess.conf /etc/sing-box /etc/rr-nexus /etc/rr-naive /etc/rr-update /etc/rr-cloudflared \
        /var/lib/rr-nexus/remote.key; do
        [ -e "$target" ] || continue
        mkdir -p "$rollback/rootfs$(dirname "$target")"
        cp -a -- "$target" "$rollback/rootfs$target" || { rm -rf "$stage"; return 1; }
    done
    rr_backup_sqlite_consistent /var/lib/rr-nexus/nexus.db "$rollback/rootfs/var/lib/rr-nexus/nexus.db" || { rm -rf "$stage"; return 1; }
    rr_backup_capture_crontab "$rollback/crontab.txt" || { rm -rf "$stage"; return 1; }
    systemctl is-active --quiet sing-box 2>/dev/null && : > "$rollback/singbox_was_running"
    systemctl is-active --quiet rr-nexus 2>/dev/null && : > "$rollback/nexus_was_running"
    subscription_server_running && : > "$rollback/subscription_was_running"
    pgrep -f 'cloudflared.*tunnel' >/dev/null 2>&1 && : > "$rollback/argo_was_running"
    systemctl is-enabled --quiet argo-rr-health.timer 2>/dev/null && : > "$rollback/health_timer_was_enabled"
    if [ -s "$stage/payload/rootfs/etc/rr-cloudflared/token" ] && \
       [ -f /etc/systemd/system/cloudflared.service ]; then
        cp -p /etc/systemd/system/cloudflared.service "$rollback/cloudflared.service" || { rm -rf "$stage"; return 1; }
        : > "$rollback/cloudflared_service_was_present"
        systemctl is-active --quiet cloudflared 2>/dev/null && : > "$rollback/cloudflared_was_running"
        systemctl is-enabled --quiet cloudflared 2>/dev/null && : > "$rollback/cloudflared_was_enabled"
    fi

    printf '备份已完整验证。即将恢复配置、设备、额度、流量周期和密钥。\n'
    systemctl stop rr-nexus sing-box >/dev/null 2>&1 || true
    if [ -s "$stage/payload/rootfs/etc/rr-cloudflared/token" ] && \
       systemctl cat cloudflared >/dev/null 2>&1; then
        systemctl disable --now cloudflared >/dev/null 2>&1 || true
        cloudflared service uninstall >/dev/null 2>&1 || argo_prepare_ok=false
    fi
    rr_restore_clear_managed_tree
    if [ "$argo_prepare_ok" = true ] && rr_restore_apply_tree "$stage/payload" && \
       rr_restore_crontab "$stage/payload/crontab.txt" && \
       rr_restore_regenerate_runtime_files && \
       post_update_migrate; then
        result=0
        printf '恢复完成：已根据新服务器 IP、端口和系统环境重新生成运行配置。\n'
    else
        printf '恢复后健康检查失败，正在恢复本机原状态…\n' >&2
        systemctl stop rr-nexus sing-box >/dev/null 2>&1 || true
        if [ -s "$stage/payload/rootfs/etc/rr-cloudflared/token" ]; then
            systemctl disable --now cloudflared >/dev/null 2>&1 || true
            cloudflared service uninstall >/dev/null 2>&1 || true
        fi
        rr_restore_clear_managed_tree
        rr_restore_apply_tree "$rollback" || true
        rr_restore_crontab "$rollback/crontab.txt" || true
        rr_restore_regenerate_runtime_files || true
        RR_UPDATE_TRANSACTION=1 \
        RR_UPDATE_SINGBOX_WAS_RUNNING="$([ -f "$rollback/singbox_was_running" ] && printf true || printf false)" \
        RR_UPDATE_NEXUS_WAS_RUNNING="$([ -f "$rollback/nexus_was_running" ] && printf true || printf false)" \
        RR_UPDATE_SUBSCRIPTION_WAS_RUNNING="$([ -f "$rollback/subscription_was_running" ] && printf true || printf false)" \
        RR_UPDATE_ARGO_WAS_RUNNING="$([ -f "$rollback/argo_was_running" ] && printf true || printf false)" \
        RR_UPDATE_HEALTH_TIMER_WAS_ENABLED="$([ -f "$rollback/health_timer_was_enabled" ] && printf true || printf false)" \
            post_update_migrate >/dev/null 2>&1 || true
        if [ -f "$rollback/cloudflared_service_was_present" ]; then
            install -m 644 "$rollback/cloudflared.service" /etc/systemd/system/cloudflared.service || true
            systemctl daemon-reload >/dev/null 2>&1 || true
            if [ -f "$rollback/cloudflared_was_enabled" ]; then
                systemctl enable cloudflared >/dev/null 2>&1 || true
            else
                systemctl disable cloudflared >/dev/null 2>&1 || true
            fi
            if [ -f "$rollback/cloudflared_was_running" ]; then
                systemctl start cloudflared >/dev/null 2>&1 || true
            else
                systemctl stop cloudflared >/dev/null 2>&1 || true
            fi
        fi
        result=1
    fi
    rm -rf "$stage"
    return "$result"
}

rr_update_preflight() {
    local ok=true free_kb="" db_state="not_installed" config_state="not_installed" lock_state="available" summary=""
    check_supported_os >/dev/null 2>&1 || ok=false
    for command_name in bash awk sed grep sha256sum tar find stat python3 flock systemctl jq sqlite3; do
        command -v "$command_name" >/dev/null 2>&1 || ok=false
    done
    free_kb=$(df -Pk /usr/local 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$free_kb" =~ ^[0-9]+$ ]] && [ "$free_kb" -ge 262144 ] || ok=false
    if [ -r /var/lib/rr-nexus/nexus.db ]; then
        db_state=$(sqlite3 /var/lib/rr-nexus/nexus.db 'PRAGMA quick_check;' 2>/dev/null || echo failed)
        [ "$db_state" = ok ] || ok=false
    fi
    if [ -s /etc/sing-box/config.json ] && [ -x "$SINGBOX_BIN" ]; then
        if "$SINGBOX_BIN" check -c /etc/sing-box/config.json >/dev/null 2>&1; then
            config_state=ok
        else
            config_state=failed
            ok=false
        fi
    fi
    mkdir -p /run/lock
    if ! (exec 9>/run/lock/rr-update.lock; flock -n 9); then
        lock_state=busy
        ok=false
    fi
    if [ "$ok" = true ]; then
        summary="系统、磁盘、数据库、配置和更新锁均通过"
    else
        summary="预检未通过；请运行 rr doctor 查看并修复"
    fi
    jq -cn --argjson ok "$ok" --arg summary "$summary" --arg channel "${RR_UPDATE_CHANNEL:-stable}" \
        --arg disk_free_mb "$(( ${free_kb:-0} / 1024 ))" --arg database "$db_state" \
        --arg singbox_config "$config_state" --arg update_lock "$lock_state" \
        '{ok:$ok,summary:$summary,channel:$channel,disk_free_mb:($disk_free_mb|tonumber),database:$database,singbox_config:$singbox_config,update_lock:$update_lock}'
    [ "$ok" = true ]
}

rr_set_update_channel() {
    local channel="${1:-}" temporary=""
    case "$channel" in stable|beta) ;; *) printf '更新通道只能是 stable 或 beta。\n' >&2; return 2 ;; esac
    mkdir -p /etc/rr-update || return 1
    temporary=$(mktemp /etc/rr-update/.channel.XXXXXX) || return 1
    if ! printf '%s\n' "$channel" > "$temporary" || ! chmod 600 "$temporary" || \
       ! mv -f "$temporary" /etc/rr-update/channel; then
        rm -f "$temporary"
        return 1
    fi
    printf '更新通道已切换为 %s；下次检查更新时生效。\n' "$channel"
}
