# Changelog

> RR-vps 自 6.6.9 起作为新的公开稳定版本基线（RR-vps public stable history starts from 6.6.9）。此前版本仅视为开发阶段，不再作为项目公开正式历史保留。

## 6.6.16 - 面板订阅地址列表每项都带二维码

### 新增
- 设备详情页的订阅地址列表（总订阅/NekoBox/URI 全集/Sing-box 完整）此前只有
  第一项有二维码；现在每项右侧都有二维码，扫码即得订阅，方便快速添加设备
- 后端 /api/devices/{id}/qr 新增 raw 参数（仅接受 http/https），前端按 URL 逐项生成

## 6.6.15 - 修复 LE 证书 403（root umask 077 权限链）

### 修复
- DMIT 等模板 root umask 077：mkdir 出 700 目录、certbot 写 600 文件，
  nginx(www-data) 读挑战文件 Permission denied → LE 验证 403（五哥实机复现）
- 面板域名模式与 NaiveProxy 的 webroot 流程：显式 chmod 755 目录链
  （webroot/.well-known/acme-challenge）+ umask 022 子壳跑 certbot（文件 644）
- 实机对比：Vultr（umask 022）一次过，DMIT（umask 077）403——现已强制权限

## 6.6.14 - 修复面板域名模式 LE 证书 404（nginx 未 reload）

### 修复
- nexus_write_nginx_site / nexus_write_nginx_custom_port 写完 server 块只做 nginx -t
  不 reload——nginx 继续跑 default 站，acme-challenge 请求 404，Let's Encrypt 签发失败
- 现在语法检查通过后立即 reload（reload 失败退级 restart），新配置即时生效

## 6.6.13 - 修复面板安装 typing_extensions 冲突（6.6.10 回归）

### 修复
- 6.6.10 起 grpcio 统一 pip 安装，在 Ubuntu 24.04 上 pip 升级 apt 版 typing_extensions
  时报 "Cannot uninstall typing_extensions 4.10.0, RECORD file not found" 导致面板装不上
- 新策略：已装新版跳过 → apt 源版优先（Debian12=1.51/Ubuntu24=1.60，无 pip 冲突）
  → 仅 Ubuntu22（源版 1.41）走 pip 兜底，兜底前先 --ignore-installed 装 pip 版
  typing_extensions shadow 掉 debian 版（/usr/local/lib 优先）
- 实机验证：CS2 Ubuntu22 卸净重装走 pip 兜底 1.83 面板 active；CS3 半删残留异常态
  亦兜底成功；面板服务不受影响

## 6.6.12 - 订阅服务自愈链加固

### 修复
- 健康检查自愈订阅时 `generate_node_and_sub` 无超时保护：重建含公网入口探测，网络抖动会把整个健康检查链卡住，导致订阅服务迟迟未拉起。现在加 `timeout 90` 兜底，卡住也不阻断后续检查

### 验证
- CS1 实测：杀订阅服务 → `rr --health-check` 一次拉起（3.8s）；timer 每 5 分钟自动巡检正常
- 前链实测（6.6.11）：H1 截断 bundle 回滚 / H2 乱码 manifest 拒绝 / B5 default→singbox_node 全过

## 6.6.11 - P2 修复：防火墙关闭拒绝基线 + 设备同步 O(n) 合并

### 修复（P2 ×2）
- **防火墙 close 无拒绝基线**：INPUT 默认策略 ACCEPT 时，删除放行规则后端口依然可达。现在 `close_protocol_firewall` 在链尾补一条 `DROP`（comment: argo-rr-managed-block），关闭=明确拒绝；`open_protocol_firewall` 先删该 DROP 再放行，语义闭环（iptables/ip6tables/ufw 三路一致，不影响其他服务）
- **设备操作 O(n)**：批量设备变更（如批量删除）触发 N 次全量重建（每次 13-53s），面板被拖到 504。`sync_devices` 加合并窗口：同步进行中时新请求标记 pending 秒回，执行完 drain 兜住期间全部变更——批量 20 并发实测从 20 次重建合并为 2 次

### 验证
- 防火墙（CS1 实机）：open=HTTP 200 连通 → close=DROP 在位+连接超时拒绝 → re-open=HTTP 200 恢复；规则无残留
- debounce（本地并发单测）：20 并发调用全部 True、实际执行 2 次（首+尾 drain）
- 面板 smoke：CS1 加载新 rr_nexus.py 重启后 active、HTTP 200

## 6.6.10 - P1 修复：grpcio 旧版面板 CPU 死循环

### 修复（P1）
- grpcio < 1.43 在 Ubuntu 22.04 上会导致 Nexus 面板 CPU 死循环（apt 源 python3-grpcio 为 1.41，过旧）
- `nexus_install_dependencies` 改用 pip 统一安装 `grpcio>=1.43`（兼容 PEP 668：Debian 12 / Ubuntu 24.04 自动加 `--break-system-packages`），并卸载 apt 版避免并存冲突，装后强制校验版本
- 幂等：已装新版时 pip 自带版本比较直接跳过；更新流程面板重启后自动加载新版

### 验证
- 三系统实机（Debian 12 / Ubuntu 22.04 / Ubuntu 24.04）：依赖函数 FN_RC=0、grpcio 1.83.0、面板重启后 3 分钟观察 CPU 0.2%（无死循环）

## 6.6.9 - 稳定基线（系统级审计修复版，全量实机验证 103 PASS/0 FAIL）

### 修复（7 个产品缺陷全闭环）
- 到期设备不清扫 + 订阅服务与面板 /sub 双路由语义不一致 → 幂等清扫标记 + SQL 过滤对齐
- toggle 失败伪装成功（403 变 200 {}）→ 非零退出也解析 stdout 透传真实状态
- 无公网证书时 revoke 会重新生成 key → 与签发对称补证书门槛
- Nexus 数据库损坏无限崩溃循环 → quick_check 完整性检查 + 退出码 3 + StartLimit（不自动重建，数据安全优先）
- Naive LE 证书邮箱 admin@example.com 被 LE 恒拒 → 未配置时从域名派生，LE_EMAIL 可配置
- /nexus/ 目录泄露设备 token → index.html 防护
- cron worker PATH 缺 /usr/local/bin → 孤儿清理失效修复

### 增强（完善项 + 可靠性改进）
- TLS 证书删除后自动重建，节点不再因证书丢失无法启动
- NAIVE 未启用时清空遗留掩码凭据，保持配置终态干净
- 迁移后活节点机器健康定时器介入，判定收紧
- 直连自签模式补防火墙规则
- SNI map 修复（443 节点流量精确归属面板）
- 审计补全两路径（成败双落账 + revoke denied）
- 断网时更新检查三态（有新/已最新/检查失败），不再误报"已是最新"
- 内核自愈失败写日志 + 面板提示（不再静默吞错）
- 孤立 sing-box 进程三通道提示（仅提示不清理）
- 降级拦截显式提示
- 升级失败自动回滚全链路（坏 bundle/坏 config/降级不兼容）
- 旧版配置迁移后热更升级字段零丢失（兼容性实测通过）
- Debian 12 / Ubuntu 22.04 / Ubuntu 24.04 全新安装实测通过
