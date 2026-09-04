#!/usr/bin/env python3
"""Deterministic validator for bounded implementation work-unit manifests.

FlowPilot partitions a strategy-owned bounded implementation stage into logical
units before spawning implementers. This helper validates the manifest against
ExecutionPlan StagePolicy so unit boundaries, dependency ordering, and writable
parallelism are explicit rather than improvised by Parent.
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Iterable

WORK_UNIT_MODES = {"single", "bounded"}


@dataclass(frozen=True)
class WorkUnit:
    unit_id: str
    scope_id: str
    acceptance_delta: str
    write_scope_id: str
    validation: tuple[str, ...]
    depends_on: tuple[str, ...]
    parallel_group: str | None = None

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "WorkUnit":
        required = ("unit_id", "scope_id", "acceptance_delta", "write_scope_id", "validation")
        missing = [key for key in required if key not in value]
        if missing:
            raise ValueError(f"work unit missing fields: {missing}")

        unit_id = str(value["unit_id"]).strip()
        scope_id = str(value["scope_id"]).strip()
        acceptance_delta = str(value["acceptance_delta"]).strip()
        write_scope_id = str(value["write_scope_id"]).strip()
        if not unit_id or not scope_id or not acceptance_delta or not write_scope_id:
            raise ValueError("unit_id, scope_id, acceptance_delta, and write_scope_id must be non-empty")

        raw_validation = value["validation"]
        if not isinstance(raw_validation, list) or not raw_validation:
            raise ValueError(f"work unit {unit_id}: validation must be a non-empty list")
        validation = tuple(str(item).strip() for item in raw_validation)
        if any(not item for item in validation):
            raise ValueError(f"work unit {unit_id}: validation entries must be non-empty")

        raw_dependencies = value.get("depends_on", [])
        if not isinstance(raw_dependencies, list):
            raise ValueError(f"work unit {unit_id}: depends_on must be a list")
        depends_on = tuple(str(item).strip() for item in raw_dependencies)
        if any(not item for item in depends_on):
            raise ValueError(f"work unit {unit_id}: depends_on entries must be non-empty")
        if unit_id in depends_on:
            raise ValueError(f"work unit {unit_id}: unit cannot depend on itself")

        parallel_group = value.get("parallel_group")
        if parallel_group is not None:
            parallel_group = str(parallel_group).strip() or None

        return cls(
            unit_id=unit_id,
            scope_id=scope_id,
            acceptance_delta=acceptance_delta,
            write_scope_id=write_scope_id,
            validation=validation,
            depends_on=depends_on,
            parallel_group=parallel_group,
        )


def _load_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid {label} JSON: {exc}") from exc


def _policy_contract(value: dict[str, Any]) -> tuple[str, int, bool]:
    mode = str(value.get("work_unit_mode", "single"))
    try:
        minimum = int(value.get("minimum_work_units", 1))
    except (TypeError, ValueError) as exc:
        raise ValueError("minimum_work_units must be an integer") from exc
    join_between = value.get("join_between_work_units", False)
    if not isinstance(join_between, bool):
        raise ValueError("join_between_work_units must be boolean")
    if mode not in WORK_UNIT_MODES:
        raise ValueError(f"invalid work_unit_mode: {mode}")
    if minimum < 1:
        raise ValueError("minimum_work_units must be positive")
    if mode == "single":
        if minimum != 1:
            raise ValueError("single work-unit mode requires minimum_work_units=1")
        if join_between:
            raise ValueError("single work-unit mode cannot join between work units")
    else:
        if minimum < 2:
            raise ValueError("bounded work-unit mode requires at least two work units")
        if not join_between:
            raise ValueError("bounded work-unit mode requires Parent joins between work units")
    return mode, minimum, join_between


def _check_dependencies(units: tuple[WorkUnit, ...]) -> None:
    by_id = {unit.unit_id: unit for unit in units}
    if len(by_id) != len(units):
        raise ValueError("work-unit ids must be unique")

    for unit in units:
        unknown = [dependency for dependency in unit.depends_on if dependency not in by_id]
        if unknown:
            raise ValueError(f"work unit {unit.unit_id}: unknown dependencies: {unknown}")

    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(unit_id: str) -> None:
        if unit_id in visited:
            return
        if unit_id in visiting:
            raise ValueError("work-unit dependency graph contains a cycle")
        visiting.add(unit_id)
        for dependency in by_id[unit_id].depends_on:
            visit(dependency)
        visiting.remove(unit_id)
        visited.add(unit_id)

    for unit_id in by_id:
        visit(unit_id)


def _check_shared_writable_scope_order(units: tuple[WorkUnit, ...]) -> None:
    previous_by_scope: dict[str, WorkUnit] = {}
    for unit in units:
        previous = previous_by_scope.get(unit.write_scope_id)
        if previous is not None and previous.unit_id not in unit.depends_on:
            raise ValueError(
                f"work unit {unit.unit_id}: shared write_scope_id {unit.write_scope_id!r} "
                f"must directly depend on previous unit {previous.unit_id!r}"
            )
        previous_by_scope[unit.write_scope_id] = unit


def _check_parallel_groups(units: tuple[WorkUnit, ...]) -> None:
    groups: dict[str, list[WorkUnit]] = defaultdict(list)
    for unit in units:
        if unit.parallel_group is not None:
            groups[unit.parallel_group].append(unit)
    for group, members in groups.items():
        seen_scopes: set[str] = set()
        for member in members:
            if member.write_scope_id in seen_scopes:
                raise ValueError(
                    f"parallel group {group!r} contains overlapping write scope {member.write_scope_id!r}"
                )
            seen_scopes.add(member.write_scope_id)
        member_ids = {member.unit_id for member in members}
        for member in members:
            if member_ids.intersection(member.depends_on):
                raise ValueError(
                    f"parallel group {group!r} contains dependency-linked units; dependent units must run in later waves"
                )


def validate_manifest(policy: dict[str, Any], manifest: dict[str, Any]) -> dict[str, Any]:
    mode, minimum, join_between = _policy_contract(policy)
    raw_units = manifest.get("units")
    if not isinstance(raw_units, list) or not raw_units:
        raise ValueError("manifest.units must be a non-empty list")
    units = tuple(WorkUnit.from_dict(value) for value in raw_units if isinstance(value, dict))
    if len(units) != len(raw_units):
        raise ValueError("every manifest unit must be an object")

    if mode == "single" and len(units) != 1:
        raise ValueError("single work-unit mode requires exactly one manifest unit")
    if mode == "bounded" and len(units) < minimum:
        raise ValueError(
            f"bounded implementation requires at least {minimum} work units; got {len(units)}"
        )

    _check_dependencies(units)
    _check_shared_writable_scope_order(units)
    _check_parallel_groups(units)

    parallel_groups = sorted({unit.parallel_group for unit in units if unit.parallel_group is not None})
    return {
        "valid": True,
        "work_unit_mode": mode,
        "minimum_work_units": minimum,
        "join_between_work_units": join_between,
        "unit_count": len(units),
        "unit_ids": [unit.unit_id for unit in units],
        "parallel_groups": parallel_groups,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="work-unit-runtime")
    parser.add_argument("--policy-json", required=True, help="implementation_stage JSON object")
    parser.add_argument("--manifest-json", required=True, help="bounded work-unit manifest JSON object")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    ns = build_parser().parse_args(list(argv) if argv is not None else None)
    policy = _load_json(ns.policy_json, "policy")
    manifest = _load_json(ns.manifest_json, "manifest")
    if not isinstance(policy, dict):
        raise ValueError("policy must be a JSON object")
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")
    print(json.dumps(validate_manifest(policy, manifest), ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
