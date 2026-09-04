#!/usr/bin/env python3
"""Regression coverage for task-budget phase admission and required completion."""
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
from strategies.task_phase_runtime import init, reserve_implementation, status  # noqa: E402


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


def plan(
    strategy: str,
    *,
    strict: bool = False,
    task: TaskProfile | None = None,
    fanout: str = "auto",
):
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
    expected_effective_hard: int,
    expected_reviewer_reserve: int,
    expected_parent_reserve: int,
) -> None:
    execution_plan = plan(strategy, strict=strict)
    assert execution_plan.task_budget is not None, execution_plan
    assert execution_plan.review_stage is not None, execution_plan
    assert execution_plan.reviewer_workers > 0, execution_plan

    start = 100.0
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / f"{strategy}.json")
        initialized = init(state, strategy, execution_plan.to_dict(), start)
        plan_json = execution_plan.to_dict()
        cutoff = start + expected_soft
        hard = start + expected_effective_hard

        assert initialized["soft_deadline"] == cutoff, initialized
        assert initialized["hard_deadline"] == hard, initialized
        assert initialized["effective_task_budget"]["soft_timeout_seconds"] == expected_soft, initialized
        assert initialized["effective_task_budget"]["hard_timeout_seconds"] == expected_effective_hard, initialized
        assert initialized["reviewer_reserve_seconds"] == expected_reviewer_reserve, initialized
        assert initialized["parent_finalization_reserve_seconds"] == expected_parent_reserve, initialized
        assert initialized["required_completion_reserve_seconds"] == (
            expected_reviewer_reserve + expected_parent_reserve
        ), initialized
        assert initialized["hard_deadline_extended"] == (
            expected_effective_hard > execution_plan.task_budget.hard_timeout_seconds
        ), initialized

        before = status(state, strategy, plan_json, "implementation", cutoff - 1)
        assert before["permits_phase_start"] is True and before["action"] == "continue", before

        at_cutoff = status(state, strategy, plan_json, "implementation", cutoff)
        assert at_cutoff["permits_phase_start"] is False, at_cutoff
        assert at_cutoff["action"] == "converge_for_required_completion", at_cutoff
        assert at_cutoff["checkpoint_convergence_required"] is True, at_cutoff
        assert at_cutoff["required_completion_handoff"] is True, at_cutoff

        required = status(state, strategy, plan_json, "required_completion", cutoff)
        assert required["permits_phase_start"] is True, required
        assert required["action"] == "complete_required", required

        near_hard = status(state, strategy, plan_json, "required_completion", hard - 1)
        assert near_hard["permits_phase_start"] is True, near_hard
        stopped = status(state, strategy, plan_json, "required_completion", hard)
        assert stopped["permits_phase_start"] is False and stopped["action"] == "stop", stopped


def assert_parallel_topology_budget(strategy: str, *, fanout: str = "auto") -> None:
    execution_plan = plan(
        strategy,
        task=profile(
            parallelism="high",
            write_conflict="low",
            writable_workstreams=4,
        ),
        fanout=fanout,
    )
    assert execution_plan.implementation_stage is not None, execution_plan
    assert execution_plan.task_budget is not None, execution_plan
    assert execution_plan.implementation_workers >= 1, execution_plan
    assert execution_plan.implementation_stage.maximum_work_units >= execution_plan.implementation_workers, execution_plan
    assert execution_plan.task_budget.max_work_units >= execution_plan.implementation_workers, execution_plan
    assert execution_plan.task_budget.max_implementation_attempts >= execution_plan.implementation_workers, execution_plan

    # Phase init repeats the invariant and therefore fails closed if a future
    # compiler/strategy regression emits an impossible plan.
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / f"{strategy}-parallel.json")
        init(state, f"{strategy}-parallel", execution_plan.to_dict(), 100)


def main() -> None:
    # General work retains the strategy soft target. Required review is additive:
    # effective hard extends to preserve both the reviewer hard window and a
    # distinct Parent finalization reserve.
    assert_tail(
        "quality",
        expected_soft=4800,
        expected_effective_hard=8100,
        expected_reviewer_reserve=3000,
        expected_parent_reserve=300,
    )
    assert_tail(
        "balanced",
        strict=True,
        expected_soft=2400,
        expected_effective_hard=4380,
        expected_reviewer_reserve=1800,
        expected_parent_reserve=180,
    )
    assert_tail(
        "speed",
        strict=True,
        expected_soft=1200,
        expected_effective_hard=2220,
        expected_reviewer_reserve=900,
        expected_parent_reserve=120,
    )
    assert_tail(
        "efficient",
        strict=True,
        expected_soft=1500,
        expected_effective_hard=2850,
        expected_reviewer_reserve=1200,
        expected_parent_reserve=150,
    )

    # Parent-only review keeps the original strategy task envelope unchanged.
    balanced = plan("balanced")
    assert balanced.reviewer_workers == 0 and balanced.review_stage is None, balanced
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "balanced-parent.json")
        initialized = init(state, "balanced-parent", balanced.to_dict(), 100)
        assert initialized["effective_task_budget"] == {
            "soft_timeout_seconds": 2400,
            "hard_timeout_seconds": 3000,
            "max_work_units": balanced.task_budget.max_work_units,
            "max_implementation_attempts": balanced.task_budget.max_implementation_attempts,
            "max_replans": 2,
            "max_replacements": 2,
        }, initialized
        decision = status(state, "balanced-parent", balanced.to_dict(), "implementation", 2500)
        assert decision["required_completion_reserve_seconds"] == 0, decision
        assert decision["action"] == "converge", decision

    # The raw ledger soft deadline remains the general-work boundary. It rejects
    # genuinely new implementation work there but keeps idempotent replay valid.
    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "quality-reserve.json")
        init(state, "quality-reserve", quality.to_dict(), 100)
        first = reserve_implementation(
            state,
            "quality-reserve",
            quality.to_dict(),
            "implementation_attempt",
            "attempt-before-tail",
            "unit-0-generation-0",
            4899,
        )
        assert first["reserved"] is True and first["idempotent"] is False, first

        replay = reserve_implementation(
            state,
            "quality-reserve",
            quality.to_dict(),
            "implementation_attempt",
            "attempt-before-tail",
            "unit-0-generation-0",
            4900,
        )
        assert replay["reserved"] is True and replay["idempotent"] is True, replay
        assert replay["permits_phase_start"] is False, replay

        try:
            reserve_implementation(
                state,
                "quality-reserve",
                quality.to_dict(),
                "implementation_attempt",
                "attempt-in-tail",
                "unit-0-generation-1",
                4900,
            )
        except LedgerError as exc:
            assert "soft deadline reached" in str(exc), exc
        else:
            raise AssertionError("new implementation reservation unexpectedly entered required-completion tail")

    # Initial budget-plan identity remains immutable across replanning.
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
            raise AssertionError("different budget plan unexpectedly reused task phase ledger")

    # There is no grandfathered pre-phase state. A raw ledger created with a
    # different policy fingerprint fails closed instead of silently changing semantics.
    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "mismatch.json")
        init_ledger(state, "mismatch", quality.task_budget, 100)
        try:
            status(state, "mismatch", quality.to_dict(), "implementation", 101)
        except LedgerError as exc:
            assert "plan/policy mismatch" in str(exc), exc
        else:
            raise AssertionError("mismatched raw ledger unexpectedly adopted phase-aware semantics")

    # Exercise the real argparse path: --now arrives as text in every shell.
    phase_cli = ROOT / "scripts/strategies/task_phase_runtime.py"
    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "cli.json")
        plan_json = json.dumps(quality.to_dict(), separators=(",", ":"))
        init_run = subprocess.run(
            [
                sys.executable,
                str(phase_cli),
                "init",
                "--state-file",
                state,
                "--task-id",
                "cli",
                "--plan-json",
                plan_json,
                "--now",
                "100",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        initialized = json.loads(init_run.stdout)
        assert initialized["soft_deadline"] == 4900, initialized
        assert initialized["hard_deadline"] == 8200, initialized
        status_run = subprocess.run(
            [
                sys.executable,
                str(phase_cli),
                "status",
                "--state-file",
                state,
                "--task-id",
                "cli",
                "--plan-json",
                plan_json,
                "--phase",
                "required_completion",
                "--now",
                "4900",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        required = json.loads(status_run.stdout)
        assert required["action"] == "complete_required" and required["permits_phase_start"], required

    # High technical risk may opt into multiple evidence-backed quality units,
    # but minimum_work_units remains one so this never forces a fake split.
    high_risk = profile(risk="high")
    quality_stage = get("quality").lifecycle(high_risk, "implementation")
    assert quality_stage.minimum_work_units == 1, quality_stage
    assert quality_stage.maximum_work_units == 3, quality_stage

    # Real multi-writer topology must always fit the logical-unit and attempt
    # budgets. This is the regression that the previous single-worker tests missed.
    assert_parallel_topology_budget("balanced")
    assert_parallel_topology_budget("quality")
    assert_parallel_topology_budget("speed")
    assert_parallel_topology_budget("efficient", fanout="aggressive")

    # Explicitly corrupt a valid plan to prove phase init rejects under-provisioned
    # topology even if a future strategy/compiler bug bypasses normal checks.
    speed_parallel = plan(
        "speed",
        task=profile(parallelism="high", write_conflict="low", writable_workstreams=4),
    ).to_dict()
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
            raise AssertionError("under-provisioned parallel topology unexpectedly initialized")

    print("task phase admission tests passed")


if __name__ == "__main__":
    main()
