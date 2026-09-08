# FlowPilot task entry

For every repository technical work request, including exploration, editing,
configuration, integration, testing, and implementation, use this entry gate
before repository exploration or technical action:

Apply this entry even when another skill is selected and the user has not
named FlowPilot. If a required gate command fails, report the installation
error instead of treating the failure as a disabled switch.

1. Read the installed FlowPilot skill at
   `{{CODEX_HOME}}/skills/flow-pilot/SKILL.md` completely.
2. Show the global strategy state, then consume the one-shot bypass when the
   state is enabled:

   ```text
   python3 "{{CODEX_HOME}}/codex-flow/strategy_runtime.py" --policy "{{CODEX_HOME}}/codex-flow.toml" show --json
   python3 "{{CODEX_HOME}}/codex-flow/strategy_runtime.py" --policy "{{CODEX_HOME}}/codex-flow.toml" consume-bypass
   ```

3. Treat the receipt as authoritative for this task. `enabled=false` or a
   consumed bypass means ordinary execution for this task. Never infer the
   enabled state from an earlier turn. If FlowPilot remains enabled, profile
   the task and let its planner choose direct execution or delegation; do not
   use uncertainty about the task as a reason to skip the gate.

Conversation-only answers and work explicitly assigned to a subagent are
excluded. Follow-ups in the same task preserve the existing plan and
ledger; a bypass is consumed at most once for that task. Higher-priority
instructions and explicit current-task overrides still apply.

The entry instructions are a prompt-level entry point. They help the active
agent load the installed skill and deterministic runtime; they are not a
security boundary or a guarantee that every host, model, or integration will
follow the prompt. Hooks are telemetry-only and do not enforce this gate.
