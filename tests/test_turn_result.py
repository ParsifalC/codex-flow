"""Parent/session/turn proof must precede result extraction."""
from __future__ import annotations

import copy
import importlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from telemetry_core.app_server import extract_transcript_insights
from telemetry_core import render


class TurnResultTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "transcript.jsonl"
        fixture = json.loads((ROOT / "tests/fixtures/turn-context/transcript-format.json").read_text())
        self.records = [fixture["parent_metadata"], *fixture["records"]]
        self.worker_metadata = fixture["worker_metadata"]

    def extract(self, records=None, turn_id="turn-2", session_id="chat-a", **kwargs):
        try:
            module = importlib.import_module("telemetry_core.turn_result")
        except ModuleNotFoundError:
            self.fail("strict parent final extractor is not implemented")
        self.path.write_text("\n".join(json.dumps(row, ensure_ascii=False) for row in (records or self.records)) + "\n")
        before = self.path.read_bytes()
        result = module.extract_parent_final(str(self.path), turn_id, session_id=session_id, **kwargs)
        self.assertEqual(self.path.read_bytes(), before)
        return result

    def test_exact_turn_ignores_old_next_commentary_worker_and_extra_user(self):
        self.assertEqual(self.extract(), {"text": "本轮最终结果", "source": "parent_final", "turn_id": "turn-2", "truncated": False})
        self.assertEqual(self.extract(turn_id="turn-1")["text"], "旧轮结果")
        self.assertEqual(self.extract(turn_id="turn-3")["text"], "下一轮结果")

    def test_missing_turn_session_or_parent_proof_returns_none(self):
        for kwargs in ({"turn_id": None}, {"turn_id": "absent"}, {"session_id": "other"}):
            with self.subTest(kwargs=kwargs):
                self.assertIsNone(self.extract(**kwargs))
        for metadata in (None, self.worker_metadata, {"type": "session_meta", "payload": {"id": "chat-a"}}):
            records = copy.deepcopy(self.records)
            records = ([metadata] if metadata else []) + records[1:]
            self.assertIsNone(self.extract(records))

    def test_missing_final_has_no_last_assistant_or_user_fallback(self):
        records = [r for r in self.records if r.get("payload", {}).get("phase") != "final_answer"]
        self.assertIsNone(self.extract(records))
        records = copy.deepcopy(self.records)
        for row in records:
            if row.get("payload", {}).get("phase") == "final_answer":
                row["payload"]["phase"] = "final"
        self.assertIsNone(self.extract(records))

    def test_boundaries_clear_implicit_turn_and_explicit_id_wins(self):
        final = copy.deepcopy(self.records[11])
        records = self.records[:1] + [self.records[4], self.records[12], final]
        self.assertIsNone(self.extract(records))
        final["payload"]["turn_id"] = "turn-2"
        self.assertEqual(self.extract(records)["text"], "本轮最终结果")
        final["payload"]["turn_id"] = "turn-other"
        self.assertIsNone(self.extract(records))

    def test_parent_terminal_for_another_turn_clears_stale_implicit_boundary(self):
        records = [
            self.records[0],
            {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-2"}},
            {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "turn-3"}},
            {"type": "response_item", "payload": {
                "type": "message", "role": "assistant", "phase": "final_answer",
                "content": [{"type": "output_text", "text": "错误归属"}],
            }},
        ]
        self.assertIsNone(self.extract(records))

    def test_child_turn_boundaries_never_set_or_clear_parent_association(self):
        child_start = {
            "type": "event_msg", "agent_id": "worker",
            "payload": {
                "type": "task_started", "turn_id": "turn-2", "agent_id": "worker",
                "thread_source": "subagent", "source": {"subagent": {}},
            },
        }
        child_only = [self.records[0], child_start, {
            "type": "response_item", "payload": {
                "type": "message", "role": "assistant", "phase": "final_answer",
                "content": [{"type": "output_text", "text": "子任务错误归属"}],
            },
        }]
        self.assertIsNone(self.extract(child_only))

        parent_start = {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "turn-2"}}
        child_terminal = {
            "type": "event_msg", "agent_id": "worker",
            "payload": {
                "type": "task_complete", "turn_id": "turn-3", "agent_id": "worker",
                "thread_source": "subagent", "source": {"subagent": {}},
            },
        }
        parent_final = {
            "type": "response_item", "payload": {
                "type": "message", "role": "assistant", "phase": "final_answer",
                "content": [{"type": "output_text", "text": "父任务归属"}],
            },
        }
        self.assertEqual(self.extract([self.records[0], parent_start, child_terminal, parent_final])["text"], "父任务归属")

    def test_conflicting_parent_metadata_fails_closed(self):
        records = self.records + [self.worker_metadata]
        self.assertIsNone(self.extract(records))

    def test_source_text_and_explicit_truncation_are_preserved(self):
        records = copy.deepcopy(self.records)
        records[11]["payload"]["content"] = [{"type": "output_text", "text": " 第一段\n"}, {"type": "output_text", "text": "第二段 "}]
        expected = " 第一段\n第二段 "
        self.assertEqual(self.extract(records)["text"], expected)
        short = self.extract(records, max_chars=3)
        self.assertEqual(short["text"], expected[:3])
        self.assertTrue(short["truncated"])
        records[11]["payload"]["truncated"] = True
        self.assertTrue(self.extract(records)["truncated"])

    def test_insights_keep_tools_without_guessing_goal_or_conclusion(self):
        self.path.write_text("\n".join(json.dumps(row) for row in self.records))
        insights = extract_transcript_insights(str(self.path), "turn-2")
        self.assertFalse((insights.get("summary_info") or {}).get("goal"))
        self.assertFalse((insights.get("summary_info") or {}).get("conclusion"))

    def test_terminal_summary_uses_published_parent_result_not_legacy_conclusion(self):
        run = {"session_id": "chat-a", "turn_id": "turn-2", "parent": {}, "workers": {},
               "publication": {"revision": 1, "completed_at_ms": 2},
               "summary_info": {"conclusion": "旧推断结论"},
               "result": {"source": "parent_final", "turn_id": "turn-2", "text": "本轮真实结果"}}
        with patch.object(render, "LANG", "zh"):
            text = render.render_summary(run)
            self.assertIn("本轮真实结果", text)
            self.assertNotIn("旧推断结论", text)
            self.assertNotIn("交付结论", text)
            for invalid in ({"source": "worker"}, {"turn_id": "turn-1"}):
                candidate = {**run, "result": {**run["result"], **invalid}}
                self.assertNotIn("本轮真实结果", render.render_summary(candidate))
            del run["publication"]
            self.assertNotIn("本轮真实结果", render.render_summary(run))


if __name__ == "__main__":
    unittest.main()
