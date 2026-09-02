from pathlib import Path

updater = Path("scripts/updater.py")
text = updater.read_text(encoding="utf-8")

anchor = '''def start_background_check() -> bool:
'''
install_lock = '''@contextlib.contextmanager
def install_lock():
    """Require exclusive ownership for update/rollback writers."""
    with update_lock() as acquired:
        if not acquired:
            raise RuntimeError("another codex-flow update or rollback is already running")
        yield


'''
if "def install_lock()" not in text:
    if anchor not in text:
        raise SystemExit("install lock anchor missing")
    text = text.replace(anchor, install_lock + anchor, 1)

if "def _perform_update_unlocked" not in text:
    text = text.replace(
        "def perform_update(*, force_check: bool = True) -> UpdateState:\n",
        "def _perform_update_unlocked(*, force_check: bool = True) -> UpdateState:\n",
        1,
    )
    needle = '''        return _install_package(root, version, manifest)


def rollback() -> UpdateState:
'''
    if needle not in text:
        raise SystemExit("perform wrapper anchor missing")
    text = text.replace(needle, '''        return _install_package(root, version, manifest)


def perform_update(*, force_check: bool = True) -> UpdateState:
    with install_lock():
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
    with install_lock():
        return _rollback_unlocked()


def _legacy_git_update() -> int:
''', 1)

updater.write_text(text, encoding="utf-8")

tests = Path("tests/test_updater.py")
t = tests.read_text(encoding="utf-8")
marker = '    def test_legacy_update_detached_checkout_reinstalls_without_pull(self) -> None:\n'
addition = '''    def test_install_lock_rejects_concurrent_writer(self) -> None:
        with updater.install_lock():
            with self.assertRaisesRegex(RuntimeError, "already running"):
                with updater.install_lock():
                    pass

'''
if "test_install_lock_rejects_concurrent_writer" not in t:
    if marker not in t:
        raise SystemExit("test marker missing")
    t = t.replace(marker, addition + marker, 1)
tests.write_text(t, encoding="utf-8")
