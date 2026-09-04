"""App-Server JSON-RPC communication, usage parsing, transcript extraction, and metadata enrichment."""

from __future__ import annotations

import json
import math
import os
import queue
import re
import shlex
import subprocess
import threading
import time
from pathlib import Path
from typing import Any

from .common import (
    SESSION_INDEX_FILE,
    TIMEOUT,
    text_value,
)


def session_index_metadata(session_id: Any) -> dict[str, Any] | None:
    """Read the local title index when app-server cannot materialize a thread."""
    if not session_id or not SESSION_INDEX_FILE.is_file():
        return None
    target = str(session_id)
    try:
        lines = SESSION_INDEX_FILE.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return None
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(entry, dict):
            continue
        entry_id = entry.get("id") or entry.get("session_id")
        if str(entry_id or "") != target:
            continue
        metadata: dict[str, Any] = {"id": entry_id}
        name = entry.get("thread_name") or entry.get("name")
        if name is not None:
            metadata["name"] = name
        preview = entry.get("preview")
        if preview is not None:
            metadata["preview"] = preview
        return metadata
    return None


def merge_thread_metadata(*values: Any) -> dict[str, Any] | None:
    result: dict[str, Any] = {}
    for value in values:
        if not isinstance(value, dict):
            continue
        for key, item in value.items():
            if item is not None and item != "":
                result[key] = item
    return result or None


def app_server_command() -> list[str]:
    override = os.environ.get("CODEX_FLOW_APP_SERVER_COMMAND")
    if override:
        return shlex.split(override)
    explicit = os.environ.get("CODEX_FLOW_CODEX_PATH")
    explicit_path = Path(explicit).expanduser() if explicit else None
    if explicit_path and os.access(explicit_path, os.X_OK):
        explicit_dir = str(explicit_path.parent)
        current_path = os.environ.get("PATH", "")
        os.environ["PATH"] = (
            explicit_dir
            if not current_path
            else os.pathsep.join((explicit_dir, current_path))
        )
        return [str(explicit_path), "app-server"]

    home = Path.home()
    codex_home = Path(os.environ.get("CODEX_HOME", home / ".codex")).expanduser()
    directories: list[Path] = []
    candidates: list[Path] = []

    def add_directory(path: Path) -> None:
        if path not in directories:
            directories.append(path)

    def add_candidate(path: Path) -> None:
        if path not in candidates:
            candidates.append(path)

    for raw in os.environ.get("PATH", "").split(os.pathsep):
        if raw:
            directory = Path(raw)
            add_directory(directory)
            add_candidate(directory / "codex")

    for directory in (
        home / ".local/bin",
        home / ".npm-global/bin",
        home / "Library/pnpm",
        home / ".volta/bin",
        home / ".bun/bin",
        codex_home / "bin",
        home / "Applications/ChatGPT.app/Contents/Resources",
        Path("/opt/homebrew/bin"),
        Path("/usr/local/bin"),
        Path("/Applications/ChatGPT.app/Contents/Resources"),
        Path("/usr/bin"),
        Path("/bin"),
    ):
        add_directory(directory)
        add_candidate(directory / "codex")

    nvm_roots = [
        Path(os.environ["NVM_DIR"]).expanduser() if os.environ.get("NVM_DIR") else None,
        home / ".nvm",
        home / ".config/nvm",
    ]
    for root in (path for path in nvm_roots if path is not None):
        for alias in ("current", "default"):
            directory = root / alias / "bin"
            add_directory(directory)
            add_candidate(directory / "codex")
        versions = root / "versions/node"
        try:
            entries = sorted(
                (path for path in versions.iterdir() if path.is_dir()),
                key=_nvm_version_sort_key,
                reverse=True,
            )
        except OSError:
            entries = []
        for version in entries:
            directory = version / "bin"
            add_directory(directory)
            add_candidate(directory / "codex")

    prefix = os.environ.get("npm_config_prefix") or os.environ.get("PREFIX")
    if prefix:
        directory = Path(prefix).expanduser() / "bin"
        add_directory(directory)
        add_candidate(directory / "codex")

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            if directories:
                os.environ["PATH"] = os.pathsep.join(str(path) for path in directories)
            return [str(candidate), "app-server"]

    # Keep an enriched PATH for launchd/Finder launches when no direct path was
    # found; shell sessions still use the normal codex lookup behavior.
    if directories:
        os.environ["PATH"] = os.pathsep.join(str(path) for path in directories)
    return ["codex", "app-server"]


def _nvm_version_sort_key(path: Path) -> tuple[tuple[int, ...], str]:
    """Order versioned nvm candidates numerically, with a stable name tie-break."""
    return tuple(int(part) for part in re.findall(r"\d+", path.name)), path.name


class AppServer:
    """Minimal stdio JSONL client for the Codex app-server."""

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

    def thread_metadata(self, thread_id: str | None) -> dict[str, Any] | None:
        """Read deterministic user-facing thread metadata without loading turns."""
        if not thread_id:
            return None
        response = self.request(
            "thread/read", {"threadId": thread_id, "includeTurns": False}
        )
        if not response:
            return None
        thread = response.get("thread")
        return thread if isinstance(thread, dict) else None


def quota_windows(snapshot: dict[str, Any] | None) -> list[dict[str, Any]]:
    """Return deterministic logical windows from current and legacy API views.

    Newer Codex responses expose ``rateLimitsByLimitId.codex`` while older
    responses put the same slots in ``rateLimits``. Codex fields win and each
    missing field is filled from the legacy slot. Duplicate logical rows are
    then collapsed by duration/reset while preserving same-reset rows whose
    durations differ.
    """
    if not isinstance(snapshot, dict):
        return []

    legacy = snapshot.get("rateLimits")
    if not isinstance(legacy, dict):
        legacy = {}
    by_id = snapshot.get("rateLimitsByLimitId")
    if not isinstance(by_id, dict):
        by_id = {}
    codex = by_id.get("codex")
    if not isinstance(codex, dict):
        codex = {}

    candidates: list[tuple[tuple[int, int], str, dict[str, Any]]] = []
    for slot_index, slot in enumerate(("primary", "secondary")):
        codex_window = codex.get(slot)
        legacy_window = legacy.get(slot)
        codex_window = codex_window if isinstance(codex_window, dict) else None
        legacy_window = legacy_window if isinstance(legacy_window, dict) else None
        if codex_window is None and legacy_window is None:
            continue

        duration = _first_quota_number(
            codex_window,
            legacy_window,
            ("windowDurationMins", "windowMinutes", "window_duration_mins"),
            integer=True,
        )
        reset = _first_quota_number(codex_window, legacy_window, ("resetsAt", "resets_at"))
        used = _first_quota_number(codex_window, legacy_window, ("usedPercent", "used_percent"))
        if duration is None and reset is None and used is None:
            continue
        normalized = {
            "slot": slot,
            "used_percent": used,
            "window_duration_mins": duration,
            "resets_at": reset,
        }
        candidates.append(
            ((0 if codex_window is not None else 1, slot_index), slot, normalized)
        )

    def logical_key(row: dict[str, Any], slot: str) -> tuple[Any, ...]:
        duration = row.get("window_duration_mins")
        reset = row.get("resets_at")
        if reset is not None:
            reset_key = reset / 1000.0 if reset > 1_000_000_000_000 else reset
            return (duration, reset_key)
        # Without a reset timestamp there is not enough information to know
        # whether two same-duration slots are duplicates. Keep their slot
        # identity (and, for malformed responses, the observed usage) so an
        # incomplete bucket cannot hide another incomplete bucket.
        return (duration, reset, slot, row.get("used_percent"))

    selected: dict[tuple[Any, ...], tuple[tuple[int, int], dict[str, Any]]] = {}
    for rank, slot, row in candidates:
        key = logical_key(row, slot)
        current = selected.get(key)
        if current is None or rank < current[0]:
            selected[key] = (rank, row)

    return [
        row
        for _, row in sorted(
            selected.values(),
            key=lambda item: (
                item[1].get("window_duration_mins")
                if isinstance(item[1].get("window_duration_mins"), (int, float))
                else float("inf"),
                item[1].get("resets_at") if item[1].get("resets_at") is not None else float("inf"),
                item[1].get("slot", ""),
            ),
        )
    ]


def _quota_number(value: Any, *, integer: bool = False) -> int | float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        if not math.isfinite(float(value)):
            return None
        return int(value) if integer else value
    if isinstance(value, str):
        try:
            parsed = float(value.strip())
        except ValueError:
            return None
        if not math.isfinite(parsed):
            return None
        return int(parsed) if integer else parsed
    return None


def _first_quota_number(
    primary: dict[str, Any] | None,
    fallback: dict[str, Any] | None,
    keys: tuple[str, ...],
    *,
    integer: bool = False,
) -> int | float | None:
    """Use the first valid value, allowing malformed codex fields to fall back."""
    for source in (primary, fallback):
        if not isinstance(source, dict):
            continue
        for key in keys:
            parsed = _quota_number(source.get(key), integer=integer)
            if parsed is not None:
                return parsed
    return None


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


def usage_delta(
    before: dict[str, Any] | None, after: dict[str, Any] | None
) -> dict[str, Any] | None:
    if not before or not after:
        return None
    numeric = [
        "input_tokens",
        "cached_input_tokens",
        "net_new_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "cache_write_input_tokens",
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


def normalize_transcript_usage(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    fields = (
        "input_tokens",
        "cached_input_tokens",
        "cache_write_input_tokens",
        "output_tokens",
        "reasoning_output_tokens",
        "total_tokens",
    )
    result: dict[str, Any] = {}
    for field in fields:
        raw = value.get(field)
        if isinstance(raw, (int, float)) and not isinstance(raw, bool):
            result[field] = int(raw)
    if not result:
        return None
    input_tokens = result.get("input_tokens")
    cached_tokens = result.get("cached_input_tokens")
    cache_write_tokens = result.get("cache_write_input_tokens", 0)
    if isinstance(input_tokens, int) and isinstance(cached_tokens, int):
        result["net_new_input_tokens"] = max(
            0, input_tokens - cached_tokens - cache_write_tokens
        )
    return result


def event_reasoning_effort(event: dict[str, Any] | None) -> str | None:
    if not isinstance(event, dict):
        return None
    for key in (
        "reasoning_effort",
        "reasoningEffort",
        "effort",
        "model_reasoning_effort",
    ):
        value = text_value(event.get(key))
        if value:
            return value
    for key in ("thread_settings", "threadSettings", "settings"):
        settings = event.get(key)
        if not isinstance(settings, dict):
            continue
        for setting_key in (
            "reasoning_effort",
            "reasoningEffort",
            "effort",
            "model_reasoning_effort",
        ):
            value = text_value(settings.get(setting_key))
            if value:
                return value
    return None


def transcript_turn_metadata(path_value: Any, turn_id: Any) -> dict[str, Any] | None:
    if not isinstance(path_value, str) or not path_value or not turn_id:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None

    target_turn = str(turn_id)
    result: dict[str, Any] = {}
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue

                record_type = record.get("type")
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue

                candidate: dict[str, Any] | None = None
                candidate_turn: Any = None
                if record_type == "turn_context":
                    candidate = payload
                    candidate_turn = payload.get("turn_id")
                elif record_type == "event_msg":
                    event_type = payload.get("type")
                    if event_type == "task_started":
                        candidate = payload
                        candidate_turn = payload.get("turn_id")
                    elif event_type == "thread_settings_applied":
                        candidate = payload.get("thread_settings")
                        candidate_turn = payload.get("turn_id")

                if candidate_turn is None or str(candidate_turn) != target_turn:
                    continue
                if not isinstance(candidate, dict):
                    continue
                model = text_value(candidate.get("model"))
                if model:
                    result["model"] = model
                effort = event_reasoning_effort(candidate)
                if effort:
                    result["reasoning_effort"] = effort
    except (OSError, UnicodeError):
        return None
    return result or None


def transcript_turn_usage(path_value: Any, turn_id: Any) -> dict[str, Any] | None:
    if not isinstance(path_value, str) or not path_value or not turn_id:
        return None
    path = Path(path_value)
    if not path.is_file():
        return None

    target_turn = str(turn_id)
    current_turn: str | None = None
    latest_total: dict[str, Any] | None = None
    before: dict[str, Any] | None = None
    after: dict[str, Any] | None = None
    target_seen = False
    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict) or record.get("type") != "event_msg":
                    continue
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue
                kind = payload.get("type")
                event_turn = payload.get("turn_id")
                if kind == "task_started":
                    current_turn = str(event_turn) if event_turn is not None else None
                    if current_turn == target_turn:
                        target_seen = True
                        before = dict(latest_total) if latest_total is not None else None
                    continue
                if kind == "token_count":
                    info = payload.get("info")
                    usage = normalize_transcript_usage(
                        info.get("total_token_usage") if isinstance(info, dict) else None
                    )
                    if usage is not None:
                        latest_total = usage
                        if current_turn == target_turn:
                            after = usage
                    continue
                if kind in {"task_complete", "turn_aborted"}:
                    completed_turn = (
                        str(event_turn) if event_turn is not None else current_turn
                    )
                    if completed_turn == current_turn:
                        current_turn = None
    except (OSError, UnicodeError):
        return None

    if not target_seen or after is None:
        return None
    if before is None:
        result = dict(after)
        result["groups"] = []
    else:
        result = usage_delta(before, after)
        if result is None:
            return None
    result["source"] = "transcript"
    return result


def merge_usage(
    transcript_usage: dict[str, Any] | None,
    service_usage: dict[str, Any] | None,
) -> dict[str, Any] | None:
    if transcript_usage is None:
        if service_usage is not None:
            service_usage = dict(service_usage)
            service_usage["source"] = "app-server"
        return service_usage
    result = dict(transcript_usage)
    if service_usage is not None:
        for key in ("estimated_credits_micros", "estimated_usd_micros"):
            value = service_usage.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                result[key] = int(value)
        groups = service_usage.get("groups")
        if isinstance(groups, list):
            result["groups"] = groups
        result["source"] = "transcript+app-server"
    return result


def usage_group_identities(usage: dict[str, Any] | None) -> list[tuple[str | None, str | None]]:
    if not isinstance(usage, dict):
        return []
    groups = usage.get("groups")
    if not isinstance(groups, list):
        return []
    identities: list[tuple[str | None, str | None]] = []
    for group in groups:
        if not isinstance(group, dict):
            continue
        model = text_value(group.get("model"))
        effort = text_value(group.get("reasoning_effort"))
        identity = (model, effort)
        if identity != (None, None) and identity not in identities:
            identities.append(identity)
    return identities


def apply_participant_metadata(
    participant: dict[str, Any],
    *,
    event: dict[str, Any] | None = None,
    transcript_path: Any = None,
    turn_id: Any = None,
    usage: dict[str, Any] | None = None,
) -> None:
    if event is not None:
        model = text_value(event.get("model"))
        if model and not text_value(participant.get("model")):
            participant["model"] = model
        effort = event_reasoning_effort(event)
        if effort and not text_value(participant.get("reasoning_effort")):
            participant["reasoning_effort"] = effort

    metadata = transcript_turn_metadata(transcript_path, turn_id)
    if metadata is not None:
        model = text_value(metadata.get("model"))
        if model and not text_value(participant.get("model")):
            participant["model"] = model
        effort = text_value(metadata.get("reasoning_effort"))
        if effort and not text_value(participant.get("reasoning_effort")):
            participant["reasoning_effort"] = effort

    identities = usage_group_identities(usage)
    if not text_value(participant.get("model")):
        models = {model for model, _ in identities if model}
        if len(models) == 1:
            participant["model"] = next(iter(models))
    if not text_value(participant.get("reasoning_effort")):
        efforts = {effort for _, effort in identities if effort}
        if len(efforts) == 1:
            participant["reasoning_effort"] = next(iter(efforts))


def extract_transcript_insights(
    transcript_path: Any, turn_id: Any = None
) -> dict[str, Any] | None:
    """Extract skills used, tools/MCP calls, trajectory steps, logs, and summary from a session transcript."""
    if not isinstance(transcript_path, str) or not transcript_path:
        return None
    path = Path(transcript_path)
    if not path.is_file():
        return None

    skills: dict[str, int] = {}
    tools: dict[str, dict[str, Any]] = {}
    trajectory: list[dict[str, Any]] = []
    logs: list[dict[str, Any]] = []
    goal: str | None = None
    conclusion: str | None = None

    try:
        with path.open("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if not isinstance(record, dict):
                    continue

                ts = record.get("timestamp")
                record_type = record.get("type")
                payload = record.get("payload")
                if not isinstance(payload, dict):
                    continue

                if record_type == "response_item":
                    p_type = payload.get("type")
                    if p_type == "custom_tool_call":
                        tool_name = str(payload.get("name") or "unknown")
                        raw_input = payload.get("input", "")
                        call_id = payload.get("call_id")
                        is_mcp = tool_name.startswith("mcp__") or "mcp" in tool_name.lower()

                        input_text = str(raw_input)
                        for skill in re.findall(r"skills/([a-zA-Z0-9_\-]+)", input_text):
                            skills[skill] = skills.get(skill, 0) + 1

                        if tool_name not in tools:
                            tools[tool_name] = {
                                "name": tool_name,
                                "count": 0,
                                "is_mcp": is_mcp,
                                "category": "mcp" if is_mcp else "system",
                            }
                        tools[tool_name]["count"] += 1

                        inp_summary = ""
                        if isinstance(raw_input, str):
                            m = re.search(r"\"cmd\"\s*:\s*\"([^\"]+)\"", raw_input)
                            if m:
                                inp_summary = m.group(1).strip()
                            else:
                                inp_summary = " ".join(raw_input.split()).strip()
                        elif isinstance(raw_input, dict):
                            inp_summary = json.dumps(raw_input, ensure_ascii=False)
                        if len(inp_summary) > 160:
                            inp_summary = inp_summary[:157] + "..."

                        clean_title = (
                            "MCP: " + tool_name.replace("mcp__", "")
                            if is_mcp
                            else "调用 " + tool_name
                        )
                        trajectory.append(
                            {
                                "type": "tool_call",
                                "name": tool_name,
                                "title": clean_title,
                                "detail": inp_summary,
                                "status": "completed",
                                "is_mcp": is_mcp,
                                "call_id": call_id,
                                "timestamp": ts,
                            }
                        )

                        logs.append(
                            {
                                "timestamp": ts,
                                "level": "info",
                                "type": "tool_call",
                                "message": f"[{tool_name}] {inp_summary}",
                            }
                        )
                    elif p_type == "message":
                        role = payload.get("role")
                        content = payload.get("content", [])
                        text_parts = []
                        for item in content:
                            if isinstance(item, dict):
                                text_parts.append(
                                    item.get("text") or item.get("output_text") or ""
                                )
                        msg_text = "".join(text_parts).strip()
                        if role == "user" and msg_text:
                            clean_prompt = msg_text
                            if "<USER_REQUEST>" in clean_prompt:
                                m = re.search(
                                    r"<USER_REQUEST>(.*?)</USER_REQUEST>",
                                    clean_prompt,
                                    re.DOTALL,
                                )
                                if m:
                                    clean_prompt = m.group(1).strip()
                            if "## My request:" in clean_prompt:
                                clean_prompt = clean_prompt.split("## My request:", 1)[1].strip()
                            if not clean_prompt.startswith("<") or not goal:
                                goal = clean_prompt
                        elif role == "assistant" and msg_text:
                            conclusion = msg_text
                elif (
                    record_type == "event_msg"
                    and payload.get("type") == "item_completed"
                ):
                    item = payload.get("item", {})
                    if isinstance(item, dict):
                        itype = item.get("type")
                        if itype == "CommandExecution":
                            exit_code = item.get("exit_code", 0)
                            stdout = str(item.get("stdout") or "")[:200].strip()
                            duration = item.get("duration")
                            dur_ms = None
                            if isinstance(duration, dict):
                                dur_ms = int(
                                    (duration.get("secs") or 0) * 1000
                                    + (duration.get("nanos") or 0) / 1_000_000
                                )
                            if trajectory and trajectory[-1]["type"] == "tool_call":
                                trajectory[-1]["status"] = (
                                    "completed" if exit_code == 0 else "error"
                                )
                                if dur_ms is not None:
                                    trajectory[-1]["duration_ms"] = dur_ms
                            if stdout:
                                logs.append(
                                    {
                                        "timestamp": ts,
                                        "level": "info" if exit_code == 0 else "error",
                                        "type": "command_output",
                                        "message": f"Exit {exit_code}: {stdout[:120]}",
                                    }
                                )
    except (OSError, UnicodeError):
        return None

    skills_list = [{"name": name, "count": count} for name, count in skills.items()]
    tools_list = list(tools.values())

    return {
        "skills_used": skills_list,
        "tools_used": tools_list,
        "trajectory": trajectory[-20:],
        "logs": logs[-30:],
        "summary_info": {
            "goal": goal[:300] if goal else None,
            "conclusion": conclusion[:500] if conclusion else None,
        },
    }


def enrich_run_metadata(run: dict[str, Any]) -> None:
    thread = merge_thread_metadata(
        session_index_metadata(run.get("session_id")), run.get("thread")
    )
    if thread is not None:
        run["thread"] = thread

    parent = run.get("parent")
    if isinstance(parent, dict):
        apply_participant_metadata(
            parent,
            transcript_path=run.get("transcript_path"),
            turn_id=run.get("turn_id"),
            usage=parent.get("usage_delta"),
        )
    workers = run.get("workers")
    if isinstance(workers, dict):
        for worker in workers.values():
            if not isinstance(worker, dict):
                continue
            apply_participant_metadata(
                worker,
                transcript_path=worker.get("transcript_path"),
                turn_id=worker.get("turn_id") or run.get("turn_id"),
                usage=worker.get("usage"),
            )

    # Extract skills, tools, trajectory, logs, summary if not already populated
    if "skills_used" not in run or "trajectory" not in run:
        insights = extract_transcript_insights(
            run.get("transcript_path"), run.get("turn_id")
        )
        if insights:
            for k, v in insights.items():
                if v is not None and (k not in run or not run[k]):
                    run[k] = v


def quota_delta(
    before: list[dict[str, Any]], after: list[dict[str, Any]]
) -> list[dict[str, Any]]:
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
