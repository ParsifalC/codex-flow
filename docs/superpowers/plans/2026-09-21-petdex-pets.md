# Petdex pets implementation plan

> Agentic workers: execute bounded units under the installed FlowPilot plan and test-driven-development. The user approved implementation on a new branch; no additional design approval is pending.

**Goal:** Install and switch pet resources with one command, and render Petdex's nine animations from actual interactions and task events.

**Architecture:** Python owns downloading, local import and selection. Swift reads validated local sprite sheets and uses a small animation state reducer. A separate live event stream drives transient pet state without changing completed-turn publication.

**Tech stack:** Python standard library (Python >=3.8), SwiftUI/AppKit/ImageIO, Unix socket IPC.

**Spec:** [Approved simplified design](../specs/2026-09-21-pet-resource-installation-design.md).

## Constraints

- Branch: `codex/petdex-pets`, based on `9b002b86e06e08ffb18cca8938086b074965d195`.
- Existing README change and `docs/development-guide.md` belong to other work. Preserve them.
- Four user operations: `pets install`, `pets list`, `pets use`, `pets use default`. Local directory/ZIP use the same install command.
- User resources stay under the resolved `CODEX_HOME/codex-flow/pets/`, outside app versions. Preserve them on update/uninstall.
- No Node dependency, third-party scripts, marketplace or arbitrary executable plugin loading.
- Petdex state row order and durations follow the verified upstream sprite table. v1/v2 use their first nine rows.
- Explicit live events, never a success inferred from Stop or review inferred from an execution plan.

## Shared interfaces

- `pets/installed/<safe-id>/pet.json` plus `spritesheet.png` or `spritesheet.webp`; original known metadata fields include `id`, `displayName`, `description`, `spriteVersionNumber`, `spritesheetPath`.
- `pets/current` is an atomically replaced UTF-8 local ID; `default` selects the existing built-in appearance. Optional `provenance.json` records source and digest.
- IDs cannot escape the managed directory or collide with reserved selection paths. Local imports receive a distinguishable safe ID and print it.
- Native IPC `pet reload` reloads the current selection and returns JSON `ok` only after native decode succeeds. Failure keeps/falls back to built-in functionality and is reported separately from download success.
- Live IPC is `pet event <JSON>` with `schema_version: 1`, `event`, `session_id`, `turn_id`, `sequence`, `timestamp_ms`, `started_at_ms`, and `source`. Events are `started`, `running`, `waiting`, `review`, `succeeded`, `failed`, `completed`, and `aborted`. Sequence increases per parent turn; task start time orders competing turns.

Units 1 and 2 run in parallel with separate write scopes after agreeing on the storage and reload interfaces. Unit 3 starts after both join.

## Live event producers

- `UserPromptSubmit` starts or resumes a parent turn. `PermissionRequest` and actual user-input tools enter waiting; matching tool completion or new input resumes work. An asynchronous question's immediate acknowledgement does not mean the user answered.
- Actual reviewer `SubagentStart`/`SubagentStop` events enter and leave review. Child events must resolve through their exact recorded parent association; an unrelated child's activity cannot select a parent task.
- `Stop` means completed and may wave; `Interrupt` means aborted. Neither implies success or failure. Failed commands also do not imply failed tasks.
- Semantic success/failure needs an explicit execution report. A receipt-bound `telemetry activity` command reports it at the real completion boundary, with FlowPilot instructions calling it only after checking the outcome. It does not modify publication snapshots or task results.
- Fast activity hooks use local state and bounded IPC only. They do not query app-server or parse unrelated transcripts. Telemetry disabled means no activity writes.
- Keep a bounded activity snapshot for startup recovery, reject stale/out-of-order events, and expire abandoned activity to idle. Missing host hooks leave the last known state or idle; never invent a missing transition.

## Review focus

1. Path traversal, symlinks, oversized images/archives must not write outside pet storage or replace the current pet.
2. Real catalog version can be stale: Boba catalog says v1 while its downloaded metadata and geometry are v2. Package metadata plus geometry are authoritative.
3. Stale, duplicate or cross-session events must not replace a newer task, replay completion, or imply false success.
4. A hidden/expanded pet view must not run an unnecessary animation loop; reduced motion uses a static pose.
5. Install/reinstall/OTA/uninstall must preserve the pet directory without preserving unrelated application state.

## Unit 1 — Resource installation and CLI

Files: new `scripts/pets.py`, `tests/test_pets.py`; CLI wrappers, Python package entry, installer file lists, help/completions, uninstall scripts, CI as required.

- [x] Write behavior tests for directory/ZIP install, current selection, list/use/default, collision/idempotency, trusted Petdex catalog resolution, v1/v2 PNG/WebP geometry, unsafe archives and failed download preservation. Example expected result: installing a valid local v2 pack stores an intact 1536×2288 sheet; `use default` changes only selection and retains that pack.
- [x] Run the new suite before implementation and record the expected missing-feature failures.
- [x] Implement bounded download/validation/staging, atomic selection, shared CLI dispatch and preservation during uninstall. Resolve official Petdex API with a documented canonical CDN fallback, no arbitrary mirror.
- [x] Run the resource tests and installed CLI smoke checks. Expected: package files preserved, no source directory changes, existing CLI behavior intact.

## Unit 2 — Native sprites and nine-state reducer

Files: new focused pet models/services/view under `apps/macos-overlay/Sources/`; existing BubbleView, OverlayWindowController, IPCServer and native tests; new `tests/overlay-pets.sh`.

- [x] Write tests for the nine row/frame sequences, variable frame times, image dimensions, selection loading, missing/corrupt resources, reduced motion, hover/drag direction and return state.
- [x] Run tests before adding production types; record the missing-feature failure.
- [x] Decode PNG/WebP with ImageIO, crop cells using verified geometry, keep a bounded image cache, animate only visible views. Add `pet reload` and preserve the current window hit region and drag behavior.
- [x] Run native tests and build with an isolated test CODEX_HOME. Expected: both real Boba WebP and generated PNG fixtures decode; the existing overlay regressions stay green.

## Unit 3 — Real event bridge and delivery

Files: telemetry hook/collector integration and focused pet activity module; native event consumer/service; activity tests, integration tests and user documentation.

- [x] Finalize event schema from actual available producers: identity, timestamp, ordered sequence, task start/resume/wait/review/success/failure/end.
- [x] Write tests using realistic rollout/hook payloads and an actual Unix socket receiver. Verify wait/resume/review/terminal mapping, duplicate ordering, unrelated tasks, expired activity and completion dedupe.
- [x] Run RED, then implement a read-only live follower or supported hook bridge as required by actual runtime coverage. Keep completed-result publication separate and preserve telemetry-off behavior.
- [x] Integrate Swift event handling with the unit-2 reducer and re-run event → wire → animation checks. Explicitly report any host capability that cannot generate a required event; do not replace it with a guessed event.
- [x] Add concise usage docs and run Python suite, native pet/regression tests, telemetry and installation checks. Record actual online Boba installation in an isolated CODEX_HOME.

## Baseline evidence

- `uv run --no-project --with pytest python -m pytest -q`: 175 passed, 58 subtests; one existing tar extraction deprecation warning.
- `bash tests/smoke.sh`, `bash tests/telemetry-core.sh`, `bash tests/overlay-startup.sh`, `bash tests/overlay-turn-navigation.sh`: passed.
- System Python lacks pytest; use the temporary uv test environment, without installing runtime dependencies into the project.
- Official Petdex API timed out; its documented `assets.petdex.dev/manifests/petdex-v2.json` returned 200. Boba metadata and 2.4MB WebP downloaded and decoded with ImageIO successfully on this host.

## Integration evidence

- The implemented installer downloaded `boba` from the official source into an isolated `CODEX_HOME`, without a catalog override. Exit status was 0; the 2,440,892-byte WebP and v2 metadata were retained, and an absent overlay was reported as saved for next startup.
- `pets list`, `pets use default`, `pets use boba`, and the repository's `bin/codex-flow pets list` entry all succeeded against that isolated installation.
- Parent resource review fixed explicit ZIP directory entries, image-limit alignment, corrupt selection handling, and retained source/author provenance. Resource/updater regression check after independent review: 59 passed. Exact slug matching, malformed ZIP errors, symlink guards and strict sprite version validation are covered.

- Unit 2 native sprite/resource/interaction checks, overlay startup/navigation regressions, and the isolated native build passed. Real Boba WebP decoded at 1536×2288.

## Final review

Two independent read-only reviewers inspect resource/installation safety and native/event correctness respectively. Parent reconciles both reviews, reruns affected checks and reports the branch, implemented behavior and any validation limits. No merge or live user installation is implied by this task.

## Final validation (2026-09-21)

- Full Python suite: 229 passed, 58 subtests passed; one pre-existing tar extraction deprecation warning.
- Installation smoke, telemetry-core, overlay startup and turn-navigation checks passed.
- Native pet tests passed: all nine sprite rows and frame timing, real Boba WebP (1536×2288), native IPC, task ordering, terminal deduplication, visibility/reduced motion and fallback.
- Native app build passed with an isolated CODEX_HOME. No live user installation was modified.
- Independent resource and native/event reviews completed. Repairs cover exact catalog matching, bounded corrupt archives, symlink/version validation, first-reviewer parent association, asynchronous acknowledgement handling, immutable terminal outcomes and hidden-window animation timers. Each behavioral repair has regression coverage.
- `git diff --check` passed. Existing README/development-guide changes remain outside this feature.
