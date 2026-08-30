# codex-flow

Fast, low-friction cost-aware multi-agent defaults for Codex.

**Plan with the strongest model. Execute with a cheaper worker. Review with the strongest model again.**

`codex-flow` installs a small Codex configuration layer that keeps the main thread focused on architecture and review while delegating execution-heavy work to lower-cost subagents.

## Why

For medium and large engineering tasks, raw token usage can increase with delegation because agents read context independently, while total cost can still fall substantially when implementation loops run on a cheaper model.

The default policy is:

```text
small task         -> parent handles directly
medium/large task  -> parent plans
                    -> Luna subagent implements
                    -> parent reviews
                    -> Luna performs bounded fixes if needed
                    -> parent gives final acceptance
```

## Install

### macOS / Linux

Because this repository is private, clone it first:

```bash
git clone git@github.com:ParsifalC/codex-flow.git
cd codex-flow
bash install.sh
```

### Windows PowerShell

```powershell
.\install.ps1
```

Restart Codex after installation.

Then use Codex normally. No special prompt is required.

```text
Refactor the renew workflow and keep backward compatibility.
```

The installed skill is designed for implicit activation on non-trivial engineering work. You can also invoke it explicitly:

```text
Use $cost-aware-development and refactor the renew workflow.
```

## What gets installed

User-level files under `~/.codex`:

```text
~/.codex/
├── config.toml
├── agents/
│   ├── luna-explorer.toml
│   └── luna-implementer.toml
└── skills/
    └── cost-aware-development/
        └── SKILL.md
```

The installer backs up an existing `config.toml` before changing the managed `[agents]` keys.

## Defaults

- Parent model: left unchanged. Select `gpt-5.6-sol` with `xhigh` in Codex when you want the full strategy.
- Default subagent model: `gpt-5.6-luna`
- Default subagent reasoning: `max`
- Concurrent subagents: 4
- Skill: automatically routes trivial work directly and delegates execution-heavy work for medium/large tasks.

Why not force the parent model? People often maintain their own Codex model/profile settings. `codex-flow` changes only the delegation policy by default.

## Verify

```bash
bash scripts/doctor
```

The doctor checks the Codex CLI, installed files, and effective config hints.

## Uninstall

```bash
bash scripts/uninstall
```

The uninstall script removes files owned by codex-flow and leaves unrelated Codex configuration alone.

## Compatibility strategy

Codex multi-agent behavior is evolving. `codex-flow` deliberately uses two layers:

1. `[agents]` defaults provide the reliable baseline: spawned subagents use Luna unless explicitly overridden.
2. Custom agents provide richer explorer/implementer roles where the current Codex surface supports named custom-agent selection.

If named custom agents are unavailable, the workflow still works through the default Luna subagent policy and the orchestration skill.

## Design principles

- Expensive tokens are spent at decision gates, not implementation loops.
- Children receive compact task packets instead of irrelevant parent history when the runtime supports fresh forks.
- Review checks the diff and evidence instead of re-solving the task.
- Read-only exploration may run in parallel; overlapping writable workers should not.
- Repair loops are bounded. Repeated failure causes the parent to reassess the plan instead of burning tokens indefinitely.

## Status

Early private preview. Codex model routing and multi-agent APIs are changing quickly, so `doctor` and compatibility fallbacks are first-class parts of this project.
