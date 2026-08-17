# Contributing / 参与贡献

感谢改进 RR-vps。为了避免影响已经在线的节点，请遵守以下原则：

1. 不改变 `/etc/argo_vmess.conf` 的既有字段含义；新增字段必须提供旧配置默认值和迁移逻辑。
2. 不改变 `rr`、`--post-update`、`--health-check` 和 `--sync-subscriptions` 的兼容入口。
3. 配置更新必须先生成临时文件并校验，再原子替换；失败时恢复旧配置和运行状态。
4. 修改节点端口、入口地址或协议开关时，必须同步刷新 Sing-box 配置和全部订阅格式。
5. 新功能必须兼容 Debian 12 与 Ubuntu 22.04/24.04，并避免依赖非基础 Shell 特性。
6. 不在代码、测试或 Issue 中提交 UUID、私钥、Token、订阅地址或服务器凭据。

提交前运行：

```bash
bash scripts/validate.sh
```

The same compatibility rules apply to English-language contributions: preserve persistent configuration semantics, keep the stable `rr` entry points, validate before atomic replacement, refresh every subscription format after state changes, and test the supported Debian/Ubuntu targets.
