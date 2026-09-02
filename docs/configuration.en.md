# Configuration & Adaptive Strategy

<div align="center">

[ 简体中文 ](configuration.md) | [ English ](configuration.en.md)

</div>

This document details the configuration system, policy parameters, reasoning levels, and environment overrides for **codex-flow**.

---

## Configuration File

The configuration file is located at:
```text
~/.codex/codex-flow.toml
```

When installed without custom environment overrides, `codex-flow` generates a configuration conforming to `schema_version = 3`:

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

## Configuration Reference

### `[parent]`
- `model_policy`: `"latest-capable"` — Always favors the strongest reasoning model.
- `min_model`: `"auto"` — Follows codex-flow recommended baseline.
- `min_reasoning_effort`: `"high"` — Minimum reasoning level for parent orchestration.
- `reasoning_policy`: `"adaptive"` — Dynamically scales effort (`high`, `xhigh`, `max`) according to prompt complexity.

### `[worker]`
- `model_policy`: `"latest-efficient"` — Prefers high-throughput, cost-effective models.
- `model`: `"auto"` — Resolves automatically against local availability.
- `resolved_model`: `"gpt-5.6-luna"` — Pinned default worker model.
- `min_reasoning_effort`: `"high"` — Baseline reasoning floor for worker tasks.
- `reasoning_policy`: `"adaptive"` — Escalates effort for refactoring, architecture, and debugging subtasks.

### `[runtime]`
- `max_concurrent_threads`: `4` — Maximum subagents running in parallel.
- `max_repair_cycles`: `2` — Maximum automatic self-correction attempts before escalation.

### `[telemetry]`
- `enabled`: `true` — Activates deterministic token and quota recording.
- `summary`: `true` — Displays terminal summary cards after task completion.
- `notifications`: `true` — Dispatches macOS Notification Center alerts.
- `retention_days`: `30` — Log retention period.
- `source`: `"hooks+app-server"` — Telemetry ingestion channels.

### `[ui]`
- `language`: `"auto"` — Supported values: `"auto"`, `"en"`, `"zh"`.

---

## Reasoning Effort Matrix

| Task Complexity | Parent Effort | Worker Effort | Target Workloads |
| :--- | :--- | :--- | :--- |
| **Routine** | `high` | `high` | Documentation, formatting, small script tweaks |
| **Complex** | `xhigh` | `xhigh` | Multi-file features, interface refactoring, bug tracing |
| **Critical** | `max` | `max` | Architectural migrations, kernel debugging, security auditing |

---

## Environment Variable Overrides

Any configuration key can be overridden via environment variables without editing the TOML file:

| Environment Variable | Overrides | Example Value |
| :--- | :--- | :--- |
| `CODEX_FLOW_PARENT_MODEL` | `parent.model_policy` | `gpt-5.6-sol` |
| `CODEX_FLOW_WORKER_MODEL` | `worker.model` | `gpt-5.6-luna` |
| `CODEX_FLOW_PARENT_EFFORT` | `parent.routine_effort` | `high` / `xhigh` / `max` |
| `CODEX_FLOW_WORKER_EFFORT` | `worker.routine_effort` | `high` / `xhigh` / `max` |
| `CODEX_FLOW_THREADS` | `runtime.max_concurrent_threads` | `8` |
| `CODEX_FLOW_TELEMETRY` | `telemetry.enabled` | `true` / `false` |
| `CODEX_FLOW_UI_LANG` | `ui.language` | `zh` / `en` |
