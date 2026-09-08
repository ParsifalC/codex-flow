from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("codex_flow_instructions", ROOT / "scripts" / "manage-instructions.py")
assert SPEC and SPEC.loader
instructions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(instructions)


class InstructionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name) / ".codex with spaces"
        self.home.mkdir(parents=True)
        self.template = self.home / "template.md"
        self.template.write_bytes(b"Read FlowPilot at {{CODEX_HOME}}/skills/flow-pilot/SKILL.md.\n")

    def tearDown(self):
        self.tmp.cleanup()

    def test_merge_remove_preserves_bytes_and_is_idempotent(self):
        base = self.home / "AGENTS.md"
        original = b"user bytes with no final newline"
        base.write_bytes(original)

        first = instructions.install(self.home, self.template)
        installed = base.read_bytes()
        self.assertEqual(first["status"], "installed")
        self.assertIn(str(self.home).encode(), installed)
        self.assertTrue(installed.endswith(original))
        instructions.install(self.home, self.template)
        self.assertEqual(base.read_bytes(), installed)

        instructions.uninstall(self.home)
        self.assertEqual(base.read_bytes(), original)

    def test_nonempty_override_is_effective_and_empty_override_is_not_populated(self):
        base = self.home / "AGENTS.md"
        override = self.home / "AGENTS.override.md"
        base.write_bytes(b"base sentinel")
        override.write_bytes(b"")
        instructions.install(self.home, self.template)
        self.assertEqual(override.read_bytes(), b"")
        self.assertEqual(instructions.check(self.home, self.template)["target"], "AGENTS.md")

        override.write_bytes(b"override sentinel")
        instructions.install(self.home, self.template)
        self.assertIn(instructions.BEGIN_MARKER, override.read_bytes())
        self.assertEqual(base.read_bytes(), b"base sentinel")
        self.assertEqual(instructions.check(self.home, self.template)["target"], "AGENTS.override.md")
        instructions.uninstall(self.home)
        self.assertEqual(base.read_bytes(), b"base sentinel")
        self.assertEqual(override.read_bytes(), b"override sentinel")

    def test_missing_stale_and_shadowed_statuses(self):
        base = self.home / "AGENTS.md"
        self.assertEqual(instructions.check(self.home, self.template)["status"], "missing")
        base.write_bytes(b"base")
        instructions.install(self.home, self.template)
        self.assertEqual(instructions.check(self.home, self.template)["status"], "installed")

        self.template.write_bytes(b"new template\n")
        self.assertEqual(instructions.check(self.home, self.template)["status"], "stale")
        (self.home / "AGENTS.override.md").write_bytes(b"user override")
        self.assertEqual(instructions.check(self.home, self.template)["status"], "shadowed")

    def test_malformed_or_duplicate_markers_fail_before_writes(self):
        base = self.home / "AGENTS.md"
        override = self.home / "AGENTS.override.md"
        base.write_bytes(b"before\n" + instructions.BEGIN_MARKER + b"\n")
        override.write_bytes(b"override sentinel")
        before = (base.read_bytes(), override.read_bytes())
        with self.assertRaises(instructions.InstructionError):
            instructions.install(self.home, self.template)
        self.assertEqual((base.read_bytes(), override.read_bytes()), before)

        base.write_bytes(
            instructions.BEGIN_MARKER
            + b"\nbody\n"
            + instructions.END_MARKER
            + b"\n"
            + instructions.BEGIN_MARKER
            + b"\nbody\n"
            + instructions.END_MARKER
            + b"\n"
        )
        before = base.read_bytes()
        with self.assertRaises(instructions.InstructionError):
            instructions.uninstall(self.home)
        self.assertEqual(base.read_bytes(), before)

    def test_symlink_is_refused_without_following_or_replacing_it(self):
        external = Path(self.tmp.name) / "external"
        external.write_bytes(b"outside")
        base = self.home / "AGENTS.md"
        base.symlink_to(external)
        with self.assertRaises(instructions.InstructionError):
            instructions.install(self.home, self.template)
        self.assertTrue(base.is_symlink())
        self.assertEqual(external.read_bytes(), b"outside")

    def test_inline_end_marker_is_rejected_without_changing_user_content(self):
        base = self.home / "AGENTS.md"
        original = instructions.BEGIN_MARKER + b"\nuser content " + instructions.END_MARKER + b"\n"
        base.write_bytes(original)
        with self.assertRaises(instructions.InstructionError):
            instructions.uninstall(self.home)
        self.assertEqual(base.read_bytes(), original)

    def test_new_target_is_removed_on_uninstall(self):
        instructions.install(self.home, self.template)
        self.assertTrue((self.home / "AGENTS.md").exists())
        instructions.uninstall(self.home)
        self.assertFalse((self.home / "AGENTS.md").exists())


if __name__ == "__main__":
    unittest.main()
