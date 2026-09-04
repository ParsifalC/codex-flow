#!/usr/bin/env python3
"""Cross-strategy convergence/recovery and cumulative-budget coverage."""
from __future__ import annotations

import sys
from dataclasses import asdict
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from strategies import get  # noqa: E402
from strategies.lifecycle_runtime import (  # noqa: E402
    CheckpointRecord,
    LifecyclePolicy,
    WorkerObservation,
    evaluate_worker,
)
from strategies.work_unit_runtime import validate_manifest  # noqa: E402


def task(**overrides):
    values = {
        "complexity": "routine",
        "risk": "medium",
        "scope": "module",
        "iteration_intensity": "iterative",
        "uncertainty": "medium",
        "exploration_need": "medium",
        "verification_cost": "medium",
        "quality_intent": "normal",
        "parallelism": "limited",
        "write_conflict": "low",
        "writable_workstreams": 1,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def manifest(count: int) -> dict:
    return {
        "units": [
            {
                "unit_id": f"u{index}",
                "scope_id": f"scope-{index}",
                "generation": 0,
                "acceptance_delta": f"acceptance delta {index}",
                "write_scope_id": f"write-{index}",
                "write_paths": [f"src/unit-{index}.py"],
                "validation": [f"test unit {index}"],
                "depends_on": [],
            }
            for index in range(1, count + 1)
        ]
    }


def assert_profile(name: str, profile, expected: tuple[int, int, int, int, int]) -> None:
    soft, rearm, repairs, maximum_units, hard = expected
    stage = get(name).lifecycle(profile, "implementation")
    stage.validate()

    assert stage.soft_timeout_seconds == soft, (name, stage)
    assert stage.checkpoint_rearm_seconds == rearm, (name, stage)
    assert stage.max_worker_repair_attempts == repairs, (name, stage)
    assert stage.minimum_work_units == 1, (name, stage)
    assert stage.maximum_work_units == maximum_units, (name, stage)
    assert stage.hard_timeout_seconds == hard, (name, stage)
    assert stage.soft_timeout_seconds + stage.checkpoint_rearm_seconds < stage.hard_timeout_seconds, (name, stage)

    bounded = maximum_units > 1
    assert stage.work_unit_mode == ("bounded" if bounded else "single"), (name, stage)
    assert stage.join_between_work_units is bounded, (name, stage)
    assert stage.require_write_paths is bounded, (name, stage)

    policy = LifecyclePolicy.from_dict(asdict(stage))
    started = 100.0
    first_now = started + soft
    first = evaluate_worker(
        policy,
        WorkerObservation(
            scope_id=f"{name}-first",
            stage="implementation",
            started_at=started,
            last_progress_at=first_now,
            last_meaningful_progress_at=first_now,
            now=first_now,
            writable=True,
            in_flight=True,
        ),
    )
    assert first.action == "request_checkpoint", (name, first)
    assert first.next_checkpoint_sequence == 1, (name, first)
    assert first.cancel_required is False and first.fence_required is False, (name, first)

    harvested_at = first_now + 2
    second_now = harvested_at + rearm
    sequence = (
        CheckpointRecord(
            sequence=1,
            generation=0,
            requested_at=first_now,
            received_at=first_now + 1,
            harvested_at=harvested_at,
        ),
    )
    second = evaluate_worker(
        policy,
        WorkerObservation(
            scope_id=f"{name}-second",
            stage="implementation",
            started_at=started,
            last_progress_at=second_now,
            last_meaningful_progress_at=second_now,
            now=second_now,
            writable=True,
            in_flight=True,
            checkpoint_sequence=sequence,
        ),
    )
    assert second.action == "request_checkpoint", (name, second)
    assert second.next_checkpoint_sequence == 2, (name, second)
    assert second.harvested_checkpoint_sequence == 1, (name, second)

    legacy_liveness_only = evaluate_worker(
        policy,
        WorkerObservation(
            scope_id=f"{name}-legacy-liveness",
            stage="implementation",
            started_at=started,
            last_progress_at=second_now,
            now=second_now,
            writable=True,
            in_flight=True,
            checkpoint_sequence=sequence,
        ),
    )
    assert legacy_liveness_only.action == "continue", (name, legacy_liveness_only)

    policy_json = asdict(stage)
    valid_one = validate_manifest(
        policy_json,
        manifest(1),
        implementation_workers=1,
        max_concurrent_threads=4,
    )
    assert valid_one["valid"] and valid_one["unit_count"] == 1, (name, valid_one)

    valid_max = validate_manifest(
        policy_json,
        manifest(maximum_units),
        implementation_workers=1,
        max_concurrent_threads=4,
    )
    assert valid_max["valid"] and valid_max["unit_count"] == maximum_units, (name, valid_max)

    try:
        validate_manifest(
            policy_json,
            manifest(maximum_units + 1),
            implementation_workers=1,
            max_concurrent_threads=4,
        )
    except ValueError:
        pass
    else:
        raise AssertionError(f"{name}: manifest above maximum_work_units unexpectedly accepted")


def assert_task_budget(name: str, profile, expected: tuple[int, int, int, int, int, int]) -> None:
    soft, hard, max_units, max_attempts, max_replans, max_replacements = expected
    spec = get(name)
    assert spec.task_budget is not None, name
    budget = spec.task_budget(profile)
    budget.validate()
    assert budget.soft_timeout_seconds == soft, (name, budget)
    assert budget.hard_timeout_seconds == hard, (name, budget)
    assert budget.max_work_units == max_units, (name, budget)
    assert budget.max_implementation_attempts == max_attempts, (name, budget)
    assert budget.max_replans == max_replans, (name, budget)
    assert budget.max_replacements == max_replacements, (name, budget)
    stage = spec.lifecycle(profile, "implementation")
    assert budget.max_work_units == stage.maximum_work_units, (name, budget, stage)


def main() -> None:
    routine = task()
    complex_cross = task(complexity="complex", scope="cross-module")
    demanding = task(
        complexity="critical",
        risk="critical",
        scope="repo-wide",
        iteration_intensity="heavy-loop",
        verification_cost="high",
        quality_intent="absolute",
    )

    lifecycle_expected = {
        "efficient": {
            "routine": (600, 180, 1, 1, 1800),
            "complex": (900, 240, 2, 2, 1800),
            "demanding": (1200, 300, 2, 3, 1800),
        },
        "balanced": {
            "routine": (1200, 240, 1, 1, 2400),
            "complex": (1500, 300, 2, 2, 2400),
            "demanding": (1800, 360, 2, 3, 2400),
        },
        "quality": {
            "routine": (1800, 360, 2, 1, 3600),
            "complex": (2400, 480, 3, 3, 3600),
            "demanding": (2700, 600, 3, 4, 3600),
        },
        "speed": {
            "routine": (420, 180, 1, 1, 1200),
            "complex": (600, 180, 1, 3, 1200),
            "demanding": (720, 180, 1, 4, 1200),
        },
    }

    budget_expected = {
        "efficient": {
            "routine": (1500, 1800, 1, 2, 1, 1),
            "complex": (1500, 1800, 2, 3, 1, 1),
            "demanding": (1500, 1800, 3, 4, 1, 1),
        },
        "balanced": {
            "routine": (2400, 3000, 1, 3, 2, 2),
            "complex": (2700, 3300, 2, 4, 2, 2),
            "demanding": (3000, 3600, 3, 5, 2, 2),
        },
        "quality": {
            "routine": (4800, 6000, 1, 4, 3, 3),
            "complex": (5400, 6600, 3, 6, 3, 3),
            "demanding": (6000, 7200, 4, 7, 3, 3),
        },
        "speed": {
            "routine": (1200, 1800, 1, 2, 1, 1),
            "complex": (1200, 1800, 3, 4, 1, 1),
            "demanding": (1200, 1800, 4, 5, 1, 1),
        },
    }

    profiles = {
        "routine": routine,
        "complex": complex_cross,
        "demanding": demanding,
    }
    for strategy, matrix in lifecycle_expected.items():
        for label, profile in profiles.items():
            assert_profile(strategy, profile, matrix[label])
            assert_task_budget(strategy, profile, budget_expected[strategy][label])

    print("shared strategy lifecycle and task-budget contract tests passed")


if __name__ == "__main__":
    main()
