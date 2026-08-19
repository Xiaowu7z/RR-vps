# RR-vps

[中文](README.md) · [English](README_EN.md) · [RR-vps Official Channel](https://t.me/GMgP4NG7lncwZGE1)

RR-vps is a multi-protocol Sing-box management script for Debian and Ubuntu VPS instances. Users keep one simple `rr` command, while program modules, persistent settings, runtime configuration, and subscriptions are stored separately for safer updates and rollback.

> **Disclaimer: This project is provided solely for technical exchange, theoretical study, and research on managing your own servers. It does not provide any network access service. Do not use it for any purpose that violates local laws, your VPS provider's terms of service, or Cloudflare's usage policies. Users bear full responsibility for their own use; the author assumes no liability for any consequences of misuse.**

> Current version: **6.6.18** · [Full changelog](CHANGELOG.md) · [GitHub Releases](https://github.com/Xiaowu7z/RR-vps/releases)

## One-command installation

Supported systems (full test matrix passed, 2026-08):

| System | Support | Notes |
| --- | --- | --- |
| **Debian 12 (bookworm)** | ⭐ Recommended | Most thoroughly verified; first choice |
| Ubuntu 22.04 (jammy) | ✅ Supported | Fully tested |
| Ubuntu 24.04 (noble) | ✅ Supported | Fully tested |

Other Debian/Ubuntu derivatives are untested and not guaranteed.

Become root first:

```bash
sudo -i
```

Install with curl (recommended):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/main/install.sh)
```

Or use wget:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/main/install.sh)
```

Open the control panel:

```bash
rr
```

### First-time installation order (important)

1. **Step 1: Install the node first** — open `rr` and choose option `1` to install the Sing-box core and configure protocols (VLESS Reality / Hysteria2 / TUIC / AnyTLS, etc.). You may also initialize the management framework only, without enabling any node yet.
2. **Step 2: Then install the RR Nexus console** — after node configuration is complete, choose option `14` from the main menu to install the optional management console. The console reads ports and generates device subscriptions from the node configuration, so it must be installed after the node.
3. Console access modes (local SSH tunnel / public domain / public direct) are chosen inside the `14` menu; see "RR Nexus · XingShu" below.

Show the installed version:

```bash
rr --version
```

Choose menu option `8` to update. Choose option `6` and enter `UNINSTALL` to remove RR-vps. The uninstall result prints the project URL and reinstall command for future use.

## Companion tool: CF Domain Optimizer (Android)

An Android tool that scans Cloudflare edge IPs and domains to find the fastest combination for your node subscriptions. Native Kotlin, minimal permissions (network only), no ads.

- Latest **2.6.0** APK: [assets/cf-optimizer/CF-Optimizer-2.6.0-debug.apk] (2.5.0 archive: [assets/cf-optimizer/CF-Optimizer-2.5.0-debug.apk](assets/cf-optimizer/CF-Optimizer-2.5.0-debug.apk)
- Full source: [assets/cf-optimizer/](assets/cf-optimizer/) (`app/` project + `test/` suite + `build.sh` + 134-domain pool)
- Features: preferred-IP probing, triple-metric throughput, IPv4/IPv6 pipelines, baseline champion comparison, 50-entry history
- Details: [assets/cf-optimizer/README.md](assets/cf-optimizer/README.md)

## Features

- Free protocol selection during first install, including a framework-only choice
- Vmess-WS over temporary or named Cloudflare Tunnel
- Direct Vmess over TLS
- VLESS Reality Vision
- Hysteria2 with configurable port hopping and interval
- TUIC v5
- AnyTLS
- NaiveProxy (sing-box 1.13 native naive inbound, HTTP/2 + padding camouflage, real Let's Encrypt certificate, official naiveproxy client supported; Clash lacks native naive support and is skipped automatically)
- Independent protocol switches and ports
- Independent IPv4/IPv6 inbound and outbound preferences
- Public subscription-port mapping for NAT/LXD VPS instances
- Sing-box validation, health checks, and guarded automatic restart
- Synchronized share links, Base64, Sing-box client JSON, and Clash Meta YAML
- Transactional modular updates with SHA256 verification, Bash syntax checks, migration, and rollback
- No forced reservation of local port 443 for Argo
- Optional RR Nexus web console with local-only or public HTTPS access
- Per-device credentials, protocol links, QR codes, enable/disable state, and expiry
- Panel live server status page: per-second CPU / memory / disk / network, zero-dependency `/proc` sampling
- Panel firewall settings page: port toggles, IPv4/IPv6 inbound/outbound split, SSH port protection, and a permission tutorial
- Panel streaming unlock checker: unlock status and region for Netflix / Disney+ / YouTube Premium and more
- Panel brute-force protection: dual-dimension IP + account lockout, 5 failures in 30 minutes, exponential backoff, persisted state; reset via script menu 14 → 2
- Panel brute-force protection: dual-dimension IP + account lockout, 5 failures in 30 minutes, exponential backoff, persisted state; reset via script menu 14 → 2
- Device subscriptions in three formats (universal link / Sing-box full config / Clash Meta YAML), automatic alternate-node optimization sync, live Argo domain display

## Client tools and protocol support

RR-vps subscriptions work with these mainstream client tools:

| Tool | Platform | Download |
|---|---|---|
| Official sing-box clients (SFI / SFM / SFA) | iOS / macOS / Android | [GitHub](https://github.com/SagerNet/sing-box) · [Clients page](https://sing-box.sagernet.org/installation/clients/) |
| mihomo (Clash Meta core) | Windows / Linux / macOS | [GitHub](https://github.com/MetaCubeX/mihomo) |
| Clash Verge Rev (mihomo GUI) | Windows / Linux / macOS | [GitHub](https://github.com/clash-verge-rev/clash-verge-rev) |
| FlClash (mihomo GUI) | Windows / Linux / macOS / Android | [GitHub](https://github.com/chen08209/FlClash) |
| v2rayN | Windows / Linux / macOS | [GitHub](https://github.com/2dust/v2rayN) |
| v2rayNG | Android | [GitHub](https://github.com/2dust/v2rayNG) |
| Shadowrocket (paid) | iOS | [App Store](https://apps.apple.com/app/shadowrocket/id932747118) |
| NekoBox / NekoRay | Android / Windows / Linux | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) · [NekoRay](https://github.com/MatsuriDayo/nekoray) |
| Hiddify | All platforms | [GitHub](https://github.com/hiddify/hiddify-app) |

Protocol support matrix:

| Protocol | sing-box | mihomo family | v2rayN / v2rayNG | Shadowrocket | NekoBox |
|---|---|---|---|---|---|
| Vmess-WS (Argo / direct) | ✅ | ✅ | ✅ | ✅ | ✅ |
| VLESS Reality | ✅ | ✅ | ✅ | ✅ | ✅ |
| Hysteria2 | ✅ | ✅ | ✅ | ✅ | ✅ |
| TUIC v5 | ✅ | ✅ | ✅ | ✅ | ✅ |
| AnyTLS | ✅ | ✅ (not with Reality) | ✅ (recent versions) | ✅ (2.2.65+) | ✅ (1.3.8+) |

Tip: for fast recovery after screen lock/suspend, enable the active heartbeat mode (main menu 9 → 11) and prefer clients with sing-box core 1.13+.

## Optional RR Nexus console

Choose menu option `14`, then select one access mode:

| Mode | Entry point | Security boundary |
|---|---|---|
| Local (recommended) | `127.0.0.1:7900` through an SSH port forward | No public management port and no public certificate requirement |
| Public domain | `https://` on a domain you control | The backend still binds only to loopback; Nginx proxies HTTPS and installation succeeds only after a Let's Encrypt certificate is issued |
| Public direct | `https://` on the server IP with a self-signed certificate | Browser shows a certificate warning; the user must trust it manually |

Public mode never offers bare-IP login or plain HTTP. RR Nexus uses Argon2id password hashes, application and Nginx login rate limits, CSRF protection, HttpOnly/SameSite sessions, Secure cookies in public mode, eight one-time recovery codes, and an audit log.

Each device is an access identity, not another administrator. It receives an independent UUID and protocol links. Disabling, deleting, or expiring a device transactionally rebuilds the Sing-box user list. Public mode exposes a random-token subscription URL for each device; local mode also syncs each device's personal subscription under the main subscription address (`http://SERVER-IP:SUBSCRIPTION-PORT/nexus/<random-token>.txt`) without exposing the management port.

For local mode, run the command printed by the installer on your **own computer**, enter the server root password when prompted, keep that terminal open, and browse to `http://127.0.0.1:7900`. The command uses `UserKnownHostsFile=/dev/null`, `StrictHostKeyChecking=no`, and an SSH `-L` forward; the console displays the exact command for the configured server and port.

RR Nexus downloads a SHA256-verified core built by the project GitHub Actions workflow from the official stable Sing-box source with the additional `with_v2ray_api` tag. It polls counters named by device ID every five seconds, persists upload and download totals, and revokes access when a quota is reached. This is intended for operational usage and quota management, not carrier-grade billing; an abnormal Sing-box exit or the instant around a reload can still lose a small uncollected delta.

## Which protocol fits my VPS?

The route sets the performance ceiling. A protocol cannot turn a congested route into a premium private line. Argo is a Cloudflare tunnel, not a VPS route; “PRO” is normally a provider product tier, not a protocol.

| VPS or network condition | Try first | Why |
|---|---|---|
| CN2 GIA, CMI/CMIN2, AS9929, or another China-optimized direct route | Reality → AnyTLS → HY2 | Keeps the low-latency direct path and avoids an unnecessary relay |
| Ordinary Tier 1 route with poor peak-hour reachability | Argo/Vmess-WS | Cloudflare may improve reachability and hides the origin address |
| UDP works well and high throughput or loss recovery matters | HY2 | Better tolerance of variable networks; optional port hopping |
| Stable UDP and latency-sensitive traffic | TUIC v5 | QUIC-based option for responsive connections |
| UDP is blocked or heavily shaped but TCP is good | Reality or AnyTLS | Does not depend on UDP |
| NAT/LXD with a small set of mapped ports | Reality/AnyTLS; HY2 only with correct UDP mapping | Easier port planning and troubleshooting |
| IPv6-only public ingress | Reality, AnyTLS, or HY2 as client IPv6 support allows | RR-vps separates ingress and egress address-family choices |

### Practical selection order

1. On a clearly optimized VPS, test Reality during local peak hours.
2. If direct TCP is stable but throughput is limited and UDP is available, test HY2.
3. If UDP is shaped or unreliable, use AnyTLS instead of repeatedly changing HY2 ports.
4. If an ordinary international route performs poorly, compare Argo/Vmess-WS against direct protocols.
5. Keep only the protocols that provide a real benefit. Enabling everything adds ports and troubleshooting work; it does not make the server faster.

Judge a route using sustained downloads, video seeking, calls, packet loss, and jitter from the actual client ISP. Test outbound and return paths separately. A route advertised as “optimized” may cover only one direction or one mainland carrier.

## Understanding China-optimized routes

| Label | Typical focus | Notes |
|---|---|---|
| CN2 GIA | China Telecom and multi-carrier premium products | Usually priced for lower loss and more consistent direct access |
| CMI / CMIN2 | China Mobile users | Multi-carrier quality still depends on peering and the exact return route |
| AS9929 | China Unicom premium bearer products | China Unicom describes AS9929 as its premium bearer network |
| Multi-carrier premium return route | Mixed Telecom/Mobile/Unicom users | Verify all three carriers, both directions, and peak-hour tests |
| Ordinary Tier 1 | Global capacity and lower cost | Usually no mainland-China routing guarantee |

DMIT's current naming is a useful example: Premium/Pro products emphasize mainland-China routing, Eyeball products balance price and China-user reachability, and Tier 1 products prioritize general global capacity. This explains product categories and is not a permanent provider endorsement.

Official references:

- [Cloudflare Quick Tunnel limitations](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Create a named Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
- [DMIT network product categories](https://www.dmit.io/pages/cloud-instance)
- [China Unicom international AS9929 / Premium DIA](https://eu.chinaunicomglobal.com/products-dia)
- [China Mobile International IP Transit / DIA](https://iconnect.cmi.chinamobile.com/en/product/i-connect-data/ip-transit-dia)

Temporary Quick Tunnels are convenient for testing and personal use, but the hostname can change and Cloudflare applies specific limits. A named tunnel with an account token is the better long-term choice. Cloudflare performance depends on both the VPS-to-Cloudflare and client-to-Cloudflare paths and is not guaranteed to beat a premium direct route.

## Compatibility

| Item | Support |
|---|---|
| Debian | 12 or newer; Debian 12 is a primary target |
| Ubuntu | 22.04 or newer; 22.04 and 24.04 are primary targets |
| CPU | amd64/x86_64 and arm64/aarch64 |
| Virtualization | KVM recommended; NAT/LXD requires correct TCP/UDP mappings |
| Requirements | root, APT, systemd, and access to GitHub/Cloudflare download endpoints |
| Not currently supported | Alpine, CentOS/RHEL families, and minimal systems without systemd |

Restricted OpenVZ, container, or NAT environments may block BBR, sysctl, iptables, or UDP. RR-vps safely skips unavailable tuning where possible, but the host and port mappings ultimately decide which protocols can work.

## Modular layout and safe updates

```text
/usr/local/bin/rr                  stable command entry point
/usr/local/lib/rr/manifest.sha256  release integrity manifest
/usr/local/lib/rr/modules/         system, config, protocol, subscription, update, and UI modules
/usr/local/lib/rr/nexus/           optional RR Nexus backend and static console
/etc/argo_vmess.conf               UUID, ports, keys, and user choices
/etc/sing-box/config.json          generated Sing-box runtime configuration
/etc/rr-nexus/nexus.json           access-mode and listener settings
/var/lib/rr-nexus/nexus.db         administrator, device, and audit database
/tmp/sub_server/                   generated subscription files
```

Option 8 replaces program modules without resetting persistent settings. Updates run in two stages: a release bundle is downloaded first for a fast hot-update (integrity, member count, and version are verified to block stale CDN packages); on failure it falls back to per-file download. New modules are verified with SHA256 and Bash syntax checks, both the launcher and module copies are replaced together, configuration migration runs, and subscriptions plus the auto-optimization worker are refreshed automatically. Any failure restores the previous launcher, modules, configuration, core, services, and subscriptions; node and panel services restart automatically after a successful upgrade.

## Safety notes

- Start with one or two protocols and add more only when they solve a measured problem.
- Never assign the same IP/port pair to two services. The local Argo origin does not need port 443.
- Refresh your client subscription after changing protocol ports, address-family mode, or subscription mapping.
- Never publish `/etc/argo_vmess.conf`, Reality private keys, UUIDs, Tunnel Tokens, complete subscription URLs, or server credentials.
- Prefer a named Cloudflare Tunnel for long-lived use and keep one direct protocol as a fallback.

When opening an Issue, include the OS version, CPU architecture, virtualization type, selected protocol, error text, and redacted status output. Read [SECURITY.md](SECURITY.md) before sharing logs, and see [CHANGELOG.md](CHANGELOG.md) for release changes.
