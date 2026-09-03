#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "scripts" / "manage-hooks.py"
SPEC = importlib.util.spec_from_file_location("manage_hooks", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
manage_hooks = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(manage_hooks)


def _toml_basic(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def _write_trust_state(config: Path, report: dict, *, disabled_key: str | None = None) -> None:
    lines: list[str] = []
    for entry in report["entries"]:
        lines.append(f"[hooks.state.{_toml_basic(entry['key'])}]")
        lines.append(f"trusted_hash = {_toml_basic(entry['current_hash'])}")
        if entry["key"] == disabled_key:
            lines.append("enabled = false")
        lines.append("")
    config.write_text("\n".join(lines), encoding="utf-8")


class HookTrustTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name) / ".codex"
        self.home.mkdir(parents=True)
        self.hooks = self.home / "hooks.json"
        self.config = self.home / "config.toml"
        self.script = self.home / "codex-flow" / "telemetry.py"
        self.script.parent.mkdir(parents=True)
        self.script.write_text("# fixture\n", encoding="utf-8")
        manage_hooks.install(self.hooks, self.script)

    def report(self) -> dict:
        return manage_hooks.trust_report(self.hooks, self.config)

    def test_fresh_install_requires_review(self) -> None:
        report = self.report()
        self.assertEqual(report["status"], "untrusted")
        self.assertFalse(report["ready"])
        self.assertTrue(report["authorization_required"])
        self.assertEqual(report["untrusted"], 4)
        self.assertEqual(report["total"], 4)

    def test_exact_current_hash_is_trusted(self) -> None:
        initial = self.report()
        _write_trust_state(self.config, initial)
        report = self.report()
        self.assertEqual(report["status"], "trusted")
        self.assertTrue(report["ready"])
        self.assertFalse(report["authorization_required"])
        self.assertEqual(report["trusted"], 4)

    def test_changed_hook_definition_is_modified(self) -> None:
        initial = self.report()
        _write_trust_state(self.config, initial)

        payload = json.loads(self.hooks.read_text(encoding="utf-8"))
        payload["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 16
        self.hooks.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")

        report = self.report()
        self.assertEqual(report["status"], "modified")
        self.assertFalse(report["ready"])
        self.assertTrue(report["authorization_required"])
        self.assertEqual(report["modified"], 1)
        self.assertEqual(report["trusted"], 3)

    def test_trust_detection_does_not_depend_on_codex_cli_in_path(self) -> None:
        initial = self.report()
        _write_trust_state(self.config, initial)
        empty_path = str(Path(self.tmp.name) / "empty-bin")
        Path(empty_path).mkdir()
        with mock.patch.dict(os.environ, {"PATH": empty_path}, clear=False):
            report = self.report()
        self.assertEqual(report["status"], "trusted")
        self.assertTrue(report["ready"])

    def test_disabled_hook_is_reported_separately(self) -> None:
        initial = self.report()
        disabled_key = initial["entries"][0]["key"]
        _write_trust_state(self.config, initial, disabled_key=disabled_key)
        report = self.report()
        self.assertEqual(report["status"], "disabled")
        self.assertFalse(report["ready"])
        self.assertFalse(report["authorization_required"])
        self.assertEqual(report["disabled"], 1)


if __name__ == "__main__":
    unittest.main()
