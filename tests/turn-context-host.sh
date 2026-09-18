#!/usr/bin/env bash
# A release gate, not a synthetic hook test. Unproven host support exits 2.
set -euo pipefail
rtk proxy python3 - "${BASH_SOURCE[0]}" <<'PY'
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path(sys.argv[1]).resolve().parents[1]
result = {
    "status": "unverified", "target_host": "codex-desktop",
    "automatic_writes_enabled": False, "metadata_display": "未记录",
    "same_turn_receipt_delivery_verified": False,
    "goal_plan_stop_chain_verified": False,
}

def finish(reason):
    result["reason"] = reason
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))

with tempfile.TemporaryDirectory(prefix="flow-turn-context-host-") as directory:
    base = Path(directory)
    home = base / "codex-home"
    home.mkdir()
    env = {**os.environ, "CODEX_HOME": str(home), "CODEX_FLOW_BIN_DIR": str(base / "bin"), "CODEX_FLOW_SHELL": "none"}
    install = subprocess.run(["rtk", "proxy", "bash", str(root / "install.sh")], env=env, text=True, capture_output=True)
    if install.returncode:
        finish("temporary_install_failed")
        sys.exit(2)
    # This local rejection is a fail-closed assertion, not protocol evidence.
    goal = base / "goal.txt"
    goal.write_text("host probe", encoding="utf-8")
    rejection = subprocess.run(
        [sys.executable, str(home / "codex-flow" / "telemetry.py"), "context", "write-goal",
         "--receipt-file", str(base / "missing-receipt.json"), "--text-file", str(goal)],
        env=env, text=True, capture_output=True,
    )
    result["missing_receipt_rejected"] = (
        rejection.returncode == 2 and json.loads(rejection.stderr).get("error") == "receipt_missing"
        and not (home / "codex-flow" / "telemetry" / "turn-context").exists()
    )
    if not result["missing_receipt_rejected"]:
        finish("fail_closed_assertion_failed")
        sys.exit(1)
    codex = shutil.which("codex")
    if not codex:
        finish("host_executable_missing")
        sys.exit(2)
    login = subprocess.run(["rtk", "proxy", codex, "login", "status"], env=env, text=True, capture_output=True)
    if login.returncode:
        # Do not copy authentication or infer protocol support from this failure.
        finish("temporary_home_not_authenticated")
        sys.exit(2)
    try:
        probe = subprocess.run(
            ["rtk", "proxy", codex, "exec", "--json", "--skip-git-repo-check",
             "输出一个固定 marker：turn-context-host-probe"],
            env=env, text=True, capture_output=True, timeout=45,
        )
    except subprocess.TimeoutExpired:
        finish("host_probe_timeout")
        sys.exit(2)
    if probe.returncode:
        finish("host_probe_failed_or_untrusted")
        sys.exit(2)
    # A successful CLI marker says nothing about Desktop receipt delivery.
    # No verified context transport adapter exists yet. Do not manufacture a
    # supported fixture from model text, CODEX_* variables, or systemMessage.
    finish("desktop_receipt_transport_not_verified")
sys.exit(2)
PY
