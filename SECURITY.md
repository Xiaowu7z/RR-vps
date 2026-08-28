# Security Policy / 安全说明

## 提交问题前请脱敏

请勿在 Issue、截图、日志或聊天中公开以下内容：

- `/etc/argo_vmess.conf` 完整内容
- UUID、Reality 私钥、Tunnel Token
- 完整节点链接和订阅地址
- VPS 密码、SSH 私钥、API Token
- `/etc/rr-nexus/nexus.json`、`/var/lib/rr-nexus/nexus.db`、管理员恢复码
- 远程管理接入钥匙（`rrmgr1.` 开头）与 `/var/lib/rr-nexus/remote.key`
- RR Nexus 设备订阅地址、设备独立 UUID
- 可直接识别个人或服务器身份的信息

可以提供系统版本、CPU 架构、虚拟化类型、脱敏后的端口状态、`systemctl status` 错误和 Sing-box 配置校验错误。公开问题中请把域名、IP、UUID 和密钥替换为占位符。

## Before opening an issue

Never publish complete configuration files, UUIDs, Reality private keys, Cloudflare Tunnel Tokens, RR Nexus databases or recovery codes, device subscription URLs, remote manager credentials (`rrmgr1.` prefixed) or the signing key `remote.key`, VPS passwords, SSH keys, or API tokens. Redact IP addresses and domains when they are not necessary to reproduce the issue.

## RR Nexus exposure model

Local mode binds only to `127.0.0.1` and should be reached through an SSH tunnel. Public mode also keeps the application on loopback and exposes it only through Nginx: domain mode requires a matching publicly trusted certificate, while direct-IP mode uses an explicitly self-signed certificate and browser trust warning. Do not add a firewall rule that publishes the private backend port, and do not place another untrusted reverse proxy in front of it without preserving HTTPS and source-address handling.

## Login protection

- Sessions expire after 12 hours. The browser keeps an Authorization Bearer only in the current origin/tab's `sessionStorage`, so another HTTPS port on the same hostname does not receive it; every session also carries its own CSRF token for state-changing requests. Password or MFA changes revoke every existing session and require a fresh login.
- Brute-force protection is two-dimensional and persistent: per-IP rate limit (5 failures / 30 min) plus per-account lockout (10 failures / 1 h), with a progressive response delay on each failed attempt.
- Keep administrator recovery codes offline and protect them like the password: each code grants one administrator login. A recovery-code login still cannot replace the current-password/TOTP step-up required for sensitive credential changes.

## Remote management keys (6.6.0+)

- A managed panel issues a one-line credential of the form `rrmgr1.<payload>.<HMAC-SHA256>`. The payload contains only address, port, random nonce, display name and issue time; the signature is computed with a 256-bit secret key stored only on that panel (`/var/lib/rr-nexus/remote.key`, mode 600).
- Verification uses constant-time HMAC comparison plus payload structure checks. Rotating/removing the local key revokes every previously issued credential at once.
- Issuance is restricted to public-certificate panels (valid domain + Let's Encrypt certificate). Local/IP panels cannot issue keys.
- Credential verification is persisted and rate-limited per source IP after 10 failures in a 30-minute window, limiting online brute force.
- Treat a credential as a password for that server: only paste it into a manager panel you control, and revoke (rotate) it if it ever leaks.

## Remote & local upgrade (6.6.2–6.6.6)

- Remote upgrade endpoints are only reachable with a valid credential for that managed panel, under the same rate limits above.
- Upgrade jobs run inside a dedicated `systemd-run` transient unit, isolated from the panel's cgroup, so restarting the panel does not kill an in-progress upgrade.
- Concurrent local/remote upgrades are serialized by an O_EXCL lock file with a unique token; a stuck lock is only reclaimed after both the systemd unit heartbeat and the unit's cgroup directory confirm the process is gone.
- Job state is authoritative from the systemd unit; stuck jobs are detected via log heartbeat and timed out (8 minutes). Failures are reported and the update transaction attempts recovery; if recovery is incomplete, persistent evidence and the manual recovery path remain available.

## Update integrity

RR-vps verifies release files against `manifest.sha256`, bounds and independently parses release archives before extraction, checks Bash/Python/JavaScript syntax, loads all modules in a validation process, and runs post-update migration before accepting a new release. User-configured mirrors are transport only: their bundle cannot decide the version unless its full manifest matches a trusted source. Update, backup, restore, health and Nexus synchronization share root-owned locks under `/run/rr-vps/locks` so snapshots cannot overlap writers and an unprivileged user cannot pre-claim a lock name.

If a post-update health gate fails, RR attempts to restore the previous managed runtime, configuration, database and recorded service state. A killed process or degraded host can still prevent automatic recovery; the persistent transaction and boot recovery helper preserve evidence and expose explicit recovery/rollback commands. These controls reduce update risk but do not replace reviewing source code before running it as root.

## Subscription and backup boundaries

- Public subscription content is either trusted-domain HTTPS or loopback-only HTTP through an SSH tunnel. All subscription responses, including conditional responses, are marked `no-store`; URLs remain bearer secrets and must not be pasted into public logs or screenshots.
- `.rrbak` is an authenticated, password-encrypted migration backup of RR-managed files and SQLite state, not a whole-server backup. Restore accepts only allowlisted members, rejects links and path traversal, applies bounded streaming checks, and regenerates executable services from the verified local runtime.
