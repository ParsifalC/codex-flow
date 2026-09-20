"""Shared telemetry entry points preserve historical state when disabled."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class TelemetryWriteGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / "codex-flow/telemetry"
        self.env = {
            **os.environ,
            "CODEX_HOME": str(self.home),
            "PYTHONPATH": str(ROOT / "scripts"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "CODEX_FLOW_LANGUAGE": "en",
        }
        self.env.pop("CODEX_FLOW_LATENCY_FILE", None)

    def disable_telemetry(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n", encoding="utf-8")

    def snapshot(self):
        return {
            str(path.relative_to(self.home)): (
                path.read_bytes() if path.is_file() else None,
                path.stat().st_mtime_ns,
            )
            for path in [self.home, *self.home.rglob("*")]
        }

    def python(self, code, *args, stdin=None):
        result = subprocess.run(
            [sys.executable, "-c", code, *args],
            input=stdin, env=self.env, text=True, encoding="utf-8", capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def repair(self, dry_run=False):
        result = self.python(
            "import json, sys\n"
            "from telemetry_core.repair import repair_history\n"
            "print(json.dumps(repair_history(dry_run=json.loads(sys.argv[1]), verbose=False)))",
            json.dumps(dry_run),
        )
        return json.loads(result.stdout)

    def seed_run(self):
        runs = self.state / "runs"
        runs.mkdir(parents=True)
        run = {
            "schema_version": 1, "session_id": "saved-chat", "turn_id": "saved-turn",
            "cwd": "/", "parent": {}, "workers": {}, "started_at_ms": 1000, "finished_at_ms": 2000,
        }
        for path in (runs / "saved-chat--saved-turn.json", self.state / "last.json"):
            path.write_text(json.dumps(run), encoding="utf-8")

    def event(self, event_id="guard-event"):
        return {
            "event_id": event_id, "task_id": "guard-task", "worker_id": "guard-worker",
            "strategy": "efficient", "task_class": "routine", "stage": "implementation",
            "role": "implementer", "model": "gpt-5.6-luna", "rollout_mode": "shadow",
            "legacy_effort": "xhigh", "proposed_effort": "high", "selected_effort": "xhigh",
            "observed_effort": None, "boundary": "terminal", "outcome": "completed",
            "started_at": 1000, "finished_at": 1004, "repair_count": 0, "checkpoint_count": 0,
        }

    def record(self, event_id="guard-event", **paths):
        result = self.python(
            "import json, sys\n"
            "from telemetry_core.latency import record_latency_event\n"
            "print(json.dumps(record_latency_event(json.loads(sys.argv[1]), **json.loads(sys.argv[2]))))",
            json.dumps(self.event(event_id)), json.dumps(paths),
        )
        return json.loads(result.stdout)

    def report(self, state_file=None, cli=False):
        if cli:
            args = [sys.executable, str(ROOT / "scripts/telemetry.py"), "latency", "report", "--json"]
            if state_file is not None:
                args.extend(["--state-file", str(state_file)])
            result = subprocess.run(args, env=self.env, text=True, encoding="utf-8", capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            result = self.python(
                "import json, sys\n"
                "from telemetry_core.latency import latency_report\n"
                "print(json.dumps(latency_report(state_file=json.loads(sys.argv[1]))))",
                json.dumps(state_file),
            )
        return json.loads(result.stdout)

    def test_disabled_direct_repair_preserves_absent_and_seeded_state(self):
        self.disable_telemetry()
        before = self.snapshot()
        self.assertEqual(self.repair()["repaired"], 0)
        self.assertEqual(self.snapshot(), before)
        self.seed_run()
        before = self.snapshot()
        self.assertEqual(self.repair()["repaired"], 0)
        self.assertEqual(self.snapshot(), before)

    def test_disabled_menu_repair_preserves_seeded_state(self):
        self.seed_run()
        self.disable_telemetry()
        before = self.snapshot()
        result = self.python("import menu\nmenu.handle_repair_history()", stdin="2\n\n")
        self.assertEqual(self.snapshot(), before)
        self.assertIn("Telemetry is disabled", result.stdout)

    def test_disabled_repair_dry_run_preserves_historical_report(self):
        self.seed_run()
        expected = self.repair(dry_run=True)
        self.assertEqual(expected["scanned"], 1)
        self.assertEqual(expected["repaired"], 1)
        self.disable_telemetry()
        before = self.snapshot()
        self.assertEqual(self.repair(dry_run=True), expected)
        self.assertEqual(self.snapshot(), before)

    def test_enabled_repair_still_updates_run_and_last(self):
        self.seed_run()
        self.assertEqual(self.repair()["repaired"], 1)
        for path in (self.state / "runs/saved-chat--saved-turn.json", self.state / "last.json"):
            self.assertTrue(json.loads(path.read_text(encoding="utf-8"))["is_system_task"])
        self.assertEqual(self.repair()["repaired"], 0)

    def test_disabled_direct_latency_record_creates_no_state_or_sidecars(self):
        self.disable_telemetry()
        before = self.snapshot()
        for paths in (
            {},
            {
                "state_file": str(self.home / "custom/latency.jsonl"),
                "salt_file": str(self.home / "salts/.latency-salt"),
                "lock_file": str(self.home / "locks/.latency.lock"),
            },
        ):
            with self.subTest(paths=paths):
                result = self.record(**paths)
                self.assertEqual(self.snapshot(), before)
                self.assertEqual(result, {"status": "disabled"})

    def test_disabled_latency_report_creates_no_default_or_custom_directory(self):
        self.disable_telemetry()
        before = self.snapshot()
        for cli in (False, True):
            for path in (None, str(self.home / "custom/latency.jsonl")):
                with self.subTest(cli=cli, state_file=path):
                    report = self.report(path, cli=cli)
                    self.assertEqual(report["n"], 0)
                    self.assertEqual(report["groups"], [])
                    self.assertIsNone(report["p50_seconds"])
                    self.assertEqual(self.snapshot(), before)

    def test_disabled_direct_latency_record_preserves_existing_state(self):
        self.assertTrue(self.record()["recorded"])
        self.disable_telemetry()
        before = self.snapshot()
        result = self.record("blocked-event")
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(result, {"status": "disabled"})

    def test_disabled_latency_report_preserves_directory_metadata_and_existing_lock(self):
        self.assertTrue(self.record()["recorded"])
        expected = self.report()
        self.assertEqual(expected["n"], 1)
        self.assertEqual(expected["p95_seconds"], 4)
        self.disable_telemetry()
        lock = self.state / ".latency.lock"
        for existing_lock in (False, True):
            if existing_lock:
                lock.write_text("existing stale lock\n", encoding="ascii")
                os.utime(lock, (1, 1))
            before = self.snapshot()
            for cli in (False, True):
                with self.subTest(existing_lock=existing_lock, cli=cli):
                    self.assertEqual(self.report(cli=cli), expected)
                    self.assertEqual(self.snapshot(), before)

    def test_enabled_latency_record_deduplicates_and_reports(self):
        self.assertTrue(self.record()["recorded"])
        self.assertTrue(self.record()["deduplicated"])
        self.assertTrue(self.record("second-event")["recorded"])
        report = self.report()
        self.assertEqual(report["n"], 2)
        self.assertEqual(report["success"], 2)
        self.assertEqual(report["p50_seconds"], 4)
        self.assertEqual(self.report(cli=True), report)


if __name__ == "__main__":
    unittest.main()
