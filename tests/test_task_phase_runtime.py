#!/usr/bin/env python3
"""Regression coverage for task-budget phase admission and required review tail."""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from strategy_runtime import Modifiers, TaskProfile, compile_plan  # noqa: E402
from strategies import get  # noqa: E402
from strategies.task_budget_runtime import LedgerError  # noqa: E402
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
        initialized = init(state, strategy, execution_plan.to_dict(), start)
        plan_json = execution_plan.to_dict()
        cutoff = start + expected_elapsed_cutoff

        assert initialized["effective_task_budget"]["soft_timeout_seconds"] == expected_elapsed_cutoff, initialized
        assert initialized["soft_deadline"] == cutoff, initialized

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
    # Quality plans require independent review by default. Their ledger soft
    # deadline is deterministically clamped to preserve the review stage's full
    # hard tail.
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
        initialized = init(state, "balanced-parent", balanced.to_dict(), 100)
        assert initialized["effective_task_budget"] == {
            "soft_timeout_seconds": 2400,
            "hard_timeout_seconds": 3000,
            "max_work_units": 1,
            "max_implementation_attempts": 3,
            "max_replans": 2,
            "max_replacements": 2,
        }, initialized
        decision = status(state, "balanced-parent", balanced.to_dict(), "implementation", 100 + 2400)
        assert decision["required_completion_reserve_seconds"] == 0, decision
        assert decision["general_work_deadline"] == 100 + 2400, decision
        assert decision["action"] == "converge", decision

    # Phase-aware init moves the raw ledger soft deadline to the required-review
    # boundary. The underlying atomic reserve therefore rejects *new* work there
    # while preserving its deliberate idempotent replay behavior.
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
            3099,
        )
        assert first["reserved"] is True and first["idempotent"] is False, first

        replay = reserve_implementation(
            state,
            "quality-reserve",
            quality.to_dict(),
            "implementation_attempt",
            "attempt-before-tail",
            "unit-0-generation-0",
            3100,
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
                3100,
            )
        except LedgerError as exc:
            assert "soft deadline reached" in str(exc), exc
        else:
            raise AssertionError("new implementation reservation unexpectedly entered required-review tail")

    # The phase helper refuses a different budget plan against an existing
    # ledger, preventing a caller from extending the admission window after init.
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
        assert initialized["soft_deadline"] == 3100, initialized
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
                "3100",
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

    print("task phase admission tests passed")


if __name__ == "__main__":
    main()
