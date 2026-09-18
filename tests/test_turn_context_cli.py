"""File-only context CLI contract in a fresh, isolated Python process."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TELEMETRY_SCRIPT = Path(os.environ.get("CODEX_FLOW_TEST_TELEMETRY_SCRIPT", str(ROOT / "scripts/telemetry.py")))


class TurnContextCLITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.env = {**os.environ, "CODEX_HOME": str(self.home), "PYTHONPATH": str(TELEMETRY_SCRIPT.parent)}
        self.receipt = self.home / "receipt.json"
        self.text = self.home / "goal.txt"
        self.plan = self.home / "plan.json"
        self.text.write_text("修复 Unicode 🌏\n保留 '$HOME' 与 `literal`", encoding="utf-8")

    def cli(self, *args):
        return subprocess.run([sys.executable, str(TELEMETRY_SCRIPT), "context", *args], env=self.env, text=True, encoding="utf-8", capture_output=True, check=False)

    def seed(self):
        code = """
import json, sys
from dataclasses import asdict
from pathlib import Path
from telemetry_core.turn_context import register_receipt
from strategy_runtime import TaskProfile, compile_plan
r=register_receipt({'hook_event_name':'UserPromptSubmit','session_id':'chat-a','turn_id':'turn-2'})
Path(sys.argv[1]).write_text(json.dumps(asdict(r)), encoding='utf-8')
Path(sys.argv[2]).write_text(json.dumps(compile_plan(TaskProfile(),routing_mode='delegate').to_dict()), encoding='utf-8')
"""
        result = subprocess.run([sys.executable, "-c", code, str(self.receipt), str(self.plan)], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def goal_args(self):
        return ("write-goal", "--receipt-file", str(self.receipt), "--text-file", str(self.text))

    def assert_error(self, result, code=None):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        payload = json.loads(result.stderr)
        self.assertIsInstance(payload["error"], str)
        if code:
            self.assertEqual(payload["error"], code)

    def test_invalid_arguments_return_structured_exit_two(self):
        for args in (
            (), ("unknown",), ("write-goal",),
            ("write-goal", "--receipt-file", "r"),
            ("write-goal", "--receipt-file", "r", "--text-file", "t", "--text-file", "t2"),
            ("write-goal", "--receipt-file", "r", "--text", "inline"),
            ("write-plan", "--receipt-file", "r", "--plan-file", "p", "--origin", "invented"),
            ("write-plan", "--receipt-file", "r", "--plan-file", "p"),
        ):
            with self.subTest(args=args):
                self.assert_error(self.cli(*args))
        self.assertFalse((self.home / "codex-flow").exists())

    def test_missing_receipt_does_not_use_environment_or_last_run(self):
        self.env.update({"CODEX_THREAD_ID": "chat-a", "CODEX_SESSION_ID": "chat-a", "CODEX_TURN_ID": "turn-2"})
        self.assert_error(self.cli(*self.goal_args()), "receipt_missing")
        self.assertFalse((self.home / "codex-flow").exists())

    def test_file_content_roundtrips_and_conflict_does_not_overwrite(self):
        self.seed()
        first = self.cli(*self.goal_args())
        self.assertEqual(first.returncode, 0, first.stderr)
        payload = json.loads(first.stdout)
        self.assertEqual((payload["session_id"], payload["turn_id"]), ("chat-a", "turn-2"))
        self.assertEqual(payload["goal"]["text"], self.text.read_text(encoding="utf-8"))
        self.assertEqual(self.cli(*self.goal_args()).stdout, first.stdout)
        self.text.write_text("changed", encoding="utf-8")
        self.assert_error(self.cli(*self.goal_args()), "goal_conflict")

    def test_unicode_json_output_is_safe_on_non_utf8_console(self):
        self.seed()
        self.env["PYTHONIOENCODING"] = "ascii"
        result = self.cli(*self.goal_args())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["goal"]["text"], self.text.read_text(encoding="utf-8"))

    def test_empty_overlong_and_invalid_utf8_files(self):
        self.seed()
        for text, code in (("", "goal_empty"), ("字" * 401, "goal_too_long")):
            self.text.write_text(text, encoding="utf-8")
            self.assert_error(self.cli(*self.goal_args()), code)
        self.text.write_bytes(b"\xff")
        self.assert_error(self.cli(*self.goal_args()), "invalid_utf8")

    def test_plan_json_schema_and_revision(self):
        self.seed()
        args = ("write-plan", "--receipt-file", str(self.receipt), "--plan-file", str(self.plan), "--origin", "compiled")
        good = self.plan.read_text(encoding="utf-8")
        for text in ("{", "null", '{"schema_version":11}', '{"schema_version":NaN}'):
            self.plan.write_text(text, encoding="utf-8")
            self.assert_error(self.cli(*args), "invalid_execution_plan")
        self.plan.write_text(good, encoding="utf-8")
        first = self.cli(*args)
        self.assertEqual(first.returncode, 0, first.stderr)
        payload = json.loads(first.stdout)
        self.assertEqual(payload["orchestration"]["revision"], 1)
        self.assertEqual(payload["orchestration"]["execution_plan"], json.loads(good))
        self.assertEqual(self.cli(*args).stdout, first.stdout)

    def test_wrong_turn_and_child_receipts_are_rejected(self):
        self.seed()
        original = json.loads(self.receipt.read_text())
        for field, value, code in (("session_id", "other", "receipt_expired"), ("turn_id", "other", "receipt_expired"), ("role", "worker", "receipt_role_forbidden")):
            self.receipt.write_text(json.dumps({**original, field: value}), encoding="utf-8")
            self.assert_error(self.cli(*self.goal_args()), code)

    def test_disabled_context_returns_zero_without_reading_files_or_writing(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n", encoding="utf-8")
        for args in (self.goal_args(), ("write-plan", "--receipt-file", "missing", "--plan-file", "missing", "--origin", "compiled")):
            result = self.cli(*args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout)["status"], "disabled")
        self.assertFalse((self.home / "codex-flow").exists())


if __name__ == "__main__":
    unittest.main()
