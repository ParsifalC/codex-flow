# Conversation analysis preview Implementation Plan

> For agentic workers: execute the bounded units under FlowPilot. User explicitly requested implementation and a separate branch; no repeated approval gate.

**Goal:** Deliver a native, functional preview of independent requirements, reply summaries, and manual skill drafts.
**Architecture:** Python transcript reader, persistent queue, isolated codex exec adapter, and atomic UI snapshots. Native SwiftUI preview consumes snapshots and dispatches explicit commands; existing telemetry remains unchanged.
**Tech Stack:** Python standard library, SQLite, SwiftUI/AppKit, Codex CLI.
**Spec:** docs/superpowers/specs/2026-09-22-conversation-analysis-preview.md

## Global Constraints
- Python standard library only; preserve existing declared platform/version compatibility.
- No mutation of installed runtime, hooks, global config, original telemetry, task ledger or goals.
- No automatically triggered skill extraction, no installation of generated skills.
- Use verified source identities, bounded model calls, private preview state and no credential output.
- Existing user uncommitted changes remain in original checkout.

## Review Focus
- Multiple same-turn user messages including repeated text retain distinct revisions.
- Hook/transcript replay and restart never duplicate model calls or roll back latest state.
- Missing parent proof, partial JSON lines, missing IDs and model failures are visible and fail closed.
- Skill selection, privacy and export operate on correct conversation/turn with explicit user action.
- Launch/stop and model isolation cannot modify installed FlowPilot or recurse into its hooks.

## Unit 1: Source, store, model runner and CLI
Files: scripts/analysis.py, scripts/analysis_core/*.py, tests/test_analysis_*.py.
Produces CLI: configure --state-dir PATH --transcript PATH --session-id ID --model MODEL [--auth-home PATH]; sync --state-dir PATH; work --state-dir PATH [--once]; watch --state-dir PATH; status --state-dir PATH; extract-skill --state-dir PATH --turn-id ID; retry --state-dir PATH --job-id ID. State snapshot contract finalized in backend handoff before UI unit.
- [ ] Write failing fixture tests for exact user IDs/turns, same text twice, parent final, injected context exclusion and partial tail.
- [ ] Run new tests and observe missing behavior; implement source parser.
- [ ] Write failing tests for durable jobs, restart dedup, latest by source order, disabled state, bounded failures and manual-only skills; implement SQLite store + atomic snapshot.
- [ ] Write fake-process boundary tests for isolated argv, stdin prompts, schema validation and timeout; implement model adapter.
- [ ] Implement CLI/service and validate full fake-runner end-to-end.
Validation: python3 -m unittest discover -s tests -p 'test_analysis_*.py'.

## Unit 2: Native preview experience
Files: new apps/macos-overlay/Sources/Models/ConversationAnalysis.swift, Services/ConversationAnalysisService.swift, Views/ConversationAnalysisPreview.swift; main.swift preview dispatch; tests and shell runner.
Consumes finalized snapshot and CLI interfaces from unit 1. Produces a native `analysis-preview` command using explicit state/runtime paths.
- [ ] Add failing Swift projection tests for turn selection, latest revision, missing summary, failed/pending jobs and privacy behavior.
- [ ] Implement read-only snapshot model and async action service.
- [ ] Build requirement, summary/original and manually triggered skill preview/export UI with turn picker.
- [ ] Add isolated preview window launch route; normal app startup unchanged.
Validation: new Swift test runner plus existing overlay-turn-navigation tests and isolated full build.

## Unit 3: Runnable preview and integration evidence
Files: scripts/preview-analysis.py, docs/conversation-analysis-preview.md, tests/test_analysis_preview.py and any narrow integration repairs.
Consumes units 1+2; produces start/status/stop commands and usable native window against explicit transcript.
- [ ] Write failing launcher tests for command argv, private state, duplicate start and stop isolation.
- [ ] Implement launcher using source paths, guarded private state, no global installation.
- [ ] Run Python and relevant Swift regressions, compile full native binary using isolated CODEX_HOME.
- [ ] Start actual model analysis for this explicitly selected conversation with bounded requests; inspect result and UI.
- [ ] Run two independent read-only reviews, fix actionable issues with regression tests, and commit the branch.
Validation: analysis tests, turn-result/publication regression, native build, live actual-model snapshot and native preview.
