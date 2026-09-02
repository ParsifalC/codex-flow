# 配置系统与自适应策略

<div align="center">

[ 简体中文 ](configuration.md) | [ English ](configuration.en.md)

</div>

本文档详细说明 **codex-flow** 的配置体系、策略参数、推理强度矩阵以及环境变量覆盖规则。

---

## 配置文件路径

配置文件默认位于用户主目录下：
```text
~/.codex/codex-flow.toml
```

安装后生成的标准配置（符合 `schema_version = 3` 规范）：

```toml
schema_version = 3

[parent]
model_policy = "latest-capable"
min_model = "auto"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
complex_effort = "xhigh"
critical_effort = "max"

[worker]
model_policy = "latest-efficient"
model = "auto"
resolved_model = "gpt-5.6-luna"
min_reasoning_effort = "high"
reasoning_policy = "adaptive"
routine_effort = "high"
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

[ui]
language = "auto"
```

---

## 配置字段详解

### `[parent]`（父级规划模型策略）
- `model_policy`: `"latest-capable"` — 优先采用能力最强的大参数推理模型（负责顶层任务拆解与全局决策）。
- `min_model`: `"auto"` — 遵循官方推荐基线。
- `min_reasoning_effort`: `"high"` — 父级编排的最低推理思考强度底线。
- `reasoning_policy`: `"adaptive"` — 依据任务输入复杂度动态缩放推理强度（`high` / `xhigh` / `max`）。

### `[worker]`（子任务执行模型策略）
- `model_policy`: `"latest-efficient"` — 优先采用高吞吐、高性价比的经济型模型（负责具体编码、执行与探索）。
- `model`: `"auto"` — 自动匹配本地环境可用模型。
- `resolved_model`: `"gpt-5.6-luna"` — 默认固定的子任务执行模型。
- `min_reasoning_effort`: `"high"` — 子任务执行的推理基线。
- `reasoning_policy`: `"adaptive"` — 在复杂重构、架构探索和排障时自适应上调。

### `[runtime]`（运行时控制）
- `max_concurrent_threads`: `4` — 子 Agent 最大并行并发数。
- `max_repair_cycles`: `2` — 自动自我修复重试上限，超限后升级至 Parent 重新仲裁。

### `[telemetry]`（遥测与通知）
- `enabled`: `true` — 启用确定性 Token 与配额记录。
- `summary`: `true` — 任务结束后在终端输出格式化卡片。
- `notifications`: `true` — 发送 macOS 系统通知中心弹窗。
- `retention_days`: `30` — 日志与历史保留天数。
- `source`: `"hooks+app-server"` — 遥测数据采集源。

### `[ui]`（用户界面语言）
- `language`: `"auto"` — 支持 `"auto"`（随系统）、`"zh"`（简体中文）、`"en"`（English）。

---

## 推理强度策略矩阵 (Reasoning Effort Matrix)

| 任务复杂度等级 | Parent 推理强度 | Worker 推理强度 | 适用工作负载示例 |
| :--- | :--- | :--- | :--- |
| **常规日常 (Routine)** | `high` | `high` | 文档更新、单文件微调、常规脚本修补 |
| **复杂工程 (Complex)** | `xhigh` | `xhigh` | 多文件跨模块特性开发、接口深度重构、并发 Bug 排查 |
| **关键核心 (Critical)** | `max` | `max` | 核心架构重构、底层内核调试、安全性漏洞加固 |

---

## 环境变量即时覆盖 (Environment Variables)

无需修改 TOML 文件即可通过环境变量直接覆盖任意参数：

| 环境变量 | 覆盖配置项 | 示例取值 |
| :--- | :--- | :--- |
| `CODEX_FLOW_PARENT_MODEL` | `parent.model_policy` | `gpt-5.6-sol` |
| `CODEX_FLOW_WORKER_MODEL` | `worker.model` | `gpt-5.6-luna` |
| `CODEX_FLOW_PARENT_EFFORT` | `parent.routine_effort` | `high` / `xhigh` / `max` |
| `CODEX_FLOW_WORKER_EFFORT` | `worker.routine_effort` | `high` / `xhigh` / `max` |
| `CODEX_FLOW_THREADS` | `runtime.max_concurrent_threads` | `8` |
| `CODEX_FLOW_TELEMETRY` | `telemetry.enabled` | `true` / `false` |
| `CODEX_FLOW_UI_LANG` | `ui.language` | `zh` / `en` |
