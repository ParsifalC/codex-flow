#!/usr/bin/env python3
"""Install/remove FlowPilot lifecycle hooks and inspect Codex hook trust state.

Trust detection intentionally mirrors Codex's current hook identity rules:
- one persisted state key per event/group/handler
- normalized command-hook config before hashing
- canonical JSON + SHA-256 with the ``sha256:`` prefix

The detector is read-only. It never grants trust on the user's behalf.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any

EVENTS = ("UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop")
MARKER = "codex-flow/telemetry.py"
DEFAULT_TIMEOUT_SEC = 600
SESSION_END_DEFAULT_TIMEOUT_SEC = 1
SESSION_END_MAX_TIMEOUT_SEC = 3
DEFAULT_ADDITIONAL_CONTEXT_LIMIT = 2500
ADDITIONAL_CONTEXT_EVENTS = {
    "PreToolUse",
    "PostToolUse",
    "SessionStart",
    "UserPromptSubmit",
    "SubagentStart",
}
EVENT_KEY_LABELS = {
    "PreToolUse": "pre_tool_use",
    "PermissionRequest": "permission_request",
    "PostToolUse": "post_tool_use",
    "PreCompact": "pre_compact",
    "PostCompact": "post_compact",
    "SessionStart": "session_start",
    "SessionEnd": "session_end",
    "UserPromptSubmit": "user_prompt_submit",
    "SubagentStart": "subagent_start",
    "SubagentStop": "subagent_stop",
    "Stop": "stop",
    "Interrupt": "interrupt",
}


def load(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"hooks": {}}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"invalid hooks JSON in {path}: {exc}")
    if not isinstance(value, dict):
        raise SystemExit(f"invalid hooks JSON in {path}: root must be an object")
    value.setdefault("hooks", {})
    if not isinstance(value["hooks"], dict):
        raise SystemExit(f"invalid hooks JSON in {path}: hooks must be an object")
    return value


def is_managed_hook(hook: Any) -> bool:
    if not isinstance(hook, dict):
        return False
    command = hook.get("command")
    return isinstance(command, str) and MARKER in command.replace("\\", "/")


def is_managed_entry(entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    hooks = entry.get("hooks", [])
    return isinstance(hooks, list) and any(is_managed_hook(hook) for hook in hooks)


def remove_managed(data: dict[str, Any]) -> None:
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return
    for event in list(hooks):
        entries = hooks[event]
        if not isinstance(entries, list):
            continue
        kept = []
        for entry in entries:
            # Keep malformed entries and entries with malformed `hooks` values
            # unchanged; only a valid hook list is safe to filter.
            if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
                kept.append(entry)
                continue

            entry_hooks = entry["hooks"]
            filtered_hooks = [hook for hook in entry_hooks if not is_managed_hook(hook)]
            if len(filtered_hooks) == len(entry_hooks):
                kept.append(entry)
            elif filtered_hooks:
                entry["hooks"] = filtered_hooks
                kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            hooks.pop(event, None)


def command_for(script: Path) -> str:
    # Codex command hooks use a shell command string. Double quotes cover the
    # normal user-home path cases on Unix and Windows.
    escaped = str(script).replace('"', '\\"')
    return f'python3 "{escaped}"'


def install(path: Path, script: Path) -> None:
    data = load(path)
    remove_managed(data)
    command = command_for(script)
    for event in EVENTS:
        data["hooks"].setdefault(event, []).append(
            {
                "hooks": [
                    {
                        "type": "command",
                        "command": command,
                        "timeout": 15,
                        "statusMessage": "FlowPilot telemetry",
                    }
                ]
            }
        )
    write(path, data)


def uninstall(path: Path) -> None:
    if not path.exists():
        return
    data = load(path)
    remove_managed(data)
    write(path, data)


def write(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".codex-flow.tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def check(path: Path) -> int:
    if not path.exists():
        return 1
    data = load(path)
    hooks = data.get("hooks", {})
    for event in EVENTS:
        entries = hooks.get(event, [])
        if not isinstance(entries, list) or not any(is_managed_entry(entry) for entry in entries):
            return 1
    return 0


def _absolute_display_path(path: Path) -> str:
    # Codex builds hook keys from an absolute source path. Do not resolve
    # symlinks here: the config-layer path is made absolute, not canonicalized.
    return os.path.abspath(os.path.expanduser(str(path)))


def _event_key_label(event: str) -> str:
    return EVENT_KEY_LABELS.get(event, re.sub(r"(?<!^)(?=[A-Z])", "_", event).lower())


def _normalized_timeout(event: str, value: Any) -> int:
    try:
        timeout = int(value) if value is not None else None
    except (TypeError, ValueError):
        timeout = None
    if event in {"SessionEnd", "Interrupt"}:
        timeout = SESSION_END_DEFAULT_TIMEOUT_SEC if timeout is None else timeout
        return max(1, min(timeout, SESSION_END_MAX_TIMEOUT_SEC))
    timeout = DEFAULT_TIMEOUT_SEC if timeout is None else timeout
    return max(1, timeout)


def _canonical_hash(value: dict[str, Any]) -> str:
    serialized = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(serialized).hexdigest()


def _normalized_command_identity(
    event: str,
    matcher: Any,
    handler: dict[str, Any],
) -> dict[str, Any]:
    command = handler.get("command")
    if os.name == "nt" and isinstance(handler.get("commandWindows"), str):
        command = handler["commandWindows"]
    if not isinstance(command, str):
        command = ""

    normalized_handler: dict[str, Any] = {
        "type": "command",
        "command": command,
        "timeout": _normalized_timeout(event, handler.get("timeout")),
        "async": bool(handler.get("async", False)),
    }
    status_message = handler.get("statusMessage")
    if isinstance(status_message, str):
        normalized_handler["statusMessage"] = status_message

    if event in ADDITIONAL_CONTEXT_EVENTS:
        limit = handler.get("additionalContextLimit")
        if isinstance(limit, int) and not isinstance(limit, bool) and limit != DEFAULT_ADDITIONAL_CONTEXT_LIMIT:
            normalized_handler["additionalContextLimit"] = limit

    identity: dict[str, Any] = {
        "event_name": _event_key_label(event),
        "hooks": [normalized_handler],
    }
    if isinstance(matcher, str):
        identity["matcher"] = matcher
    return identity


def _managed_hook_entries(path: Path) -> list[dict[str, Any]]:
    data = load(path)
    hooks = data.get("hooks", {})
    if not isinstance(hooks, dict):
        return []
    source = _absolute_display_path(path)
    result: list[dict[str, Any]] = []
    for event, groups in hooks.items():
        if not isinstance(event, str) or not isinstance(groups, list):
            continue
        for group_index, group in enumerate(groups):
            if not isinstance(group, dict):
                continue
            matcher = group.get("matcher")
            handlers = group.get("hooks", [])
            if not isinstance(handlers, list):
                continue
            for handler_index, handler in enumerate(handlers):
                if not is_managed_hook(handler):
                    continue
                assert isinstance(handler, dict)
                key = f"{source}:{_event_key_label(event)}:{group_index}:{handler_index}"
                current_hash = _canonical_hash(_normalized_command_identity(event, matcher, handler))
                result.append(
                    {
                        "event": event,
                        "group_index": group_index,
                        "handler_index": handler_index,
                        "key": key,
                        "current_hash": current_hash,
                    }
                )
    return result


def _fallback_hook_states(text: str) -> dict[str, dict[str, Any]]:
    """Minimal parser for hook trust state when stdlib tomllib is unavailable."""
    states: dict[str, dict[str, Any]] = {}
    current: str | None = None
    header = re.compile(r'^\s*\[hooks\.state\.(?P<key>.+)\]\s*$')
    for raw_line in text.splitlines():
        match = header.match(raw_line)
        if match:
            token = match.group("key").strip()
            current = None
            if len(token) >= 2 and token[0] == token[-1] == "'":
                current = token[1:-1]
            elif len(token) >= 2 and token[0] == token[-1] == '"':
                try:
                    current = json.loads(token)
                except json.JSONDecodeError:
                    current = token[1:-1].replace('\\"', '"').replace("\\\\", "\\")
            if current is not None:
                states.setdefault(current, {})
            continue
        if current is None:
            continue
        trusted = re.match(r'^\s*trusted_hash\s*=\s*"([^"]+)"\s*(?:#.*)?$', raw_line)
        if trusted:
            states[current]["trusted_hash"] = trusted.group(1)
            continue
        enabled = re.match(r"^\s*enabled\s*=\s*(true|false)\s*(?:#.*)?$", raw_line, re.IGNORECASE)
        if enabled:
            states[current]["enabled"] = enabled.group(1).lower() == "true"
    return states


def _load_hook_states(config: Path) -> tuple[dict[str, dict[str, Any]], str | None]:
    if not config.exists():
        return {}, None
    try:
        text = config.read_text(encoding="utf-8-sig")
    except OSError as exc:
        return {}, str(exc)
    try:
        import tomllib  # Python 3.11+
    except ImportError:
        return _fallback_hook_states(text), None
    try:
        parsed = tomllib.loads(text)
    except Exception as exc:  # invalid config should not crash install/update
        fallback = _fallback_hook_states(text)
        return fallback, None if fallback else str(exc)
    hooks = parsed.get("hooks", {}) if isinstance(parsed, dict) else {}
    state = hooks.get("state", {}) if isinstance(hooks, dict) else {}
    if not isinstance(state, dict):
        return {}, None
    result: dict[str, dict[str, Any]] = {}
    for key, value in state.items():
        if isinstance(key, str) and isinstance(value, dict):
            result[key] = value
    return result, None


def trust_report(path: Path, config: Path) -> dict[str, Any]:
    if not path.exists():
        return {
            "status": "missing",
            "ready": False,
            "authorization_required": False,
            "total": 0,
            "trusted": 0,
            "untrusted": 0,
            "modified": 0,
            "disabled": 0,
            "entries": [],
            "error": None,
        }

    entries = _managed_hook_entries(path)
    if not entries:
        return {
            "status": "missing",
            "ready": False,
            "authorization_required": False,
            "total": 0,
            "trusted": 0,
            "untrusted": 0,
            "modified": 0,
            "disabled": 0,
            "entries": [],
            "error": None,
        }

    states, state_error = _load_hook_states(config)
    counts = {"trusted": 0, "untrusted": 0, "modified": 0, "disabled": 0}
    for entry in entries:
        state = states.get(entry["key"], {})
        enabled = state.get("enabled") is not False
        trusted_hash = state.get("trusted_hash") if isinstance(state.get("trusted_hash"), str) else None
        if not enabled:
            status = "disabled"
        elif trusted_hash == entry["current_hash"]:
            status = "trusted"
        elif trusted_hash:
            status = "modified"
        else:
            status = "untrusted"
        counts[status] += 1
        entry["status"] = status
        entry["enabled"] = enabled
        entry["trusted_hash"] = trusted_hash

    if state_error:
        aggregate = "unknown"
    elif counts["disabled"]:
        aggregate = "disabled"
    elif counts["modified"]:
        aggregate = "modified"
    elif counts["untrusted"]:
        aggregate = "untrusted"
    else:
        aggregate = "trusted"

    return {
        "status": aggregate,
        "ready": aggregate == "trusted",
        "authorization_required": bool(counts["untrusted"] or counts["modified"]),
        "total": len(entries),
        **counts,
        "entries": entries,
        "error": state_error,
        "hooks_path": _absolute_display_path(path),
        "config_path": _absolute_display_path(config),
    }


def _print_trust_report(report: dict[str, Any]) -> None:
    status = report.get("status", "unknown")
    total = int(report.get("total", 0) or 0)
    trusted = int(report.get("trusted", 0) or 0)
    if status == "trusted":
        print(f"FlowPilot hook trust: trusted ({trusted}/{total})")
    elif status == "modified":
        print("FlowPilot hook trust: changed since approval; review required with /hooks")
    elif status == "untrusted":
        print("FlowPilot hook trust: approval required; review with /hooks")
    elif status == "disabled":
        print("FlowPilot hook trust: one or more managed hooks are disabled in Codex")
    elif status == "missing":
        print("FlowPilot hook trust: managed hooks are not installed")
    else:
        detail = report.get("error") or "trust state could not be verified"
        print(f"FlowPilot hook trust: unknown ({detail})")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall", "check", "status"))
    parser.add_argument("--hooks", required=True, type=Path)
    parser.add_argument("--script", type=Path)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if args.action == "install":
        if args.script is None:
            parser.error("--script is required for install")
        install(args.hooks, args.script)
        return 0
    if args.action == "uninstall":
        uninstall(args.hooks)
        return 0
    if args.action == "check":
        return check(args.hooks)

    config = args.config or args.hooks.parent / "config.toml"
    report = trust_report(args.hooks, config)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        _print_trust_report(report)
    if report["ready"]:
        return 0
    if report["status"] == "missing":
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
