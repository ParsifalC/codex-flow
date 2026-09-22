from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from analysis_core.source import SourceError, parse_transcript
from analysis_core.store import AnalysisStore
from analysis_core.service import AnalysisService


def metadata(turn_id, kinds, create_time=1):
    return {
        "turn_id": turn_id,
        "create_time": create_time,
        "content_item_kinds": kinds,
    }


def message(message_id, turn_id, role, text, *, phase=None, kinds=None, create_time=1,
            agent_id=None, content=None):
    blocks = content or [{"type": "input_text" if role == "user" else "output_text", "text": text}]
    payload = {
        "type": "message",
        "id": message_id,
        "role": role,
        "content": blocks,
        "internal_chat_message_metadata_passthrough": metadata(
            turn_id, kinds or (["user.text"] if role == "user" else ["assistant.text"]), create_time
        ),
    }
    if phase is not None:
        payload["phase"] = phase
    if agent_id is not None:
        payload["agent_id"] = agent_id
    return {"type": "response_item", "payload": payload}


def transcript_rows(session_id="session-a", rows=()):
    return [
        {
            "type": "session_meta",
            "payload": {
                "id": session_id,
                "source": "vscode",
                "originator": "Codex Desktop",
                "thread_source": "user",
            },
        },
        *rows,
    ]


def write_jsonl(path, rows, trailing=b"\n"):
    path.write_bytes(
        b"\n".join(json.dumps(row, ensure_ascii=False).encode("utf-8") for row in rows)
        + trailing
    )


class TranscriptSourceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_source_keeps_distinct_same_text_ids_and_filters_wrappers(self):
        rows = transcript_rows(
            rows=(
                message(
                    "msg-1", "turn-1", "user", "context\nreal request", kinds=[
                        "environments.environment_context", "user.text"
                    ], content=[
                        {"type": "input_text", "text": "context"},
                        {"type": "input_text", "text": "real request"},
                    ],
                ),
                message("msg-2", "turn-1", "user", "same", create_time=2),
                message("msg-3", "turn-1", "user", "same", create_time=3),
                message("msg-worker", "turn-1", "assistant", "worker", phase="final_answer", agent_id="child"),
                message("msg-final", "turn-1", "assistant", "parent result", phase="final_answer"),
            )
        )
        path = self.root / "transcript.jsonl"
        write_jsonl(path, rows)

        parsed = parse_transcript(path, "session-a")

        self.assertEqual([item.message_id for item in parsed.messages], ["msg-1", "msg-2", "msg-3", "msg-final"])
        self.assertEqual([item.text for item in parsed.user_messages], ["real request", "same", "same"])
        self.assertEqual(parsed.turns[0].user_text, "same")
        self.assertEqual(parsed.turns[0].original_result, "parent result")
        self.assertEqual(parsed.turns[0].final_message_id, "msg-final")
        self.assertEqual(parsed.coverage["status"], "complete")

    def test_source_preserves_question_reply_and_partial_tail(self):
        rows = transcript_rows(
            rows=(
                message(
                    "reply-1", "turn-1", "user", "<send_user_message_question_reply>\n[{\"question\":\"q1\",\"answer\":\"yes\"}]\n</send_user_message_question_reply>",
                    kinds=["user.text"],
                ),
                {
                    "type": "response_item",
                    "payload": {
                        "type": "message",
                        "role": "user",
                        "id": "reply-2",
                        "content": [{"type": "input_text", "text": "<send_user_message_question_reply>\n[{\"question\":\"q1\",\"answer\":\"yes\"}]\n</send_user_message_question_reply>"}],
                        "internal_chat_message_metadata_passthrough": metadata("turn-1", ["user.text"], 2),
                    },
                },
                message("msg-final", "turn-1", "assistant", "done", phase="final_answer"),
            )
        )
        path = self.root / "partial.jsonl"
        write_jsonl(path, rows, trailing=b"\n{" + b'"type":"response_item"')

        parsed = parse_transcript(path, "session-a")

        self.assertEqual(parsed.user_messages[0].text, "问题：q1\n回答：yes")
        self.assertEqual(parsed.user_messages[1].text, "问题：q1\n回答：yes")
        self.assertEqual(parsed.turns[0].user_text, "问题：q1\n回答：yes")
        self.assertEqual(parsed.coverage["status"], "partial")
        self.assertTrue(parsed.coverage["truncated"])

    def test_source_rejects_unverified_identity_without_id(self):
        row = message("msg-1", "turn-1", "user", "hello")
        del row["payload"]["id"]
        path = self.root / "missing-id.jsonl"
        write_jsonl(path, transcript_rows(rows=(row,)))

        with self.assertRaises(SourceError) as raised:
            parse_transcript(path, "session-a")

        self.assertEqual(raised.exception.code, "missing_message_id")

    def test_source_rejects_child_session_and_wrong_session(self):
        path = self.root / "child.jsonl"
        write_jsonl(path, [
            {
                "type": "session_meta",
                "payload": {
                    "id": "session-a",
                    "source": {"subagent": {"thread_spawn": {"parent_thread_id": "p"}}},
                    "originator": "Codex Desktop",
                    "thread_source": "subagent",
                },
            }
        ])
        with self.assertRaises(SourceError) as raised:
            parse_transcript(path, "session-a")
        self.assertEqual(raised.exception.code, "child_source")


class DurableStoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = AnalysisStore(self.root, "session-a")
        self.addCleanup(self.store.close)

    def test_job_key_is_idempotent_but_same_text_ids_are_distinct(self):
        first = self.store.enqueue_job(
            "requirement", "msg-1", "turn-1", 1, {"messages": ["same"]}
        )
        duplicate = self.store.enqueue_job(
            "requirement", "msg-1", "turn-1", 1, {"messages": ["same"]}
        )
        second = self.store.enqueue_job(
            "requirement", "msg-2", "turn-1", 2, {"messages": ["same"]}
        )
        self.assertEqual(first["job_id"], duplicate["job_id"])
        self.assertNotEqual(first["job_id"], second["job_id"])
        self.assertEqual(self.store.pending_count(), 2)

    def test_claim_and_complete_keeps_late_old_result_from_rolling_back_latest(self):
        old = self.store.enqueue_job("requirement", "old", "turn-1", 1, {"text": "old"})
        latest = self.store.enqueue_job("requirement", "latest", "turn-1", 2, {"text": "latest"})
        self.store.set_turn_requirement("turn-1", "latest", 2, "pending", latest["job_id"])

        claimed_latest = self.store.claim_job()
        self.assertEqual(claimed_latest["job_id"], old["job_id"])
        self.store.complete_job(old["job_id"], {"text": "old answer"})
        claimed = self.store.claim_job()
        self.assertEqual(claimed["job_id"], latest["job_id"])
        self.store.complete_job(latest["job_id"], {"text": "latest answer"})

        turn = self.store.snapshot()["turns"][0]
        self.assertEqual(turn["requirement"]["text"], "latest answer")
        self.assertEqual(turn["requirement"]["revision"], 2)

    def test_atomic_snapshot_contains_disabled_source_and_usage(self):
        self.store.set_enabled(False)
        self.store.set_source_state({"status": "partial", "truncated": True, "line_count": 3})
        snapshot = self.store.snapshot()
        self.assertFalse(snapshot["enabled"])
        self.assertEqual(snapshot["source"]["status"], "partial")
        self.assertEqual(snapshot["usage"]["total_calls"], 0)
        self.assertEqual(json.loads((self.root / "view.json").read_text())["schema_version"], 1)


class FakeRunner:
    def __init__(self, failures=0):
        self.calls = []
        self.failures = failures

    def run(self, kind, prompt):
        self.calls.append((kind, prompt))
        if self.failures:
            self.failures -= 1
            from analysis_core.model import ModelError
            raise ModelError("fake_failure")
        if kind == "skill":
            return {"name": "candidate", "description": "candidate skill", "markdown": "# Skill"}
        return {"text": "%s result %d" % (kind, len(self.calls))}


class ServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.transcript = self.root / "transcript.jsonl"

    def configure(self, rows, **kwargs):
        write_jsonl(self.transcript, rows)
        service = AnalysisService.configure(
            self.root / "state", self.transcript, "session-a", "gpt-test", **kwargs
        )
        service.close()
        return AnalysisService(self.root / "state", runner=FakeRunner())

    def test_bootstrap_enqueues_only_latest_user_and_parent_final(self):
        service = self.configure(transcript_rows(rows=(
            message("u1", "turn-1", "user", "old request"),
            message("f1", "turn-1", "assistant", "old final", phase="final_answer"),
            message("u2", "turn-2", "user", "latest request", create_time=2),
            message("f2", "turn-2", "assistant", "latest final", phase="final_answer", create_time=2),
        )))
        self.addCleanup(service.close)

        jobs = service.store.jobs_for_turn("turn-1") + service.store.jobs_for_turn("turn-2")
        self.assertEqual([(job["kind"], job["source_id"]) for job in jobs], [
            ("requirement", "u2"), ("summary", "f2")
        ])
        self.assertEqual(service.store.snapshot()["turns"][0]["requirement"]["status"], "not_analyzed")
        self.assertEqual(service.store.snapshot()["turns"][1]["requirement"]["status"], "pending")

    def test_new_same_text_id_is_queued_and_late_old_result_cannot_regress(self):
        rows = transcript_rows(rows=(
            message("u1", "turn-1", "user", "same"),
            message("f1", "turn-1", "assistant", "final", phase="final_answer"),
        ))
        service = self.configure(rows)
        self.addCleanup(service.close)
        write_jsonl(self.transcript, transcript_rows(rows=(
            *rows[1:],
            message("u2", "turn-1", "user", "same", create_time=2),
        )))
        service.sync()
        self.assertEqual(service.store.pending_count(), 3)
        service.work_once()
        service.work_once()
        service.work_once()
        turn = service.store.snapshot()["turns"][0]
        self.assertEqual(turn["requirement"]["revision"], 3)
        self.assertIn("requirement result", turn["requirement"]["text"])

    def test_model_failure_is_visible_and_retry_is_bounded(self):
        service = self.configure(transcript_rows(rows=(
            message("u1", "turn-1", "user", "request"),
        )))
        self.addCleanup(service.close)
        runner = FakeRunner(failures=1)
        service.runner = runner
        service.work_once()
        snapshot = service.store.snapshot()
        job_id = snapshot["turns"][0]["requirement"]["job_id"]
        self.assertEqual(snapshot["turns"][0]["requirement"]["status"], "failed")
        service.retry(job_id)
        service.work_once()
        self.assertEqual(service.store.snapshot()["turns"][0]["requirement"]["status"], "succeeded")
        service.analyze_turn("turn-1")
        self.assertEqual(service.store.snapshot()["turns"][0]["requirement"]["status"], "succeeded")

    def test_skill_is_manual_only_and_disable_prevents_new_model_calls(self):
        service = self.configure(transcript_rows(rows=(
            message("u1", "turn-1", "user", "request"),
        )))
        self.addCleanup(service.close)
        self.assertEqual(service.store.jobs_for_turn("turn-1", "skill"), [])
        service.extract_skill("turn-1")
        self.assertEqual(len(service.store.jobs_for_turn("turn-1", "skill")), 1)
        runner = service.runner
        service.disable()
        service.work_once()
        self.assertEqual(runner.calls, [])

    def test_bad_source_preserves_previous_turns_and_sets_visible_error(self):
        service = self.configure(transcript_rows(rows=(message("u1", "turn-1", "user", "request"),)))
        self.addCleanup(service.close)
        self.assertEqual(len(service.store.snapshot()["turns"]), 1)
        bad = message("u2", "turn-2", "user", "bad")
        del bad["payload"]["id"]
        write_jsonl(self.transcript, transcript_rows(rows=(bad,)))
        snapshot = service.sync()
        self.assertEqual(len(snapshot["turns"]), 1)
        self.assertEqual(snapshot["source_error"]["code"], "missing_message_id")

    def test_partial_tail_keeps_messages_and_marks_source_warning(self):
        service = self.configure(transcript_rows(rows=(message("u1", "turn-1", "user", "request"),)))
        self.addCleanup(service.close)
        self.transcript.write_bytes(self.transcript.read_bytes() + b'{"type":"response_item"')

        snapshot = service.sync()

        self.assertEqual(len(snapshot["turns"]), 1)
        self.assertEqual(snapshot["source"]["status"], "partial")
        self.assertEqual(snapshot["source_error"]["code"], "partial_tail")

    def test_restart_sync_does_not_duplicate_bootstrap_jobs(self):
        service = self.configure(transcript_rows(rows=(
            message("u1", "turn-1", "user", "request"),
            message("f1", "turn-1", "assistant", "final", phase="final_answer"),
        )))
        service.close()
        restarted = AnalysisService(self.root / "state", runner=FakeRunner())
        self.addCleanup(restarted.close)

        restarted.sync()

        self.assertEqual(restarted.store.pending_count(), 2)
        self.assertEqual(len(restarted.store.jobs_for_turn("turn-1")), 2)

    def test_model_context_truncation_is_visible_in_pending_snapshot(self):
        service = self.configure(
            transcript_rows(rows=(
                message("u1", "turn-1", "user", "a" * 40),
            )),
            max_context_chars=20,
        )
        self.addCleanup(service.close)

        turn = service.store.snapshot()["turns"][0]

        self.assertTrue(turn["requirement"]["coverage"]["truncated"])
        self.assertLessEqual(turn["requirement"]["coverage"]["included_chars"], 20)

    def test_explicit_reanalyze_does_not_reset_completed_job(self):
        service = self.configure(transcript_rows(rows=(message("u1", "turn-1", "user", "request"),)))
        self.addCleanup(service.close)
        service.work_once()
        self.assertEqual(service.store.snapshot()["turns"][0]["requirement"]["status"], "succeeded")

    def test_shutdown_interrupt_releases_claimed_job_for_next_worker(self):
        service = self.configure(transcript_rows(rows=(message("u1", "turn-1", "user", "request"),)))
        self.addCleanup(service.close)

        class InterruptRunner:
            def run(self, kind, prompt):
                raise KeyboardInterrupt()

        service.runner = InterruptRunner()
        with self.assertRaises(KeyboardInterrupt):
            service.work_once()

        job = service.store.jobs_for_turn("turn-1", "requirement")[0]
        self.assertEqual(job["status"], "pending")
        self.assertEqual(job["attempts"], 1)


if __name__ == "__main__":
    unittest.main()
