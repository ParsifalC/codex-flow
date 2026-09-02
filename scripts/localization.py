#!/usr/bin/env python3
"""Shared language resolution and policy persistence for codex-flow."""

from __future__ import annotations

import argparse
import locale
import os
import re
import subprocess
import sys
from pathlib import Path

SUPPORTED_LANGUAGES = {"auto", "zh", "en"}


def normalize_language(value: str | None, *, allow_auto: bool = True) -> str:
    raw = (value or "").strip().lower().replace("_", "-")
    if allow_auto and raw in ("", "auto", "system", "default"):
        return "auto"
    if raw == "zh" or raw.startswith("zh-") or raw.startswith("chinese"):
        return "zh"
    if raw == "en" or raw.startswith("en-") or raw.startswith("english"):
        return "en"
    raise ValueError("language must be auto, zh, or en")


def _language_from_text(value: str | None) -> str | None:
    if not value:
        return None
    lowered = value.strip().lower().replace("_", "-")
    if lowered.startswith("zh") or "chinese" in lowered:
        return "zh"
    if lowered.startswith("en") or "english" in lowered:
        return "en"
    return None


def detect_system_language() -> str:
    if sys.platform == "darwin":
        try:
            result = subprocess.run(
                ["defaults", "read", "-g", "AppleLanguages"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=1.0,
            )
            match = re.search(r'"([^"\n]+)"', result.stdout or "")
            detected = _language_from_text(match.group(1) if match else result.stdout)
            if detected:
                return detected
        except (OSError, subprocess.SubprocessError):
            pass

    env_candidates = (
        os.environ.get("LC_ALL"),
        os.environ.get("LC_MESSAGES"),
        os.environ.get("LANGUAGE"),
        os.environ.get("LANG"),
    )
    for candidate in env_candidates:
        detected = _language_from_text(candidate)
        if detected:
            return detected

    try:
        current = locale.getlocale()[0]
    except (ValueError, TypeError):
        current = None
    detected = _language_from_text(current)
    return detected or "en"


def policy_path() -> Path:
    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    return codex_home / "codex-flow.toml"


def configured_language(path: Path | None = None) -> str:
    path = path or policy_path()
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return "auto"
    section = re.search(r"(?ms)^\[ui\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)", text)
    if not section:
        return "auto"
    match = re.search(r'(?m)^\s*language\s*=\s*"?([^"\s#]+)"?', section.group(1))
    if not match:
        return "auto"
    try:
        return normalize_language(match.group(1))
    except ValueError:
        return "auto"


def resolve_language(path: Path | None = None) -> str:
    override = os.environ.get("CODEX_FLOW_LANGUAGE")
    if override:
        try:
            value = normalize_language(override)
        except ValueError:
            value = "auto"
    else:
        value = configured_language(path)
    return detect_system_language() if value == "auto" else value


def set_configured_language(value: str, path: Path | None = None) -> str:
    normalized = normalize_language(value)
    path = path or policy_path()
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        text = ""

    section_re = re.compile(r"(?ms)^\[ui\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
    match = section_re.search(text)
    line = f'language = "{normalized}"'
    if match:
        body = match.group(1)
        key_re = re.compile(r"(?m)^\s*language\s*=.*$")
        if key_re.search(body):
            body = key_re.sub(line, body)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
        text = text[: match.start(1)] + body + text[match.end(1) :]
    else:
        if text and not text.endswith("\n"):
            text += "\n"
        if text and not text.endswith("\n\n"):
            text += "\n"
        text += f"[ui]\n{line}\n"

    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return normalized


def tr(english: str, chinese: str, *, lang: str | None = None) -> str:
    selected = lang or resolve_language()
    return chinese if selected == "zh" else english


def _main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--policy", type=Path, default=None)
    parser.add_argument("--resolved", action="store_true")
    parser.add_argument("--configured", action="store_true")
    parser.add_argument("--system", action="store_true")
    parser.add_argument("--normalize")
    parser.add_argument("--set")
    args = parser.parse_args()

    try:
        if args.normalize is not None:
            print(normalize_language(args.normalize))
        elif args.set is not None:
            print(set_configured_language(args.set, args.policy))
        elif args.configured:
            print(configured_language(args.policy))
        elif args.system:
            print(detect_system_language())
        else:
            print(resolve_language(args.policy))
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(_main())
