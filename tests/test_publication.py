"""Observable publication, replay, concurrent writer, and hook contracts."""
from __future__ import annotations

import copy
import importlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from telemetry_core import common
from telemetry_core.turn_context import context_path, receipt_digest, register_receipt
from telemetry_core.turn_context import ReceiptError


def observed(session="chat-a", turn="turn-2"):
    return {"schema_version": 1, "session_id": session, "turn_id": turn, "cwd": "/tmp/project", "started_at_ms": 10,
            "prompt_seen": True, "parent": {"model": "parent", "usage_delta": {"total_tokens": 10}}, "workers": {}}


def final(turn="turn-2"):
    return {"text": "本轮结果\n保持原文", "source": "parent_final", "turn_id": turn, "truncated": False}


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / "state"
        self.addCleanup(patch.stopall)
        patch.object(common, "CODEX_HOME", self.home).start()
        patch.object(common, "LOCK_TIMEOUT", 0.5).start()
        try:
            self.pub = importlib.import_module("telemetry_core.publication")
        except ModuleNotFoundError:
            self.fail("ordered publication is not implemented")

    def stop(self, obs=None, result=None, completed=200):
        obs = observed() if obs is None else obs
        return self.pub.publish_parent_stop(run_key=common.run_key(obs), observed=obs,
            result=final(obs["turn_id"]) if result is None else result,
            completed_at_ms=completed, state_root=self.root)

    def read(self, filename="last.json"):
        return json.loads((self.root / filename).read_text())

    def test_complete_snapshot_seals_context_and_ignores_protected_observations(self):
        receipt = register_receipt({**observed(), "hook_event_name": "UserPromptSubmit"}, state_root=self.root)
        context = {"schema_version": 1, "session_id": "chat-a", "turn_id": "turn-2", "goal": {"text": "真实目标"}, "orchestration": {"execution_plan": {"strategy": "quality"}}}
        common.atomic_json(context_path("chat-a", "turn-2", self.root), context)
        obs = {**observed(), "turn_context": {"goal": "forged"}, "result": {"text": "forged"}, "publication": {"revision": 99}, "receipt_id": "secret"}
        first = self.stop(obs)
        self.assertTrue(first.published and first.changed and first.last_updated and first.notify)
        self.assertEqual(first.revision, 1)
        self.assertEqual(first.snapshot["turn_context"], context)
        self.assertEqual(first.snapshot["result"], final())
        self.assertNotIn("receipt_id", first.snapshot)
        self.assertEqual(first.snapshot, self.read("runs/chat-a--turn-2.json"))
        self.assertEqual(first.snapshot, self.read())
        registry = self.read("turn-receipts/" + receipt_digest("chat-a", "turn-2") + ".json")
        self.assertEqual(registry["state"], "sealed")
        self.assertNotIn(receipt.receipt_id, json.dumps(first.snapshot))

    def test_repeat_is_noop_and_first_completion_is_immutable(self):
        first = self.stop()
        before = (self.root / "last.json").stat().st_mtime_ns
        again = self.stop(completed=999)
        self.assertFalse(again.changed or again.notify or again.last_updated)
        self.assertEqual(again.revision, 1)
        self.assertEqual(again.snapshot["publication"], {"revision": 1, "completed_at_ms": 200})
        self.assertEqual(again.snapshot["finished_at_ms"], 200)
        self.assertEqual(before, (self.root / "last.json").stat().st_mtime_ns)
        self.assertEqual(first.snapshot, again.snapshot)

    def test_stop_without_start_cannot_be_reopened_by_late_prompt(self):
        self.stop()
        with self.assertRaises(ReceiptError) as rejected:
            register_receipt({**observed(), "hook_event_name": "UserPromptSubmit"}, state_root=self.root)
        self.assertEqual(rejected.exception.code, "receipt_expired")

    def test_last_uses_stable_completion_session_turn_order(self):
        for session, turn, completed in (("chat-b", "t2", 200), ("chat-a", "t9", 200), ("chat-b", "t1", 100), ("chat-b", "t3", 200)):
            self.stop(observed(session, turn), completed=completed)
        self.assertEqual((self.read()["session_id"], self.read()["turn_id"]), ("chat-b", "t3"))
        old = self.stop(observed("chat-z", "old"), completed=1)
        self.assertFalse(old.last_updated)
        self.assertTrue(old.notify)

    def test_mismatched_existing_identity_cannot_be_overwritten(self):
        common.atomic_json(self.root / "runs/chat-a--turn-2.json", observed("other", "turn-2"))
        before = (self.root / "runs/chat-a--turn-2.json").read_bytes()
        result = self.stop()
        self.assertEqual(result.reason, "run_identity_mismatch")
        self.assertFalse(result.published)
        self.assertEqual(before, (self.root / "runs/chat-a--turn-2.json").read_bytes())
        self.assertFalse((self.root / "last.json").exists())

    def test_missing_or_wrong_turn_final_does_not_invent_a_result(self):
        result = self.stop(result={"text": "wrong", "source": "parent_final", "turn_id": "another"})
        self.assertNotIn("result", result.snapshot)

    def test_turn_and_global_lock_timeout_do_not_write_or_seal(self):
        register_receipt({**observed(), "hook_event_name": "UserPromptSubmit"}, state_root=self.root)
        for key in ("turn-" + receipt_digest("chat-a", "turn-2"), "global-publication"):
            with common.state_lock(key, state_root=self.root) as acquired:
                self.assertTrue(acquired)
                result = self.stop()
            self.assertEqual(result.reason, "locked")
            self.assertFalse((self.root / "last.json").exists())
            self.assertFalse((self.root / "runs").exists())
        self.assertEqual(self.read("turn-receipts/" + receipt_digest("chat-a", "turn-2") + ".json")["state"], "active")

    def test_crash_after_run_write_recovers_without_completion_notification(self):
        atomic = self.pub.atomic_json
        def crash(path, value):
            if path.name == "last.json":
                raise OSError("simulated crash after run commit")
            atomic(path, value)
        with patch.object(self.pub, "atomic_json", crash):
            with self.assertRaises(OSError):
                self.stop()
        recovered = self.pub.recover_last(state_root=self.root)
        self.assertTrue(recovered.last_updated)
        self.assertFalse(recovered.notify)
        self.assertEqual(self.read()["publication"]["revision"], 1)
        self.assertFalse(self.pub.recover_last(state_root=self.root).last_updated)

    def test_recovery_ignores_unfinished_runs_and_repairs_corrupt_last(self):
        self.stop()
        common.atomic_json(self.root / "runs/unfinished.json", {**observed("new", "t"), "finished_at_ms": 9999})
        (self.root / "last.json").write_text("{")
        result = self.pub.recover_last(state_root=self.root)
        self.assertEqual(result.snapshot["session_id"], "chat-a")
        self.assertFalse(result.notify)

    def test_late_worker_replay_is_idempotent_and_cannot_rollback_newer_last(self):
        self.stop()
        worker = {"agent_id": "w", "turn_id": "child", "executions": {"child": {"turn_id": "child", "status": "completed", "finished_at_ms": 300, "usage": {"total_tokens": 20, "source": "transcript"}}}}
        update = {**observed(), "workers": {"w": worker}, "result": {"text": "forged"}}
        first = self.pub.publish_late_worker(run_key="chat-a--turn-2", observed=update, state_root=self.root)
        self.assertEqual(first.revision, 2)
        self.assertTrue(first.last_updated)
        self.assertFalse(first.notify)
        repeat = self.pub.publish_late_worker(run_key="chat-a--turn-2", observed=update, state_root=self.root)
        self.assertFalse(repeat.changed or repeat.last_updated or repeat.notify)
        self.assertEqual(repeat.snapshot["result"], final())
        self.stop(observed("chat-a", "turn-3"), completed=400)
        update["workers"]["w"]["executions"]["child"]["usage"]["total_tokens"] = 25
        late = self.pub.publish_late_worker(run_key="chat-a--turn-2", observed=update, state_root=self.root)
        self.assertEqual(late.revision, 3)
        self.assertFalse(late.last_updated or late.notify)
        self.assertEqual(self.read()["turn_id"], "turn-3")

    def test_stale_stop_preserves_newer_disk_worker_and_execution_facts(self):
        current = observed()
        current["workers"] = {"w": {"agent_id": "w", "turn_id": "child", "status": "completed", "executions": {"child": {"turn_id": "child", "status": "completed", "finished_at_ms": 300, "service_usage_finalized": True, "usage": {"total_tokens": 80, "source": "transcript"}}}}}
        common.atomic_json(self.root / "runs/chat-a--turn-2.json", current)
        stale = copy.deepcopy(current)
        stale["workers"]["w"]["executions"]["child"].update(status="running", finished_at_ms=100, service_usage_finalized=False, usage={"total_tokens": 2, "source": "app-server"})
        value = self.stop(stale).snapshot["workers"]["w"]["executions"]["child"]
        self.assertEqual(value["status"], "completed")
        self.assertEqual(value["finished_at_ms"], 300)
        self.assertEqual(value["usage"]["total_tokens"], 80)
        self.assertTrue(value["service_usage_finalized"])

    def test_stale_completed_execution_cannot_hide_a_newer_running_execution(self):
        current = observed()
        current["workers"] = {"w": {"agent_id": "w", "turn_id": "new-child", "status": "running", "model": "new-model", "executions": {
            "old-child": {"turn_id": "old-child", "status": "completed", "finished_at_ms": 100, "usage": {"total_tokens": 5}},
            "new-child": {"turn_id": "new-child", "status": "running", "started_at_ms": 300}}}}
        common.atomic_json(self.root / "runs/chat-a--turn-2.json", current)
        stale = observed()
        stale["workers"] = {"w": {"agent_id": "w", "turn_id": "old-child", "status": "completed", "model": "old-model", "executions": {
            "old-child": {"turn_id": "old-child", "status": "completed", "finished_at_ms": 100, "usage": {"total_tokens": 5}}}}}
        worker = self.stop(stale).snapshot["workers"]["w"]
        self.assertEqual(worker["status"], "running")
        self.assertEqual(worker["turn_id"], "new-child")
        self.assertEqual(worker["model"], "new-model")
        self.assertEqual(worker["usage"]["total_tokens"], 5)

    def test_concurrent_chats_and_late_workers_keep_all_facts(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda i: self.stop(observed("chat-" + str(i), "t"), completed=200 + i), range(4)))
        self.assertTrue(all(value.published for value in results))
        self.assertEqual(self.read()["session_id"], "chat-3")
        def update(i):
            obs = observed("chat-3", "t")
            obs["workers"] = {str(i): {"agent_id": str(i), "status": "completed", "usage": {"total_tokens": i + 1}}}
            return self.pub.publish_late_worker(run_key="chat-3--t", observed=obs, state_root=self.root)
        with ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(update, range(4)))
        self.assertTrue(all(value.published for value in results))
        self.assertEqual(len(self.read()["workers"]), 4)
        self.assertEqual(self.read()["publication"]["revision"], 5)

    def test_disabled_guard_leaves_no_files(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n")
        self.assertEqual(self.stop().reason, "disabled")
        self.assertEqual(self.pub.publish_late_worker(run_key="chat-a--turn-2", observed=observed(), state_root=self.root).reason, "disabled")
        self.assertEqual(self.pub.recover_last(state_root=self.root).reason, "disabled")
        self.assertFalse(self.root.exists())

    def test_parent_stop_and_worker_race_preserve_both_publication_and_worker(self):
        update = {**observed(), "workers": {"w": {"agent_id": "w", "turn_id": "child", "status": "completed", "usage": {"total_tokens": 7}}}}
        with ThreadPoolExecutor(max_workers=2) as pool:
            parent = pool.submit(self.stop)
            child = pool.submit(self.pub.publish_late_worker, run_key="chat-a--turn-2", observed=update, state_root=self.root)
            self.assertTrue(parent.result().published)
            self.assertNotEqual(child.result().reason, "locked")
        self.assertEqual(self.read()["workers"]["w"]["usage"]["total_tokens"], 7)
        self.assertEqual(self.read()["result"], final())


class HookPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / "codex-flow/telemetry"
        self.addCleanup(patch.stopall)
        self.telemetry = importlib.import_module("telemetry")
        self.collector = importlib.import_module("telemetry_core.collector")
        self.repair = importlib.import_module("telemetry_core.repair")
        for module in (common, self.telemetry, self.collector, self.repair):
            for key, value in (("CODEX_HOME", self.home), ("STATE_ROOT", self.state), ("RUNS_DIR", self.state / "runs"), ("LAST_FILE", self.state / "last.json"), ("WORKER_INDEX_FILE", self.state / "worker-index.json")):
                if hasattr(module, key):
                    patch.object(module, key, value).start()
        class OfflineServer:
            available = False
            def __enter__(self): return self
            def __exit__(self, *args): pass
        patch.object(self.collector, "AppServer", OfflineServer).start()
        patch.object(self.collector, "find_session_transcript", return_value=None).start()
        patch.object(self.collector, "now_ms", return_value=1789718403000).start()
        patch.object(common, "LOCK_TIMEOUT", 0.06).start()
        self.real_notify = self.collector.notify_overlay_if_active
        self.ipc = patch.object(self.collector, "notify_overlay_if_active").start()
        self.notify = patch.object(self.collector, "send_system_notification").start()
        patch.object(self.collector, "write_stop_output").start()
        self.event = {"hook_event_name": "UserPromptSubmit", "session_id": "chat-a", "turn_id": "turn-2", "cwd": "/tmp/project"}
        fixture = json.loads((ROOT / "tests/fixtures/turn-context/transcript-format.json").read_text())
        transcript = self.home / "parent.jsonl"
        transcript.write_text("\n".join(json.dumps(r) for r in [fixture["parent_metadata"], *fixture["records"]]))
        self.event["transcript_path"] = str(transcript)

    def _overlay_socket(self, expected):
        path = self.home / "codex-flow/overlay.sock"
        path.parent.mkdir(parents=True, exist_ok=True)
        patch.dict(os.environ, {"CODEX_HOME": str(self.home)}).start()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen()
        server.settimeout(0.1)
        commands = []

        def serve():
            deadline = time.monotonic() + 5
            while len(commands) < expected and time.monotonic() < deadline:
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                with connection:
                    commands.append(connection.recv(4096).decode().strip())
                    connection.sendall(b'{"ok": true}\n')

        thread = threading.Thread(target=serve, daemon=True)
        thread.start()

        def wait_for_commands():
            thread.join(5)
            server.close()
            self.assertEqual(len(commands), expected)
            return commands

        return wait_for_commands

    def test_real_socket_first_stop_update_and_late_worker_refresh(self):
        self.collector.collect_hook(self.event)
        worker = {**self.event, "hook_event_name": "SubagentStart", "turn_id": "child", "agent_id": "worker", "agent_type": "worker"}
        self.collector.collect_hook(worker)
        self.ipc.side_effect = self.real_notify
        wait_for_commands = self._overlay_socket(expected=2)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        self.collector.collect_hook({**worker, "hook_event_name": "SubagentStop"})
        self.assertEqual(wait_for_commands(), [
            f"update {(self.state / 'runs/chat-a--turn-2.json').resolve()}",
            "refresh",
        ])

    def test_real_socket_repair_recovery_is_quiet(self):
        self.collector.collect_hook(self.event)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        (self.state / "last.json").unlink()
        self.ipc.side_effect = self.real_notify
        wait_for_commands = self._overlay_socket(expected=1)
        self.repair.repair_history(verbose=False)
        self.assertEqual(wait_for_commands(), ["refresh"])

    def test_real_socket_cli_recovery_is_quiet(self):
        self.collector.collect_hook(self.event)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        (self.state / "last.json").unlink()
        self.ipc.side_effect = self.real_notify
        wait_for_commands = self._overlay_socket(expected=1)
        result = subprocess.run([sys.executable, str(ROOT / "scripts/telemetry.py"), "recover-last"],
            env={**os.environ, "CODEX_HOME": str(self.home), "PYTHONPATH": str(ROOT / "scripts")},
            text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(wait_for_commands(), ["refresh"])

    def test_hooks_publish_once_without_render_or_notification_persistence(self):
        self.collector.collect_hook(self.event)
        self.assertFalse((self.state / "last.json").exists())
        path = self.state / "runs/chat-a--turn-2.json"
        self.assertNotIn("result", json.loads(path.read_text()))
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop", "last_assistant_message": "forged"})
        value = json.loads(path.read_text())
        self.assertEqual(value["result"]["text"], "本轮最终结果")
        self.assertEqual(value["publication"]["completed_at_ms"], 1789718402000)
        self.assertEqual(self.ipc.call_count, 1)
        self.assertEqual(self.notify.call_count, 1)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        self.assertEqual(self.ipc.call_count, 1)
        self.assertEqual(self.notify.call_count, 1)
        before = path.read_bytes(), (self.state / "last.json").read_bytes()
        self.collector.render_summary(value)
        with patch.object(self.telemetry, "telemetry_notifications_enabled", return_value=False):
            self.telemetry._localized_send_system_notification(value)
        self.assertEqual(before, (path.read_bytes(), (self.state / "last.json").read_bytes()))
        self.assertEqual(self.ipc.call_count, 1)

    def test_expensive_stop_reads_are_outside_turn_lock(self):
        self.collector.collect_hook(self.event)
        parent = self
        class CheckingServer:
            available = False
            def __enter__(self):
                with common.state_lock("turn-" + receipt_digest("chat-a", "turn-2"), state_root=parent.state) as acquired:
                    parent.assertTrue(acquired)
                return self
            def __exit__(self, *args): pass
        with patch.object(self.collector, "AppServer", CheckingServer):
            self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})

    def test_disabled_hook_does_not_write_or_notify(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n")
        self.collector.collect_hook(self.event)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        self.assertFalse(self.state.exists())
        self.assertEqual(self.ipc.call_count, 0)
        self.assertEqual(self.notify.call_count, 0)

    def test_recover_last_public_cli_repairs_missing_last(self):
        self.collector.collect_hook(self.event)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        (self.state / "last.json").unlink()
        result = subprocess.run([sys.executable, str(ROOT / "scripts/telemetry.py"), "recover-last", "--json"],
            env={**os.environ, "CODEX_HOME": str(self.home)}, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / "last.json").exists(), result.stdout)
        self.assertTrue(json.loads(result.stdout)["last_updated"])

    def test_repair_rereads_concurrent_worker_and_versions_only_published_runs(self):
        self.collector.collect_hook(self.event)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        path = self.state / "runs/chat-a--turn-2.json"
        before = json.loads(path.read_text())
        unfinished = observed("unfinished", "turn")
        common.atomic_json(self.state / "runs/unfinished--turn.json", unfinished)
        repair_run = self.repair.repair_run
        publication = importlib.import_module("telemetry_core.publication")
        def interleaved(run, **kwargs):
            repair_run(run, **kwargs)
            run["logs"] = [{"message": "recovered evidence"}]
            if run["session_id"] == "chat-a":
                update = {**observed(), "workers": {"w": {"agent_id": "w", "status": "completed", "usage": {"total_tokens": 42}}}}
                publication.publish_late_worker(run_key="chat-a--turn-2", observed=update, state_root=self.state)
            return run
        with patch.object(self.repair, "repair_run", interleaved):
            self.repair.repair_history(verbose=False)
        current = json.loads(path.read_text())
        self.assertEqual(current["workers"]["w"]["usage"]["total_tokens"], 42)
        self.assertEqual(current["result"], before["result"])
        self.assertEqual(current["publication"]["revision"], 3)
        self.assertEqual(json.loads((self.state / "last.json").read_text()), current)
        self.assertNotIn("publication", json.loads((self.state / "runs/unfinished--turn.json").read_text()))
        self.assertEqual(self.notify.call_count, 1)

    def test_late_worker_hook_sends_ipc_only_when_current_and_no_completion_notification(self):
        self.collector.collect_hook(self.event)
        worker = {**self.event, "hook_event_name": "SubagentStart", "turn_id": "child", "agent_id": "worker", "agent_type": "worker"}
        self.collector.collect_hook(worker)
        self.collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        self.collector.collect_hook({**worker, "hook_event_name": "SubagentStop"})
        self.assertEqual(self.ipc.call_count, 2)
        self.assertEqual(self.notify.call_count, 1)
        self.collector.collect_hook({**worker, "hook_event_name": "SubagentStop"})
        self.assertEqual(self.ipc.call_count, 2)
        self.assertEqual(self.notify.call_count, 1)
        next_turn = {**self.event, "turn_id": "turn-3"}
        self.collector.collect_hook(next_turn)
        self.collector.collect_hook({**next_turn, "hook_event_name": "Stop"})
        self.assertEqual(self.ipc.call_count, 3)
        self.assertEqual(self.notify.call_count, 2)
        self.collector.collect_hook({**worker, "hook_event_name": "SubagentStop", "last_assistant_message": "late worker evidence"})
        self.assertEqual(self.ipc.call_count, 3)
        self.assertEqual(self.notify.call_count, 2)
        old = json.loads((self.state / "runs/chat-a--turn-2.json").read_text())
        self.assertEqual(old["workers"]["worker"]["conclusion"], "late worker evidence")

    def test_maintenance_cannot_delete_published_files_while_global_lock_is_held(self):
        old = {**observed(), "finished_at_ms": 1, "publication": {"revision": 1, "completed_at_ms": 1}}
        path = self.state / "runs/chat-a--turn-2.json"
        common.atomic_json(path, old)
        common.atomic_json(self.state / "last.json", old)
        with common.state_lock("global-publication", state_root=self.state) as acquired:
            self.assertTrue(acquired)
            self.collector.run_maintenance()
        self.assertTrue(path.exists())
        self.assertTrue((self.state / "last.json").exists())


if __name__ == "__main__":
    unittest.main()
