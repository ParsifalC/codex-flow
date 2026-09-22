import importlib.util
import json
import os
import socket
import stat
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from analysis_core.service import AnalysisService
from analysis_core.store import AnalysisStore
from analysis_core.source import parse_transcript
from test_analysis_core import message, transcript_rows, write_jsonl


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source.jsonl'
        self.rows = transcript_rows(rows=[message('u1', 't1', 'user', 'old'), message('f1', 't1', 'assistant', 'old final', phase='final_answer'), message('u2', 't2', 'user', 'new')])
        write_jsonl(self.source, self.rows)

    def service(self):
        return AnalysisService.configure(self.root / 'state', self.source, 'session-a', 'fake')

    def test_sync_recovers_crash_after_source_commit_without_backfilling_history(self):
        with patch.object(AnalysisService, '_enqueue_message_job', side_effect=RuntimeError('crash')):
            with self.assertRaises(RuntimeError):
                self.service()
        service = AnalysisService(self.root / 'state')
        self.addCleanup(service.close)
        service.sync()
        jobs = [j for t in service.store.turns() for j in service.store.jobs_for_turn(t['turn_id'])]
        self.assertEqual({(j['kind'], j['source_id']) for j in jobs}, {('requirement', 'u2'), ('summary', 'f1')})
        service.sync()
        self.assertEqual(service.store.pending_count(), 2)

    def test_interrupted_final_attempt_is_failed_and_caveats_and_running_are_visible(self):
        service = self.service()
        self.addCleanup(service.close)
        store = service.store
        job = store.claim_job()
        turn = next(t for t in store.snapshot()['turns'] if t['turn_id'] == job['turn_id'])
        self.assertEqual(turn[job['kind']]['status'], 'running')
        store.complete_job(job['job_id'], {'text': 'need', 'caveats': ['confirm scope']})
        turn = next(t for t in store.snapshot()['turns'] if t['turn_id'] == job['turn_id'])
        self.assertEqual(turn[job['kind']]['caveats'], ['confirm scope'])
        store.enqueue_job('skill', 'manual', 't2', 3, {}, max_attempts=1)
        store.claim_job()  # other bootstrap job
        skill = store.claim_job()
        store.release_job(skill['job_id'], preserve_attempts=True)
        self.assertEqual(store.get_job(skill['job_id'])['status'], 'failed')
        self.assertEqual(store.get_job(skill['job_id'])['error'], 'interrupted')

    def test_expired_final_attempt_does_not_stay_running(self):
        store = AnalysisStore(self.root / 'queue', 'session-a')
        self.addCleanup(store.close)
        job = store.enqueue_job('requirement', 'x', 't', 1, {}, max_attempts=1)
        store.claim_job(lease_ms=-1)
        self.assertIsNone(store.claim_job())
        self.assertEqual(store.get_job(job['job_id'])['status'], 'failed')

    def test_manual_skill_reextracts_after_same_turn_changes_but_dedupes_same_scope(self):
        service = self.service()
        self.addCleanup(service.close)
        service.extract_skill('t2')
        service.extract_skill('t2')
        self.assertEqual(len(service.store.jobs_for_turn('t2', 'skill')), 1)
        self.rows.append(message('u3', 't2', 'user', 'extra constraint'))
        write_jsonl(self.source, self.rows)
        service.extract_skill('t2')
        self.assertEqual(len(service.store.jobs_for_turn('t2', 'skill')), 2)

    def test_question_reply_keeps_the_question_that_yes_refers_to(self):
        body = '<send_user_message_question_reply>' + json.dumps([{'question': 'Only display, without feedback?', 'answer': 'Yes'}]) + '</send_user_message_question_reply>'
        write_jsonl(self.source, transcript_rows(rows=[message('q1', 't1', 'user', body)]))
        text = parse_transcript(self.source, 'session-a').user_messages[0].text
        self.assertIn('Only display, without feedback?', text)
        self.assertIn('Yes', text)

    def test_committed_job_result_survives_missing_turn_projection(self):
        service = self.service()
        self.addCleanup(service.close)
        job = service.store.claim_job()
        service.store._set_job_result(job['job_id'], 'succeeded', {'text': 'durable result', 'caveats': []}, None)
        turn = next(t for t in service.store.snapshot()['turns'] if t['turn_id'] == job['turn_id'])
        self.assertEqual(turn[job['kind']]['text'], 'durable result')

    def test_upsert_immediately_hides_stale_requirement(self):
        service = self.service()
        self.addCleanup(service.close)
        while True:
            job = service.store.claim_job()
            if not job: break
            service.store.complete_job(job['job_id'], {'text': 'old analysis', 'caveats': []})
        self.rows.append(message('u3', 't2', 'user', 'new constraint'))
        write_jsonl(self.source, self.rows)
        service.store.upsert_transcript(parse_transcript(self.source, 'session-a'))
        need = service.store.snapshot()['turns'][-1]['requirement']
        self.assertEqual(need['status'], 'pending')
        self.assertIsNone(need['text'])

    def test_child_markers_on_record_and_payload_are_filtered(self):
        children = []
        for i, marker in enumerate([{'agent_id': 'child'}, {'thread_source': 'subagent'}, {'source': {'subagent': {}}}]):
            row = message('f' + str(i), 't1', 'assistant', 'child', phase='final_answer')
            (row if i == 0 else row['payload']).update(marker)
            children.append(row)
        write_jsonl(self.source, transcript_rows(rows=[message('u', 't1', 'user', 'request')] + children))
        self.assertEqual(parse_transcript(self.source, 'session-a').final_messages, [])

    def test_skill_metadata_is_valid_canonical_frontmatter_including_old_results(self):
        from analysis_core.model import CodexExecRunner
        runner = CodexExecRunner(self.root / 'runner', 'fake')
        raw = {'name': 'good-skill', 'description': 'A: "quoted" description', 'markdown': '---\nname: wrong\n description: broken\n---\n# Body', 'caveats': []}
        cleaned = runner._clean_result(raw, 'skill')
        lines = cleaned['markdown'].splitlines()
        self.assertEqual(lines[0], '---')
        self.assertEqual(json.loads(lines[1].split(': ', 1)[1]), raw['name'])
        self.assertEqual(json.loads(lines[2].split(': ', 1)[1]), raw['description'])
        self.assertIn('# Body', cleaned['markdown'])
        service = self.service()
        self.addCleanup(service.close)
        job = service.store.enqueue_job('skill', 'legacy', 't2', 3, {})
        service.store._set_job_result(job['job_id'], 'succeeded', raw, None)
        self.assertEqual(service.store.snapshot()['turns'][-1]['skills'][0]['markdown'], cleaned['markdown'])


class LauncherTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('preview_analysis', ROOT / 'scripts/preview-analysis.py')
        self.launcher = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.launcher)
        self.temp = tempfile.TemporaryDirectory(prefix='preview test ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'private state'
        self.source = self.root / 'source.jsonl'
        write_jsonl(self.source, transcript_rows(rows=[message('u1', 't1', 'user', 'request')]))
        (self.root / 'empty-auth').mkdir()
        self.ui = self.root / 'fake ui'
        self.ui.write_text('#!' + sys.executable + '\nimport sys,time,pathlib\np=pathlib.Path(sys.argv[sys.argv.index("--state-dir")+1]);(p/"ui-args.json").write_text(__import__("json").dumps(sys.argv))\nwhile not (p/"close-ui").exists(): time.sleep(.05)\n')
        self.ui.chmod(0o700)
        self.addCleanup(lambda: self.launcher.stop(self.state))

    def start(self):
        args = self.launcher.parser().parse_args(['start', '--state-dir', str(self.state), '--transcript', str(self.source), '--session-id', 'session-a', '--model', 'fake', '--auth-home', str(self.root / 'empty-auth'), '--codex-bin', '/usr/bin/false', '--ui-binary', str(self.ui)])
        return self.launcher.start(args)

    def test_duplicate_start_private_state_safe_argv_and_window_close_cleanup(self):
        first = self.start()
        self.assertTrue(first['running'])
        second = self.start()
        self.assertEqual(first['pid'], second['pid'])
        self.assertEqual(stat.S_IMODE(self.state.stat().st_mode), 0o700)
        for _ in range(150):
            if (self.state / 'ui-args.json').exists(): break
            time.sleep(.05)
        argv = json.loads((self.state / 'ui-args.json').read_text())
        self.assertIn(str(self.state.resolve()), argv)
        self.assertIn('analysis-preview', argv)
        (self.state / 'close-ui').touch()
        for _ in range(100):
            if not self.launcher.status(self.state)['running']: break
            time.sleep(.05)
        self.assertFalse(self.launcher.status(self.state)['running'])

    def test_stop_uses_authenticated_control_and_stale_pid_is_never_signalled(self):
        self.start()
        meta = json.loads((self.state / 'preview-runtime.json').read_text())
        wrong = dict(meta, token='wrong')
        self.assertIsNone(self.launcher.request(wrong, 'stop'))
        self.assertTrue(self.launcher.status(self.state)['running'])
        self.assertFalse(self.launcher.stop(self.state)['running'])
        (self.state / 'preview-runtime.json').write_text(json.dumps({'pid': os.getpid(), 'port': 1, 'token': 'stale'}))
        self.assertFalse(self.launcher.stop(self.state)['running'])

    def test_missing_ui_does_not_leave_worker(self):
        self.ui.unlink()
        with self.assertRaises(ValueError): self.start()
        self.assertFalse(self.launcher.status(self.state)['running'])

if __name__ == '__main__': unittest.main()
