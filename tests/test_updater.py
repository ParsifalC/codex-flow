from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("codex_flow_updater", ROOT / "scripts" / "updater.py")
assert SPEC and SPEC.loader
updater = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = updater
SPEC.loader.exec_module(updater)


class UpdaterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.codex_home = self.root / ".codex"
        self.state = self.codex_home / "codex-flow"
        self.state.mkdir(parents=True)
        (self.state / "version").write_text("1.7.0\n", encoding="utf-8")
        (self.codex_home / "codex-flow.toml").write_text(
            "schema_version = 4\n\n"
            "[telemetry]\n"
            "enabled = false\n\n"
            "[update]\n"
            "channel = \"stable\"\n"
            "check = true\n"
            "check_interval_hours = 24\n"
            "notify_cli = true\n"
            "notify_app = true\n"
            "auto_install = false\n",
            encoding="utf-8",
        )
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.env = patch.dict(
            os.environ,
            {
                "CODEX_HOME": str(self.codex_home),
                "CODEX_FLOW_BIN_DIR": str(self.bin_dir),
                "CODEX_FLOW_UPDATE_SKIP_DOCTOR": "1",
            },
            clear=False,
        )
        self.env.start()

    def tearDown(self) -> None:
        self.env.stop()
        self.tmp.cleanup()

    def manifest(self, version: str = "1.8.0", artifact: dict | None = None) -> dict:
        return {
            "schema": 1,
            "version": version,
            "channel": "stable",
            "restart_required": True,
            "artifacts": {
                updater.platform_key(): artifact
                or {
                    "url": "https://example.invalid/codex-flow.tar.gz",
                    "sha256": "0" * 64,
                    "format": "tar.gz",
                }
            },
        }

    def test_version_order_handles_stable_and_prerelease(self) -> None:
        self.assertTrue(updater.is_newer("1.8.0", "1.7.9"))
        self.assertTrue(updater.is_newer("1.8.0", "1.8.0-beta.3"))
        self.assertFalse(updater.is_newer("1.8.0-beta.1", "1.8.0"))
        self.assertTrue(updater.is_newer("2.0", "1.99.99"))

    def test_check_writes_shared_state_and_menu_label(self) -> None:
        manifest_path = self.root / "manifest.json"
        manifest_path.write_text(json.dumps(self.manifest()), encoding="utf-8")
        with patch.dict(os.environ, {"CODEX_FLOW_UPDATE_MANIFEST_URL": str(manifest_path)}, clear=False):
            state = updater.check_for_updates(force=True)
        self.assertTrue(state.update_available)
        self.assertEqual(state.latest_version, "1.8.0")
        self.assertEqual(state.status, "available")
        self.assertEqual(updater.update_menu_label("zh", state), "🆕 更新 codex-flow · v1.8.0 可用")
        cached = json.loads((self.state / "state" / "update.json").read_text(encoding="utf-8"))
        self.assertEqual(cached["current_version"], "1.7.0")
        self.assertEqual(cached["latest_version"], "1.8.0")

    def test_pre_ota_older_release_is_treated_as_latest(self) -> None:
        release = {
            "tag_name": "v1.6.0",
            "draft": False,
            "prerelease": False,
            "html_url": "https://example.invalid/releases/v1.6.0",
            "assets": [],
        }
        with patch.object(updater, "_request_json", return_value=[release]):
            state = updater.check_for_updates(force=True)
        self.assertEqual(state.status, "latest")
        self.assertEqual(state.current_version, "1.7.0")
        self.assertEqual(state.latest_version, "1.7.0")
        self.assertFalse(state.update_available)
        self.assertIsNone(state.last_error)

    def test_safe_extract_rejects_zip_path_traversal(self) -> None:
        archive = self.root / "bad.zip"
        with zipfile.ZipFile(archive, "w") as zf:
            zf.writestr("../escape.txt", "bad")
        with self.assertRaises(RuntimeError):
            updater.safe_extract(archive, self.root / "extract")

    def test_perform_update_from_local_release_artifact(self) -> None:
        package = self.root / "package"
        release_root = package / "codex-flow-1.8.0"
        (release_root / "scripts").mkdir(parents=True)
        (release_root / "bin").mkdir(parents=True)
        (release_root / "policy").mkdir(parents=True)
        (release_root / "VERSION").write_text("1.8.0\n", encoding="utf-8")
        (release_root / "scripts" / "updater.py").write_text("# updater fixture\n", encoding="utf-8")
        launcher = release_root / "bin" / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")
        launcher.write_text("@echo off\r\n" if os.name == "nt" else "#!/usr/bin/env bash\necho ota-fixture\n", encoding="utf-8")
        if os.name != "nt":
            launcher.chmod(0o755)
        (release_root / "policy" / "defaults.toml").write_text("schema_version = 4\n", encoding="utf-8")

        archive = self.root / "codex-flow-1.8.0-test.tar.gz"
        with tarfile.open(archive, "w:gz") as tf:
            tf.add(release_root, arcname=release_root.name)
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest = self.manifest(
            artifact={"url": str(archive), "sha256": digest, "format": "tar.gz"}
        )
        manifest_path = self.root / "manifest-install.json"
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

        with patch.dict(os.environ, {"CODEX_FLOW_UPDATE_MANIFEST_URL": str(manifest_path)}, clear=False):
            state = updater.perform_update(force_check=True)

        self.assertEqual(state.current_version, "1.8.0")
        self.assertTrue(state.restart_required)
        self.assertEqual((self.state / "version").read_text(encoding="utf-8").strip(), "1.8.0")
        self.assertEqual((self.state / "previous-version").read_text(encoding="utf-8").strip(), "1.7.0")
        self.assertTrue((self.state / "versions" / "1.8.0" / "VERSION").exists())
        self.assertTrue((self.bin_dir / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")).exists())


    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:
        source = self.root / "source"
        (source / ".git").mkdir(parents=True)
        (source / ("install.ps1" if os.name == "nt" else "install.sh")).write_text("fixture\n", encoding="utf-8")
        (self.state / "source").write_text(str(source) + "\n", encoding="utf-8")
        with patch.object(updater.subprocess, "check_output", return_value="HEAD\n"), \
             patch.object(updater.subprocess, "run") as run:
            run.return_value.returncode = 0
            result = updater._legacy_git_update()
        self.assertEqual(result, 0)
        commands = [call.args[0] for call in run.call_args_list]
        self.assertFalse(any("pull" in command for command in commands))
        self.assertTrue(any(("install.ps1" in " ".join(command)) or ("install.sh" in " ".join(command)) for command in commands))


if __name__ == "__main__":
    unittest.main()
