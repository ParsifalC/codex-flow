# 轮次上下文与新版浮窗验收记录

本记录对应 `plans/2026-09-18-turn-context-overlay.md`，不替代原计划的验收门。
状态截至 2026-09-18；整体尚未完成。

| 计划范围 | 当前证据 | 判定 |
| --- | --- | --- |
| Task 1：真实宿主同轮凭证 | `host-validation.json` 为 unverified；一次性 Desktop 探针仍为 armed，没有收到真实 Hook | 未通过，需真实用户消息触发 |
| Task 1：凭证、隔离、锁与关闭守卫 | `test_turn_context.py`、`test_lock_recovery.py`、`test_publication.py`；此前遥测聚合 78 项 Python 测试通过 | 本机数据层验证通过；Windows 锁未实机验证 |
| Task 2：目标、完整计划及 CLI | `test_turn_context_cli.py` 的 13 项测试通过；`turn-context-install.sh` 安装副本同样通过；已补齐帮助、错误与 disabled 响应字段 | CLI 通过，真实宿主自动写入未通过 |
| Task 3：精确父 final | `turn_result.py` 与指定轮次提取测试；提交 `872d84d` | 已实现并通过本机测试 |
| Task 4：Stop 发布、revision、排序与恢复 | publication/并发/崩溃测试；原生 reducer 与 watcher 集成可执行测试通过 | 本机数据链路通过；真实宿主链路仍缺证据 |
| Task 5：四 tab 仿真与确认 | `flowpilot-overlay-navigation.html`、三个 fixture；用户确认“布局确认，按这版实现” | 用户确认已满足；自动浏览器交互验证受阻，未宣称通过 |
| Task 6：原生 UI | `676e7c4`；四 tab、更多、毛玻璃、目标/结果优先、完整计划默认折叠、五小时展示过滤 | 已实现；独立复审进行中 |
| Task 6：模型和刷新 | model/query 与 watcher 可执行测试通过；历史排除未发布和旧 running；原样保留结果空白 | 本机验证通过 |
| Task 6：真机交互与无障碍 | 已有任务/历史/统计截图；当前安装版历史截图及 IPC 收起/展开通过；账户、更多、键盘、VoiceOver、多屏和系统减少透明度尚无完整操作证据 | 未完成 |
| Task 7：安装、打包与平台 | POSIX 隔离安装通过；目录递归打包保留；Windows 脚本与 CI 已接入 | Windows 执行未完成，本机无 PowerShell/Windows |
| Task 8：场景回归 | 两 chat 四 turn fixture、遥测聚合、hook trust、instructions、隔离 smoke 的已有记录 | 不能替代宿主、Windows、真机及独立审查门 |
| 用户追加：源码编译到本机 | 构建成功，安装和源码 binary SHA-256 一致；进程 61152 的 IPC status 返回 running | 已完成 |

## 本机版本

源码与安装产物 SHA-256：
`afc27deba4aacd8b72fcddad7c6fddcadd218d641179fd3d08f85c2b9a209752`。
安装位置：`~/.codex/codex-flow/bin/FlowPilot`。
后续若再次编译，以新校验值为准。

用户后续明确授权本机源码安装，覆盖原计划“仅临时安装”的限制。
没有恢复登录自启动，没有新增备份。测试中的安装仍使用临时 home。
此前 smoke 隔离缺陷曾影响登录启动项，已告知用户并修复测试，不能声称此前从未影响真实设置。

## 不可省略的后续验收

1. 用真实 Desktop 用户消息触发已安装探针，同轮写入目标和完整实际计划，父 Stop 后验证相同 session/turn 的发布快照；当前自动写入保持关闭。
2. 在 Windows runner/设备执行安装、UTF-8 CLI 与锁恢复测试。
3. 完成账户、更多、复制、置顶/收起、切换、长文本、键盘/VoiceOver及系统材质降级检查。
4. 收敛独立复审发现并重新编译安装受影响版本。原 ledger 和历史审查结果保留，不把过期窗口或缺失审查当作通过。

## 当前安装版补充检查

CGWindowList 确认 PID 61152 的窗口为 384×590。第一次捕获是裁切画面，切换历史并收起/展开后未复现；完整截图为 `/tmp/flowpilot-history-installed.png` 与 `/tmp/flowpilot-reexpand.png`。这证明新布局已在本机运行，但不替代账户、更多或无障碍交互验收。

本轮修复后的 13 项 CLI 测试与 13 项安装副本测试通过。新增运行时代码通过 Python 3.8 语法解析，这不等于实际 Python 3.8/Windows 运行通过。

当前真实 Desktop Stop 的结果已追加核验：已发布快照 result 与使用快照内明确 session/turn/transcript 路径提取的父 final 完全一致（221 字符）。历史行的“未记录”来自 publishedGoal，不能据此推断 result 缺失。该证据只证明结果归属与发布，不证明 receipt 传递或 goal/plan 写入。
