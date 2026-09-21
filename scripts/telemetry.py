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
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from telemetry_core import *  # noqa: F401,F403
from telemetry_core import (
    AppServer,
    aggregate_usage_value,
    collect_hook,
    fmt_duration_ms,
    fmt_tokens,
    format_latency_report,
    latency_report,
    numeric_ms,
    record_latency_event,
    repair_history,
    run_context,
    show_last,
    show_list,
    show_run,
    show_stats,
    telemetry_notifications_enabled,
    telemetry_retention_days,
)
from telemetry_core.latency import LatencyError
from telemetry_core.common import telemetry_writes_enabled
from telemetry_core.turn_context import ReceiptError, write_goal, write_plan
from telemetry_core.publication import recover_last
import telemetry_core.collector as _collector
from localization import resolve_language, tr

LANG = resolve_language(Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "codex-flow.toml")


def T(en: str, zh: str) -> str:
    return tr(en, zh, lang=LANG)


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


def _notify_overlay_safely(run: dict | None = None, *, notify: bool = False) -> None:
    """Ask the overlay to refresh, or present a newly completed publication."""
    if not telemetry_writes_enabled():
        return
    codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
    sock_path = os.path.join(codex_home, "codex-flow", "overlay.sock")
    if not os.path.exists(sock_path):
        return
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.75)
            client.connect(sock_path)
            if notify and isinstance(run, dict):
                session = run.get("session_id")
                turn = run.get("turn_id")
                if isinstance(session, str) and session and isinstance(turn, str) and turn:
                    run_path = run_path_for_key(run_key(run)).resolve()
                    command = f"update {run_path}"
                else:
                    command = "update"
            else:
                command = "refresh"
            client.sendall(command.encode() + b"\n")
            try:
                client.recv(4096)
            except socket.timeout:
                pass
    except (OSError, TimeoutError):
        pass


def _localized_send_system_notification(run: dict) -> None:
    if not telemetry_writes_enabled():
        return
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

# collect_hook resolves these names from telemetry_core.collector at runtime.
_collector.notification_body = _localized_notification_body
_collector.send_system_notification = _localized_send_system_notification
_collector.notify_overlay_if_active = lambda run, *, notify=False: _notify_overlay_safely(run, notify=notify)


def _context_cli(args: list[str]) -> int:
    """Accept explicit receipt identity and UTF-8 input; never infer a turn."""
    if args[1:] in (["--help"], ["-h"]):
        print("Usage: codex-flow telemetry context <command>\n\n"
              "  write-goal --receipt-file PATH (--stdin | --text-file PATH)\n"
              "  write-plan --receipt-file PATH --plan-file PATH "
              "--origin compiled|reused|replanned\n"
              "  enable-desktop-transport (legacy compatibility diagnostic)\n\n"
              "Use an explicit host receipt. --stdin reads UTF-8 without an intermediate goal file.")
        return 0
    if not telemetry_writes_enabled():
        print(json.dumps({"ok": False, "status": "disabled", "reason": "telemetry_disabled"}))
        return 0
    try:
        if args[1:] == ["enable-desktop-transport"]:
            from telemetry_core.host_transport import enable_desktop_transport
            print(json.dumps(enable_desktop_transport(), sort_keys=True))
            return 0
        if len(args) < 2 or args[1] not in {"write-goal", "write-plan"}:
            raise ReceiptError("invalid_arguments")
        action = args[1]
        required = {"--receipt-file"} if action == "write-goal" else {
            "--receipt-file", "--plan-file", "--origin",
        }
        allowed = required | {"--text-file", "--stdin"} if action == "write-goal" else required
        values: dict[str, str] = {}
        index = 2
        while index < len(args):
            option = args[index]
            if option == "--stdin" and action == "write-goal" and option not in values:
                values[option] = "true"
                index += 1
                continue
            if (option not in allowed or option in values or index + 1 >= len(args)
                    or args[index + 1].startswith("--") or not args[index + 1]):
                raise ReceiptError("invalid_arguments")
            values[option] = args[index + 1]
            index += 2
        inputs = set(values) & {"--stdin", "--text-file"}
        if not required <= set(values) or (action == "write-goal" and len(inputs) != 1):
            raise ReceiptError("invalid_arguments")
        if action == "write-goal":
            if "--stdin" in values:
                try:
                    text = sys.stdin.buffer.read().decode("utf-8")
                except UnicodeError:
                    raise ReceiptError("invalid_utf8") from None
                result = write_goal(receipt_file=Path(values["--receipt-file"]), text=text)
            else:
                result = write_goal(receipt_file=Path(values["--receipt-file"]), text_file=Path(values["--text-file"]))
        else:
            result = write_plan(
                receipt_file=Path(values["--receipt-file"]), plan_file=Path(values["--plan-file"]),
                origin=values["--origin"],
            )
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except (ReceiptError, OSError) as exc:
        print(json.dumps({"ok": False, "error": exc.code if isinstance(exc, ReceiptError) else "file_write_error"}), file=sys.stderr)
        return 2


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
            if not telemetry_writes_enabled():
                print(json.dumps({"status": "disabled"}))
                return 0
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


def _check_auto_ack_restart_on_hook() -> None:
    try:
        import updater
        state = updater.load_state()
        if not state.restart_required:
            return
        parent_pid = os.getppid()
        if state.pending_codex_pids:
            if parent_pid not in state.pending_codex_pids:
                state.restart_required = False
                state.pending_codex_pids = []
                state.restart_reason = None
                updater.save_state(state)
    except Exception:
        pass


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "recover-last":
        publication = recover_last()
        if publication.last_updated and "--quiet" not in args[1:]:
            _notify_overlay_safely(notify=False)
        print(json.dumps(asdict(publication), ensure_ascii=False, sort_keys=True))
        return 0
    if args:
        cmd = args[0]
        if cmd == "context":
            return _context_cli(args)
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
            if not dry_run and not telemetry_writes_enabled():
                print(json.dumps({"status": "disabled"}) if as_json else T(
                    "Telemetry is disabled; no files changed.", "遥测已关闭，未修改文件。",
                ))
                return 0
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
    if isinstance(event, dict) and telemetry_writes_enabled():
        try:
            collect_hook(event)
            from telemetry_core.host_transport import hook_context
            context = hook_context(event)
            if context is not None:
                print(json.dumps(context, ensure_ascii=False))
            _check_auto_ack_restart_on_hook()
        except Exception:
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
