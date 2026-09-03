# 配置系统与多策略策略

<div align="center">

[ 简体中文 ](configuration.md) | [ English ](configuration.en.md)

</div>

本文档说明 **codex-flow policy schema v4** 的完整配置体系，包括 Strategy、Routing、Modifiers、模型/推理能力策略、仓库级策略、Runtime 硬上限、Quota 感知规划与环境变量覆盖。

> Policy schema 仍然是 **v4**。动态 Worker Budget、`quality_intent` 和角色级资源选择属于单次任务的 `ExecutionPlan v7`，不会增加持久化配置 schema 版本。

架构与 `ExecutionPlan` 合约参见 [strategy-runtime.md](strategy-runtime.md)。

---

## 全局策略文件

默认位于：

```text
~/.codex/codex-flow.toml
```

全新安装的当前默认配置：

```toml
schema_version = 4

[ui]
language = "auto"

[strategy]
enabled = true
profile = "efficient"

[routing]
mode = "adaptive"

[modifiers]
review = "auto"
fanout = "auto"

[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "high"
critical_effort = "xhigh"

[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-5.6-luna"
min_reasoning_effort = "xhigh"
reasoning_policy = "adaptive"
routine_effort = "xhigh"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = 4
max_repair_cycles = 2

[telemetry]
enabled = true
summary = true
notifications = true
retention_days = 30
source = "hooks+app-server"
```

这个默认值刻意采用 **低成本高能力 Parent + 更深推理 Worker** 的非对称分配：Parent 负责架构、根因、边界和验收，便宜得多的 Worker 承担长时间探索、实现、调试与验证循环。

旧 schema v3 缺少策略/路由/Modifier 字段时，语义兼容为：

```text
strategy_enabled = true
strategy = efficient
routing = adaptive
review = auto
fanout = auto
quality_intent = normal
```

`quality_intent` 不写入持久化配置；它属于当前任务 TaskProfile，默认 `normal`。

安装或更新会迁移到 schema v4，同时保留已有支持字段。也就是说：**已有用户的自定义 reasoning matrix 不会因为升级而被新默认值覆盖**；新默认值主要影响全新安装或用户显式重置后的配置。

---

## 配置优先级

`[strategy].enabled` 是全局总开关。它位于下面的普通策略优先级之上：当值为 `false` 时，FlowPilot 不构造 TaskProfile、不编译 ExecutionPlan、也不做自动 Worker 分发；仓库策略和当前任务覆盖都不能重新开启它。关闭时 profile/routing/modifier 配置仍会保留，重新开启后继续生效。

Planner 按以下优先级解析：

```text
运行时 / 安全硬上限
  > 当前任务显式覆盖
  > 仓库 .codex-flow.toml
  > 用户 ~/.codex/codex-flow.toml
  > release defaults
```

当前任务可以临时选择 Strategy、Routing 和 Modifiers，但不能抬高已经解析出的 Runtime 硬上限。例如仓库限制 `max_concurrent_threads = 2` 时，当前任务不能提高到 `99`，只能继续收紧。

---

## Strategy / Routing / Modifiers

三个维度彼此正交。

### `[strategy]`

`enabled`：FlowPilot 自动策略分发总开关，默认 `true`。可通过 CLI 直接控制：

```bash
codex-flow strategy enabled
codex-flow strategy disable
codex-flow strategy enable
```

关闭只会停用 **codex-flow 自动规划与自动分发**，不会修改 Codex 原生 `[agents].enabled`，因此不会剥夺用户显式使用原生子 Agent 的能力。

仓库 `.codex-flow.toml` 可以在总开关开启时覆盖 `profile` / routing / modifiers，但不能覆盖全局 `enabled = false`。这可以避免用户全局关闭后，进入某个仓库又被静默重新开启。

`profile` 支持：

- `efficient` — 减少昂贵 Parent 的使用和无效总消耗，同时把深执行循环更多卸载给 Worker。
- `balanced` — 平衡质量、额度与 wall-clock latency，允许中等强度的安全 Worker fan-out。
- `quality` — 通过更深 Worker reasoning、更宽探索、独立 Review，以及显式质量意图触发的**角色级**高 capability 最大化正确性。
- `speed` — 在已证明安全的工作流上尽量占满 Worker 并发，缩短 wall-clock latency。

Strategy 不直接写死 Worker 数，而是提供 `WorkerBudget` 和策略资源 hook。Runtime 再根据 TaskProfile、隔离证据、Quota 和线程上限编译出本次任务具体的 explorer / implementer / reviewer 数量与资源选择。

### `[routing]`

`mode` 支持：

- `adaptive` — 当前 Strategy 根据 TaskProfile 选择 direct / delegate。
- `direct` — 当前任务不使用子 Agent，由 Parent 实现并自审。
- `delegate` — 在 Runtime 支持且作用域可安全划分时委派给 Worker。

### `[modifiers]`

`review`：

- `auto` — Strategy / TaskProfile 决定 Review 拓扑。
- `standard` — Parent Review。
- `strict` — 委派模式下增加独立 Reviewer，并由 Parent 做最终验证。

`fanout`：

- `auto` — Strategy / TaskProfile 决定 fan-out。
- `conservative` — 收紧探索和写入并发。
- `aggressive` — 在隔离证据成立时提高 fan-out，但不能越过 Strategy budget 和 Runtime ceiling。

Modifier 不能绕过 `writable_workstreams`、write conflict 或 Runtime 硬上限。

---

## Quality Intent

`quality_intent` 是 **TaskProfile 当前任务语义**，不是 `[strategy]` 下的持久配置，也不是 `risk` 的别名：

```text
normal | strong | absolute
```

- `normal` — 默认；普通质量要求。`quality` 优先使用 `latest-efficient` Worker + 深 reasoning。
- `strong` — 用户明确表达质量优先于普通成本效率。`quality` 可将关键 **Implementer / Reviewer** capability 升级到 Parent 的 `latest-capable` policy；普通只读 Explorer 仍保持 `latest-efficient`。
- `absolute` — 用户明确要求最高实际质量，并接受更高成本/延迟。`quality` 会在 Runtime 安全 ceiling 内优先 correctness，提高 fan-out/review budget，并将关键 Implementer / Reviewer 使用 Parent-class capability；普通 Explorer 仍不会因为质量偏好本身而自动升级。

只有当技术画像本身达到 `complexity=critical` 或 `risk=critical` 时，`quality` 才允许 Explorer 也使用 Parent-class capability，因为此时探索本身就是高价值、高风险判断。

不要因为技术任务风险高就自动把 `quality_intent` 设为 `strong/absolute`；反过来，也不要为了表达用户质量偏好而伪造 `risk=critical`。这两个维度必须独立。

CLI 示例：

```bash
codex-flow strategy plan --profile quality --quality-intent strong --complexity complex
codex-flow strategy plan --profile quality --quality-intent absolute --parallelism high --writable-workstreams 4
```

`quality_intent` **只有 `quality` Strategy 消费**。在 `efficient` / `balanced` / `speed` 下，它可以保留在 Plan 中用于可观测性，但不得改变 topology、capability、reasoning、review 或 Worker 数量。

---

## Worker Budget

`WorkerBudget` 不写入 `codex-flow.toml`，它由每个 Strategy 在编译单次 `ExecutionPlan` 时产生：

```text
max_explorers
max_implementers
max_reviewers
max_total_workers
speculation: low | medium | high
```

当前内置策略在高需求任务上的预算大致为：

| Strategy | Explorer | Implementer | Reviewer | Total | Speculation |
| --- | ---: | ---: | ---: | ---: | --- |
| `efficient` | 2 | 2 | 1 | 5 | low |
| `balanced` | 3 | 3 | 1 | 5 | medium |
| `quality normal/strong` | 4 | 3 | 2 | 6–7 | high |
| `quality absolute` | 4 | 4 | 2 | 8 | high |
| `speed` | 4 | 8 | 1 | 8 | high |

这些是**预算上限**，不是每次都必须 spawn 到满。具体数量由 Runtime 根据任务证据计算。

例如 `speed` 虽然允许最多 8 个 implementer，但默认 `max_concurrent_threads = 4`，且必须先有相同数量的已证明隔离 writable workstreams，因此普通任务不会无条件创建 8 个写 Worker。

---

## 仓库级策略

仓库可以提供：

```text
<repo>/.codex-flow.toml
```

例如：

```toml
[strategy]
profile = "quality"

[routing]
mode = "adaptive"

[modifiers]
review = "strict"
fanout = "conservative"

[parent]
min_reasoning_effort = "xhigh"

[worker]
min_reasoning_effort = "max"

[runtime]
max_concurrent_threads = 2
max_repair_cycles = 1
```

仓库策略可以：

- 覆盖该仓库的 strategy / routing / modifiers；
- 提高 Parent / Worker reasoning floor；
- 收紧 thread / repair 上限。

仓库策略不能静默降低用户已有 reasoning floor。`quality_intent` 不属于仓库策略，它只来自当前任务语义。

```bash
codex-flow strategy show --effective
codex-flow strategy plan --repo-policy none --complexity routine
codex-flow strategy plan --repo-policy ./policy.toml --complexity routine
```

---

## Parent / Worker 推理策略

当前设计不再追求 Parent 与 Worker 使用相同 reasoning。

### Fresh-install 默认值

| Task class | Parent | Worker baseline |
| --- | --- | --- |
| routine | `high` | `xhigh` |
| complex | `high` | `xhigh` |
| critical | `xhigh` | `max` |

除此之外，Runtime 对**委派任务的每个 Worker role** 都有跨 Strategy invariant：

```text
role_reasoning >= next_tier(parent_reasoning)
```

努力等级：

```text
high  → xhigh
xhigh → max
max   → max
```

因此：

```text
Parent high  → Explorer / Implementer / Reviewer 至少 xhigh
Parent xhigh → Explorer / Implementer / Reviewer 至少 max
Parent max   → Worker role 只能 max（已经没有更高档位）
```

如果用户或 Repo 把 Parent floor 强制到 `max`，Runtime 不会虚构不存在的更高档位，而是在 `ExecutionPlan.notes` 中明确记录 Worker role 只能与 Parent 同为 `max`。

### 为什么这样分配

能力更强的 Parent 负责高价值的语义工作：

```text
root cause
architecture
scope / non-goals
compatibility constraints
acceptance criteria
final verification
```

Worker 负责更长的执行循环：

```text
code exploration
hypothesis verification
implementation
tests
debugging
independent review
repair loop
```

因此在 Worker 模型显著便宜的前提下，让 Worker 使用更深 reasoning，通常比让昂贵 Parent 长时间维持高 reasoning 更符合 codex-flow 的资源目标。

### Capability 与 reasoning 分开

更高 reasoning 不等于自动换成 Parent-class model，也不能把 `latest-efficient + max` 当成 `latest-capable` 的等价替代。

ExecutionPlan v7 把角色资源明确拆开：

```text
explorer_capability_policy / explorer_model / explorer_reasoning
implementer_capability_policy / implementer_model / implementer_reasoning
reviewer_capability_policy / reviewer_model / reviewer_reasoning
```

普通 complex `quality` 任务三类角色通常仍使用 `latest-efficient + max reasoning`。

`quality_intent=strong` 或 `absolute` 时，即使技术风险只是 routine/medium，也允许：

```text
Explorer     → latest-efficient + max reasoning
Implementer  → latest-capable + max reasoning
Reviewer     → latest-capable + max reasoning
```

真正 `critical` 的复杂度/风险在 `quality_intent=normal` 下也允许 Explorer / Implementer / Reviewer 全部请求 `latest-capable`。运行时若不支持 per-spawn model/capability override，则回退到已安装 Worker baseline，并如实报告限制。

---

## Writable Worker 并行规则

多个 Implementer 仍需要硬证据：

```text
parallelism == high
write_conflict == low
writable_workstreams >= 2
```

并且具体数量受：

```text
TaskProfile.writable_workstreams
Strategy WorkerBudget.max_implementers
Runtime max_concurrent_threads
```

共同限制。

`writable_workstreams=4` 的含义是已经识别出四个互不重叠的可写 scope/worktree，而不是“希望开四个 Worker”。`absolute` 也不能绕过这条规则。

---

## Runtime 硬上限

`[runtime]`：

- `max_concurrent_threads` — **每个执行阶段**的最大并发硬上限。
- `max_repair_cycles` — re-profile / re-plan 前允许的 repair 上限。

探索、实现、Review 是不同阶段，因此 `planned_worker_count` 可以大于 `max_concurrent_threads`。

例如：

```text
2 explorers
→ 4 implementers
→ 2 reviewers
```

总计划 Worker 是 8，但任一阶段并发都不超过 4。

仓库策略与当前任务参数只能继续收紧已解析出的 Runtime ceiling。

---

## Quota 感知规划

`codex-flow strategy plan` 会通过现有 app-server telemetry 读取可靠 rate-limit 状态并归一化为：

```text
unknown | low | medium | high | critical
```

`efficient` / `balanced` 属于 quota-sensitive 策略。高/临界压力可以减少 explorer / implementer / reviewer fan-out 和 repair budget，但不会降低配置 floor，也不会破坏 Worker-role-over-Parent reasoning invariant。

`quality` 不属于 quota-sensitive 策略；特别是 `strong/absolute` 不会因为 quota 紧张而把关键 Implementer / Reviewer capability 降回 `latest-efficient`。Runtime / safety hard ceiling 仍始终有效。

```bash
codex-flow strategy plan --quota-pressure unknown --complexity complex
codex-flow strategy plan --profile quality --quality-intent absolute --quota-pressure critical
```

---

## Strategy CLI

```bash
codex-flow strategy show
codex-flow strategy profiles
codex-flow strategy set quality
codex-flow strategy routing adaptive
codex-flow strategy show --effective

codex-flow strategy plan \
  --profile quality \
  --quality-intent strong \
  --complexity complex \
  --uncertainty high \
  --risk medium \
  --scope cross-module \
  --parallelism high \
  --write-conflict low \
  --exploration-need high \
  --verification-cost medium \
  --iteration-intensity iterative \
  --writable-workstreams 4
```

Plan JSON 会同时输出：

```text
quality_intent
explorer_capability_policy
explorer_model
explorer_reasoning
implementer_capability_policy
implementer_model
implementer_reasoning
reviewer_capability_policy
reviewer_model
reviewer_reasoning
worker_budget
exploration_workers
implementation_workers
reviewer_workers
planned_worker_count
```

---

## 环境变量

| 环境变量 | Fresh-install 默认值 | 用途 |
| --- | --- | --- |
| `CODEX_FLOW_STRATEGY` | `efficient` | 全局策略 |
| `CODEX_FLOW_ROUTING_MODE` | `adaptive` | 全局路由 |
| `CODEX_FLOW_REVIEW_MODIFIER` | `auto` | Review Modifier |
| `CODEX_FLOW_FANOUT_MODIFIER` | `auto` | Fan-out Modifier |
| `CODEX_FLOW_QUOTA_PRESSURE` | 自动检测 | Quota 诊断/测试覆盖 |
| `CODEX_FLOW_PARENT_MODEL_POLICY` | `latest-capable` | Parent capability policy |
| `CODEX_FLOW_PARENT_MIN_MODEL` | `auto` | Parent model floor |
| `CODEX_FLOW_PARENT_MIN_EFFORT` | `high` | Parent reasoning floor |
| `CODEX_FLOW_WORKER_MODEL_POLICY` | `latest-efficient` | Worker baseline capability policy |
| `CODEX_FLOW_WORKER_MODEL` | `auto` | Worker baseline model request |
| `CODEX_FLOW_WORKER_MIN_EFFORT` | `xhigh` | Worker baseline reasoning floor |
| `CODEX_FLOW_MAX_THREADS` | `4` | 每阶段 Worker thread ceiling |
| `CODEX_FLOW_MAX_REPAIR_CYCLES` | `2` | Repair ceiling |
| `CODEX_FLOW_TELEMETRY_ENABLED` | `true` | Telemetry 开关 |
| `CODEX_FLOW_TELEMETRY_NOTIFICATIONS` | `true` | 系统通知开关 |
| `CODEX_FLOW_TELEMETRY_RETENTION_DAYS` | `30` | 遥测保留天数 |
| `CODEX_FLOW_LANGUAGE` | `auto` | UI 语言覆盖 |
| `CODEX_FLOW_BIN_DIR` | `~/.local/bin` | CLI 安装目录 |

`quality_intent` 故意没有对应环境变量或全局配置项，因为它必须表达当前任务的显式语义，而不是静态默认。

---

## Codex Agent fallback

全新安装时，Codex 原生 Agent baseline 为：

```toml
[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "xhigh"
```

它只是 runtime fallback，不属于某个 Strategy 的固定语义。ExecutionPlan v7 支持 per-role reasoning/capability intent；运行时不支持 override 时才使用这个 baseline。
