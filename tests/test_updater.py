from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import sys
import tarfile
import tempfile
import threading
import time
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

PKG_SPEC = importlib.util.spec_from_file_location("codex_flow_packager", ROOT / "scripts" / "package-release.py")
assert PKG_SPEC and PKG_SPEC.loader
packager = importlib.util.module_from_spec(PKG_SPEC)
PKG_SPEC.loader.exec_module(packager)


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
        (self.codex_home / "config.toml").write_text(
            "# user sentinel\n[unrelated]\nkeep_me = true\n",
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

    def test_stable_channel_rejects_unmarked_beta_tag(self) -> None:
        release = {"tag_name": "v1.8.0-beta.1", "draft": False, "prerelease": False}
        self.assertFalse(updater._release_matches_channel(release, "stable"))
        self.assertTrue(updater._release_matches_channel(release, "beta"))

    def test_menu_can_disable_cli_update_badge(self) -> None:
        state = updater.UpdateState(current_version="1.7.0", latest_version="1.8.0", update_available=True, notify_cli=False)
        self.assertEqual(updater.update_menu_label("en", state), "🔄 Check for updates")

    def test_manifest_enforces_minimum_updater_version(self) -> None:
        manifest = self.manifest()
        manifest["minimum_updater_version"] = "1.1.0"
        with self.assertRaises(RuntimeError):
            updater._validate_manifest(manifest)

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
        (release_root / "policy" / "defaults.toml").write_text('[models]\nworker_model = "fixture-worker"\n\n[reasoning.worker]\nminimum = "xhigh"\n\n[runtime]\nmax_concurrent_threads = 4\n', encoding="utf-8")
        (release_root / "scripts" / "update_runtime_config.py").write_text(
            (ROOT / "scripts" / "update_runtime_config.py").read_text(encoding="utf-8"),
            encoding="utf-8",
        )

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
        config_text = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertIn("keep_me = true", config_text)
        self.assertIn('default_subagent_model = "fixture-worker"', config_text)
        policy_text = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")
        self.assertIn('resolved_model = "fixture-worker"', policy_text)

    def test_cached_available_state_is_recomputed_after_another_process_updates(self) -> None:
        state = updater.UpdateState(
            current_version="1.7.0",
            latest_version="1.8.0",
            update_available=True,
            status="available",
        )
        updater.save_state(state)
        (self.state / "version").write_text("1.8.0\n", encoding="utf-8")
        loaded = updater.load_state()
        self.assertEqual(loaded.current_version, "1.8.0")
        self.assertFalse(loaded.update_available)
        self.assertEqual(loaded.status, "latest")

    def test_stale_lock_owned_by_live_process_is_not_stolen(self) -> None:
        lock = updater._lock_path()
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(str(os.getpid()), encoding="ascii")
        os.utime(lock, (1, 1))
        with updater.update_lock(stale_seconds=1) as acquired:
            self.assertFalse(acquired)
        self.assertTrue(lock.exists())
        lock.unlink()

    def test_install_waits_for_inflight_background_check(self) -> None:
        acquired_writer: list[bool] = []
        errors: list[Exception] = []
        with updater.update_lock() as acquired:
            self.assertTrue(acquired)

            def acquire_writer() -> None:
                try:
                    with updater.install_lock(timeout_seconds=1.0, poll_interval=0.01):
                        acquired_writer.append(True)
                except Exception as exc:
                    errors.append(exc)

            thread = threading.Thread(target=acquire_writer)
            thread.start()
            time.sleep(0.05)
            self.assertTrue(thread.is_alive())
            self.assertEqual(acquired_writer, [])

        thread.join(timeout=2.0)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(acquired_writer, [True])

    def test_flowpilot_restart_ack_is_independent_from_codex_restart(self) -> None:
        state = updater.load_state()
        state.restart_required = True
        state.flowpilot_restart_required = True
        updater.save_state(state)
        self.assertEqual(updater.main(["--ack-flowpilot-restart", "--quiet"]), 0)
        loaded = updater.load_state()
        self.assertTrue(loaded.restart_required)
        self.assertFalse(loaded.flowpilot_restart_required)
        self.assertEqual(updater.main(["--ack-restart", "--quiet"]), 0)
        self.assertFalse(updater.load_state().restart_required)

    def test_manifest_generator_uses_updater_protocol_version(self) -> None:
        source = (ROOT / "scripts" / "generate-release-manifest.py").read_text(encoding="utf-8")
        match = re.search(r'^MINIMUM_UPDATER_VERSION = "([^"]+)"$', source, re.MULTILINE)
        self.assertIsNotNone(match)
        self.assertEqual(match.group(1), updater.UPDATER_VERSION)

    def test_install_lock_rejects_concurrent_writer(self) -> None:
        with updater.install_lock():
            with self.assertRaisesRegex(RuntimeError, "still running"):
                with updater.install_lock(timeout_seconds=0):
                    pass

    def test_legacy_fallback_is_only_allowed_for_missing_ota_manifest(self) -> None:
        self.assertTrue(
            updater._legacy_fallback_allowed(
                RuntimeError("release v1.7.0 does not provide codex-flow-update.json")
            )
        )
        self.assertFalse(updater._legacy_fallback_allowed(RuntimeError("checksum mismatch")))
        self.assertFalse(
            updater._legacy_fallback_allowed(
                RuntimeError("another codex-flow update or rollback is already running")
            )
        )
        self.assertFalse(updater._legacy_fallback_allowed(RuntimeError("doctor failed")))

    def test_failed_health_check_restores_policy_and_does_not_commit_migration(self) -> None:
        original_policy = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")
        original_config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        (self.state / "updater.py").write_text("# installed updater\n", encoding="utf-8")
        package = self.root / "failed-package"
        (package / "scripts" / "migrations").mkdir(parents=True)
        (package / "scripts" / "updater.py").write_text("# new updater\n", encoding="utf-8")
        (package / "policy").mkdir(parents=True)
        (package / "policy" / "defaults.toml").write_text('[models]\nworker_model = "fixture-worker"\n\n[reasoning.worker]\nminimum = "xhigh"\n\n[runtime]\nmax_concurrent_threads = 4\n', encoding="utf-8")
        (package / "scripts" / "update_runtime_config.py").write_text(
            (ROOT / "scripts" / "update_runtime_config.py").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        (package / "VERSION").write_text("1.8.0\n", encoding="utf-8")
        migration = package / "scripts" / "migrations" / "9999_test_failure.py"
        migration.write_text(
            "from pathlib import Path\nimport sys\np=Path(sys.argv[sys.argv.index('--policy')+1])\np.write_text(p.read_text()+'\\n# migrated\\n')\n",
            encoding="utf-8",
        )
        with patch.object(updater, "_run_health_check", side_effect=RuntimeError("doctor failed")):
            with self.assertRaisesRegex(RuntimeError, "doctor failed"):
                updater._install_package(package, "1.8.0", self.manifest())
        self.assertEqual(
            (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8"),
            original_policy,
        )
        self.assertEqual(
            (self.codex_home / "config.toml").read_text(encoding="utf-8"),
            original_config,
        )
        migration_state = self.state / "state" / "migrations.json"
        self.assertFalse(migration_state.exists())

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

    def test_rollback_uses_exact_snapshot_without_previous_package(self) -> None:
        original_source = self.root / "original-checkout"
        original_source.mkdir()
        (original_source / "VERSION").write_text("1.7.0\n", encoding="utf-8")
        (self.state / "source").write_text(str(original_source) + "\n", encoding="utf-8")
        (self.state / "updater.py").write_text("# old updater\n", encoding="utf-8")
        (self.bin_dir / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")).write_text(
            "@echo off\r\n" if os.name == "nt" else "#!/usr/bin/env bash\n",
            encoding="utf-8",
        )

        package = self.root / "rollback-package"
        (package / "scripts").mkdir(parents=True)
        (package / "bin").mkdir(parents=True)
        (package / "policy").mkdir(parents=True)
        (package / "VERSION").write_text("1.8.0\n", encoding="utf-8")
        (package / "scripts" / "updater.py").write_text("# new updater\n", encoding="utf-8")
        (package / "scripts" / "update_runtime_config.py").write_text(
            (ROOT / "scripts" / "update_runtime_config.py").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        (package / "policy" / "defaults.toml").write_text(
            '[models]\nworker_model = "fixture-worker"\n\n[reasoning.worker]\nminimum = "xhigh"\n\n[runtime]\nmax_concurrent_threads = 4\n',
            encoding="utf-8",
        )
        launcher = package / "bin" / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")
        launcher.write_text("@echo off\r\n" if os.name == "nt" else "#!/usr/bin/env bash\n", encoding="utf-8")

        updater._install_package(package, "1.8.0", self.manifest())
        previous_package = self.state / "versions" / "1.7.0"
        if previous_package.exists():
            import shutil
            shutil.rmtree(previous_package)
        state = updater.rollback()
        self.assertEqual(state.current_version, "1.7.0")
        self.assertEqual(
            (self.state / "source").read_text(encoding="utf-8").strip(),
            str(original_source),
        )
        self.assertIn(
            "# user sentinel",
            (self.codex_home / "config.toml").read_text(encoding="utf-8"),
        )

    def test_safe_extract_rejects_tar_special_member(self) -> None:
        archive = self.root / "special.tar"
        with tarfile.open(archive, "w") as tf:
            info = tarfile.TarInfo("payload.fifo")
            info.type = tarfile.FIFOTYPE
            tf.addfile(info)
        with self.assertRaisesRegex(RuntimeError, "special member"):
            updater.safe_extract(archive, self.root / "special-extract")

    def test_restart_reminder_requires_explicit_acknowledgement(self) -> None:
        state = updater.load_state()
        state.restart_required = True
        updater.save_state(state)
        self.assertEqual(updater.main(["--ack-restart", "--quiet"]), 0)
        self.assertFalse(updater.load_state().restart_required)

    def test_release_package_keeps_runtime_dependencies(self) -> None:
        linux = {path.relative_to(ROOT).as_posix() for path in packager.iter_files("linux-x86_64")}
        self.assertIn("benchmark/corpus.json", linux)
        self.assertIn("apps/chatgpt-mcp/server.py", linux)
        self.assertNotIn("apps/macos-overlay/build.sh", linux)
        mac = {path.relative_to(ROOT).as_posix() for path in packager.iter_files("darwin-arm64")}
        self.assertIn("apps/macos-overlay/build.sh", mac)
        self.assertIn("apps/macos-overlay/Sources/main.swift", mac)
        if (ROOT / "apps" / "macos-overlay" / "bin" / "FlowPilot").exists():
            self.assertIn("apps/macos-overlay/bin/FlowPilot", mac)


if __name__ == "__main__":
    unittest.main()
