#!/usr/bin/env python3
"""Deterministic codex-flow telemetry collector and CLI."""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from telemetry_core import *  # noqa: F401,F403
from telemetry_core import (
    AppServer,
    LAST_FILE,
    aggregate_usage_value,
    atomic_json,
    collect_hook,
    enrich_run_metadata,
    extract_transcript_insights,
    fmt_duration_ms,
    fmt_tokens,
    format_repair_summary,
    iter_run_files,
    numeric_ms,
    read_json_object,
    repair_history,
    repair_run,
    run_context,
    show_last,
    show_list,
    show_run,
    show_stats,
    telemetry_notifications_enabled,
    telemetry_retention_days,
)
import telemetry_core.collector as _collector
from localization import resolve_language, tr

LANG = resolve_language(Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "codex-flow.toml")


def T(en: str, zh: str) -> str:
    return tr(en, zh, lang=LANG)


def _same_run(left: dict | None, right: dict) -> bool:
    if not isinstance(left, dict):
        return False
    return (
        str(left.get("session_id") or "") == str(right.get("session_id") or "")
        and str(left.get("turn_id") or "") == str(right.get("turn_id") or "")
    )


def _persist_enriched_run(run: dict) -> None:
    """Make the persisted run self-contained before UI/CLI consumers reload it."""
    insights = extract_transcript_insights(run.get("transcript_path"), run.get("turn_id"))
    if insights:
        for key, value in insights.items():
            if value is not None and not run.get(key):
                run[key] = value
    enrich_run_metadata(run)

    atomic_json(LAST_FILE, run)
    for path in iter_run_files():
        candidate = read_json_object(path)
        if _same_run(candidate, run):
            atomic_json(path, run)
            break


def _localized_notification_body(run: dict) -> str:
    session, project, branch = run_context(run)
    label = project or session or T("Codex task", "Codex 任务")
    if branch and project:
        label = f"{label} · {branch}"
    workers = list((run.get("workers") or {}).values())
    parent = run.get("parent") or {}
    usages = [parent.get("usage_delta") if isinstance(parent, dict) else None]
    usages.extend(worker.get("usage") if isinstance(worker, dict) else None for worker in workers)
    total_tokens = aggregate_usage_value(usages, "total_tokens")
    worker_count = T(
        f"{len(workers)} worker{'s' if len(workers) != 1 else ''}",
        f"{len(workers)} 个子 Agent",
    )
    parts = [label, worker_count, f"{fmt_tokens(total_tokens)} tokens"]
    started = numeric_ms(run.get("started_at_ms"))
    finished = numeric_ms(run.get("finished_at_ms"))
    if started is not None and finished is not None:
        duration = fmt_duration_ms(finished - started)
        if duration:
            parts.append(duration)
    return " · ".join(parts)


def _notify_overlay_safely() -> None:
    """Push an update and wait for the daemon response before closing the socket."""
    codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    sock_path = os.path.join(codex_home, "codex-flow", "overlay.sock")
    if not os.path.exists(sock_path):
        return
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.75)
            client.connect(sock_path)
            client.sendall(b"update\n")
            try:
                client.recv(4096)
            except socket.timeout:
                pass
    except (OSError, TimeoutError):
        pass


def _localized_send_system_notification(run: dict) -> None:
    _persist_enriched_run(run)
    _notify_overlay_safely()
    telemetry_mod = sys.modules.get("telemetry")
    sub_mod = getattr(telemetry_mod, "subprocess", subprocess) if telemetry_mod else subprocess
    shutil_mod = getattr(telemetry_mod, "shutil", shutil) if telemetry_mod else shutil
    sys_mod = getattr(telemetry_mod, "sys", sys) if telemetry_mod else sys
    if not telemetry_notifications_enabled() or sys_mod.platform != "darwin":
        return
    executable = shutil_mod.which("osascript")
    if not executable:
        return
    title = T("FlowPilot task finished", "FlowPilot 任务已完成")
    script = (
        f"display notification {_collector.applescript_literal(_localized_notification_body(run))} "
        f"with title {_collector.applescript_literal(title)}"
    )
    try:
        sub_mod.run(
            [executable, "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=2.0,
            check=False,
        )
    except (OSError, Exception):
        return


# Quota snapshots are observational, but a transient app-server miss should not
# permanently erase the task delta. Retry only the read operation; never invent data.
_ORIGINAL_RATE_LIMITS = AppServer.rate_limits


def _rate_limits_with_retry(self: AppServer):
    last = None
    for attempt in range(3):
        last = _ORIGINAL_RATE_LIMITS(self)
        if isinstance(last, dict) and isinstance(last.get("rateLimits"), dict):
            return last
        if attempt < 2:
            time.sleep(0.08 * (attempt + 1))
    return last


AppServer.rate_limits = _rate_limits_with_retry
_collector.AppServer.rate_limits = _rate_limits_with_retry

# Enrich and persist before the Stop summary is rendered. This makes last.json
# and the per-run file authoritative for live view, restart, history, and CLI.
_ORIGINAL_RENDER_SUMMARY = _collector.render_summary


def _render_summary_with_enrichment(run: dict) -> str:
    _persist_enriched_run(run)
    return _ORIGINAL_RENDER_SUMMARY(run)


# collect_hook resolves these names from telemetry_core.collector at runtime.
_collector.render_summary = _render_summary_with_enrichment
_collector.notification_body = _localized_notification_body
_collector.send_system_notification = _localized_send_system_notification


def main() -> int:
    args = sys.argv[1:]
    if args:
        cmd = args[0]
        if cmd == "last":
            return show_last("--json" in args[1:])
        if cmd == "list":
            as_json = "--json" in args[1:]
            today = "--today" in args[1:]
            limit = 10
            project = None
            i = 1
            while i < len(args):
                if args[i] in ("-n", "--limit") and i + 1 < len(args):
                    try:
                        limit = int(args[i + 1])
                    except ValueError:
                        pass
                    i += 2
                elif args[i] in ("-p", "--project") and i + 1 < len(args):
                    project = args[i + 1]
                    i += 2
                else:
                    i += 1
            return show_list(limit=limit, project=project, today=today, as_json=as_json)
        if cmd == "show":
            as_json = "--json" in args[1:]
            target = "last"
            for a in args[1:]:
                if a != "--json":
                    target = a
                    break
            return show_run(target, as_json=as_json)
        if cmd in ("stats", "summary"):
            as_json = "--json" in args[1:]
            days = telemetry_retention_days()
            project = None
            i = 1
            while i < len(args):
                if args[i] in ("-d", "--days") and i + 1 < len(args):
                    try:
                        days = int(args[i + 1])
                    except ValueError:
                        pass
                    i += 2
                elif args[i] in ("-p", "--project") and i + 1 < len(args):
                    project = args[i + 1]
                    i += 2
                else:
                    i += 1
            return show_stats(project=project, days=days, as_json=as_json)
        if cmd == "repair":
            dry_run = "--dry-run" in args[1:]
            as_json = "--json" in args[1:]
            stats = repair_history(dry_run=dry_run, verbose=not as_json)
            if as_json:
                print(json.dumps(stats, indent=2))
            return 0
        if not cmd.startswith("-"):
            return show_run(cmd, as_json="--json" in args[1:])

    has_data = False
    if not sys.stdin.isatty():
        try:
            import select
            r, _, _ = select.select([sys.stdin], [], [], 0.0)
            has_data = bool(r)
        except Exception:
            has_data = False
    if not has_data:
        return show_last(as_json=False)
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0
    if isinstance(event, dict):
        try:
            collect_hook(event)
        except Exception:
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
