#!/usr/bin/env python3
"""Regression coverage for schema-v11 task phase admission."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from copy import deepcopy
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from strategy_runtime import Modifiers, TaskProfile, compile_plan  # noqa: E402
from strategies import get  # noqa: E402
from strategies.task_budget_runtime import LedgerError, init_ledger  # noqa: E402
from strategies.task_phase_runtime import init, reserve_phase, status  # noqa: E402


def profile(**overrides) -> TaskProfile:
    values = {
        "complexity": "routine",
        "uncertainty": "medium",
        "risk": "medium",
        "scope": "module",
        "parallelism": "limited",
        "write_conflict": "low",
        "exploration_need": "medium",
        "verification_cost": "medium",
        "iteration_intensity": "iterative",
        "writable_workstreams": 1,
        "quality_intent": "normal",
    }
    values.update(overrides)
    return TaskProfile(**values)


def plan(strategy: str, *, strict: bool = False, task: TaskProfile | None = None, fanout: str = "auto"):
    return compile_plan(
        task or profile(),
        strategy=strategy,
        routing_mode="delegate",
        modifiers=Modifiers(review="strict" if strict else "auto", fanout=fanout),
    )


def assert_tail(
    strategy: str,
    *,
    strict: bool = False,
    expected_soft: int,
    expected_hard: int,
    expected_reviewer_reserve: int,
    expected_parent_reserve: int,
) -> None:
    execution_plan = plan(strategy, strict=strict)
    assert execution_plan.schema_version == 11, execution_plan
    assert execution_plan.task_budget is not None, execution_plan
    assert execution_plan.review_stage is not None and execution_plan.reviewer_workers > 0, execution_plan
    assert execution_plan.review_stage.fallback_policy == "retry_review", execution_plan
    assert execution_plan.task_budget.soft_timeout_seconds == expected_soft, execution_plan
    assert execution_plan.task_budget.hard_timeout_seconds == expected_hard, execution_plan

    start = 100.0
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / f"{strategy}.json")
        initialized = init(state, strategy, execution_plan.to_dict(), start)
        plan_json = execution_plan.to_dict()
        cutoff = start + expected_soft
        hard = start + expected_hard
        review_deadline = hard - expected_parent_reserve

        assert initialized["soft_deadline"] == cutoff, initialized
        assert initialized["hard_deadline"] == hard, initialized
        assert initialized["review_deadline"] == review_deadline, initialized
        assert initialized["task_budget"] == execution_plan.task_budget.__dict__, initialized
        assert initialized["reviewer_reserve_seconds"] == expected_reviewer_reserve, initialized
        assert initialized["parent_finalization_reserve_seconds"] == expected_parent_reserve, initialized
        assert initialized["required_completion_reserve_seconds"] == expected_reviewer_reserve + expected_parent_reserve, initialized

        before = status(state, strategy, plan_json, "implementation", cutoff - 1)
        assert before["permits_phase_start"] and before["action"] == "continue", before
        at_cutoff = status(state, strategy, plan_json, "implementation", cutoff)
        assert not at_cutoff["permits_phase_start"], at_cutoff
        assert at_cutoff["action"] == "converge_for_required_completion", at_cutoff
        assert at_cutoff["checkpoint_convergence_required"], at_cutoff
        required = status(state, strategy, plan_json, "required_completion", cutoff)
        assert required["permits_phase_start"] and required["action"] == "complete_required", required
        assert required["permits_review_start"] and required["permits_parent_finalization"], required

        review = reserve_phase(
            state, strategy, plan_json, "required_completion", "review_attempt",
            "review-0", "review-generation-0", cutoff,
        )
        assert review["reserved"] and not review["idempotent"], review
        assert review["counters"]["review_attempt"] == 1, review

        retry = reserve_phase(
            state, strategy, plan_json, "required_completion", "review_attempt",
            "review-1", "review-generation-1", review_deadline - 1,
        )
        assert retry["reserved"] and retry["counters"]["review_attempt"] == 2, retry

        finalization = status(state, strategy, plan_json, "required_completion", review_deadline)
        assert finalization["permits_phase_start"], finalization
        assert finalization["permits_required_completion"], finalization
        assert not finalization["permits_review_start"], finalization
        assert finalization["permits_parent_finalization"], finalization
        assert finalization["action"] == "finalize_parent", finalization

        # A reservation committed before review_deadline remains exactly replayable
        # after admission closes; this acknowledgement does not create new work.
        replay = reserve_phase(
            state, strategy, plan_json, "required_completion", "review_attempt",
            "review-1", "review-generation-1", review_deadline,
        )
        assert replay["reserved"] and replay["idempotent"], replay
        assert replay["action"] == "finalize_parent", replay
        assert replay["counters"]["review_attempt"] == 2, replay

        try:
            reserve_phase(
                state, strategy, plan_json, "required_completion", "review_attempt",
                "review-too-late", "review-generation-2", review_deadline,
            )
        except LedgerError as exc:
            assert "admission deadline" in str(exc), exc
        else:
            raise AssertionError("new review retry consumed Parent finalization reserve")

        near_hard = status(state, strategy, plan_json, "required_completion", hard - 1)
        assert near_hard["permits_phase_start"] and near_hard["action"] == "finalize_parent", near_hard
        stopped = status(state, strategy, plan_json, "required_completion", hard)
        assert not stopped["permits_phase_start"] and stopped["action"] == "stop", stopped


def assert_parallel_topology_budget(strategy: str, *, fanout: str = "auto") -> None:
    execution_plan = plan(
        strategy,
        task=profile(parallelism="high", write_conflict="low", writable_workstreams=4),
        fanout=fanout,
    )
    assert execution_plan.implementation_stage is not None and execution_plan.task_budget is not None, execution_plan
    assert execution_plan.implementation_workers >= 1, execution_plan
    assert execution_plan.implementation_stage.maximum_work_units >= execution_plan.implementation_workers, execution_plan
    assert execution_plan.task_budget.max_work_units >= execution_plan.implementation_workers, execution_plan
    assert execution_plan.task_budget.max_implementation_attempts >= execution_plan.implementation_workers, execution_plan
    with tempfile.TemporaryDirectory() as tmp:
        init(str(Path(tmp) / f"{strategy}.json"), strategy, execution_plan.to_dict(), 100)


def main() -> None:
    assert_tail("quality", expected_soft=4800, expected_hard=8100, expected_reviewer_reserve=3000, expected_parent_reserve=300)
    assert_tail("balanced", strict=True, expected_soft=2400, expected_hard=4380, expected_reviewer_reserve=1800, expected_parent_reserve=180)
    assert_tail("speed", strict=True, expected_soft=1200, expected_hard=2220, expected_reviewer_reserve=900, expected_parent_reserve=120)
    assert_tail("efficient", strict=True, expected_soft=1500, expected_hard=2850, expected_reviewer_reserve=1200, expected_parent_reserve=150)

    balanced = plan("balanced")
    assert balanced.reviewer_workers == 0 and balanced.review_stage is None, balanced
    assert balanced.task_budget.max_review_attempts == 0, balanced
    assert balanced.task_budget.hard_timeout_seconds == 3000, balanced
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "balanced-parent.json")
        initialized = init(state, "balanced-parent", balanced.to_dict(), 100)
        assert initialized["required_completion_reserve_seconds"] == 0, initialized
        assert initialized["review_deadline"] is None, initialized
        decision = status(state, "balanced-parent", balanced.to_dict(), "implementation", 2500)
        assert decision["action"] == "converge", decision
        no_completion = status(state, "balanced-parent", balanced.to_dict(), "required_completion", 2500)
        assert not no_completion["permits_phase_start"] and no_completion["action"] == "stop", no_completion

    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "quality-reserve.json")
        init(state, "quality-reserve", quality.to_dict(), 100)
        first = reserve_phase(
            state, "quality-reserve", quality.to_dict(), "implementation", "implementation_attempt",
            "attempt-0", "unit-0-generation-0", 4899,
        )
        assert first["reserved"] and not first["idempotent"], first
        replay = reserve_phase(
            state, "quality-reserve", quality.to_dict(), "implementation", "implementation_attempt",
            "attempt-0", "unit-0-generation-0", 4900,
        )
        assert replay["reserved"] and replay["idempotent"], replay
        try:
            reserve_phase(
                state, "quality-reserve", quality.to_dict(), "implementation", "implementation_attempt",
                "attempt-1", "unit-0-generation-1", 4900,
            )
        except LedgerError as exc:
            assert "soft deadline" in str(exc), exc
        else:
            raise AssertionError("new implementation attempt entered required-completion tail")

        review = reserve_phase(
            state, "quality-reserve", quality.to_dict(), "required_completion", "review_attempt",
            "review-1", "reviewer-1", 4900,
        )
        assert review["reserved"] and review["counters"]["review_attempt"] == 1, review
        try:
            reserve_phase(
                state, "quality-reserve", quality.to_dict(), "implementation", "review_attempt",
                "bad-phase", "bad", 4900,
            )
        except LedgerError as exc:
            assert "require" in str(exc), exc
        else:
            raise AssertionError("review_attempt accepted in implementation phase")

    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "identity.json")
        init(state, "identity", quality.to_dict(), 100)
        other = plan("quality", task=profile(complexity="complex", scope="cross-module"))
        try:
            status(state, "identity", other.to_dict(), "implementation", 101)
        except LedgerError as exc:
            assert "plan/policy mismatch" in str(exc), exc
        else:
            raise AssertionError("different canonical budget plan reused task ledger")

    quality = plan("quality")
    raw_quality_policy = get("quality").task_budget(profile())
    assert raw_quality_policy.hard_timeout_seconds != quality.task_budget.hard_timeout_seconds
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "mismatch.json")
        init_ledger(state, "mismatch", raw_quality_policy, 100)
        try:
            status(state, "mismatch", quality.to_dict(), "implementation", 101)
        except LedgerError as exc:
            assert "plan/policy mismatch" in str(exc), exc
        else:
            raise AssertionError("non-canonical ledger was accepted")

    phase_cli = ROOT / "scripts/strategies/task_phase_runtime.py"
    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "cli.json")
        plan_json = json.dumps(quality.to_dict(), separators=(",", ":"))
        init_run = subprocess.run([
            sys.executable, str(phase_cli), "init", "--state-file", state, "--task-id", "cli",
            "--plan-json", plan_json, "--now", "100",
        ], check=True, text=True, capture_output=True)
        initialized = json.loads(init_run.stdout)
        assert initialized["soft_deadline"] == 4900 and initialized["hard_deadline"] == 8200, initialized
        assert initialized["review_deadline"] == 7900, initialized
        review_run = subprocess.run([
            sys.executable, str(phase_cli), "reserve", "--state-file", state, "--task-id", "cli",
            "--plan-json", plan_json, "--phase", "required_completion", "--kind", "review_attempt",
            "--reservation-id", "review-cli", "--fingerprint", "review-cli-v0", "--now", "4900",
        ], check=True, text=True, capture_output=True)
        review = json.loads(review_run.stdout)
        assert review["reserved"] and review["phase"] == "required_completion", review

    high_risk = profile(risk="high")
    quality_stage = get("quality").lifecycle(high_risk, "implementation")
    assert quality_stage.minimum_work_units == 1 and quality_stage.maximum_work_units == 3, quality_stage

    assert_parallel_topology_budget("balanced")
    assert_parallel_topology_budget("quality")
    assert_parallel_topology_budget("speed")
    assert_parallel_topology_budget("efficient", fanout="aggressive")

    speed_parallel = plan("speed", task=profile(parallelism="high", write_conflict="low", writable_workstreams=4)).to_dict()
    assert speed_parallel["implementation_workers"] > 1, speed_parallel
    broken = deepcopy(speed_parallel)
    broken["implementation_stage"]["maximum_work_units"] = 1
    broken["task_budget"]["max_work_units"] = 1
    with tempfile.TemporaryDirectory() as tmp:
        try:
            init(str(Path(tmp) / "broken.json"), "broken", broken, 100)
        except LedgerError as exc:
            assert "topology exceeds task budget max_work_units" in str(exc), exc
        else:
            raise AssertionError("under-provisioned parallel topology initialized")

    print("task phase admission tests passed")


if __name__ == "__main__":
    main()
