# Conversation analysis preview

User explicitly requested implementation on a separate branch to try before optimizing (2026-09-22). This authorizes implementation of the discussed initial experience without another design approval loop.

## Product behavior
- Independent model extracts the current turn need after every real user message, using conversation context. It replaces the goal presentation in the preview, never injects instructions into the parent agent.
- Every parent final receives a short summary; original text remains expandable. No final means no invented summary.
- Skill extraction is exclusively a user button action for the selected conversation through the selected turn. Output is a candidate SKILL.md preview, export on explicit user action; never install automatically.
- Conversation provides context; turn owns requirement revisions; message ID identifies each update. History never changes to another turn's need. Late results cannot regress latest requirement.
- Real model output and explicit model failures; fixture mode, if supplied, must be labeled as a demo and never masquerade as model inference.

## Initial delivery boundary
An isolated native preview window and Python service run from this worktree, with a private preview state directory. It follows one explicitly selected Desktop transcript. No replacement of installed runtime, hooks, floating app, login items, global AGENTS, original goal/publication, or policy. Integration with the existing overlay should reuse data/view infrastructure when feasible, but must never manufacture published TaskRun records for active analysis.

## Sources and identity
Read only the explicitly selected transcript. Validate session_meta id, source=vscode, originator=Codex Desktop, thread_source=user; reject child records. Current host verified response_item messages contain payload.id and internal_chat_message_metadata_passthrough.turn_id. Prefer those exact IDs. A no-ID source may use persistent immutable record location+hash only with prefix integrity validation; safest initial behavior is an explicit unsupported status. Do not deduplicate on text.
Ignore known pure harness context blocks (environment_context, recommended_plugins / AGENTS), developer messages, tool outputs and commentary. Preserve actual question replies by parsing send_user_message_question_reply. Never remove ordinary text just because it quotes a wrapper. Source bounds and truncation are explicit. Import conversation for context but bootstrap model jobs only for latest real user and latest parent final, then all new messages. This avoids charging for entire history on startup.

## Backend
Python standard library only. New scripts/analysis_core modules for transcript source, SQLite queue/store, model adapter, service, CLI (scripts/analysis.py). SQLite transactions claim work with leases, bound attempts and serialize processing. Atomic JSON snapshot is the UI read interface. Each job is unique by kind+session+source ID+analyzer version; skill jobs only exist after explicit request. Failed jobs report errors and require bounded retry. Enable flag is rechecked before a job starts. No uncontrolled model retries. Store input snapshots at enqueue; a persisted bootstrap boundary reconciles missing jobs after an interrupted source import. Analysis usage separate from parent telemetry; shared account quota is not attributed as exact parent cost.

## Model boundary
Adapt codex exec: ephemeral, ignore-user-config, read-only sandbox, isolated empty cwd and private CODEX_HOME. Reuse login through protected local credential copy without printing it or committing it. Explicitly disable hooks, plugins/apps, shell/unified execution, multi-agent and web search where supported. Supply transcript as untrusted data, require output schema, finite timeout and schema field length bounds. Cancel/reap subprocess group on timeout/shutdown. Mark background-analysis source. Validate output JSON types/lengths, keep caveats and unknowns. Model name configurable; initial model uses installed efficient-worker recommendation, reasoning low for short analysis.

## UI contract
Native SwiftUI preview selects turn, displays latest requirement with status and revision; summary plus expandable original final; button to extract skills for the selected conversation up to the selected turn; candidate editor/preview and export via save dialog. Pending/failed/unsupported states visible; no fake completed status. Re-read atomic snapshot independent of publication/last.json. All action calls use argv (no shell interpolation) and avoid blocking main thread. Privacy hides source and derived text and prevents copy/export. Old normal overlay works with no analysis config.

## Delivery
Source launcher starts dedicated Python watcher and native preview with private state, supplies explicit transcript/session/model paths, handles stop and prevents duplicate workers. Live verification on selected conversation uses a bounded number of model calls. Tests use fixtures/fake external runner, not credentials. Include regression tests for same-turn repeated text, restart deduplication, late results, malformed/partial source, child isolation, failing model, manual-only skill jobs, and UI history projection. Build with temporary CODEX_HOME because existing build script syncs installed binaries. No dependency installation required.
