#!/usr/bin/env python3
"""Deterministic codex-flow telemetry collector.

Consumes Codex command-hook JSON on stdin. It never calls a model. Usage and
quota data are read from `codex app-server`; lifecycle data comes from hooks.
"""
from __future__ import annotations

import json
import os
import queue
import shlex
import subprocess
import sys
import tempfile
import threading
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_ROOT = CODEX_HOME / "codex-flow" / "telemetry"
RUNS_DIR = STATE_ROOT / "runs"
LAST_FILE = STATE_ROOT / "last.json"
TIMEOUT = float(os.environ.get("CODEX_FLOW_TELEMETRY_TIMEOUT", "3.0"))
LOCK_TIMEOUT = float(os.environ.get("CODEX_FLOW_TELEMETRY_LOCK_TIMEOUT", "2.0"))


def now_ms() -> int:
    return int(time.time() * 1000)


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


@contextmanager
def state_lock(key: str):
    STATE_ROOT.mkdir(parents=True, exist_ok=True)
    lock = STATE_ROOT / ("." + key.replace("/", "_") + ".lock")
    deadline = time.monotonic() + LOCK_TIMEOUT
    acquired = False
    while True:
        try:
            lock.mkdir()
            acquired = True
            break
        except FileExistsError:
            if time.monotonic() >= deadline:
                break
            time.sleep(0.025)
    try:
        # Callers must not enter a critical section unless this process owns
        # the lock.  A timeout is a normal fail-open outcome for telemetry,
        # not permission to proceed without serialization.
        yield acquired
    finally:
        if acquired:
            try:
                lock.rmdir()
            except OSError:
                pass


def run_key(event: dict[str, Any]) -> str:
    session = str(event.get("session_id") or "unknown")
    turn = str(event.get("turn_id") or "unknown")
    return f"{session}--{turn}".replace("/", "_")


def run_path(event: dict[str, Any]) -> Path:
    return RUNS_DIR / f"{run_key(event)}.json"


def load_run(event: dict[str, Any]) -> dict[str, Any]:
    path = run_path(event)
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            pass
    return {
        "schema_version": 1,
        "session_id": event.get("session_id"),
        "turn_id": event.get("turn_id"),
        "cwd": event.get("cwd"),
        "parent": {"model": event.get("model")},
        "workers": {},
        "started_at_ms": now_ms(),
    }


def app_server_command() -> list[str]:
    override = os.environ.get("CODEX_FLOW_APP_SERVER_COMMAND")
    if override:
        return shlex.split(override)
    return ["codex", "app-server"]


class AppServer:
    """Minimal stdio JSONL client for the Codex app-server.

    Codex intentionally omits the JSON-RPC `jsonrpc` header on the wire. A
    background reader thread is used instead of selectors so subprocess pipes
    work the same way on Unix and Windows.
    """

    def __init__(self) -> None:
        self.proc: subprocess.Popen[str] | None = None
        self.next_id = 1
        self.messages: queue.Queue[dict[str, Any] | None] = queue.Queue()
        self.reader: threading.Thread | None = None

    def __enter__(self) -> "AppServer":
        try:
            self.proc = subprocess.Popen(
                app_server_command(),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
            self.reader = threading.Thread(target=self._pump_stdout, daemon=True)
            self.reader.start()
            response = self.request(
                "initialize",
                {
                    "clientInfo": {
                        "name": "codex-flow",
                        "title": "FlowPilot telemetry",
                        "version": "1",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            )
            if response is None:
                self.close()
                return self
            self.notify("initialized")
        except (OSError, ValueError):
            self.close()
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    @property
    def available(self) -> bool:
        return (
            self.proc is not None
            and self.proc.poll() is None
            and self.proc.stdin is not None
            and self.proc.stdout is not None
        )

    def _pump_stdout(self) -> None:
        proc = self.proc
        if proc is None or proc.stdout is None:
            self.messages.put(None)
            return
        try:
            for line in proc.stdout:
                try:
                    message = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(message, dict):
                    self.messages.put(message)
        finally:
            self.messages.put(None)

    def close(self) -> None:
        proc = self.proc
        if proc is None:
            return
        try:
            proc.terminate()
            proc.wait(timeout=0.4)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        self.proc = None

    def _send(self, payload: dict[str, Any]) -> bool:
        if not self.available:
            return False
        try:
            assert self.proc is not None and self.proc.stdin is not None
            self.proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
            self.proc.stdin.flush()
            return True
        except (BrokenPipeError, OSError):
            return False

    def notify(self, method: str, params: Any | None = None) -> None:
        payload: dict[str, Any] = {"method": method}
        if params is not None:
            payload["params"] = params
        self._send(payload)

    def request(self, method: str, params: Any | None = None) -> dict[str, Any] | None:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        if not self._send(payload):
            return None
        return self._read_response(request_id)

    def _read_response(self, request_id: int) -> dict[str, Any] | None:
        deadline = time.monotonic() + TIMEOUT
        deferred: list[dict[str, Any]] = []
        try:
            while time.monotonic() < deadline:
                remaining = max(0.0, deadline - time.monotonic())
                try:
                    message = self.messages.get(timeout=remaining)
                except queue.Empty:
                    break
                if message is None:
                    break
                if message.get("id") != request_id:
                    deferred.append(message)
                    continue
                if "error" in message:
                    return None
                result = message.get("result")
                return result if isinstance(result, dict) else None
        finally:
            for message in deferred:
                self.messages.put(message)
        return None

    def rate_limits(self) -> dict[str, Any] | None:
        return self.request("account/rateLimits/read")

    def thread_usage(self, thread_id: str | None) -> dict[str, Any] | None:
        if not thread_id:
            return None
        response = self.request("account/usage/read", {"threadId": thread_id})
        if not response:
            return None
        usage = response.get("threadUsage")
        return usage if isinstance(usage, dict) else None


def quota_windows(snapshot: dict[str, Any] | None) -> list[dict[str, Any]]:
    if not snapshot:
        return []
    rate_limits = snapshot.get("rateLimits")
    if not isinstance(rate_limits, dict):
        return []
    result: list[dict[str, Any]] = []
    for slot in ("primary", "secondary"):
        window = rate_limits.get(slot)
        if not isinstance(window, dict):
            continue
        result.append(
            {
                "slot": slot,
                "used_percent": window.get("usedPercent"),
                "window_duration_mins": window.get("windowDurationMins"),
                "resets_at": window.get("resetsAt"),
            }
        )
    return result


def usage_summary(usage: dict[str, Any] | None) -> dict[str, Any] | None:
    if not usage:
        return None
    groups = usage.get("groups") if isinstance(usage.get("groups"), list) else []
    estimated_credits = usage.get("estimatedUsageCreditsMicros")
    totals: dict[str, Any] = {
        "input_tokens": 0,
        "cached_input_tokens": 0,
        "net_new_input_tokens": 0,
        "output_tokens": 0,
        "total_tokens": 0,
        "estimated_credits_micros": (
            int(estimated_credits)
            if isinstance(estimated_credits, (int, float))
            else None
        ),
        "estimated_usd_micros": usage.get("estimatedUsageUsdMicros"),
    }
    normalized_groups = []
    mapping = {
        "inputTokens": "input_tokens",
        "cachedInputTokens": "cached_input_tokens",
        "netNewInputTokens": "net_new_input_tokens",
        "outputTokens": "output_tokens",
        "totalTokens": "total_tokens",
    }
    for group in groups:
        if not isinstance(group, dict):
            continue
        normalized: dict[str, Any] = {
            "model": group.get("model"),
            "reasoning_effort": group.get("reasoningEffort"),
            "speed": group.get("speed"),
            "estimated_credits_micros": (
                int(group["estimatedUsageCreditsMicros"])
                if isinstance(group.get("estimatedUsageCreditsMicros"), (int, float))
                else None
            ),
        }
        for source, target in mapping.items():
            value = group.get(source)
            normalized[target] = int(value) if isinstance(value, (int, float)) else None
            if normalized[target] is not None:
                totals[target] += normalized[target]
        normalized_groups.append(normalized)
    totals["groups"] = normalized_groups
    return totals


def usage_delta(before: dict[str, Any] | None, after: dict[str, Any] | None) -> dict[str, Any] | None:
    if not before or not after:
        return None
    numeric = [
        "input_tokens",
        "cached_input_tokens",
        "net_new_input_tokens",
        "output_tokens",
        "total_tokens",
        "estimated_credits_micros",
    ]
    result: dict[str, Any] = {}
    for key in numeric:
        end = after.get(key)
        start = before.get(key)
        if isinstance(end, (int, float)) and isinstance(start, (int, float)):
            result[key] = max(0, int(end - start))
    usd_after = after.get("estimated_usd_micros")
    usd_before = before.get("estimated_usd_micros")
    if isinstance(usd_after, (int, float)) and isinstance(usd_before, (int, float)):
        result["estimated_usd_micros"] = max(0, int(usd_after - usd_before))
    # Group totals are cumulative too.  Only subtract groups whose complete
    # stable identity exists in both snapshots; newly appearing groups have
    # no defensible baseline and must not be attributed to this run.
    identity_fields = ("model", "reasoning_effort", "speed")
    group_numeric = (
        "input_tokens",
        "cached_input_tokens",
        "net_new_input_tokens",
        "output_tokens",
        "total_tokens",
        "estimated_credits_micros",
        "estimated_usd_micros",
    )

    def group_identity(group: Any) -> tuple[Any, ...] | None:
        if not isinstance(group, dict):
            return None
        identity = tuple(group.get(field) for field in identity_fields)
        if any(value is None for value in identity):
            return None
        return identity

    before_groups: dict[tuple[Any, ...], dict[str, Any]] = {}
    duplicate_before: set[tuple[Any, ...]] = set()
    before_group_values = before.get("groups")
    if not isinstance(before_group_values, list):
        before_group_values = []
    for group in before_group_values:
        identity = group_identity(group)
        if identity is None:
            continue
        if identity in before_groups:
            duplicate_before.add(identity)
        else:
            before_groups[identity] = group

    delta_groups: list[dict[str, Any]] = []
    after_group_values = after.get("groups")
    if not isinstance(after_group_values, list):
        after_group_values = []
    for group in after_group_values:
        identity = group_identity(group)
        if identity is None or identity in duplicate_before:
            continue
        old = before_groups.get(identity)
        if old is None:
            continue
        delta_group: dict[str, Any] = {
            field: group[field] for field in identity_fields
        }
        comparable = False
        for key in group_numeric:
            end = group.get(key)
            start = old.get(key)
            if isinstance(end, (int, float)) and isinstance(start, (int, float)):
                delta_group[key] = max(0, int(end - start))
                comparable = True
        if comparable:
            delta_groups.append(delta_group)
    result["groups"] = delta_groups
    return result


def quota_delta(before: list[dict[str, Any]], after: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_duration = {
        item.get("window_duration_mins"): item
        for item in before
        if item.get("window_duration_mins") is not None
    }
    result = []
    for item in after:
        old = by_duration.get(item.get("window_duration_mins"))
        delta = None
        if (
            old
            and isinstance(old.get("used_percent"), (int, float))
            and isinstance(item.get("used_percent"), (int, float))
        ):
            delta = item["used_percent"] - old["used_percent"]
        result.append({**item, "delta_percentage_points": delta})
    return result


def fmt_tokens(value: Any) -> str:
    if not isinstance(value, (int, float)):
        return "n/a"
    value = int(value)
    if value >= 1_000_000:
        return f"{value / 1_000_000:.2f}m"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return str(value)


def window_label(minutes: Any) -> str:
    if minutes == 300:
        return "5h"
    if minutes == 10080:
        return "7d"
    if isinstance(minutes, int) and minutes > 0:
        if minutes % 1440 == 0:
            return f"{minutes // 1440}d"
        return f"{minutes}m"
    return "quota"


def aggregate_usage_value(
    usages: list[dict[str, Any] | None], key: str
) -> int | None:
    """Return a complete participant aggregate, or None when any is unknown."""
    values: list[int] = []
    for usage in usages:
        if not isinstance(usage, dict):
            return None
        value = usage.get(key)
        if not isinstance(value, (int, float)):
            return None
        values.append(int(value))
    return sum(values) if values else None


def render_summary(run: dict[str, Any]) -> str:
    workers = list((run.get("workers") or {}).values())
    parent = run.get("parent") or {}
    parent_usage = parent.get("usage_delta") if isinstance(parent, dict) else None
    participant_usages = [parent_usage]
    participant_usages.extend(
        worker.get("usage") if isinstance(worker, dict) else None for worker in workers
    )

    p_count = f"1 parent + {len(workers)} worker{'s' if len(workers) != 1 else ''}"
    p_model = parent.get("model") or "unknown"
    p_tokens = f"{fmt_tokens(parent_usage.get('total_tokens') if isinstance(parent_usage, dict) else None)} tokens"

    total_tokens = aggregate_usage_value(participant_usages, "total_tokens")
    credits = aggregate_usage_value(participant_usages, "estimated_credits_micros")
    attr_tokens = f"{fmt_tokens(total_tokens)} tokens"
    attr_credits = f" · {credits / 1_000_000:.3f} credits" if credits is not None else ""

    def pad_line(content: str, width: int = 68) -> str:
        pad = max(0, width - len(content))
        return f"  │  {content}{' ' * pad} │"

    lines = ["", "📊 FlowPilot Telemetry Summary", ""]
    lines.append("  ╭─ Run Overview ────────────────────────────────────────────────────╮")
    lines.append(pad_line(f"• Participants:   {p_count}"))
    lines.append(pad_line(f"• Parent:         {p_model:<20} {p_tokens}"))
    for worker in workers:
        usage = worker.get("usage") or {}
        state = worker.get("status") or "observed"
        w_type = worker.get("agent_type") or "worker"
        w_model = worker.get("model") or "unknown"
        w_tokens = f"{fmt_tokens(usage.get('total_tokens'))} tokens ({state})"
        label = f"• Worker [{w_type}]:"
        lines.append(pad_line(f"{label:<18} {w_model:<20} {w_tokens}"))
    lines.append(pad_line(f"• Attributed:     {attr_tokens}{attr_credits}"))

    windows = run.get("quota_change_during_run") or []
    if windows:
        pieces = []
        for window in windows:
            before_match = next(
                (
                    item
                    for item in run.get("quota_before", [])
                    if item.get("window_duration_mins") == window.get("window_duration_mins")
                ),
                None,
            )
            old = before_match.get("used_percent") if before_match else None
            new = window.get("used_percent")
            delta = window.get("delta_percentage_points")
            if old is None or new is None:
                continue
            delta_text = "n/a" if delta is None else f"{delta:+g} pp"
            pieces.append(
                f"{window_label(window.get('window_duration_mins'))} "
                f"{old}% → {new}% ({delta_text})"
            )
        if pieces:
            lines.append("  ├─ Quota & Windows ─────────────────────────────────────────────────┤")
            lines.append(pad_line(f"• Account Quota:  {' | '.join(pieces)}"))
    lines.append("  ╰───────────────────────────────────────────────────────────────────╯")
    lines.append("  ℹ  Note: Quota delta is account-wide; attributed usage is thread-based.\n")
    return "\n".join(lines)


def write_stop_output(text: str) -> None:
    # Codex command hooks consume JSON on stdout.  Keep a deliberately named
    # plain-text escape hatch for shell tests; production hooks always use the
    # supported systemMessage field so Desktop/UI can surface the summary.
    if os.environ.get("CODEX_FLOW_TELEMETRY_TEST_PLAIN_OUTPUT") == "1":
        sys.stdout.write(text)
        return
    sys.stdout.write(
        json.dumps({"systemMessage": text}, ensure_ascii=False, separators=(",", ":"))
        + "\n"
    )


def collect_hook(event: dict[str, Any]) -> None:
    kind = event.get("hook_event_name")
    if kind not in {"UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop"}:
        return
    key = run_key(event)
    with state_lock(key) as acquired:
        if not acquired:
            return
        run = load_run(event)
        path = run_path(event)

        if kind == "UserPromptSubmit":
            run.update(
                {
                    "started_at_ms": now_ms(),
                    "cwd": event.get("cwd"),
                    "prompt_seen": True,
                }
            )
            run.setdefault("parent", {})["model"] = event.get("model")
            with AppServer() as server:
                run["quota_before"] = (
                    quota_windows(server.rate_limits()) if server.available else []
                )
                run["parent"]["usage_before"] = (
                    usage_summary(server.thread_usage(event.get("session_id")))
                    if server.available
                    else None
                )
            atomic_json(path, run)
            return

        if kind in {"SubagentStart", "SubagentStop"}:
            agent_id = str(event.get("agent_id") or "unknown")
            worker = run.setdefault("workers", {}).setdefault(
                agent_id, {"agent_id": agent_id}
            )
            worker.update(
                {
                    "agent_type": event.get("agent_type"),
                    "model": event.get("model"),
                }
            )
            if kind == "SubagentStart":
                worker.update({"started_at_ms": now_ms(), "status": "running"})
            else:
                worker.update({"finished_at_ms": now_ms(), "status": "completed"})
            atomic_json(path, run)
            return

        run["finished_at_ms"] = now_ms()
        run.setdefault("parent", {})["model"] = event.get("model")
        with AppServer() as server:
            quota_after = quota_windows(server.rate_limits()) if server.available else []
            parent_after = (
                usage_summary(server.thread_usage(event.get("session_id")))
                if server.available
                else None
            )
            run["quota_after"] = quota_after
            run["quota_change_during_run"] = quota_delta(
                run.get("quota_before", []), quota_after
            )
            run["parent"]["usage_after"] = parent_after
            run["parent"]["usage_delta"] = usage_delta(
                run["parent"].get("usage_before"), parent_after
            )
            for agent_id, worker in run.get("workers", {}).items():
                worker["usage"] = (
                    usage_summary(server.thread_usage(agent_id))
                    if server.available
                    else None
                )
                if worker.get("status") == "running":
                    # Some interrupted subagent paths can miss SubagentStop. Do
                    # not claim completion; retain that it participated.
                    worker["status"] = "observed"
        atomic_json(path, run)
        atomic_json(LAST_FILE, run)
        write_stop_output(render_summary(run))


def show_last(as_json: bool = False) -> int:
    if not LAST_FILE.exists():
        print("No FlowPilot telemetry run has completed yet.", file=sys.stderr)
        return 1
    try:
        run = json.loads(LAST_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"Unable to read telemetry: {exc}", file=sys.stderr)
        return 1
    if as_json:
        print(json.dumps(run, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(render_summary(run), end="")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "last":
        return show_last("--json" in sys.argv[2:])
    try:
        raw = sys.stdin.read()
        event = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0
    if isinstance(event, dict):
        try:
            collect_hook(event)
        except Exception:
            # Telemetry must never break or block a Codex turn.
            return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
