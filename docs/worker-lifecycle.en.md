# Worker Lifecycle Runtime

ExecutionPlan v8 adds deterministic asynchronous Worker lifecycle semantics on top of the multi-strategy runtime introduced in v7.

The goal is not simply to make the Parent wait less. It is to maximize useful parallel Parent/Worker work while minimizing duplicated work, abandoned Worker work, and pointless waiting.

## Core model

```text
TaskProfile
    ↓
StrategySpec
    ↓
ExecutionPlan v8
    ↓
Async Worker Scheduler semantics
    ├─ scope tracking
    ├─ progress lease
    ├─ join policy
    ├─ quorum
    ├─ supersession
    ├─ stall detection
    └─ delta fallback
```

Strategy modules own lifecycle preferences. Generic Runtime only normalizes those preferences against the actual planned Worker count and hard safety ceilings.

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

`idle_timeout_seconds` is a renewable progress lease, not a completion deadline. Observable progress refreshes the lease. `hard_timeout_seconds` is an absolute wall-clock ceiling.

A Parent `wait()` call returning without a final Worker result is **never** sufficient evidence that the Worker timed out. A high-reasoning Worker can be slow while still actively reading files, running commands, searching, or waiting on an in-flight tool operation.

## Worker states

FlowPilot uses these semantic states when the active runtime exposes enough evidence:

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
- `stalled`: the idle lease expired with no observable progress and no visible in-flight operation.
- `failed`: terminal Agent/tool/runtime error.
- `superseded`: the same bounded scope has already been covered with equivalent evidence elsewhere and the StagePolicy allows supersession.

If the active Codex runtime cannot expose reliable intermediate progress, FlowPilot must not infer `stalled` from repeated `wait()` timeouts. It may rely on explicit terminal state, clear activity evidence, supersession, and the hard timeout.

## Scope-aware fork/join

Every Worker receives a stable bounded `scope_id`. Parent execution is fork/join rather than fork/block:

1. spawn the planned Workers;
2. continue Parent work that does not overlap their scopes;
3. consume completed Worker evidence as it arrives;
4. join only when Parent reaches a real dependency on that stage;
5. never redo an entire Worker scope merely because it has not finished yet.

Supersession is overlap-aware cancellation, not a timeout shortcut. If a PR-metadata Worker is still running but Parent has already obtained the same PR metadata and checks, that Worker may be superseded. A Runtime reviewer still actively inspecting code while Parent works on unrelated branding is not superseded.

## Join policies

### opportunistic

Best-effort evidence. Parent does not block specifically for the stage. Completed evidence is consumed if useful.

### quorum

At the join point, at least `min_successful_workers` successful results are required. Reaching numeric quorum does not automatically make every remaining distinct scope worthless. Stragglers may be cancelled only when policy allows it and they no longer own unique acceptance-relevant evidence.

### required

Every non-superseded assigned scope must be covered and the minimum successful result requirement must be satisfied. Required independent review cannot be silently replaced with Parent self-review when supersession is disabled.

## Fallback

Fallback always covers the missing delta rather than restarting the whole stage:

- `continue_partial`: proceed with sufficient existing evidence.
- `parent_delta`: Parent covers only the missing scope/evidence.
- `replan`: compile a new plan for the remaining delta.
- `fail`: surface the unresolved stage failure.

Worker lifecycle failures do not consume `max_repair_cycles`; repair cycles are reserved for defects in implementation output.

## Built-in strategy defaults

- **efficient**: quorum exploration, aggressive supersession of redundant work, required implementation, lightweight quorum review.
- **balanced**: quorum exploration, required implementation, required review with scope-aware supersession.
- **quality**: longer progress leases, exploration quorum target 2, required implementation, required independent review target 2, and no Parent supersession of required review.
- **speed**: opportunistic exploration, shorter leases, required implementation, quorum review.

All strategy preferences remain bounded by Runtime hard ceilings. Lifecycle v1 intentionally uses deterministic rules rather than historical duration prediction.

## Real scenarios

### Slow PR metadata investigation

If Parent independently obtains equivalent PR metadata before the Worker returns, the Worker becomes `superseded` and may be cancelled. The reason is loss of marginal value, not elapsed time.

### Luna max reviewer keeps working through multiple waits

If the Worker keeps reading files, running commands, searching, or otherwise showing progress, it remains `progressing`. Repeated Parent wait intervals do not justify termination. Parent continues non-overlapping work and applies StagePolicy at the real join point.

### Two complementary deep reviewers

If one reviewer owns Runtime semantics and another owns installation/platform integration, their scopes are complementary. If both are progressing, Parent should not terminate them and then repeat both scopes itself. A required review stage waits for the required scope coverage unless there is a real failure/stall/hard timeout that triggers fallback.

### Worker has no observable progress

After the idle lease expires with no in-flight work, the Worker becomes `stalled` and the stage follows its fallback policy. This prevents genuinely stuck Workers from occupying resources indefinitely.

### Explorer finds the root cause early

Other Explorers can be superseded only if their scopes no longer carry unique value. Numeric quorum alone is not evidence that every remaining investigation is redundant.

### Implementation Worker is already writing an isolated worktree

Implementation is required by default and does not allow casual supersession. A progressing implementation Worker is not cancelled merely so Parent can recreate the same patch. Failure/stall normally triggers replanning from the remaining writable delta.

## Runtime invariants

1. `wait()` timeout is not Worker timeout.
2. Observable progress renews the idle lease.
3. Cancelling a progressing Worker requires a policy-authorized supersession/straggler reason or the hard timeout.
4. Parent fallback covers only missing delta.
5. Lifecycle failure does not consume implementation repair cycles.
6. Strategy-specific lifecycle decisions stay in StrategySpec; generic Runtime does not branch on built-in strategy names.
