#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


path = ROOT / "scripts" / "updater.py"
text = path.read_text(encoding="utf-8")
old = '''@contextlib.contextmanager
def update_lock(stale_seconds: int = 600):
    path = _lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        with contextlib.suppress(OSError):
            if time.time() - path.stat().st_mtime > stale_seconds:
                path.unlink()
    fd: int | None = None
'''
new = '''def _pid_is_alive(pid: int) -> bool:
    """Best-effort process liveness check; failures are treated as alive."""
    if pid <= 0:
        return False
    if pid == os.getpid():
        return True
    if os.name == "nt":
        try:
            import ctypes

            process_query_limited_information = 0x1000
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.OpenProcess(process_query_limited_information, False, pid)
            if handle:
                kernel32.CloseHandle(handle)
                return True
            return False
        except Exception:
            return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return True


@contextlib.contextmanager
def update_lock(stale_seconds: int = 600):
    path = _lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        owner_pid: int | None = None
        with contextlib.suppress(OSError, ValueError):
            owner_pid = int(path.read_text(errors="ignore").strip())
        age = 0.0
        with contextlib.suppress(OSError):
            age = max(0.0, time.time() - path.stat().st_mtime)
        # A crashed writer can be reclaimed immediately once its PID is gone.
        # A malformed lock can be reclaimed after the stale threshold. Never
        # delete a lock whose owner is still alive, regardless of elapsed time.
        should_reclaim = (
            owner_pid is not None and not _pid_is_alive(owner_pid)
        ) or (
            owner_pid is None and age > stale_seconds
        )
        if should_reclaim:
            with contextlib.suppress(OSError):
                path.unlink()
    fd: int | None = None
'''
text = replace_once(text, old, new, "lock implementation")
path.write_text(text, encoding="utf-8")


test_path = ROOT / "tests" / "test_updater.py"
test = test_path.read_text(encoding="utf-8")
insert = '''    def test_stale_lock_owned_by_live_process_is_not_stolen(self) -> None:
        lock = updater._lock_path()
        lock.parent.mkdir(parents=True, exist_ok=True)
        lock.write_text(str(os.getpid()), encoding="ascii")
        old = 1
        os.utime(lock, (old, old))
        with updater.update_lock(stale_seconds=1) as acquired:
            self.assertFalse(acquired)
        self.assertTrue(lock.exists())
        lock.unlink()

'''
test = replace_once(
    test,
    '    def test_install_lock_rejects_concurrent_writer(self) -> None:\n',
    insert + '    def test_install_lock_rejects_concurrent_writer(self) -> None:\n',
    "live lock regression",
)
test_path.write_text(test, encoding="utf-8")
