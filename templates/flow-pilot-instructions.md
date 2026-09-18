# FlowPilot task entry

For every repository technical work request, including exploration, editing,
configuration, integration, testing, and implementation, use this entry gate
before repository exploration or technical action:

Apply this entry even when another skill is selected and the user has not
named FlowPilot. If a required gate command fails, report the installation
error instead of treating the failure as a disabled switch.

1. Read the installed FlowPilot skill at
   `{{CODEX_HOME}}/skills/flow-pilot/SKILL.md` completely.
2. Show the global strategy state. For a new task only, consume the one-shot
   bypass when the state is enabled; same-task follow-ups keep the existing
   task receipt, plan, and ledger and never consume another bypass:

   ```text
   python3 "{{CODEX_HOME}}/codex-flow/strategy_runtime.py" --policy "{{CODEX_HOME}}/codex-flow.toml" show --json
   python3 "{{CODEX_HOME}}/codex-flow/strategy_runtime.py" --policy "{{CODEX_HOME}}/codex-flow.toml" consume-bypass
   ```

3. Treat the strategy gate receipt as authoritative for this task. `enabled=false` or a
   consumed bypass means ordinary execution for this task. Never infer the
   enabled state from an earlier turn. If FlowPilot remains enabled, follow
   the turn-context sequence below, then profile the task and let its planner
   choose direct execution or delegation; do not
   use uncertainty about the task as a reason to skip the gate.

4. Only for a FlowPilot-participating parent turn with telemetry enabled and
   a receipt delivered through a verified host context protocol, save a
   1–400 Unicode-codepoint goal to a UTF-8 file and call:

   ```text
   codex-flow telemetry context write-goal --receipt-file <host-receipt-file> --text-file <utf8-goal-file>
   ```

   This happens after the gate and before TaskProfile/planner work. Preserve
   the user's original message. The first successful goal is immutable for
   this turn. Bind it only to the receipt's `session_id + turn_id`: project is
   `cwd`, chat is `session_id`, and turn is `turn_id`.

5. Save the planner's complete returned ExecutionPlan JSON to a file, then
   call `codex-flow telemetry context write-plan --receipt-file
   <host-receipt-file> --plan-file <full-plan-json-file> --origin compiled`.
   On a same-task follow-up, use that turn's new host receipt, record its own
   goal, and save the existing plan with `--origin reused`. A legitimate
   re-profile uses `--origin replanned`; it never resets the task ledger or
   its original budget plan.

No verified host receipt transport is currently established. Until the
target host passes the end-to-end compatibility gate, automatic goal/plan
writes stay disabled and missing details are “未记录”. Do not discover a
receipt by scanning state, infer one from `CODEX_*`, `last.json`, or an active
turn, or treat `systemMessage` as a supported transport. Missing/invalid
receipts and telemetry-disabled results do not interrupt the main task.
Do not pass parent receipts to workers or forge goals/plans for disabled or
bypassed tasks. Metadata writes do not publish details; only parent Stop does.

Conversation-only answers and work explicitly assigned to a subagent are
excluded. Follow-ups in the same task preserve the existing plan and
ledger; a bypass is consumed at most once for that task. Higher-priority
instructions and explicit current-task overrides still apply.

The entry instructions are a prompt-level entry point. They help the active
agent load the installed skill and deterministic runtime; they are not a
security boundary or a guarantee that every host, model, or integration will
follow the prompt. Hooks are telemetry-only and do not enforce this gate.
