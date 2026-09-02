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
    '''    targets = {
        "policy": _policy_path(),
        "version": _state_dir() / "version",
''',
    '''    targets = {
        "policy": _policy_path(),
        "config": _codex_home() / "config.toml",
        "version": _state_dir() / "version",
''',
    "snapshot config",
)

text = replace_once(
    text,
    '''    policy = backup / "policy"
    if policy.exists():
        _atomic_copy(policy, _policy_path())
    for name in ("version", "source", "defaults"):
''',
    '''    policy = backup / "policy"
    if policy.exists():
        _atomic_copy(policy, _policy_path())
    config = backup / "config"
    if config.exists():
        _atomic_copy(config, _codex_home() / "config.toml")
    for name in ("version", "source", "defaults"):
''',
    "restore config",
)

text = replace_once(
    text,
    '''        for member in tf.getmembers():
            _safe_target(destination, member.name)
            if member.issym() or member.islnk():
                raise RuntimeError(f"release archive may not contain links: {member.name}")
        tf.extractall(destination)
''',
    '''        for member in tf.getmembers():
            _safe_target(destination, member.name)
            if member.issym() or member.islnk():
                raise RuntimeError(f"release archive may not contain links: {member.name}")
            if not (member.isfile() or member.isdir()):
                raise RuntimeError(f"release archive contains unsupported special member: {member.name}")
        tf.extractall(destination)
''',
    "safe tar extraction",
)

text = replace_once(
    text,
    '''def _sync_managed_runtime(package_root: Path) -> None:
''',
    '''def _reconcile_runtime_config(package_root: Path) -> None:
    reconciler = package_root / "scripts" / "update_runtime_config.py"
    defaults = package_root / "policy" / "defaults.toml"
    if not reconciler.exists():
        raise RuntimeError("release package is missing runtime config reconciler")
    if not defaults.exists():
        raise RuntimeError("release package is missing policy defaults")
    subprocess.run(
        [
            sys.executable,
            str(reconciler),
            "--config",
            str(_codex_home() / "config.toml"),
            "--policy",
            str(_policy_path()),
            "--defaults",
            str(defaults),
        ],
        check=True,
        env=os.environ.copy(),
    )


def _sync_managed_runtime(package_root: Path) -> None:
''',
    "runtime config reconciler",
)

text = replace_once(
    text,
    '''    # Hooks keep their stable state-dir target, so replacing telemetry.py does not
    # require re-authorization. Reconcile the hook only when telemetry is enabled.
    manage_hooks = state / "manage-hooks.py"
    if manage_hooks.exists() and _read_policy_bool("telemetry", "enabled", True):
        hooks = _codex_home() / "hooks.json"
        subprocess.run(
            [sys.executable, str(manage_hooks), "install", "--hooks", str(hooks), "--script", str(state / "telemetry.py")],
            check=True,
        )
''',
    '''    # Hooks keep their stable state-dir target, so replacing telemetry.py does not
    # require re-authorization. Reconcile both enabled and disabled states so a
    # previously-installed managed hook cannot survive after telemetry is disabled.
    manage_hooks = state / "manage-hooks.py"
    if manage_hooks.exists():
        hooks = _codex_home() / "hooks.json"
        if _read_policy_bool("telemetry", "enabled", True):
            command = [
                sys.executable,
                str(manage_hooks),
                "install",
                "--hooks",
                str(hooks),
                "--script",
                str(state / "telemetry.py"),
            ]
        else:
            command = [sys.executable, str(manage_hooks), "uninstall", "--hooks", str(hooks)]
        subprocess.run(command, check=True)
''',
    "hook reconciliation",
)

text = replace_once(
    text,
    '''        if source is not None:
            for name in ("VERSION", "install.sh", "install.ps1", "bin", "scripts", "templates", "completions", "policy"):
                src = source / name
''',
    '''        if source is not None:
            package_items = [
                "VERSION",
                "LICENSE",
                "README.md",
                "README.en.md",
                "install.sh",
                "install.ps1",
                "bin",
                "scripts",
                "templates",
                "completions",
                "policy",
                "benchmark",
                "apps/chatgpt-mcp",
            ]
            if platform.system().lower() == "darwin":
                package_items.append("apps/macos-overlay")
            for name in package_items:
                src = source / name
''',
    "bootstrap package contents",
)

# The new package_items path already includes the full macOS overlay; do not
# copy its bin directory a second time from the source checkout.
text = replace_once(
    text,
    '''            overlay = source / "apps" / "macos-overlay" / "bin"
            if overlay.exists():
                shutil.copytree(overlay, staging / "apps" / "macos-overlay" / "bin")
        else:
''',
    '''        else:
''',
    "remove duplicate overlay bootstrap copy",
)

text = replace_once(
    text,
    '''        applied_migrations = _run_migrations(staged_version)
        _sync_managed_runtime(staged_version)
        _run_health_check()
''',
    '''        applied_migrations = _run_migrations(staged_version)
        _reconcile_runtime_config(staged_version)
        _sync_managed_runtime(staged_version)
        _run_health_check()
''',
    "install config reconcile",
)

text = replace_once(
    text,
    '''    try:
        if history_entry:
            historical_backup = Path(str(history_entry["backup"]))
            if historical_backup.exists():
                _restore_snapshot(historical_backup)
        _sync_managed_runtime(package_root)
        _run_health_check()
''',
    '''    try:
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
''',
    "exact rollback restore",
)

text = replace_once(
    text,
    '''    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--json", action="store_true")
''',
    '''    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--ack-restart",
        action="store_true",
        help="clear restart-required reminder after Codex has been fully restarted",
    )
''',
    "ack parser",
)

text = replace_once(
    text,
    '''    args = build_parser().parse_args(list(argv) if argv is not None else None)
    _update_dir().mkdir(parents=True, exist_ok=True)
    if args.command == "rollback":
''',
    '''    args = build_parser().parse_args(list(argv) if argv is not None else None)
    _update_dir().mkdir(parents=True, exist_ok=True)
    if args.ack_restart:
        state = load_state()
        state.restart_required = False
        save_state(state)
        if not args.quiet:
            print("✓ Restart reminder cleared after Codex restart.")
        return 0
    if args.command == "rollback":
''',
    "ack main",
)

updater_path.write_text(text, encoding="utf-8")

# Extend regression coverage for the newly reviewed invariants.
test_path = ROOT / "tests" / "test_updater.py"
test = test_path.read_text(encoding="utf-8")

test = replace_once(
    test,
    '''SPEC.loader.exec_module(updater)


class UpdaterTest(unittest.TestCase):
''',
    '''SPEC.loader.exec_module(updater)

PKG_SPEC = importlib.util.spec_from_file_location("codex_flow_packager", ROOT / "scripts" / "package-release.py")
assert PKG_SPEC and PKG_SPEC.loader
packager = importlib.util.module_from_spec(PKG_SPEC)
PKG_SPEC.loader.exec_module(packager)


class UpdaterTest(unittest.TestCase):
''',
    "packager import",
)

test = replace_once(
    test,
    '''        (self.bin_dir).mkdir()
''',
    '''        (self.bin_dir).mkdir()
''',
    "noop bin marker",
) if False else test

# Preserve a user-owned config sentinel so successful and failed transactions
# prove that the reconciler updates only codex-flow-managed keys.
test = replace_once(
    test,
    '''        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
''',
    '''        (self.codex_home / "config.toml").write_text(
            "# user sentinel\n[unrelated]\nkeep_me = true\n",
            encoding="utf-8",
        )
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
''',
    "config sentinel",
)

release_defaults = '''[models]\nworker_model = "fixture-worker"\n\n[reasoning.worker]\nminimum = "xhigh"\n\n[runtime]\nmax_concurrent_threads = 4\n'''

test = replace_once(
    test,
    '''        (release_root / "policy" / "defaults.toml").write_text("schema_version = 4\\n", encoding="utf-8")
''',
    f'''        (release_root / "policy" / "defaults.toml").write_text({release_defaults!r}, encoding="utf-8")
        (release_root / "scripts" / "update_runtime_config.py").write_text(
            (ROOT / "scripts" / "update_runtime_config.py").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
''',
    "successful fixture defaults",
)

test = replace_once(
    test,
    '''        self.assertTrue((self.bin_dir / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")).exists())


    def test_install_lock_rejects_concurrent_writer(self) -> None:
''',
    '''        self.assertTrue((self.bin_dir / ("codex-flow.cmd" if os.name == "nt" else "codex-flow")).exists())
        config_text = (self.codex_home / "config.toml").read_text(encoding="utf-8")
        self.assertIn("keep_me = true", config_text)
        self.assertIn('default_subagent_model = "fixture-worker"', config_text)
        policy_text = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")
        self.assertIn('resolved_model = "fixture-worker"', policy_text)

    def test_install_lock_rejects_concurrent_writer(self) -> None:
''',
    "successful reconcile assertions",
)

test = replace_once(
    test,
    '''        (package / "policy" / "defaults.toml").write_text("schema_version = 4\\n", encoding="utf-8")
        (package / "VERSION").write_text("1.8.0\\n", encoding="utf-8")
''',
    f'''        (package / "policy" / "defaults.toml").write_text({release_defaults!r}, encoding="utf-8")
        (package / "scripts" / "update_runtime_config.py").write_text(
            (ROOT / "scripts" / "update_runtime_config.py").read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        (package / "VERSION").write_text("1.8.0\\n", encoding="utf-8")
''',
    "failed fixture defaults",
)

insert = '''
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
        self.assertIn("apps/macos-overlay/bin/FlowPilot", mac)

'''

test = replace_once(
    test,
    '''
if __name__ == "__main__":
    unittest.main()
''',
    insert + '''if __name__ == "__main__":
    unittest.main()
''',
    "review regression tests",
)

test_path.write_text(test, encoding="utf-8")
