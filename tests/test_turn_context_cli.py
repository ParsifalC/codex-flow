"""Explicit-receipt context CLI contract in a fresh, isolated Python process."""
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

    def cli(self, *args, input=None):
        return self.telemetry_cli("context", *args, input=input)

    def telemetry_cli(self, *args, input=None):
        return subprocess.run([sys.executable, str(TELEMETRY_SCRIPT), *args], env=self.env, input=input, text=True, encoding="utf-8", capture_output=True, check=False)

    def test_stdin_goal_needs_no_input_file_and_preserves_literal_text(self):
        self.seed()
        self.text.unlink()
        source = "修复 Unicode 🌏，保留 '$HOME'、`literal` 和 $(literal)"
        args = ("write-goal", "--receipt-file", str(self.receipt), "--stdin")
        result = self.cli(*args, input=source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["goal"]["text"], source)
        self.assertFalse(self.text.exists())
        self.assertEqual(self.cli(*args, input=source).stdout, result.stdout)
        self.assert_error(self.cli(*args, input="另一个目标"), "goal_conflict")

    def test_stdin_goal_validates_input_and_disabled_does_not_read(self):
        self.seed()
        args = ("write-goal", "--receipt-file", str(self.receipt), "--stdin")
        for source, code in (("", "goal_empty"), ("字" * 81, "goal_too_long")):
            self.assert_error(self.cli(*args, input=source), code)
        self.disable_telemetry()
        before = self.state_snapshot(self.home / "codex-flow")
        result = self.cli(*args, input="")
        self.assertEqual(json.loads(result.stdout)["status"], "disabled")
        self.assertEqual(before, self.state_snapshot(self.home / "codex-flow"))

    def test_stdin_rejects_invalid_utf8_without_writing_context(self):
        self.seed()
        result = subprocess.run(
            [sys.executable, str(TELEMETRY_SCRIPT), "context", "write-goal",
             "--receipt-file", str(self.receipt), "--stdin"],
            env=self.env, input=b"\xff", capture_output=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stderr)["error"], "invalid_utf8")
        self.assertFalse((self.home / "codex-flow/telemetry/turn-context").exists())

    def disable_telemetry(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n", encoding="utf-8")

    def state_snapshot(self, path):
        if not path.exists():
            return {}
        return {
            str(item.relative_to(path)): (item.read_bytes(), item.stat().st_mtime_ns)
            for item in path.rglob("*")
            if item.is_file()
        }

    def latency_event(self, event_id="guard-event"):
        return {
            "event_id": event_id, "task_id": "guard-task", "worker_id": "guard-worker",
            "strategy": "efficient", "task_class": "routine", "stage": "implementation",
            "role": "implementer", "model": "gpt-5.6-luna", "rollout_mode": "shadow",
            "legacy_effort": "xhigh", "proposed_effort": "high", "selected_effort": "xhigh",
            "observed_effort": None, "boundary": "terminal", "outcome": "completed",
            "started_at": 1000, "finished_at": 1004, "repair_count": 0, "checkpoint_count": 0,
        }

    def seed(self, *, turn_id="turn-2"):
        code = """
import json, sys
from dataclasses import asdict
from pathlib import Path
from telemetry_core.turn_context import register_receipt
from strategy_runtime import TaskProfile, compile_plan
r=register_receipt({'hook_event_name':'UserPromptSubmit','session_id':'chat-a','turn_id':sys.argv[3]})
Path(sys.argv[1]).write_text(json.dumps(asdict(r)), encoding='utf-8')
Path(sys.argv[2]).write_text(json.dumps(compile_plan(TaskProfile(),routing_mode='delegate').to_dict()), encoding='utf-8')
"""
        result = subprocess.run([sys.executable, "-c", code, str(self.receipt), str(self.plan), turn_id], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def write_goal_content(self, text, *, line_ending="\n"):
        self.text.write_bytes(text.replace("\n", line_ending).encode("utf-8"))

    def goal_args(self):
        return ("write-goal", "--receipt-file", str(self.receipt), "--text-file", str(self.text))

    def assert_error(self, result, code=None):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        payload = json.loads(result.stderr)
        self.assertIs(payload["ok"], False)
        self.assertIsInstance(payload["error"], str)
        if code:
            self.assertEqual(payload["error"], code)

    def test_context_help_is_available(self):
        proc = self.cli("--help")
        self.assertEqual(proc.returncode, 0)
        self.assertIn("write-goal", proc.stdout)
        self.assertIn("write-plan", proc.stdout)

    def test_enable_desktop_transport_requires_completed_probe(self):
        self.assert_error(self.cli("enable-desktop-transport"), "host_transport_unverified")
        self.assertFalse((self.home / "codex-flow").exists())
        self.seed()
        # Synthetic transport fixture verifies CLI behavior, not real host support.
        code = """
import json, sys
from pathlib import Path
from telemetry_core.host_transport import arm_probe, probe_hook_context
from telemetry_core.turn_context import write_goal, write_plan
from telemetry_core.publication import publish_parent_stop
from telemetry_core.common import run_key
home=Path(sys.argv[1])
transcript=home/'desktop.jsonl'
transcript.write_text(json.dumps({'type':'session_meta','payload':{
    'id':'chat-a','source':'vscode','originator':'Codex Desktop','thread_source':'user'}}), encoding='utf-8')
event={'hook_event_name':'UserPromptSubmit','session_id':'chat-a','turn_id':'turn-2',
       'cwd':str(home),'transcript_path':str(transcript)}
arm_probe(session_id='chat-a',cwd=str(home))
assert probe_hook_context(event) is not None
write_goal(receipt_file=home/'receipt.json',text_file=home/'goal.txt')
write_plan(receipt_file=home/'receipt.json',plan_file=home/'plan.json',origin='compiled')
publish_parent_stop(run_key=run_key(event),observed=event,completed_at_ms=123,
    result={'source':'parent_final','turn_id':'turn-2','text':'fixture result'})
"""
        seeded = subprocess.run([sys.executable, "-c", code, str(self.home)], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        enabled = self.cli("enable-desktop-transport")
        self.assertEqual(enabled.returncode, 0, enabled.stderr)
        self.assertTrue(json.loads(enabled.stdout)["automatic_writes_enabled"])
        config = self.home / "codex-flow/telemetry/desktop-context-transport.json"
        self.assertTrue(json.loads(config.read_text())["enabled"])
        self.disable_telemetry()
        before = self.state_snapshot(self.home / "codex-flow")
        self.assertEqual(json.loads(self.cli("enable-desktop-transport").stdout)["status"], "disabled")
        self.assertEqual(before, self.state_snapshot(self.home / "codex-flow"))

    def test_default_desktop_parent_hook_delivers_without_probe_or_enable(self):
        code = """
import json, sys
from pathlib import Path
from telemetry_core.host_transport import hook_context
home = Path(sys.argv[1])
transcript = home / 'desktop.jsonl'
transcript.write_text(json.dumps({'type': 'session_meta', 'payload': {
    'id': 'chat-a', 'source': 'vscode', 'originator': 'Codex Desktop', 'thread_source': 'user'}}) + '\\n', encoding='utf-8')
for turn_id in ('turn-1', 'turn-2'):
    event = {'hook_event_name': 'UserPromptSubmit', 'session_id': 'chat-a', 'turn_id': turn_id,
             'cwd': str(home), 'transcript_path': str(transcript)}
    output = hook_context(event)
    assert output and output['hookSpecificOutput']['hookEventName'] == 'UserPromptSubmit'
    assert 'additionalContext' in output['hookSpecificOutput']
receipts = list((home / 'codex-flow/telemetry/turn-receipts').glob('*.json'))
assert len(receipts) == 2
assert {(json.loads(path.read_text())['session_id'], json.loads(path.read_text())['turn_id']) for path in receipts} == {
    ('chat-a', 'turn-1'), ('chat-a', 'turn-2')}
assert not (home / 'codex-flow/telemetry/desktop-context-transport.json').exists()
"""
        result = subprocess.run([sys.executable, "-c", code, str(self.home)], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_enable_rejects_damaged_probe_without_writing_transport(self):
        root = self.home / "codex-flow/telemetry"
        root.mkdir(parents=True)
        probe = root / "desktop-context-probe.json"
        for text in ("{broken", "[]", '{"status":"delivered"}'):
            with self.subTest(text=text):
                probe.write_text(text)
                before = self.state_snapshot(root)
                self.assert_error(self.cli("enable-desktop-transport"), "host_transport_unverified")
                self.assertEqual(before, self.state_snapshot(root))

    def test_quiet_recovery_does_not_notify_overlay(self):
        code = """
import sys
from unittest.mock import patch
import telemetry
from telemetry_core.publication import PublicationResult
result = PublicationResult(True, True, 1, True, False, None, {})
with patch.object(telemetry, 'recover_last', return_value=result), patch.object(telemetry, '_notify_overlay_safely') as notify:
    sys.argv = ['telemetry.py', 'recover-last', '--quiet']
    assert telemetry.main() == 0
    notify.assert_not_called()
    sys.argv = ['telemetry.py', 'recover-last']
    assert telemetry.main() == 0
    notify.assert_called_once()
"""
        result = subprocess.run([sys.executable, "-c", code], env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_arguments_return_structured_exit_two(self):
        for args in (
            (), ("unknown",), ("write-goal",),
            ("write-goal", "--receipt-file", "r"),
            ("write-goal", "--receipt-file", "r", "--text-file", "t", "--text-file", "t2"),
            ("write-goal", "--receipt-file", "r", "--text", "inline"),
            ("write-goal", "--receipt-file", "r", "--stdin", "--text-file", "t"),
            ("write-goal", "--receipt-file", "r", "--stdin", "--stdin"),
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
        source = "修复 Unicode 🌏\n保留 '$HOME' 与 `literal`"
        for label, line_ending in (("lf", "\n"), ("crlf", "\r\n")):
            with self.subTest(line_ending=label):
                self.receipt = self.home / f"receipt-{label}.json"
                self.text = self.home / f"goal-{label}.txt"
                self.write_goal_content(source, line_ending=line_ending)
                self.seed(turn_id=f"turn-{label}")
                expected = source.replace("\n", line_ending)

                first = self.cli(*self.goal_args())
                self.assertEqual(first.returncode, 0, first.stderr)
                payload = json.loads(first.stdout)
                self.assertEqual((payload["session_id"], payload["turn_id"]), ("chat-a", f"turn-{label}"))
                self.assertEqual(payload["goal"]["text"], expected)

                state_after_first = self.state_snapshot(self.home / "codex-flow")
                second = self.cli(*self.goal_args())
                self.assertEqual(second.stdout, first.stdout)
                self.assertEqual(self.state_snapshot(self.home / "codex-flow"), state_after_first)

                self.write_goal_content("changed", line_ending=line_ending)
                self.assert_error(self.cli(*self.goal_args()), "goal_conflict")
                self.assertEqual(self.state_snapshot(self.home / "codex-flow"), state_after_first)

    def test_unicode_json_output_is_safe_on_non_utf8_console(self):
        source = "修复 Unicode 🌏\n保留 '$HOME' 与 `literal`"
        for label, line_ending in (("lf", "\n"), ("crlf", "\r\n")):
            with self.subTest(line_ending=label):
                self.receipt = self.home / f"receipt-ascii-{label}.json"
                self.text = self.home / f"goal-ascii-{label}.txt"
                self.write_goal_content(source, line_ending=line_ending)
                self.seed(turn_id=f"ascii-{label}")
                expected = source.replace("\n", line_ending)

                self.env["PYTHONIOENCODING"] = "ascii"
                result = self.cli(*self.goal_args())
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["goal"]["text"], expected)

    def test_empty_overlong_and_invalid_utf8_files(self):
        self.seed()
        for text, code in (("", "goal_empty"), ("字" * 81, "goal_too_long")):
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
            self.assertEqual(json.loads(result.stdout), {
                "ok": False, "status": "disabled", "reason": "telemetry_disabled"
            })
        self.assertFalse((self.home / "codex-flow").exists())

    def test_disabled_repair_preserves_seeded_runs_and_read_only_outputs(self):
        state = self.home / "codex-flow/telemetry"
        runs = state / "runs"
        runs.mkdir(parents=True)
        original = {
            "schema_version": 1, "session_id": "saved-chat", "turn_id": "saved-turn",
            "cwd": "/", "parent": {}, "workers": {}, "started_at_ms": 1000, "finished_at_ms": 2000,
        }
        for path in (runs / "saved-chat--saved-turn.json", state / "last.json"):
            path.write_text(json.dumps(original), encoding="utf-8")
        before = self.state_snapshot(state)
        dry_run_before = self.telemetry_cli("repair", "--dry-run", "--json")
        self.assertEqual(dry_run_before.returncode, 0, dry_run_before.stderr)
        self.assertEqual(json.loads(dry_run_before.stdout)["repaired"], 1)
        self.disable_telemetry()
        result = self.telemetry_cli("repair", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state_snapshot(state), before)
        self.assertEqual(json.loads(result.stdout)["status"], "disabled")
        dry_run_after = self.telemetry_cli("repair", "--dry-run", "--json")
        self.assertEqual(dry_run_after.stdout, dry_run_before.stdout)
        self.assertEqual(dry_run_after.returncode, 0, dry_run_after.stderr)
        historical = self.telemetry_cli("last", "--json")
        self.assertEqual(historical.returncode, 0, historical.stderr)
        self.assertEqual(json.loads(historical.stdout)["session_id"], "saved-chat")
        self.assertEqual(self.state_snapshot(state), before)

    def test_disabled_latency_record_does_not_create_state_or_custom_directory(self):
        self.disable_telemetry()
        for options in ((), ("--state-file", str(self.home / "custom/latency.jsonl"))):
            result = self.telemetry_cli("latency", "record", "--event-json", json.dumps(self.latency_event()), *options)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((self.home / "codex-flow").exists())
            self.assertFalse((self.home / "custom").exists())
            self.assertEqual(json.loads(result.stdout)["status"], "disabled")

    def test_disabled_latency_preserves_existing_directory_and_report(self):
        seeded = self.telemetry_cli("latency", "record", "--event-json", json.dumps(self.latency_event()))
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        state = self.home / "codex-flow/telemetry"
        report_before = self.telemetry_cli("latency", "report", "--json")
        self.assertEqual(report_before.returncode, 0, report_before.stderr)
        # latency report obtains its own short-lived read lock; establish the
        # no-write baseline after that read-only command has completed.
        before = self.state_snapshot(state)
        self.disable_telemetry()
        result = self.telemetry_cli("latency", "record", "--event-json", json.dumps(self.latency_event("blocked-event")))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state_snapshot(state), before)
        self.assertEqual(json.loads(result.stdout)["status"], "disabled")
        report_after = self.telemetry_cli("latency", "report", "--json")
        self.assertEqual(report_after.returncode, 0, report_after.stderr)
        self.assertEqual(json.loads(report_after.stdout), json.loads(report_before.stdout))
        self.assertEqual(self.state_snapshot(state), before)


if __name__ == "__main__":
    unittest.main()
