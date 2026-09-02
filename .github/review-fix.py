#!/usr/bin/env python3
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(path: str, *, bom: bool = False) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig" if bom else "utf-8")


def save(path: str, text: str, *, bom: bool = False) -> None:
    (ROOT / path).write_text(text, encoding="utf-8-sig" if bom else "utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, found {count}")
    return text.replace(old, new, 1)


def replace_count(text: str, old: str, new: str, expected: int, label: str) -> str:
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} matches, found {count}")
    return text.replace(old, new)


# ---------------------------------------------------------------------------
# updater.py: updater protocol version, exact state, live-owner lock, activation
# state separation, reconciler persistence, backup cleanup and stale-cache race.
# ---------------------------------------------------------------------------
path = "scripts/updater.py"
text = load(path)
text = replace_once(
    text,
    'STATE_SCHEMA = 1\nMANIFEST_SCHEMA = 1\n',
    'STATE_SCHEMA = 2\nMANIFEST_SCHEMA = 1\nUPDATER_VERSION = "1.0.0"\n',
    "updater protocol version",
)
text = replace_once(
    text,
    '    restart_required: bool = False\n    mandatory: bool = False\n',
    '    restart_required: bool = False\n    flowpilot_restart_required: bool = False\n    mandatory: bool = False\n',
    "separate restart state",
)
text = replace_once(
    text,
    '''def load_state() -> UpdateState:\n    state = UpdateState.from_mapping(_read_json(_update_state_path(), {}))\n    state.current_version = current_version()\n    return state\n''',
    '''def load_state() -> UpdateState:\n    state = UpdateState.from_mapping(_read_json(_update_state_path(), {}))\n    state.current_version = current_version()\n    # Cached availability is advisory. Recompute it from the version currently\n    # installed on disk so a second process cannot reinstall a version another\n    # updater completed after this cache was written.\n    if state.latest_version:\n        state.update_available = is_newer(state.latest_version, state.current_version)\n        if not state.update_available and state.status in {"available", "downloading", "installing"}:\n            state.status = "latest"\n    return state\n''',
    "recompute cached availability",
)
text = replace_once(
    text,
    '    if minimum_updater and is_newer(minimum_updater, current_version()):\n',
    '    if minimum_updater and is_newer(minimum_updater, UPDATER_VERSION):\n',
    "minimum updater semantics",
)

old_lock = '''@contextlib.contextmanager\ndef update_lock(stale_seconds: int = 600):\n    path = _lock_path()\n    path.parent.mkdir(parents=True, exist_ok=True)\n    if path.exists():\n        with contextlib.suppress(OSError):\n            if time.time() - path.stat().st_mtime > stale_seconds:\n                path.unlink()\n    fd: int | None = None\n    try:\n        fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)\n        os.write(fd, str(os.getpid()).encode("ascii"))\n        os.close(fd)\n        fd = None\n        yield True\n    except FileExistsError:\n        yield False\n    finally:\n        if fd is not None:\n            os.close(fd)\n        with contextlib.suppress(FileNotFoundError):\n            if path.exists() and path.read_text(errors="ignore").strip() == str(os.getpid()):\n                path.unlink()\n'''
new_lock = '''def _pid_is_alive(pid: int) -> bool:\n    """Best-effort process liveness check; uncertainty is treated as alive."""\n    if pid <= 0:\n        return False\n    if pid == os.getpid():\n        return True\n    if os.name == "nt":\n        try:\n            import ctypes\n\n            process_query_limited_information = 0x1000\n            kernel32 = ctypes.windll.kernel32\n            handle = kernel32.OpenProcess(process_query_limited_information, False, pid)\n            if handle:\n                kernel32.CloseHandle(handle)\n                return True\n            return False\n        except Exception:\n            return True\n    try:\n        os.kill(pid, 0)\n        return True\n    except ProcessLookupError:\n        return False\n    except PermissionError:\n        return True\n    except OSError:\n        return True\n\n\n@contextlib.contextmanager\ndef update_lock(stale_seconds: int = 600):\n    path = _lock_path()\n    path.parent.mkdir(parents=True, exist_ok=True)\n    if path.exists():\n        owner_pid: int | None = None\n        with contextlib.suppress(OSError, ValueError):\n            owner_pid = int(path.read_text(errors="ignore").strip())\n        age = 0.0\n        with contextlib.suppress(OSError):\n            age = max(0.0, time.time() - path.stat().st_mtime)\n        should_reclaim = (\n            owner_pid is not None and not _pid_is_alive(owner_pid)\n        ) or (\n            owner_pid is None and age > stale_seconds\n        )\n        if should_reclaim:\n            with contextlib.suppress(OSError):\n                path.unlink()\n    fd: int | None = None\n    owned = False\n    try:\n        fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)\n        os.write(fd, str(os.getpid()).encode("ascii"))\n        os.close(fd)\n        fd = None\n        owned = True\n        yield True\n    except FileExistsError:\n        yield False\n    finally:\n        if fd is not None:\n            os.close(fd)\n        if owned:\n            with contextlib.suppress(FileNotFoundError):\n                if path.exists() and path.read_text(errors="ignore").strip() == str(os.getpid()):\n                    path.unlink()\n'''
text = replace_once(text, old_lock, new_lock, "live-owner update lock")

text = replace_once(
    text,
    '''    if state.restart_required:\n        version = state.current_version or state.latest_version or ""\n        return f"⚠️ v{version} 已安装 · 请重启 Codex" if zh else f"⚠️ v{version} installed · restart Codex"\n''',
    '''    if state.flowpilot_restart_required or state.restart_required:\n        version = state.current_version or state.latest_version or ""\n        if state.flowpilot_restart_required and state.restart_required:\n            return f"⚠️ v{version} 已安装 · 请重启 FlowPilot / Codex" if zh else f"⚠️ v{version} installed · restart FlowPilot / Codex"\n        if state.flowpilot_restart_required:\n            return f"⚠️ v{version} 已安装 · 请重启 FlowPilot" if zh else f"⚠️ v{version} installed · restart FlowPilot"\n        return f"⚠️ v{version} 已安装 · 请重启 Codex" if zh else f"⚠️ v{version} installed · restart Codex"\n''',
    "CLI restart label",
)

for marker in (
    '        "updater.py",\n        "telemetry.py",\n',
):
    # Occurs in snapshot and sync lists. Fallback list is one-line and patched below.
    text = replace_count(
        text,
        marker,
        '        "updater.py",\n        "update_runtime_config.py",\n        "telemetry.py",\n',
        2,
        "persist reconciler managed lists",
    )
    break
text = replace_once(
    text,
    '            for name in ("updater.py", "telemetry.py", "manage-hooks.py", "menu.py", "localization.py", "ui.py", "doctor.py", "strategy_runtime.py"):\n',
    '            for name in ("updater.py", "update_runtime_config.py", "telemetry.py", "manage-hooks.py", "menu.py", "localization.py", "ui.py", "doctor.py", "strategy_runtime.py"):\n',
    "persist reconciler bootstrap list",
)

text = replace_once(
    text,
    '''def _append_history(entry: dict[str, Any]) -> None:\n    history = _history()\n    history.append(entry)\n    atomic_write_json(_history_path(), history[-20:])\n''',
    '''def _append_history(entry: dict[str, Any]) -> None:\n    history = _history()\n    history.append(entry)\n    retained = history[-20:]\n    atomic_write_json(_history_path(), retained)\n    referenced = {str(item.get("backup")) for item in retained if item.get("backup")}\n    backup_root = _state_dir() / "backups"\n    if backup_root.exists():\n        for candidate in backup_root.iterdir():\n            if candidate.is_dir() and str(candidate) not in referenced:\n                shutil.rmtree(candidate, ignore_errors=True)\n''',
    "backup retention cleanup",
)

text = replace_once(
    text,
    '''        state.status = "available" if state.update_available else "latest"\n        state.restart_required = True\n        state.installed_at = utc_now()\n''',
    '''        state.status = "available" if state.update_available else "latest"\n        state.restart_required = bool(manifest.get("restart_required", True))\n        state.flowpilot_restart_required = (\n            platform.system().lower() == "darwin"\n            and any((target_version / "apps" / "macos-overlay" / "bin" / name).exists() for name in ("FlowPilot", "codex-flow-overlay"))\n        )\n        state.installed_at = utc_now()\n''',
    "install activation flags",
)
text = replace_once(
    text,
    '''        state.status = "available" if state.update_available else "latest"\n        state.restart_required = True\n        state.last_error = None\n        save_state(state)\n        _append_history({"from": current, "to": previous, "rollback": True, "installed_at": utc_now(), "backup": str(backup)})\n''',
    '''        state.status = "available" if state.update_available else "latest"\n        state.restart_required = True\n        state.flowpilot_restart_required = (\n            platform.system().lower() == "darwin"\n            and any((_state_dir() / "bin" / name).exists() for name in ("FlowPilot", "codex-flow-overlay"))\n        )\n        state.last_error = None\n        save_state(state)\n        _append_history({"from": current, "to": previous, "rollback": True, "installed_at": utc_now(), "backup": str(backup)})\n''',
    "rollback activation flags",
)
text = replace_count(
    text,
    '''    except Exception:\n        _restore_snapshot(backup)\n        raise\n''',
    '''    except Exception:\n        _restore_snapshot(backup)\n        shutil.rmtree(backup, ignore_errors=True)\n        raise\n''',
    2,
    "failed transaction backup cleanup",
)

text = replace_once(
    text,
    '''def _print_status(state: UpdateState, as_json: bool = False) -> None:\n    if as_json:\n        print(json.dumps(state.to_mapping(), ensure_ascii=False, indent=2, sort_keys=True))\n        return\n    if state.restart_required:\n        print(f"✓ codex-flow v{state.current_version} installed; restart Codex to activate updated policy/hooks snapshots.")\n    elif state.update_available and state.latest_version:\n''',
    '''def _print_status(state: UpdateState, as_json: bool = False) -> None:\n    if as_json:\n        print(json.dumps(state.to_mapping(), ensure_ascii=False, indent=2, sort_keys=True))\n        return\n    if state.flowpilot_restart_required and state.restart_required:\n        print(f"✓ codex-flow v{state.current_version} installed; restart FlowPilot and Codex to activate all updated components.")\n    elif state.flowpilot_restart_required:\n        print(f"✓ codex-flow v{state.current_version} installed; restart FlowPilot to load the updated app binary.")\n    elif state.restart_required:\n        print(f"✓ codex-flow v{state.current_version} installed; restart Codex to activate updated policy/hooks snapshots.")\n    elif state.update_available and state.latest_version:\n''',
    "status activation text",
)
text = replace_once(
    text,
    '''    parser.add_argument(\n        "--ack-restart",\n        action="store_true",\n        help="clear restart-required reminder after Codex has been fully restarted",\n    )\n    parser.add_argument("--no-legacy-fallback", action="store_true")\n''',
    '''    parser.add_argument(\n        "--ack-restart",\n        action="store_true",\n        help="clear Codex restart reminder after Codex has been fully restarted",\n    )\n    parser.add_argument(\n        "--ack-flowpilot-restart",\n        action="store_true",\n        help="clear FlowPilot restart reminder after the updated FlowPilot binary has launched",\n    )\n    parser.add_argument("--no-legacy-fallback", action="store_true")\n''',
    "FlowPilot ack parser",
)
text = replace_once(
    text,
    '''    if args.ack_restart:\n        state = load_state()\n        state.restart_required = False\n        save_state(state)\n        if not args.quiet:\n            print("✓ Restart reminder cleared after Codex restart.")\n        return 0\n    if args.command == "rollback":\n''',
    '''    if args.ack_restart:\n        state = load_state()\n        state.restart_required = False\n        save_state(state)\n        if not args.quiet:\n            print("✓ Codex restart reminder cleared.")\n        return 0\n    if args.ack_flowpilot_restart:\n        state = load_state()\n        state.flowpilot_restart_required = False\n        save_state(state)\n        if not args.quiet:\n            print("✓ FlowPilot restart reminder cleared.")\n        return 0\n    if args.command == "rollback":\n''',
    "FlowPilot ack handling",
)
text = replace_once(
    text,
    '''            if not args.quiet:\n                print(f"↩ Rolled back codex-flow to v{state.current_version}. Restart Codex to activate it.")\n            return 0\n''',
    '''            if not args.quiet:\n                print(f"↩ Rolled back codex-flow to v{state.current_version}.")\n                if state.flowpilot_restart_required:\n                    print("⚠ Restart FlowPilot to load the rolled-back app binary.")\n                if state.restart_required:\n                    print("⚠ Restart Codex to activate rolled-back policy/hooks snapshots.")\n            return 0\n''',
    "rollback output",
)
text = replace_once(
    text,
    '''            if not args.quiet:\n                print(f"✨ Updated codex-flow to v{state.current_version}.")\n                print("⚠ Restart Codex to activate updated FlowPilot policy/hooks snapshots.")\n            return 0\n''',
    '''            if not args.quiet:\n                print(f"✨ Updated codex-flow to v{state.current_version}.")\n                if state.flowpilot_restart_required:\n                    print("⚠ Restart FlowPilot to load the updated app binary.")\n                if state.restart_required:\n                    print("⚠ Restart Codex to activate updated FlowPilot policy/hooks snapshots.")\n            return 0\n''',
    "update output",
)
save(path, text)

# ---------------------------------------------------------------------------
# Manifest: minimum updater is an updater-protocol version, not product VERSION.
# ---------------------------------------------------------------------------
path = "scripts/generate-release-manifest.py"
text = load(path)
text = replace_once(
    text,
    'REPO = "ParsifalC/codex-flow"\n',
    'REPO = "ParsifalC/codex-flow"\nMINIMUM_UPDATER_VERSION = "1.0.0"\n',
    "manifest updater protocol constant",
)
text = replace_once(
    text,
    '        "minimum_updater_version": "1.7.0",\n',
    '        "minimum_updater_version": MINIMUM_UPDATER_VERSION,\n',
    "manifest updater protocol value",
)
save(path, text)

# ---------------------------------------------------------------------------
# Installer/runtime persistence: reconciler must survive source-checkout removal.
# ---------------------------------------------------------------------------
path = "install.sh"
text = load(path)
text = replace_once(
    text,
    'for file in updater.py telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py strategy_runtime.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done\n',
    'for file in updater.py update_runtime_config.py telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py strategy_runtime.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done\n',
    "install.sh reconciler persistence",
)
save(path, text)

path = "install.ps1"
text = load(path, bom=True)
text = replace_once(
    text,
    "foreach ($name in @('updater.py','telemetry.py','manage-hooks.py','menu.py','localization.py','ui.py','doctor.py','strategy_runtime.py')) { Copy-Item (Join-Path $RootDir \"scripts/$name\") (Join-Path $StateDir $name) -Force }\n",
    "foreach ($name in @('updater.py','update_runtime_config.py','telemetry.py','manage-hooks.py','menu.py','localization.py','ui.py','doctor.py','strategy_runtime.py')) { Copy-Item (Join-Path $RootDir \"scripts/$name\") (Join-Path $StateDir $name) -Force }\n",
    "install.ps1 reconciler persistence",
)
save(path, text, bom=True)

path = "scripts/doctor.py"
text = load(path)
text = replace_once(
    text,
    '        (STATE_DIR / "updater.py", "OTA updater"),\n',
    '        (STATE_DIR / "updater.py", "OTA updater"),\n        (STATE_DIR / "update_runtime_config.py", "runtime config reconciler"),\n',
    "doctor reconciler check",
)
save(path, text)

# ---------------------------------------------------------------------------
# FlowPilot: distinguish app-binary restart from Codex snapshot restart.
# A newly launched FlowPilot binary acknowledges only its own restart flag.
# ---------------------------------------------------------------------------
path = "apps/macos-overlay/Sources/Services/UpdateService.swift"
text = load(path)
text = replace_once(
    text,
    '    public var restartRequired: Bool?\n    public var mandatory: Bool?\n',
    '    public var restartRequired: Bool?\n    public var flowPilotRestartRequired: Bool?\n    public var mandatory: Bool?\n',
    "Swift FlowPilot restart state",
)
text = replace_once(
    text,
    '        case restartRequired = "restart_required"\n        case releaseURL = "release_url"\n',
    '        case restartRequired = "restart_required"\n        case flowPilotRestartRequired = "flowpilot_restart_required"\n        case releaseURL = "release_url"\n',
    "Swift FlowPilot coding key",
)
text = replace_once(
    text,
    '''    private init() {\n        refreshFromDisk()\n        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in\n''',
    '''    private init() {\n        refreshFromDisk()\n        acknowledgeFlowPilotRestartAfterLaunchIfNeeded()\n        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in\n''',
    "FlowPilot post-launch acknowledgement",
)
text = replace_once(
    text,
    '''    public var hasUpdateBadge: Bool {\n        (snapshot.notifyApp ?? true) && ((snapshot.updateAvailable ?? false) || (snapshot.restartRequired ?? false))\n    }\n\n    public var isRestartRequired: Bool {\n        snapshot.restartRequired ?? false\n    }\n''',
    '''    public var hasUpdateBadge: Bool {\n        (snapshot.notifyApp ?? true) && (\n            (snapshot.updateAvailable ?? false)\n            || (snapshot.restartRequired ?? false)\n            || (snapshot.flowPilotRestartRequired ?? false)\n        )\n    }\n\n    public var isRestartRequired: Bool {\n        snapshot.restartRequired ?? false\n    }\n\n    public var isFlowPilotRestartRequired: Bool {\n        snapshot.flowPilotRestartRequired ?? false\n    }\n''',
    "FlowPilot badge state",
)
text = replace_once(
    text,
    '''        if snapshot.restartRequired == true {\n            return L("Update installed · restart FlowPilot and Codex", "更新已安装 · 请重启 FlowPilot 和 Codex")\n        }\n''',
    '''        if snapshot.flowPilotRestartRequired == true && snapshot.restartRequired == true {\n            return L("Update installed · restart FlowPilot and Codex", "更新已安装 · 请重启 FlowPilot 和 Codex")\n        }\n        if snapshot.flowPilotRestartRequired == true {\n            return L("Update installed · restart FlowPilot", "更新已安装 · 请重启 FlowPilot")\n        }\n        if snapshot.restartRequired == true {\n            return L("Update installed · restart Codex", "更新已安装 · 请重启 Codex")\n        }\n''',
    "FlowPilot status text",
)
anchor = '''    // The OTA installer atomically replaces the FlowPilot binary on disk, but\n    // the already-running process remains the old executable. Launch the newly\n'''
method = '''    private func acknowledgeFlowPilotRestartAfterLaunchIfNeeded() {\n        guard snapshot.flowPilotRestartRequired == true, let executable = codexFlowExecutable else { return }\n        Task.detached(priority: .utility) {\n            let result = Self.executeUpdater(\n                executable: executable,\n                arguments: ["update", "--ack-flowpilot-restart", "--quiet"]\n            )\n            guard result.exitCode == 0 else { return }\n            await MainActor.run {\n                FlowPilotUpdateService.shared.refreshFromDisk()\n            }\n        }\n    }\n\n'''
text = replace_once(text, anchor, method + anchor, "FlowPilot launch ack method")
save(path, text)

path = "apps/macos-overlay/Sources/Views/UpdateView.swift"
text = load(path)
text = text.replace(
    'Image(systemName: service.isRestartRequired ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")',
    'Image(systemName: (service.isRestartRequired || service.isFlowPilotRestartRequired) ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")',
)
text = replace_once(
    text,
    '            if service.isRestartRequired {\n',
    '            if service.isRestartRequired || service.isFlowPilotRestartRequired {\n',
    "UpdateView restart section",
)
old_explanation = '''                        Text(L(\n                            "The new files are installed. Restart FlowPilot to load the new app binary, and fully restart Codex to activate updated FlowPilot policy and hook snapshots.",\n                            "新文件已经安装。请重启 FlowPilot 载入新的 App 程序，并完整重启 Codex 以激活新的 FlowPilot 策略和 Hook 快照。"\n                        ))\n'''
text = replace_once(text, old_explanation, '                        Text(restartExplanation)\n', "UpdateView conditional explanation")
restart_button = re.compile(r'''(?ms)                    Button \{\n                        service\.restartFlowPilot\(\)\n                    \} label: \{.*?                    \.disabled\(\n                        service\.isRestartingFlowPilot\n                        \|\| service\.isAcknowledgingRestart\n                        \|\| service\.isInstalling\n                        \|\| service\.isChecking\n                    \)\n''')
m = restart_button.search(text)
if not m:
    raise SystemExit("UpdateView FlowPilot restart button not found")
block = m.group(0)
indented = ''.join('    ' + line if line.strip() else line for line in block.splitlines(keepends=True))
text = text[:m.start()] + '                    if service.isFlowPilotRestartRequired {\n' + indented + '                    }\n' + text[m.end():]
codex_button = re.compile(r'''(?ms)                    Button \{\n                        service\.acknowledgeRestart\(\)\n                    \} label: \{.*?                    \.disabled\(\n                        service\.isAcknowledgingRestart\n                        \|\| service\.isRestartingFlowPilot\n                        \|\| service\.isInstalling\n                        \|\| service\.isChecking\n                    \)\n''')
m = codex_button.search(text)
if not m:
    raise SystemExit("UpdateView Codex restart button not found")
block = m.group(0)
indented = ''.join('    ' + line if line.strip() else line for line in block.splitlines(keepends=True))
text = text[:m.start()] + '                    if service.isRestartRequired {\n' + indented + '                    }\n' + text[m.end():]
text = replace_once(
    text,
    '''    private func versionRow(title: String, value: String) -> some View {\n''',
    '''    private var restartExplanation: String {\n        if service.isFlowPilotRestartRequired && service.isRestartRequired {\n            return L(\n                "The new files are installed. Restart FlowPilot to load the new app binary, and fully restart Codex to activate updated FlowPilot policy and hook snapshots.",\n                "新文件已经安装。请重启 FlowPilot 载入新的 App 程序，并完整重启 Codex 以激活新的 FlowPilot 策略和 Hook 快照。"\n            )\n        }\n        if service.isFlowPilotRestartRequired {\n            return L(\n                "The updated FlowPilot binary is installed. Restart FlowPilot to load it.",\n                "新的 FlowPilot 程序已经安装。请重启 FlowPilot 以载入新版本。"\n            )\n        }\n        return L(\n            "Fully restart Codex to activate updated FlowPilot policy and hook snapshots.",\n            "请完整重启 Codex，以激活新的 FlowPilot 策略和 Hook 快照。"\n        )\n    }\n\n    private func versionRow(title: String, value: String) -> some View {\n''',
    "UpdateView explanation helper",
)
save(path, text)

# ---------------------------------------------------------------------------
# Tests: ensure the review findings cannot regress.
# ---------------------------------------------------------------------------
path = "tests/test_updater.py"
text = load(path)
text = replace_once(text, 'import os\nimport sys\n', 'import os\nimport re\nimport sys\n', "test regex import")
text = replace_once(
    text,
    '        manifest["minimum_updater_version"] = "9.0.0"\n',
    '        manifest["minimum_updater_version"] = "1.1.0"\n',
    "minimum updater regression strength",
)
insert = '''    def test_cached_available_state_is_recomputed_after_another_process_updates(self) -> None:\n        state = updater.UpdateState(\n            current_version="1.7.0",\n            latest_version="1.8.0",\n            update_available=True,\n            status="available",\n        )\n        updater.save_state(state)\n        (self.state / "version").write_text("1.8.0\\n", encoding="utf-8")\n        loaded = updater.load_state()\n        self.assertEqual(loaded.current_version, "1.8.0")\n        self.assertFalse(loaded.update_available)\n        self.assertEqual(loaded.status, "latest")\n\n    def test_stale_lock_owned_by_live_process_is_not_stolen(self) -> None:\n        lock = updater._lock_path()\n        lock.parent.mkdir(parents=True, exist_ok=True)\n        lock.write_text(str(os.getpid()), encoding="ascii")\n        os.utime(lock, (1, 1))\n        with updater.update_lock(stale_seconds=1) as acquired:\n            self.assertFalse(acquired)\n        self.assertTrue(lock.exists())\n        lock.unlink()\n\n    def test_flowpilot_restart_ack_is_independent_from_codex_restart(self) -> None:\n        state = updater.load_state()\n        state.restart_required = True\n        state.flowpilot_restart_required = True\n        updater.save_state(state)\n        self.assertEqual(updater.main(["--ack-flowpilot-restart", "--quiet"]), 0)\n        loaded = updater.load_state()\n        self.assertTrue(loaded.restart_required)\n        self.assertFalse(loaded.flowpilot_restart_required)\n        self.assertEqual(updater.main(["--ack-restart", "--quiet"]), 0)\n        self.assertFalse(updater.load_state().restart_required)\n\n    def test_manifest_generator_uses_updater_protocol_version(self) -> None:\n        source = (ROOT / "scripts" / "generate-release-manifest.py").read_text(encoding="utf-8")\n        match = re.search(r'^MINIMUM_UPDATER_VERSION = "([^"]+)"$', source, re.MULTILINE)\n        self.assertIsNotNone(match)\n        self.assertEqual(match.group(1), updater.UPDATER_VERSION)\n\n'''
text = replace_once(
    text,
    '    def test_install_lock_rejects_concurrent_writer(self) -> None:\n',
    insert + '    def test_install_lock_rejects_concurrent_writer(self) -> None:\n',
    "review regression tests",
)
save(path, text)

# ---------------------------------------------------------------------------
# Docs: make the two activation states and updater protocol explicit.
# ---------------------------------------------------------------------------
path = "docs/update.md"
text = load(path)
text = replace_once(
    text,
    '`codex-flow update --ack-restart` 清除提醒。Updater 无法可靠跨平台证明 Codex 宿主进程是否已经完整重启，因此不伪造自动确认。\n',
    '`codex-flow update --ack-restart` 清除 Codex 提醒。macOS 还会单独记录 `flowpilot_restart_required`；新的 FlowPilot 进程成功启动后会自动执行 `codex-flow update --ack-flowpilot-restart`，因此 App 二进制激活与 Codex snapshot 激活不会被混成同一个状态。Updater 无法可靠跨平台证明 Codex 宿主进程是否已经完整重启，因此 Codex 仍要求用户主动确认。\n',
    "docs split activation state",
)
text = replace_once(
    text,
    '## Release channel\n',
    'manifest 中的 `minimum_updater_version` 使用独立的 updater protocol version（当前为 `1.0.0`），不会拿 codex-flow 产品版本代替 updater 版本做兼容判断。\n\n## Release channel\n',
    "docs updater protocol",
)
text = replace_once(
    text,
    '新的 CLI、updater、telemetry 和 FlowPilot binary 在 OTA 成功后已经落盘，但 Codex 对 Skill / Agent / Hook / policy snapshot 的加载需要完整重启 Codex 才能保证全部生效。因此 CLI / App 会明确保持 restart reminder，直到用户完成重启并主动确认，而不是把“文件已安装”和“Codex 已激活新 snapshot”混为一个状态。\n',
    '新的 CLI、updater、telemetry 和 FlowPilot binary 在 OTA 成功后已经落盘。macOS 上 `flowpilot_restart_required` 只表示需要重启 FlowPilot 进程来载入新 App binary，并由新进程自动清除；`restart_required` 则只表示 Codex 对 Skill / Agent / Hook / policy snapshot 的加载需要完整重启 Codex，并由用户完成重启后主动确认。两个状态互不代替。\n',
    "docs restart semantics",
)
save(path, text)
