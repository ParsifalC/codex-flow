#!/usr/bin/env python3
"""Cross-strategy convergence/recovery and budget coverage."""
from __future__ import annotations

import sys
from dataclasses import asdict
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from strategies import get  # noqa: E402
from strategies.base import standard_lifecycle  # noqa: E402
from strategies.lifecycle_runtime import CheckpointRecord, LifecyclePolicy, WorkerObservation, evaluate_worker  # noqa: E402
from strategies.work_unit_runtime import validate_manifest  # noqa: E402


def task(**overrides):
    values = {
        "complexity":"routine","risk":"medium","scope":"module","iteration_intensity":"iterative",
        "uncertainty":"medium","exploration_need":"medium","verification_cost":"medium","quality_intent":"normal",
        "parallelism":"limited","write_conflict":"low","writable_workstreams":1,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def manifest(count: int) -> dict:
    return {"units":[{
        "unit_id":f"u{i}","scope_id":f"scope-{i}","generation":0,"acceptance_delta":f"acceptance {i}",
        "write_scope_id":f"write-{i}","write_paths":[f"src/unit-{i}.py"],"validation":[f"test {i}"],"depends_on":[],
    } for i in range(1,count+1)]}


def assert_profile(name: str, profile, expected: tuple[int,int,int,int,int]) -> None:
    soft,rearm,repairs,max_units,hard=expected
    stage=get(name).lifecycle(profile,"implementation"); stage.validate()
    assert (stage.soft_timeout_seconds,stage.checkpoint_rearm_seconds,stage.max_worker_repair_attempts,stage.maximum_work_units,stage.hard_timeout_seconds)==expected,(name,stage)
    assert stage.minimum_work_units==1,stage
    bounded=max_units>1
    assert stage.work_unit_mode==("bounded" if bounded else "single"),stage
    assert stage.join_between_work_units is bounded and stage.require_write_paths is bounded,stage

    policy=LifecyclePolicy.from_dict(asdict(stage)); started=100.0; first_now=started+soft
    first=evaluate_worker(policy,WorkerObservation(
        scope_id=f"{name}-first",stage="implementation",started_at=started,last_progress_at=first_now,
        last_meaningful_progress_at=first_now,now=first_now,writable=True,in_flight=True,
    ))
    assert first.action=="request_checkpoint" and first.next_checkpoint_sequence==1,first
    harvested=first_now+2; second_now=harvested+rearm
    seq=(CheckpointRecord(1,0,first_now,first_now+1,harvested),)
    second=evaluate_worker(policy,WorkerObservation(
        scope_id=f"{name}-second",stage="implementation",started_at=started,last_progress_at=second_now,
        last_meaningful_progress_at=second_now,now=second_now,writable=True,in_flight=True,checkpoint_sequence=seq,
    ))
    assert second.action=="request_checkpoint" and second.next_checkpoint_sequence==2,second
    liveness=evaluate_worker(policy,WorkerObservation(
        scope_id=f"{name}-liveness",stage="implementation",started_at=started,last_progress_at=second_now,
        now=second_now,writable=True,in_flight=True,checkpoint_sequence=seq,
    ))
    assert liveness.action=="continue",liveness

    policy_json=asdict(stage)
    assert validate_manifest(policy_json,manifest(1),implementation_workers=1,max_concurrent_threads=4)["valid"]
    assert validate_manifest(policy_json,manifest(max_units),implementation_workers=1,max_concurrent_threads=4)["valid"]
    try:
        validate_manifest(policy_json,manifest(max_units+1),implementation_workers=1,max_concurrent_threads=4)
    except ValueError:
        pass
    else:
        raise AssertionError(f"{name}: manifest above maximum accepted")


def assert_task_budget(name: str, profile, expected: tuple[int,int,int,int,int,int,int,int]) -> None:
    soft,hard,max_units,max_attempts,replans,replacements,review_attempts,parent_finalization=expected
    spec=get(name); budget=spec.task_budget(profile); budget.validate()
    assert (
        budget.soft_timeout_seconds,budget.hard_timeout_seconds,budget.max_work_units,budget.max_implementation_attempts,
        budget.max_replans,budget.max_replacements,budget.max_review_attempts,budget.parent_finalization_seconds,
    )==expected,(name,budget)
    assert budget.max_work_units==spec.lifecycle(profile,"implementation").maximum_work_units,(name,budget)


def assert_review_retry(name: str, profile) -> None:
    stage=get(name).lifecycle(profile,"review"); stage.validate()
    assert stage.fallback_policy=="retry_review",(name,stage)
    decision=evaluate_worker(
        LifecyclePolicy.from_dict(asdict(stage)),
        WorkerObservation(scope_id=f"{name}-review",stage="review",started_at=100,last_progress_at=100,now=100,terminal_failure=True,writable=False),
    )
    assert decision.action=="retry_review",decision
    assert decision.replacement_allowed is True and decision.fence_required is False,decision
    assert decision.replan_scope is None and decision.checkpoint_reuse_mode is None,decision


def assert_v11_default_lifecycle() -> None:
    implementation=standard_lifecycle(task(),"implementation")
    implementation.validate()
    assert implementation.soft_timeout_seconds==1200,implementation
    assert implementation.checkpoint_rearm_seconds==240,implementation
    assert implementation.max_worker_repair_attempts==1,implementation
    assert implementation.work_unit_mode=="single",implementation
    assert implementation.minimum_work_units==implementation.maximum_work_units==1,implementation
    decision=evaluate_worker(
        LifecyclePolicy.from_dict(asdict(implementation)),
        WorkerObservation(
            scope_id="default-implementation",stage="implementation",started_at=100,last_progress_at=1300,
            last_meaningful_progress_at=1300,now=1300,writable=True,in_flight=True,
        ),
    )
    assert decision.action=="request_checkpoint",decision
    review=standard_lifecycle(task(),"review")
    review.validate()
    assert review.fallback_policy=="retry_review",review


def main() -> None:
    routine=task()
    complex_cross=task(complexity="complex",scope="cross-module")
    demanding=task(complexity="critical",risk="critical",scope="repo-wide",iteration_intensity="heavy-loop",verification_cost="high",quality_intent="absolute")

    lifecycle_expected={
        "efficient":{"routine":(600,180,1,1,1800),"complex":(900,240,2,2,1800),"demanding":(1200,300,2,3,1800)},
        "balanced":{"routine":(1200,240,1,1,2400),"complex":(1500,300,2,2,2400),"demanding":(1800,360,2,3,2400)},
        "quality":{"routine":(1800,360,2,1,3600),"complex":(2400,480,3,3,3600),"demanding":(2700,600,3,4,3600)},
        "speed":{"routine":(420,180,1,1,1200),"complex":(600,180,1,3,1200),"demanding":(720,180,1,4,1200)},
    }
    budget_expected={
        "efficient":{"routine":(1500,1800,1,2,1,1,2,150),"complex":(1500,1800,2,3,1,1,2,150),"demanding":(1500,1800,3,4,1,1,2,150)},
        "balanced":{"routine":(2400,3000,1,3,2,2,2,180),"complex":(2700,3300,2,4,2,2,2,180),"demanding":(3000,3600,3,5,2,2,2,180)},
        "quality":{"routine":(4800,6000,1,4,3,3,2,300),"complex":(5400,6600,3,6,3,3,4,300),"demanding":(6000,7200,4,7,3,3,4,300)},
        "speed":{"routine":(1200,1800,1,2,1,1,2,120),"complex":(1200,1800,3,4,1,1,2,120),"demanding":(1200,1800,4,5,1,1,2,120)},
    }
    profiles={"routine":routine,"complex":complex_cross,"demanding":demanding}
    for strategy,matrix in lifecycle_expected.items():
        for label,p in profiles.items():
            assert_profile(strategy,p,matrix[label])
            assert_task_budget(strategy,p,budget_expected[strategy][label])
        assert_review_retry(strategy,routine)

    assert_v11_default_lifecycle()

    multi=task(parallelism="high",write_conflict="low",writable_workstreams=4)
    assert get("efficient").lifecycle(multi,"implementation").maximum_work_units==1
    assert get("balanced").lifecycle(multi,"implementation").maximum_work_units==2
    assert get("quality").lifecycle(multi,"implementation").maximum_work_units==2
    assert get("speed").lifecycle(multi,"implementation").maximum_work_units==4

    # Speed's 1/3/4 values are semantic baselines. Proven isolated writable
    # topology may raise the total logical-unit envelope up to its 8-implementer
    # strategy budget, allowing serial waves without inventing new workstreams.
    speed_eight=task(parallelism="high",write_conflict="low",writable_workstreams=8)
    speed_stage=get("speed").lifecycle(speed_eight,"implementation")
    speed_budget=get("speed").task_budget(speed_eight)
    assert speed_stage.maximum_work_units==8,speed_stage
    assert speed_budget.max_work_units==8 and speed_budget.max_implementation_attempts==9,speed_budget

    print("shared strategy lifecycle and task-budget contract tests passed")


if __name__=="__main__":
    main()
