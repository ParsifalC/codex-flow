"""OS lock ownership, timeout, and disabled-write regression tests."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from telemetry_core import common


class LockRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / "state"
        self.addCleanup(patch.stopall)
        patch.object(common, "CODEX_HOME", self.home).start()
        patch.object(common, "LOCK_TIMEOUT", 0.08).start()

    def test_lock_file_survives_release_and_is_reusable(self):
        with common.state_lock("turn-a", state_root=self.state) as acquired:
            self.assertTrue(acquired)
        self.assertTrue((self.state / ".turn-a.lck").is_file())
        with common.state_lock("turn-a", state_root=self.state) as acquired:
            self.assertTrue(acquired)

    def test_contended_lock_times_out_without_entering_write_section(self):
        with common.state_lock("turn-a", state_root=self.state) as first:
            self.assertTrue(first)
            with common.state_lock("turn-a", state_root=self.state) as second:
                self.assertFalse(second)

    def test_process_exit_releases_lock_without_deleting_lock_file(self):
        self.check_process_exit("turn-a")

    def test_process_exit_releases_global_publication_lock(self):
        self.check_process_exit("global-publication")

    def check_process_exit(self, key):
        code = """
import os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from telemetry_core.common import state_lock
with state_lock(sys.argv[3], state_root=Path(sys.argv[2])) as acquired:
    print('ready' if acquired else 'failed', flush=True)
    sys.stdin.readline()
    os._exit(0)
"""
        process = subprocess.Popen(
            [sys.executable, "-c", code, str(ROOT / "scripts"), str(self.state), key],
            env={**os.environ, "CODEX_HOME": str(self.home)},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True,
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "ready")
            with common.state_lock(key, state_root=self.state) as acquired:
                self.assertFalse(acquired)
            process.communicate("exit\n", timeout=5)
            self.assertEqual(process.returncode, 0)
            with common.state_lock(key, state_root=self.state) as acquired:
                self.assertTrue(acquired)
        finally:
            if process.poll() is None:
                process.kill()
            process.communicate()

    def test_disabled_telemetry_does_not_create_lock_directory(self):
        (self.home / "codex-flow.toml").write_text("[telemetry]\nenabled=false\n", encoding="utf-8")
        with common.state_lock("turn-a", state_root=self.state) as acquired:
            self.assertFalse(acquired)
        self.assertFalse(self.state.exists())

    def test_unsupported_platform_fails_closed(self):
        with patch.object(common.os, "name", "unsupported"):
            with common.state_lock("turn-a", state_root=self.state) as acquired:
                self.assertFalse(acquired)
        self.assertFalse(self.state.exists())


if __name__ == "__main__":
    unittest.main()
