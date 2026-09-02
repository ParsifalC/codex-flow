#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


updater_path = ROOT / "scripts" / "updater.py"
text = updater_path.read_text(encoding="utf-8")
text = replace_once(
    text,
    'stamp = datetime.now().strftime("%Y%m%d-%H%M%S")',
    'stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")',
    "unique snapshot stamp",
)

old = '''    previous = _strip_v(previous_path.read_text(encoding="utf-8-sig").strip())
    package_root = state_dir / "versions" / previous
    if not package_root.exists():
        raise RuntimeError(f"rollback package is missing: {package_root}")
    backup = _snapshot(current)
    history_entry = next(
        (entry for entry in reversed(_history()) if entry.get("from") == previous and entry.get("to") == current and entry.get("backup")),
        None,
    )
    try:
        restored_exact_snapshot = False
        if history_entry:
            historical_backup = Path(str(history_entry["backup"]))
            if historical_backup.exists():
                _restore_snapshot(historical_backup)
                restored_exact_snapshot = True
        if not restored_exact_snapshot:
            _reconcile_runtime_config(package_root)
            _sync_managed_runtime(package_root)
        _run_health_check()
        atomic_write_text(state_dir / "version", previous + "\\n")
        atomic_write_text(state_dir / "current-version", previous + "\\n")
        atomic_write_text(state_dir / "source", str(package_root) + "\\n")
        atomic_write_text(state_dir / "previous-version", current + "\\n")
'''
new = '''    previous = _strip_v(previous_path.read_text(encoding="utf-8-sig").strip())
    history_entry = next(
        (entry for entry in reversed(_history()) if entry.get("from") == previous and entry.get("to") == current and entry.get("backup")),
        None,
    )
    historical_backup = Path(str(history_entry["backup"])) if history_entry else None
    has_exact_snapshot = bool(historical_backup and historical_backup.exists())
    package_root = state_dir / "versions" / previous
    if not has_exact_snapshot and not package_root.exists():
        raise RuntimeError(f"rollback package is missing: {package_root}")
    backup = _snapshot(current)
    try:
        if has_exact_snapshot:
            assert historical_backup is not None
            _restore_snapshot(historical_backup)
        else:
            _reconcile_runtime_config(package_root)
            _sync_managed_runtime(package_root)
        _run_health_check()
        atomic_write_text(state_dir / "version", previous + "\\n")
        atomic_write_text(state_dir / "current-version", previous + "\\n")
        if not has_exact_snapshot:
            atomic_write_text(state_dir / "source", str(package_root) + "\\n")
        atomic_write_text(state_dir / "previous-version", current + "\\n")
'''
text = replace_once(text, old, new, "rollback exact snapshot")
updater_path.write_text(text, encoding="utf-8")


test_path = ROOT / "tests" / "test_updater.py"
test = test_path.read_text(encoding="utf-8")
# Repair the accidental literal-newline string introduced by the previous patch.
test = replace_once(
    test,
    '''        (self.codex_home / "config.toml").write_text(
            "# user sentinel
[unrelated]
keep_me = true
",
            encoding="utf-8",
        )
''',
    '''        (self.codex_home / "config.toml").write_text(
            "# user sentinel\\n[unrelated]\\nkeep_me = true\\n",
            encoding="utf-8",
        )
''',
    "test config string",
)
# Verify failed transactions restore both policy and config.
test = replace_once(
    test,
    '''        original_policy = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")
        (self.state / "updater.py").write_text("# installed updater\\n", encoding="utf-8")
''',
    '''        original_policy = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")
        original_config = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        (self.state / "updater.py").write_text("# installed updater\\n", encoding="utf-8")
''',
    "failed update config snapshot",
)
test = replace_once(
    test,
    '''        self.assertEqual(
            (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8"),
            original_policy,
        )
        migration_state = self.state / "state" / "migrations.json"
''',
    '''        self.assertEqual(
            (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8"),
            original_policy,
        )
        self.assertEqual(
            (self.codex_home / "config.toml").read_text(encoding="utf-8"),
            original_config,
        )
        migration_state = self.state / "state" / "migrations.json"
''',
    "failed update config assertion",
)

rollback_test = r'''
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

'''
test = replace_once(
    test,
    '\n    def test_safe_extract_rejects_tar_special_member(self) -> None:\n',
    '\n' + rollback_test + '    def test_safe_extract_rejects_tar_special_member(self) -> None:\n',
    "rollback regression insertion",
)
test_path.write_text(test, encoding="utf-8")
