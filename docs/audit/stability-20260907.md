# 三机短测结果（2026-09-07）

结论：未通过。三台均在首次安装的 systemd 服务核验环节退出；服务重启、订阅同步和 180 秒稳定观察尚未执行，不能据此宣称三机稳定。

## 测试对象与范围

- 产品代码：main `afa9c00874c78e6837c7bf412e8c3f8c809b3821`，RR-vps 7.2.0。未修改主分支或产品代码。
- 三台既有专用测试机：A Debian 12、B Ubuntu 22.04、C Ubuntu 24.04。
- 用户授权清理测试机旧状态与冲突防火墙；保留 root 私有备份，并优先放行 SSH。
- 取消交叉迁移、规模和完整发布审计。目标是五协议安装、本地面板、单设备同步、两次服务重启和 180 秒观察。

## 实际结果

| 检查 | A | B | C |
| --- | --- | --- | --- |
| 旧状态及防火墙重置 | 通过 | 通过 | 通过 |
| 运行时、内核、证书和 Reality 密钥生成 | 完成 | 完成 | 完成 |
| 首次协议安装 | 失败 | 失败 | 失败 |
| 面板、同步、重启和持续观察 | 未执行 | 未执行 | 未执行 |

首次短测：[34080842590](https://github.com/Xiaowu7z/RR-vps/actions/runs/34080842590)。

后续仅读取日志和定位同一个失败点，没有重置或重新安装三台机器。A 的定点调用证实 `build_singbox_config` 返回 0，`setup_systemd` 返回 1，退出位置为 `modules/30-singbox.sh` 的服务属性核验。证据：[34081226788](https://github.com/Xiaowu7z/RR-vps/actions/runs/34081226788)。

## 已确认原因

三台 `sing-box.service` 的 `User=root`、`WorkingDirectory=/etc/sing-box`、`DynamicUser=no`、`PrivateNetwork=no` 均符合脚本要求；`RootDirectory`、`RootImage`、`DropInPaths` 均为空，实际单元没有 Condition/Assert 指令。

然而 `systemctl show` 返回：

```text
Conditions=[unprintable]
Asserts=[unprintable]
```

`rr_singbox_service_guards_are_effective` 要求这两个输出字符串为空，因而拒绝脚本自身创建的单元。这是已观察到的 systemd 属性显示兼容问题；不能把 `[unprintable]` 直接当作空条件放行。正确修复需要读取实际条件数据并保留原有核验。

三台属性证据：[34081297859](https://github.com/Xiaowu7z/RR-vps/actions/runs/34081297859)。这些诊断任务的绿色状态只表示读取成功，不表示安装或稳定性测试通过。

## 收尾状态

遵循用户节省额度、避免复杂化的要求，发现共同阻断问题后停止扩查，没有继续重复三机全量测试。临时诊断工作流改为仅手动触发；本轮没有活动中的测试。

测试机保留未完成的安装现场和 root 私有日志、备份。旧防火墙按用户授权被清理；这些测试机的过滤链默认策略为 ACCEPT，未恢复原规则。服务安装未完成，不能当作已验收可用环境。

本轮没有修复上述产品缺陷，也没有合并或发布新版本。
