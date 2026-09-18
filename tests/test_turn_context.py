"""Turn binding and sidecar writes; these fixtures do not prove host transport."""
from __future__ import annotations

import importlib
import json
import sys
import tempfile
import unittest
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
        path.write_text(text, encoding="utf-8")
        return path

    def plan_file(self, plan=None, name="plan.json"):
        path = self.home / name
        path.write_text(json.dumps(plan if plan is not None else self.plan(), ensure_ascii=False), encoding="utf-8")
        return path

    def plan(self, route="delegate"):
        return compile_plan(TaskProfile(), routing_mode=route).to_dict()

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

    def test_retention_seals_receipt_before_removing_its_run(self):
        receipt = self.register()
        runs = self.state / "runs"
        runs.mkdir()
        run_path = runs / "chat-a--turn-2.json"
        run_path.write_text(json.dumps({
            "session_id": "chat-a", "turn_id": "turn-2",
            "started_at_ms": common.now_ms() - 31 * 86_400_000,
        }), encoding="utf-8")
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "RUNS_DIR", runs), \
                patch.object(collector, "LAST_FILE", self.state / "last.json"), \
                patch.object(collector, "WORKER_INDEX_FILE", self.state / "worker-index.json"):
            collector.run_maintenance()
        self.assertFalse(run_path.exists())
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

    def test_parent_stop_waits_for_legacy_worker_lock_before_sealing(self):
        receipt = self.receipt_file()
        context.write_goal(receipt_file=receipt, text_file=self.text_file("本轮目标"), state_root=self.state)
        registry = self.state / "turn-receipts" / (context.receipt_digest("chat-a", "turn-2") + ".json")
        sidecar = context.context_path("chat-a", "turn-2", self.state)
        before = registry.read_bytes(), sidecar.read_bytes()
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "LOCK_TIMEOUT", 0.02), \
                patch.object(collector, "AppServer", side_effect=AssertionError("parent bypassed worker lock")):
            with common.state_lock("chat-a--turn-2") as acquired:
                self.assertTrue(acquired)
                collector.collect_hook({**self.event, "hook_event_name": "Stop"})
        self.assertEqual(before, (registry.read_bytes(), sidecar.read_bytes()))
        self.assertFalse((self.state / "runs").exists())

    def test_parent_submit_waits_for_legacy_worker_lock_before_registering(self):
        with patch.object(common, "STATE_ROOT", self.state), patch.object(common, "LOCK_TIMEOUT", 0.02), \
                patch.object(collector, "AppServer", side_effect=AssertionError("parent bypassed worker lock")):
            with common.state_lock("chat-a--turn-2") as acquired:
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
        for bad, code in (("", "goal_empty"), (" \n", "goal_empty"), ("🌏" * 401, "goal_too_long")):
            self.assert_code(code, context.write_goal, receipt_file=receipt, text_file=self.text_file(bad), state_root=self.state)
        for index, text in enumerate(("🌏", "🌏" * 400)):
            r = self.receipt_file(self.register(turn_id="unicode-" + str(index)))
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
