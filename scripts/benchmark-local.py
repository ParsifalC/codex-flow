#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PRICE = ROOT / "benchmark/prices/gpt-5.6-2026-08-30.json"


def run(cmd: list[str], *, check: bool = True, capture: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        check=check,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def require(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise RuntimeError(f"{name} is required")
    return path


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Run the built-in codex-flow benchmark using the local Codex login session."
    )
    ap.add_argument("profile", nargs="?", choices=["quick", "full"], default="quick")
    ap.add_argument("--workspace", default=".codex-flow-benchmark")
    ap.add_argument("--output")
    ap.add_argument("--prices", default=str(DEFAULT_PRICE))
    ap.add_argument("--yes", action="store_true", help="skip the paid-run confirmation prompt")
    args = ap.parse_args()

    require("git")
    codex = require("codex")
    require("python3")

    version = run([codex, "--version"], capture=True).stdout.strip()

    workspace = Path(args.workspace).resolve()
    manifest = workspace / "manifest.json"
    results_dir = ROOT / "benchmark/results"
    results_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = Path(args.output).resolve() if args.output else (results_dir / f"{args.profile}-{stamp}.jsonl")

    materialize = run([
        sys.executable,
        str(ROOT / "scripts/materialize-corpus.py"),
        "--profile", args.profile,
        "--output-dir", str(workspace / "corpus"),
        "--manifest", str(manifest),
    ], capture=True)
    plan_meta = json.loads(materialize.stdout)

    dry = run([
        sys.executable,
        str(ROOT / "scripts/run-benchmark.py"),
        "--manifest", str(manifest),
        "--output", str(output),
        "--dry-run",
    ], capture=True)
    plan = json.loads(dry.stdout)
    planned = int(plan["planned_runs"])

    disp_output = str(output)
    home_str = str(Path.home())
    if disp_output.startswith(home_str):
        disp_output = "~" + disp_output[len(home_str):]

    budget = "~15M tokens (planning + repairs may increase)" if args.profile == "quick" else "high (90 runs, substantial Codex quota)"

    def pad_line(content: str, width: int = 68) -> str:
        pad = max(0, width - len(content))
        return f"  │  {content}{' ' * pad} │"

    print(f"\n⚡ codex-flow benchmark-local\n")
    print("  ╭─ Benchmark Plan ──────────────────────────────────────────────────╮")
    print(pad_line(f"• Profile:       {args.profile} ({planned} real model runs)"))
    print(pad_line(f"• Codex CLI:     {version} (local auth session)"))
    print(pad_line(f"• Est. Budget:   {budget}"))
    print(pad_line(f"• Output File:   {disp_output}"))
    print("  ╰───────────────────────────────────────────────────────────────────╯\n")

    print("┌─ ⚠️  REAL MODEL EXECUTION CONFIRMATION ────────────────────────────┐")
    print("│  This will execute tasks using your authenticated Codex account    │")
    print("│  and will consume real quota/credits.                              │")
    print("└───────────────────────────────────────────────────────────────────┘\n")

    if not args.yes:
        expected = f"RUN {args.profile.upper()} {planned}"
        typed = input(f"Type '{expected}' to proceed: ").strip()
        if typed != expected:
            print("Cancelled; no model run was started.")
            return 2

    output.parent.mkdir(parents=True, exist_ok=True)
    run([
        sys.executable,
        str(ROOT / "scripts/run-benchmark.py"),
        "--manifest", str(manifest),
        "--output", str(output),
        "--fail-fast-infrastructure",
    ])

    analysis = output.with_suffix(".analysis.json")
    report = output.with_suffix(".report.md")
    with analysis.open("w", encoding="utf-8") as fh:
        proc = subprocess.run([
            sys.executable,
            str(ROOT / "scripts/analyze-benchmark.py"),
            "--results", str(output),
            "--prices", str(Path(args.prices).resolve()),
            "--json",
        ], check=True, text=True, stdout=fh)

    run([
        sys.executable,
        str(ROOT / "scripts/render-benchmark-report.py"),
        "--results", str(output),
        "--prices", str(Path(args.prices).resolve()),
        "--analysis", str(analysis),
        "--output", str(report),
        "--title", f"Codex {args.profile} local benchmark",
    ])

    meta = output.with_suffix(".meta.json")
    meta.write_text(json.dumps({
        "schema_version": 2,
        "profile": args.profile,
        "planned_runs": planned,
        "codex_cli_version": version,
        "codex_flow_commit": subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip(),
        "authentication_mode": "local-codex-session",
        "cost_semantics": "API-equivalent reference cost only; not the user's ChatGPT subscription charge",
        "manifest": str(manifest),
        "results": str(output),
        "analysis": str(analysis),
        "report": str(report),
        "materialization": plan_meta,
    }, indent=2) + "\n")

    print("\nBenchmark complete.")
    print(f"Results:  {output}")
    print(f"Analysis: {analysis}")
    print(f"Report:   {report}")
    print(f"Metadata: {meta}")
    print("Dollar values in the report are API-equivalent reference costs, not actual ChatGPT subscription charges.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nCancelled.", file=sys.stderr)
        raise SystemExit(130)
    except Exception as exc:
        print(f"local benchmark failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
