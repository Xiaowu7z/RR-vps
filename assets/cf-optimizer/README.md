# CF 域名优选（Android）

Cloudflare IP / 域名入口优选 Android 工具。原生 Kotlin，仅申请联网与网络状态权限，无广告。

## 当前版本

**2.7.1**（`CF-Optimizer-2.7.1.apk`，SHA-256：`d2e26ab5a56e0888ad21c6ae2e900a7446f7e7e548c2084a52babcb772409937`）

- 包名：`com.cfoptimizer`，versionCode 21，minSdk 29，targetSdk 34
- IPv4 / IPv6 / 双栈独立测速
- 均衡模式 + **亚洲入口狩猎**模式
- 亚洲入口优先级：HKG > NRT > SIN > ICN > TPE；Full 阶段再次 trace 检查 POP 漂移
- 1000 个候选域名种子，DNS 去重 Cloudflare IP，按 IP / POP / Prefix 发现入口
- Nexus Mods 固定基准、Final Address Floor、失败计 0、成功率/波动/TTFB/最佳与最差 IP
- 50 条历史记录；2.7.1 修复主页内容超出屏幕后无法向下滚动、历史记录入口无法点击的问题

历史 APK：`CF-Optimizer-2.6.0-debug.apk`、`CF-Optimizer-2.5.0-debug.apk`。

## 目录

- `app/` — Android 工程源码
- `test/` — 测试源码
- `domains.txt` — 1000 域名候选池
- `build.gradle.kts` / `settings.gradle.kts` — Gradle 构建入口
- `build.sh` — CLI 构建脚本

## 构建

标准 Gradle 环境可使用 JDK 17 + Android SDK 34 + Gradle 8.10.2 构建。
