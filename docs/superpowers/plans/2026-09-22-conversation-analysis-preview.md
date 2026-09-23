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
- [x] Write failing fixture tests for exact user IDs/turns, same text twice, parent final, injected context exclusion and partial tail.
- [x] Run new tests and observe missing behavior; implement source parser.
- [x] Write failing tests for durable jobs, restart dedup, latest by source order, disabled state, bounded failures and manual-only skills; implement SQLite store + atomic snapshot.
- [x] Write fake-process boundary tests for isolated argv, stdin prompts, schema validation and timeout; implement model adapter.
- [x] Implement CLI/service and validate full fake-runner end-to-end.
Validation: python3 -m unittest discover -s tests -p 'test_analysis_*.py'.

## Unit 2: Native preview experience
Files: new apps/macos-overlay/Sources/Models/ConversationAnalysis.swift, Services/ConversationAnalysisService.swift, Views/ConversationAnalysisPreview.swift; main.swift preview dispatch; tests and shell runner.
Consumes finalized snapshot and CLI interfaces from unit 1. Produces a native `analysis-preview` command using explicit state/runtime paths.
- [x] Add failing Swift projection tests for turn selection, latest revision, missing summary, failed/pending jobs and privacy behavior.
- [x] Implement read-only snapshot model and async action service.
- [x] Build requirement, summary/original and manually triggered skill preview/export UI with turn picker.
- [x] Add isolated preview window launch route; normal app startup unchanged.
Validation: new Swift test runner plus existing overlay-turn-navigation tests and isolated full build.

## Unit 3: Runnable preview and integration evidence
Files: scripts/preview-analysis.py, docs/conversation-analysis-preview.md, tests/test_analysis_preview.py and any narrow integration repairs.
Consumes units 1+2; produces start/status/stop commands and usable native window against explicit transcript.
- [x] Write failing launcher tests for command argv, private state, duplicate start and stop isolation.
- [x] Implement launcher using source paths, guarded private state, no global installation.
- [x] Run Python and relevant Swift regressions, compile full native binary using isolated CODEX_HOME.
- [x] Start actual model analysis for this explicitly selected conversation with bounded requests; inspect model results.
- [x] Complete visual UI and button inspection after macOS is unlocked; see the 2026-09-23 acceptance findings below.
- [x] Run two independent read-only reviews, fix actionable issues with regression tests, and commit the branch.
Validation: analysis tests, turn-result/publication regression, native build, live actual-model snapshot and native preview.

## Delivery evidence (2026-09-22)

- 37 Python analysis/launcher/recovery tests pass.
- New native projection, draft editing and privacy tests pass; full native build passes with private CODEX_HOME.
- Existing startup, navigation and read-only-status checks passed during native implementation.
- Two independent reviewers completed; all reported issues were repaired and passed focused re-review.
- Three real analysis operations succeeded against the explicitly selected conversation: requirement, reply summary and manually requested skill draft. Existing generated skill metadata is normalized before display/export.
- Original checkout's README, AccountView, OverlayTheme and development-guide edits were preserved.
- Visual UI clicking remains pending because the desktop automation reported macOS locked; user was asked to unlock. No visual acceptance is claimed.

## Acceptance findings (2026-09-23)

The earlier lock-screen blocker is resolved. Acceptance is **not fully passed**: the following UI paths passed, but the source-classification issue below remains open.

- The actual current user message generated a requirement automatically. The later question reply updated the same turn from revision 20 to 21; the unfinished reply correctly remained without a summary.
- Selected historical source messages and complete original replies expanded successfully. The previous final reply had a real model-generated summary.
- Clicking the native skill button added exactly one skill call (1 to 2), progressing through waiting/running/succeeded. Later user input did not automatically extract another skill.
- Editing, clearing and refreshing the draft worked. Privacy mode hid source/derived text and the editor, disabled extraction, and preserved the edited draft when switched off.
- The native save panel exported the original draft, then an edited draft. The exported file contained the added acceptance marker and canonical name/description frontmatter. Test exports were moved from Documents into the private preview state's `acceptance-export` directory; no skill was installed.
- Clicking the window close button stopped the supervisor, worker and UI; no private `auth.json` remained. The preview was restarted for continued user inspection.
- Restart exposed an invalid bundle signature: the launcher copied a signed executable without generating a matching signature for the new bundle. A regression test reproduced `code has no resources but signature indicates they must be present`. The launcher now replaces the executable atomically and signs only its private preview bundle. All 38 analysis tests passed; real window close/restart was verified again.

### Open finding: automatic goal continuation classified as user speech

The live transcript contains two messages with authoritative content kind `goal.internal_context`. They appear in the history as user messages containing `<codex_internal_context source="goal">` and caused requirement calls. `source.py` currently excludes other host wrappers but not this kind. This does not satisfy the requirement to analyze genuine user messages. Repair must cover both future parsing and already imported preview state, while preserving message order, job identity, and historical results; adding a filter alone would leave persisted input and indexes inconsistent. This finding remains unimplemented and prevents an unconditional acceptance claim.

During UI automation, Stage Manager background thumbnails and native save-panel transitions caused intermittent timeouts. The completed checks above are based on final AX states, actual exported bytes and owned-process checks, rather than attempted clicks.


## Original popup integration (2026-09-23)

The user's correction supersedes Unit 2's standalone UI. The standalone SwiftUI page and window controller were removed. The isolated launcher now creates the existing `OverlayWindowController`, with analysis integrated into `SummaryView` and `TurnDetailView`; existing tabs, navigation, history, pinning and capsule behavior remain.

- Requirement and summary are resolved by both session ID and turn ID, including unfinished turns. Display-only transcript runs do not publish telemetry or fabricate timestamps and metrics. Historical selection survives live snapshot updates.
- The manual skill button, editable draft and export live inside the existing detail view. Export captures and validates the source session, turn and job, including privacy changes while the save panel is open.
- Native checks passed: `overlay-analysis.sh`, `overlay-turn-navigation.sh`, and `overlay-startup.sh`; the full isolated native build succeeded. Analysis tests passed again after the final privacy repair.
- Actual original-popup UI verification passed: current requirement includes the user's existing-popup constraint; previous-turn summary and full original reply expand; skill draft edits export correctly; collapse returns to the original capsule and reopening retains the selected turn.
- Edited export bytes contain `<!-- 原弹框导出验收 2026-09-23 -->` (4817 bytes, SHA-256 `b64a513ad8e5f5d4fcfacb4e7b109b2f30e47879e3463539f0848be74f9faecf`). Test files were moved to the private state's acceptance-export directory.
- Real save-panel verification found that terminating after the last regular window closed also terminated the NSPanel-based app after export. The preview now terminates explicitly; a second successful export and alert dismissal left the same overlay process running.
- Real privacy verification found selectable native text retained old accessibility content after becoming visually hidden. Recreating the detail subtree on privacy changes clears that cache; the final AX tree shows only hidden placeholders and disables analysis/copy actions.
- The original popup is running, pinned and displaying the latest selected conversation turn for continued inspection. The installed app was not replaced. The existing source-classification finding above remains open; this UI correction does not claim unconditional end-to-end acceptance.


## Original-page regression repair (2026-09-23)

User feedback invalidated the previous integration acceptance for history, statistics and account. The launcher had passed an empty private CODEX_HOME to the whole UI, hiding the existing telemetry and login. The preview delegate also omitted the original telemetry watcher. The launcher now preserves the UI's actual CODEX_HOME and configured Codex executable while retaining the analysis worker's isolated environment. A passive telemetry watcher is restored without preview-triggered recovery writes or taking over the installed IPC endpoint.

A launcher regression test reproduced missing history/statistics/account inputs through a subprocess boundary, then passed after the environment repair. Actual native UI verification showed the original history list, another project's full original turn details, populated 30-day statistics, and the existing account/limits including a successful refresh. No login data was copied into the temporary UI directory.

A separate regression test added sixteen newer conversations ahead of the selected historical session and reproduced missing previous/next turns. The full telemetry chat collection is now retained for historical navigation; only the recent-conversation menu is limited to fifteen. The goal-continuation source-classification finding remains separate and unresolved.

Validation after the repair: all 39 Python analysis tests, account snapshot fixtures (including custom CODEX_HOME and bounded failures), native turn navigation, analysis projection/guards, startup/IPC/capsule tests, and the full native build passed. The final build was reopened and history, statistics and account data were verified again in the actual popup.
