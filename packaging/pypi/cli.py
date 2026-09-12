"""Unified cross-platform CLI dispatcher for codex-flow."""

from __future__ import annotations

import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_DIR = CODEX_HOME / "codex-flow"
SOURCE_FILE = STATE_DIR / "source"
POLICY_FILE = CODEX_HOME / "codex-flow.toml"


def get_resource_root() -> Path:
    """Resolve the directory containing runtime scripts and assets."""
    # 1. Check if bundled data directory inside the package exists
    bundled = Path(__file__).resolve().parent / "data"
    if (bundled / "VERSION").exists() and (bundled / "scripts").exists():
        return bundled

    # 2. Check if running from a git checkout / source tree
    for parent in Path(__file__).resolve().parents:
        if (parent / "VERSION").exists() and (parent / "scripts").exists():
            return parent

    # 3. Check installed state source file
    if SOURCE_FILE.exists():
        try:
            target = Path(SOURCE_FILE.read_text(encoding="utf-8").strip())
            if target.is_dir():
                return target
        except OSError:
            pass

    return bundled


def find_script(name: str, root: Path) -> Optional[Path]:
    """Find a script in resource root or state dir."""
    candidates = [
        root / "scripts" / name,
        root / name,
        STATE_DIR / name,
    ]
    for c in candidates:
        try:
            if c.is_file():
                return c
        except OSError:
            continue
    return None


def run_python_script(script_path: Path, args: List[str], env: Optional[dict] = None) -> int:
    """Run a python script using current interpreter and appropriate environment."""
    run_env = os.environ.copy()
    if env:
        run_env.update(env)

    # Ensure script's directory and its parent are in PYTHONPATH for internal imports
    script_dir = str(script_path.parent)
    parent_dir = str(script_path.parents[1]) if len(script_path.parents) > 1 else script_dir
    existing_pp = run_env.get("PYTHONPATH", "")
    new_pp = f"{script_dir}{os.pathsep}{parent_dir}"
    run_env["PYTHONPATH"] = f"{new_pp}{os.pathsep}{existing_pp}" if existing_pp else new_pp

    cmd = [sys.executable, str(script_path), *args]
    try:
        proc = subprocess.run(cmd, env=run_env)
        return proc.returncode
    except KeyboardInterrupt:
        return 130


def handle_install(root: Path, args: List[str]) -> int:
    """Execute installation bootstrap."""
    is_windows = platform.system() == "Windows"

    # Prefer install-release scripts for full multi-platform + prebuilt FlowPilot support
    if is_windows:
        installer = root / "install-release.ps1"
        if not installer.exists():
            installer = root / "install.ps1"
        if not installer.exists():
            print("Error: install.ps1 not found in codex-flow package", file=sys.stderr)
            return 1
        cmd = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(installer), *args]
    else:
        installer = root / "install-release.sh"
        if not installer.exists():
            installer = root / "install.sh"
        if not installer.exists():
            print("Error: install.sh not found in codex-flow package", file=sys.stderr)
            return 1
        cmd = ["bash", str(installer), *args]

    try:
        proc = subprocess.run(cmd)
        return proc.returncode
    except KeyboardInterrupt:
        return 130


def handle_overlay(root: Path, args: List[str]) -> int:
    """Execute native FlowPilot macOS overlay."""
    if platform.system() != "Darwin":
        print("FlowPilot native overlay widget is only available on macOS.", file=sys.stderr)
        return 1

    candidates = [
        STATE_DIR / "bin" / "FlowPilot",
        STATE_DIR / "bin" / "codex-flow-overlay",
        root / "apps" / "macos-overlay" / "bin" / "FlowPilot",
        root / "apps" / "macos-overlay" / "bin" / "codex-flow-overlay",
    ]
    overlay_bin = None
    for c in candidates:
        if c.is_file() and os.access(c, os.X_OK):
            overlay_bin = c
            break

    if not overlay_bin:
        print(
            "FlowPilot native overlay is not built or installed yet. Run: codex-flow install",
            file=sys.stderr,
        )
        return 1

    sub = args[0] if args else "toggle"
    if sub in ("start", "restart"):
        logs_dir = STATE_DIR / "logs"
        logs_dir.mkdir(parents=True, exist_ok=True)
        start_log = logs_dir / "flowpilot-start.log"
        with open(start_log, "a", encoding="utf-8") as lf:
            proc = subprocess.Popen([str(overlay_bin), "start"], stdout=lf, stderr=lf)
        print("🚀 Launched FlowPilot in background.")
        return 0
    else:
        proc = subprocess.run([str(overlay_bin), *args])
        return proc.returncode


def main(argv: Optional[List[str]] = None) -> int:
    """Main CLI entry point."""
    if argv is None:
        argv = sys.argv[1:]

    root = get_resource_root()

    if not argv:
        if sys.stdin.isatty() and sys.stdout.isatty() and os.environ.get("TERM") != "dumb":
            menu = find_script("menu.py", root)
            if menu:
                return run_python_script(menu, [])
        argv = ["help"]

    cmd = argv[0]
    rest = argv[1:]

    if cmd in ("install", "init"):
        return handle_install(root, rest)

    if cmd in ("status", "help", "-h", "--help"):
        ui = find_script("ui.py", root)
        if not ui:
            print("Error: ui.py helper not found; reinstall codex-flow", file=sys.stderr)
            return 1
        sub = "status" if cmd == "status" else "help"
        return run_python_script(ui, [sub, *rest])

    if cmd == "language":
        ui = find_script("ui.py", root)
        if not ui:
            print("Error: ui.py helper not found; reinstall codex-flow", file=sys.stderr)
            return 1
        return run_python_script(ui, ["language", *rest])

    if cmd == "strategy":
        strat = find_script("strategy_runtime.py", root)
        if not strat:
            print("Error: strategy_runtime.py not found; reinstall codex-flow", file=sys.stderr)
            return 1
        return run_python_script(strat, ["--policy", str(POLICY_FILE), *rest])

    if cmd in ("usage", "telemetry"):
        tel = find_script("telemetry.py", root)
        if not tel:
            print("Error: telemetry.py not found; reinstall codex-flow", file=sys.stderr)
            return 1
        sub_args = rest if rest else ["last"]
        return run_python_script(tel, sub_args)

    if cmd == "doctor":
        doc = find_script("doctor.py", root)
        if not doc:
            print("Error: doctor.py not found; reinstall codex-flow", file=sys.stderr)
            return 1
        return run_python_script(doc, rest)

    if cmd == "update":
        upd = find_script("updater.py", root)
        if not upd:
            print("Error: updater.py not found; reinstall codex-flow", file=sys.stderr)
            return 1
        return run_python_script(upd, rest)

    if cmd == "rollback":
        upd = find_script("updater.py", root)
        if not upd:
            print("Error: updater.py not found; reinstall codex-flow", file=sys.stderr)
            return 1
        return run_python_script(upd, ["rollback", *rest])

    if cmd == "overlay":
        return handle_overlay(root, rest)

    if cmd == "benchmark":
        bench = find_script("run-benchmark.py", root)
        if bench:
            return run_python_script(bench, rest)

    if cmd == "benchmark-local":
        bench = find_script("benchmark-local.py", root)
        if bench:
            return run_python_script(bench, rest)

    if cmd == "benchmark-analyze":
        bench = find_script("analyze-benchmark.py", root)
        if bench:
            return run_python_script(bench, rest)

    print(f"codex-flow: unknown command: {cmd}", file=sys.stderr)
    print("Run 'codex-flow help' for available commands.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
