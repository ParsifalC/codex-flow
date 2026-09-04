#!/usr/bin/env python3
"""Deterministic validator for bounded implementation work-unit manifests.

FlowPilot partitions a strategy-owned bounded implementation stage into logical
units before spawning implementers. This helper validates the manifest against
ExecutionPlan StagePolicy and the already-resolved implementation concurrency so
unit boundaries, dependency ordering, and writable parallelism are explicit
rather than improvised by Parent.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
from collections import defaultdict
from dataclasses import dataclass
from typing import Any, Iterable

WORK_UNIT_MODES = {"single", "bounded"}


def _strict_string(value: Any, label: str) -> str:
    """Return a manifest string without coercing other JSON scalar types."""
    if type(value) is not str:
        raise ValueError(f"{label} must be a string")
    result = value.strip()
    if not result:
        raise ValueError(f"{label} must be a non-empty string")
    return result


def _strict_int(value: Any, label: str, *, minimum: int | None = None) -> int:
    """Validate JSON integers explicitly; bool is an int subclass in Python."""
    if type(value) is not int:
        raise ValueError(f"{label} must be an integer")
    if minimum is not None and value < minimum:
        raise ValueError(f"{label} must be >= {minimum}")
    return value


def _normalize_repo_path(value: Any, label: str) -> str:
    """Validate and return one normalized, repo-relative POSIX path.

    This is deliberately lexical preflight only. It does not resolve symlinks or
    provide an operating-system lock, so the caller must still retain normal
    writable-scope/fencing safeguards.
    """
    path = _strict_string(value, label)
    if "\x00" in path:
        raise ValueError(f"{label} must not contain NUL")
    if "\\" in path:
        raise ValueError(f"{label} must use POSIX separators and must not contain backslashes")
    if path.startswith("/"):
        raise ValueError(f"{label} must be repo-relative, not absolute")
    if re.match(r"^[A-Za-z]:", path):
        raise ValueError(f"{label} must not use a Windows drive path")
    if any(char in path for char in "*?[]{}"):
        raise ValueError(f"{label} must not contain glob metacharacters")

    components = path.split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise ValueError(f"{label} must be a normalized path without empty, '.' or '..' components")

    normalized = posixpath.normpath(path)
    if normalized in {"", ".", ".."} or normalized != path or normalized.startswith("../"):
        raise ValueError(f"{label} must be a normalized repo-relative POSIX path")
    return normalized


@dataclass(frozen=True)
class WorkUnit:
    unit_id: str
    scope_id: str
    acceptance_delta: str
    write_scope_id: str
    validation: tuple[str, ...]
    depends_on: tuple[str, ...]
    parallel_group: str | None = None
    generation: int = 0
    write_paths: tuple[str, ...] = ()

    @classmethod
    def from_dict(cls, value: dict[str, Any]) -> "WorkUnit":
        required = ("unit_id", "scope_id", "acceptance_delta", "write_scope_id", "validation")
        missing = [key for key in required if key not in value]
        if missing:
            raise ValueError(f"work unit missing fields: {missing}")

        unit_id = _strict_string(value["unit_id"], "unit_id")
        scope_id = _strict_string(value["scope_id"], f"work unit {unit_id}: scope_id")
        acceptance_delta = _strict_string(
            value["acceptance_delta"], f"work unit {unit_id}: acceptance_delta"
        )
        write_scope_id = _strict_string(
            value["write_scope_id"], f"work unit {unit_id}: write_scope_id"
        )

        raw_validation = value["validation"]
        if type(raw_validation) is not list or not raw_validation:
            raise ValueError(f"work unit {unit_id}: validation must be a non-empty list")
        validation = tuple(
            _strict_string(item, f"work unit {unit_id}: validation entry") for item in raw_validation
        )

        if "depends_on" in value:
            raw_dependencies = value["depends_on"]
        else:
            raw_dependencies = []
        if type(raw_dependencies) is not list:
            raise ValueError(f"work unit {unit_id}: depends_on must be a list")
        depends_on = tuple(
            _strict_string(item, f"work unit {unit_id}: depends_on entry") for item in raw_dependencies
        )
        if len(set(depends_on)) != len(depends_on):
            raise ValueError(f"work unit {unit_id}: depends_on entries must be unique")
        if unit_id in depends_on:
            raise ValueError(f"work unit {unit_id}: unit cannot depend on itself")

        if value.get("parallel_group") is not None:
            parallel_group = _strict_string(
                value["parallel_group"], f"work unit {unit_id}: parallel_group"
            )
        else:
            parallel_group = None

        if "generation" in value:
            generation = _strict_int(
                value["generation"], f"work unit {unit_id}: generation", minimum=0
            )
        else:
            generation = 0

        if "write_paths" in value:
            raw_write_paths = value["write_paths"]
            if type(raw_write_paths) is not list or not raw_write_paths:
                raise ValueError(f"work unit {unit_id}: write_paths must be a non-empty list")
            write_paths = tuple(
                _normalize_repo_path(item, f"work unit {unit_id}: write_paths entry")
                for item in raw_write_paths
            )
            if len(set(write_paths)) != len(write_paths):
                raise ValueError(f"work unit {unit_id}: write_paths entries must be unique")
        else:
            write_paths = ()

        return cls(
            unit_id=unit_id,
            scope_id=scope_id,
            acceptance_delta=acceptance_delta,
            write_scope_id=write_scope_id,
            validation=validation,
            depends_on=depends_on,
            parallel_group=parallel_group,
            generation=generation,
            write_paths=write_paths,
        )


def _load_json(raw: str, label: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid {label} JSON: {exc}") from exc


def _positive_int(value: Any, label: str) -> int:
    if type(value) is not int:
        raise ValueError(f"{label} must be an integer")
    if value < 1:
        raise ValueError(f"{label} must be positive")
    return value


def _policy_contract(value: dict[str, Any]) -> tuple[str, int, bool, int | None, bool, bool]:
    if type(value) is not dict:
        raise ValueError("policy must be an object")

    mode = value.get("work_unit_mode", "single")
    if type(mode) is not str:
        raise ValueError("work_unit_mode must be a string")
    minimum = _strict_int(
        value["minimum_work_units"] if "minimum_work_units" in value else 1,
        "minimum_work_units",
        minimum=1,
    )
    join_between = value.get("join_between_work_units", False)
    if type(join_between) is not bool:
        raise ValueError("join_between_work_units must be boolean")

    maximum = value.get("maximum_work_units") if "maximum_work_units" in value else None
    # StagePolicy serializes an omitted Optional field as null. Treat that as
    # legacy absence; any concrete value must be an integer and is enforced.
    if maximum is not None:
        maximum = _strict_int(maximum, "maximum_work_units", minimum=1)

    require_write_paths = value.get("require_write_paths", False)
    if type(require_write_paths) is not bool:
        raise ValueError("require_write_paths must be boolean")

    if mode not in WORK_UNIT_MODES:
        raise ValueError(f"invalid work_unit_mode: {mode}")
    if mode == "single":
        if minimum != 1:
            raise ValueError("single work-unit mode requires minimum_work_units=1")
        if join_between:
            raise ValueError("single work-unit mode cannot join between work units")
        if maximum is not None and maximum != 1:
            raise ValueError("single work-unit mode requires maximum_work_units=1")
    else:
        if not join_between:
            raise ValueError("bounded work-unit mode requires Parent joins between work units")
        if maximum is not None and maximum < minimum:
            raise ValueError("bounded work-unit mode requires maximum_work_units >= minimum_work_units")

    # New bounded plans opt into generation/path lineage through either a
    # concrete maximum or require_write_paths. Older bounded policies omit both
    # fields and continue to support serial manifests without write_paths.
    new_bounded = mode == "bounded" and (maximum is not None or require_write_paths)
    return mode, minimum, join_between, maximum, require_write_paths, new_bounded


def _check_dependencies(units: tuple[WorkUnit, ...]) -> dict[str, WorkUnit]:
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
    return by_id


def _depends_on_transitively(
    by_id: dict[str, WorkUnit],
    unit_id: str,
    dependency_id: str,
) -> bool:
    stack = list(by_id[unit_id].depends_on)
    seen: set[str] = set()
    while stack:
        current = stack.pop()
        if current == dependency_id:
            return True
        if current in seen:
            continue
        seen.add(current)
        stack.extend(by_id[current].depends_on)
    return False


def _paths_overlap(left: str, right: str) -> bool:
    return left == right or left.startswith(f"{right}/") or right.startswith(f"{left}/")


def _check_acceptance_deltas(units: tuple[WorkUnit, ...]) -> None:
    seen: dict[str, str] = {}
    for unit in units:
        previous = seen.get(unit.acceptance_delta)
        if previous is not None:
            raise ValueError(
                f"work units {previous!r} and {unit.unit_id!r}: acceptance_delta must be unique"
            )
        seen[unit.acceptance_delta] = unit.unit_id


def _check_write_path_order(units: tuple[WorkUnit, ...], by_id: dict[str, WorkUnit]) -> None:
    """Require dependency ordering for every known path overlap.

    Legacy manifests may omit paths, so an unknown path is not treated as an
    overlap here. Parallel groups independently reject missing paths, which keeps
    legacy serial execution compatible without claiming unproven isolation.
    """
    for index, left in enumerate(units):
        if not left.write_paths:
            continue
        for right in units[index + 1 :]:
            if not right.write_paths:
                continue
            overlaps = [
                (left_path, right_path)
                for left_path in left.write_paths
                for right_path in right.write_paths
                if _paths_overlap(left_path, right_path)
            ]
            if not overlaps:
                continue
            linked = _depends_on_transitively(by_id, left.unit_id, right.unit_id) or _depends_on_transitively(
                by_id, right.unit_id, left.unit_id
            )
            if not linked:
                left_path, right_path = overlaps[0]
                raise ValueError(
                    f"work units {left.unit_id!r} and {right.unit_id!r} have overlapping write paths "
                    f"({left_path!r}, {right_path!r}); they must be directly or transitively dependency-linked"
                )


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


def _check_parallel_groups(
    units: tuple[WorkUnit, ...],
    by_id: dict[str, WorkUnit],
    *,
    max_parallel_units: int,
) -> None:
    groups: dict[str, list[WorkUnit]] = defaultdict(list)
    for unit in units:
        if unit.parallel_group is not None:
            groups[unit.parallel_group].append(unit)
    for group, members in groups.items():
        if len(members) > max_parallel_units:
            raise ValueError(
                f"parallel group {group!r} has {len(members)} units but ExecutionPlan allows at most "
                f"{max_parallel_units} concurrent implementation units"
            )
        seen_scopes: set[str] = set()
        for member in members:
            if not member.write_paths:
                raise ValueError(
                    f"parallel group {group!r} requires write_paths for every member; "
                    f"work unit {member.unit_id!r} is missing them"
                )
            if member.write_scope_id in seen_scopes:
                raise ValueError(
                    f"parallel group {group!r} contains overlapping write scope {member.write_scope_id!r}"
                )
            seen_scopes.add(member.write_scope_id)

        for index, left in enumerate(members):
            for right in members[index + 1 :]:
                if any(
                    _paths_overlap(left_path, right_path)
                    for left_path in left.write_paths
                    for right_path in right.write_paths
                ):
                    raise ValueError(
                        f"parallel group {group!r} contains overlapping write paths between "
                        f"{left.unit_id!r} and {right.unit_id!r}"
                    )
                if _depends_on_transitively(by_id, left.unit_id, right.unit_id) or _depends_on_transitively(
                    by_id, right.unit_id, left.unit_id
                ):
                    raise ValueError(
                        f"parallel group {group!r} contains transitively dependency-linked units; "
                        "dependent units must run in later waves"
                    )


def _unit_fingerprint(unit: WorkUnit) -> str:
    payload = {
        "unit_id": unit.unit_id,
        "scope_id": unit.scope_id,
        "generation": unit.generation,
        "acceptance_delta": unit.acceptance_delta,
        "write_scope_id": unit.write_scope_id,
        "write_paths": list(unit.write_paths),
        "validation": list(unit.validation),
        "depends_on": list(unit.depends_on),
    }
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def validate_manifest(
    policy: dict[str, Any],
    manifest: dict[str, Any],
    *,
    implementation_workers: int = 1,
    max_concurrent_threads: int = 1,
) -> dict[str, Any]:
    if type(policy) is not dict:
        raise ValueError("policy must be an object")
    if type(manifest) is not dict:
        raise ValueError("manifest must be an object")
    implementation_workers = _positive_int(implementation_workers, "implementation_workers")
    max_concurrent_threads = _positive_int(max_concurrent_threads, "max_concurrent_threads")
    max_parallel_units = min(implementation_workers, max_concurrent_threads)

    mode, minimum, join_between, maximum, require_write_paths, new_bounded = _policy_contract(policy)
    raw_units = manifest.get("units")
    if type(raw_units) is not list or not raw_units:
        raise ValueError("manifest.units must be a non-empty list")
    units = tuple(WorkUnit.from_dict(value) for value in raw_units if type(value) is dict)
    if len(units) != len(raw_units):
        raise ValueError("every manifest unit must be an object")

    if mode == "single" and len(units) != 1:
        raise ValueError("single work-unit mode requires exactly one manifest unit")
    if mode == "bounded" and len(units) < minimum:
        raise ValueError(
            f"bounded implementation requires at least {minimum} work units; got {len(units)}"
        )
    if maximum is not None and len(units) > maximum:
        raise ValueError(
            f"manifest contains {len(units)} work units but policy maximum_work_units is {maximum}"
        )

    if new_bounded:
        missing_generation = [unit.unit_id for raw, unit in zip(raw_units, units) if "generation" not in raw]
        if missing_generation:
            raise ValueError(
                f"new bounded policy requires generation for every work unit; missing: {missing_generation}"
            )
    if require_write_paths:
        missing_paths = [unit.unit_id for raw, unit in zip(raw_units, units) if "write_paths" not in raw]
        if missing_paths:
            raise ValueError(
                f"policy requires write_paths for every work unit; missing: {missing_paths}"
            )
        empty_paths = [unit.unit_id for unit in units if not unit.write_paths]
        if empty_paths:
            raise ValueError(
                f"policy requires non-empty write_paths for every work unit; empty: {empty_paths}"
            )

    by_id = _check_dependencies(units)
    _check_acceptance_deltas(units)
    _check_shared_writable_scope_order(units)
    _check_write_path_order(units, by_id)
    _check_parallel_groups(units, by_id, max_parallel_units=max_parallel_units)

    parallel_groups = sorted({unit.parallel_group for unit in units if unit.parallel_group is not None})
    fingerprints = {unit.unit_id: _unit_fingerprint(unit) for unit in units}
    return {
        "valid": True,
        "work_unit_mode": mode,
        "minimum_work_units": minimum,
        "maximum_work_units": maximum,
        "require_write_paths": require_write_paths,
        "join_between_work_units": join_between,
        "unit_count": len(units),
        "unit_ids": [unit.unit_id for unit in units],
        "parallel_groups": parallel_groups,
        "max_parallel_units": max_parallel_units,
        "unit_fingerprints": fingerprints,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="work-unit-runtime")
    parser.add_argument("--policy-json", required=True, help="implementation_stage JSON object")
    parser.add_argument("--manifest-json", required=True, help="bounded work-unit manifest JSON object")
    parser.add_argument("--implementation-workers", required=True, type=int)
    parser.add_argument("--max-concurrent-threads", required=True, type=int)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    ns = build_parser().parse_args(list(argv) if argv is not None else None)
    policy = _load_json(ns.policy_json, "policy")
    manifest = _load_json(ns.manifest_json, "manifest")
    if not isinstance(policy, dict):
        raise ValueError("policy must be a JSON object")
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")
    print(
        json.dumps(
            validate_manifest(
                policy,
                manifest,
                implementation_workers=ns.implementation_workers,
                max_concurrent_threads=ns.max_concurrent_threads,
            ),
            ensure_ascii=False,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
