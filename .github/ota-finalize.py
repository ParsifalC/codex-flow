from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing patch target: {label}")
    return text.replace(old, new, 1)


updater_path = Path("scripts/updater.py")
s = updater_path.read_text(encoding="utf-8")

marker = '''def _print_status(state: UpdateState, as_json: bool = False) -> None:\n'''
helper = '''def _legacy_fallback_allowed(exc: Exception) -> bool:\n    # Legacy git update exists only to bootstrap users while the first OTA-aware\n    # release is rolling out. Never bypass checksum, transaction, concurrency,\n    # migration, or health-check failures with an unverified git pull.\n    message = str(exc)\n    return MANIFEST_ASSET in message and "does not provide" in message\n\n\n'''
if helper not in s:
    if marker not in s:
        raise SystemExit("missing fallback helper insertion point")
    s = s.replace(marker, helper + marker, 1)

s = replace_once(
    s,
    '''    except Exception as exc:\n        if not args.no_legacy_fallback and _legacy_git_update() == 0:\n            if not args.quiet:\n                print("✓ Updated using the legacy source checkout fallback. Future release packages will use OTA automatically.")\n            return 0\n        print(f"codex-flow update failed: {exc}", file=sys.stderr)\n        return 1\n''',
    '''    except Exception as exc:\n        if (\n            not args.no_legacy_fallback\n            and _legacy_fallback_allowed(exc)\n            and _legacy_git_update() == 0\n        ):\n            if not args.quiet:\n                print("✓ Updated using the legacy source checkout fallback. Future release packages will use OTA automatically.")\n            return 0\n        print(f"codex-flow update failed: {exc}", file=sys.stderr)\n        return 1\n''',
    "restricted legacy fallback",
)
updater_path.write_text(s, encoding="utf-8")

tests = Path("tests/test_updater.py")
t = tests.read_text(encoding="utf-8")
insert_before = '''    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:\n'''
additions = '''    def test_legacy_fallback_is_only_allowed_for_missing_ota_manifest(self) -> None:\n        self.assertTrue(\n            updater._legacy_fallback_allowed(\n                RuntimeError("release v1.7.0 does not provide codex-flow-update.json")\n            )\n        )\n        self.assertFalse(updater._legacy_fallback_allowed(RuntimeError("checksum mismatch")))\n        self.assertFalse(\n            updater._legacy_fallback_allowed(\n                RuntimeError("another codex-flow update or rollback is already running")\n            )\n        )\n        self.assertFalse(updater._legacy_fallback_allowed(RuntimeError("doctor failed")))\n\n    def test_failed_health_check_restores_policy_and_does_not_commit_migration(self) -> None:\n        original_policy = (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8")\n        (self.state / "updater.py").write_text("# installed updater\\n", encoding="utf-8")\n        package = self.root / "failed-package"\n        (package / "scripts" / "migrations").mkdir(parents=True)\n        (package / "scripts" / "updater.py").write_text("# new updater\\n", encoding="utf-8")\n        (package / "policy").mkdir(parents=True)\n        (package / "policy" / "defaults.toml").write_text("schema_version = 4\\n", encoding="utf-8")\n        (package / "VERSION").write_text("1.8.0\\n", encoding="utf-8")\n        migration = package / "scripts" / "migrations" / "9999_test_failure.py"\n        migration.write_text(\n            "from pathlib import Path\\nimport sys\\np=Path(sys.argv[sys.argv.index('--policy')+1])\\np.write_text(p.read_text()+'\\\\n# migrated\\\\n')\\n",\n            encoding="utf-8",\n        )\n        with patch.object(updater, "_run_health_check", side_effect=RuntimeError("doctor failed")):\n            with self.assertRaisesRegex(RuntimeError, "doctor failed"):\n                updater._install_package(package, "1.8.0", self.manifest())\n        self.assertEqual(\n            (self.codex_home / "codex-flow.toml").read_text(encoding="utf-8"),\n            original_policy,\n        )\n        migration_state = self.state / "state" / "migrations.json"\n        self.assertFalse(migration_state.exists())\n\n'''
if additions not in t:
    if insert_before not in t:
        raise SystemExit("missing test insertion point")
    t = t.replace(insert_before, additions + insert_before, 1)
tests.write_text(t, encoding="utf-8")
