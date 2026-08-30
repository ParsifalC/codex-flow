---
name: cost-aware-development
description: Route non-trivial software engineering work through a qualifying high-capability parent for planning/review and cheaper workers for exploration, implementation, testing, debugging, and bounded repair. Adapt reasoning effort to task difficulty while keeping high as the normal minimum.
---

# Cost-Aware Development

Optimize expensive-token efficiency while preserving correctness. The policy is capability-driven, not tied to a permanent model slug.

## 0. Load policy and honor explicit routing overrides

When `~/.codex/codex-flow.toml` exists, use it as the policy source.

Before normal classification/routing, inspect the current user task for an explicit routing override. A clear current-task instruction has higher priority than codex-flow defaults or persistent routing policy.

Supported current-task modes:

- `direct` — do not spawn or delegate to subagents for this task. The active parent performs implementation and self-review directly.
- `delegate` — use subagent delegation for execution when the runtime supports it and the task can be safely scoped.
- `adaptive` — use normal codex-flow classification and routing for this task.

Treat unambiguous natural-language equivalents as the same current-task override. Examples include:

- direct: `direct`, `不要使用子 agent，直接完成`, `这次直接做`, `跳过 worker`, `不用 delegation`
- delegate: `delegate`, `使用子 agent`, `这次交给 worker 实现`
- adaptive: `adaptive`, `按默认策略`, `自动决定是否使用子 agent`

Do not infer an override from incidental mentions of these words. Only honor an explicit instruction about how the current task should be executed. If multiple routing instructions conflict, follow the latest unambiguous instruction in the current user task.

Routing override scope is the current task only. Do not persist or rewrite user configuration because of a prompt-level override.

`direct` disables delegation only. It does not disable task classification, adaptive reasoning effort, validation, acceptance criteria, bounded retry, or review discipline. In direct mode, collapse the normal parent -> worker -> parent path into parent -> implementation -> self-review.

Default parent eligibility:
- prefer the latest available high-capability model
- minimum reasoning effort is `high`
- exact model floor is configurable; `auto` means follow the current codex-flow recommendation/runtime capability

Default worker policy:
- prefer the latest cost-efficient model suitable for coding work
- `model = "auto"` resolves to the current codex-flow recommendation at install/update time
- reasoning baseline is `high`
- task-specific escalation may request `xhigh` or `max`

Never require one historical model name such as `gpt-5.6-sol` to qualify.

If the active parent is known to be below the configured floor, do not pretend it qualifies. Elevate when the runtime supports it; otherwise keep the work direct and surface a concise policy warning.

## 1. Classify before spending

Classify the engineering task as SMALL, ROUTINE, COMPLEX, or CRITICAL.

SMALL:
- obvious localized change
- usually one or two files
- low uncertainty and regression risk
- little exploration/testing

ROUTINE:
- clear implementation plan
- several files may change
- normal tests/debugging
- no major architecture decision

COMPLEX:
- unclear root cause, difficult debugging, refactor/migration
- architecture/compatibility decisions
- substantial exploration or cross-system impact

CRITICAL:
- security-sensitive change
- destructive/data migration
- production-critical infrastructure or integrity risk
- repeated lower-effort failure where quality dominates cost

SMALL work stays with the parent. In `adaptive` mode, delegate ROUTINE/COMPLEX/CRITICAL execution when useful. In `direct` mode, keep all execution with the parent. In `delegate` mode, prefer delegation when the runtime supports it and safe scoping is possible.

## 2. Choose the lowest sufficient effort

Use the configured floor and never go below it.

Default routing:

| Class | Parent planning/review | Worker execution |
| --- | --- | --- |
| SMALL | `high` or current qualifying effort | direct; no worker unless explicitly delegated and useful |
| ROUTINE | `high` | `high` |
| COMPLEX | `xhigh` when available/justified | `xhigh` when available/justified |
| CRITICAL | `xhigh` or `max` | `xhigh` or `max` only when quality-first |

Do not use `max` merely because it exists. Escalate one level only when task risk/complexity or actual failure evidence justifies it.

When the current Codex spawn surface supports per-child reasoning/model overrides, request the selected worker effort for that child. When it does not, use the installed high baseline and compensate with tighter scope, evidence, and review rather than relying on a broken override path.

## 3. Explore cheaply

Unless the current task is in `direct` mode, delegate bounded read-only investigations for substantial repository discovery. Parallelize only independent questions such as implementation/call sites, tests/fixtures, workflow/config paths, or compatibility constraints.

Prefer `worker-explorer` when named roles are supported. Otherwise use a normal child with explicit read-only instructions. Do not duplicate investigations or dump entire repositories into parent context.

In `direct` mode, perform the same targeted exploration in the active parent context without spawning subagents.

## 4. Parent decides

Before broad implementation, the qualifying parent owns:
- root cause / architecture
- scope and non-goals
- implementation sequence
- compatibility constraints
- risks
- acceptance criteria

Do not delegate an ambiguous "go solve this" if the parent can cheaply remove ambiguity first.

## 5. Compact handoff

When delegation is active, send only:
- Goal
- Root cause/design decision
- Scope
- Relevant files/components
- Steps
- Constraints/non-goals
- Acceptance criteria
- Required validation

Prefer fresh/no-history child context when supported. Do not hydrate a worker with irrelevant parent history.

Skip this handoff stage entirely in `direct` mode.

## 6. Worker implements and proves

When delegation is active, the worker makes the scoped change, runs the narrowest relevant validation first, fixes failures caused by the patch, avoids unrelated cleanup, and returns:
- changed files
- concise implementation summary
- validation commands/results
- deviations
- unresolved risks/failures

Return evidence, not verbose logs.

In `direct` mode, the parent follows the same implementation and validation discipline itself.

## 7. Parent reviews, not reimplements

Review `git diff --stat`, the actual relevant diff, directly affected call sites, validation evidence, every acceptance criterion, architecture consistency, and regression risk.

Expand investigation only for a concrete review concern. PASS only when criteria are satisfied with adequate evidence.

In `direct` mode this is a self-review pass by the same parent after implementation; do not skip it merely because no worker was used.

## 8. Repair with bounded delta tasks

On failure, send only the exact defect, impact, required correction, relevant file/symbol, and validation required. Do not resend the original task.

Use the configured maximum repair cycles (default 2). If repeated repairs fail, reassess root cause/plan and optionally escalate effort/model capability rather than continuing a blind loop.

In `direct` mode, apply the same bounded repair policy in the parent context without spawning a worker.

## Context discipline

Prefer targeted search, diff-scoped review, concise test modes, and small relevant excerpts. Avoid full repo dumps, full verbose logs, rereading unchanged files, duplicate agents, and parent reimplementation.

## Concurrency discipline

Parallelize independent read-only exploration only when delegation is allowed. Do not run overlapping writable workers on the same files/worktree; isolate genuinely independent workstreams.

The invariant is: explicit user routing intent wins for the current task; qualifying high-capability reasoning makes decisions; cost-efficient execution performs loops when delegation is allowed; effort rises only when the task proves it needs to.
