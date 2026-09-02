# Worker Lifecycle Runtime

本文定义 FlowPilot ExecutionPlan v8 的异步 Worker 生命周期语义。目标不是让 Parent 更少等待，而是让 Parent 与 Worker 的并行工作尽可能有效，同时减少重复执行、已投入但被丢弃的 Worker 工作和无价值等待。

## 设计原则

Strategy Runtime 决定期望资源拓扑与 StagePolicy；FlowPilot 负责观察真实运行状态并执行该策略。

```text
TaskProfile
    ↓
StrategySpec
    ↓
ExecutionPlan v8
    ↓
Async Worker Scheduler semantics
    ├─ scope tracking
    ├─ progress lease
    ├─ join policy
    ├─ quorum
    ├─ supersede
    ├─ stall detection
    └─ delta fallback
```

Runtime 不把一次 `wait()` 返回超时解释成 Worker 超时。高 reasoning Worker 可能执行较慢；只要仍有可观察进展，它就是 `progressing`。

## StagePolicy

每个存在 Worker 的阶段都会得到一个策略生成的 StagePolicy：

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

`idle_timeout_seconds` 是可续期的 progress lease：新命令完成、新文件/搜索证据、新工具事件或其他明确活动都会刷新它。长时间正在执行且可见为 in-flight 的工具调用也不能仅因为 Parent 的 wait 返回而视为 idle。

`hard_timeout_seconds` 从 Worker 启动时计时，防止真正 runaway。策略值仍受 Runtime 硬上限约束。

## Worker 状态

FlowPilot 使用以下语义状态：

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

- `progressing`：持续产生新的可观察活动或存在明确 in-flight 工作。
- `stalled`：超过 StagePolicy 的 idle lease，且没有可观察进展。
- `failed`：Agent/工具/runtime 明确终止失败。
- `superseded`：同一 bounded scope 已被 Parent 或另一个执行者用等价证据覆盖，继续执行不再有边际价值；只有 `cancel_if_superseded=true` 才可因此取消。

如果当前 Codex runtime 不能可靠暴露中间活动，FlowPilot 不得凭 `wait()` 次数猜测 `stalled`；只能依据可用的终态/活动证据和 hard timeout。

## Scope tracking

每个 Worker 在 spawn 时必须得到稳定的 `scope_id` 和 bounded scope。不同 Worker 不应重复同一 scope，除非计划明确要求独立重复验证。

Parent 默认继续执行与 Worker 不重叠的工作，直到真正依赖 Worker 结论的 join point。Parent 不应为了“等 Worker”立即停止自己的独立工作。

`superseded` 是 overlap-aware cancellation，而不是 timeout：

- PR metadata Worker 尚未完成，但 Parent 已完成同一 PR metadata 检查：可以 supersede。
- Runtime 深度 reviewer 正持续审查，而 Parent 只在做 Logo/构建：scope 未覆盖，不可因为运行时间长而 supersede。

## Join policy

### opportunistic

阶段结果是 best effort。Parent 不专门阻塞等待；已返回的结果可消费。典型用于 `speed` 的 speculative exploration。

### quorum

达到 `min_successful_workers` 后可进入下一阶段，但只有没有剩余独特价值的 straggler 才能按策略取消。数字 quorum 本身不等于“所有剩余不同 scope 都无价值”。

### required

所有尚未被允许 supersede 的 assigned scope 都必须得到覆盖，并满足最小成功 Worker 结果要求。典型用于 implementation 与高价值 independent review。

## Fallback

Fallback 永远基于缺失 delta，而不是从头重复完整阶段：

- `continue_partial`：已有证据足够时继续。
- `parent_delta`：Parent 只补未覆盖 scope。
- `replan`：重新 profile/compile，只针对剩余问题生成新计划。
- `fail`：不自动替代，向上报告失败。

Worker timeout/stall 不消耗 `max_repair_cycles`；repair cycle 只用于实现缺陷后的修复。

## Built-in strategy defaults

### efficient

- exploration：quorum=1，快速 supersede/裁剪无价值 straggler。
- implementation：required；失败或 stall 重新规划。
- review：quorum=1；普通审查允许 Parent delta fallback。

目标是减少 abandoned work 和 duplicated work。

### balanced

- exploration：quorum=1，中等 progress lease。
- implementation：required。
- review：required，但允许在 scope 已有等价覆盖时 supersede。

目标是平衡质量、成本和 wall-clock latency。

### quality

- exploration：quorum 目标为 2（实际 Worker 少时自动归一化），给深 reasoning 更长 lease，不因达到 quorum 自动杀掉仍有独立价值的 Worker。
- implementation：required。
- review：required，目标为 2；不能被 Parent 静默 supersede，缺失独立证据时 replan。

目标是避免 premature cancellation，而不是无限等待。

### speed

- exploration：opportunistic，不为 speculative Worker 阻塞主流程。
- implementation：required，但 hard timeout 更短。
- review：quorum=1，优先 wall-clock latency。

## 典型场景

### PR metadata Worker 较慢，但 Parent 已完成同一检查

Worker scope 已有等价证据：`superseded → cancelled`。这是正确节省，不属于 Worker 失败。

### Luna max 深度审查持续读文件/跑命令，但两次 wait 没返回最终结果

Worker 保持 `progressing`；wait timeout 不改变其状态。Parent 继续独立工作，到 join point 再根据 StagePolicy 判断。不得仅因为“连续两次 wait 超时”终止。

### 两路 reviewer 分别审 Runtime 和跨平台安装

两个 scope 互补。Parent 做其他独立工作；进入 join point 后，如果两个 reviewer 都在 progressing 且 policy=required，应让它们完成，而不是终止后由 Parent 从头重复两个 scope。

### Worker 长时间无任何可观察活动

超过 idle lease 后进入 `stalled`，按 fallback policy 做 parent delta 或 replan。真正 stall 不会无限占资源。

### 三个 Explorer 中一个已经找到根因

如果另外两个 scope 已因该证据失去价值，可 supersede/cancel；如果仍检查独立关键未知项，则继续。达到 numeric quorum 不是自动取消所有剩余 Worker 的理由。

### Implementation Worker 已开始写独立 worktree

默认 required 且 `cancel_if_superseded=false`。除明确失败、stall 或 hard timeout 外不随意终止；失败后 replan，避免半截 patch 与 Parent 重复实现。

## Runtime invariants

1. `wait()` timeout 永远不等价于 Worker timeout。
2. 可观察进展会续期 idle lease。
3. 取消 progressing Worker 必须有策略允许的 superseded/straggler 原因，或达到 hard timeout。
4. Parent fallback 只补未覆盖 delta，不从头复制 Worker 的完整工作。
5. Implementation failure 和 Worker lifecycle failure 不计入 repair cycle。
6. Strategy-specific lifecycle 只存在于 StrategySpec；generic Runtime 不按 built-in strategy 名称分支。
