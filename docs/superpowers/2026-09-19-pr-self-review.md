# PR 前自审：轮次上下文与原生浮窗

日期：2026-09-19。分支：`codex/intent-orchestration-overlay`。
审查基线：`a456068`，包含之后的提交及当前未提交改动。

结论：本轮确认的主要代码问题已修复，可以准备草稿 PR。Windows 和完整原生交互验收仍未完成，不建议把本报告作为“所有平台均已验证”的依据。尚未提交、推送或创建 PR；本轮自审后的源码尚未替换本机正在运行的版本。

## Standards：代码质量与冗余

| 问题 | 处理及意义 |
| --- | --- |
| 新历史页替换后仍保留旧历史行、旧详情弹层、指标与技能组件 | 删除 1,200 余行无调用入口的旧 UI，移除未使用的 `compact` 参数。相关代码位于 HistoryView、SummaryView 及已删除的 InspectorSkillsToolsView |
| 不再消费的状态和查询 | 删除 `historyRuns`、`allProjectsList`、`isTaskRunning`、全展开/全收起方法；历史加载只执行实际使用的会话查询 |
| 历史摘要回填已经没有生产来源 | 删除 repair.py 的 `summary_info` 回填分支、无效计数和文档承诺；历史已有字段保留，不推断或回填目标和结果 |
| 辅助脚本与生产类型脱节 | 更新 generate_showcase.swift 的旧状态赋值，并补齐原有示例缺失的策略 enabled 字段；实际编译通过 |
| 过期宿主测试有无效工作 | turn-context-host.sh 改为读取真实 Desktop probe 状态，不再运行始终无法证明 Desktop 支持的 CLI marker，不再依赖 RTK |

保留凭证校验、进程锁、发布修订、恢复和降级判断。这些逻辑分别防止跨轮关联、并发覆盖、旧快照回滚或缺失数据被伪造，有明确的故障场景，不为减少行数而删除。

## Spec：需求与行为

| 问题 | 修复 |
| --- | --- |
| 账户页使用独立布尔状态，切回最近轮次时可能仍停在账户；IPC 也无法报告账户页 | 将 Account 纳入 OverlayTab，四页共用导航状态；增加账户 IPC 路由 |
| 打开历史/统计也会把最新结果标为已读 | 分离纯展开 `expand()` 和查看最新 `openLatest()`；进入历史或查看旧轮次不确认新结果 |
| 隐私模式的切换弹层仍显示“最近完成”项目名 | 对该入口应用与项目标题相同的隐藏规则 |
| 终端摘要仍使用旧“交付结论” | 只读取已发布、source 为 parent_final 且 turn_id 匹配的 result，标题改为“结果”；原生结果归属规则保持一致 |
| 新安装的全局模板写死“没有已验证宿主，自动写入关闭” | 改为按安装环境判断；已验证且启用的 Desktop 使用实际传入的 additionalContext 凭证。临时安装已验证模板正确进入 AGENTS 管理块 |
| 探针通过后没有正式自动启用入口 | 增加 `codex-flow telemetry context enable-desktop-transport`；未验证或探针配置损坏时结构化拒绝，遥测关闭时不写配置 |
| 文档与示例仍写 400 字、实时进度和彩虹环 | 更新入口、规范、计划、中英文 README、遥测/浮窗说明与验收记录；长目标示例改为 71 码点、两句话，同步 HTML 内嵌数据 |

两个独立只读审查分别覆盖代码质量和需求一致性。首轮发现已由父级核对；主要修复经过增量复审。最后的损坏配置拒绝与合法预览目标由父级通过针对性验证收口。

## 验证证据

- 完整遥测回归 `tests/telemetry.sh` 通过：当时的 89 项核心 Python 测试、Hook trust、账户快照、采集/发布、修复和 latency 验证均通过。
- 清理导入、修正入口后重新运行 82 项 instructions/数据层测试及安装副本 CLI 测试，通过；随后新增损坏探针拒绝用例，相关 32 项测试通过。
- 最终安装副本 CLI 测试共 15 项，通过；安装使用临时 CODEX_HOME，无真实登录启动设置变更。
- `tests/overlay-startup.sh` 通过：真实 OverlayState 的恢复、未读持久化、账户导航、历史不清未读及胶囊命中区域。两个导航回归均先观察到失败，再修复到通过。
- 完整原生 app 和宣传图生成器均使用临时输出目录编译成功；未执行图像生成、未读取真实内容生成宣传图。
- Swift 模型/Query、Watcher 与只读 status 检查由独立审查运行通过。
- 三份 JSON 预览中的 11 个目标均通过生产 write_goal 校验；长结果仍保留多段内容以验证折叠布局。
- 真实开发机 host gate 返回 supported_probe，同轮凭证和 goal/plan/Stop 两个验证字段为 true；此证据仅限该安装，脱敏状态记录在 host-validation.json。
- `git diff --check` 通过。

## PR 仍需明确的边界

- Windows 安装/锁恢复需等待 Windows CI；当前环境没有 Windows/PowerShell。
- 多屏拖动、账户/更多完整交互、VoiceOver 与系统材质降级仍需人工检查；编译成功不能代替这些行为验收。
- 现有 TaskRun 的 `session--turn` 标识依赖宿主 UUID 不含 `--`；任意字符串 ID 的碰撞是既有边界。本轮不更改历史数据键协议。
- 独立 probe 的 status 诊断脚本遇到人工损坏 JSON 仍可能输出 traceback；新公开启用命令已安全拒绝，自动 Hook 也会 fail-open，不会据此启用传递。
- 根 README 的既有改动及开发上手指南保留；提交时需按功能范围明确选择。原任务计划和 ledger 不重置。

建议 PR 标题：`feat: publish per-turn goals and orchestration in native overlay`。
PR 描述应围绕“父 Agent 写入目标/完整计划，父 Stop 发布结果，原生四页读取已完成快照”，并列明上述平台验收限制。

## 本轮自审问题修复（2026-09-19）

本节记录用户确认修复后追加的改动与重新验证结果，补充上文的历史记录。

| 问题 | 最终处理 |
| --- | --- |
| 过期 run 删除后仍遗留目标与完整计划 | 在同一轮次锁内先删除上下文 sidecar，再删除 run；sidecar 删除失败时保留 run 供后续重试，sealed receipt 保持失效 |
| 已中止轮次仍接受目标或计划写入 | 写入前读取绑定转录中的同会话、同轮次父任务中止证据，在锁内复核并封存凭证；实际写入锁内复核转录版本，版本变化时拒绝旧检查结果并要求重试；已有 goal/plan 不改写。旧凭证仅按指定状态目录中的精确 run 查找转录，不扫描其他历史 |
| 恢复历史结果触发完成弹窗 | Python IPC 将静默 refresh 与完成 update 区分；Swift 共用快照加载逻辑，通过通知标记区分行为。静默刷新不提前消耗真正完成的通知资格 |
| 原生界面仍执行无消费者的转录解析 | 删除 QueryEngine 的解析器及 watcher、IPC、详情和示例生成器调用；保留旧数据字段的解码兼容性 |

新增行为回归覆盖保留期删除失败重试、跨轮次和子任务归属、中止后内容不变、真实 Unix socket 命令，以及静默刷新后首次完成展开一次、重复完成不再展开。Swift IPC 回归已纳入 `tests/overlay-startup.sh` 现有测试入口及 CI，无需额外手工执行独立文件。

本次最终验证：

- 全量 Python：174 项通过，另有 54 个 subtest 通过；有一条既有 updater tar.extractall 的 Python 弃用警告。
- `tests/telemetry.sh`：104 项核心测试、5 项 Hook trust 及账户快照、采集发布、修复、latency 集成检查通过。
- `tests/turn-context-install.sh`：临时安装副本的 15 项检查通过。
- `tests/overlay-startup.sh`：真实 IPC、启动恢复、未读状态和胶囊命中检查通过。
- Swift watcher、turn-context model/query、query concurrency 检查通过；完整原生应用与示例生成器编译通过，产物位于临时目录，未运行示例生成器。

Windows、多屏交互及 VoiceOver 仍未在本次本地验证。本轮未提交、推送或创建 PR，也未替换正在运行的安装版本。

复审中的显式 IPC payload 优先级意见未采纳：修复前已有“优先 last.json、仅在缺失时使用 payload”的发布规则，本轮静默刷新继续共用该规则。中止竞态意见已补转录版本校验和先失败后通过的回归；版本检查是写入授权的确认点，不要求外部转录写入器遵守本项目的锁。

最终独立复核：本轮四项修复无剩余阻断或可行动发现。目标与计划的中止校验依赖可验证、可读取的父任务转录；证据缺失时不会推断为中止。`git diff --check` 通过。
