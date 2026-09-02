"""Deterministic historical telemetry backfill and repair engine."""
from __future__ import annotations

import copy
from pathlib import Path
from typing import Any

from .app_server import enrich_run_metadata, extract_transcript_insights, quota_delta
from .common import LAST_FILE, atomic_json, iter_run_files, read_json_object


def _has_summary(val: Any) -> bool:
    if not isinstance(val, dict):
        return False
    return any(bool(v) for v in val.values())


def repair_run(
    run: dict[str, Any],
    *,
    report: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Repair a single telemetry run in-place by backfilling recoverable fields.

    Principles:
    1. Only fills missing fields, never overwrites existing valid data.
    2. Safe skips when transcript is missing or unreadable.
    3. Backfills quota delta only if both before and after snapshots exist.
    """
    if not isinstance(run, dict):
        return run

    before_summary = _has_summary(run.get("summary_info"))
    before_skills = bool(run.get("skills_used"))
    before_tools = bool(run.get("tools_used"))
    before_trajectory = bool(run.get("trajectory"))
    before_logs = bool(run.get("logs"))
    before_quota = bool(run.get("quota_change_during_run"))

    transcript_path = run.get("transcript_path")
    turn_id = run.get("turn_id")
    has_valid_transcript = (
        isinstance(transcript_path, str)
        and bool(transcript_path)
        and Path(transcript_path).is_file()
    )

    if has_valid_transcript:
        insights = extract_transcript_insights(transcript_path, turn_id)
        if isinstance(insights, dict):
            for key in ("skills_used", "tools_used", "trajectory", "logs"):
                if not run.get(key) and insights.get(key):
                    run[key] = insights[key]
            if not before_summary and _has_summary(insights.get("summary_info")):
                run["summary_info"] = insights["summary_info"]

    enrich_run_metadata(run)

    quota_change = run.get("quota_change_during_run")
    if not quota_change:
        before = run.get("quota_before")
        after = run.get("quota_after")
        if isinstance(before, list) and before and isinstance(after, list) and after:
            run["quota_change_during_run"] = quota_delta(before, after)

    if report is not None:
        report["task_summaries_restored"] = not before_summary and _has_summary(run.get("summary_info"))
        report["skills_tools_restored"] = (
            (not before_skills and bool(run.get("skills_used")))
            or (not before_tools and bool(run.get("tools_used")))
        )
        report["trajectories_restored"] = not before_trajectory and bool(run.get("trajectory"))
        report["logs_restored"] = not before_logs and bool(run.get("logs"))
        if not before_quota:
            report["quota_deltas_restored"] = bool(run.get("quota_change_during_run"))
            report["quota_deltas_impossible"] = not bool(run.get("quota_change_during_run"))
        else:
            report["quota_deltas_restored"] = False
            report["quota_deltas_impossible"] = False
        report["transcript_missing"] = not has_valid_transcript

    return run


def format_repair_summary(stats: dict[str, int]) -> str:
    val_width = max((len(str(v)) for v in stats.values()), default=1)
    val_width = max(val_width, 2)
    col_width = 25

    lines = [
        "Telemetry repair complete\n",
        f"{'scanned:':<{col_width}}{stats.get('scanned', 0):>{val_width}}",
        f"{'repaired:':<{col_width}}{stats.get('repaired', 0):>{val_width}}",
        f"{'unchanged:':<{col_width}}{stats.get('unchanged', 0):>{val_width}}",
        f"{'transcript missing:':<{col_width}}{stats.get('transcript_missing', 0):>{val_width}}",
        "",
        f"{'task summaries restored:':<{col_width}}{stats.get('task_summaries_restored', 0):>{val_width}}",
        f"{'skills/tools restored:':<{col_width}}{stats.get('skills_tools_restored', 0):>{val_width}}",
        f"{'trajectories restored:':<{col_width}}{stats.get('trajectories_restored', 0):>{val_width}}",
        f"{'logs restored:':<{col_width}}{stats.get('logs_restored', 0):>{val_width}}",
        f"{'quota deltas restored:':<{col_width}}{stats.get('quota_deltas_restored', 0):>{val_width}}",
        f"{'quota deltas impossible:':<{col_width}}{stats.get('quota_deltas_impossible', 0):>{val_width}}",
    ]
    return "\n".join(lines)


def repair_history(dry_run: bool = False, verbose: bool = True) -> dict[str, int]:
    """Scan and repair all historical run records deterministically."""
    stats = {
        "scanned": 0,
        "repaired": 0,
        "unchanged": 0,
        "transcript_missing": 0,
        "task_summaries_restored": 0,
        "skills_tools_restored": 0,
        "trajectories_restored": 0,
        "logs_restored": 0,
        "quota_deltas_restored": 0,
        "quota_deltas_impossible": 0,
    }

    last = read_json_object(LAST_FILE)

    for path in iter_run_files():
        run = read_json_object(path)
        if not isinstance(run, dict):
            continue

        stats["scanned"] += 1

        run_report: dict[str, Any] = {}
        original = copy.deepcopy(run)

        repair_run(run, report=run_report)

        changed = (run != original)

        if run_report.get("task_summaries_restored"):
            stats["task_summaries_restored"] += 1
        if run_report.get("skills_tools_restored"):
            stats["skills_tools_restored"] += 1
        if run_report.get("trajectories_restored"):
            stats["trajectories_restored"] += 1
        if run_report.get("logs_restored"):
            stats["logs_restored"] += 1
        if run_report.get("quota_deltas_restored"):
            stats["quota_deltas_restored"] += 1
        if run_report.get("quota_deltas_impossible"):
            stats["quota_deltas_impossible"] += 1

        if changed:
            stats["repaired"] += 1
            if not dry_run:
                atomic_json(path, run)
                if (
                    isinstance(last, dict)
                    and last.get("session_id") == run.get("session_id")
                    and last.get("turn_id") == run.get("turn_id")
                ):
                    atomic_json(LAST_FILE, run)
        else:
            if run_report.get("transcript_missing"):
                stats["transcript_missing"] += 1
            else:
                stats["unchanged"] += 1

    if verbose:
        print(format_repair_summary(stats))

    return stats
