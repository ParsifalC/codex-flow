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
    format_latency_report,
    format_repair_summary,
    iter_run_files,
    latency_report,
    numeric_ms,
    read_json_object,
    record_latency_event,
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
from telemetry_core.latency import LatencyError
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


def _has_rate_limit_snapshot(value: object) -> bool:
    """Return whether a response contains either supported rate-limit shape."""
    if not isinstance(value, dict):
        return False
    if isinstance(value.get("rateLimits"), dict):
        return True
    by_id = value.get("rateLimitsByLimitId")
    return isinstance(by_id, dict) and isinstance(by_id.get("codex"), dict)


def _rate_limits_with_retry(self: AppServer):
    last = None
    for attempt in range(3):
        last = _ORIGINAL_RATE_LIMITS(self)
        if _has_rate_limit_snapshot(last):
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


def _latency_option(args: list[str], name: str) -> str | None:
    for index, value in enumerate(args):
        if value == name:
            if index + 1 >= len(args) or args[index + 1].startswith("-"):
                raise LatencyError(f"{name} requires a value")
            return args[index + 1]
    return None


def _latency_state_file(args: list[str]) -> str | None:
    return _latency_option(args, "--state-file")


def _validate_latency_options(action: str, args: list[str]) -> None:
    value_options = {"--state-file"}
    if action == "record":
        value_options.update({"--event-json", "--json"})
    flag_options = {"--json"} if action == "report" else set()
    positionals = 0
    seen: set[str] = set()
    index = 0
    while index < len(args):
        value = args[index]
        if value in value_options:
            if value in seen:
                raise LatencyError(f"{value} may be supplied only once")
            seen.add(value)
            if index + 1 >= len(args) or args[index + 1].startswith("-"):
                raise LatencyError(f"{value} requires a value")
            index += 2
            continue
        if value in flag_options:
            if value in seen:
                raise LatencyError(f"{value} may be supplied only once")
            seen.add(value)
            index += 1
            continue
        if value.startswith("-"):
            raise LatencyError(f"unknown latency option: {value}")
        if action != "record" or positionals:
            raise LatencyError(f"unexpected latency argument: {value}")
        positionals += 1
        index += 1


def _latency_record_args(args: list[str]) -> tuple[object, str | None]:
    state_file = _latency_state_file(args)
    raw = _latency_option(args, "--event-json")
    if raw is None:
        # `--json <object>` is accepted as a convenient shell spelling for
        # record; on report, --json remains the output-format flag.
        raw = _latency_option(args, "--json")
    if raw is None:
        positional = [
            value
            for index, value in enumerate(args)
            if value not in {"--event-json", "--json", "--state-file"}
            and (index == 0 or args[index - 1] not in {"--event-json", "--json", "--state-file"})
            and not value.startswith("-")
        ]
        raw = positional[0] if positional else None
    if raw is None and not sys.stdin.isatty():
        raw = sys.stdin.read()
    if not raw or not raw.strip():
        raise LatencyError("latency record requires --event-json or JSON on stdin")
    try:
        event = json.loads(raw)
    except json.JSONDecodeError:
        raise LatencyError("latency record event JSON is invalid") from None
    return event, state_file


def _latency_cli(args: list[str]) -> int:
    if len(args) < 2 or args[1] not in {"record", "report"}:
        print("usage: telemetry latency record|report [options]", file=sys.stderr)
        return 2
    action = args[1]
    options = args[2:]
    try:
        _validate_latency_options(action, options)
        state_file = _latency_state_file(options)
        if action == "record":
            event, state_file = _latency_record_args(options)
            result = record_latency_event(event, state_file=state_file)
            print(json.dumps(result, ensure_ascii=False, sort_keys=True))
            return 0
        result = latency_report(state_file=state_file)
        if "--json" in options:
            print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            print(format_latency_report(result))
        return 0
    except (LatencyError, OSError) as exc:
        print(f"telemetry latency: {exc}", file=sys.stderr)
        return 2


def main() -> int:
    args = sys.argv[1:]
    if args:
        cmd = args[0]
        if cmd == "latency":
            return _latency_cli(args)
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
