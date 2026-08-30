#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
from pathlib import Path

FIXED_DATE = "2026-01-01T00:00:00+00:00"


def load_json(path: Path):
    return json.loads(path.read_text())


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

    corpus = load_json(Path(args.corpus))
    profiles = load_json(Path(args.profiles))
    if corpus.get("schema_version") != 1 or profiles.get("schema_version") != 1:
        raise ValueError("unsupported corpus/profile schema")
    profile = profiles["profiles"][args.profile]

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
    Path(args.manifest).write_text(json.dumps(manifest, indent=2) + "\n")
    runs = len(manifest_tasks) * len(profile["matrix"]) * profile["repetitions"]
    print(json.dumps({
        "profile": args.profile,
        "tasks": len(manifest_tasks),
        "configurations": len(profile["matrix"]),
        "repetitions": profile["repetitions"],
        "planned_runs": runs,
        "manifest": str(Path(args.manifest).resolve()),
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
