#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path, PurePosixPath

FIXED_DATE = "2026-01-01T00:00:00+00:00"
VALID_CLASSES = {"routine", "complex", "critical"}
VALID_EFFORTS = {"high", "xhigh", "max"}


def load_json(path: Path):
    return json.loads(path.read_text())


def validate_relative_path(value: str) -> None:
    p = PurePosixPath(value)
    if not value or p.is_absolute() or ".." in p.parts or value.endswith("/"):
        raise ValueError(f"unsafe corpus file path: {value!r}")


def validate(corpus: dict, profiles: dict, profile_name: str) -> dict:
    if corpus.get("schema_version") != 1 or profiles.get("schema_version") != 1:
        raise ValueError("unsupported corpus/profile schema")
    tasks = corpus.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ValueError("corpus tasks must be a non-empty array")
    seen: set[str] = set()
    for task in tasks:
        task_id = task.get("id")
        if not isinstance(task_id, str) or not task_id:
            raise ValueError("task id must be a non-empty string")
        if task_id in seen:
            raise ValueError(f"duplicate task id: {task_id}")
        seen.add(task_id)
        if task.get("class") not in VALID_CLASSES:
            raise ValueError(f"invalid task class for {task_id}: {task.get('class')}")
        if not isinstance(task.get("prompt"), str) or not task["prompt"].strip():
            raise ValueError(f"empty prompt for {task_id}")
        if not isinstance(task.get("verifier"), str) or not task["verifier"].strip():
            raise ValueError(f"empty verifier for {task_id}")
        files = task.get("files")
        if not isinstance(files, dict) or not files:
            raise ValueError(f"task {task_id} must contain seed files")
        for rel, content in files.items():
            if not isinstance(rel, str) or not isinstance(content, str):
                raise ValueError(f"task {task_id} files must map string paths to string contents")
            validate_relative_path(rel)

    profile = profiles.get("profiles", {}).get(profile_name)
    if not isinstance(profile, dict):
        raise ValueError(f"missing profile: {profile_name}")
    repetitions = profile.get("repetitions")
    matrix = profile.get("matrix")
    if not isinstance(repetitions, int) or repetitions < 1:
        raise ValueError(f"profile {profile_name} repetitions must be >= 1")
    if not isinstance(matrix, list) or not matrix:
        raise ValueError(f"profile {profile_name} matrix must be non-empty")
    seen_configs: set[tuple[str, str]] = set()
    for config in matrix:
        model = config.get("model")
        effort = config.get("reasoning_effort")
        if not isinstance(model, str) or not model:
            raise ValueError(f"profile {profile_name} contains an empty model")
        if effort not in VALID_EFFORTS:
            raise ValueError(f"profile {profile_name} has invalid reasoning effort: {effort}")
        key = (model, effort)
        if key in seen_configs:
            raise ValueError(f"profile {profile_name} has duplicate configuration: {model}/{effort}")
        seen_configs.add(key)
    return profile


def write_files(root: Path, files: dict[str, str]) -> None:
    for rel, content in files.items():
        target = root / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)


def init_repo(repo: Path) -> str:
    subprocess.run(["git", "init", "-q", str(repo)], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "codex-flow benchmark"], check=True)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "benchmark@codex-flow.invalid"], check=True)
    subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
    env = os.environ.copy()
    env.update({"GIT_AUTHOR_DATE": FIXED_DATE, "GIT_COMMITTER_DATE": FIXED_DATE})
    subprocess.run(["git", "-C", str(repo), "commit", "-qm", "benchmark seed"], check=True, env=env)
    return subprocess.check_output(["git", "-C", str(repo), "rev-parse", "HEAD"], text=True).strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--corpus", default="benchmark/corpus.json")
    ap.add_argument("--profiles", default="benchmark/profiles.json")
    ap.add_argument("--profile", choices=["quick", "full"], default="quick")
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--timeout-seconds", type=int, default=900)
    ap.add_argument("--max-repair-cycles", type=int, default=2)
    args = ap.parse_args()
    if args.timeout_seconds < 1:
        raise ValueError("timeout-seconds must be >= 1")
    if args.max_repair_cycles < 0:
        raise ValueError("max-repair-cycles must be >= 0")

    corpus = load_json(Path(args.corpus))
    profiles = load_json(Path(args.profiles))
    profile = validate(corpus, profiles, args.profile)

    out = Path(args.output_dir).resolve()
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    manifest_tasks = []
    for task in corpus["tasks"]:
        task_root = out / task["id"]
        repo = task_root / "repo"
        verifier = task_root / "verify.py"
        repo.mkdir(parents=True)
        write_files(repo, task["files"])
        verifier.write_text(task["verifier"])
        commit = init_repo(repo)
        manifest_tasks.append({
            "id": task["id"],
            "class": task["class"],
            "source": str(repo),
            "base_ref": commit,
            "prompt": task["prompt"],
            "verify": ["python3", str(verifier)],
        })

    manifest = {
        "schema_version": 1,
        "repetitions": profile["repetitions"],
        "timeout_seconds": args.timeout_seconds,
        "max_repair_cycles": args.max_repair_cycles,
        "matrix": profile["matrix"],
        "tasks": manifest_tasks,
    }
    manifest_path = Path(args.manifest).resolve()
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    runs = len(manifest_tasks) * len(profile["matrix"]) * profile["repetitions"]
    print(json.dumps({
        "profile": args.profile,
        "tasks": len(manifest_tasks),
        "configurations": len(profile["matrix"]),
        "repetitions": profile["repetitions"],
        "planned_runs": runs,
        "manifest": str(manifest_path),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
