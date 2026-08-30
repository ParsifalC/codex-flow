---
name: cost-aware-development
description: Route non-trivial software engineering work through a strong parent for planning and review while delegating exploration, implementation, testing, debugging, and bounded repair loops to cheaper subagents. Use for medium/large coding tasks, refactors, migrations, CI/CD, infrastructure, debugging, and multi-file changes.
---

# Cost-Aware Development

Optimize for expensive-token efficiency, not minimum raw token count.

The parent is the technical lead. Subagents are execution workers.

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

When the runtime supports named custom agents, prefer `luna-explorer` for this work. Otherwise use a normal subagent and explicitly instruct it to remain read-only and concise.

## 3. Parent plans

Before broad implementation, the parent owns and resolves:
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

When the runtime supports named custom agents, prefer `luna-implementer`. Otherwise the configured default subagent is the implementation worker.

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

## Context discipline

Prefer:
- targeted searches
- `git diff --stat`
- `git diff -- <paths>`
- concise test modes
- grep/head/tail for logs
- small relevant excerpts

Avoid:
- whole-repository dumps
- full verbose build logs
- rereading unchanged files
- duplicate investigations
- asking the parent to redo worker implementation

## Concurrency discipline

Parallelize independent read-only exploration.
Do not run overlapping writable workers against the same files/worktree.
Use separate worktrees only when implementation workstreams are genuinely independent.

## Escalation

The parent should take deeper control when:
- the worker reports a real architecture blocker
- two repair cycles fail
- security, destructive migration, data integrity, or critical infrastructure risk is involved
- acceptance criteria cannot be proven with available validation

The goal is simple: spend expensive-model tokens at decision gates and cheaper-model tokens inside execution loops.
