from __future__ import annotations

import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from analysis_core.model import CodexExecRunner, ModelError


class FakeProcess:
    def __init__(self, stdout, returncode=0, stderr=b""):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode
        self.input = None
        self.killed = False

    def communicate(self, input=None, timeout=None):
        self.input = input
        return self.stdout, self.stderr

    def kill(self):
        self.killed = True

    def wait(self):
        return self.returncode


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.calls = []
        self.process = None

    def fake_popen(self, argv, **kwargs):
        self.calls.append((argv, kwargs))
        self.process = FakeProcess(b'{"text":"need","caveats":[]}', 0)
        return self.process

    def test_runner_uses_isolated_read_only_exec_and_validates_schema(self):
        auth = self.root / "auth"
        auth.mkdir()
        (auth / "auth.json").write_text('{"token":"secret"}', encoding="utf-8")
        (auth / "models_cache.json").write_text('{"models":[]}', encoding="utf-8")
        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            auth_home=auth,
            codex_bin="codex",
            process_factory=self.fake_popen,
        )

        result = runner.run("requirement", "untrusted transcript")

        self.assertEqual(result["text"], "need")
        argv, kwargs = self.calls[0]
        self.assertEqual(argv[:3], ["codex", "exec", "--ephemeral"])
        for item in ("--ignore-user-config", "--sandbox", "read-only", "--json", "--output-schema",
                     "--thread-source", "background-analysis", "--skip-git-repo-check", "--cd", "--model", "gpt-test", "-"):
            self.assertIn(item, argv)
        self.assertIn("features.hooks=false", argv)
        self.assertIn("features.plugins=false", argv)
        self.assertIn("features.skip_host_skill_discovery=true", argv)
        self.assertIn('web_search="disabled"', argv)
        self.assertIn('model_reasoning_effort="low"', argv)
        self.assertEqual(kwargs["env"]["CODEX_HOME"], str((self.root / "state" / "private" / "codex-home").resolve()))
        self.assertEqual(self.process.input, "untrusted transcript")
        self.assertTrue((self.root / "state" / "private" / "codex-home" / "auth.json").exists())
        self.assertTrue((self.root / "state" / "private" / "codex-home" / "models_cache.json").exists())
        self.assertEqual(stat.S_IMODE((self.root / "state" / "private" / "codex-home" / "auth.json").stat().st_mode), 0o600)

    def test_runner_rejects_invalid_json_and_sanitizes_error(self):
        def invalid(argv, **kwargs):
            self.calls.append((argv, kwargs))
            return FakeProcess(b'{"markdown": 3}', 0, b"secret-token\nraw transcript")

        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            process_factory=invalid,
        )
        with self.assertRaises(ModelError) as raised:
            runner.run("requirement", "prompt")
        self.assertEqual(raised.exception.code, "invalid_output")
        self.assertNotIn("secret-token", str(raised.exception))
        self.assertNotIn("raw transcript", str(raised.exception))

    def test_runner_rejects_nonzero_process_without_echoing_stdout(self):
        def failed(argv, **kwargs):
            return FakeProcess(b'{"text":"leak"}', 9, b"secret-token")

        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            process_factory=failed,
        )
        with self.assertRaises(ModelError) as raised:
            runner.run("summary", "prompt")
        self.assertEqual(raised.exception.code, "process_failed")
        self.assertNotIn("leak", str(raised.exception))
        self.assertNotIn("secret-token", str(raised.exception))

    def test_runner_accepts_codex_json_event_with_structured_agent_message(self):
        def event_process(argv, **kwargs):
            payload = {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps({"text": "event result", "caveats": []})}}
            return FakeProcess(json.dumps(payload).encode("utf-8"), 0)

        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            process_factory=event_process,
        )

        self.assertEqual(runner.run("summary", "prompt")["text"], "event result")

    def test_runner_kills_timed_out_process_and_hides_output(self):
        class TimeoutProcess(FakeProcess):
            def communicate(self, input=None, timeout=None):
                raise subprocess.TimeoutExpired(["codex"], timeout)

        processes = []

        def timeout_process(argv, **kwargs):
            process = TimeoutProcess(b"private transcript", 0)
            processes.append(process)
            return process

        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            process_factory=timeout_process,
            timeout=0.001,
        )
        with self.assertRaises(ModelError) as raised:
            runner.run("summary", "prompt")
        self.assertEqual(raised.exception.code, "timeout")
        self.assertTrue(processes[0].killed)

    def test_runner_reaps_child_when_shutdown_interrupts_communication(self):
        class InterruptProcess(FakeProcess):
            def communicate(self, input=None, timeout=None):
                raise KeyboardInterrupt()

        processes = []

        def interrupt_process(argv, **kwargs):
            process = InterruptProcess(b"private transcript", 0)
            processes.append(process)
            return process

        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            process_factory=interrupt_process,
        )
        with self.assertRaises(KeyboardInterrupt):
            runner.run("summary", "prompt")
        self.assertTrue(processes[0].killed)

    def test_runner_interrupt_kills_real_fake_sleep_child(self):
        fake = self.root / "sleep-codex.py"
        fake.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n", encoding="utf-8")
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        runner = CodexExecRunner(
            state_dir=self.root / "state",
            model="gpt-test",
            codex_bin=str(fake),
            timeout=30,
        )
        prior = signal.getsignal(signal.SIGINT)
        signal.signal(signal.SIGINT, lambda _signum, _frame: (_ for _ in ()).throw(KeyboardInterrupt()))
        timer = threading.Timer(0.1, lambda: os.kill(os.getpid(), signal.SIGINT))
        started = time.monotonic()
        timer.start()
        try:
            with self.assertRaises(KeyboardInterrupt):
                runner.run("summary", "prompt")
        finally:
            timer.cancel()
            signal.signal(signal.SIGINT, prior)
        self.assertLess(time.monotonic() - started, 3.0)

    def test_cli_configure_sync_work_and_status_use_durable_fake_exec(self):
        transcript = self.root / "transcript.jsonl"
        rows = [
            {"type": "session_meta", "payload": {"id": "session-a", "source": "vscode", "originator": "Codex Desktop", "thread_source": "user"}},
            {"type": "response_item", "payload": {"type": "message", "role": "user", "id": "u1", "content": [{"type": "input_text", "text": "request"}], "internal_chat_message_metadata_passthrough": {"turn_id": "turn-1", "create_time": 1, "content_item_kinds": ["user.text"]}}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant", "phase": "final_answer", "id": "f1", "content": [{"type": "output_text", "text": "final"}], "internal_chat_message_metadata_passthrough": {"turn_id": "turn-1", "create_time": 2, "content_item_kinds": ["assistant.text"]}}},
        ]
        transcript.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
        fake = self.root / "fake-codex.py"
        fake.write_text(
            "#!/usr/bin/env python3\n"
            "import json,sys\n"
            "kind='skill' if any('skill.json' in x for x in sys.argv) else ('summary' if any('summary.json' in x for x in sys.argv) else 'requirement')\n"
            "print(json.dumps({'text': kind+' result','caveats':[]} if kind != 'skill' else {'name':'x','description':'y','markdown':'# x','caveats':[]}))\n",
            encoding="utf-8",
        )
        fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
        script = ROOT / "scripts" / "analysis.py"
        state = self.root / "state"
        configure = subprocess.run(
            [sys.executable, str(script), "configure", "--state-dir", str(state), "--transcript", str(transcript), "--session-id", "session-a", "--model", "fake", "--codex-bin", str(fake)],
            capture_output=True, text=True,
        )
        self.assertEqual(configure.returncode, 0, configure.stderr)
        first = subprocess.run([sys.executable, str(script), "work", "--state-dir", str(state), "--once"], capture_output=True, text=True)
        second = subprocess.run([sys.executable, str(script), "work", "--state-dir", str(state), "--once"], capture_output=True, text=True)
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        status = json.loads(subprocess.run([sys.executable, str(script), "status", "--state-dir", str(state)], capture_output=True, text=True).stdout)
        self.assertEqual([turn["requirement"]["status"] for turn in status["turns"]], ["succeeded"])
        self.assertEqual(status["usage"]["total_calls"], 2)


if __name__ == "__main__":
    unittest.main()
