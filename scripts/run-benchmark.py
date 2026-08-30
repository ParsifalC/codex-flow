#!/usr/bin/env python3
"""Run reproducible Codex benchmark tasks and emit analyzer-compatible JSONL.

The runner intentionally records the requested model/effort rather than claiming
provider-reported model identity, because current `codex exec --json` does not
reliably expose that field. Token usage is summed from `turn.completed` events.
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
FULL_COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")
MAX_CAPTURE = 8000


def fail(message: str) -> None:
    raise ValueError(message)


def load_manifest(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text())
    if data.get("schema_version") != 1:
        fail("manifest schema_version must be 1")
    tasks = data.get("tasks")
    matrix = data.get("matrix")
    if not isinstance(tasks, list) or not tasks:
        fail("manifest tasks must be a non-empty array")
    if not isinstance(matrix, list) or not matrix:
        fail("manifest matrix must be a non-empty array")
    allow_floating = data.get("allow_floating_refs", False)
    if not isinstance(allow_floating, bool):
        fail("allow_floating_refs must be boolean")

    ids: set[str] = set()
    for task in tasks:
        required = {"id", "class", "source", "base_ref", "prompt", "verify"}
        missing = required - task.keys()
        if missing:
            fail(f"task missing fields: {sorted(missing)}")
        if task["id"] in ids:
            fail(f"duplicate task id: {task['id']}")
        ids.add(task["id"])
        if task["class"] not in VALID_CLASSES:
            fail(f"invalid task class for {task['id']}: {task['class']}")
        if not isinstance(task["verify"], list) or not task["verify"] or not all(isinstance(x, str) for x in task["verify"]):
            fail(f"verify for {task['id']} must be a non-empty argv array")
        if not isinstance(task["prompt"], str) or not task["prompt"].strip():
            fail(f"prompt for {task['id']} must be non-empty")
        if not isinstance(task["source"], str) or not task["source"].strip():
            fail(f"source for {task['id']} must be non-empty")
        if not isinstance(task["base_ref"], str) or not task["base_ref"].strip():
            fail(f"base_ref for {task['id']} must be non-empty")
        if not allow_floating and not FULL_COMMIT_RE.fullmatch(task["base_ref"]):
            fail(
                f"task {task['id']} base_ref must be a full 40-character commit SHA; "
                "set allow_floating_refs=true only for exploratory runs"
            )

    for config in matrix:
        if not isinstance(config.get("model"), str) or not config["model"]:
            fail("matrix model must be a non-empty string")
        if config.get("reasoning_effort") not in VALID_EFFORTS:
            fail(f"invalid reasoning effort: {config.get('reasoning_effort')}")

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


def run_codex(workdir: Path, model: str, effort: str, prompt: str, timeout: int) -> tuple[int, dict[str, int], str, float]:
    cmd = [
        "codex", "exec", "--ephemeral", "--json", "--ignore-user-config",
        "--sandbox", "workspace-write", "--model", model,
        "-c", f'model_reasoning_effort="{effort}"',
        "--cd", str(workdir), prompt,
    ]
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
        elapsed = time.monotonic() - started
        return proc.returncode, parse_usage(proc.stdout), (proc.stderr or proc.stdout)[-MAX_CAPTURE:], elapsed
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - started
        stdout = exc.stdout if isinstance(exc.stdout, str) else ""
        stderr = exc.stderr if isinstance(exc.stderr, str) else ""
        return 124, parse_usage(stdout), (stderr or stdout)[-MAX_CAPTURE:], elapsed


def run_verify(workdir: Path, argv: list[str], timeout: int) -> tuple[bool, str, float]:
    started = time.monotonic()
    try:
        proc = subprocess.run(argv, cwd=workdir, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return proc.returncode == 0, proc.stdout[-MAX_CAPTURE:], time.monotonic() - started
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout if isinstance(exc.stdout, str) else ""
        return False, (output + "\nverification timed out")[-MAX_CAPTURE:], time.monotonic() - started


def add_usage(total: dict[str, int], current: dict[str, int]) -> None:
    for key in total:
        total[key] += current[key]


def execute_run(task: dict[str, Any], config: dict[str, str], root: Path, repetition: int, timeout: int, max_repairs: int) -> dict[str, Any]:
    workdir = root / "repo"
    commit = clone_source(task["source"], task["base_ref"], workdir)
    total_usage = {"input_tokens": 0, "cached_input_tokens": 0, "output_tokens": 0}
    total_wall = 0.0

    codex_exit, usage, diagnostic, elapsed = run_codex(
        workdir, config["model"], config["reasoning_effort"], task["prompt"], timeout
    )
    total_wall += elapsed
    add_usage(total_usage, usage)
    repair_cycles = 0

    if codex_exit == 0:
        passed, verification, verify_elapsed = run_verify(workdir, task["verify"], timeout)
        total_wall += verify_elapsed
    else:
        passed = False
        verification = "benchmark verification skipped because codex exec exited non-zero"

    while not passed and codex_exit == 0 and repair_cycles < max_repairs:
        repair_cycles += 1
        repair_prompt = (
            "The previous implementation did not pass the fixed benchmark verifier. "
            "Repair only the implementation needed to satisfy the original task; do not weaken, skip, or edit the verifier.\n\n"
            f"Original task:\n{task['prompt']}\n\nVerifier output:\n{verification}"
        )
        codex_exit, usage, diagnostic, elapsed = run_codex(
            workdir, config["model"], config["reasoning_effort"], repair_prompt, timeout
        )
        total_wall += elapsed
        add_usage(total_usage, usage)
        if codex_exit != 0:
            passed = False
            verification = "benchmark verification skipped because repair codex exec exited non-zero"
            break
        passed, verification, verify_elapsed = run_verify(workdir, task["verify"], timeout)
        total_wall += verify_elapsed

    return {
        "schema_version": 1,
        "task_id": task["id"],
        "task_class": task["class"],
        "model": config["model"],
        "reasoning_effort": config["reasoning_effort"],
        "passed": passed,
        **total_usage,
        "repair_cycles": repair_cycles,
        "wall_time_seconds": round(total_wall, 3),
        "source_commit": commit,
        "repetition": repetition,
        "codex_exit_code": codex_exit,
        "verification_excerpt": verification[-2000:] if not passed else "",
        "diagnostic_excerpt": diagnostic[-2000:] if codex_exit != 0 else "",
    }


def no_usage(row: dict[str, Any]) -> bool:
    return (
        row["input_tokens"] == 0
        and row["cached_input_tokens"] == 0
        and row["output_tokens"] == 0
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--only-task")
    parser.add_argument("--only-model")
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
    matrix = [m for m in manifest["matrix"] if not args.only_model or m["model"] == args.only_model]
    if not tasks:
        fail("task filter matched nothing")
    if not matrix:
        fail("model filter matched nothing")

    planned = len(tasks) * len(matrix) * manifest.get("repetitions", 1)
    if args.dry_run:
        print(json.dumps({"planned_runs": planned, "tasks": [t["id"] for t in tasks], "matrix": matrix}, sort_keys=True))
        return 0

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
                        f"{row['task_id']} {row['model']}/{row['reasoning_effort']} "
                        f"rep={repetition} pass={row['passed']} repairs={row['repair_cycles']} "
                        f"tokens={row['input_tokens'] + row['output_tokens']}",
                        file=sys.stderr,
                    )
                    if args.fail_fast_infrastructure and row["codex_exit_code"] != 0 and no_usage(row):
                        fail(
                            "codex exited non-zero without reporting usage; stopping benchmark "
                            f"after {row['task_id']} {row['model']}/{row['reasoning_effort']} "
                            f"(exit={row['codex_exit_code']})"
                        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"benchmark runner failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
