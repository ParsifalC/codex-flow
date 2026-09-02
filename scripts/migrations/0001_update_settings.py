#!/usr/bin/env python3
"""Add OTA update preferences without rewriting unrelated policy fields."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
from pathlib import Path

DEFAULTS = {
    "channel": '"stable"',
    "check": "true",
    "check_interval_hours": "24",
    "notify_cli": "true",
    "notify_app": "true",
    "auto_install": "false",
}


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass


def migrate(policy: Path) -> bool:
    try:
        text = policy.read_text(encoding="utf-8-sig")
    except OSError:
        return False

    section_re = re.compile(r"(?ms)^\[update\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
    match = section_re.search(text)
    changed = False
    if not match:
        if text and not text.endswith("\n"):
            text += "\n"
        if text and not text.endswith("\n\n"):
            text += "\n"
        text += "[update]\n" + "".join(f"{key} = {value}\n" for key, value in DEFAULTS.items())
        changed = True
    else:
        body = match.group(1)
        for key, value in DEFAULTS.items():
            if re.search(rf"(?m)^\s*{re.escape(key)}\s*=", body):
                continue
            if body and not body.endswith("\n"):
                body += "\n"
            body += f"{key} = {value}\n"
            changed = True
        if changed:
            text = text[: match.start(1)] + body + text[match.end(1) :]

    if changed:
        atomic_write(policy, text)
    return changed


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True, type=Path)
    args = parser.parse_args()
    migrate(args.policy)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
