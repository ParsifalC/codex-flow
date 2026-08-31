#!/usr/bin/env python3
"""Install/remove codex-flow lifecycle hooks without clobbering user hooks."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from typing import Any

EVENTS = ("UserPromptSubmit", "SubagentStart", "SubagentStop", "Stop")
MARKER = "codex-flow/telemetry.py"


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


def is_managed_entry(entry: Any) -> bool:
    if not isinstance(entry, dict):
        return False
    for hook in entry.get("hooks", []):
        if isinstance(hook, dict) and MARKER in str(hook.get("command", "")).replace("\\", "/"):
            return True
    return False


def remove_managed(data: dict[str, Any]) -> None:
    hooks = data.get("hooks", {})
    for event in list(hooks):
        entries = hooks[event]
        if not isinstance(entries, list):
            continue
        kept = [entry for entry in entries if not is_managed_entry(entry)]
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
                        "timeout": 8,
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("install", "uninstall", "check"))
    parser.add_argument("--hooks", required=True, type=Path)
    parser.add_argument("--script", type=Path)
    args = parser.parse_args()
    if args.action == "install":
        if args.script is None:
            parser.error("--script is required for install")
        install(args.hooks, args.script)
        return 0
    if args.action == "uninstall":
        uninstall(args.hooks)
        return 0
    return check(args.hooks)


if __name__ == "__main__":
    raise SystemExit(main())
