#!/usr/bin/env python3
"""Arm/check one real Desktop turn without copying auth or fabricating events."""
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from telemetry_core.host_transport import arm_probe, probe_status

parser = argparse.ArgumentParser(description=__doc__)
commands = parser.add_subparsers(dest="command", required=True)
arm = commands.add_parser("arm")
arm.add_argument("--session-id", required=True, help="Explicit Desktop chat id; not inferred from the environment")
arm.add_argument("--cwd", required=True)
commands.add_parser("status")
args = parser.parse_args()
result = arm_probe(session_id=args.session_id, cwd=args.cwd) if args.command == "arm" else probe_status()
print(json.dumps(result, ensure_ascii=False, sort_keys=True))
if args.command == "status" and result["status"] != "supported_probe":
    sys.exit(2)
