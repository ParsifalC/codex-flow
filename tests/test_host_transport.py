import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from telemetry_core import host_transport


class DesktopProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.transcript = self.root / "transcript.jsonl"
        self.transcript.write_text(json.dumps({"type": "session_meta", "payload": {
            "id": "chat", "source": "vscode", "originator": "Codex Desktop", "thread_source": "user"
        }}) + "\n")
        self.event = {"hook_event_name": "UserPromptSubmit", "session_id": "chat", "turn_id": "one",
                      "cwd": str(self.root), "transcript_path": str(self.transcript)}
        self.guard = patch("telemetry_core.host_transport.telemetry_writes_enabled", return_value=True)
        self.guard.start(); self.addCleanup(self.guard.stop)
        self.receipt_guard = patch("telemetry_core.turn_context.telemetry_writes_enabled", return_value=True)
        self.receipt_guard.start(); self.addCleanup(self.receipt_guard.stop)

    def arm(self):
        host_transport.arm_probe(session_id="chat", cwd=str(self.root), state_root=self.root, clock=lambda: 100)

    def test_default_is_silent_and_read_only(self):
        before = set(self.root.iterdir())
        self.assertIsNone(host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: 101))
        self.assertEqual(before, set(self.root.iterdir()))

    def test_one_exact_parent_turn_only_and_no_receipt_secret_in_output(self):
        self.arm()
        output = host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: 101)
        self.assertEqual(output["hookSpecificOutput"]["hookEventName"], "UserPromptSubmit")
        self.assertNotIn("systemMessage", output)
        receipt = json.loads(next((self.root / "turn-receipts").iterdir()).read_text())
        self.assertNotIn(receipt["receipt_id"], json.dumps(output))
        self.assertIsNone(host_transport.probe_hook_context({**self.event, "turn_id": "two"}, state_root=self.root, clock=lambda: 102))
        self.assertEqual(output, host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: 102))

    def test_wrong_chat_child_and_expired_probe_are_silent(self):
        self.arm()
        for event in [{**self.event, "session_id": "other"}, {**self.event, "agent_id": "child"},
                      {**self.event, "cwd": "/different"}, {**self.event, "hook_event_name": "SubagentStart"}]:
            self.assertIsNone(host_transport.probe_hook_context(event, state_root=self.root, clock=lambda: 101))
        self.assertIsNone(host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: 10**12))
        self.assertFalse((self.root / "turn-receipts").exists())

    def test_disabled_does_not_arm_or_deliver(self):
        with patch("telemetry_core.host_transport.telemetry_writes_enabled", return_value=False):
            before = set(self.root.iterdir())
            self.assertEqual(host_transport.arm_probe(session_id="chat", cwd=str(self.root), state_root=self.root)["status"], "disabled")
            self.assertIsNone(host_transport.probe_hook_context(self.event, state_root=self.root))
            self.assertEqual(before, set(self.root.iterdir()))

    def test_cli_metadata_does_not_prove_desktop(self):
        self.arm()
        self.transcript.write_text(json.dumps({"type": "session_meta", "payload": {"id": "chat", "source": "cli"}}))
        self.assertIsNone(host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: 101))

    def test_expired_probe_status_is_read_only_and_not_supported(self):
        self.arm()
        path = self.root / host_transport.PROBE_FILE
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        status = host_transport.probe_status(state_root=self.root, clock=lambda: 10**12)
        self.assertEqual(status["status"], "expired")
        self.assertFalse(status["automatic_writes_enabled"])
        self.assertFalse(status["goal_plan_stop_chain_verified"])
        self.assertEqual((path.read_bytes(), path.stat().st_mtime_ns), before)

    def test_explicit_wait_survives_delay_but_still_accepts_only_one_turn(self):
        host_transport.arm_probe(session_id="chat", cwd=str(self.root), state_root=self.root,
                                 clock=lambda: 100, wait_for_next_turn=True)
        tomorrow = 86400100
        self.assertEqual(host_transport.probe_status(state_root=self.root, clock=lambda: tomorrow)["status"], "armed")
        self.assertIsNotNone(host_transport.probe_hook_context(self.event, state_root=self.root, clock=lambda: tomorrow))
        self.assertIsNone(host_transport.probe_hook_context({**self.event, "turn_id": "two"},
                                                          state_root=self.root, clock=lambda: tomorrow + 1))
        self.assertFalse(host_transport.probe_status(state_root=self.root)["automatic_writes_enabled"])


if __name__ == "__main__":
    unittest.main()
