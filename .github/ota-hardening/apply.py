from pathlib import Path
import re


def sub_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE | re.DOTALL)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 replacement, got {count}")
    return updated


path = Path("scripts/updater.py")
text = path.read_text(encoding="utf-8")

# Add a portable exclusive-file lock immediately after migration-state helper.
text = sub_once(
    text,
    r'(def _migration_state_path\(\) -> Path:\n    return _update_dir\(\) / "migrations\.json"\n)',
    r'''\1

def _install_lock_path() -> Path:
    return _update_dir() / "install.lock"


@contextlib.contextmanager
def update_lock(stale_after_seconds: int = 2 * 60 * 60):
    """Serialize update/rollback writers across CLI and FlowPilot processes."""

    lock = _install_lock_path()
    lock.parent.mkdir(parents=True, exist_ok=True)
    fd = None
    for attempt in range(2):
        try:
            fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.write(fd, f"pid={os.getpid()}\nstarted_at={utc_now()}\n".encode("utf-8"))
            os.close(fd)
            fd = None
            break
        except FileExistsError:
            try:
                stale = time.time() - lock.stat().st_mtime > stale_after_seconds
            except OSError:
                stale = False
            if stale and attempt == 0:
                with contextlib.suppress(FileNotFoundError):
                    lock.unlink()
                continue
            raise RuntimeError("another codex-flow update or rollback is already running")
    else:
        raise RuntimeError("unable to acquire codex-flow update lock")
    try:
        yield
    finally:
        if fd is not None:
            os.close(fd)
        with contextlib.suppress(FileNotFoundError):
            lock.unlink()
''',
    "insert lock",
)

# Extend snapshot targets without rewriting surrounding implementation.
text = sub_once(
    text,
    r'("defaults": _state_dir\(\) / "defaults\.toml",\n)(\s*})',
    r'''\1        "migrations": _migration_state_path(),
        "hooks": _codex_home() / "hooks.json",
\2''',
    "snapshot targets",
)

# Restore migration marker + hooks after normal state metadata.
anchor = '''    for name in ("version", "source", "defaults"):
        src = backup / name
        dst_name = "defaults.toml" if name == "defaults" else name
        if src.exists():
            _atomic_copy(src, _state_dir() / dst_name)
'''
if anchor not in text:
    raise SystemExit("restore anchor missing")
text = text.replace(anchor, anchor + '''    migrations = backup / "migrations"
    if migrations.exists():
        _atomic_copy(migrations, _migration_state_path())
    else:
        with contextlib.suppress(FileNotFoundError):
            _migration_state_path().unlink()
    hooks = backup / "hooks"
    hooks_path = _codex_home() / "hooks.json"
    if hooks.exists():
        _atomic_copy(hooks, hooks_path)
''', 1)

# Wrap update and rollback writers. Function bodies remain unchanged.
text = text.replace("def perform_update(*, force_check: bool = True) -> UpdateState:\n", "def _perform_update_unlocked(*, force_check: bool = True) -> UpdateState:\n", 1)
needle = '''        return _install_package(root, version, manifest)


def rollback() -> UpdateState:
'''
if needle not in text:
    raise SystemExit("update wrapper anchor missing")
text = text.replace(needle, '''        return _install_package(root, version, manifest)


def perform_update(*, force_check: bool = True) -> UpdateState:
    with update_lock():
        return _perform_update_unlocked(force_check=force_check)


def _rollback_unlocked() -> UpdateState:
''', 1)
needle = '''    except Exception:
        _restore_snapshot(backup)
        raise


def _legacy_git_update() -> int:
'''
if needle not in text:
    raise SystemExit("rollback wrapper anchor missing")
text = text.replace(needle, '''    except Exception:
        _restore_snapshot(backup)
        raise


def rollback() -> UpdateState:
    with update_lock():
        return _rollback_unlocked()


def _legacy_git_update() -> int:
''', 1)

# Gracefully degrade glyphs on legacy Windows consoles instead of crashing.
needle = "def main(argv: list[str] | None = None) -> int:\n"
if needle not in text:
    raise SystemExit("main anchor missing")
text = text.replace(needle, '''def _configure_stdio() -> None:
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(errors="replace")
        except (OSError, ValueError):
            pass


def main(argv: list[str] | None = None) -> int:
    _configure_stdio()
''', 1)

path.write_text(text, encoding="utf-8")

# Add focused regressions.
tests = Path("tests/test_updater.py")
t = tests.read_text(encoding="utf-8")
marker = '    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:\n'
addition = '''    def test_update_lock_rejects_concurrent_writer(self) -> None:
        with updater.update_lock():
            with self.assertRaisesRegex(RuntimeError, "already running"):
                with updater.update_lock():
                    pass

    def test_snapshot_restore_restores_migration_state(self) -> None:
        migration_state = self.state / "state" / "migrations.json"
        migration_state.parent.mkdir(parents=True, exist_ok=True)
        migration_state.write_text('{"applied": ["before"]}\n', encoding="utf-8")
        backup = updater._snapshot("1.7.0")
        migration_state.write_text('{"applied": ["after"]}\n', encoding="utf-8")
        updater._restore_snapshot(backup)
        payload = json.loads(migration_state.read_text(encoding="utf-8"))
        self.assertEqual(payload["applied"], ["before"])

'''
if "test_update_lock_rejects_concurrent_writer" not in t:
    if marker not in t:
        raise SystemExit("test marker missing")
    t = t.replace(marker, addition + marker, 1)
tests.write_text(t, encoding="utf-8")
