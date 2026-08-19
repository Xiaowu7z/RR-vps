# CF 域名优选（Android）

Cloudflare IP 优选 Android 工具：扫描最优 Cloudflare IP + 域名组合，供节点订阅使用。原生 Kotlin，无第三方运行依赖。

## 当前版本

**2.6.0**（`CF-Optimizer-2.6.0-debug.apk`，SHA-256：`8c2203278c05f23d4491242eb1b85d281bda20f06230354a14060e063e2f063c`）

- 应用名：CF 域名优选（包名 `com.cfoptimizer`，minSdk 29）
- 权限最小化：仅 INTERNET + ACCESS_NETWORK_STATE
- 功能：优选 IP 探测、吞吐三口径测速、IPv4/IPv6 独立管线、历史记录（50 条）、VPN 提示
- 基线守擂：www.nexusmods.com 固定晋级，挑战者显示相对基线百分比
- 2.6.0 修复：**停止测速**——点停止立即中断在途请求（Call.cancel），清理动画并返回首页，提示「测速已停止」（旧版点了没反应）

历史版本：2.5.0（`CF-Optimizer-2.5.0-debug.apk`，SHA-256：`ce9b25064936ed2a55b48153ab3ef878fcbf63c60f7cd74e56c10c7b1194dbc3`）

## 目录

- `app/` — Android 工程源码（`AndroidManifest.xml`、`assets/domains.txt` 域名池、`res/`、`src/com/cfoptimizer/`）
- `test/` — 测试源码（SmokeTest / Phase2Test / Phase21Test / Phase22Test / IPv6Test / HistoryTest）
- `build.sh` — CLI 构建脚本（RRAV JDK17 + kotlinc 1.9.25 + build-tools r34）
- `domains.txt` — 域名池（134 个 Cloudflare 站点）

## 构建

```bash
bash build.sh
```

产物输出到项目根的 `build/` 目录。
