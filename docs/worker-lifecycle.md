# Worker Lifecycle Runtime

本文定义 FlowPilot ExecutionPlan v8 的异步 Worker 生命周期语义。目标不是简单让 Parent 少等待，而是最大化 Parent 与 Worker 的有效并行工作，同时减少重复执行、被丢弃的 Worker 工作和无价值等待。

## 架构

```text
TaskProfile
    ↓
StrategySpec
    ↓
ExecutionPlan v8 / StagePolicy
    ↓
FlowPilot scope observations
    ↓
Deterministic lifecycle evaluator
    ├─ progress lease
    ├─ hard timeout
    ├─ supersession
    ├─ fallback
    └─ writable writer fencing
```

Strategy Runtime 决定期望资源拓扑和 StagePolicy；FlowPilot 只提供可观察事实，例如 Worker 是否仍在活动、scope 是否已被覆盖、是否已经终止。时间计算、stall/fallback、旧 Worker 是否必须回收以及 downstream writer 是否允许进入 writable scope，由 `scripts/strategies/lifecycle_runtime.py` 确定性计算。

该 helper 随 `strategies/` 目录一起被 Unix/Windows 安装器复制到 `~/.codex/codex-flow/strategies/lifecycle_runtime.py`。

## StagePolicy

每个存在 Worker 的阶段会得到：

```text
join_policy
  opportunistic | quorum | required

min_successful_workers
idle_timeout_seconds
hard_timeout_seconds
cancel_if_superseded
cancel_stragglers_after_quorum
fallback_policy
  continue_partial | parent_delta | replan | fail
```

`idle_timeout_seconds` 是可续期 progress lease，不是完成 deadline。新的命令、文件读取、搜索、工具事件或明确可见的 in-flight 操作都说明 Worker 仍可能健康。

`hard_timeout_seconds` 是绝对 wall-clock 上限，即使存在 in-flight 操作也不能无限运行。

## Worker 状态

```text
queued
running
progressing
completed
stalled
failed
superseded
cancelled
```

- `progressing`：存在近期可观察活动或明确 in-flight 工作。
- `stalled`：idle lease 已过期，且没有可见 in-flight 工作。
- `failed`：Agent/tool/runtime 明确终止失败。
- `superseded`：同一 bounded scope 已被 Parent 或其他执行路径用等价证据覆盖，并且 StagePolicy 允许取消。
- `cancelled`：取消/终止已得到确认。

**Parent 的 `wait()` 返回超时永远不等于 Worker timeout。** 连续两次甚至更多次 wait 没有最终结果，也不能单独把高 reasoning Worker 判为 stalled。

如果当前 Codex runtime 无法可靠暴露中间活动，不得猜测 idle 状态；只能依据明确活动、终态、supersession 或 hard timeout。

## Scope-aware fork/join

每个 Worker spawn 前必须获得稳定的 `scope_id`。Parent 默认继续执行与 Worker scope 不重叠的工作，只有到真实依赖点才 join。

- PR metadata Worker 还没结束，但 Parent 已取得相同 metadata/checks：可以 `superseded`。
- Runtime reviewer 持续读代码，而 Parent 在处理 Logo/build：scope 互补，不能因为耗时较长而取消。

`quorum` 只是阶段最低成功结果数量，不意味着所有剩余独立 scope 自动失去价值。`cancel_stragglers_after_quorum=true` 也只允许取消已经没有独立 acceptance value 的 straggler。

## Deterministic evaluator

FlowPilot 在需要做 lifecycle 决策时，把 StagePolicy 与实际观察传给 evaluator。三个时间参数必须使用**秒级 Unix timestamp**，例如 Python `time.time()`；不要传 JavaScript/telemetry 常见的 13 位毫秒时间戳。evaluator 会对明显的毫秒输入 fail-fast，而不是自动 `/1000`。

```bash
python3 ~/.codex/codex-flow/strategies/lifecycle_runtime.py \
  --policy-json '<stage-policy-json>' \
  --scope-id <scope> \
  --stage exploration|implementation|review \
  --started-at <unix-seconds> \
  --last-progress-at <unix-seconds> \
  --now <unix-seconds> \
  [--writable] [--in-flight] \
  [--terminal-success] [--terminal-failure] \
  [--scope-superseded] [--cancel-confirmed] \
  [--replacement-isolated]
```

输出包括：

```text
state
action
reason
cancel_required
replacement_allowed
fence_required
idle_seconds
wall_seconds
fallback_policy
```

`cancel_required=true` 表示 Worker 仍是非终态，即使 `action` 已允许 `parent_delta`、`continue_partial` 或 isolated `replan`，Scheduler 仍必须请求回收旧 Worker。这样 read-only fallback 不会把超时 Worker 留在后台继续消耗资源；对 writable Worker，`fence_required` 还会进一步约束任何新的 writer。

`fallback_policy` 只在失败、取消或 stall 等确实需要 fallback 的决策中返回；成功或已 superseded 且 scope 已满足时为 `null`，避免消费端误以为还需要补做工作。

这样 StagePolicy 是 deterministic 的，状态跃迁、timeout/fallback 和 cancellation requirement 也不再由 Parent 临场重新发明。

## Writable writer fencing

这是 Runtime hard safety invariant，任何 strategy 都不能关闭。

真正需要保护的不是“replacement Worker”这个角色，而是**任何新的 writer**。只要 implementation Worker 已拥有 writable scope，且非终态 Worker 发生 stall / hard timeout，以下 fallback 都会产生新的 writer：

- `parent_delta`：Parent 将成为 downstream writer；
- `replan`：新的 Implementer/执行路径将成为 downstream writer。

这两种路径都必须先满足同一 hard fence：

```text
旧 Worker 仍可能恢复写入
        ↓
禁止新的 writer 进入同一 live scope
        ↓
request_cancel
        ↓
cancel/termination confirmed
        ↓
Parent delta 或 replan replacement 才能写入
```

如果运行时不能可靠终止旧 Worker，允许另一条安全路径：

```text
旧 Worker 非终态
        ↓
请求取消旧 Worker（cancel_required=true）
        ↓
新的 downstream writer 使用全新 isolated worktree
        ↓
旧 Worker 输出被 fencing，禁止参与 integration
        ↓
Parent delta 或 replan 可以继续
```

`replacement_allowed` 只描述 `replan` 是否允许拉起 replacement Worker；`parent_delta` 不需要这个字段变为 true。对两种 writer fallback，`fence_required=true` 才是统一安全信号。

因此不会出现 stalled Worker A 恢复后与 Parent 或 replacement Worker B 同时修改同一 writable scope 的竞态。

## Fallback

Fallback 永远只处理 missing delta：

- `continue_partial`：现有证据已足够时继续。
- `parent_delta`：Parent 只补缺失 scope；若是 writable implementation delta，必须先满足 writable writer fence。
- `replan`：只针对剩余 delta 重新 profile/compile；若会产生新的 writable Implementer，同样必须先满足 fence。
- `fail`：报告未解决失败，不静默替换。

对非终态 `stalled` / hard-timeout Worker，fallback 可以继续推进，但 `cancel_required=true` 会同时要求回收旧 Worker。

Worker lifecycle failure 不消耗 `max_repair_cycles`；repair cycle 只用于实现产物本身的缺陷修复。

## Built-in strategy defaults

- **efficient**：quorum exploration、积极裁掉冗余只读工作、required implementation、轻量 quorum review。
- **balanced**：quorum exploration、required implementation、required review，可按等价 scope supersede。
- **quality**：更长 lease、exploration quorum 目标 2、required implementation、required independent review 目标 2，不允许 Parent 静默替代 required reviewer。
- **speed**：opportunistic exploration、较短 lease、required implementation、quorum review。

这些 strategy preference 都受 Runtime hard ceiling、cancellation requirement 和 writable writer fencing 约束。

## 典型场景

### Luna max 持续工作，但多次 wait 没返回

只要仍有文件读取、命令、搜索或明确 in-flight 活动，保持 `progressing`。Parent 继续非重叠工作，到 join point 再处理，不因 wait 次数终止。

### 两路互补 reviewer 都较慢

一个审 Runtime，一个审安装/跨平台。只要两个都 progressing 且 scope 互补，就继续；不得终止后让 Parent 从头重复两个 review scope。

### Read-only Worker 已被 Parent 覆盖

scope 有等价证据且 policy 允许 supersession：`superseded → request_cancel`。这是基于边际价值取消，不是基于耗时。

### Read-only Worker stall

可以按 `parent_delta` 等 fallback 继续主流程，但 evaluator 同时返回 `cancel_required=true`，要求旧 Worker 回收，避免 hard/idle ceiling 变成只写在文档里的数字。

### Writable Worker stall，Parent 准备接管

`parent_delta` 也会创建新的 writer，因此不能让 Parent 直接在旧 Worker 的 live scope 里继续写。先确认旧 Worker 已终止，或者让 Parent 在新的 isolated worktree 中补 missing delta，并 fence 旧输出。

### Writable Worker stall，需要 replacement

不能直接 `replan → spawn same-scope replacement`。先终止旧 Worker，或者把 replacement 放进新 isolated worktree 并 fence 旧输出；无论哪种路径，非终态旧 Worker 都必须请求取消。

## Runtime invariants

1. `wait()` timeout 永远不等价于 Worker timeout。
2. evaluator 时间参数统一使用秒级时间戳；明显的毫秒输入直接报错。
3. 可观察进展续期 idle lease。
4. hard timeout 是绝对上限。
5. supersession 必须基于 scope 等价覆盖，而不是耗时。
6. Parent fallback 只补 missing delta。
7. 非终态 lifecycle exit 必须显式表达 `cancel_required=true`，不能让超时 Worker 静默留在后台。
8. writable downstream writer（Parent 或 replacement）必须满足 `old terminal OR new isolated+fenced`。
9. lifecycle failure 不消耗 implementation repair cycle。
10. Strategy-specific lifecycle preference 留在 StrategySpec；hard safety invariants 由 deterministic lifecycle evaluator 统一执行。
