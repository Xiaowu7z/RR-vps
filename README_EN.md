# RR-vps

> 📢 **[Join the official RR-vps community channel](https://t.me/GMgP4NG7lncwZGE1)**

[中文](README.md) · [English](README_EN.md)

RR-vps is a multi-protocol Sing-box management script for Debian and Ubuntu VPS instances. Users keep one simple `rr` command, while program modules, persistent settings, runtime configuration, and subscriptions are stored separately for safer updates and rollback.

> **Disclaimer: This project is provided solely for technical exchange, theoretical study, and research on managing your own servers. It does not provide any network access service. Do not use it for any purpose that violates local laws, your VPS provider's terms of service, or Cloudflare's usage policies. Users bear full responsibility for their own use; the author assumes no liability for any consequences of misuse.**

> Current version: **7.2.0** · [Full changelog](CHANGELOG.md) · [GitHub Releases](https://github.com/Xiaowu7z/RR-vps/releases)

### 7.2.0: rebuilt trust boundaries, hardened recovery, and verifiable releases

7.2.0 is a system-wide engineering release spanning subscription and management security, durable hot updates, cross-version rollback, encrypted migration, supply-chain controls, and the release pipeline itself. The server core used for RR Nexus real-time traffic accounting is fixed to **sing-box 1.14.0**, built from one pinned upstream source commit. Stable consumes only an immutable GitHub Release whose exact current-`main` commit passed CI `push`, the three-host audit `push`, and the public-IP ACME `workflow_dispatch`; Beta remains isolated on its own branch.

This release also removes public cleartext HTTP subscriptions. A standalone endpoint must either use TLS on a trusted domain or listen only on `127.0.0.1` and be reached through an SSH tunnel. Users without a domain can select Nexus trusted public-IP mode: RR obtains a short-lived Let's Encrypt IP certificate for a globally routable public IPv4 or IPv6 address and serves personal subscriptions through the same trusted HTTPS endpoint. Legacy public HTTP URLs stop working after the upgrade.

Trusted public-IP mode is not a self-signed bypass. The IP must be globally routable, public TCP/80 must continuously reach the local ACME Webroot, and the certificate must match that exact IP and validate against the system CA store. RR publishes no public personal-subscription URL if any requirement fails; use trusted-domain HTTPS or a local SSH tunnel instead.

Restore validates mount topology, object type, root ownership, write permissions, and hard-link/symlink boundaries before it queries target service state or changes RR-managed paths, then repeats that proof after freezing writers, after completing the rollback snapshot, and before recursive cleanup. If a late check fails after services have crossed the READY gate, restore clears READY, re-isolates Nginx and the managed runtime, and preserves recovery evidence. After acquiring both the shared update lock and the legacy compatibility lock, direct installation and update fail closed before release download or runtime preparation whenever the restore-marker path contains any object, including a dangling symlink; the installer does not remove that evidence.

Diagnostics, encrypted `.rrbak` migration, alerts, TOTP/Passkeys, history charts, batch management, and NaiveProxy HTTP/3 remain available. See the prerequisites below for 7.2.0 `.rrbak` and NaiveProxy restore requirements, and see the changelog for the trust-boundary, recovery, multi-distribution CI, and real-host audit evidence.

## One-command installation

Target systems are listed below. CI covers containers for all three distributions; a release is not considered real-VPS verified until the current release report records all three machine gates:

| System | Support | Notes |
| --- | --- | --- |
| **Debian 12 (bookworm)** | ⭐ Recommended | Primary target; must pass the per-release VPS gate |
| Ubuntu 22.04 (jammy) | ✅ Targeted | Covers legacy upgrade and data-retention gates |
| Ubuntu 24.04 (noble) | ✅ Targeted | Covers current-system and fault-injection gates |

Other Debian/Ubuntu derivatives are untested and not guaranteed.

Become root first:

```bash
sudo -i
```

Install with curl (recommended):

```bash
bash <(curl -fsSL "https://github.com/Xiaowu7z/RR-vps/releases/latest/download/install.sh")
```

Or use wget:

```bash
bash <(wget -qO- "https://github.com/Xiaowu7z/RR-vps/releases/latest/download/install.sh")
```

Open the control panel:

```bash
rr
```

### First-time installation order (important)

1. **Step 1: Install the node first** — open `rr` and choose option `1` to install the Sing-box core and configure protocols (VLESS Reality / Hysteria2 / TUIC / AnyTLS, etc.). You may also initialize the management framework only, without enabling any node yet.
2. **Step 2: Then install the RR Nexus console** — after node configuration is complete, choose option `14` from the main menu to install the optional management console. The console reads ports and generates device subscriptions from the node configuration, so it must be installed after the node.
3. Console access modes (local SSH tunnel / public domain / trusted public IP) are chosen inside the `14` menu; see "RR Nexus · XingShu" below.

Show the installed version:

```bash
rr --version
```

Choose menu option `8` to update. Choose option `6` and enter `y` (upper- or lowercase) to confirm removal. The uninstall result prints the project URL and reinstall command for future use.

Common operations:

```bash
rr doctor
rr doctor --repair
rr doctor --report
rr backup
rr restore /path/file.rrbak  # see prerequisites below
rr update --check
rr update --channel stable   # or beta
rr update --rollback
```

An `.rrbak` contains RR-managed data, not Certbot accounts or renewal configuration. If NaiveProxy is enabled in the backup, the destination must first run the current RR-vps and have a renewable Certbot lineage for the same domain. Before writing, restore verifies that the certificate is trusted by the system CA store, matches the domain and private key, has at least seven days of validity remaining, and uses the current deploy hook. A blank or unprepared destination is rejected. To migrate through a blank host, disable NaiveProxy on the source before creating the backup, then re-enable it and issue a certificate on the destination after restore.

Copying only `fullchain.pem` and `privkey.pem` is insufficient: Certbot's `cert`, `chain`, `fullchain`, and `privkey` links under `live` must resolve to one `archive` generation, the renewal configuration must bind the production Let's Encrypt ACME account and RR's ACME Webroot, and the related paths must pass strict ownership and mode checks.

Direct restore to a blank destination is supported only when NaiveProxy is disabled in the backup; subscriptions then default to loopback-only access. An existing destination's standalone HTTPS subscription access plane is preserved, but its trusted certificate and current deploy hook must also pass preflight. With active UFW, only simple user rules that can be proven disjoint from RR-managed ports are admitted. Rules on the same port, or complex rules whose ordering independence cannot be established safely, cause restore to reject before any firewall write; back up and reconcile those rules before retrying.

## Companion tool: RR Edge Atlas

[RR Edge Atlas](https://github.com/Xiaowu7z/RR-Edge-Atlas) is now a standalone open-source multi-platform project with desktop **1.0** and Android **2.7.1** editions. Both use native fixed-IP probing, SNI and certificate validation, and layered screening. Android can screen candidates across China Mobile, China Telecom, and China Unicom, but results must still be retested on the current carrier, time window, and actual client before configuration. The browser panel remains a shortlist fallback when no native test environment is available.

- Project and full source: [Xiaowu7z/RR-Edge-Atlas](https://github.com/Xiaowu7z/RR-Edge-Atlas)
- Desktop **1.0** for Windows, macOS, and Linux: [release downloads](https://github.com/Xiaowu7z/RR-Edge-Atlas/releases/tag/v1.0)
- Android **2.7.1** APK: [direct download](https://github.com/Xiaowu7z/RR-Edge-Atlas/releases/download/v1.0/CF-Optimizer-2.7.1.apk)
- Features: IPv4/IPv6/dual-stack pipelines, POP/prefix discovery, Asia Hunt, Final Address Floor, TTFB/success/variation ranking, and local history

## Features

- Free protocol selection during first install, including a framework-only choice
- Vmess-WS over temporary or named Cloudflare Tunnel
- Direct Vmess over TLS
- VLESS Reality Vision
- Hysteria2 with configurable port hopping and interval
- TUIC v5
- AnyTLS
- NaiveProxy (native naive inbound with selectable HTTP/2, HTTP/3 over QUIC, or dual mode; configurable QUIC congestion control and a real Let's Encrypt certificate; after RR Nexus is installed, its accounting server core is fixed to sing-box 1.14.0)
- Independent protocol switches and ports
- Independent IPv4/IPv6 inbound and outbound preferences
- Trusted-domain HTTPS subscriptions, plus domain-free Nexus personal subscriptions on a globally routable public IPv4/IPv6 address with a short-lived Let's Encrypt certificate; NAT/LXD must map public TCP/80 and the selected HTTPS port precisely to this host
- Sing-box validation, health checks, and guarded automatic restart
- Target-scoped UFW/IPv4/IPv6 firewall transactions: a durable cross-boot gate is established and managed ingress is stopped before the first write; the gate is removed only after every participating backend's live and persistent state validates. Unprovable writes, saves, or compensation retain fail-closed evidence until a complete repair is revalidated
- Menu, CLI, background-sync, health-repair, and certificate-deploy writers share a root-only transaction lock domain. Naive/Sing-box and public Nexus certificate pairs remain gated until atomic publication, effective systemd policy, and the actually served certificate are proved; durable pending evidence makes failures idempotently recoverable
- Synchronized share links, Base64, Sing-box client JSON, and Clash Meta YAML
- Durable updates: Stable verifies an immutable product Release, the exact five assets, Tag/Commit, publication ownership, and the latest successful CI push, VPS push, and VPS workflow_dispatch evidence for one exact SHA before execution, while Beta remains branch-isolated; persistent journals, boot recovery, consistent database snapshots, health gates, automatic rollback attempts, and explicit manual recovery remain in place
- `rr doctor` checks system, DNS, clock, public networking, core, ports, firewall, certificates, console, subscriptions, database, disk, and update sources; safe repair and redacted reports are available
- Password-encrypted `.rrbak` backup/migration of RR-managed data with authenticated encryption, scoped restore, and automatic local rollback attempts on health failure; it is not a full-machine backup
- No forced reservation of local port 443 for Argo
- Optional RR Nexus web console with local-only or public HTTPS access
- Per-device credentials, protocol links, QR codes, enable/disable state, and expiry
- Calendar-month automatic quota resets with a first date and renewal count; depleted devices are removed from runtime access on the next roughly five-second collection/sync cycle and are deleted after 35 unattended days
- A server carrier-package meter with a manually entered allowance and bidirectional, TX-only, or RX-only host-interface accounting
- Panel live server status page: per-second CPU / memory / disk / network, zero-dependency `/proc` sampling
- Panel firewall settings page: port toggles, IPv4/IPv6 inbound/outbound split, SSH port protection, and a permission tutorial
- Panel streaming unlock checker: unlock status and region for Netflix / Disney+ / YouTube Premium and more
- Panel Edge candidate screener: locally narrows 1,000 domains to a TOP 20 shortlist; its ranking is not real proxy quality, so candidates must be retested with RR Edge Atlas desktop 1.0, Android 2.7.1, or the actual client
- Panel brute-force protection: dual-dimension IP + account lockout, 5 failures in 30 minutes, progressive response delay, persisted state; reset via script menu 14 → 2
- TOTP, one-time recovery codes, and origin-bound WebAuthn Passkeys
- Telegram and HTTPS-webhook alerts for service, disk, allowance, certificate, device quota, Argo domain change, update/backup failure, and security lockout events, with deduplication and optional HMAC signatures
- Device groups, templates, filters, and batch actions; traffic and system history for 24 hours, 7 days, or 30 days
- Per-client device subscriptions: a full multi-protocol sing-box profile; separate YAML URLs for mihomo, Clash Verge, and FlClash; dedicated v2rayN, v2rayNG, Shadowrocket, and NekoBox feeds; plus universal links, each with its own QR code
- Every personal subscription returns `Subscription-Userinfo`, allowing compatible clients to display upload, download, allowance, remaining traffic, and expiry

## Client tools and protocol support

RR-vps generates formats for these mainstream clients. This is a format/protocol capability matrix, not a claim that every current client version completed a real connection test in this release; see the release report for the tested scope:

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
| NaiveProxy H2 / H3 | ✅ (native naive; RR Nexus accounting core fixed to 1.14.0) | ❌ | Depends on client core | Version-dependent | Version-dependent |

Tip: for fast recovery after screen lock/suspend, enable the active heartbeat mode (main menu 9 → 11) and prefer clients with sing-box core 1.14+.

## Subscription access security

Public cleartext HTTP subscriptions have been removed. Nexus and the standalone subscription service use the states below. `SUB_ACCESS_MODE` describes only the standalone service; it is not the RR Nexus console mode.

| Subscription state | Address | Security requirement |
|---|---|---|
| Trusted-domain Nexus | `https://trusted-domain[:panel-port]/sub/...` | The domain exactly matches a valid certificate anchored in the system CA store |
| Trusted public-IP Nexus | IPv4: `https://PUBLIC-IPv4:panel-port/sub/...`; IPv6: `https://[PUBLIC-IPv6]:panel-port/sub/...` | The IP is globally routable; a Let's Encrypt `shortlived` IP certificate has settled atomically; SAN, private key, system-CA chain, and remaining validity all pass; public TCP/80 continuously reaches the ACME Webroot |
| `SUB_ACCESS_MODE=https` | `https://trusted-domain:subscription-port/...` | `SUB_DOMAIN` is a valid DNS name with a matching, valid, publicly trusted TLS certificate; the service refuses to start publicly when validation fails |
| `SUB_ACCESS_MODE=local` (default) | `http://127.0.0.1:subscription-port/...` | Binds only to loopback and does not open the subscription firewall port; HTTP never leaves the SSH tunnel |

Let's Encrypt public-IP certificates are short-lived (currently roughly 6–7 days). RR runs a persistent renewal job every 12 hours and retains the HTTP-01 Webroot. If port 80 is blocked, the IP is not local, the chain is not trusted by the system CA store, the certificate expires, or pair publication remains pending, RR does not fall back to a self-signed subscription and emits no publicly shareable personal-subscription URL. Some old clients may not support trusted IP certificates yet; upgrade the client or use a domain/SSH tunnel.

Without a certificate that satisfies those conditions, create a forward on the device that runs the client. For example, if RR reports subscription port `39291` and the example server IP is `203.0.113.10`:

```bash
ssh -N -L 39291:127.0.0.1:39291 root@203.0.113.10
```

Keep that SSH session open, then add the `http://127.0.0.1:39291/...` URL shown by `rr` to a client on the same device. Do not replace the loopback host with the server's public IP. If the local port is already occupied, choose another local port and change the port in the client URL to match.

> **Upgrade warning:** After upgrading from a release that exposed subscriptions over public HTTP, every old `http://SERVER-IP:SUBSCRIPTION-PORT/...` URL becomes invalid and is not redirected. Tokens/UUIDs in those URLs and node credentials returned in the feed may already have been exposed in transit. Treat them as potentially compromised, manually rotate the affected credentials, and distribute new URLs. The upgrade does not automatically rotate every node and device credential for you.

## Optional RR Nexus console

Choose menu option `14`, then select one access mode:

| Mode | Entry point | Security boundary |
|---|---|---|
| Local (recommended) | `127.0.0.1:7900` through an SSH port forward | No public management port and no public certificate requirement |
| Public domain | `https://` on a domain you control | The backend still binds only to loopback; Nginx proxies HTTPS and installation succeeds only after a Let's Encrypt certificate is issued |
| Trusted public IP | Globally routable server IPv4/IPv6 with a short-lived Let's Encrypt IP certificate | Public TCP/80 must remain reachable; the certificate must match the exact IP and validate through the system CA store; there is no self-signed fallback |

Public login and console content are HTTPS-only. In domain and trusted-IP modes, port 80 serves only ACME HTTP-01 challenges (domain mode may redirect to HTTPS after issuance); other cleartext requests receive neither console nor subscription content. RR Nexus uses Argon2id password hashes, application and Nginx login rate limits, CSRF protection, 12-hour sessions, eight one-time recovery codes, and an audit log.

Each device is an access identity, not another administrator. It receives an independent UUID and protocol links. Disabling, deleting, expiring, or changing a quota commits the database first and then schedules a background Sing-box/subscription sync, normally taking effect in the next sync cycle. If the audit log reports a sync failure, retry it; a committed database change is not proof that runtime synchronization succeeded. An administrator-only note can be renamed without restarting the node or refreshing subscriptions.

Public-domain consoles and public-IP consoles that pass every certificate gate expose personal subscriptions through `/sub/...` on that same trusted HTTPS endpoint; IPv6 literals use URI brackets. Nginx access logging is disabled for these requests, and backend error logs omit the URL, so the token is not written to request-line logs. A legacy self-signed IP certificate is panel compatibility state only and never unlocks public subscriptions or remote keys. If trusted IP issuance or renewal fails, use a trusted subscription domain or a local SSH tunnel. A local console returns only loopback URLs such as `http://127.0.0.1:subscription-port/nexus/<random-token>.txt`, which require a second SSH port forward.

A device can define a first automatic-reset date and a maximum number of monthly renewals. At each boundary, used/upload/download counters return to zero while the allowance stays unchanged; calendar anchoring prevents a 31st-of-the-month plan from drifting permanently after February. A depleted device remains blocked until the next scheduled or manual reset. After all renewals, it expires on the calculated final date. A quota-depleted device left untouched for 35 days is automatically deleted with its credential.

RR Nexus trusted-domain/public-IP HTTPS routes and the standalone subscription endpoint (trusted-domain TLS or loopback-only HTTP) attach the standard `Subscription-Userinfo` header, plus an hourly refresh recommendation. NekoBox, Clash-family clients, and other compatible apps can show usage, remaining allowance, and expiry. For clients that do not expose this header, all nine personal subscription formats dynamically add a first “used | remaining | expiry” entry: sing-box JSON and Clash YAML use a real-node copy, while URI/Base64 feeds use an explicitly labelled, non-connectable `127.0.0.1:9` marker. Do not select that marker as a proxy. Stored subscription artifacts remain unchanged.

For local mode, run the command printed by the installer on your **own computer**. On first connection, verify the SSH host fingerprint before accepting it; do not disable host-key checking. Enter the server root password when prompted, keep that terminal open, and browse to `http://127.0.0.1:7900`. The command uses an SSH `-L` forward plus a 30-second client keepalive and fails fast when the forward cannot be created. To use personal subscriptions, also forward the subscription port as described above.

RR Nexus downloads an accounting core built by the project GitHub Actions workflow from one pinned official sing-box 1.14.0 source commit with the additional `with_v2ray_api` tag. RR verifies its version, source revision, build tags, and SHA256. It polls counters named by device ID every five seconds, persists upload and download totals, and revokes access when a quota is reached. These per-device figures are application-layer accounting; an abnormal Sing-box exit or the instant around a reload can still lose a small uncollected delta.

The server carrier-package meter is separate. It reads RX/TX byte counters from the selected Linux public interface, persists its baseline across panel restarts, and safely re-baselines after a VPS reboot, counter rollback, or interface change. The operator can enter the provider's current usage at any time; RR then re-baselines at that value and accumulates only subsequent traffic, which also covers mid-cycle panel installations. It can count RX+TX, TX only, or RX only. This is closer to provider billing than application counters, but provider-specific overhead and unit conversion still make the provider invoice authoritative. Exhausting this monitor raises a warning; it never takes the whole VPS offline automatically.

## Which protocol fits my VPS?

The route sets the performance ceiling. A protocol cannot turn a congested route into a premium private line. Argo is a Cloudflare tunnel, not a VPS route; “PRO” is normally a provider product tier, not a protocol.

| VPS or network condition | Try first | Why |
|---|---|---|
| CN2 GIA, CMI/CMIN2, AS9929, or another China-optimized direct route | Reality → AnyTLS → HY2 | Keeps the low-latency direct path and avoids an unnecessary relay |
| Ordinary Tier 1 route with poor peak-hour reachability | Argo/Vmess-WS | Cloudflare may improve reachability and hides the origin address |
| UDP works well and high throughput or loss recovery matters | HY2 | Better tolerance of variable networks; optional port hopping |
| Stable UDP and latency-sensitive traffic | TUIC v5 | QUIC-based option for responsive connections |
| UDP is blocked or heavily shaped but TCP is good | Reality or AnyTLS | Does not depend on UDP |
| NAT/LXD with a small set of mapped ports | Reality/AnyTLS; HY2 only with correct UDP mapping | Node ports remain independent; a mapped public subscription port is only for trusted-domain HTTPS |
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
| Debian | Debian 12 is the current verified target; other releases are best-effort and outside this release gate |
| Ubuntu | Ubuntu 22.04 and 24.04 are the current verified targets; other releases are best-effort and outside this release gate |
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

Option 8 replaces program modules without resetting persistent settings. Updates run in two stages: a release bundle is downloaded first for a fast hot-update (integrity, member count, and version are verified to block stale CDN packages); on failure it falls back to per-file download. New modules are verified with SHA256 and Bash syntax checks, both the launcher and module copies are replaced together, configuration migration runs, and subscriptions plus the auto-optimization worker are refreshed automatically. Any failure triggers a recovery attempt. If host degradation prevents complete recovery, the persistent transaction preserves evidence and reports the explicit recovery command. A successful upgrade restores services according to their recorded pre-update state.

## Safety notes

- Start with one or two protocols and add more only when they solve a measured problem.
- Never assign the same IP/port pair to two services. The local Argo origin does not need port 443.
- Refresh your client subscription after changing protocol ports, address-family mode, or subscription mapping.
- Never publish `/etc/argo_vmess.conf`, Reality private keys, UUIDs, Tunnel Tokens, complete subscription URLs, or server credentials.
- Prefer a named Cloudflare Tunnel for long-lived use and keep one direct protocol as a fallback.

When opening an Issue, include the OS version, CPU architecture, virtualization type, selected protocol, error text, and redacted status output. Read [SECURITY.md](SECURITY.md) before sharing logs, and see [CHANGELOG.md](CHANGELOG.md) for release changes.
