"""Turn binding and sidecar writes; these fixtures do not prove host transport."""
from __future__ import annotations

import importlib
import json
import sys
import tempfile
import unittest
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import asdict, replace
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from telemetry_core import common, collector
from strategy_runtime import TaskProfile, compile_plan

try:
    context = importlib.import_module("telemetry_core.turn_context")
except ModuleNotFoundError:
    context = None


class TurnContextTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(context, "turn_context implementation is missing")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / "state"
        self.policy = self.home / "codex-flow.toml"
        self.addCleanup(patch.stopall)
        patch.object(common, "CODEX_HOME", self.home).start()
        self.event = {"hook_event_name": "UserPromptSubmit", "session_id": "chat-a", "turn_id": "turn-2"}

    def register(self, **overrides):
        return context.register_receipt({**self.event, **overrides}, state_root=self.state)

    def receipt_file(self, receipt=None, name="receipt.json"):
        path = self.home / name
        path.write_text(json.dumps(asdict(receipt or self.register())), encoding="utf-8")
        return path

    def text_file(self, text, name="text.txt"):
        path = self.home / name
        # Keep the fixture's code points and newline bytes unchanged on
        # Windows; text-mode writes would silently translate LF to CRLF.
        path.write_bytes(text.encode("utf-8"))
        return path

    def plan_file(self, plan=None, name="plan.json"):
        path = self.home / name
        path.write_text(json.dumps(plan if plan is not None else self.plan(), ensure_ascii=False), encoding="utf-8")
        return path

    def plan(self, route="delegate"):
        return compile_plan(TaskProfile(), routing_mode=route).to_dict()

    def transcript_rows(self, session_id="chat-a"):
        fixture = json.loads((ROOT / "tests/fixtures/turn-context/transcript-format.json").read_text())
        parent = deepcopy(fixture["parent_metadata"])
        parent["payload"]["id"] = session_id
        return [parent, *deepcopy(fixture["records"])]

    def transcript_file(self, session_id="chat-a", rows=None, name="transcript.jsonl"):
        path = self.home / name
        path.write_text(
            "\n".join(json.dumps(row, ensure_ascii=False) for row in (rows or self.transcript_rows(session_id))) + "\n",
            encoding="utf-8",
        )
        return path

    def assert_code(self, code, function, *args, **kwargs):
        with self.assertRaises(context.ReceiptError) as raised:
            function(*args, **kwargs)
        self.assertEqual(raised.exception.code, code)

    def validate(self, receipt):
        with common.state_lock("turn-" + context.receipt_digest(receipt.session_id, receipt.turn_id), state_root=self.state) as acquired:
            self.assertTrue(acquired)
            return context.validate_receipt(receipt, state_root=self.state)

    def test_receipt_digest_separates_turns_and_unsafe_path_strings(self):
        self.assertNotEqual(context.receipt_digest("chat-a", "turn-2"), context.receipt_digest("chat-a", "turn-3"))
        self.assertNotEqual(context.receipt_digest("a/b", "c"), context.receipt_digest("a", "b/c"))
        path = context.context_path("../会话", "../../轮次", self.state)
        self.assertEqual(path.parent, self.state / "turn-context")
        self.assertRegex(path.name, r"^[0-9a-f]{64}\.json$")
        self.assertFalse(self.state.exists())

    def test_duplicate_submit_returns_same_random_receipt(self):
        receipt = self.register()
        self.assertEqual(receipt, self.register())
        self.assertNotEqual(receipt.receipt_id, self.register(turn_id="turn-3").receipt_id)
        self.assertEqual(context.load_receipt(self.receipt_file(receipt)), receipt)
        self.validate(receipt)

    def test_receipt_rejects_missing_invalid_and_child_fields(self):
        original = asdict(self.register())
        for field in ("session_id", "turn_id", "receipt_id"):
            for bad in (None, "", "  ", 3, "nul\x00id", "\ud800"):
                data = {**original, field: bad}
                path = self.home / "bad.json"
                path.write_text(json.dumps(data), encoding="utf-8")
                self.assert_code("receipt_invalid", context.load_receipt, path)
        for version in (0, 2, True, "1"):
            path = self.home / "bad.json"
            path.write_text(json.dumps({**original, "schema_version": version}), encoding="utf-8")
            self.assert_code("receipt_invalid", context.load_receipt, path)
        path.write_text(json.dumps({**original, "role": "worker"}), encoding="utf-8")
        self.assert_code("receipt_role_forbidden", context.load_receipt, path)
        self.assert_code("receipt_missing", context.load_receipt, self.home / "absent.json")

    def test_load_only_parses_but_validate_checks_hook_registration(self):
        receipt = context.load_receipt(self.receipt_file())
        self.assert_code("receipt_expired", self.validate, replace(receipt, receipt_id="unknown"))
        self.assert_code("receipt_expired", self.validate, replace(receipt, session_id="other-chat"))
        self.assert_code("receipt_expired", self.validate, replace(receipt, turn_id="other-turn"))
        path = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        data = json.loads(path.read_text())
        data["turn_id"] = "wrong-turn"
        path.write_text(json.dumps(data), encoding="utf-8")
        self.assert_code("receipt_mismatch", self.validate, receipt)

    def test_stop_seals_receipt_and_submit_cannot_reopen_it(self):
        receipt = self.register()
        with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2"), state_root=self.state) as acquired:
            self.assertTrue(acquired)
            context.seal_receipt(receipt, state_root=self.state)
            context.seal_receipt(receipt, state_root=self.state)
        self.assert_code("receipt_expired", self.validate, receipt)
        self.assert_code("receipt_expired", self.register)

    def test_parent_abort_rejects_late_goal_write_and_seals_receipt(self):
        transcript = self.transcript_file()
        receipt = self.register(turn_id="turn-3", transcript_path=str(transcript))
        receipt_file = self.receipt_file(receipt)
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-3") + ".json")
        self.assertEqual(json.loads(registry.read_text())["transcript_path"], str(transcript))
        self.assertNotIn("transcript_path", asdict(receipt))
        self.assert_code(
            "receipt_expired", context.write_goal,
            receipt_file=receipt_file, text_file=self.text_file("迟到目标"), state_root=self.state,
        )
        self.assertIsNone(context.load_context("chat-a", "turn-3", self.state))
        self.assertEqual(json.loads(registry.read_text())["state"], "sealed")
        transcript.unlink()
        self.assert_code(
            "receipt_expired", context.write_goal,
            receipt_file=receipt_file, text_file=self.text_file("再次迟到"), state_root=self.state,
        )

    def test_parent_abort_rejects_late_plan_write_without_creating_context(self):
        transcript = self.transcript_file()
        receipt = self.register(turn_id="turn-3", transcript_path=str(transcript))
        receipt_file = self.receipt_file(receipt)
        self.assert_code(
            "receipt_expired", context.write_plan,
            receipt_file=receipt_file, plan_file=self.plan_file(), origin="compiled", state_root=self.state,
        )
        self.assertIsNone(context.load_context("chat-a", "turn-3", self.state))
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-3") + ".json")
        self.assertEqual(json.loads(registry.read_text())["state"], "sealed")

    def test_abort_proof_ignores_missing_malformed_other_turn_session_and_child_transcripts(self):
        child_rows = self.transcript_rows("chat-child")
        child_abort = next(
            row for row in child_rows
            if row.get("payload", {}).get("type") == "turn_aborted"
        )
        child_abort["agent_id"] = "child"
        child_abort["payload"].update({
            "agent_id": "child", "thread_source": "subagent",
            "source": {"subagent": {"thread_spawn": {"parent_thread_id": "chat-child"}}},
        })
        malformed = self.home / "malformed.jsonl"
        malformed.write_text("{broken\n", encoding="utf-8")
        cases = [
            ("missing", "chat-missing", "turn-3", self.home / "missing.jsonl"),
            ("malformed", "chat-malformed", "turn-3", malformed),
            ("other-session", "chat-other", "turn-3", self.transcript_file("chat-transcript", name="other-session.jsonl")),
            ("other-turn", "chat-other-turn", "turn-2", self.transcript_file("chat-other-turn", name="other-turn.jsonl")),
            ("child", "chat-child", "turn-3", self.transcript_file("chat-child", child_rows, "child.jsonl")),
        ]
        for label, session_id, turn_id, transcript in cases:
            with self.subTest(label=label):
                receipt = self.register(
                    session_id=session_id, turn_id=turn_id, transcript_path=str(transcript),
                )
                saved = context.write_goal(
                    receipt_file=self.receipt_file(receipt, name=label + "-receipt.json"),
                    text_file=self.text_file(label, name=label + ".txt"), state_root=self.state,
                )
                self.assertEqual(saved["goal"]["text"], label)
                self.assertNotIn("transcript_path", json.dumps(saved))

    def test_abort_in_new_turn_does_not_change_prior_turn_goal(self):
        transcript = self.transcript_file()
        prior = self.register(transcript_path=str(transcript))
        prior_file = self.receipt_file(prior, name="prior-receipt.json")
        self.assertEqual(
            context.write_goal(
                receipt_file=prior_file, text_file=self.text_file("保留目标", name="prior.txt"), state_root=self.state,
            )["goal"]["text"],
            "保留目标",
        )
        next_receipt = self.register(turn_id="turn-3", transcript_path=str(transcript))
        self.assert_code(
            "receipt_expired", context.write_goal,
            receipt_file=self.receipt_file(next_receipt, name="next-receipt.json"),
            text_file=self.text_file("新目标", name="next.txt"), state_root=self.state,
        )
        self.assertEqual(context.load_context("chat-a", "turn-2", self.state)["goal"]["text"], "保留目标")
        self.validate(prior)

    def test_preflight_reads_abort_transcript_before_taking_turn_lock(self):
        transcript = self.transcript_file()
        receipt = self.register(transcript_path=str(transcript))
        receipt_file = self.receipt_file(receipt)
        original_lock = context.state_lock
        original_open = Path.open
        lock_held = False
        transcript_reads = []

        @contextmanager
        def tracking_lock(*args, **kwargs):
            nonlocal lock_held
            with original_lock(*args, **kwargs) as acquired:
                if acquired:
                    lock_held = True
                try:
                    yield acquired
                finally:
                    lock_held = False

        def track_open(candidate, *args, **kwargs):
            if candidate == transcript:
                transcript_reads.append(lock_held)
            return original_open(candidate, *args, **kwargs)

        with patch.object(context, "state_lock", tracking_lock), \
                patch.object(Path, "open", autospec=True, side_effect=track_open):
            context.write_goal(
                receipt_file=receipt_file, text_file=self.text_file("顺序目标"), state_root=self.state,
            )
        self.assertEqual(transcript_reads, [False])

    def test_preflight_uses_exact_run_transcript_for_legacy_receipt(self):
        transcript = self.transcript_file()
        receipt = self.register(turn_id="turn-3")
        runs = self.state / "runs"
        runs.mkdir()
        (runs / "chat-a--turn-3.json").write_text(json.dumps({
            "session_id": "chat-a", "turn_id": "turn-3", "transcript_path": str(transcript),
        }), encoding="utf-8")
        self.assert_code(
            "receipt_expired", context.write_goal,
            receipt_file=self.receipt_file(receipt), text_file=self.text_file("遗留目标"), state_root=self.state,
        )
        self.assertIsNone(context.load_context("chat-a", "turn-3", self.state))

    def test_aborted_late_writes_preserve_existing_goal_and_plan_bytes(self):
        rows = [row for row in self.transcript_rows() if row.get("payload", {}).get("type") != "turn_aborted"]
        transcript = self.transcript_file(rows=rows)
        receipt = self.register(turn_id="turn-3", transcript_path=str(transcript))
        receipt_file = self.receipt_file(receipt)
        goal_file = self.text_file("原始目标", name="original-goal.txt")
        plan_file = self.plan_file(name="original-plan.json")
        context.write_goal(receipt_file=receipt_file, text_file=goal_file, state_root=self.state)
        context.write_plan(receipt_file=receipt_file, plan_file=plan_file, origin="compiled", state_root=self.state)
        sidecar = context.context_path("chat-a", "turn-3", self.state)
        before = sidecar.read_bytes()

        self.transcript_file(rows=self.transcript_rows(), name="transcript.jsonl")
        self.assert_code("receipt_expired", context.write_goal,
                         receipt_file=receipt_file, text_file=goal_file, state_root=self.state)
        self.assert_code("receipt_expired", context.write_plan,
                         receipt_file=receipt_file, plan_file=plan_file, origin="compiled", state_root=self.state)
        self.assertEqual(sidecar.read_bytes(), before)

    def test_transcript_change_between_abort_check_and_write_rejects_stale_proof(self):
        for action, aborted in (("goal", True), ("plan", True), ("goal", False)):
            with self.subTest(action=action, aborted=aborted):
                session_id = "race-" + action + str(aborted)
                rows = [row for row in self.transcript_rows(session_id)
                        if row.get("payload", {}).get("type") != "turn_aborted"]
                transcript = self.transcript_file(session_id, rows, action + ".jsonl")
                receipt = self.register(session_id=session_id, turn_id="turn-3", transcript_path=str(transcript))
                kwargs = {"receipt_file": self.receipt_file(receipt), "state_root": self.state}
                if action == "goal":
                    writer = context.write_goal
                    kwargs["text_file"] = self.text_file("迟到目标")
                else:
                    writer = context.write_plan
                    kwargs.update(plan_file=self.plan_file(), origin="compiled")
                scan = context.parent_turn_aborted

                def scan_then_append(*args, **kw):
                    result = scan(*args, **kw)
                    with transcript.open("a") as stream:
                        stream.write(json.dumps({"type": "event_msg", "payload": {
                            "type": "turn_aborted" if aborted else "task_started", "turn_id": "turn-3",
                        }}) + "\n")
                    return result

                with patch.object(context, "parent_turn_aborted", side_effect=scan_then_append):
                    self.assert_code("locked", writer, **kwargs)
                self.assertIsNone(context.load_context(session_id, "turn-3", self.state))
                if aborted:
                    self.assert_code("receipt_expired", writer, **kwargs)
                    self.assert_code("receipt_expired", self.validate, receipt)
                else:
                    writer(**kwargs)
                    self.validate(receipt)

    def test_retention_seals_receipt_before_removing_its_run(self):
        receipt = self.register()
        runs = self.state / "runs"
        runs.mkdir()
        run_path = runs / "chat-a--turn-2.json"
        run_path.write_text(json.dumps({
            "session_id": "chat-a", "turn_id": "turn-2",
            "started_at_ms": common.now_ms() - 31 * 86_400_000,
        }), encoding="utf-8")
        sidecar = context.context_path("chat-a", "turn-2", self.state)
        common.atomic_json(sidecar, {
            "schema_version": 1, "session_id": "chat-a", "turn_id": "turn-2",
            "goal": {"text": "过期目标", "source": "flow-pilot", "recorded_at_ms": 1},
        })
        fresh_run = runs / "chat-a--turn-fresh.json"
        fresh_run.write_text(json.dumps({
            "session_id": "chat-a", "turn_id": "turn-fresh",
            "started_at_ms": common.now_ms(),
        }), encoding="utf-8")
        fresh_sidecar = context.context_path("chat-a", "turn-fresh", self.state)
        common.atomic_json(fresh_sidecar, {
            "schema_version": 1, "session_id": "chat-a", "turn_id": "turn-fresh",
            "goal": {"text": "新鲜目标", "source": "flow-pilot", "recorded_at_ms": 1},
        })
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", runs), \
                patch.object(collector, "LAST_FILE", self.state / "last.json"), \
                patch.object(collector, "WORKER_INDEX_FILE", self.state / "worker-index.json"):
            collector.run_maintenance()
        self.assertFalse(run_path.exists())
        self.assertFalse(sidecar.exists())
        self.assertTrue(fresh_run.exists())
        self.assertTrue(fresh_sidecar.exists())
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        self.assertEqual(json.loads(registry.read_text()), {"schema_version": 1, "state": "sealed"})
        self.assert_code("receipt_expired", self.validate, receipt)
        self.assert_code("receipt_expired", self.register)

    def test_maintenance_compacts_legacy_orphan_receipt(self):
        receipt = self.register(transcript_path="/private/old/transcript.jsonl")
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        value = json.loads(registry.read_text())
        value["state"] = "sealed"
        common.atomic_json(registry, value)
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", self.state / "runs"), patch.object(collector, "LAST_FILE", self.state / "last.json"), patch.object(collector, "WORKER_INDEX_FILE", self.state / "worker-index.json"):
            collector.run_maintenance()
        self.assertEqual(json.loads(registry.read_text()), {"schema_version": 1, "state": "sealed"})
        self.assert_code("receipt_expired", self.validate, receipt)
        self.assert_code("receipt_expired", self.register)

    def test_retention_keeps_run_when_context_sidecar_cannot_be_removed(self):
        receipt = self.register()
        runs = self.state / "runs"
        runs.mkdir()
        run_path = runs / "chat-a--turn-2.json"
        run_path.write_text(json.dumps({
            "session_id": "chat-a", "turn_id": "turn-2",
            "started_at_ms": common.now_ms() - 31 * 86_400_000,
        }), encoding="utf-8")
        sidecar = context.context_path("chat-a", "turn-2", self.state)
        common.atomic_json(sidecar, {
            "schema_version": 1, "session_id": "chat-a", "turn_id": "turn-2",
            "goal": {"text": "稍后重试", "source": "flow-pilot", "recorded_at_ms": 1},
        })
        original_unlink = Path.unlink

        def unlink(candidate, *args, **kwargs):
            if candidate == sidecar:
                raise OSError("sidecar busy")
            return original_unlink(candidate, *args, **kwargs)

        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", runs), \
                patch.object(collector, "LAST_FILE", self.state / "last.json"), \
                patch.object(collector, "WORKER_INDEX_FILE", self.state / "worker-index.json"), \
                patch.object(Path, "unlink", autospec=True, side_effect=unlink):
            collector.run_maintenance()
        self.assertTrue(run_path.exists())
        self.assertTrue(sidecar.exists())
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        self.assertEqual(json.loads(registry.read_text()), {"schema_version": 1, "state": "sealed"})
        self.assert_code("receipt_expired", self.validate, receipt)
        self.assert_code("receipt_expired", self.register)

    def test_submit_racing_stop_does_not_write_after_receipt_is_sealed(self):
        original = context.register_receipt

        def register_then_stop(event, **kwargs):
            receipt = original(event, **kwargs)
            with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2"), state_root=self.state):
                context.seal_receipt(receipt, state_root=self.state)
            return receipt

        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", self.state / "runs"), \
                patch.object(collector, "register_receipt", side_effect=register_then_stop), \
                patch.object(collector, "AppServer", side_effect=AssertionError("sealed submit reached app-server")):
            collector.collect_hook(self.event)
        self.assertFalse((self.state / "runs").exists())

    def test_parent_stop_waits_for_turn_lock_before_sealing(self):
        receipt = self.receipt_file()
        context.write_goal(receipt_file=receipt, text_file=self.text_file("本轮目标"), state_root=self.state)
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        sidecar = context.context_path("chat-a", "turn-2", self.state)
        before = registry.read_bytes(), sidecar.read_bytes()
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", self.state / "runs"), \
                patch.object(common, "LOCK_TIMEOUT", 0.02), patch.object(collector, "AppServer") as server, \
                patch.object(collector, "notify_overlay_if_active") as ipc, \
                patch.object(collector, "send_system_notification") as notify:
            # Expensive observation is deliberately outside the publication lock.
            server.return_value.__enter__.return_value.available = False
            with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2")) as acquired:
                self.assertTrue(acquired)
                collector.collect_hook({**self.event, "hook_event_name": "Stop"})
            ipc.assert_not_called()
            notify.assert_not_called()
        self.assertEqual(before, (registry.read_bytes(), sidecar.read_bytes()))
        self.assertFalse((self.state / "runs").exists())

    def test_parent_submit_waits_for_turn_lock_before_registering(self):
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "LOCK_TIMEOUT", 0.02), \
                patch.object(collector, "AppServer", side_effect=AssertionError("parent bypassed worker lock")):
            with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2")) as acquired:
                self.assertTrue(acquired)
                collector.collect_hook(self.event)
        self.assertFalse((self.state / "turn-receipts").exists())
        self.assertFalse((self.state / "runs").exists())

    def test_child_hook_and_missing_ids_never_register_receipts(self):
        for extra in ({"hook_event_name": "SubagentStart"}, {"agent_id": "child"}, {"role": "worker"}):
            self.assert_code("receipt_role_forbidden", self.register, **extra)
        for key in ("session_id", "turn_id"):
            self.assert_code("receipt_missing", self.register, **{key: None})
        self.assertFalse(self.state.exists())

    def test_goal_is_exact_immutable_and_unicode_codepoint_limited(self):
        receipt = self.receipt_file()
        text = '目标：保留 "$HOME"、`command` 和\n第二行 🌏'
        goal = self.text_file(text)
        result = context.write_goal(receipt_file=receipt, text_file=goal, state_root=self.state, clock=lambda: 123)
        self.assertEqual(result["goal"], {"text": text, "source": "flow-pilot", "recorded_at_ms": 123})
        target = context.context_path("chat-a", "turn-2", self.state)
        before = target.read_bytes(), target.stat().st_mtime_ns
        context.write_goal(receipt_file=receipt, text_file=goal, state_root=self.state, clock=lambda: 999)
        self.assertEqual(before, (target.read_bytes(), target.stat().st_mtime_ns))
        self.assert_code("goal_conflict", context.write_goal, receipt_file=receipt, text_file=self.text_file("别的目标"), state_root=self.state)
        self.assertEqual(before, (target.read_bytes(), target.stat().st_mtime_ns))
        for bad, code in (("", "goal_empty"), (" \n", "goal_empty"), ("🌏" * 81, "goal_too_long")):
            self.assert_code(code, context.write_goal, receipt_file=receipt, text_file=self.text_file(bad), state_root=self.state)
        for index, text in enumerate(("🌏", "🌏" * 80)):
            r = self.receipt_file(self.register(turn_id="unicode-" + str(index)))
            saved = context.write_goal(receipt_file=r, text_file=self.text_file(text), state_root=self.state)
            self.assertEqual(saved["goal"]["text"], text)

    def test_goal_rejects_three_sentences_before_creating_context(self):
        for index, text in enumerate(("一句。二句。三句。", "One. Two! Three?", "一句。二句。还有半句")):
            r = self.receipt_file(self.register(turn_id="sentences-" + str(index)))
            self.assert_code("goal_too_many_sentences", context.write_goal,
                             receipt_file=r, text_file=self.text_file(text), state_root=self.state)
            self.assertIsNone(context.load_context("chat-a", "sentences-" + str(index), self.state))

    def test_goal_accepts_two_sentences_and_decimal_version(self):
        for index, text in enumerate(("一句。二句！", "Fix v2.1. Keep tests.", "完成了吗？！验证通过。")):
            r = self.receipt_file(self.register(turn_id="short-" + str(index)))
            saved = context.write_goal(receipt_file=r, text_file=self.text_file(text), state_root=self.state)
            self.assertEqual(saved["goal"]["text"], text)

    def test_utf8_goal_preserves_crlf_codepoints(self):
        goal = self.home / "crlf.txt"
        goal.write_bytes("第一行\r\n第二行\r\n".encode("utf-8"))
        saved = context.write_goal(receipt_file=self.receipt_file(), text_file=goal, state_root=self.state)
        self.assertEqual(saved["goal"]["text"], "第一行\r\n第二行\r\n")

    def test_unregistered_receipt_does_not_create_any_state_directory(self):
        receipt = context.TurnReceipt(1, "unknown-chat", "unknown-turn", "unregistered-secret", "parent")
        self.assert_code("receipt_expired", context.write_goal, receipt_file=self.receipt_file(receipt),
                         text_file=self.text_file("目标"), state_root=self.state)
        self.assertFalse(self.state.exists())

    def test_plan_persists_full_object_and_only_content_changes_revision(self):
        receipt = self.receipt_file()
        plan = self.plan()
        plan["extra_metadata"] = {"说明": "preserve original JSON"}
        path = self.plan_file(plan)
        result = context.write_plan(receipt_file=receipt, plan_file=path, origin="compiled", state_root=self.state, clock=lambda: 123)
        self.assertEqual(result["orchestration"]["execution_plan"], plan)
        self.assertEqual(result["orchestration"]["revision"], 1)
        target = context.context_path("chat-a", "turn-2", self.state)
        before = target.read_bytes(), target.stat().st_mtime_ns
        path.write_text(json.dumps(plan, sort_keys=True, indent=3), encoding="utf-8")
        context.write_plan(receipt_file=receipt, plan_file=path, origin="reused", state_root=self.state, clock=lambda: 999)
        self.assertEqual(before, (target.read_bytes(), target.stat().st_mtime_ns))
        plan["notes"].append("changed scope")
        result = context.write_plan(receipt_file=receipt, plan_file=self.plan_file(plan), origin="replanned", state_root=self.state, clock=lambda: 456)
        self.assertEqual(result["orchestration"]["revision"], 2)
        self.assertEqual(result["orchestration"]["origin"], "replanned")
        self.assertEqual(result["orchestration"]["recorded_at_ms"], 456)

    def test_complete_execution_plan_validation(self):
        for strategy in ("efficient", "balanced", "quality", "speed"):
            for route in ("direct", "delegate"):
                plan = compile_plan(TaskProfile(), strategy=strategy, routing_mode=route).to_dict()
                self.assertEqual(context.validate_execution_plan(plan), plan)
        for invalid in (None, [], {"schema_version": 11}):
            self.assert_code("invalid_execution_plan", context.validate_execution_plan, invalid)
        mutations = [
            ("schema_version", 10), ("schema_version", 11.0), ("routing", "adaptive"),
            ("strategy", "unknown"), ("parent_reasoning", "none"),
            ("implementation_workers", True), ("planned_worker_count", 99),
            ("notes", "not a list"), ("escalate_on_failure", 1),
            ("task_budget", None), ("context_mode", "anything"),
        ]
        for field, bad in mutations:
            plan = self.plan()
            plan[field] = bad
            with self.subTest(field=field, bad=bad):
                self.assert_code("invalid_execution_plan", context.validate_execution_plan, plan)
        for section, field, bad in (
            ("worker_budget", "max_implementers", True),
            ("worker_budget", "speculation", "unknown"),
            ("implementation_stage", "fallback_policy", "unknown"),
            ("implementation_stage", "cancel_if_superseded", "true"),
            ("implementation_stage", "maximum_work_units", 999),
            ("task_budget", "soft_timeout_seconds", -1),
            ("task_budget", "hard_timeout_seconds", 1),
            ("task_budget", "max_implementation_attempts", 0),
            ("reasoning_rollout", "mode", "invalid"),
        ):
            plan = deepcopy(self.plan())
            plan[section][field] = bad
            with self.subTest(section=section, field=field):
                self.assert_code("invalid_execution_plan", context.validate_execution_plan, plan)
        for field in self.plan():
            plan = self.plan()
            del plan[field]
            self.assert_code("invalid_execution_plan", context.validate_execution_plan, plan)
        direct = self.plan("direct")
        direct["implementation_stage"] = self.plan()["implementation_stage"]
        self.assert_code("invalid_execution_plan", context.validate_execution_plan, direct)

    def test_execution_plan_accepts_inherited_parent_model(self):
        plan = compile_plan(TaskProfile(quality_intent="strong"), strategy="quality", routing_mode="delegate").to_dict()
        self.assertIsNone(plan["implementer_model"])
        self.assertIsNone(plan["reviewer_model"])
        self.assertEqual(context.validate_execution_plan(plan), plan)
        for field, value in (("parent_model_floor", "explicit-model"),
                             ("implementer_capability_policy", "other-capability")):
            invalid = deepcopy(plan)
            invalid[field] = value
            with self.subTest(field=field):
                self.assert_code("invalid_execution_plan", context.validate_execution_plan, invalid)

    def test_concurrent_goal_and_plan_merge_without_lost_updates(self):
        receipt = self.receipt_file()
        goal, plan = self.text_file("并发目标"), self.plan_file()
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(context.write_goal, receipt_file=receipt, text_file=goal, state_root=self.state),
                pool.submit(context.write_plan, receipt_file=receipt, plan_file=plan, origin="compiled", state_root=self.state),
            ]
            for future in futures:
                future.result()
        saved = context.load_context("chat-a", "turn-2", self.state)
        self.assertEqual(saved["goal"]["text"], "并发目标")
        self.assertEqual(saved["orchestration"]["revision"], 1)
        self.assertNotIn("receipt_id", json.dumps(saved))

    def test_locked_writer_and_expired_receipt_do_not_create_sidecar(self):
        receipt = self.receipt_file()
        goal = self.text_file("目标")
        with patch.object(common, "LOCK_TIMEOUT", 0.02):
            with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2"), state_root=self.state):
                self.assert_code("locked", context.write_goal, receipt_file=receipt, text_file=goal, state_root=self.state)
        loaded = context.load_receipt(receipt)
        with common.state_lock("turn-" + context.receipt_digest("chat-a", "turn-2"), state_root=self.state):
            context.seal_receipt(loaded, state_root=self.state)
        self.assert_code("receipt_expired", context.write_goal, receipt_file=receipt, text_file=goal, state_root=self.state)
        self.assertFalse(context.context_path("chat-a", "turn-2", self.state).exists())

    def test_disabled_entry_points_create_no_telemetry_state(self):
        self.policy.write_text("[telemetry]\nenabled=false\n", encoding="utf-8")
        self.assertIsNone(self.register())
        for writer, kwargs in (
            (context.write_goal, {"text_file": self.home / "absent.txt"}),
            (context.write_plan, {"plan_file": self.home / "absent.json", "origin": "compiled"}),
        ):
            result = writer(receipt_file=self.home / "absent-receipt.json", state_root=self.state, **kwargs)
            self.assertEqual(result["status"], "disabled")
        with patch.object(collector, "AppServer", side_effect=AssertionError("disabled hook reached app-server")):
            for kind in ("UserPromptSubmit", "Stop", "SubagentStart", "SubagentStop"):
                collector.collect_hook({**self.event, "hook_event_name": kind})
        self.assertFalse(self.state.exists())
        self.assertFalse((self.home / "codex-flow").exists())


if __name__ == "__main__":
    unittest.main()
