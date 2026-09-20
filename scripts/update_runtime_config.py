#!/usr/bin/env python3
"""Reconcile codex-flow-owned runtime settings without rewriting user config."""

from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path


MANAGED_AGENT_FILES = (
    "worker-explorer.toml",
    "worker-implementer.toml",
    "worker-reviewer.toml",
)
MANAGED_AGENT_KEYS = ("model", "model_provider")


def read_value(text: str, section: str, key: str) -> str | None:
    section_match = re.search(
        rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)", text
    )
    if not section_match:
        return None
    key_match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", section_match.group(1))
    if not key_match:
        return None
    value = re.sub(r"\s+#.*$", "", key_match.group(1)).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        try:
            # TOML basic-string escapes overlap with JSON's, and decoding here
            # prevents a previously escaped quote/backslash from being escaped
            # a second time when we render managed values.
            return json.loads(value)
        except json.JSONDecodeError:
            return value[1:-1]
    return value


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


def set_section_values(text: str, section: str, values: dict[str, str]) -> str:
    section_re = re.compile(
        rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)"
    )
    match = section_re.search(text)
    if match:
        body = match.group(1)
        for key, value in values.items():
            line = f"{key} = {value}"
            key_re = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
            if key_re.search(body):
                body = key_re.sub(line, body)
            else:
                if body and not body.endswith("\n"):
                    body += "\n"
                body += line + "\n"
        return text[: match.start(1)] + body + text[match.end(1) :]

    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += f"[{section}]\n"
    text += "".join(f"{key} = {value}\n" for key, value in values.items())
    return text


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def _set_agent_values(text: str, values: dict[str, str | None]) -> str:
    """Set or remove codex-flow-owned top-level agent keys.

    Agent templates are intentionally kept free of model settings so Codex's
    host defaults remain authoritative for the normal ``auto`` path.  When a
    provider is explicitly selected, this small line-oriented reconciler adds
    the provider and resolved model without disturbing the rest of the agent
    instructions.
    """

    for key, value in values.items():
        key_re = re.compile(rf"(?m)^[ \t]*{re.escape(key)}[ \t]*=.*(?:\r?\n|$)")
        if value is None:
            text = key_re.sub("", text)
            continue
        line = f"{key} = {value}\n"
        if key_re.search(text):
            text = key_re.sub(line, text, count=1)
        else:
            if text and not text.endswith(("\n", "\r")):
                text += "\n"
            text += line
    return text


def _reconcile_agent_files(agents_dir: Path, model: str, provider: str) -> None:
    values: dict[str, str | None]
    if provider == "auto":
        values = {key: None for key in MANAGED_AGENT_KEYS}
    else:
        values = {"model": quoted(model), "model_provider": quoted(provider)}

    for name in MANAGED_AGENT_FILES:
        path = agents_dir / name
        try:
            text = path.read_text(encoding="utf-8-sig")
        except OSError:
            # A partial/older release may not ship all templates.  The next
            # install or OTA sync will create them; do not make reconciliation
            # fail solely because a managed file is absent.
            continue
        atomic_write(path, _set_agent_values(text, values))


def reconcile(
    config: Path,
    policy: Path,
    defaults: Path,
    agents_dir: Path | None = None,
) -> None:
    policy_text = policy.read_text(encoding="utf-8-sig")
    defaults_text = defaults.read_text(encoding="utf-8-sig")
    try:
        config_text = config.read_text(encoding="utf-8-sig")
    except OSError:
        config_text = ""

    requested_model = read_value(policy_text, "worker", "model") or "auto"
    requested_provider = read_value(policy_text, "worker", "model_provider") or "auto"
    default_model = read_value(defaults_text, "models", "worker_model")
    if not default_model:
        raise RuntimeError("release defaults are missing [models].worker_model")
    resolved_model = default_model if requested_model == "auto" else requested_model

    worker_effort = (
        read_value(policy_text, "worker", "min_reasoning_effort")
        or read_value(defaults_text, "reasoning.worker", "minimum")
    )
    max_threads = (
        read_value(policy_text, "runtime", "max_concurrent_threads")
        or read_value(defaults_text, "runtime", "max_concurrent_threads")
    )
    if not worker_effort or not max_threads:
        raise RuntimeError("release policy is missing worker effort or max thread settings")
    if not re.fullmatch(r"[1-9][0-9]*", max_threads):
        raise RuntimeError("invalid max_concurrent_threads in policy")

    policy_text = set_section_values(
        policy_text,
        "worker",
        {"resolved_model": quoted(resolved_model)},
    )
    config_text = set_section_values(
        config_text,
        "agents",
        {
            "enabled": "true",
            "max_concurrent_threads_per_session": max_threads,
            "default_subagent_model": quoted(resolved_model),
            "default_subagent_reasoning_effort": quoted(worker_effort),
        },
    )

    atomic_write(policy, policy_text)
    atomic_write(config, config_text)
    if agents_dir is not None:
        _reconcile_agent_files(agents_dir, resolved_model, requested_provider)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--defaults", required=True, type=Path)
    parser.add_argument("--agents-dir", type=Path)
    args = parser.parse_args()
    reconcile(args.config, args.policy, args.defaults, args.agents_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
