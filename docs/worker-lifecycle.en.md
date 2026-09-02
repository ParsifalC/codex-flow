# Worker Lifecycle Runtime

ExecutionPlan v8 adds asynchronous Worker lifecycle semantics on top of the multi-strategy runtime. The goal is not simply to make Parent wait less; it is to maximize useful parallel Parent/Worker work while minimizing duplicated work, abandoned Worker work, and pointless waiting.

## Architecture

```text
TaskProfile
    ↓
StrategySpec
    ↓
ExecutionPlan v8 / StagePolicy
    ↓
FlowPilot scope observations
    ↓
Deterministic lifecycle evaluator
    ├─ progress lease
    ├─ hard timeout
    ├─ supersession
    ├─ fallback
    └─ writable writer fencing
```

Strategy Runtime determines topology and StagePolicy. FlowPilot supplies observable facts such as recent Worker activity, scope coverage, and terminal state. Timing, stall/fallback transitions, cancellation requirements, and permission for any downstream writer to enter a writable scope are evaluated deterministically by `scripts/strategies/lifecycle_runtime.py`.

The helper is copied automatically with the `strategies/` package by both Unix and Windows installers to `~/.codex/codex-flow/strategies/lifecycle_runtime.py`.

## StagePolicy

Every delegated stage with Workers receives:

```text
join_policy
  opportunistic | quorum | required

min_successful_workers
idle_timeout_seconds
hard_timeout_seconds
cancel_if_superseded
cancel_stragglers_after_quorum
fallback_policy
  continue_partial | parent_delta | replan | fail
```

`idle_timeout_seconds` is a renewable progress lease, not a completion deadline. New commands, file reads, searches, tool events, or a clearly visible in-flight operation indicate that a Worker can still be healthy.

`hard_timeout_seconds` is an absolute wall-clock ceiling. Even visible in-flight work cannot run forever.

## Worker states

```text
queued
running
progressing
completed
stalled
failed
superseded
cancelled
```

- `progressing`: recent observable activity or visible in-flight work.
- `stalled`: idle lease expired and there is no visible in-flight operation.
- `failed`: terminal Agent/tool/runtime error.
- `superseded`: an equivalent execution path already covered the bounded scope and StagePolicy allows cancellation.
- `cancelled`: cancellation/termination has been confirmed.

**A Parent `wait()` timeout is never a Worker timeout.** Two or more waits returning without a final result are not, by themselves, evidence that a high-reasoning Worker is stalled.

If the active Codex runtime cannot expose reliable intermediate progress, FlowPilot must not guess idle state. It may rely on explicit activity, terminal state, supersession, or the hard timeout.

## Scope-aware fork/join

Every Worker receives a stable `scope_id` before spawn. Parent continues work that does not overlap Worker scopes and joins only at real dependency points.

- A PR-metadata Worker can be superseded if Parent has already obtained equivalent metadata/check evidence.
- A Runtime reviewer still reading code while Parent performs unrelated branding/build work is complementary, not superseded.

A numeric quorum is only the minimum successful result count. It does not automatically make every remaining independent scope worthless. `cancel_stragglers_after_quorum=true` only permits cancellation when the remaining Worker no longer owns unique acceptance-relevant evidence.

## Deterministic evaluator

When a lifecycle decision is required, FlowPilot passes StagePolicy plus actual observations to the evaluator. All three timestamp arguments must be **Unix seconds**, for example Python `time.time()`. Do not pass the 13-digit millisecond timestamps common in JavaScript or telemetry events. The evaluator fails fast on obvious millisecond input instead of silently dividing by 1000.

```bash
python3 ~/.codex/codex-flow/strategies/lifecycle_runtime.py \
  --policy-json '<stage-policy-json>' \
  --scope-id <scope> \
  --stage exploration|implementation|review \
  --started-at <unix-seconds> \
  --last-progress-at <unix-seconds> \
  --now <unix-seconds> \
  [--writable] [--in-flight] \
  [--terminal-success] [--terminal-failure] \
  [--scope-superseded] [--cancel-confirmed] \
  [--replacement-isolated]
```

The result contains:

```text
state
action
reason
cancel_required
replacement_allowed
fence_required
idle_seconds
wall_seconds
fallback_policy
```

`cancel_required=true` means the Worker is still non-terminal. Even when `action` already permits `parent_delta`, `continue_partial`, or an isolated `replan`, Scheduler must still request cancellation of the old Worker. That prevents read-only fallback from leaving a timed-out Worker burning resources in the background; writable stages additionally obey `fence_required` for any new writer.

`fallback_policy` is populated only when failure/cancellation/stall actually requires a fallback decision. It is `null` for successful results and for superseded scopes that are already satisfied, so consumers do not infer duplicate work.

This keeps StagePolicy deterministic and moves timeout/fallback state transitions plus cancellation requirements out of ad-hoc Parent judgment.

## Writable writer fencing

Writable fencing is a Runtime hard safety invariant. Strategies cannot disable it.

The invariant protects **any new writer**, not only a replacement Worker. Once an implementation Worker owns a writable scope and becomes stalled/hard-timed-out while still non-terminal, both of these fallback paths create a downstream writer:

- `parent_delta`: Parent becomes the downstream writer;
- `replan`: a new Implementer/execution path becomes the downstream writer.

Both must satisfy the same hard fence:

```text
old Worker may still write
        ↓
block any new writer from the same live scope
        ↓
request cancellation
        ↓
cancel/termination confirmed
        ↓
Parent delta or replan replacement may write
```

If the runtime cannot reliably terminate the old Worker, a second safe path is allowed:

```text
old Worker remains non-terminal
        ↓
request cancellation of old Worker (cancel_required=true)
        ↓
new downstream writer uses a fresh isolated worktree
        ↓
old output is fenced from integration
        ↓
Parent delta or replan may proceed
```

`replacement_allowed` describes only whether `replan` may spawn a replacement Worker; it does not need to become true for `parent_delta`. For both writer-producing fallback modes, `fence_required=true` is the common safety signal.

This prevents a stalled Worker A from recovering and writing concurrently with either Parent or replacement Worker B in the same writable scope.

## Fallback

Fallback always covers the missing delta:

- `continue_partial`: continue when existing evidence already satisfies acceptance needs.
- `parent_delta`: Parent covers only the missing scope; for writable implementation delta it must satisfy writable writer fencing first.
- `replan`: re-profile/recompile only for the remaining delta; a new writable Implementer must satisfy the same fence.
- `fail`: surface the unresolved failure instead of silently replacing it.

For a non-terminal stalled/hard-timed-out Worker, fallback may proceed where policy allows, while `cancel_required=true` simultaneously requires cleanup of the old Worker.

Worker lifecycle failures do not consume `max_repair_cycles`; repair cycles are reserved for defects in implementation output.

## Built-in strategy defaults

- **efficient**: quorum exploration, aggressive trimming of redundant read-only work, required implementation, lightweight quorum review.
- **balanced**: quorum exploration, required implementation, required review with equivalent-scope supersession.
- **quality**: longer leases, exploration quorum target 2, required implementation, required independent review target 2, no silent Parent replacement of required reviewers.
- **speed**: opportunistic exploration, shorter leases, required implementation, quorum review.

All strategy preferences remain bounded by Runtime hard ceilings, cancellation requirements, and writable writer fencing.

## Real scenarios

### Luna max keeps working through multiple waits

If the Worker continues reading files, running commands, searching, or showing visible in-flight activity, it remains `progressing`. Parent continues non-overlapping work and applies StagePolicy at the real join point.

### Two complementary deep reviewers are both slow

If one owns Runtime semantics and another owns installation/platform integration, both scopes remain valuable while they are progressing. Parent must not terminate them and then restart both review scopes from zero.

### Read-only work has already been covered by Parent

When equivalent scope evidence already exists and policy allows supersession, the Worker becomes `superseded` and cancellation may be requested. The reason is loss of marginal value, not elapsed time.

### Read-only Worker stalls

A fallback such as `parent_delta` may continue, but evaluator also returns `cancel_required=true` so the old Worker is reclaimed rather than silently running past idle/hard ceilings.

### Writable Worker stalls and Parent wants to take over

`parent_delta` also creates a new writer. Parent must not write directly into the old Worker's live scope. Confirm termination first, or perform the missing delta in a fresh isolated worktree and fence the old output from integration.

### Writable implementation stalls and needs a replacement

Do not execute `replan → spawn same-scope replacement` directly. Terminate the old Worker first, or move the replacement into a fresh isolated worktree and fence the old output. In either path, a non-terminal old Worker must receive a cancellation request.

## Runtime invariants

1. `wait()` timeout is not Worker timeout.
2. Evaluator timestamps are Unix seconds; obvious millisecond inputs fail fast.
3. Observable progress renews the idle lease.
4. Hard timeout is absolute.
5. Supersession requires equivalent scope coverage, not elapsed time.
6. Parent fallback covers only missing delta.
7. Any non-terminal lifecycle exit explicitly carries `cancel_required=true`; a timed-out Worker is never silently left running.
8. A writable downstream writer (Parent or replacement) requires `old terminal OR new isolated+fenced`.
9. Lifecycle failure does not consume implementation repair cycles.
10. Strategy-specific lifecycle preferences stay in StrategySpec; deterministic evaluator enforces hard safety invariants uniformly.
