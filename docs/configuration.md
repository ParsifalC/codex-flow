# Configuration & Adaptive Strategy

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
- `reasoning_policy`: `"adaptive"` — Dynamically adjusts reasoning effort based on task complexity.
- `routine_effort`, `complex_effort`, `critical_effort`: Effort targets for each tier (`high`, `xhigh`, `max`).

### `[worker]`
- `model_policy`: `"latest-efficient"` — Selects the most cost-effective and coding-capable model.
- `model`: `"auto"` — Auto-resolved to the latest recommended worker model (e.g., `gpt-5.6-luna`).
- `resolved_model`: Current pinned/resolved model identifier.
- `min_reasoning_effort`: Default lower bound for worker tasks.
- `reasoning_policy`: `"adaptive"` — Worker reasoning adapts along with the parent's task categorization.

### `[runtime]`
- `max_concurrent_threads`: Maximum concurrent worker threads per session (default: `4`).
- `max_repair_cycles`: Maximum repair iterations when external verifier reports errors (default: `2`).

### `[telemetry]`
- `enabled`: `true` — Activates lifecycle hooks and transcript token tracking.
- `summary`: `true` — Emits formatted terminal summary upon task completion.
- `notifications`: `true` — Sends macOS Notification Center alerts.
- `retention_days`: `30` — Number of days to retain run telemetry JSON files.
- `source`: `"hooks+app-server"` — Data sources for usage extraction and rate-limit tracking.

### `[ui]`
- `language`: `"auto"` (`"zh"` / `"en"`) — Language for CLI, notifications, and interactive console.

---

## Reasoning Effort Matrix

The core philosophy is **"use the lowest qualified reasoning effort sufficient to accomplish the task"**, avoiding unconditional maximums:

| Task Class | Parent Reasoning | Worker Reasoning | Delegation Trigger |
| :--- | :--- | :--- | :--- |
| **SMALL** | `high` or current qualified | None (executed directly) | Single-file, localized, trivial changes |
| **ROUTINE** | `high` | `high` | Standard multi-file edits, straightforward features |
| **COMPLEX** | `high` / `xhigh` | `high` / `xhigh` | Architecture refactoring, cross-module migrations |
| **CRITICAL** | `xhigh` / `max` | Quality-first (`xhigh`/`max`) | Atomic state mutations, zero-downtime data migrations |

> **Note**: `max` reasoning is never a blanket default. It is only activated when task complexity or prior lower-tier failures justify it.

---

## Environment Variable Overrides

Any configuration item can be temporarily or permanently overridden via environment variables during installation or execution:

| Environment Variable | Default Value | Description |
| :--- | :--- | :--- |
| `CODEX_FLOW_PARENT_MODEL_POLICY` | `latest-capable` | Parent model selection policy |
| `CODEX_FLOW_PARENT_MIN_MODEL` | `auto` | Parent baseline model requirement |
| `CODEX_FLOW_PARENT_MIN_EFFORT` | `high` | Parent minimum reasoning effort |
| `CODEX_FLOW_WORKER_MODEL_POLICY` | `latest-efficient` | Worker model selection policy |
| `CODEX_FLOW_WORKER_MODEL` | `auto` | Pinned worker model or auto |
| `CODEX_FLOW_WORKER_MIN_EFFORT` | `high` | Worker minimum reasoning effort |
| `CODEX_FLOW_MAX_THREADS` | `4` | Maximum parallel worker threads |
| `CODEX_FLOW_MAX_REPAIR_CYCLES` | `2` | Maximum automatic repair retries |
| `CODEX_FLOW_TELEMETRY_ENABLED` | `true` | Telemetry capture toggle |
| `CODEX_FLOW_TELEMETRY_NOTIFICATIONS`| `true` | macOS Notification Center alerts |
| `CODEX_FLOW_TELEMETRY_RETENTION_DAYS`| `30` | Run telemetry log retention (days) |
| `CODEX_FLOW_LANGUAGE` | `auto` | Per-process UI language override |
| `CODEX_FLOW_BIN_DIR` | `~/.local/bin` | Binary installation directory |
| `CODEX_FLOW_SHELL` | `basename $SHELL` | Target shell for path & auto-completion |
| `CODEX_FLOW_SHELL_CONFIG_DIR` | `$HOME` | Directory housing shell configuration files |

---

## Codex Agent Runtime Fallback

During installation, `codex-flow` also configures Codex's native `[agents]` runtime in `~/.codex/config.toml` to guarantee graceful subagent execution:

```toml
[agents]
enabled = true
max_concurrent_threads_per_session = 4
default_subagent_model = "gpt-5.6-luna"
default_subagent_reasoning_effort = "high"
```

This ensures consistent fallback behavior without altering the user's primary interactive session model.
