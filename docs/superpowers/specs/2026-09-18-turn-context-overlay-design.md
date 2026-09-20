# FlowPilot 轮次目标、编排与浮窗设计

状态：用户已确认按推荐范围编写实现计划；本文冻结本期设计，不代表功能已经实现。

## 1. 用户要解决的问题

用户在浮窗和历史记录中，需要看懂 Agent 针对**这一轮输入**理解了什么、采用了什么编排、最后给出了什么结果。需求提炼是展示信息，不修改用户消息，不替代用户原文，不成为另一个自动执行目标系统。

最新确认纠正了此前“每个 chat 维护一个目标”的方案：**每轮独立记录目标**。新一轮可以承接上文，但不能覆盖上一轮目标。

## 2. 术语与现有代码

| 产品概念 | 现有代码 / 数据 | 本期语义 |
| --- | --- | --- |
| 项目 project | `cwd`；界面通常显示目录名 | 展示、筛选的项目上下文，不新增项目实体系统 |
| 对话 chat | `session_id`；Swift `ChatSession.id` | 包含多轮记录；仓库用它作为 app-server `threadId` |
| 轮次 turn | `turn_id`；Swift `TaskRun` | 当前用户输入触发的一次执行，目标归属此层 |
| 轮次唯一键 | `session_id + turn_id` | 两者共同标识，不能只用项目或 chat |

代码证据：`scripts/telemetry_core/common.py` 的 `run_key()`；`scripts/telemetry_core/app_server.py` 的 `thread/read` 调用；`apps/macos-overlay/Sources/Models/TelemetryData.swift` 的 `TaskRun`、`ChatSession`；`TelemetryQueryEngine.swift` 的 `fetchChatHistory`。

这是对本仓库字段的映射，不宣称所有 Codex 宿主都使用相同外部术语。项目显示名相同也不能用目录 basename 合并对话。轮次边界以宿主实际提供的 `turn_id` 为准，不按消息数自行生成轮次；宿主若将执行中的补充消息归入同一 turn，也不能擅自换键。

例如：第一轮“重构浮窗”记录自己的目标；第二轮“去掉五小时额度”记录“在本次浮窗改造中移除五小时额度展示”。两轮归属同一 chat，各自保留目标、计划和结果。

## 3. 已确认范围

- 本期只为 FlowPilot 参与的轮次记录需求提炼与编排信息。
- 本期实现 macOS 原生浮窗；Python 数据层与 CLI 保持 Windows 兼容。
- Windows 原生浮窗不在本期；交付 Windows 材质降级与布局规范，不把 HTML 仿真当作原生效果已经验证。
- 保留任务、历史、统计、账户四个 tab，以及更多菜单、置顶、收起、任务切换、历史入口。
- 移除五小时额度 UI；不删除底层额度采集和编排依赖，也不顺带删除账户其他信息。
- 执行中的内部记录不作为实时进度展示。收到父 Agent Stop 后才发布这一轮详情。
- 界面文案使用“结果”，不新增“交付结论”。

## 4. 端到端行为

1. `UserPromptSubmit` 用 hook 提供的 `session_id`、`turn_id` 创建轮次记录和绑定凭证；不更新浮窗详情。
2. 父 Agent 进入 FlowPilot，先结合当前输入与必要上下文提炼本轮目标，再通过 CLI 写入独立的轮次元数据。
3. planner 编译后，Agent 将实际返回的完整 ExecutionPlan 写入同一轮次。已有任务的后续轮次沿用原计划和 task ledger 时，记录实际沿用的计划及 `origin=reused`，不能重新消费 bypass 或重置预算。
4. Agent 正常执行。新信息导致原有编排合法调整时，保存最新实际计划和递增的计划修订号；本轮目标在首次成功写入后不可被后续写入覆盖。
5. 父 Agent Stop：按本轮 ID 提取最终输出，合并元数据和最新运行事实，持久化完整快照，再通过现有 IPC `update` 通知浮窗。
6. 浮窗与历史记录读取已发布的快照，呈现本轮目标、结果、可折叠的编排信息与运行事实。

这里的“更新”是产生新轮次并显示新记录；不是不断改写一个 chat 目标。Stop 是本轮结束信号，不推断整个 chat 的长期任务已经完成。

## 5. 可靠绑定是首个交付门槛

现有 hook 有 `session_id`、`turn_id`；当前 Agent 环境可见 chat/session 标识，但未验证可用的 turn 环境变量。仓库也没有已验证的 hook 向 Agent 注入上下文实现。因此不能在计划中假定 `$CODEX_TURN_ID` 或某种 hook 输出协议必然可用。

采用 **hook 生成、宿主传递、本轮父 Agent 使用的显式凭证**：

```json
{
  "schema_version": 1,
  "session_id": "chat-a",
  "turn_id": "turn-2",
  "receipt_id": "opaque-random-id",
  "role": "parent"
}
```

首个实施任务必须用真实支持的宿主验证凭证能在同一轮传给父 Agent，保存脱敏协议 fixture 和兼容性说明，然后才接通自动写入。传输通过宿主支持的 hook 上下文或明确提供的 turn 上下文，不能写入用户消息；不能把伪造的 JSON 输出当作协议验证成功。

凭证以 hook 侧登记表的 active/sealed 状态校验；Stop、中止和 retention 清理使其失效，不只信任调用方 JSON。遥测关闭时登记表也不写入。固定失败策略：缺少凭证、ID 不匹配、已结束轮次、过期凭证、子 Agent 调用全部拒绝元数据写入，CLI 输出结构化原因，主任务继续。**不允许按 `last.json`、最近文件、唯一活动轮次或全局环境猜测 turn ID。** 未证明绑定能力的宿主不启用自动写入，展示“未记录”，并在兼容性说明中标记 unsupported；缺少认证、Hook 信任或无法运行探针则标记 unverified，不能误判协议不支持。要宣称目标宿主支持本功能，必须通过真实端到端绑定验收。

凭证用于正确关联，不是防恶意 Agent 的安全边界。不得把父 Agent 的凭证复制到子 Agent handoff 中。

## 6. 元数据契约

新增 `scripts/telemetry_core/turn_context.py`，专门负责凭证验证、元数据校验与原子写入。源数据存于 telemetry 根目录的 `turn-context/<digest>.json`；digest 为 `[session_id, turn_id]` 的确定性 JSON 编码的 SHA-256，不直接拼接用户提供的路径片段。

```json
{
  "schema_version": 1,
  "session_id": "chat-a",
  "turn_id": "turn-2",
  "goal": {
    "text": "在本次浮窗改造中移除五小时额度展示",
    "source": "flow-pilot",
    "recorded_at_ms": 1789700000000
  },
  "orchestration": {
    "origin": "compiled",
    "revision": 1,
    "recorded_at_ms": 1789700000100,
    "execution_plan": {"schema_version": 11}
  }
}
```

上例 `execution_plan` 仅示意嵌套位置；实际必须保存并校验 planner 的**完整原始 JSON 对象**，不只摘录策略名，不由 Agent 手写替代计划。展示的是策略与配置等可验证决策事实，不要求保存模型内部推理。`origin` 只接受 `compiled`、`reused`、`replanned`。目标与计划分两次写入，Stop 允许部分缺失；文案各自显示“未记录”。无需为了填满 UI 调模型。

新增 CLI 接口：

```text
codex-flow telemetry context write-goal --receipt-file <path> --text-file <utf8-path>
codex-flow telemetry context write-plan --receipt-file <path> --plan-file <json-path> --origin compiled|reused|replanned
```

UTF-8 文件传参避免引号、换行和 shell 插值改变原文。目标允许 1–80 个 Unicode 码点、最多两句话；空文本和超限明确拒绝，不静默截断。目标重复写入相同文本幂等，不同文本报 `goal_conflict`。计划对象的规范 JSON 相同则幂等；合法变更递增计划修订号。凭证不能写进导出的 TaskRun、复制摘要、日志和统计。

TaskRun 增加可选 `turn_context`、`result`、`publication`，旧 schema v1 兼容读取。新 hook 在 run 上设置 `publication_required=true`，没有 publication 时不能进入详情；此标记用于区别旧的已结束历史，不改变轮次身份：

```json
{
  "turn_context": {"schema_version": 1, "session_id": "chat-a", "turn_id": "turn-2", "goal": {}, "orchestration": {}},
  "result": {"text": "已移除五小时额度展示。", "source": "parent_final", "turn_id": "turn-2"},
  "publication": {"revision": 1, "completed_at_ms": 1789700000200}
}
```

`turn_context` 的内容是通过校验后复制的上述元数据；不包含凭证。`result` 只包含本轮父 Agent 的最终输出。无法证明 turn 或角色/消息阶段时字段为空，不能使用上一轮输出、commentary、子 Agent 回复或用户输入代替。长输出界面折叠显示，复制保留已存文本；若传输源本身截断，应携带 `truncated=true`，界面明确提示。

## 7. Stop 发布与并发

- Hook 的运行中事实仍保存在 runs；Agent 仅写 sidecar，不直接写 runs 或 last。
- 引入 `scripts/telemetry_core/publication.py`，统一负责父 Stop 完整快照发布，消除 collector 与 `telemetry.py` 重复持久化半成品的路径。
- 昂贵的 transcript/app-server 读取在锁外完成；随后在同一个 run 锁下重新读取最新 worker/usage 事实并合并。`state_lock()` 返回未获取锁时必须停止本次写入，不能继续裸写。
- 各类会修改同一 run 的 hook/enrichment 路径共同遵循 run 锁。保持固定锁顺序：run 锁 → 全局发布锁，不存在反向获取。各平台使用标准库 OS 文件锁，进程退出自动释放；跨版本锁协议不混用，结束旧 hook writer 后再验证新版本。
- 完整快照先原子替换 run，再更新 last。last 选择依据第一次完成时间 `completed_at_ms` 以及轮次键作稳定排序；旧轮次重试或补充 worker 数据不能把 last 回滚。
- 发布修订号与目标不同：这是同一轮数据的完整快照版本，不是 chat 目标版本。相同完整内容重复 Stop 不增加修订、不重复弹窗；迟到的真实 worker 数据可以增加该轮修订，只有它仍是 last 时才刷新当前浮窗。
- 每份文件本身始终完整；跨文件不宣称事务原子性。写 run 后崩溃、尚未写 last 的场景，由下一次启动/修复选择最新已发布快照恢复。修复不触发完成通知。
- 文件 watcher 与 IPC 都读取 `publication` 完整快照，按“轮次键 + publication revision”去重；IPC 丢失时 watcher 可恢复，IPC 只是刷新信号。late worker 与修复只刷新，不重复展开或发送完成提醒。
- 旧历史可浏览；旧目标缺失显示“未记录”。不能在后台用用户原文自动生成“提炼目标”，也不能再从整份 transcript 的最后一句补本轮结果。

## 8. 浮窗信息结构与视觉

延续已确认毛玻璃方案的导航、尺寸与操作位置。参考[已确认导航仿真](/Users/zcj/.codex/visualizations/2026/09/18/01a0b245-db54-74a3-8e6f-b6dcada1c13d/flowpilot-overlay-navigation.html)；其中旧的实时进度、“交付结论”与 chat 目标内容被本文覆盖。

| 区域 | 内容 / 行为 |
| --- | --- |
| 顶部 | 项目、对话标题/轮次时间、任务切换；置顶与更多入口 |
| 任务 tab 主体 | 本轮目标 → 结果 → 紧凑的耗时/token/参与者事实 |
| 执行详情 | 默认折叠；展示真实计划的策略、direct/delegate、计划人数、review 模式；明确计划人数不等于实际参与人数 |
| 历史 | chat 分组，进入独立轮次；每轮共用目标/结果/编排组件 |
| 统计 | 保留现有 7/30 天选择、趋势与分布；纯视觉整理 |
| 账户 | 保留账户身份、其他额度/重置事实、全局策略、自启动；删除五小时额度相关卡片、进度条和提示；任务页与历史详情同样过滤 300 分钟窗口 |
| 更多 | 保留更新、隐私、GitHub、控制台、复制摘要等已有操作；不能只画无功能按钮 |

没有已完成快照时显示“尚无已完成轮次”；不显示空进度条，不在收到用户输入时把运行中数据填入详情。已有历史保留可访问。目标/结果缺失分别显示“未记录”，隐藏没有数据的编排内容，不画猜测状态。

视觉实现：原生 `NSVisualEffectView` 材质承载玻璃底层，文本区域使用足够实的底色；限定少量层级、统一边距与字重，长目标/长结果允许展开。保留约 384px 的现有浮窗宽度、拖动、吸附、收起/展开和多屏行为。支持系统减少透明度、减少动态效果、键盘操作与 VoiceOver。Windows 规范采用更高不透明度的亚克力感底色；无系统材质时退化为高对比纯色，禁止依赖网页 `backdrop-filter` 作为桌面跨平台方案。

在改生产 Swift UI 前，先交付覆盖四个 tab、更多菜单、长文本/缺失数据/历史轮次的修正仿真，供用户确认。当前已有视觉方向批准，不重复询问已经确认的数据模型与范围。

## 9. Global Constraints

- 用户原始消息与 transcript 不得因需求提炼而改写。
- 目标归属 `session_id + turn_id`；不新增 chat 目标版本管理。
- 仅父 Stop 发布本轮详情；不新增运行中进度展示。
- 结果文案固定为“结果”；缺失提炼或结果显示“未记录”。
- 保存 planner 的完整 ExecutionPlan；不另造策略引擎，不重置已有任务预算。
- `telemetry.enabled=false` 时不得新增凭证、sidecar、run、last 或 IPC 写入；主任务正常继续。
- `strategy.enabled=false` 或本任务 bypass 时不伪造计划；已有历史照常可读。
- 本期只记录 FlowPilot 参与的轮次；本期原生 UI 只实现 macOS。
- Python 数据层和 CLI 保持 Windows 兼容；不提高现有 Python 最低版本声明，不新增第三方运行时依赖。
- 政策 schema v4、ExecutionPlan schema v11、task-ledger schema v2 保持原有语义；新增元数据单独 version。
- 构建和安装验收必须使用临时 `CODEX_HOME`，不得覆盖开发者已安装的运行时或浮窗。
- 保留四个 tab 与现有主要操作；仅删除五小时额度 UI，不删除对应底层采集。

## 10. 验收与发布门槛

1. 同一 chat 连续两轮目标不同，历史互不覆盖；两个 chat 并行不串数据。
2. “确认”承接上下文提炼；用户原文逐字保留；首次目标写入后不会在同轮被悄悄改写。
3. 凭证经过真实目标宿主验证；缺失、错轮次、迟到、子 Agent 写入拒绝；不能用单元测试模拟成功替代宿主验证。
4. Stop 前没有新的详情快照；Stop 后目标、实际计划、本轮最终输出一起可读。
5. transcript 有多轮、commentary、worker 回复，仍只能选中指定轮次的父 Agent final；无 final 就显示缺失。
6. 重复/乱序 Stop、迟到 worker、锁超时、IPC 丢失、崩溃后恢复均不丢已收集数据、不回滚 last、不重复完成提醒。
7. 两个开关各自测试；关闭 telemetry 无新增遥测写入；关闭策略不伪造 direct 计划。
8. macOS 四 tab、更多、任务切换、复制、置顶/收起保持可用，五小时 UI 在所有入口消失；Windows CLI 测试通过。
9. 修正仿真获确认后才实现原生 UI；真机检查默认/减少透明度、长文本、小屏与多屏。Windows 原生视觉验证列为未来独立工作。

本期不做：全量聊天自动分析、历史目标回填、chat 总目标系统、新策略引擎、实时任务进度、Windows 原生浮窗。
