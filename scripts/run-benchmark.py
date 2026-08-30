#!/usr/bin/env python3
"""Run reproducible direct-model and codex-flow benchmark strategies.

Result schema v2 adds an explicit strategy dimension. Direct strategies use
one Codex model for implementation and bounded verifier repairs. The flow
strategy uses a capable parent for read-only planning/review and a cheaper
worker for all writes. Usage is attributed per role/model so mixed-model cost
is measurable instead of estimated.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

VALID_CLASSES = {"routine", "complex", "critical"}
VALID_EFFORTS = {"high", "xhigh", "max"}
VALID_STRATEGIES = {"direct", "flow"}
FULL_COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")
MAX_CAPTURE = 8000
REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"enum": ["pass", "repair"]},
        "feedback": {"type": "string"},
    },
    "required": ["verdict", "feedback"],
    "additionalProperties": False,
}


def fail(message: str) -> None:
    raise ValueError(message)


def config_id(config: dict[str, Any]) -> str:
    if isinstance(config.get("id"), str) and config["id"]:
        return config["id"]
    if config.get("strategy", "direct") == "flow":
        fail("flow strategies require a non-empty id")
    return f"{config['model']}-{config['reasoning_effort']}"


def config_strategy(config: dict[str, Any]) -> str:
    return config.get("strategy", "direct")


def validate_actor(actor: Any, label: str) -> None:
    if not isinstance(actor, dict):
        fail(f"{label} must be an object")
    if not isinstance(actor.get("model"), str) or not actor["model"]:
        fail(f"{label}.model must be a non-empty string")
    effort = actor.get("reasoning_effort")
    if isinstance(effort, str):
        if effort not in VALID_EFFORTS:
            fail(f"invalid {label}.reasoning_effort: {effort!r}")
    elif isinstance(effort, dict):
        if set(effort) != VALID_CLASSES or any(value not in VALID_EFFORTS for value in effort.values()):
            fail(f"{label}.reasoning_effort must define valid routine/complex/critical efforts")
    else:
        fail(f"invalid {label}.reasoning_effort: {effort!r}")


def actor_effort(actor: dict[str, Any], task_class: str) -> str:
    effort = actor["reasoning_effort"]
    return effort[task_class] if isinstance(effort, dict) else effort


def config_models(config: dict[str, Any]) -> set[str]:
    if config_strategy(config) == "direct":
        return {config["model"]}
    return {config["parent"]["model"], config["worker"]["model"]}


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    version = data.get("schema_version")
    if version not in {1, 2}:
        fail("manifest schema_version must be 1 or 2")
    tasks = data.get("tasks")
    matrix = data.get("matrix")
    if not isinstance(tasks, list) or not tasks:
        fail("manifest tasks must be a non-empty array")
    if not isinstance(matrix, list) or not matrix:
        fail("manifest matrix must be a non-empty array")
    allow_floating = data.get("allow_floating_refs", False)
    if not isinstance(allow_floating, bool):
        fail("allow_floating_refs must be boolean")

    task_ids: set[str] = set()
    for task in tasks:
        required = {"id", "class", "source", "base_ref", "prompt", "verify"}
        missing = required - task.keys()
        if missing:
            fail(f"task missing fields: {sorted(missing)}")
        if task["id"] in task_ids:
            fail(f"duplicate task id: {task['id']}")
        task_ids.add(task["id"])
        if task["class"] not in VALID_CLASSES:
            fail(f"invalid task class for {task['id']}: {task['class']}")
        if not isinstance(task["verify"], list) or not task["verify"] or not all(isinstance(x, str) for x in task["verify"]):
            fail(f"verify for {task['id']} must be a non-empty argv array")
        for field in ("prompt", "source", "base_ref"):
            if not isinstance(task[field], str) or not task[field].strip():
                fail(f"{field} for {task['id']} must be non-empty")
        if not allow_floating and not FULL_COMMIT_RE.fullmatch(task["base_ref"]):
            fail(
                f"task {task['id']} base_ref must be a full 40-character commit SHA; "
                "set allow_floating_refs=true only for exploratory runs"
            )

    strategy_ids: set[str] = set()
    for config in matrix:
        if not isinstance(config, dict):
            fail("matrix entries must be objects")
        strategy = config_strategy(config)
        if strategy not in VALID_STRATEGIES:
            fail(f"invalid strategy: {strategy!r}")
        identifier = config_id(config)
        if identifier in strategy_ids:
            fail(f"duplicate strategy id: {identifier}")
        strategy_ids.add(identifier)
        if strategy == "direct":
            validate_actor(config, f"matrix[{identifier}]")
            if not isinstance(config["reasoning_effort"], str):
                fail(f"matrix[{identifier}] direct strategies require a fixed reasoning_effort")
        else:
            if version < 2:
                fail("flow strategies require manifest schema_version 2")
            validate_actor(config.get("parent"), f"matrix[{identifier}].parent")
            validate_actor(config.get("worker"), f"matrix[{identifier}].worker")
            policy = config.get("reasoning_policy", "fixed")
            if policy not in {"fixed", "adaptive"}:
                fail(f"matrix[{identifier}].reasoning_policy must be fixed or adaptive")
            parent_effort = config["parent"]["reasoning_effort"]
            worker_effort = config["worker"]["reasoning_effort"]
            if policy == "fixed" and not all(isinstance(value, str) for value in (parent_effort, worker_effort)):
                fail(f"matrix[{identifier}] fixed flow requires fixed actor reasoning efforts")
            if policy == "adaptive" and not all(isinstance(value, dict) for value in (parent_effort, worker_effort)):
                fail(f"matrix[{identifier}] adaptive flow requires per-class actor reasoning efforts")

    repetitions = data.get("repetitions", 1)
    timeout = data.get("timeout_seconds", 1800)
    repairs = data.get("max_repair_cycles", 2)
    if not isinstance(repetitions, int) or repetitions < 1:
        fail("repetitions must be >= 1")
    if not isinstance(timeout, int) or timeout < 1:
        fail("timeout_seconds must be >= 1")
    if not isinstance(repairs, int) or repairs < 0:
        fail("max_repair_cycles must be >= 0")
    return data


def clone_source(source: str, base_ref: str, destination: Path) -> str:
    subprocess.run(
        ["git", "clone", "--quiet", "--no-checkout", source, str(destination)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    subprocess.run(
        ["git", "-C", str(destination), "checkout", "--quiet", "--detach", base_ref],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return subprocess.check_output(
        ["git", "-C", str(destination), "rev-parse", "HEAD"], text=True
    ).strip()


def parse_usage(jsonl: str) -> dict[str, int]:
    usage = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    for line in jsonl.splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") != "turn.completed" or not isinstance(event.get("usage"), dict):
            continue
        for key in usage:
            value = event["usage"].get(key, 0)
            if isinstance(value, int) and value >= 0:
                usage[key] += value
    return usage


def run_codex(
    workdir: Path,
    model: str,
    effort: str,
    prompt: str,
    timeout: int,
    *,
    sandbox: str = "workspace-write",
    last_message_path: Path | None = None,
    output_schema_path: Path | None = None,
) -> tuple[int, dict[str, int], str, float, str]:
    cmd = [
        "codex", "exec", "--ephemeral", "--json", "--ignore-user-config",
        "--sandbox", sandbox, "--model", model,
        "-c", f'model_reasoning_effort="{effort}"',
    ]
    if output_schema_path is not None:
        cmd.extend(["--output-schema", str(output_schema_path)])
    if last_message_path is not None:
        cmd.extend(["--output-last-message", str(last_message_path)])
    cmd.extend(["--cd", str(workdir), prompt])
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        elapsed = time.monotonic() - started
        last_message = ""
        if last_message_path is not None and last_message_path.exists():
            last_message = last_message_path.read_text()[-MAX_CAPTURE:]
        return proc.returncode, parse_usage(proc.stdout), (proc.stderr or proc.stdout)[-MAX_CAPTURE:], elapsed, last_message
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - started
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return 124, parse_usage(stdout), (stderr or stdout)[-MAX_CAPTURE:], elapsed, ""


def run_verify(workdir: Path, argv: list[str], timeout: int) -> tuple[bool, str, float]:
    started = time.monotonic()
    try:
        proc = subprocess.run(argv, cwd=workdir, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode == 0, proc.stdout[-MAX_CAPTURE:], time.monotonic() - started
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout if isinstance(exc.stdout, str) else ""
        return False, (output + "\nverification timed out")[-MAX_CAPTURE:], time.monotonic() - started


def empty_usage() -> dict[str, int]:
    return {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}


def add_usage(total: dict[str, int], current: dict[str, int]) -> None:
    for key in empty_usage():
        total[key] += current[key]


def add_model_usage(
    totals: dict[tuple[str, str, str], dict[str, int]],
    role: str,
    model: str,
    effort: str,
    usage: dict[str, int],
) -> None:
    key = (role, model, effort)
    if key not in totals:
        totals[key] = {**empty_usage(), "calls": 0}
    add_usage(totals[key], usage)
    totals[key]["calls"] += 1


def flatten_model_usage(totals: dict[tuple[str, str, str], dict[str, int]]) -> list[dict[str, Any]]:
    return [
        {"role": role, "model": model, "reasoning_effort": effort, **usage}
        for (role, model, effort), usage in sorted(totals.items())
    ]


def build_row(
    task: dict[str, Any],
    config: dict[str, Any],
    repetition: int,
    commit: str,
    passed: bool,
    first_passed: bool,
    repair_cycles: int,
    review_cycles: int,
    total_wall: float,
    codex_exit: int,
    verification: str,
    diagnostic: str,
    usage_by_model: dict[tuple[str, str, str], dict[str, int]],
) -> dict[str, Any]:
    strategy = config_strategy(config)
    if strategy == "direct":
        model = config["model"]
        effort = actor_effort(config, task["class"])
        worker_model = None
        worker_effort = None
        reasoning_policy = "fixed"
    else:
        model = config["parent"]["model"]
        effort = actor_effort(config["parent"], task["class"])
        worker_model = config["worker"]["model"]
        worker_effort = actor_effort(config["worker"], task["class"])
        reasoning_policy = config.get("reasoning_policy", "fixed")
    model_usage = flatten_model_usage(usage_by_model)
    total_usage = empty_usage()
    for item in model_usage:
        add_usage(total_usage, item)
    return {
        "schema_version": 2,
        "task_id": task["id"],
        "task_class": task["class"],
        "strategy_id": config_id(config),
        "strategy": strategy,
        "reasoning_policy": reasoning_policy,
        "model": model,
        "reasoning_effort": effort,
        "worker_model": worker_model,
        "worker_reasoning_effort": worker_effort,
        "passed": passed,
        "first_passed": first_passed,
        **total_usage,
        "model_usage": model_usage,
        "repair_cycles": repair_cycles,
        "review_cycles": review_cycles,
        "wall_time_seconds": round(total_wall, 3),
        "source_commit": commit,
        "repetition": repetition,
        "codex_exit_code": codex_exit,
        "verification_excerpt": verification[-2000:] if not passed else "",
        "diagnostic_excerpt": diagnostic[-2000:] if codex_exit != 0 else "",
    }


def execute_direct(
    task: dict[str, Any],
    config: dict[str, Any],
    root: Path,
    repetition: int,
    timeout: int,
    max_repairs: int,
) -> dict[str, Any]:
    workdir = root / "repo"
    commit = clone_source(task["source"], task["base_ref"], workdir)
    model = config["model"]
    effort = actor_effort(config, task["class"])
    usage_by_model: dict[tuple[str, str, str], dict[str, int]] = {}
    total_wall = 0.0

    codex_exit, usage, diagnostic, elapsed, _ = run_codex(
        workdir, model, effort, task["prompt"], timeout
    )
    total_wall += elapsed
    add_model_usage(usage_by_model, "direct", model, effort, usage)
    repair_cycles = 0

    if codex_exit == 0:
        passed, verification, verify_elapsed = run_verify(workdir, task["verify"], timeout)
        total_wall += verify_elapsed
    else:
        passed = False
        verification = "benchmark verification skipped because codex exec exited non-zero"
    first_passed = passed

    while not passed and codex_exit == 0 and repair_cycles < max_repairs:
        repair_cycles += 1
        repair_prompt = (
            "The previous implementation did not pass the fixed benchmark verifier. "
            "Repair only the implementation needed to satisfy the original task; do not weaken, skip, or edit the verifier.\n\n"
            f"Original task:\n{task['prompt']}\n\nVerifier output:\n{verification}"
        )
        codex_exit, usage, diagnostic, elapsed, _ = run_codex(
            workdir, model, effort, repair_prompt, timeout
        )
        total_wall += elapsed
        add_model_usage(usage_by_model, "direct", model, effort, usage)
        if codex_exit != 0:
            passed = False
            verification = "benchmark verification skipped because repair codex exec exited non-zero"
            break
        passed, verification, verify_elapsed = run_verify(workdir, task["verify"], timeout)
        total_wall += verify_elapsed

    return build_row(
        task, config, repetition, commit, passed, first_passed, repair_cycles, 0,
        total_wall, codex_exit, verification, diagnostic, usage_by_model,
    )


def parse_review(message: str) -> tuple[str, str]:
    try:
        review = json.loads(message)
    except json.JSONDecodeError as exc:
        fail(f"parent review did not return valid JSON: {exc}")
    verdict = review.get("verdict")
    feedback = review.get("feedback")
    if verdict not in {"pass", "repair"} or not isinstance(feedback, str):
        fail("parent review must contain verdict=pass|repair and string feedback")
    return verdict, feedback


def execute_flow(
    task: dict[str, Any],
    config: dict[str, Any],
    root: Path,
    repetition: int,
    timeout: int,
    max_repairs: int,
) -> dict[str, Any]:
    workdir = root / "repo"
    commit = clone_source(task["source"], task["base_ref"], workdir)
    parent = config["parent"]
    worker = config["worker"]
    parent_model = parent["model"]
    worker_model = worker["model"]
    parent_effort = actor_effort(parent, task["class"])
    worker_effort = actor_effort(worker, task["class"])
    usage_by_model: dict[tuple[str, str, str], dict[str, int]] = {}
    total_wall = 0.0
    diagnostic = ""

    plan_path = root / "parent-plan.txt"
    plan_prompt = (
        "You are the high-capability parent in the codex-flow workflow. Inspect the repository read-only. "
        "Do not modify files. Produce a compact implementation handoff containing root cause/design decision, "
        "scope and non-goals, relevant files, ordered steps, compatibility constraints, risks, acceptance criteria, "
        "and required validation. Remove ambiguity so a worker can implement without redesigning.\n\n"
        f"Task:\n{task['prompt']}"
    )
    codex_exit, usage, diagnostic, elapsed, plan = run_codex(
        workdir, parent_model, parent_effort, plan_prompt, timeout,
        sandbox="read-only", last_message_path=plan_path,
    )
    total_wall += elapsed
    add_model_usage(usage_by_model, "parent", parent_model, parent_effort, usage)
    if codex_exit != 0 or not plan.strip():
        if codex_exit == 0:
            codex_exit = 65
            diagnostic = "parent planning completed without a handoff"
        return build_row(
            task, config, repetition, commit, False, False, 0, 0, total_wall,
            codex_exit, "benchmark verification skipped because parent planning failed",
            diagnostic, usage_by_model,
        )

    worker_prompt = (
        "You are the implementation worker in the codex-flow workflow. Execute the parent's plan without redesigning it. "
        "Stay in scope, implement the complete change, run narrow relevant validation, and do not weaken or edit any external verifier.\n\n"
        f"Original task:\n{task['prompt']}\n\nParent handoff:\n{plan}"
    )
    codex_exit, usage, diagnostic, elapsed, _ = run_codex(
        workdir, worker_model, worker_effort, worker_prompt, timeout
    )
    total_wall += elapsed
    add_model_usage(usage_by_model, "worker", worker_model, worker_effort, usage)
    if codex_exit != 0:
        return build_row(
            task, config, repetition, commit, False, False, 0, 0, total_wall,
            codex_exit, "benchmark verification skipped because worker codex exec exited non-zero",
            diagnostic, usage_by_model,
        )

    review_schema_path = root / "review-schema.json"
    review_schema_path.write_text(json.dumps(REVIEW_SCHEMA))
    first_passed = False
    passed = False
    repair_cycles = 0
    review_cycles = 0
    verification = ""

    while True:
        verifier_passed, verification, verify_elapsed = run_verify(workdir, task["verify"], timeout)
        total_wall += verify_elapsed
        review_cycles += 1
        review_path = root / f"parent-review-{review_cycles}.json"
        review_prompt = (
            "You are the high-capability parent performing the codex-flow final review. Work read-only. "
            "Inspect the current git diff and directly affected call sites. Check the original task, architecture, "
            "compatibility, regression risk, and verifier result. Return verdict 'pass' only when the implementation "
            "is complete and the verifier passed. Otherwise return verdict 'repair' with a compact delta instruction "
            "for the worker; do not rewrite the whole plan.\n\n"
            f"Original task:\n{task['prompt']}\n\nVerifier passed: {str(verifier_passed).lower()}\n"
            f"Verifier output:\n{verification}"
        )
        codex_exit, usage, diagnostic, elapsed, review_message = run_codex(
            workdir, parent_model, parent_effort, review_prompt, timeout,
            sandbox="read-only", last_message_path=review_path,
            output_schema_path=review_schema_path,
        )
        total_wall += elapsed
        add_model_usage(usage_by_model, "parent", parent_model, parent_effort, usage)
        if codex_exit != 0:
            passed = False
            break
        try:
            verdict, feedback = parse_review(review_message)
        except ValueError as exc:
            codex_exit = 65
            diagnostic = str(exc)
            passed = False
            break
        passed = verifier_passed and verdict == "pass"
        if review_cycles == 1:
            first_passed = passed
        if passed or repair_cycles >= max_repairs:
            if not passed and feedback:
                verification = (
                    f"{verification}\nParent review requested repair:\n{feedback}"
                ).strip()
            break

        repair_cycles += 1
        if not verifier_passed:
            feedback = (
                f"{feedback}\n\nThe fixed external verifier still fails:\n{verification}"
            ).strip()
        repair_prompt = (
            "You are the implementation worker repairing a reviewed codex-flow change. Apply only the requested delta, "
            "keep the original acceptance criteria intact, and run narrow validation. Do not weaken or edit the verifier.\n\n"
            f"Original task:\n{task['prompt']}\n\nParent repair instruction:\n{feedback}"
        )
        codex_exit, usage, diagnostic, elapsed, _ = run_codex(
            workdir, worker_model, worker_effort, repair_prompt, timeout
        )
        total_wall += elapsed
        add_model_usage(usage_by_model, "worker", worker_model, worker_effort, usage)
        if codex_exit != 0:
            passed = False
            verification = "benchmark verification skipped because repair worker codex exec exited non-zero"
            break

    return build_row(
        task, config, repetition, commit, passed, first_passed, repair_cycles,
        review_cycles, total_wall, codex_exit, verification, diagnostic, usage_by_model,
    )


def execute_run(
    task: dict[str, Any],
    config: dict[str, Any],
    root: Path,
    repetition: int,
    timeout: int,
    max_repairs: int,
) -> dict[str, Any]:
    if config_strategy(config) == "flow":
        return execute_flow(task, config, root, repetition, timeout, max_repairs)
    return execute_direct(task, config, root, repetition, timeout, max_repairs)


def no_usage(row: dict[str, Any]) -> bool:
    return (
        row["input_tokens"] == 0
        and row["cached_input_tokens"] == 0
        and row["output_tokens"] == 0
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output")
    parser.add_argument("--only-task")
    parser.add_argument("--only-model")
    parser.add_argument("--only-strategy")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--fail-fast-infrastructure",
        action="store_true",
        help="stop the batch when codex exits non-zero before reporting any token usage",
    )
    args = parser.parse_args()

    if not shutil.which("git"):
        fail("git is required")
    if not args.dry_run and not shutil.which("codex"):
        fail("codex CLI is required")

    manifest = load_manifest(Path(args.manifest))
    tasks = [t for t in manifest["tasks"] if not args.only_task or t["id"] == args.only_task]
    matrix = [
        m for m in manifest["matrix"]
        if (not args.only_model or args.only_model in config_models(m))
        and (not args.only_strategy or args.only_strategy == config_id(m))
    ]
    if not tasks:
        fail("task filter matched nothing")
    if not matrix:
        fail("strategy/model filter matched nothing")

    planned = len(tasks) * len(matrix) * manifest.get("repetitions", 1)
    if args.dry_run:
        print(json.dumps({
            "planned_runs": planned,
            "tasks": [t["id"] for t in tasks],
            "strategies": [config_id(m) for m in matrix],
            "matrix": matrix,
        }, sort_keys=True))
        return 0

    if not args.output:
        fail("--output is required unless --dry-run is used")

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("a", encoding="utf-8") as sink:
        for task in tasks:
            for config in matrix:
                for repetition in range(1, manifest.get("repetitions", 1) + 1):
                    with tempfile.TemporaryDirectory(prefix="codex-flow-bench-") as tmp:
                        row = execute_run(
                            task, config, Path(tmp), repetition,
                            manifest.get("timeout_seconds", 1800),
                            task.get("max_repair_cycles", manifest.get("max_repair_cycles", 2)),
                        )
                    sink.write(json.dumps(row, sort_keys=True) + "\n")
                    sink.flush()
                    print(
                        f"{row['task_id']} {row['strategy_id']} "
                        f"rep={repetition} pass={row['passed']} first={row['first_passed']} "
                        f"repairs={row['repair_cycles']} reviews={row['review_cycles']} "
                        f"tokens={row['input_tokens'] + row['output_tokens']}",
                        file=sys.stderr,
                    )
                    if args.fail_fast_infrastructure and row["codex_exit_code"] != 0 and no_usage(row):
                        fail(
                            "codex exited non-zero without reporting usage; stopping benchmark "
                            f"after {row['task_id']} {row['strategy_id']} "
                            f"(exit={row['codex_exit_code']})"
                        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"benchmark runner failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
