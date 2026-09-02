from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"missing patch target: {label}")
    return text.replace(old, new, 1)


p = Path("scripts/updater.py")
s = p.read_text(encoding="utf-8")

s = replace_once(
    s,
    'USER_AGENT = "codex-flow-updater/1"\n\n',
    '''USER_AGENT = "codex-flow-updater/1"\n\n\ndef _configure_console() -> None:\n    if os.name != "nt":\n        return\n    for stream in (sys.stdout, sys.stderr):\n        reconfigure = getattr(stream, "reconfigure", None)\n        if callable(reconfigure):\n            with contextlib.suppress(OSError, ValueError):\n                reconfigure(errors="replace")\n\n\n_configure_console()\n\n''',
    "windows console",
)

s = replace_once(
    s,
    '    channel: str = "stable"\n    update_available: bool = False\n',
    '    channel: str = "stable"\n    notify_cli: bool = True\n    notify_app: bool = True\n    update_available: bool = False\n',
    "notification state fields",
)

s = replace_once(
    s,
    '''    if channel == "stable":\n        return not prerelease and "nightly" not in tag\n    if channel == "beta":\n        return "nightly" not in tag\n''',
    '''    normalized = _strip_v(tag)\n    if channel == "stable":\n        return not prerelease and "nightly" not in tag and "-" not in normalized\n    if channel == "beta":\n        return "nightly" not in tag\n''',
    "channel filtering",
)

s = replace_once(
    s,
    '    candidates = [r for r in releases if isinstance(r, dict) and _release_matches_channel(r, config.channel)]\n    if not candidates:\n',
    '    candidates = [r for r in releases if isinstance(r, dict) and _release_matches_channel(r, config.channel)]\n    candidates.sort(key=lambda r: version_key(str(r.get("tag_name") or "0.0.0")), reverse=True)\n    if not candidates:\n',
    "candidate sorting",
)

s = replace_once(
    s,
    '''    if not str(manifest.get("version") or "").strip():\n        raise RuntimeError("update manifest is missing version")\n    artifacts = manifest.get("artifacts")\n''',
    '''    if not str(manifest.get("version") or "").strip():\n        raise RuntimeError("update manifest is missing version")\n    minimum_updater = str(manifest.get("minimum_updater_version") or "").strip()\n    if minimum_updater and is_newer(minimum_updater, current_version()):\n        raise RuntimeError(\n            f"update requires updater v{_strip_v(minimum_updater)} or newer; "\n            "reinstall codex-flow once to refresh the updater"\n        )\n    artifacts = manifest.get("artifacts")\n''',
    "minimum updater",
)

s = replace_once(
    s,
    '    state.channel = config.channel\n    state.current_version = current_version()\n',
    '    state.channel = config.channel\n    state.notify_cli = config.notify_cli\n    state.notify_app = config.notify_app\n    state.current_version = current_version()\n',
    "check notification state",
)

s = replace_once(
    s,
    '    state = load_state()\n    state.channel = config.channel\n    if trigger_background and config.check and not cache_is_fresh(state, config):\n',
    '    state = load_state()\n    state.channel = config.channel\n    state.notify_cli = config.notify_cli\n    state.notify_app = config.notify_app\n    if trigger_background and config.check and not cache_is_fresh(state, config):\n',
    "cached notification state",
)

s = replace_once(
    s,
    'def update_menu_label(lang: str = "en", state: UpdateState | None = None) -> str:\n    state = state or load_state()\n    zh = lang.lower().startswith("zh")\n',
    'def update_menu_label(lang: str = "en", state: UpdateState | None = None) -> str:\n    state = state or load_state()\n    zh = lang.lower().startswith("zh")\n    if state.notify_cli is False:\n        return "🔄 检查更新" if zh else "🔄 Check for updates"\n',
    "CLI notify preference",
)

s = replace_once(
    s,
    '''    overlay_backup = backup / "overlay"\n    for name in ("FlowPilot", "codex-flow-overlay"):\n        path = _state_dir() / "bin" / name\n        if path.exists():\n            overlay_backup.mkdir(exist_ok=True)\n            shutil.copy2(path, overlay_backup / name)\n    return backup\n''',
    '''    overlay_backup = backup / "overlay"\n    for name in ("FlowPilot", "codex-flow-overlay"):\n        path = _state_dir() / "bin" / name\n        if path.exists():\n            overlay_backup.mkdir(exist_ok=True)\n            shutil.copy2(path, overlay_backup / name)\n\n    user_backup = backup / "user-managed"\n    user_backup.mkdir()\n    live_targets = {\n        "hooks.json": _codex_home() / "hooks.json",\n        "worker-explorer.toml": _codex_home() / "agents" / "worker-explorer.toml",\n        "worker-implementer.toml": _codex_home() / "agents" / "worker-implementer.toml",\n        "worker-reviewer.toml": _codex_home() / "agents" / "worker-reviewer.toml",\n        "SKILL.md": _codex_home() / "skills" / "flow-pilot" / "SKILL.md",\n        "migrations.json": _migration_state_path(),\n    }\n    presence: dict[str, bool] = {}\n    for name, path in live_targets.items():\n        presence[name] = path.exists()\n        if path.exists():\n            shutil.copy2(path, user_backup / name)\n    atomic_write_json(user_backup / "presence.json", presence)\n    return backup\n''',
    "full snapshot",
)

s = replace_once(
    s,
    '''    overlay = backup / "overlay"\n    if overlay.exists():\n        for path in overlay.iterdir():\n            _atomic_copy(path, _state_dir() / "bin" / path.name, executable=True)\n\n\ndef _read_policy_bool''',
    '''    overlay = backup / "overlay"\n    if overlay.exists():\n        for path in overlay.iterdir():\n            _atomic_copy(path, _state_dir() / "bin" / path.name, executable=True)\n\n    user_backup = backup / "user-managed"\n    if user_backup.exists():\n        presence = _read_json(user_backup / "presence.json", {})\n        live_targets = {\n            "hooks.json": _codex_home() / "hooks.json",\n            "worker-explorer.toml": _codex_home() / "agents" / "worker-explorer.toml",\n            "worker-implementer.toml": _codex_home() / "agents" / "worker-implementer.toml",\n            "worker-reviewer.toml": _codex_home() / "agents" / "worker-reviewer.toml",\n            "SKILL.md": _codex_home() / "skills" / "flow-pilot" / "SKILL.md",\n            "migrations.json": _migration_state_path(),\n        }\n        for name, dst in live_targets.items():\n            src = user_backup / name\n            if src.exists():\n                _atomic_copy(src, dst)\n            elif isinstance(presence, dict) and presence.get(name) is False:\n                with contextlib.suppress(FileNotFoundError):\n                    dst.unlink()\n\n\ndef _read_policy_bool''',
    "full restore",
)

s = replace_once(
    s,
    '''def _run_migrations(package_root: Path) -> None:\n    migrations_dir = package_root / "scripts" / "migrations"\n    if not migrations_dir.exists():\n        return\n    state = _read_json(_migration_state_path(), {"applied": []})\n    applied = set(state.get("applied") or []) if isinstance(state, dict) else set()\n    for script in sorted(migrations_dir.glob("*.py")):\n        migration_id = script.stem\n        if migration_id.startswith("_") or migration_id in applied:\n            continue\n        subprocess.run(\n            [sys.executable, str(script), "--policy", str(_policy_path())],\n            check=True,\n            env=os.environ.copy(),\n        )\n        applied.add(migration_id)\n        atomic_write_json(_migration_state_path(), {"applied": sorted(applied)})\n''',
    '''def _run_migrations(package_root: Path) -> list[str]:\n    migrations_dir = package_root / "scripts" / "migrations"\n    state = _read_json(_migration_state_path(), {"applied": []})\n    applied = set(state.get("applied") or []) if isinstance(state, dict) else set()\n    if not migrations_dir.exists():\n        return sorted(applied)\n    for script in sorted(migrations_dir.glob("*.py")):\n        migration_id = script.stem\n        if migration_id.startswith("_") or migration_id in applied:\n            continue\n        subprocess.run(\n            [sys.executable, str(script), "--policy", str(_policy_path())],\n            check=True,\n            env=os.environ.copy(),\n        )\n        applied.add(migration_id)\n    return sorted(applied)\n''',
    "transactional migrations",
)

s = replace_once(
    s,
    '        _run_migrations(staged_version)\n        _sync_managed_runtime(staged_version)\n        _run_health_check()\n',
    '        applied_migrations = _run_migrations(staged_version)\n        _sync_managed_runtime(staged_version)\n        _run_health_check()\n        atomic_write_json(_migration_state_path(), {"applied": applied_migrations})\n',
    "migration commit point",
)

s = replace_once(
    s,
    '    backup = _snapshot(current)\n    try:\n        _sync_managed_runtime(package_root)\n        _run_health_check()\n',
    '''    backup = _snapshot(current)\n    history_entry = next(\n        (entry for entry in reversed(_history()) if entry.get("from") == previous and entry.get("to") == current and entry.get("backup")),\n        None,\n    )\n    try:\n        if history_entry:\n            historical_backup = Path(str(history_entry["backup"]))\n            if historical_backup.exists():\n                _restore_snapshot(historical_backup)\n        _sync_managed_runtime(package_root)\n        _run_health_check()\n''',
    "rollback snapshot",
)

p.write_text(s, encoding="utf-8")

swift = Path("apps/macos-overlay/Sources/Services/UpdateService.swift")
sw = swift.read_text(encoding="utf-8")
sw = replace_once(
    sw,
    '    public var channel: String?\n    public var updateAvailable: Bool?\n',
    '    public var channel: String?\n    public var notifyCLI: Bool?\n    public var notifyApp: Bool?\n    public var updateAvailable: Bool?\n',
    "Swift notify fields",
)
sw = replace_once(
    sw,
    '        case schema, status, channel, mandatory, progress\n',
    '        case schema, status, channel, mandatory, progress\n        case notifyCLI = "notify_cli"\n        case notifyApp = "notify_app"\n',
    "Swift coding keys",
)
sw = replace_once(
    sw,
    '        (snapshot.updateAvailable ?? false) || (snapshot.restartRequired ?? false)\n',
    '        (snapshot.notifyApp ?? true) && ((snapshot.updateAvailable ?? false) || (snapshot.restartRequired ?? false))\n',
    "Swift badge preference",
)
swift.write_text(sw, encoding="utf-8")

doctor = Path("scripts/doctor.py")
d = doctor.read_text(encoding="utf-8")
d = replace_once(
    d,
    '        (STATE_DIR / "defaults.toml", "release policy defaults"),\n',
    '        (STATE_DIR / "defaults.toml", "release policy defaults"),\n        (STATE_DIR / "updater.py", "OTA updater"),\n',
    "doctor updater check",
)
doctor.write_text(d, encoding="utf-8")

tests = Path("tests/test_updater.py")
t = tests.read_text(encoding="utf-8")
marker = '    def test_safe_extract_rejects_zip_path_traversal(self) -> None:\n'
additions = '''    def test_stable_channel_rejects_unmarked_beta_tag(self) -> None:\n        release = {"tag_name": "v1.8.0-beta.1", "draft": False, "prerelease": False}\n        self.assertFalse(updater._release_matches_channel(release, "stable"))\n        self.assertTrue(updater._release_matches_channel(release, "beta"))\n\n    def test_menu_can_disable_cli_update_badge(self) -> None:\n        state = updater.UpdateState(current_version="1.7.0", latest_version="1.8.0", update_available=True, notify_cli=False)\n        self.assertEqual(updater.update_menu_label("en", state), "🔄 Check for updates")\n\n    def test_manifest_enforces_minimum_updater_version(self) -> None:\n        manifest = self.manifest()\n        manifest["minimum_updater_version"] = "9.0.0"\n        with self.assertRaises(RuntimeError):\n            updater._validate_manifest(manifest)\n\n'''
if additions not in t:
    if marker not in t:
        raise SystemExit("test insertion point missing")
    t = t.replace(marker, additions + marker, 1)
tests.write_text(t, encoding="utf-8")
