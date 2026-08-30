#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
CONFIG="$CODEX_HOME/config.toml"
STAMP="$(date +%Y%m%d-%H%M%S)"

mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/cost-aware-development"

if [[ -f "$CONFIG" ]]; then
  cp "$CONFIG" "$CONFIG.codex-flow.$STAMP.bak"
else
  touch "$CONFIG"
fi

python3 - "$CONFIG" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text() if path.exists() else ""

managed = {
    "enabled": "true",
    "max_concurrent_threads_per_session": "4",
    "default_subagent_model": '"gpt-5.6-luna"',
    "default_subagent_reasoning_effort": '"max"',
}

section_re = re.compile(r"(?ms)^\[agents\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)")
match = section_re.search(text)

if match:
    body = match.group(1)
    for key, value in managed.items():
        key_re = re.compile(rf"(?m)^\s*{re.escape(key)}\s*=.*$")
        line = f"{key} = {value}"
        if key_re.search(body):
            body = key_re.sub(line, body)
        else:
            if body and not body.endswith("\n"):
                body += "\n"
            body += line + "\n"
    text = text[:match.start(1)] + body + text[match.end(1):]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    if text and not text.endswith("\n\n"):
        text += "\n"
    text += "[agents]\n"
    for key, value in managed.items():
        text += f"{key} = {value}\n"

path.write_text(text)
PY

cp "$ROOT_DIR/templates/agents/luna-explorer.toml" "$CODEX_HOME/agents/luna-explorer.toml"
cp "$ROOT_DIR/templates/agents/luna-implementer.toml" "$CODEX_HOME/agents/luna-implementer.toml"
cp "$ROOT_DIR/templates/skills/cost-aware-development/SKILL.md" "$CODEX_HOME/skills/cost-aware-development/SKILL.md"

cat <<EOF
codex-flow installed.

  config: $CONFIG
  agents: $CODEX_HOME/agents
  skill:  $CODEX_HOME/skills/cost-aware-development

Restart Codex, then use it normally.
For the intended parent role, select gpt-5.6-sol with xhigh reasoning.

Run:
  $ROOT_DIR/scripts/doctor
EOF
