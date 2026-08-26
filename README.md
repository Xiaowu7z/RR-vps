# RR-vps

> 📢 **[进入 RR-vps 官方交流频道](https://t.me/GMgP4NG7lncwZGE1)**

[中文](README.md) · [English](README_EN.md)

RR-vps 是面向 Debian / Ubuntu VPS 的多协议 Sing-box 管理脚本。它保留一个简单的 `rr` 管理入口，同时把程序、协议模块、用户配置、运行配置和订阅数据分开保存，便于热更新、回滚和开源维护。

> **免责声明：本项目仅供技术交流、理论学习和自有服务器管理研究使用，不提供任何网络访问服务。请勿将本项目用于任何违反当地法律法规、VPS 服务商条款或 Cloudflare 使用政策的用途；使用者需自行承担全部责任，项目作者不对任何不当使用造成的后果负责。**

> 当前版本：**7.0.3** · [完整更新日志](CHANGELOG.md) · [GitHub Releases](https://github.com/Xiaowu7z/RR-vps/releases)

### 7.0.3 新功能：个人订阅、周期配额与服务器流量管理

RR Nexus 7.0.3 将 mihomo、Clash Verge Rev、FlClash 和 Sing-box 官方客户端订阅分开，补齐多协议节点并返回标准流量与到期信息；个人设备支持按自然月自动重置额度、设置续期次数和独立管理备注；主面板及远程副面板新增按真实网卡统计的服务器套餐额度，可选择双向、仅上传或仅下载计费。

服务器套餐统计采用系统网卡计数并保存跨重启基线，用于对照运营商账单和预警，不会自动停止整台 VPS。设备额度用尽后立即停用，到自动重置日恢复；连续 35 天没有发生自动或手动重置才会删除。

## 一键安装

支持系统（2026-08 全量矩阵实测通过）：

| 系统 | 支持度 | 说明 |
| --- | --- | --- |
| **Debian 12（bookworm）** | ⭐ 主推 | 验证最充分，三协议/四协议/面板全链路实测通过，推荐首选 |
| Ubuntu 22.04（jammy） | ✅ 支持 | 完整实测通过 |
| Ubuntu 24.04（noble） | ✅ 支持 | 完整实测通过 |

其他 Debian/Ubuntu 衍生版本未测试，不保证兼容。

先切换到 root：

```bash
sudo -i
```

使用 curl 安装（推荐）：

```bash
bash <(curl -fsSL "https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/main/install.sh?t=$(date +%s)")
```

没有 curl 时使用 wget：

```bash
bash <(wget -qO- "https://raw.githubusercontent.com/Xiaowu7z/RR-vps/refs/heads/main/install.sh?t=$(date +%s)")
```

安装后打开管理面板：

```bash
rr
```

### 首次安装顺序（重要）

1. **第一步：先安装节点** — 进入 `rr` 后选择 `1`，安装 Sing-box 内核并配置协议（VLESS Reality / Hysteria2 / TUIC / AnyTLS 等）。也可以只初始化管理框架、暂不开节点。
2. **第二步：再装 RR Nexus 面板** — 节点配置完成后，主菜单选择 `14` 安装可选的管理面板。面板依赖节点配置读取端口并生成设备订阅，因此必须在节点安装之后进行。
3. 面板访问方式（本地 SSH 隧道 / 公网域名 / 公网直连）在 `14` 菜单内选择，详见下文「RR Nexus · 星枢」。

查看版本：

```bash
rr --version
```

更新请选择主菜单 `8`；卸载请选择主菜单 `6`，再输入 `UNINSTALL` 二次确认。卸载完成后终端会再次显示项目地址和重新安装命令。

## 配套工具：RR Edge Atlas 多端域名优选

[RR Edge Atlas](https://github.com/Xiaowu7z/RR-Edge-Atlas) 已作为独立开源项目发布，同时提供电脑端正式版 **1.0** 与 Android **2.7.1**。两端都使用原生固定 IP、SNI 与证书校验及分层筛选思路，适合中国移动、中国电信、中国联通三网测试；RR 面板浏览器版继续作为没有原生测试环境时的候选初筛。

- 项目主页与完整源码：[Xiaowu7z/RR-Edge-Atlas](https://github.com/Xiaowu7z/RR-Edge-Atlas)
- 电脑端 **1.0**（Windows / macOS / Linux）：[下载正式版](https://github.com/Xiaowu7z/RR-Edge-Atlas/releases/tag/v1.0)
- Android **2.7.1** APK：[直接下载](https://github.com/Xiaowu7z/RR-Edge-Atlas/releases/download/v1.0/CF-Optimizer-2.7.1.apk)
- Android 版已经实际测试，适合移动、电信、联通三网优选，结果可直接用于实际配置
- 模式：均衡测速 + **亚洲入口狩猎**；亚洲入口优先 HKG > NRT > SIN > ICN > TPE，并在 Full 阶段复验 POP 漂移
- 功能：IPv4/IPv6/双栈独立管线、POP/Prefix 发现、Final Address Floor、TTFB/成功率/波动与本机历史记录

## 主要功能

- 首次安装先自由多选协议，也可以只初始化管理框架、暂不开节点
- Vmess-WS + Argo 临时/固定隧道
- Vmess + TLS 直连
- VLESS Reality Vision
- Hysteria2，支持端口跳跃与跳跃间隔设置
- TUIC v5
- AnyTLS
- NaiveProxy（sing-box 1.13 原生 naive inbound，HTTP/2 + padding 伪装，Let's Encrypt 真证书，官方 naiveproxy 客户端可用；Clash 原生不支持自动跳过）
- 每种协议独立开关、独立端口修改
- IPv4 / IPv6 入口与出口独立选择
- NAT/LXD 场景的订阅公网端口映射
- Sing-box 配置校验、健康检查和异常自动重启
- 节点、通用订阅、Base64 订阅、Sing-box 客户端配置和 Clash Meta 订阅同步刷新
- 主动心跳模式：客户端保活参数注入订阅，锁屏/挂起后秒级恢复网络通道（4 档 + 自定义 1~3600 秒）
- 选项 8 模块化热更新：GitHub Raw / 官方 API / IPv4 CDN 多源回退、bundle 完整性校验、SHA256 校验、语法检查、防旧包降级、运行迁移、失败自动回滚、升级后服务自动恢复
- Vmess/Argo 本地源站端口不再强制占用 `443`
- 可选安装的 RR Nexus（星枢）Web 管理界面
- 每台设备独立凭据、独立协议链接、二维码、启停和到期时间
- 个人设备支持首次日期 + 次数的自然月自动重置；额度保持不变，用尽立即停用，35 天未处理自动删除
- 服务器套餐支持手动填写总额度，并按公网网卡双向、仅出站或仅入站统计；可带入运营商当前已用量开启新周期
- 面板「服务器实时状态」页：每秒刷新 CPU / 内存 / 磁盘 / 网络，零依赖 `/proc` 采样
- 面板「防火墙」设置页：端口开关、IPv4/IPv6 进出站分流、SSH 端口保护与权限教程
- 面板「流媒体解锁检测」：Netflix / Disney+ / YouTube Premium 等平台解锁状态与地区
- 面板「Edge 候选初筛」：浏览器本地将 1000 域名缩小到 TOP 20；排名不代表真实代理质量，必须使用 RR Edge Atlas 电脑端 1.0、Android 2.7.1 或真实客户端逐个复测
- 面板登录防爆破：IP + 账号双维锁定、30 分钟 5 次失败、指数退避、状态持久化；重置入口在脚本菜单 14 → 2
- 设备订阅按客户端独立发布：Sing-box 完整多协议配置、mihomo / Clash Verge / FlClash 各自 YAML、v2rayN / v2rayNG / Shadowrocket / NekoBox 与通用链接；每条地址均有独立二维码
- 所有个人订阅返回 `Subscription-Userinfo`，兼容客户端可直接显示上传、下载、总额度、剩余额度与到期日期

## 客户端工具与协议支持

RR-vps 生成的订阅兼容以下主流客户端工具：

| 工具 | 平台 | 下载地址 |
|---|---|---|
| sing-box 官方客户端（SFI / SFM / SFA） | iOS / macOS / Android | [GitHub](https://github.com/SagerNet/sing-box) · [官方客户端页](https://sing-box.sagernet.org/zh/installation/clients/) |
| mihomo（Clash Meta 内核） | Windows / Linux / macOS | [GitHub](https://github.com/MetaCubeX/mihomo) |
| Clash Verge Rev（mihomo 图形界面） | Windows / Linux / macOS | [GitHub](https://github.com/clash-verge-rev/clash-verge-rev) |
| FlClash（mihomo 图形界面） | Windows / Linux / macOS / Android | [GitHub](https://github.com/chen08209/FlClash) |
| v2rayN | Windows / Linux / macOS | [GitHub](https://github.com/2dust/v2rayN) |
| v2rayNG | Android | [GitHub](https://github.com/2dust/v2rayNG) |
| Shadowrocket（付费） | iOS | [App Store](https://apps.apple.com/app/shadowrocket/id932747118) |
| NekoBox / NekoRay | Android / Windows / Linux | [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid) · [NekoRay](https://github.com/MatsuriDayo/nekoray) |
| Hiddify | 全平台 | [GitHub](https://github.com/hiddify/hiddify-app) |

各节点协议的客户端支持矩阵：

| 协议 | sing-box | mihomo 系 | v2rayN / v2rayNG | Shadowrocket | NekoBox |
|---|---|---|---|---|---|
| Vmess-WS（Argo / 直连） | ✅ | ✅ | ✅ | ✅ | ✅ |
| VLESS Reality | ✅ | ✅ | ✅ | ✅ | ✅ |
| Hysteria2 | ✅ | ✅ | ✅ | ✅ | ✅ |
| TUIC v5 | ✅ | ✅ | ✅ | ✅ | ✅ |
| AnyTLS | ✅ | ✅（不支持与 Reality 组合） | ✅（新版本） | ✅（2.2.65+） | ✅（1.3.8+） |
| NaiveProxy | ✅（1.13+，部分平台构建） | ❌ | 视客户端内核 | 视版本 | 视版本 |

使用提示：锁屏/挂起后需要快速恢复网络通道的场景，建议配合「主动心跳模式」（主菜单 9 → 11）使用，并优先选择 sing-box 内核 1.13+ 的客户端。

## RR Nexus · 星枢（可选安装）

主菜单选择 `14` 后，由用户自己选择访问方式：

| 模式 | 管理界面入口 | 适合场景 | 安全边界 |
|---|---|---|---|
| 本地模式（推荐） | `127.0.0.1:7900`，通过 SSH 端口转发访问 | 个人管理、无需随时公网打开面板 | 不开放管理端口，不需要公网证书 |
| 公网域名模式 | 自有域名的 `https://` 地址 | 需要从多处访问管理界面 | 后台仍只监听回环地址，由 Nginx 反代；必须成功签发 Let's Encrypt 证书 |
| 公网直连模式 | 服务器 IP + 自签证书 HTTPS | 无域名但需要公网访问 | 浏览器会提示证书警告，需手动信任 |

公网模式不提供裸 IP 登录或明文 HTTP。安装向导会要求管理员账号和强密码，并启用 Argon2id 哈希、应用与 Nginx 双层登录限流、CSRF 防护、HttpOnly/SameSite 会话、公网 Secure Cookie、8 个一次性恢复码和审计日志。

面板里的“设备”是独立访问身份，不是另一位管理员。每台设备使用单独 UUID；暂停、删除、到期或额度变更后会事务化重建 Sing-box 用户列表并刷新独立链接。设备备注只保存在管理数据库，修改备注不会重启节点或刷新订阅；客户端节点名使用稳定随机别名（如 `RR-A1B2C3D4`），不会泄露或跟随管理员备注。公网模式提供带随机令牌的设备订阅地址；本地模式也会在主订阅地址（`http://服务器IP:订阅端口/nexus/<随机令牌>.txt`）同步每台设备的个人订阅，分享时不会暴露管理端口。

设备可设置“首次自动重置日 + 自动重置次数”。到达日期时已用、上传和下载计数归零，原额度保持不变，并按相同日期推进一个自然月；例如 31 日会在短月份落到月末，之后仍回到 31 日。流量提前用完会立即停用，到下一个重置日自动恢复；所有次数用完后按面板计算的最终日期到期。额度用尽后若 35 天仍未手动或自动重置，设备和旧凭据会自动删除。

个人订阅在 HTTPS 面板路由和主订阅 HTTP 服务两条链路上都会动态返回标准 `Subscription-Userinfo` 响应头（上传、下载、总额度、到期 Unix 时间），以及每小时更新建议。NekoBox、Clash 系等支持该标准的客户端可在订阅详情中显示已用、剩余流量和到期日期。为兼容不展示响应头的客户端，九种个人订阅还会在每次刷新时动态增加一个首位信息节点，名称为“已用｜剩余｜到期”；该项复制一条真实可用节点，只修改显示名，因此误选后仍可联网，且不会改写磁盘中的原订阅文件。

本地模式安装完成后，必须在**自己的电脑**（不是 VPS 当前 SSH 窗口）执行安装结果显示的命令。例如服务器 IP 为 `45.192.205.71`、面板端口直接回车使用默认 `7900` 时：

```bash
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o TCPKeepAlive=yes -o ExitOnForwardFailure=yes -N -L 7900:127.0.0.1:7900 root@45.192.205.71
```

看到 `password:` 后输入服务器的 root 密码并回车；输入时屏幕不显示字符是正常现象。成功后保持终端窗口打开，再访问 `http://127.0.0.1:7900`。隧道每 30 秒发送一次 SSH 保活，连续 6 次无响应才退出；用完按 `Ctrl+C` 关闭隧道。

RR Nexus 安装时会下载由项目 GitHub Actions 从官方 Sing-box 稳定版源码构建、额外启用 `with_v2ray_api` 的统计内核，并校验 SHA256。面板每 5 秒读取以设备 ID 命名的用户计数器，累计上传和下载，在达到额度时撤销该设备。个人设备统计属于应用层计量，Sing-box 异常退出或重载瞬间仍可能丢失少量尚未采集的数据。

“服务器流量套餐”使用另一套独立计量：直接读取所选 Linux 公网网卡的 RX/TX 字节并把基线持久化到 SQLite，面板或进程重启后继续累计；网卡计数器回绕、VPS 重启或更换网卡时只重建基线，避免制造巨额假流量。管理员可随时在“校准当前已用”中填写运营商面板的数值，保存后 RR 以该值重新建立基线，后续只累计新产生的流量，适合面板在计费周期中途安装的服务器。可选择双向 `RX+TX`、仅服务器发送 `TX` 或仅服务器接收 `RX`，这比设备应用层流量更接近运营商账单，但不同服务商可能扣除链路层开销、内网流量或采用自己的换算单位，最终仍以服务商账单为准。服务器套餐达到上限只告警，不自动中断整台 VPS。

## 我的 VPS 适合哪种协议？

先记住两句话：

1. **线路决定速度和稳定性的上限，协议不能把拥堵线路变成专线。**
2. **Argo 是 Cloudflare 隧道方案，不是 VPS 线路；“PRO”通常是商家的线路产品名，也不是协议。**

| VPS / 网络情况 | 建议先试 | 原因 | 不建议优先使用 |
|---|---|---|---|
| CN2 GIA、CMIN2/CMI、AS9929、三网精品等直连优化线路 | Reality → AnyTLS → HY2 | 直接发挥低延迟、低丢包优势，少一次中转 | 默认先套 Argo，可能浪费好线路 |
| 普通 Tier 1 国际线路，直连晚高峰拥堵或部分地区难连接 | Argo/Vmess-WS | 借助 Cloudflare 边缘改善可达性，隐藏源站地址 | 强行直连追求低延迟 |
| UDP 可用、丢包不高、需要大带宽或移动网络恢复能力 | HY2 | 对波动和丢包更有韧性，可配置端口跳跃 | UDP 被运营商明显限速时继续硬用 |
| UDP 稳定，重视实时响应、移动切网体验 | TUIC v5 | 基于 QUIC，适合低延迟场景 | UDP 被封锁或 NAT 映射不完整的 VPS |
| UDP 不可用，但 TCP 直连质量不错 | Reality 或 AnyTLS | 不依赖 UDP，部署和排错更直接 | HY2 / TUIC |
| NAT / LXD VPS，只有少量映射端口 | Reality / AnyTLS；UDP 映射完整时再试 HY2 | 可独立设置节点端口和订阅公网端口 | 未确认端口映射就开启全部协议 |
| 只有 IPv6 公网入口 | Reality / AnyTLS / HY2，按客户端 IPv6 能力选择 | RR-vps 支持入口与出口地址族独立设置 | 客户端没有 IPv6 时强制仅 IPv6 |

### 最简单的选择顺序

1. 有明确“回国/大陆优化”的 VPS：先开 Reality，晚高峰实际下载和视频稳定就不用折腾。
2. Reality 稳定但速度上不去，并且 UDP 可用：再试 HY2；移动网络波动时可测试端口跳跃。
3. UDP 不稳定：改试 AnyTLS，不要只看延迟数字。
4. 普通国际线路直连很差：开启 Argo/Vmess-WS，对比直连和 Argo 的晚高峰表现。
5. 最后只保留真正好用的节点；协议全开会增加端口、防火墙和排错复杂度，并不会自动更快。

### 如何判断线路好不好

- 在真实客户端网络测试：中国电信、移动、联通的结果可能完全不同。
- 重点看晚高峰持续下载、视频拖动、语音通话、丢包和抖动，不只看一次 Ping。
- 去程和回程要分开看；商家写“优化”可能只优化一个方向或一个运营商。
- 同一机房也可能因套餐、IP 段、上游和促销批次不同而走不同线路。
- UDP 节点速度异常时，先判断 UDP 是否被限速，再考虑换协议或端口。

常用排查命令：

```bash
ping -c 50 你的VPS_IP
```

```bash
mtr -rwzc 100 你的VPS_IP
```

`mtr` 应在客户端到 VPS 的真实网络环境测试；只在 VPS 上测试公网网站，不能代表用户访问 VPS 的回程质量。

## 回国优化线路怎么理解？

“回国优化”通常指境外 VPS 到中国大陆运营商方向进行了更好的路由和容量安排。常见标签包括：

| 线路标签 | 更常见的目标用户 | 说明 |
|---|---|---|
| CN2 GIA | 中国电信及三网优化产品 | 通常价格较高，适合重视低丢包和稳定性的直连业务 |
| CMI / CMIN2 | 中国移动用户 | 是否三网都好仍要看具体互联和回程 |
| AS9929 / 联通精品网 | 中国联通及部分三网优化产品 | 联通官方将 AS9929描述为高质量承载网络 |
| 三网精品 / 三网回程优化 | 电信、移动、联通混合用户 | 必须查看三网、去程、回程和晚高峰实测，不能只看商品名 |
| 普通 Tier 1 | 全球访问或大流量优先 | 通常带宽大、价格低，但不承诺中国大陆方向优化 |

以 DMIT 当前产品分类为例，Premium/Pro 类产品强调中国大陆优化，Eyeball 类产品在成本和中国用户可达性之间折中，Tier 1 类产品更偏全球容量；这只是帮助理解分类，不代表对任何商家的固定推荐。线路会调整，购买前请核对产品页和近期实测。

参考资料：

- [Cloudflare Quick Tunnels 官方限制](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/do-more-with-tunnels/trycloudflare/)
- [Cloudflare 固定 Tunnel 创建说明](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/create-remote-tunnel/)
- [DMIT 网络产品分类](https://www.dmit.io/pages/cloud-instance)
- [中国联通国际 AS9929 / Premium DIA 说明](https://eu.chinaunicomglobal.com/products-dia)
- [中国移动国际 IP Transit / DIA](https://iconnect.cmi.chinamobile.com/en/product/i-connect-data/ip-transit-dia)

### Argo 临时隧道还是固定隧道？

- 临时隧道：开箱快，适合测试和个人临时使用；域名可能变化，Cloudflare 也对 Quick Tunnels 设有并发等限制。
- 固定隧道：需要 Cloudflare 账号和 Tunnel Token，域名与管理更稳定，更适合长期使用。
- Argo 表现取决于 VPS 到 Cloudflare、用户到 Cloudflare 以及当时的边缘调度，不保证永远优于优化直连线路。

## 系统与 VPS 兼容性

| 项目 | 支持情况 |
|---|---|
| Debian | 12 及以上；重点兼容 Debian 12 |
| Ubuntu | 22.04 及以上；重点兼容 22.04 / 24.04 |
| CPU | amd64 / x86_64、arm64 / aarch64 |
| 虚拟化 | KVM 最稳；NAT、LXD 可用但要正确映射端口 |
| 必需条件 | root、APT、systemd、可访问 GitHub/Cloudflare 下载源 |
| 暂不支持 | Alpine、CentOS/RHEL 系、无 systemd 的精简系统 |

OpenVZ、受限容器或廉价 NAT VPS 可能禁止 BBR、sysctl、iptables 或 UDP；脚本会尽量安全跳过不允许的优化，但协议能否正常使用仍由宿主机权限和端口映射决定。

## 文件为什么拆开？

```text
/usr/local/bin/rr                  统一管理入口
/usr/local/lib/rr/manifest.sha256  发布版本与完整性清单
/usr/local/lib/rr/modules/         系统、配置、协议、订阅、更新、菜单模块
/usr/local/lib/rr/nexus/           RR Nexus 后端与静态界面（可选启用）
/etc/argo_vmess.conf               UUID、端口、密钥和用户选择
/etc/sing-box/config.json          Sing-box 运行配置
/etc/rr-nexus/nexus.json           面板访问模式与监听配置（权限 600）
/var/lib/rr-nexus/nexus.db         管理员、设备与审计数据库（权限 600）
/tmp/sub_server/                   当前订阅文件（运行时生成）
```

选项 8 只替换程序模块，不主动重置用户数据。更新分为两步：优先下载发布 bundle 做高速热更（先校验 bundle 完整性、成员数与版本号，防 CDN 旧包降级），失败再切换逐文件下载；新模块落地后校验 SHA256 与 Bash 语法、同步更新入口与模块两份副本、执行配置迁移，并自动刷新订阅与自动优选任务。任何一步失败都会恢复更新前的入口、模块、配置、内核、服务和订阅；升级完成后节点与面板服务自动重启，无需手动干预。

## 使用建议

- 初次安装只开启 1–2 种协议，确认稳定后再增加。
- 不要让两个服务占用同一个 IP/端口；Argo 本地端口无需固定为 443。
- 修改节点端口、IP 模式或订阅端口后，从脚本重新复制最新订阅。
- 不要公开 `/etc/argo_vmess.conf`、Reality 私钥、UUID、Tunnel Token 或完整订阅地址。
- 生产用途优先使用固定 Argo 隧道，并保留一条直连协议作为备用。
- 升级前无需手动删除旧版本；直接运行新安装命令或使用选项 8 即可迁移。

## 模块结构

| 模块 | 职责 |
|---|---|
| `00-runtime.sh` | 常量、版本、架构与运行环境 |
| `10-system.sh` | 系统检测、依赖、防火墙和通用校验 |
| `20-config.sh` | 配置白名单、迁移、IPv4/IPv6 和订阅服务 |
| `30-singbox.sh` | 内核、证书、配置生成、服务和事务应用 |
| `40-subscription.sh` | 节点链接、Sing-box/Clash 订阅生成 |
| `50-status-argo.sh` | Argo 开关与运行状态 |
| `60-update.sh` | 更新检查、热更新、迁移和健康修复 |
| `70-protocols.sh` | 各协议、端口和 HY2 跳跃管理 |
| `80-ui.sh` | 端口、节点信息、CDN 与隧道刷新 |
| `85-nexus.sh` | RR Nexus 安装、HTTPS、设备用户与独立订阅 |
| `90-auto-update.sh` | 自动优选订阅任务 |
| `95-install.sh` | Fail2Ban、安装、修复与卸载 |
| `99-menus.sh` | Sing-box、IP、订阅端口和主菜单 |

## 反馈问题

提交 Issue 时请提供：系统版本、CPU 架构、虚拟化类型、所选协议、报错文本和脱敏后的状态信息。**不要粘贴 UUID、私钥、Tunnel Token、完整订阅链接或服务器登录凭据。**

安全信息请阅读 [SECURITY.md](SECURITY.md)，版本变化请阅读 [CHANGELOG.md](CHANGELOG.md)。
