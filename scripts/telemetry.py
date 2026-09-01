#!/usr/bin/env python3
"""Deterministic codex-flow telemetry collector and CLI.

Consumes Codex command-hook JSON on stdin. It never calls a model. Usage and
quota data are read from `codex app-server`; lifecycle data comes from hooks.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Ensure telemetry_core is discoverable relative to this script
sys.path.insert(0, str(Path(__file__).resolve().parent))

from telemetry_core import *  # noqa: F401, F403
from telemetry_core import (
    collect_hook,
    show_last,
    show_list,
    show_run,
    show_stats,
    telemetry_retention_days,
)


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
            return show_list(
                limit=limit, project=project, today=today, as_json=as_json
            )
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
        if not cmd.startswith("-"):
            return show_run(cmd, as_json="--json" in args[1:])

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
