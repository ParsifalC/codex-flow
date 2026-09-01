"""Telemetry query engines and CLI subcommands."""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any

from .app_server import enrich_run_metadata
from .common import (
    LAST_FILE,
    iter_run_files,
    now_ms,
    numeric_ms,
    read_json_object,
    telemetry_retention_days,
)
from .render import (
    render_project_stats,
    render_run_list,
    render_summary,
    run_context,
)


def list_runs(
    limit: int = 10,
    project: str | None = None,
    today: bool = False,
) -> list[dict[str, Any]]:
    runs: list[tuple[int, Path, dict[str, Any]]] = []
    today_cutoff = 0
    if today:
        now = time.localtime()
        today_midnight = time.mktime(
            (now.tm_year, now.tm_mon, now.tm_mday, 0, 0, 0, 0, 0, -1)
        )
        today_cutoff = int(today_midnight * 1000)

    for path in iter_run_files():
        run = read_json_object(path)
        if run is None:
            continue
        ts = numeric_ms(run.get("finished_at_ms")) or numeric_ms(
            run.get("started_at_ms")
        )
        if ts is None:
            try:
                ts = int(path.stat().st_mtime * 1000)
            except OSError:
                ts = 0
        if today and ts < today_cutoff:
            continue
        if project:
            _, run_proj, _ = run_context(run)
            cwd = str(run.get("cwd") or "")
            p_norm = project.lower()
            if not (
                (run_proj and p_norm in run_proj.lower())
                or p_norm in cwd.lower()
            ):
                continue
        runs.append((ts, path, run))

    runs.sort(key=lambda item: item[0], reverse=True)
    return [item[2] for item in runs[:limit]]


def resolve_run_target(
    target: str,
) -> tuple[dict[str, Any] | None, str | None]:
    t = target.strip()
    if not t or t == "last":
        if LAST_FILE.exists():
            last = read_json_object(LAST_FILE)
            if last is not None:
                return last, "last"
        runs = list_runs(limit=1)
        if runs:
            return runs[0], "#1"
        return None, "No FlowPilot telemetry runs recorded yet."

    num_str = t.lstrip("#")
    if num_str.isdigit():
        idx = int(num_str)
        if idx <= 0:
            return None, f"Invalid index '{target}'. Task index starts from 1."
        runs = list_runs(limit=max(idx, 1000))
        if idx <= len(runs):
            return runs[idx - 1], f"#{idx}"
        return None, f"Task index #{idx} out of range (found {len(runs)} runs)."

    matches: list[tuple[int, Path, dict[str, Any]]] = []
    t_lower = t.lower()
    for path in iter_run_files():
        stem_lower = path.stem.lower()
        if t_lower in stem_lower:
            run = read_json_object(path)
            if run is not None:
                ts = (
                    numeric_ms(run.get("finished_at_ms"))
                    or numeric_ms(run.get("started_at_ms"))
                    or 0
                )
                matches.append((ts, path, run))
                continue
        run = read_json_object(path)
        if run is not None:
            sess = str(run.get("session_id") or "").lower()
            turn = str(run.get("turn_id") or "").lower()
            if t_lower in sess or t_lower in turn:
                ts = (
                    numeric_ms(run.get("finished_at_ms"))
                    or numeric_ms(run.get("started_at_ms"))
                    or 0
                )
                matches.append((ts, path, run))

    if not matches:
        return None, f"No telemetry run found matching '{target}'."
    matches.sort(key=lambda item: item[0], reverse=True)
    return matches[0][2], matches[0][1].stem


def aggregate_project_stats(
    project: str | None = None,
    days: int = 30,
) -> dict[str, Any]:
    cutoff = now_ms() - days * 86_400_000

    total_runs = 0
    delegated_runs = 0
    direct_runs = 0
    total_duration_ms = 0

    total_tokens = 0
    parent_tokens = 0
    worker_tokens = 0

    cached_input_tokens = 0
    input_tokens = 0
    output_tokens = 0
    reasoning_output_tokens = 0

    total_credits_micros = 0
    has_credits = False

    models: dict[str, dict[str, Any]] = {}
    projects: dict[str, dict[str, Any]] = {}

    for path in iter_run_files():
        run = read_json_object(path)
        if run is None:
            continue
        ts = numeric_ms(run.get("finished_at_ms")) or numeric_ms(
            run.get("started_at_ms")
        )
        if ts is None:
            try:
                ts = int(path.stat().st_mtime * 1000)
            except OSError:
                ts = 0
        if ts < cutoff:
            continue

        _, proj_name, _ = run_context(run)
        if not proj_name and run.get("cwd"):
            try:
                proj_name = Path(str(run.get("cwd"))).name
            except Exception:
                proj_name = str(run.get("cwd"))
        proj_name = proj_name or "unknown"

        if project:
            p_norm = project.lower()
            cwd = str(run.get("cwd") or "")
            if not (p_norm in proj_name.lower() or p_norm in cwd.lower()):
                continue

        total_runs += 1
        workers = list((run.get("workers") or {}).values())
        if workers:
            delegated_runs += 1
        else:
            direct_runs += 1

        started_ms = numeric_ms(run.get("started_at_ms"))
        finished_ms = numeric_ms(run.get("finished_at_ms"))
        dur = (
            (finished_ms - started_ms)
            if (started_ms and finished_ms and finished_ms >= started_ms)
            else 0
        )
        total_duration_ms += dur

        parent = run.get("parent") or {}
        p_model = parent.get("model") or "unknown"
        p_usage = parent.get("usage_delta") if isinstance(parent, dict) else {}
        if not isinstance(p_usage, dict):
            p_usage = {}

        p_tot = p_usage.get("total_tokens") or 0
        p_in = p_usage.get("input_tokens") or 0
        p_cin = p_usage.get("cached_input_tokens") or 0
        p_out = p_usage.get("output_tokens") or 0
        p_rout = p_usage.get("reasoning_output_tokens") or 0
        p_cred = p_usage.get("estimated_credits_micros")

        parent_tokens += p_tot
        cached_input_tokens += p_cin
        input_tokens += p_in
        output_tokens += p_out
        reasoning_output_tokens += p_rout
        if isinstance(p_cred, (int, float)):
            total_credits_micros += int(p_cred)
            has_credits = True

        if p_model not in models:
            models[p_model] = {"calls": 0, "tokens": 0, "roles": set()}
        models[p_model]["calls"] += 1
        models[p_model]["tokens"] += p_tot
        models[p_model]["roles"].add("parent")

        w_tot_sum = 0
        for w in workers:
            w_model = w.get("model") or "unknown"
            w_usage = w.get("usage") if isinstance(w, dict) else {}
            if not isinstance(w_usage, dict):
                w_usage = {}
            w_tot = w_usage.get("total_tokens") or 0
            w_in = w_usage.get("input_tokens") or 0
            w_cin = w_usage.get("cached_input_tokens") or 0
            w_out = w_usage.get("output_tokens") or 0
            w_rout = w_usage.get("reasoning_output_tokens") or 0
            w_cred = w_usage.get("estimated_credits_micros")

            worker_tokens += w_tot
            w_tot_sum += w_tot
            cached_input_tokens += w_cin
            input_tokens += w_in
            output_tokens += w_out
            reasoning_output_tokens += w_rout
            if isinstance(w_cred, (int, float)):
                total_credits_micros += int(w_cred)
                has_credits = True

            if w_model not in models:
                models[w_model] = {"calls": 0, "tokens": 0, "roles": set()}
            models[w_model]["calls"] += 1
            models[w_model]["tokens"] += w_tot
            models[w_model]["roles"].add("worker")

        run_tot = p_tot + w_tot_sum
        total_tokens += run_tot

        if proj_name not in projects:
            projects[proj_name] = {
                "runs": 0,
                "delegated": 0,
                "tokens": 0,
                "duration_ms": 0,
            }
        projects[proj_name]["runs"] += 1
        if workers:
            projects[proj_name]["delegated"] += 1
        projects[proj_name]["tokens"] += run_tot
        projects[proj_name]["duration_ms"] += dur

    cache_ratio = (
        (cached_input_tokens / input_tokens * 100) if input_tokens > 0 else 0.0
    )
    worker_offload = (
        (worker_tokens / total_tokens * 100) if total_tokens > 0 else 0.0
    )

    serializable_models = {
        m: {
            "calls": info["calls"],
            "tokens": info["tokens"],
            "roles": sorted(info["roles"]),
        }
        for m, info in models.items()
    }

    return {
        "days": days,
        "project_filter": project,
        "total_runs": total_runs,
        "delegated_runs": delegated_runs,
        "direct_runs": direct_runs,
        "total_duration_ms": total_duration_ms,
        "total_tokens": total_tokens,
        "parent_tokens": parent_tokens,
        "worker_tokens": worker_tokens,
        "cached_input_tokens": cached_input_tokens,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "reasoning_output_tokens": reasoning_output_tokens,
        "cache_ratio": cache_ratio,
        "worker_offload_ratio": worker_offload,
        "estimated_credits_micros": (
            total_credits_micros if has_credits else None
        ),
        "models": serializable_models,
        "projects": projects,
    }


def show_last(as_json: bool = False) -> int:
    if not LAST_FILE.exists():
        print(
            "No FlowPilot telemetry run has completed yet.\n"
            "💡 Tip: Run `codex-flow doctor` to verify hooks, or approve pending hooks with `/hooks` in Codex.",
            file=sys.stderr,
        )
        return 1
    try:
        run = json.loads(LAST_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Unable to read telemetry: {exc}", file=sys.stderr)
        return 1
    enrich_run_metadata(run)
    if as_json:
        print(json.dumps(run, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_summary(run), end="")
    return 0


def show_list(
    limit: int = 10,
    project: str | None = None,
    today: bool = False,
    as_json: bool = False,
) -> int:
    runs = list_runs(limit=limit, project=project, today=today)
    if as_json:
        print(json.dumps(runs, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_run_list(runs, project=project, today=today), end="")
    return 0


def show_run(target: str, as_json: bool = False) -> int:
    run, ident = resolve_run_target(target)
    if run is None:
        print(f"❌ {ident}", file=sys.stderr)
        return 1
    enrich_run_metadata(run)
    if as_json:
        print(json.dumps(run, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_summary(run), end="")
    return 0


def show_stats(
    project: str | None = None,
    days: int = 30,
    as_json: bool = False,
) -> int:
    if days is None:
        days = telemetry_retention_days()
    stats = aggregate_project_stats(project=project, days=days)
    if as_json:
        print(json.dumps(stats, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_project_stats(stats), end="")
    return 0
