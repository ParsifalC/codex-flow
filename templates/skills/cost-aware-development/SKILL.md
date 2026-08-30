---
name: cost-aware-development
description: Route non-trivial software engineering work through a high-capability parent for planning and review while delegating exploration, implementation, testing, debugging, and bounded repair loops to cheaper workers. Use for medium/large coding tasks, refactors, migrations, CI/CD, infrastructure, debugging, and multi-file changes.
---

# Cost-Aware Development

Optimize for expensive-token efficiency, not minimum raw token count.

The policy is capability-driven, not tied to a specific flagship model name.

## 0. Apply the parent capability policy

When `~/.codex/codex-flow.toml` exists, treat it as the policy source.

The default policy is:
- prefer the latest available high-capability model for the parent role
- parent reasoning effort must be at least `high`
- the exact minimum model can be `auto` or explicitly configured
- worker model and effort are independently configurable

Do not require `gpt-5.6-sol` or `xhigh` specifically.

If the current parent satisfies the configured model policy and minimum reasoning effort, it may own planning and final review.

If the current parent is below the configured minimum, prefer automatic elevation to a qualifying model/reasoning level when the current Codex runtime supports it. Otherwise, avoid pretending the threshold is satisfied: keep the task direct or surface a concise warning that the active parent is below policy.

`high`, `xhigh`, and `max` all satisfy a default minimum of `high`. Do not increase to `max` mechanically; use the lowest qualifying effort that is appropriate for the task.

## 1. Classify the task

Handle directly when the task is genuinely small:
- obvious localized change
- one or two files
- little architectural uncertainty
- little or no exploratory work
- low regression risk

Use delegation when the task is medium or large:
- multiple files or systems
- unclear root cause
- architecture or compatibility decisions
- refactor or migration
- CI/CD or infrastructure
- meaningful test/debug loops
- substantial repository exploration

Do not create multi-agent overhead for trivial work.

## 2. Explore cheaply when needed

Delegate bounded read-only investigations before planning when repository discovery would otherwise consume substantial parent context.

Good parallel investigations are independent, for example:
- locate implementation and call sites
- locate tests and fixtures
- inspect workflow/configuration paths
- identify compatibility constraints

Do not spawn several agents to answer the same question.
Do not use writable workers for exploration.

When the runtime supports named custom agents, prefer `worker-explorer`. Otherwise use a normal subagent and explicitly instruct it to remain read-only and concise.

## 3. Parent plans

Before broad implementation, the qualifying parent owns and resolves:
- root cause or intended architecture
- scope and non-goals
- files/components likely affected
- implementation sequence
- compatibility constraints
- regression risks
- acceptance criteria

Do not delegate an ambiguous request as "go solve this" when the parent can cheaply remove ambiguity first.

## 4. Build a compact handoff packet

Delegate implementation with only the information needed to execute:
- Goal
- Root cause / design decision
- Scope
- Relevant files/components
- Implementation steps
- Constraints and non-goals
- Acceptance criteria
- Required validation

Prefer a fresh child or no-history fork when supported. Avoid transferring irrelevant conversation history.

When the runtime supports named custom agents, prefer `worker-implementer`. Otherwise the configured default subagent is the implementation worker.

## 5. Worker implements and verifies

The worker should:
- make the complete scoped change
- run targeted validation first
- fix failures caused by the change
- avoid unrelated cleanup
- summarize changed files and evidence

Do not send verbose build logs back to the parent. Return exit codes, failing test names, relevant excerpts, and final status.

## 6. Parent reviews instead of reimplementing

After the worker returns, inspect:
- `git diff --stat`
- the actual diff
- changed files and directly affected call sites
- validation evidence
- each acceptance criterion
- regression and architecture risk

Do not solve the whole task again.
Expand investigation only when a concrete review concern requires it.

PASS when the implementation satisfies the plan and acceptance criteria with adequate evidence.

## 7. Repair with delta tasks

If review fails, formulate a bounded repair task containing only:
- exact defect
- impact
- required correction
- relevant file/symbol
- validation required

Return the delta to the worker instead of resending the full original task.

Allow at most two implementation/review repair cycles. After repeated failure, reassess the root cause or plan at the parent level rather than continuing an expensive blind loop.

## Reasoning policy

Treat reasoning effort as a threshold plus task-adaptive choice, not a fixed constant.

Default guidance:
- parent planning/review: `high` minimum
- routine worker execution: `high`
- difficult debugging/refactor worker: `xhigh`
- `max`: only when the task is genuinely quality-first and lower qualifying levels are insufficient

When a newer model family becomes the current recommended generation, prefer it automatically when the runtime exposes a stable current-model choice. Otherwise respect the explicitly configured model floor/policy instead of hardcoding a stale model name in the workflow.

## Context discipline

Prefer targeted searches, diff-scoped review, concise test modes, and small relevant excerpts. Avoid whole-repository dumps, full verbose logs, rereading unchanged files, duplicate investigations, and asking the parent to redo worker implementation.

## Concurrency discipline

Parallelize independent read-only exploration. Do not run overlapping writable workers against the same files/worktree. Use separate worktrees only when implementation workstreams are genuinely independent.

## Escalation

The parent should take deeper control when the worker reports a real architecture blocker, two repair cycles fail, security/destructive migration/data-integrity/critical-infrastructure risk is involved, or acceptance criteria cannot be proven with available validation.

The goal is simple: spend high-capability-model tokens at decision gates and lower-cost-model tokens inside execution loops.
