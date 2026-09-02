from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8-sig")
    if old not in text:
        raise SystemExit(f"expected block not found in {path}")
    updated = text.replace(old, new, 1)
    encoding = "utf-8-sig" if path.name == "install.ps1" else "utf-8"
    path.write_text(updated, encoding=encoding)


updater = Path("scripts/updater.py")

replace_once(
    updater,
    '''def _migration_state_path() -> Path:\n    return _update_dir() / "migrations.json"\n\n\ndef _bin_dir() -> Path:\n''',
    '''def _migration_state_path() -> Path:\n    return _update_dir() / "migrations.json"\n\n\ndef _install_lock_path() -> Path:\n    return _update_dir() / "install.lock"\n\n\n@contextlib.contextmanager\ndef update_lock(stale_after_seconds: int = 2 * 60 * 60):\n    """Serialize update/rollback writers across CLI and FlowPilot processes."""\n\n    lock = _install_lock_path()\n    lock.parent.mkdir(parents=True, exist_ok=True)\n    fd = None\n    for attempt in range(2):\n        try:\n            fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)\n            os.write(fd, f"pid={os.getpid()}\\nstarted_at={utc_now()}\\n".encode("utf-8"))\n            os.close(fd)\n            fd = None\n            break\n        except FileExistsError:\n            try:\n                stale = time.time() - lock.stat().st_mtime > stale_after_seconds\n            except OSError:\n                stale = False\n            if stale and attempt == 0:\n                with contextlib.suppress(FileNotFoundError):\n                    lock.unlink()\n                continue\n            raise RuntimeError("another codex-flow update or rollback is already running")\n    else:\n        raise RuntimeError("unable to acquire codex-flow update lock")\n    try:\n        yield\n    finally:\n        if fd is not None:\n            os.close(fd)\n        with contextlib.suppress(FileNotFoundError):\n            lock.unlink()\n\n\ndef _bin_dir() -> Path:\n''',
)

replace_once(
    updater,
    '''    targets = {\n        "policy": _policy_path(),\n        "version": _state_dir() / "version",\n        "source": _state_dir() / "source",\n        "defaults": _state_dir() / "defaults.toml",\n    }\n''',
    '''    targets = {\n        "policy": _policy_path(),\n        "version": _state_dir() / "version",\n        "source": _state_dir() / "source",\n        "defaults": _state_dir() / "defaults.toml",\n        "migrations": _migration_state_path(),\n        "hooks": _codex_home() / "hooks.json",\n    }\n''',
)

replace_once(
    updater,
    '''    for name in ("version", "source", "defaults"):\n        src = backup / name\n        dst_name = "defaults.toml" if name == "defaults" else name\n        if src.exists():\n            _atomic_copy(src, _state_dir() / dst_name)\n''',
    '''    for name in ("version", "source", "defaults"):\n        src = backup / name\n        dst_name = "defaults.toml" if name == "defaults" else name\n        if src.exists():\n            _atomic_copy(src, _state_dir() / dst_name)\n    migrations = backup / "migrations"\n    if migrations.exists():\n        _atomic_copy(migrations, _migration_state_path())\n    else:\n        with contextlib.suppress(FileNotFoundError):\n            _migration_state_path().unlink()\n    hooks = backup / "hooks"\n    hooks_path = _codex_home() / "hooks.json"\n    if hooks.exists():\n        _atomic_copy(hooks, hooks_path)\n''',
)

replace_once(
    updater,
    '''def perform_update(*, force_check: bool = True) -> UpdateState:\n''',
    '''def _perform_update_unlocked(*, force_check: bool = True) -> UpdateState:\n''',
)
replace_once(
    updater,
    '''        return _install_package(root, version, manifest)\n\n\ndef rollback() -> UpdateState:\n''',
    '''        return _install_package(root, version, manifest)\n\n\ndef perform_update(*, force_check: bool = True) -> UpdateState:\n    with update_lock():\n        return _perform_update_unlocked(force_check=force_check)\n\n\ndef _rollback_unlocked() -> UpdateState:\n''',
)
replace_once(
    updater,
    '''    except Exception:\n        _restore_snapshot(backup)\n        raise\n\n\ndef _legacy_git_update() -> int:\n''',
    '''    except Exception:\n        _restore_snapshot(backup)\n        raise\n\n\ndef rollback() -> UpdateState:\n    with update_lock():\n        return _rollback_unlocked()\n\n\ndef _legacy_git_update() -> int:\n''',
)

# Avoid UnicodeEncodeError on legacy Windows consoles (e.g. cp1252). Keep the
# user's encoding and replace only glyphs that cannot be represented.
replace_once(
    updater,
    '''def main(argv: list[str] | None = None) -> int:\n''',
    '''def _configure_stdio() -> None:\n    for stream in (sys.stdout, sys.stderr):\n        reconfigure = getattr(stream, "reconfigure", None)\n        if reconfigure is None:\n            continue\n        try:\n            reconfigure(errors="replace")\n        except (OSError, ValueError):\n            pass\n\n\ndef main(argv: list[str] | None = None) -> int:\n    _configure_stdio()\n''',
)

# Add focused transaction regressions.
tests = Path("tests/test_updater.py")
text = tests.read_text(encoding="utf-8")
marker = '''    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:\n'''
addition = '''    def test_update_lock_rejects_concurrent_writer(self) -> None:\n        with updater.update_lock():\n            with self.assertRaisesRegex(RuntimeError, "already running"):\n                with updater.update_lock():\n                    pass\n\n    def test_snapshot_restore_restores_migration_state(self) -> None:\n        migration_state = self.state / "state" / "migrations.json"\n        migration_state.parent.mkdir(parents=True, exist_ok=True)\n        migration_state.write_text('{"applied": ["before"]}\\n', encoding="utf-8")\n        backup = updater._snapshot("1.7.0")\n        migration_state.write_text('{"applied": ["after"]}\\n', encoding="utf-8")\n        updater._restore_snapshot(backup)\n        payload = json.loads(migration_state.read_text(encoding="utf-8"))\n        self.assertEqual(payload["applied"], ["before"])\n\n'''
if addition not in text:
    if marker not in text:
        raise SystemExit("test insertion marker missing")
    tests.write_text(text.replace(marker, addition + marker, 1), encoding="utf-8")
