"""Regression cases found during the full conversation review."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from test_analysis_core import message, transcript_rows, write_jsonl, FakeRunner
from analysis_core.service import AnalysisService
from analysis_core.source import parse_transcript, WRAPPER_KINDS


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "transcript.jsonl"

    def service(self, rows, limit=32000):
        write_jsonl(self.source, transcript_rows(rows=rows))
        service = AnalysisService.configure(self.root / "state", self.source, "session-a", "fake", max_context_chars=limit)
        service.runner = FakeRunner()
        self.addCleanup(service.close)
        return service

    def test_automatic_continuation_and_its_reply_are_not_user_turns(self):
        service = self.service([
            message("u1", "t1", "user", "real request"),
            message("auto", "auto-turn", "user", "Continue", kinds=["goal.internal_context"]),
            message("auto-final", "auto-turn", "assistant", "automated reply", phase="final_answer"),
        ])
        self.assertEqual([t["turn_id"] for t in service.store.snapshot()["turns"]], ["t1"])
        self.assertEqual(service.store.pending_count(), 1)

    def test_mixed_context_preserves_real_user_text_and_literal_quotes(self):
        service = self.service([
            message("u1", "t1", "user", "", kinds=["goal.internal_context", "user.text"], content=[
                {"type": "input_text", "text": "Continue automatically"},
                {"type": "input_text", "text": "Explain goal.internal_context"}]),
            message("f1", "t1", "assistant", "reply", phase="final_answer"),
        ])
        self.assertEqual(service.store.snapshot()["turns"][0]["user_text"], "Explain goal.internal_context")
        self.assertEqual(service.store.snapshot()["turns"][0]["original_result"], "reply")

    def test_existing_import_is_cleaned_without_bulk_backfill_or_late_resurrection(self):
        rows = [message("u1", "t1", "user", "request"),
                message("f1", "t1", "assistant", "good reply", phase="final_answer"),
                message("auto", "auto-turn", "user", "Continue", kinds=["goal.internal_context"]),
                message("auto-final", "auto-turn", "assistant", "automated reply", phase="final_answer"),
                message("u2", "t2", "user", "real followup")]
        # Seed exactly the old parser's import, including an in-flight contaminated job.
        with patch("analysis_core.source.WRAPPER_KINDS", WRAPPER_KINDS - {"goal.internal_context"}):
            service = self.service(rows)
        stale = service.store.claim_job()
        service.analyze_turn("t1")
        snapshot = service.sync()
        self.assertEqual([t["turn_id"] for t in snapshot["turns"]], ["t1", "t2"])
        service.store.complete_job(stale["job_id"], {"text": "must not resurrect"})
        self.assertNotEqual(service.store.snapshot()["turns"][-1]["requirement"]["text"], "must not resurrect")
        service.work()
        count = len(service.runner.calls)
        service.sync()
        service.work()
        self.assertEqual(len(service.runner.calls), count)
        # A genuine new message still queues after ordinal indices shrink.
        rows.append(message("u3", "t3", "user", "next"))
        write_jsonl(self.source, transcript_rows(rows=rows))
        service.sync()
        self.assertEqual(service.store.snapshot()["turns"][-1]["requirement"]["status"], "pending")

    def test_migration_preserves_unaffected_results_and_does_not_backfill_history(self):
        rows = [message("u1", "t1", "user", "request"),
                message("f1", "t1", "assistant", "good reply", phase="final_answer"),
                message("auto", "auto-turn", "user", "Continue", kinds=["goal.internal_context"]),
                message("auto-final", "auto-turn", "assistant", "auto reply", phase="final_answer"),
                message("u2", "t2", "user", "new request")]
        with patch("analysis_core.source.WRAPPER_KINDS", WRAPPER_KINDS - {"goal.internal_context"}):
            service = self.service(rows)
            service.analyze_turn("t1")
            service.work()
        before = service.store.snapshot()["turns"][0]
        count = len(service.runner.calls)
        after = service.sync()["turns"][0]
        self.assertEqual(after["requirement"], before["requirement"])
        self.assertEqual(after["summary"], before["summary"])
        service.work()
        self.assertEqual(len(service.runner.calls) - count, 1)

    def test_migration_does_not_requeue_all_turns_since_original_bootstrap(self):
        rows = [message("u1", "t1", "user", "request"),
                message("auto", "auto-turn", "user", "Continue", kinds=["goal.internal_context"])]
        with patch("analysis_core.source.WRAPPER_KINDS", WRAPPER_KINDS - {"goal.internal_context"}):
            service = self.service(rows)
            for number in range(2, 5):
                rows.append(message("u" + str(number), "t" + str(number), "user", "followup"))
                write_jsonl(self.source, transcript_rows(rows=rows))
                service.sync()
            service.work()
        count = len(service.runner.calls)
        service.sync()
        service.work()
        self.assertEqual(len(service.runner.calls) - count, 1, "Only the latest need should be refreshed automatically")
        self.assertEqual(service.store.snapshot()["turns"][1]["requirement"]["status"], "not_analyzed")

    def test_late_result_cannot_win_if_migration_occurs_during_completion(self):
        rows = [message("auto", "auto-turn", "user", "Continue", kinds=["goal.internal_context"]),
                message("u1", "t1", "user", "request")]
        with patch("analysis_core.source.WRAPPER_KINDS", WRAPPER_KINDS - {"goal.internal_context"}):
            service = self.service(rows)
        stale = service.store.claim_job()
        finish = service.store._set_job_result
        def finish_then_migrate(*args):
            result = finish(*args)
            service.sync()
            return result
        with patch.object(service.store, "_set_job_result", side_effect=finish_then_migrate):
            service.store.complete_job(stale["job_id"], {"text": "stale result"})
        self.assertNotEqual(service.store.snapshot()["turns"][0]["requirement"]["text"], "stale result")
        self.assertEqual(service.store.snapshot()["turns"][0]["requirement"]["status"], "pending")

    def test_upgrade_retires_old_truncated_inputs_without_automatic_context(self):
        service = self.service([message("u1", "t1", "user", "Build email"),
                                message("u2", "t2", "user", "Build calendar instead")])
        service.work()
        job = service.store.jobs_for_turn("t2", "requirement")[0]
        old_input = dict(job["input"])
        old_input["format_version"] = 5
        old_input["coverage"]["truncated"] = True
        old_input["messages"] = old_input["messages"][:1]
        service.store._conn.execute("UPDATE jobs SET input_json=? WHERE job_id=?", (json.dumps(old_input), job["job_id"]))
        service.store._conn.commit()
        snapshot = service.sync()
        self.assertEqual(snapshot["turns"][-1]["requirement"]["status"], "pending")
        self.assertIsNone(snapshot["turns"][-1]["requirement"]["text"])
        service.work()
        self.assertEqual(service.store.snapshot()["turns"][-1]["requirement"]["status"], "succeeded")

    def test_scope_change_survives_long_assistant_history(self):
        service = self.service([
            message("u1", "t1", "user", "Build email"),
            message("u2", "t2", "user", "Cancel email; build calendar instead"),
            message("f2", "t2", "assistant", "x" * 40000, phase="final_answer"),
            message("u3", "t3", "user", "Continue"),
        ])
        job = service.store.jobs_for_turn("t3", "requirement")[0]
        users = [m["text"] for m in job["input"]["messages"] if m["role"] == "user"]
        self.assertEqual(users, ["Build email", "Cancel email; build calendar instead", "Continue"])
        self.assertLessEqual(sum(len(m["text"]) for m in job["input"]["messages"]), 32000)

    def test_summary_input_is_only_the_complete_selected_final(self):
        service = self.service([
            message("u1", "t1", "user", "request"),
            message("f1", "t1", "assistant", "old reply", phase="final_answer"),
            message("u2", "t2", "user", "next"),
            message("f2", "t2", "assistant", "Done but deployment failed", phase="final_answer"),
        ])
        job = service.store.jobs_for_turn("t2", "summary")[0]
        self.assertEqual(job["input"]["messages"], [{"role": "assistant", "turn_id": "t2", "text": "Done but deployment failed"}])

    def test_oversized_final_fails_visibly_without_calling_model(self):
        service = self.service([
            message("u1", "t1", "user", "request"),
            message("f1", "t1", "assistant", "x" * 32000 + "UNRESOLVED deployment failed", phase="final_answer"),
        ])
        service.work()
        turn = service.store.snapshot()["turns"][0]
        self.assertEqual(turn["summary"]["status"], "failed")
        self.assertEqual(turn["summary"]["error"], "context_limit_exceeded")
        self.assertEqual([kind for kind, _ in service.runner.calls], ["requirement"])
        self.assertTrue(turn["original_result"].endswith("UNRESOLVED deployment failed"))
        self.assertEqual(service.store.snapshot()["usage"]["total_calls"], 1)

    def test_user_evidence_overflow_does_not_generate_a_partial_need(self):
        service = self.service([message("u1", "t1", "user", "x" * 100)], limit=40)
        service.work()
        self.assertEqual(service.runner.calls, [])
        turn = service.store.snapshot()["turns"][0]
        self.assertEqual(turn["requirement"]["error"], "context_limit_exceeded")


if __name__ == "__main__":
    unittest.main()
