#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8-sig")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8", newline="\n")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one match, got {count}")
    return text.replace(old, new, 1)


def append_update_defaults() -> None:
    path = "policy/defaults.toml"
    text = read(path)
    if "\n[update]\n" not in text:
        if not text.endswith("\n"):
            text += "\n"
        text += """
[update]
channel = "stable"
check = true
check_interval_hours = 24
notify_cli = true
notify_app = true
auto_install = false
"""
    write(path, text)


def update_install_sh() -> None:
    path = "install.sh"
    text = read(path)
    text = replace_once(
        text,
        'EXISTING_TELEMETRY_RETENTION_DAYS="$(policy_or_default telemetry retention_days "$DEFAULT_TELEMETRY_RETENTION_DAYS")"\n',
        'EXISTING_TELEMETRY_RETENTION_DAYS="$(policy_or_default telemetry retention_days "$DEFAULT_TELEMETRY_RETENTION_DAYS")"\n'
        'EXISTING_UPDATE_CHANNEL="$(policy_or_default update channel stable)"\n'
        'EXISTING_UPDATE_CHECK="$(policy_or_default update check true)"\n'
        'EXISTING_UPDATE_INTERVAL="$(policy_or_default update check_interval_hours 24)"\n'
        'EXISTING_UPDATE_NOTIFY_CLI="$(policy_or_default update notify_cli true)"\n'
        'EXISTING_UPDATE_NOTIFY_APP="$(policy_or_default update notify_app true)"\n'
        'EXISTING_UPDATE_AUTO_INSTALL="$(policy_or_default update auto_install false)"\n',
        "install.sh existing update config",
    )
    text = replace_once(
        text,
        'TELEMETRY_RETENTION_DAYS="${CODEX_FLOW_TELEMETRY_RETENTION_DAYS:-$EXISTING_TELEMETRY_RETENTION_DAYS}"\nUI_LANGUAGE="auto"\n',
        'TELEMETRY_RETENTION_DAYS="${CODEX_FLOW_TELEMETRY_RETENTION_DAYS:-$EXISTING_TELEMETRY_RETENTION_DAYS}"\n'
        'UPDATE_CHANNEL="${CODEX_FLOW_UPDATE_CHANNEL:-$EXISTING_UPDATE_CHANNEL}"\n'
        'UPDATE_CHECK="${CODEX_FLOW_UPDATE_CHECK:-$EXISTING_UPDATE_CHECK}"\n'
        'UPDATE_INTERVAL="${CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS:-$EXISTING_UPDATE_INTERVAL}"\n'
        'UPDATE_NOTIFY_CLI="${CODEX_FLOW_UPDATE_NOTIFY_CLI:-$EXISTING_UPDATE_NOTIFY_CLI}"\n'
        'UPDATE_NOTIFY_APP="${CODEX_FLOW_UPDATE_NOTIFY_APP:-$EXISTING_UPDATE_NOTIFY_APP}"\n'
        'UPDATE_AUTO_INSTALL="${CODEX_FLOW_UPDATE_AUTO_INSTALL:-$EXISTING_UPDATE_AUTO_INSTALL}"\n'
        'UI_LANGUAGE="auto"\n',
        "install.sh update env",
    )
    text = replace_once(
        text,
        '[[ "$TELEMETRY_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer" >&2; exit 2; }\n\nmkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/flow-pilot" "$STATE_DIR" "$BIN_DIR"\n',
        '[[ "$TELEMETRY_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer" >&2; exit 2; }\n'
        'case "$UPDATE_CHANNEL" in stable|beta|nightly) ;; *) echo "CODEX_FLOW_UPDATE_CHANNEL must be stable, beta, or nightly" >&2; exit 2 ;; esac\n'
        'case "$UPDATE_CHECK" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_CHECK must be true or false" >&2; exit 2 ;; esac\n'
        'case "$UPDATE_NOTIFY_CLI" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_NOTIFY_CLI must be true or false" >&2; exit 2 ;; esac\n'
        'case "$UPDATE_NOTIFY_APP" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_NOTIFY_APP must be true or false" >&2; exit 2 ;; esac\n'
        'case "$UPDATE_AUTO_INSTALL" in true|false) ;; *) echo "CODEX_FLOW_UPDATE_AUTO_INSTALL must be true or false" >&2; exit 2 ;; esac\n'
        '[[ "$UPDATE_INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS must be a positive integer" >&2; exit 2; }\n\n'
        'mkdir -p "$CODEX_HOME/agents" "$CODEX_HOME/skills/flow-pilot" "$STATE_DIR" "$STATE_DIR/state" "$STATE_DIR/versions" "$BIN_DIR"\n',
        "install.sh validation",
    )
    text = replace_once(
        text,
        'source = "hooks+app-server"\nEOF\n',
        'source = "hooks+app-server"\n\n'
        '[update]\n'
        'channel = "$UPDATE_CHANNEL"\n'
        'check = $UPDATE_CHECK\n'
        'check_interval_hours = $UPDATE_INTERVAL\n'
        'notify_cli = $UPDATE_NOTIFY_CLI\n'
        'notify_app = $UPDATE_NOTIFY_APP\n'
        'auto_install = $UPDATE_AUTO_INSTALL\n'
        'EOF\n',
        "install.sh policy update section",
    )
    text = replace_once(
        text,
        'printf \'%s\\n\' "$VERSION" > "$STATE_DIR/version"\ncp "$DEFAULTS" "$STATE_DIR/defaults.toml"\n',
        'printf \'%s\\n\' "$VERSION" > "$STATE_DIR/version"\n'
        'printf \'%s\\n\' "$BIN_DIR" > "$STATE_DIR/bin_dir"\n'
        'cp "$DEFAULTS" "$STATE_DIR/defaults.toml"\n',
        "install.sh persist bin dir",
    )
    text = replace_once(
        text,
        'for file in telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py strategy_runtime.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done\n',
        'for file in updater.py telemetry.py manage-hooks.py menu.py localization.py ui.py doctor.py strategy_runtime.py; do cp "$ROOT_DIR/scripts/$file" "$STATE_DIR/$file"; done\n',
        "install.sh copy updater",
    )
    text = replace_once(
        text,
        'chmod +x "$STATE_DIR/telemetry.py" "$STATE_DIR/manage-hooks.py" "$STATE_DIR/menu.py" "$STATE_DIR/localization.py" "$STATE_DIR/ui.py" "$STATE_DIR/doctor.py" "$STATE_DIR/strategy_runtime.py"\n',
        'chmod +x "$STATE_DIR/updater.py" "$STATE_DIR/telemetry.py" "$STATE_DIR/manage-hooks.py" "$STATE_DIR/menu.py" "$STATE_DIR/localization.py" "$STATE_DIR/ui.py" "$STATE_DIR/doctor.py" "$STATE_DIR/strategy_runtime.py"\n',
        "install.sh updater executable",
    )
    write(path, text)


def update_install_ps1() -> None:
    path = "install.ps1"
    text = read(path)
    text = replace_once(
        text,
        "$ExistingTelemetryRetentionDays = Existing-OrDefault $existingText 'telemetry' 'retention_days' $DefaultTelemetryRetentionDays\n",
        "$ExistingTelemetryRetentionDays = Existing-OrDefault $existingText 'telemetry' 'retention_days' $DefaultTelemetryRetentionDays\n"
        "$ExistingUpdateChannel = Existing-OrDefault $existingText 'update' 'channel' 'stable'\n"
        "$ExistingUpdateCheck = Existing-OrDefault $existingText 'update' 'check' 'true'\n"
        "$ExistingUpdateInterval = Existing-OrDefault $existingText 'update' 'check_interval_hours' '24'\n"
        "$ExistingUpdateNotifyCli = Existing-OrDefault $existingText 'update' 'notify_cli' 'true'\n"
        "$ExistingUpdateNotifyApp = Existing-OrDefault $existingText 'update' 'notify_app' 'true'\n"
        "$ExistingUpdateAutoInstall = Existing-OrDefault $existingText 'update' 'auto_install' 'false'\n",
        "install.ps1 existing update config",
    )
    text = replace_once(
        text,
        "$TelemetryRetentionDays = if ($env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS) { $env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS } else { $ExistingTelemetryRetentionDays }\n$UiLanguage = 'auto'\n",
        "$TelemetryRetentionDays = if ($env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS) { $env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS } else { $ExistingTelemetryRetentionDays }\n"
        "$UpdateChannel = if ($env:CODEX_FLOW_UPDATE_CHANNEL) { $env:CODEX_FLOW_UPDATE_CHANNEL } else { $ExistingUpdateChannel }\n"
        "$UpdateCheck = if ($env:CODEX_FLOW_UPDATE_CHECK) { $env:CODEX_FLOW_UPDATE_CHECK } else { $ExistingUpdateCheck }\n"
        "$UpdateInterval = if ($env:CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS) { $env:CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS } else { $ExistingUpdateInterval }\n"
        "$UpdateNotifyCli = if ($env:CODEX_FLOW_UPDATE_NOTIFY_CLI) { $env:CODEX_FLOW_UPDATE_NOTIFY_CLI } else { $ExistingUpdateNotifyCli }\n"
        "$UpdateNotifyApp = if ($env:CODEX_FLOW_UPDATE_NOTIFY_APP) { $env:CODEX_FLOW_UPDATE_NOTIFY_APP } else { $ExistingUpdateNotifyApp }\n"
        "$UpdateAutoInstall = if ($env:CODEX_FLOW_UPDATE_AUTO_INSTALL) { $env:CODEX_FLOW_UPDATE_AUTO_INSTALL } else { $ExistingUpdateAutoInstall }\n"
        "$UiLanguage = 'auto'\n",
        "install.ps1 update env",
    )
    text = replace_once(
        text,
        "if ($TelemetryRetentionDays -notmatch '^[1-9][0-9]*$') { throw 'CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer' }\n\nNew-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents'),(Join-Path $CodexHome 'skills/flow-pilot'),$StateDir,$BinDir | Out-Null\n",
        "if ($TelemetryRetentionDays -notmatch '^[1-9][0-9]*$') { throw 'CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer' }\n"
        "if ($UpdateChannel -notin @('stable','beta','nightly')) { throw 'CODEX_FLOW_UPDATE_CHANNEL must be stable, beta, or nightly' }\n"
        "if ($UpdateCheck -notin @('true','false')) { throw 'CODEX_FLOW_UPDATE_CHECK must be true or false' }\n"
        "if ($UpdateNotifyCli -notin @('true','false')) { throw 'CODEX_FLOW_UPDATE_NOTIFY_CLI must be true or false' }\n"
        "if ($UpdateNotifyApp -notin @('true','false')) { throw 'CODEX_FLOW_UPDATE_NOTIFY_APP must be true or false' }\n"
        "if ($UpdateAutoInstall -notin @('true','false')) { throw 'CODEX_FLOW_UPDATE_AUTO_INSTALL must be true or false' }\n"
        "if ($UpdateInterval -notmatch '^[1-9][0-9]*$') { throw 'CODEX_FLOW_UPDATE_CHECK_INTERVAL_HOURS must be a positive integer' }\n\n"
        "New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents'),(Join-Path $CodexHome 'skills/flow-pilot'),$StateDir,(Join-Path $StateDir 'state'),(Join-Path $StateDir 'versions'),$BinDir | Out-Null\n",
        "install.ps1 validation",
    )
    text = replace_once(
        text,
        'source = "hooks+app-server"\n"@ | ForEach-Object { Write-Utf8NoBom $Policy $_ }\n',
        'source = "hooks+app-server"\n\n'
        '[update]\n'
        'channel = "$UpdateChannel"\n'
        'check = $UpdateCheck\n'
        'check_interval_hours = $UpdateInterval\n'
        'notify_cli = $UpdateNotifyCli\n'
        'notify_app = $UpdateNotifyApp\n'
        'auto_install = $UpdateAutoInstall\n'
        '"@ | ForEach-Object { Write-Utf8NoBom $Policy $_ }\n',
        "install.ps1 policy update section",
    )
    text = replace_once(
        text,
        "foreach ($name in @('telemetry.py','manage-hooks.py','menu.py','localization.py','ui.py','doctor.py','strategy_runtime.py')) { Copy-Item (Join-Path $RootDir \"scripts/$name\") (Join-Path $StateDir $name) -Force }\n",
        "foreach ($name in @('updater.py','telemetry.py','manage-hooks.py','menu.py','localization.py','ui.py','doctor.py','strategy_runtime.py')) { Copy-Item (Join-Path $RootDir \"scripts/$name\") (Join-Path $StateDir $name) -Force }\n",
        "install.ps1 copy updater",
    )
    write(path, text)


def update_launchers() -> None:
    path = "bin/codex-flow"
    text = read(path)
    text = replace_once(
        text,
        '  update)\n    src="$(source_dir)"\n',
        '  update)\n'
        '    shift\n'
        '    updater_script="$(script_path updater.py 2>/dev/null || true)"\n'
        '    if [[ -n "$updater_script" && -f "$updater_script" ]]; then\n'
        '      exec python3 "$updater_script" "$@"\n'
        '    fi\n'
        '    # Compatibility fallback for installs created before the OTA updater existed.\n'
        '    src="$(source_dir)"\n',
        "unix updater entry",
    )
    text = replace_once(
        text,
        '    exec python3 "$src/scripts/doctor.py"\n    ;;\n  overlay)\n',
        '    exec python3 "$src/scripts/doctor.py"\n'
        '    ;;\n'
        '  rollback)\n'
        '    shift\n'
        '    updater_script="$(script_path updater.py 2>/dev/null || true)"\n'
        '    [[ -n "$updater_script" && -f "$updater_script" ]] || fail "$(cf_t \'OTA updater is missing; reinstall codex-flow\' \'OTA 更新组件缺失，请重新安装 codex-flow\')"\n'
        '    exec python3 "$updater_script" rollback "$@"\n'
        '    ;;\n'
        '  overlay)\n',
        "unix rollback entry",
    )
    write(path, text)

    path = "bin/codex-flow.ps1"
    text = read(path)
    text = replace_once(
        text,
        "    'update' {\n        $src = Get-SourceDir\n",
        "    'update' {\n"
        "        $updater = Get-ScriptPath 'updater.py'\n"
        "        if ($updater) {\n"
        "            & python3 $updater @rest\n"
        "            exit $LASTEXITCODE\n"
        "        }\n"
        "        # Compatibility fallback for installs created before the OTA updater existed.\n"
        "        $src = Get-SourceDir\n",
        "powershell updater entry",
    )
    text = replace_once(
        text,
        "        & python3 (Join-Path $src 'scripts/doctor.py')\n        exit $LASTEXITCODE\n    }\n    'overlay' {\n",
        "        & python3 (Join-Path $src 'scripts/doctor.py')\n"
        "        exit $LASTEXITCODE\n"
        "    }\n"
        "    'rollback' {\n"
        "        $updater = Get-ScriptPath 'updater.py'\n"
        "        if (-not $updater) { throw (L 'OTA updater is missing; reinstall codex-flow' 'OTA 更新组件缺失，请重新安装 codex-flow') }\n"
        "        & python3 $updater rollback @rest\n"
        "        exit $LASTEXITCODE\n"
        "    }\n"
        "    'overlay' {\n",
        "powershell rollback entry",
    )
    write(path, text)


def update_menu() -> None:
    path = "scripts/menu.py"
    text = read(path)
    marker = "except ImportError:\n    from scripts.localization import resolve_language, tr  # type: ignore\n\n"
    addition = marker + "try:\n    from updater import cached_status as cached_update_status, update_menu_label as updater_menu_label\nexcept ImportError:\n    from scripts.updater import (  # type: ignore\n        cached_status as cached_update_status,\n        update_menu_label as updater_menu_label,\n    )\n\n"
    text = replace_once(text, marker, addition, "menu updater import")
    text = replace_once(
        text,
        "        print_banner(version)\n        items = [\n",
        "        print_banner(version)\n        update_state = cached_update_status(trigger_background=True)\n        update_label = updater_menu_label(LANG, update_state)\n        items = [\n",
        "menu cached update state",
    )
    text = replace_once(
        text,
        '("8", T("🔄 Check and pull updates", "🔄 检查与拉取更新"), "update"),',
        '("8", update_label, "update"),',
        "menu dynamic update label",
    )
    write(path, text)


def update_summary_view() -> None:
    path = "apps/macos-overlay/Sources/Views/SummaryView.swift"
    text = read(path)
    text = replace_once(
        text,
        "    @ObservedObject var state: OverlayState\n    @ObservedObject private var localization = AppLocalization.shared\n",
        "    @ObservedObject var state: OverlayState\n    @ObservedObject private var localization = AppLocalization.shared\n    @ObservedObject private var updateService = FlowPilotUpdateService.shared\n",
        "SummaryView update observed object",
    )
    text = replace_once(
        text,
        "    @State private var isLogsExpanded: Bool = false\n",
        "    @State private var isLogsExpanded: Bool = false\n    @State private var showUpdatePopover: Bool = false\n",
        "SummaryView popover state",
    )
    old = """            Spacer()
            
            // Pin Toggle Button
"""
    new = """            Spacer()

            // Shared OTA entry. CLI and app both read the same update.json state.
            Button {
                showUpdatePopover.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: updateService.isRestartRequired ? "arrow.clockwise.circle" : "arrow.down.circle")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(updateService.hasUpdateBadge ? .cyan : .white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.06)))

                    if updateService.hasUpdateBadge {
                        Circle()
                            .fill(updateService.isRestartRequired ? Color.orange : Color.red)
                            .frame(width: 6.5, height: 6.5)
                            .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 1))
                            .offset(x: 1.5, y: -1.5)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("Software Update", "软件更新"))
            .popover(isPresented: $showUpdatePopover, arrowEdge: .top) {
                FlowPilotUpdateView()
            }
            
            // Pin Toggle Button
"""
    text = replace_once(text, old, new, "SummaryView update button")
    write(path, text)


def update_ci() -> None:
    path = ".github/workflows/ci.yml"
    text = read(path)
    text = replace_once(
        text,
        "          python3 -m py_compile scripts/menu.py\n",
        "          python3 -m py_compile scripts/menu.py\n"
        "          python3 -m py_compile scripts/updater.py\n"
        "          python3 -m py_compile scripts/package-release.py\n"
        "          python3 -m py_compile scripts/generate-release-manifest.py\n"
        "          python3 -m py_compile scripts/migrations/0001_update_settings.py\n",
        "CI updater compile",
    )
    text = replace_once(
        text,
        "      - name: ChatGPT MCP test\n        run: bash tests/chatgpt-mcp.sh\n",
        "      - name: OTA updater test\n        run: python3 -m unittest tests.test_updater\n"
        "      - name: ChatGPT MCP test\n        run: bash tests/chatgpt-mcp.sh\n",
        "CI updater test",
    )
    write(path, text)


def update_updater_bootstrap() -> None:
    path = "scripts/updater.py"
    text = read(path)
    marker = """def _install_package(package_root: Path, version: str, manifest: dict[str, Any]) -> UpdateState:
"""
    helper = '''def _ensure_current_version_package(version: str) -> Path | None:
    """Capture the pre-OTA installation so the first OTA update can roll back."""

    versions = _state_dir() / "versions"
    versions.mkdir(parents=True, exist_ok=True)
    target = versions / version
    if target.exists():
        return target
    staging = versions / f".{version}.bootstrap-{os.getpid()}"
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    source = None
    source_file = _state_dir() / "source"
    with contextlib.suppress(OSError):
        candidate = Path(source_file.read_text(encoding="utf-8-sig").strip())
        if candidate.exists() and (candidate / "VERSION").exists():
            source = candidate
    try:
        if source is not None:
            for name in ("VERSION", "install.sh", "install.ps1", "bin", "scripts", "templates", "completions", "policy"):
                src = source / name
                dst = staging / name
                if src.is_dir():
                    shutil.copytree(src, dst, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo"))
                elif src.is_file():
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
            overlay = source / "apps" / "macos-overlay" / "bin"
            if overlay.exists():
                shutil.copytree(overlay, staging / "apps" / "macos-overlay" / "bin")
        else:
            (staging / "VERSION").write_text(version + "\\n", encoding="utf-8")
            scripts = staging / "scripts"
            scripts.mkdir(parents=True)
            for name in ("updater.py", "telemetry.py", "manage-hooks.py", "menu.py", "localization.py", "ui.py", "doctor.py", "strategy_runtime.py"):
                src = _state_dir() / name
                if src.exists():
                    shutil.copy2(src, scripts / name)
            for name in ("strategies", "telemetry_core"):
                src = _state_dir() / name
                if src.exists():
                    shutil.copytree(src, scripts / name)
            (staging / "bin").mkdir()
            for name in ("codex-flow", "codex-flow.ps1", "codex-flow.cmd"):
                src = _bin_dir() / name
                if src.exists():
                    shutil.copy2(src, staging / "bin" / name)
            defaults = _state_dir() / "defaults.toml"
            if defaults.exists():
                (staging / "policy").mkdir()
                shutil.copy2(defaults, staging / "policy" / "defaults.toml")
            for name in ("FlowPilot", "codex-flow-overlay"):
                src = _state_dir() / "bin" / name
                if src.exists():
                    dst = staging / "apps" / "macos-overlay" / "bin" / name
                    dst.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, dst)
        os.replace(staging, target)
        return target
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        return None


'''
    if "def _ensure_current_version_package" not in text:
        text = replace_once(text, marker, helper + marker, "updater rollback bootstrap helper")
    text = replace_once(
        text,
        "    current = current_version()\n    backup = _snapshot(current)\n",
        "    current = current_version()\n    _ensure_current_version_package(current)\n    backup = _snapshot(current)\n",
        "updater bootstrap invocation",
    )
    write(path, text)


def update_tests() -> None:
    path = "tests/test_updater.py"
    text = read(path)
    text = replace_once(text, "import os\n", "import os\nimport sys\n", "updater test sys import")
    text = replace_once(
        text,
        "updater = importlib.util.module_from_spec(SPEC)\nSPEC.loader.exec_module(updater)\n",
        "updater = importlib.util.module_from_spec(SPEC)\nsys.modules[SPEC.name] = updater\nSPEC.loader.exec_module(updater)\n",
        "updater test module registration",
    )
    write(path, text)


def main() -> None:
    append_update_defaults()
    update_install_sh()
    update_install_ps1()
    update_launchers()
    update_menu()
    update_summary_view()
    update_ci()
    update_updater_bootstrap()
    update_tests()
    print("OTA integration transformations applied")


if __name__ == "__main__":
    main()
