#!/usr/bin/env python3
"""Regression coverage for task-budget phase admission and required review tail."""
from __future__ import annotations

import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from strategy_runtime import Modifiers, TaskProfile, compile_plan  # noqa: E402
from strategies import get  # noqa: E402
from strategies.task_budget_runtime import LedgerError, init_ledger  # noqa: E402
from strategies.task_phase_runtime import reserve_implementation, status  # noqa: E402


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


def plan(strategy: str, *, strict: bool = False, task: TaskProfile | None = None):
    return compile_plan(
        task or profile(),
        strategy=strategy,
        routing_mode="delegate",
        modifiers=Modifiers(review="strict" if strict else "auto", fanout="auto"),
    )


def assert_tail(strategy: str, expected_elapsed_cutoff: int, *, strict: bool = False) -> None:
    execution_plan = plan(strategy, strict=strict)
    assert execution_plan.task_budget is not None, execution_plan
    assert execution_plan.review_stage is not None, execution_plan
    assert execution_plan.reviewer_workers > 0, execution_plan

    start = 100.0
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / f"{strategy}.json")
        init_ledger(state, strategy, execution_plan.task_budget, start)
        plan_json = execution_plan.to_dict()
        cutoff = start + expected_elapsed_cutoff

        before = status(state, strategy, plan_json, "implementation", cutoff - 1)
        assert before["permits_phase_start"] is True, before
        assert before["action"] == "continue", before

        at_cutoff = status(state, strategy, plan_json, "implementation", cutoff)
        assert at_cutoff["permits_phase_start"] is False, at_cutoff
        assert at_cutoff["action"] == "converge_for_required_completion", at_cutoff
        assert at_cutoff["checkpoint_convergence_required"] is True, at_cutoff
        assert at_cutoff["required_completion_handoff"] is True, at_cutoff

        required = status(state, strategy, plan_json, "required_completion", cutoff)
        assert required["permits_phase_start"] is True, required
        assert required["action"] == "complete_required", required
        assert required["required_completion_reserve_seconds"] == execution_plan.review_stage.hard_timeout_seconds, required

        hard = start + execution_plan.task_budget.hard_timeout_seconds
        near_hard = status(state, strategy, plan_json, "required_completion", hard - 1)
        assert near_hard["permits_phase_start"] is True, near_hard
        stopped = status(state, strategy, plan_json, "required_completion", hard)
        assert stopped["permits_phase_start"] is False and stopped["action"] == "stop", stopped


def main() -> None:
    # Quality plans require independent review by default. Their general-work
    # admission closes early enough to preserve the review stage's full hard tail.
    assert_tail("quality", 3000)

    # Strict review is an explicit required-completion stage even for strategies
    # that normally use Parent-only review.
    assert_tail("balanced", 1200, strict=True)
    assert_tail("speed", 900, strict=True)
    assert_tail("efficient", 600, strict=True)

    # Parent-only review keeps the original strategy soft deadline unchanged.
    balanced = plan("balanced")
    assert balanced.reviewer_workers == 0 and balanced.review_stage is None, balanced
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "balanced-parent.json")
        init_ledger(state, "balanced-parent", balanced.task_budget, 100)
        decision = status(state, "balanced-parent", balanced.to_dict(), "implementation", 100 + 2400)
        assert decision["required_completion_reserve_seconds"] == 0, decision
        assert decision["general_work_deadline"] == 100 + 2400, decision
        assert decision["action"] == "converge", decision

    # The phase-aware reservation wrapper closes the race in policy semantics:
    # the raw ledger soft deadline may be later, but new implementation work is
    # rejected once the required-review tail begins.
    quality = plan("quality")
    with tempfile.TemporaryDirectory() as tmp:
        state = str(Path(tmp) / "quality-reserve.json")
        init_ledger(state, "quality-reserve", quality.task_budget, 100)
        reserve_implementation(
            state,
            "quality-reserve",
            quality.to_dict(),
            "implementation_attempt",
            "attempt-before-tail",
            "unit-0-generation-0",
            3099,
        )
        try:
            reserve_implementation(
                state,
                "quality-reserve",
                quality.to_dict(),
                "implementation_attempt",
                "attempt-in-tail",
                "unit-0-generation-1",
                3100,
            )
        except LedgerError as exc:
            assert "required-completion reserve reached" in str(exc), exc
        else:
            raise AssertionError("implementation reservation unexpectedly entered required-review tail")

    # High technical risk may opt into multiple evidence-backed quality units,
    # but minimum_work_units remains one so this never forces a fake split.
    high_risk = profile(risk="high")
    quality_stage = get("quality").lifecycle(high_risk, "implementation")
    assert quality_stage.minimum_work_units == 1, quality_stage
    assert quality_stage.maximum_work_units == 3, quality_stage

    print("task phase admission tests passed")


if __name__ == "__main__":
    main()
