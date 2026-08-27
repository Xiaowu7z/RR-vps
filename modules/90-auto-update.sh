# shellcheck shell=bash
# 本文件由 RR-vps 主入口加载，请勿单独执行。

# ==========================================
write_auto_update_worker() {
    local worker_path="/usr/local/bin/auto_update_sub.py"
    local worker_tmp=""
    worker_tmp=$(mktemp "${worker_path%/*}/.auto_update_sub.py.XXXXXX") || return 1
    cat > "$worker_tmp" <<'PYEOF'
#!/usr/bin/env python3
# RR_AUTO_UPDATE_VERSION=8
import base64
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import uuid as uuidlib

CONFIG_FILE = "/etc/argo_vmess.conf"
LOG_FILE = "/var/log/auto_update_sub.log"
SUB_ROOT = "/tmp/sub_server"
MAX_LOG_BYTES = 1024 * 1024


def log(msg):
    try:
        if os.path.getsize(LOG_FILE) > MAX_LOG_BYTES:
            temporary = f"{LOG_FILE}.{os.getpid()}.tmp"
            with open(LOG_FILE, "rb") as current:
                current.seek(-MAX_LOG_BYTES // 2, os.SEEK_END)
                tail = current.read()
            descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as trimmed:
                trimmed.write(tail)
                trimmed.flush()
                os.fsync(trimmed.fileno())
            os.replace(temporary, LOG_FILE)
    except (FileNotFoundError, OSError):
        try:
            os.unlink(temporary)
        except (NameError, FileNotFoundError, OSError):
            pass
    with open(LOG_FILE, "a", encoding="utf-8") as log_file:
        log_file.write(msg + "\n")
    os.chmod(LOG_FILE, 0o600)


def ensure_subscription_root():
    """Atomically create or verify the root-owned, non-symlink publish root."""
    try:
        os.mkdir(SUB_ROOT, mode=0o700)
    except FileExistsError:
        pass
    root_stat = os.lstat(SUB_ROOT)
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != 0:
        raise RuntimeError("unsafe subscription root")
    os.chmod(SUB_ROOT, 0o700)
    root_stat = os.lstat(SUB_ROOT)
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != 0:
        raise RuntimeError("subscription root changed during validation")


try:
    with open(CONFIG_FILE, "r", encoding="utf-8") as config_file:
        env = {}
        for line in config_file:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, raw_value = line.split("=", 1)
                # 配置由 Bash printf %q 写入；shlex 可正确还原 ''、引号和反斜杠转义，
                # 同时不会执行命令替换或任意 shell 代码。
                parsed = shlex.split(raw_value, posix=True)
                if len(parsed) > 1:
                    raise ValueError(f"Invalid config value for {key}")
                env[key] = parsed[0] if parsed else ""
except Exception as exc:
    log(f"Config read error: {exc}")
    sys.exit(1)

try:
    ensure_subscription_root()
except Exception as exc:
    log(f"Subscription root error: {exc}")
    sys.exit(1)


def public_ip(version):
    urls = {
        4: ("https://api.ipify.org", "https://icanhazip.com"),
        6: ("https://api6.ipify.org", "https://icanhazip.com"),
    }
    for url in urls[version]:
        try:
            result = subprocess.run(
                ["curl", f"-{version}", "-fsS", "--connect-timeout", "4", "--max-time", "6", url],
                capture_output=True,
                text=True,
                timeout=8,
                check=False,
            )
            candidate = result.stdout.strip()
            address = ipaddress.ip_address(candidate)
            if address.version == version and address.is_global:
                return candidate
        except Exception:
            continue
    return ""


def valid_global_ip(value, version):
    try:
        address = ipaddress.ip_address(value)
        return address.version == version and address.is_global
    except Exception:
        return False


def local_ipv6_addresses():
    public_addr = ""
    ula_addr = ""
    try:
        result = subprocess.run(
            ["ip", "-o", "-6", "addr", "show", "scope", "global"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        for line in result.stdout.splitlines():
            fields = line.split()
            if "inet6" not in fields:
                continue
            value = fields[fields.index("inet6") + 1].split("/", 1)[0]
            address = ipaddress.ip_address(value)
            if address.is_global and not public_addr:
                public_addr = value
            if address in ipaddress.ip_network("fc00::/7") and not ula_addr:
                ula_addr = value
    except Exception:
        pass
    return public_addr, ula_addr


ipv4_egress = public_ip(4)
ipv6_egress = public_ip(6)
ipv4_override = env.get("ENTRY_IPV4_ADDRESS", "").strip()
ipv6_override = env.get("ENTRY_IPV6_ADDRESS", "").strip()
local_ipv6_public, local_ipv6_ula = local_ipv6_addresses()

ipv4 = ipv4_override if valid_global_ip(ipv4_override, 4) else ipv4_egress
if valid_global_ip(ipv6_override, 6):
    ipv6 = ipv6_override
    ipv6_source = "manual"
elif local_ipv6_public:
    ipv6 = local_ipv6_public
    ipv6_source = "interface"
elif local_ipv6_ula:
    # LXD/NAT66 的外部探测值属于宿主机出口，不能用作容器入站节点地址。
    ipv6 = ""
    ipv6_source = "nat66-manual-required"
else:
    ipv6 = ipv6_egress
    ipv6_source = "external-fallback"
entry_mode = env.get("ENTRY_IP_MODE", "auto")

if entry_mode == "ipv4":
    server_ip_raw = ipv4
elif entry_mode == "ipv6":
    server_ip_raw = ipv6
else:
    server_ip_raw = ipv4 or ipv6

if not server_ip_raw:
    log(
        f"No inbound address available for ENTRY_IP_MODE={entry_mode}; "
        f"ipv6_source={ipv6_source}"
    )
    sys.exit(1)

server_ip_uri = f"[{server_ip_raw}]" if ipaddress.ip_address(server_ip_raw).version == 6 else server_ip_raw
try:
    uuid = env.get("UUID", "")
    uuidlib.UUID(uuid)
except (ValueError, AttributeError, TypeError):
    log("Missing or invalid UUID in config")
    sys.exit(1)
argo_domain = env.get("ARGO_DOMAIN")
cdn_ip = env.get("CDN_IP")
cert_sha256 = env.get("CERT_SHA256", "")

argo_edge_port = env.get("ARGO_EDGE_PORT", "443")
base_vmess = {
    "v": "2", "ps": "", "add": cdn_ip, "port": argo_edge_port,
    "id": uuid, "aid": "0", "scy": "auto", "net": "ws",
    "type": "", "host": argo_domain, "path": f"/{uuid}-vm",
    "tls": "tls", "sni": argo_domain, "fp": "chrome", "alpn": "",
}


def make_vmess(ps, addr):
    cfg = base_vmess.copy()
    cfg["ps"] = ps
    cfg["add"] = addr
    json_str = json.dumps(cfg, separators=(",", ":"))
    encoded = base64.b64encode(json_str.encode("utf-8")).decode("utf-8")
    return f"vmess://{encoded}"


def make_vmess_direct(ps, addr, port):
    cfg = base_vmess.copy()
    cfg.update({
        "ps": ps, "add": addr, "port": str(port), "host": "www.bing.com",
        "sni": "www.bing.com", "allowInsecure": "1", "insecure": "1",
    })
    json_str = json.dumps(cfg, separators=(",", ":"))
    encoded = base64.b64encode(json_str.encode("utf-8")).decode("utf-8")
    return f"vmess://{encoded}"


def make_vless(ps, port, pubkey, sid):
    return f"vless://{uuid}@{server_ip_uri}:{port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=apple.com&fp=chrome&pbk={pubkey}&sid={sid}&type=tcp&headerType=none#{ps}"


def make_hy2(ps, port, hop_ports=""):
    hop_extra = ""
    if hop_ports:
        hop_extra = "&mport=" + hop_ports.replace(":", "-")
    return f"hysteria2://{uuid}@{server_ip_uri}:{port}?security=tls&alpn=h3&insecure=1&sni=www.bing.com&pinSHA256={cert_sha256}&obfs=salamander&obfs-password={uuid}{hop_extra}#{ps}"


def make_tuic5(ps, port):
    return f"tuic://{uuid}:{uuid}@{server_ip_uri}:{port}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&insecure=1&allow_insecure=1#{ps}"


def make_anytls(ps, port):
    return f"anytls://{uuid}@{server_ip_uri}:{port}?sni=www.bing.com&insecure=1#{ps}"


all_links = []
vm_enabled = env.get("VM_ENABLED", "true") != "false"
vm_tls_enabled = env.get("VM_TLS_ENABLED", "false") == "true"

if vm_enabled:
    if vm_tls_enabled:
        all_links.append(make_vmess_direct("Vmess-TLS-固定", server_ip_raw, env.get("PORT", "443")))
    elif not argo_domain:
        log("Missing ARGO_DOMAIN while Argo Vmess is enabled")
    else:
        all_links.append(make_vmess(f"Argo优选-固定({cdn_ip})", cdn_ip))

    added_addrs = {cdn_ip}

    def get_cname(domain):
        try:
            result = subprocess.run(
                ["dig", "+short", "CNAME", domain, "+time=2", "+tries=1"],
                capture_output=True,
                text=True,
                timeout=4,
                check=False,
            )
            output = result.stdout.strip()
            if output:
                cname = output.split("\n")[0].rstrip(".")
                if re.match(r"^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$", cname):
                    return cname
        except Exception as exc:
            log(f"DNS query failed for {domain}: {exc}")
        return None

    preferred_addrs = []
    if not vm_tls_enabled and argo_domain:
        cname_domains = [f"yg{index}.ygkkk.dpdns.org" for index in range(1, 14)]
        # 并行查询将最坏等待从约一分钟缩短到单个 DNS 超时窗口。
        with ThreadPoolExecutor(max_workers=7) as executor:
            cname_results = list(executor.map(get_cname, cname_domains))
        for cname in cname_results:
            if cname and cname not in added_addrs:
                all_links.append(make_vmess(f"Argo优选-{len(all_links)}({cname})", cname))
                added_addrs.add(cname)
                preferred_addrs.append(cname)

    # 优选结果落盘，供面板设备订阅生成 Argo 优选副节点（设备凭据版）
    preferred_file = os.path.join(SUB_ROOT, "preferred_cnames.txt")
    try:
        if preferred_addrs:
            with open(preferred_file, "w", encoding="utf-8") as preferred_handle:
                preferred_handle.write("\n".join(preferred_addrs) + "\n")
        else:
            try:
                os.remove(preferred_file)
            except FileNotFoundError:
                pass
    except OSError:
        pass

vl_enabled = env.get("VL_ENABLED", "false")
vl_port = env.get("VL_PORT", "0")
pubkey = env.get("PUBLIC_KEY", "")
short_id = env.get("SHORT_ID", "")
if vl_enabled == "true" and vl_port != "0" and pubkey and short_id:
    all_links.append(make_vless("VL-REALITY-固定", vl_port, pubkey, short_id))

hy2_enabled = env.get("HY2_ENABLED", "false")
hy2_port = env.get("HY2_PORT", "0")
if hy2_enabled == "true" and hy2_port != "0" and re.fullmatch(r"[0-9a-f]{64}", cert_sha256):
    hop_ports = env.get("HY2_HOP_PORTS", "").strip()
    if not hop_ports:
        try:
            hop_raw = subprocess.run(
                ["iptables", "-t", "nat", "-nL", "PREROUTING"],
                capture_output=True,
                text=True,
                check=False,
            )
            hop_lines = [line for line in hop_raw.stdout.split("\n") if "dpt" in line and f":{hy2_port}" in line]
            extracted = []
            for line in hop_lines:
                match = re.search(r"dpts?:(\d+(?::\d+)?)", line)
                if match and match.group(1) not in extracted:
                    extracted.append(match.group(1))
            hop_ports = ",".join(extracted)
        except Exception:
            hop_ports = ""
    all_links.append(make_hy2("HY2-固定", hy2_port, hop_ports))
elif hy2_enabled == "true" and hy2_port != "0":
    log("Missing or invalid CERT_SHA256; skipped invalid Hysteria2 link")

tu5_enabled = env.get("TU5_ENABLED", "false")
tu5_port = env.get("TU5_PORT", "0")
if tu5_enabled == "true" and tu5_port != "0":
    all_links.append(make_tuic5("TU5-固定", tu5_port))

an_enabled = env.get("AN_ENABLED", "false")
an_port = env.get("AN_PORT", "0")
if an_enabled == "true" and an_port != "0":
    all_links.append(make_anytls("ANYTLS-固定", an_port))

# NAIVE-SUPPORT: NaiveProxy 链接（naive+https://用户:密码@域名:端口#名称）
naive_enabled = env.get("NAIVE_ENABLED", "false") == "true"
naive_port = env.get("NAIVE_PORT", "0")
naive_user = env.get("NAIVE_USER", "")
naive_pass = env.get("NAIVE_PASS", "")
naive_domain = env.get("NAIVE_DOMAIN", "")
naive_mode = env.get("NAIVE_MODE", "h2")
naive_quic_cc = env.get("NAIVE_QUIC_CC", "bbr")
if naive_enabled and naive_port != "0" and naive_user and naive_pass and naive_domain:
    if naive_mode != "h3":
        all_links.append(f"naive+https://{naive_user}:{naive_pass}@{naive_domain}:{naive_port}#RR-Naive-H2")
    if naive_mode != "h2":
        all_links.append(f"naive+quic://{naive_user}:{naive_pass}@{naive_domain}:{naive_port}?congestion_control={naive_quic_cc}#RR-Naive-H3")

sub_content = "\n".join(all_links)
final_b64 = base64.b64encode(sub_content.encode("utf-8")).decode("utf-8")

target_dir = os.path.join(SUB_ROOT, uuid)
os.makedirs(target_dir, mode=0o700, exist_ok=True)
for filename, content in (("jhsub.txt", sub_content), ("jhsub_encoded.txt", final_b64)):
    temp_path = os.path.join(target_dir, f".{filename}.{os.getpid()}.tmp")
    final_path = os.path.join(target_dir, filename)
    with open(temp_path, "w", encoding="utf-8") as output_file:
        output_file.write(content)
    os.chmod(temp_path, 0o600)
    os.replace(temp_path, final_path)

# 客户端拆分地址与通用订阅使用同一份刚更新的 URI；自动优选刷新后不能
# 只更新 jhsub 而留下旧的 NekoBox/v2rayN/Shadowrocket 内容。
for filename in ("client-v2rayn.txt", "client-v2rayng.txt", "client-sr.txt", "client-nekobox.txt"):
    temp_path = os.path.join(target_dir, f".{filename}.{os.getpid()}.tmp")
    final_path = os.path.join(target_dir, filename)
    with open(temp_path, "w", encoding="utf-8") as output_file:
        output_file.write(final_b64)
    os.chmod(temp_path, 0o600)
    os.replace(temp_path, final_path)

log(
    f"Updated subscription with {len(all_links)} nodes; "
    f"entry_mode={entry_mode}; ipv6_source={ipv6_source}"
)

# 主订阅更新后同步面板设备订阅（含 Argo 优选副节点与最新 Argo 域名）
try:
    sync_result = subprocess.run(
        # 绝对路径：cron 环境 PATH 只有 /usr/bin:/bin，裸 "rr" 会 FileNotFoundError（D10）
        ["/usr/local/bin/rr", "--sync-devices"],
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    if sync_result.returncode != 0:
        log(f"Device subscription sync skipped (rc={sync_result.returncode})")
except Exception as exc:
    log(f"Device subscription sync error: {exc}")
PYEOF
    if ! python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"), sys.argv[1], "exec")' \
        "$worker_tmp" >/dev/null 2>&1; then
        rm -f "$worker_tmp"
        echo -e "${RED}[错误] 自动订阅程序语法校验失败，旧程序未改动。${RESET}" >&2
        return 1
    fi
    chmod 755 "$worker_tmp" || { rm -f "$worker_tmp"; return 1; }
    mv -f "$worker_tmp" "$worker_path"
}

toggle_auto_update() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}请先选择 1 进行安装！${RESET}"
        sleep 2
        return
    fi
    load_config_with_defaults || return 1

    clear
    echo -e "=================================================="
    echo -e "${GREEN}      自动优选更新订阅设置 (1固定 + 13动态)${RESET}"
    echo -e "=================================================="
    echo -e "说明：开启后，后台每小时自动抓取最新的 CNAME 优选节点，"
    echo -e "并与您的固定节点合并为包含 1+N 个节点的订阅链接。"
    echo -e "关闭后恢复为单一固定节点。"
    echo -e "=================================================="
    echo -e "  1. 开启自动更新 (推荐)"
    echo -e "  2. 关闭自动更新 (恢复固定单节点)"
    echo -e "  0. 返回主菜单"
    echo -e "=================================================="
    read -p "请选择操作 [0-2]: " auto_choice

    case "$auto_choice" in
        1)
            if ! command -v dig &> /dev/null; then
                echo -e "${RED}未找到 dig 命令，请先执行安装（选项1）！${RESET}"
                sleep 2
                return
            fi
            # 依赖检查：优选副节点（Argo CNAME）仅在 Vmess-ws/Argo 隧道模式下生成
            if [ "$VM_ENABLED" = "false" ] || [ "$VM_TLS_ENABLED" = "true" ]; then
                echo -e "${YELLOW}[提示] 自动优选副节点仅在 Vmess-ws/Argo 隧道模式下生效。${RESET}"
                echo -e "${YELLOW}       当前 VMess 未使用 Argo 隧道，开启后副节点不会出现在订阅中。${RESET}"
                echo -e "${YELLOW}       如需副节点，请先在协议节点管理（菜单 9→5）切换为 Argo 模式。${RESET}"
            fi

            echo -e "\n${YELLOW}正在配置自动化环境与脚本...${RESET}"
            local cron_before=""
            local cron_after=""
            local worker_backup=""
            local had_worker=false
            cron_before=$(mktemp /tmp/rr-crontab-before.XXXXXX) || return 1
            cron_after=$(mktemp /tmp/rr-crontab-after.XXXXXX) || { rm -f "$cron_before"; return 1; }
            worker_backup=$(mktemp /tmp/rr-auto-worker.XXXXXX) || {
                rm -f "$cron_before" "$cron_after"
                return 1
            }
            crontab -l > "$cron_before" 2>/dev/null || : > "$cron_before"
            if [ -f /usr/local/bin/auto_update_sub.py ]; then
                cp -p /usr/local/bin/auto_update_sub.py "$worker_backup" || {
                    rm -f "$cron_before" "$cron_after" "$worker_backup"
                    return 1
                }
                had_worker=true
            fi
            if ! systemctl enable --now cron >/dev/null 2>&1; then
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                echo -e "${RED}[失败] cron 服务无法启用，现有订阅与定时任务未改动。${RESET}"
                sleep 2
                return 1
            fi
            if ! write_auto_update_worker; then
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                echo -e "${RED}[失败] 自动订阅程序写入失败，旧程序与定时任务未改动。${RESET}"
                sleep 2
                return 1
            fi
            echo -e "${YELLOW}正在首次抓取节点池...${RESET}"
            if ! python3 /usr/local/bin/auto_update_sub.py; then
                echo -e "${RED}[失败] 首次订阅生成失败，未写入定时任务。${RESET}"
                if [ "$had_worker" = true ]; then
                    cp -p "$worker_backup" /usr/local/bin/auto_update_sub.py
                else
                    rm -f /usr/local/bin/auto_update_sub.py
                fi
                generate_node_and_sub >/dev/null 2>&1 || true
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                sleep 2
                return
            fi

            awk '!/auto_update_sub.py/' "$cron_before" > "$cron_after"
            # PATH 前置补齐：rr 在 /usr/local/bin；ip/iptables 在 /usr/sbin——cron 默认 PATH 均不含（D10）
            printf '%s\n' '0 * * * * PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin /usr/bin/python3 /usr/local/bin/auto_update_sub.py >> /var/log/auto_update_sub.log 2>&1' >> "$cron_after"
            if ! crontab "$cron_after"; then
                if [ "$had_worker" = true ]; then
                    cp -p "$worker_backup" /usr/local/bin/auto_update_sub.py
                else
                    rm -f /usr/local/bin/auto_update_sub.py
                fi
                # 首次运行可能已写入动态列表；按变更前状态重新生成一次。
                generate_node_and_sub >/dev/null 2>&1 || true
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                echo -e "${RED}[失败] 定时任务写入失败，已恢复原程序和订阅状态。${RESET}"
                sleep 2
                return 1
            fi
            rm -f "$cron_before" "$cron_after" "$worker_backup"

            echo -e "\n${GREEN}[成功] 自动更新已开启！${RESET}"
            sleep 3
            ;;
        2)
            local cron_before=""
            local cron_after=""
            local worker_backup=""
            local had_worker=false
            cron_before=$(mktemp /tmp/rr-crontab-before.XXXXXX) || return 1
            cron_after=$(mktemp /tmp/rr-crontab-after.XXXXXX) || { rm -f "$cron_before"; return 1; }
            worker_backup=$(mktemp /tmp/rr-auto-worker.XXXXXX) || {
                rm -f "$cron_before" "$cron_after"
                return 1
            }
            crontab -l > "$cron_before" 2>/dev/null || : > "$cron_before"
            if [ -f /usr/local/bin/auto_update_sub.py ]; then
                cp -p /usr/local/bin/auto_update_sub.py "$worker_backup" || {
                    rm -f "$cron_before" "$cron_after" "$worker_backup"
                    return 1
                }
                had_worker=true
            fi
            awk '!/auto_update_sub.py/' "$cron_before" > "$cron_after"
            if ! crontab "$cron_after"; then
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                echo -e "${RED}[失败] 无法更新定时任务，自动更新保持原状态。${RESET}"
                sleep 2
                return 1
            fi
            rm -f /usr/local/bin/auto_update_sub.py
            rm -f /tmp/sub_server/preferred_cnames.txt

            if ! generate_node_and_sub; then
                [ "$had_worker" = true ] && cp -p "$worker_backup" /usr/local/bin/auto_update_sub.py
                crontab "$cron_before" >/dev/null 2>&1 || true
                [ "$had_worker" = true ] && python3 /usr/local/bin/auto_update_sub.py >/dev/null 2>&1 || true
                rm -f "$cron_before" "$cron_after" "$worker_backup"
                echo -e "${RED}[失败] 固定订阅恢复失败，已回滚自动更新状态。${RESET}"
                sleep 2
                return 1
            fi
            rm -f "$cron_before" "$cron_after" "$worker_backup"

            echo -e "${GREEN}[成功] 自动更新已关闭！${RESET}"
            sleep 2
            ;;
        0) return ;;
        *) echo -e "${RED}输入无效！${RESET}"; sleep 1 ;;
    esac
}
