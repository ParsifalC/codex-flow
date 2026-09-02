#!/usr/bin/env python3
"""Release-driven self updater for codex-flow.

The updater is deliberately stdlib-only so the installed CLI and the native
FlowPilot app can share one durable update state without adding runtime deps.
It supports cached/non-blocking update checks, checksum verified release
artifacts, transactional managed-file replacement, version history and rollback.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterable

REPO = "ParsifalC/codex-flow"
STATE_SCHEMA = 1
MANIFEST_SCHEMA = 1
DEFAULT_CHECK_INTERVAL_HOURS = 24
DEFAULT_RELEASES_API = f"https://api.github.com/repos/{REPO}/releases?per_page=20"
MANIFEST_ASSET = "codex-flow-update.json"
USER_AGENT = "codex-flow-updater/1"


def _configure_console() -> None:
    if os.name != "nt":
        return
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if callable(reconfigure):
            with contextlib.suppress(OSError, ValueError):
                reconfigure(errors="replace")


_configure_console()


def _codex_home() -> Path:
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()


def _state_dir() -> Path:
    return _codex_home() / "codex-flow"


def _policy_path() -> Path:
    return _codex_home() / "codex-flow.toml"


def _update_dir() -> Path:
    return _state_dir() / "state"


def _update_state_path() -> Path:
    return _update_dir() / "update.json"


def _history_path() -> Path:
    return _update_dir() / "update-history.json"


def _migration_state_path() -> Path:
    return _update_dir() / "migrations.json"


def _bin_dir() -> Path:
    override = os.environ.get("CODEX_FLOW_BIN_DIR")
    if override:
        return Path(override).expanduser()
    persisted = _state_dir() / "bin_dir"
    if persisted.exists():
        try:
            value = persisted.read_text(encoding="utf-8-sig").strip()
            if value:
                return Path(value).expanduser()
        except OSError:
            pass
    return Path.home() / ".local" / "bin"


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except (TypeError, ValueError):
        return None


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_name, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_name)


def atomic_write_json(path: Path, payload: Any) -> None:
    atomic_write_text(path, json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def _read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError, TypeError):
        return default


def _strip_v(version: str) -> str:
    version = (version or "").strip()
    return version[1:] if version.lower().startswith("v") else version


def version_key(version: str) -> tuple[tuple[int, ...], int, tuple[Any, ...]]:
    """Return a deterministic SemVer-ish comparison key.

    Stable releases sort after prereleases with the same numeric core. The
    project currently uses simple x.y.z tags; the tolerant parser also keeps
    beta/rc channels predictable without depending on packaging.version.
    """

    raw = _strip_v(version).split("+", 1)[0]
    core, sep, prerelease = raw.partition("-")
    nums: list[int] = []
    for piece in core.split("."):
        match = re.match(r"^(\d+)", piece)
        nums.append(int(match.group(1)) if match else 0)
    while len(nums) < 3:
        nums.append(0)
    pre_key: list[Any] = []
    if sep:
        for token in re.split(r"[.-]", prerelease):
            pre_key.append((0, int(token)) if token.isdigit() else (1, token.lower()))
    return tuple(nums), 0 if sep else 1, tuple(pre_key)


def is_newer(candidate: str, current: str) -> bool:
    return version_key(candidate) > version_key(current)


def current_version() -> str:
    for path in (_state_dir() / "version", Path(__file__).resolve().parents[1] / "VERSION"):
        try:
            value = path.read_text(encoding="utf-8-sig").strip()
            if value:
                return _strip_v(value)
        except OSError:
            pass
    return "0.0.0"


def platform_key() -> str:
    system = platform.system().lower()
    machine = platform.machine().lower()
    if machine in {"amd64", "x86_64"}:
        machine = "x86_64"
    elif machine in {"aarch64", "arm64"}:
        machine = "arm64"
    if system == "darwin":
        return f"darwin-{machine}"
    if system == "windows":
        return f"windows-{machine}"
    return f"linux-{machine}"


def _simple_toml_value(text: str, section: str, key: str) -> str | None:
    section_match = re.search(
        rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)", text
    )
    if not section_match:
        return None
    key_match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", section_match.group(1))
    if not key_match:
        return None
    value = re.sub(r"\s+#.*$", "", key_match.group(1)).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value


def _as_bool(value: str | None, fallback: bool) -> bool:
    if value is None:
        return fallback
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass
class UpdateConfig:
    channel: str = "stable"
    check: bool = True
    check_interval_hours: int = DEFAULT_CHECK_INTERVAL_HOURS
    notify_cli: bool = True
    notify_app: bool = True
    auto_install: bool = False
    releases_api: str = DEFAULT_RELEASES_API
    manifest_url: str | None = None


def load_config(policy: Path | None = None) -> UpdateConfig:
    path = policy or _policy_path()
    config = UpdateConfig()
    try:
        text = path.read_text(encoding="utf-8-sig")
    except OSError:
        text = ""
    config.channel = (_simple_toml_value(text, "update", "channel") or config.channel).lower()
    config.check = _as_bool(_simple_toml_value(text, "update", "check"), config.check)
    config.notify_cli = _as_bool(_simple_toml_value(text, "update", "notify_cli"), config.notify_cli)
    config.notify_app = _as_bool(_simple_toml_value(text, "update", "notify_app"), config.notify_app)
    config.auto_install = _as_bool(_simple_toml_value(text, "update", "auto_install"), config.auto_install)
    interval = _simple_toml_value(text, "update", "check_interval_hours")
    if interval and interval.isdigit() and int(interval) > 0:
        config.check_interval_hours = int(interval)
    config.releases_api = os.environ.get("CODEX_FLOW_UPDATE_RELEASES_API", config.releases_api)
    config.manifest_url = os.environ.get("CODEX_FLOW_UPDATE_MANIFEST_URL") or None
    return config


@dataclass
class UpdateState:
    schema: int = STATE_SCHEMA
    status: str = "unknown"
    current_version: str = "0.0.0"
    latest_version: str | None = None
    channel: str = "stable"
    notify_cli: bool = True
    notify_app: bool = True
    update_available: bool = False
    checked_at: str | None = None
    last_attempt_at: str | None = None
    restart_required: bool = False
    mandatory: bool = False
    release_url: str | None = None
    release_notes: str | None = None
    artifact_available: bool = False
    artifact_platform: str | None = None
    last_error: str | None = None
    previous_version: str | None = None
    installed_at: str | None = None
    progress: float | None = None
    extra: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_mapping(cls, payload: dict[str, Any] | None) -> "UpdateState":
        payload = dict(payload or {})
        known = {field_name for field_name in cls.__dataclass_fields__}
        kwargs = {key: value for key, value in payload.items() if key in known and key != "extra"}
        extra = {key: value for key, value in payload.items() if key not in known}
        state = cls(**kwargs)
        if isinstance(payload.get("extra"), dict):
            extra.update(payload["extra"])
        state.extra = extra
        return state

    def to_mapping(self) -> dict[str, Any]:
        payload = asdict(self)
        extra = payload.pop("extra", {})
        payload.update(extra)
        return payload


def load_state() -> UpdateState:
    state = UpdateState.from_mapping(_read_json(_update_state_path(), {}))
    state.current_version = current_version()
    return state


def save_state(state: UpdateState) -> None:
    state.schema = STATE_SCHEMA
    atomic_write_json(_update_state_path(), state.to_mapping())


def cache_is_fresh(state: UpdateState, config: UpdateConfig) -> bool:
    checked = _parse_iso(state.checked_at)
    if checked is None:
        return False
    return time.time() - checked < config.check_interval_hours * 3600


def _request_bytes(url: str, timeout: float = 8.0) -> bytes:
    if url.startswith("file://"):
        return Path(url[7:]).read_bytes()
    local = Path(url)
    if "://" not in url and local.exists():
        return local.read_bytes()
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _request_json(url: str, timeout: float = 8.0) -> Any:
    return json.loads(_request_bytes(url, timeout=timeout).decode("utf-8-sig"))


def _release_matches_channel(release: dict[str, Any], channel: str) -> bool:
    if release.get("draft"):
        return False
    tag = str(release.get("tag_name") or "").lower()
    prerelease = bool(release.get("prerelease"))
    normalized = _strip_v(tag)
    if channel == "stable":
        return not prerelease and "nightly" not in tag and "-" not in normalized
    if channel == "beta":
        return "nightly" not in tag
    if channel == "nightly":
        return "nightly" in tag
    return not prerelease


def _manifest_from_release_api(config: UpdateConfig) -> tuple[dict[str, Any], dict[str, Any]]:
    releases = _request_json(config.releases_api)
    if not isinstance(releases, list):
        raise RuntimeError("release API returned an unexpected payload")
    candidates = [r for r in releases if isinstance(r, dict) and _release_matches_channel(r, config.channel)]
    candidates.sort(key=lambda r: version_key(str(r.get("tag_name") or "0.0.0")), reverse=True)
    if not candidates:
        raise RuntimeError(f"no {config.channel} release found")
    # Prefer the newest release that actually participates in the OTA protocol.
    # During rollout there may be older, pre-OTA GitHub releases without a
    # manifest. If the newest public release is not newer than the installed
    # version, treat the installed version as current instead of surfacing a
    # spurious update-check error in the CLI/App.
    for release in candidates:
        assets = release.get("assets") or []
        manifest_asset = next(
            (item for item in assets if isinstance(item, dict) and item.get("name") == MANIFEST_ASSET), None
        )
        if not manifest_asset or not manifest_asset.get("browser_download_url"):
            continue
        manifest = _request_json(str(manifest_asset["browser_download_url"]))
        if not isinstance(manifest, dict):
            raise RuntimeError("update manifest is not an object")
        return manifest, release

    newest_release = candidates[0]
    newest_tag = _strip_v(str(newest_release.get("tag_name") or "0.0.0"))
    installed = current_version()
    if not is_newer(newest_tag, installed):
        return (
            {
                "schema": MANIFEST_SCHEMA,
                "version": installed,
                "channel": config.channel,
                "restart_required": False,
                "mandatory": False,
                "release_url": newest_release.get("html_url"),
                "release_notes": "",
                "artifacts": {},
            },
            newest_release,
        )
    raise RuntimeError(f"release {newest_release.get('tag_name', '')} does not provide {MANIFEST_ASSET}")


def fetch_manifest(config: UpdateConfig) -> tuple[dict[str, Any], dict[str, Any]]:
    if config.manifest_url:
        manifest = _request_json(config.manifest_url)
        if not isinstance(manifest, dict):
            raise RuntimeError("update manifest is not an object")
        return manifest, {}
    return _manifest_from_release_api(config)


def _validate_manifest(manifest: dict[str, Any]) -> None:
    if int(manifest.get("schema", 0)) != MANIFEST_SCHEMA:
        raise RuntimeError(f"unsupported update manifest schema: {manifest.get('schema')}")
    if not str(manifest.get("version") or "").strip():
        raise RuntimeError("update manifest is missing version")
    minimum_updater = str(manifest.get("minimum_updater_version") or "").strip()
    if minimum_updater and is_newer(minimum_updater, current_version()):
        raise RuntimeError(
            f"update requires updater v{_strip_v(minimum_updater)} or newer; "
            "reinstall codex-flow once to refresh the updater"
        )
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        raise RuntimeError("update manifest is missing artifacts")


def _artifact_for_platform(manifest: dict[str, Any], key: str | None = None) -> dict[str, Any] | None:
    artifacts = manifest.get("artifacts") or {}
    value = artifacts.get(key or platform_key()) if isinstance(artifacts, dict) else None
    return value if isinstance(value, dict) else None


def check_for_updates(*, force: bool = False, quiet: bool = False) -> UpdateState:
    config = load_config()
    state = load_state()
    state.channel = config.channel
    state.notify_cli = config.notify_cli
    state.notify_app = config.notify_app
    state.current_version = current_version()
    if not config.check and not force:
        return state
    if not force and cache_is_fresh(state, config):
        return state

    state.last_attempt_at = utc_now()
    try:
        manifest, release = fetch_manifest(config)
        _validate_manifest(manifest)
        latest = _strip_v(str(manifest["version"]))
        artifact = _artifact_for_platform(manifest)
        state.latest_version = latest
        state.update_available = is_newer(latest, state.current_version)
        state.status = "available" if state.update_available else "latest"
        state.checked_at = utc_now()
        state.last_error = None
        state.mandatory = bool(manifest.get("mandatory", False))
        state.release_url = str(
            manifest.get("release_url") or release.get("html_url") or state.release_url or ""
        ) or None
        notes = manifest.get("release_notes") or release.get("body")
        state.release_notes = str(notes) if notes else None
        state.artifact_platform = platform_key()
        state.artifact_available = bool(
            artifact and artifact.get("url") and artifact.get("sha256")
        )
        state.extra["manifest"] = manifest
        save_state(state)
    except Exception as exc:  # keep a known cached result usable on transient failures
        state.last_error = str(exc)
        if state.status == "checking":
            state.status = "unknown"
        save_state(state)
        if not quiet:
            pass
    return state


def cached_status(*, trigger_background: bool = False) -> UpdateState:
    config = load_config()
    state = load_state()
    state.channel = config.channel
    state.notify_cli = config.notify_cli
    state.notify_app = config.notify_app
    if trigger_background and config.check and not cache_is_fresh(state, config):
        start_background_check()
    return state


def _lock_path() -> Path:
    return _update_dir() / "check.lock"


@contextlib.contextmanager
def update_lock(stale_seconds: int = 600):
    path = _lock_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        with contextlib.suppress(OSError):
            if time.time() - path.stat().st_mtime > stale_seconds:
                path.unlink()
    fd: int | None = None
    try:
        fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.write(fd, str(os.getpid()).encode("ascii"))
        os.close(fd)
        fd = None
        yield True
    except FileExistsError:
        yield False
    finally:
        if fd is not None:
            os.close(fd)
        with contextlib.suppress(FileNotFoundError):
            if path.exists() and path.read_text(errors="ignore").strip() == str(os.getpid()):
                path.unlink()


def start_background_check() -> bool:
    """Spawn a silent checker and return immediately.

    UI surfaces call this only after rendering cached state, so a slow network can
    never delay the CLI menu or the native app launch.
    """

    config = load_config()
    state = load_state()
    if not config.check or cache_is_fresh(state, config):
        return False
    cmd = [sys.executable, str(Path(__file__).resolve()), "--check", "--quiet"]
    kwargs: dict[str, Any] = {
        "stdin": subprocess.DEVNULL,
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "close_fds": os.name != "nt",
    }
    if os.name == "nt":
        kwargs["creationflags"] = (
            getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            | getattr(subprocess, "DETACHED_PROCESS", 0)
        )
    else:
        kwargs["start_new_session"] = True
    try:
        subprocess.Popen(cmd, **kwargs)
        return True
    except OSError:
        return False


def update_menu_label(lang: str = "en", state: UpdateState | None = None) -> str:
    state = state or load_state()
    zh = lang.lower().startswith("zh")
    if state.notify_cli is False:
        return "🔄 检查更新" if zh else "🔄 Check for updates"
    if state.restart_required:
        version = state.current_version or state.latest_version or ""
        return f"⚠️ v{version} 已安装 · 请重启 Codex" if zh else f"⚠️ v{version} installed · restart Codex"
    if state.update_available and state.latest_version:
        return (
            f"🆕 更新 codex-flow · v{state.latest_version} 可用"
            if zh
            else f"🆕 Update codex-flow · v{state.latest_version} available"
        )
    if state.status == "latest" and state.current_version:
        return (
            f"✅ 已是最新版本 · v{state.current_version}"
            if zh
            else f"✅ Up to date · v{state.current_version}"
        )
    return "🔄 检查更新" if zh else "🔄 Check for updates"


def _safe_target(root: Path, member_name: str) -> Path:
    target = (root / member_name).resolve()
    root_resolved = root.resolve()
    if target != root_resolved and root_resolved not in target.parents:
        raise RuntimeError(f"unsafe archive member: {member_name}")
    return target


def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    if archive.suffix.lower() == ".zip":
        with zipfile.ZipFile(archive) as zf:
            for info in zf.infolist():
                _safe_target(destination, info.filename)
            zf.extractall(destination)
        return
    with tarfile.open(archive, "r:*") as tf:
        for member in tf.getmembers():
            _safe_target(destination, member.name)
            if member.issym() or member.islnk():
                raise RuntimeError(f"release archive may not contain links: {member.name}")
        tf.extractall(destination)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if url.startswith("file://"):
        shutil.copy2(Path(url[7:]), destination)
        return
    local = Path(url)
    if "://" not in url and local.exists():
        shutil.copy2(local, destination)
        return
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=30) as response, destination.open("wb") as out:
        shutil.copyfileobj(response, out, length=1024 * 1024)


def _package_root(extract_dir: Path) -> Path:
    if (extract_dir / "VERSION").exists():
        return extract_dir
    children = [p for p in extract_dir.iterdir() if p.is_dir()]
    candidates = [p for p in children if (p / "VERSION").exists()]
    if len(candidates) == 1:
        return candidates[0]
    raise RuntimeError("release artifact does not contain a codex-flow package root")


def _atomic_copy(src: Path, dst: Path, executable: bool | None = None) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{dst.name}.", dir=str(dst.parent))
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        shutil.copy2(src, tmp)
        if executable is True and os.name != "nt":
            tmp.chmod(tmp.stat().st_mode | 0o111)
        os.replace(tmp, dst)
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()


def _replace_dir(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    staging = dst.parent / f".{dst.name}.new-{os.getpid()}"
    shutil.rmtree(staging, ignore_errors=True)
    shutil.copytree(src, staging)
    old = dst.parent / f".{dst.name}.old-{os.getpid()}"
    shutil.rmtree(old, ignore_errors=True)
    if dst.exists():
        os.replace(dst, old)
    os.replace(staging, dst)
    shutil.rmtree(old, ignore_errors=True)


def _snapshot(current: str) -> Path:
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = _state_dir() / "backups" / f"{stamp}-{current}"
    backup.mkdir(parents=True, exist_ok=True)
    targets = {
        "policy": _policy_path(),
        "version": _state_dir() / "version",
        "source": _state_dir() / "source",
        "defaults": _state_dir() / "defaults.toml",
    }
    for name, path in targets.items():
        if path.exists():
            shutil.copy2(path, backup / name)
    managed = backup / "managed"
    managed.mkdir()
    for name in (
        "updater.py",
        "telemetry.py",
        "manage-hooks.py",
        "menu.py",
        "localization.py",
        "ui.py",
        "doctor.py",
        "strategy_runtime.py",
    ):
        path = _state_dir() / name
        if path.exists():
            shutil.copy2(path, managed / name)
    for name in ("strategies", "telemetry_core"):
        path = _state_dir() / name
        if path.exists():
            shutil.copytree(path, managed / name)
    bin_backup = backup / "bin"
    bin_backup.mkdir()
    for name in ("codex-flow", "codex-flow.ps1", "codex-flow.cmd"):
        path = _bin_dir() / name
        if path.exists():
            shutil.copy2(path, bin_backup / name)
    overlay_backup = backup / "overlay"
    for name in ("FlowPilot", "codex-flow-overlay"):
        path = _state_dir() / "bin" / name
        if path.exists():
            overlay_backup.mkdir(exist_ok=True)
            shutil.copy2(path, overlay_backup / name)

    user_backup = backup / "user-managed"
    user_backup.mkdir()
    live_targets = {
        "hooks.json": _codex_home() / "hooks.json",
        "worker-explorer.toml": _codex_home() / "agents" / "worker-explorer.toml",
        "worker-implementer.toml": _codex_home() / "agents" / "worker-implementer.toml",
        "worker-reviewer.toml": _codex_home() / "agents" / "worker-reviewer.toml",
        "SKILL.md": _codex_home() / "skills" / "flow-pilot" / "SKILL.md",
        "migrations.json": _migration_state_path(),
    }
    presence: dict[str, bool] = {}
    for name, path in live_targets.items():
        presence[name] = path.exists()
        if path.exists():
            shutil.copy2(path, user_backup / name)
    atomic_write_json(user_backup / "presence.json", presence)
    return backup


def _restore_snapshot(backup: Path) -> None:
    policy = backup / "policy"
    if policy.exists():
        _atomic_copy(policy, _policy_path())
    for name in ("version", "source", "defaults"):
        src = backup / name
        dst_name = "defaults.toml" if name == "defaults" else name
        if src.exists():
            _atomic_copy(src, _state_dir() / dst_name)
    managed = backup / "managed"
    if managed.exists():
        for path in managed.iterdir():
            dst = _state_dir() / path.name
            if path.is_dir():
                _replace_dir(path, dst)
            else:
                _atomic_copy(path, dst, executable=path.suffix == ".py")
    bin_backup = backup / "bin"
    if bin_backup.exists():
        for path in bin_backup.iterdir():
            _atomic_copy(path, _bin_dir() / path.name, executable=path.name == "codex-flow")
    overlay = backup / "overlay"
    if overlay.exists():
        for path in overlay.iterdir():
            _atomic_copy(path, _state_dir() / "bin" / path.name, executable=True)

    user_backup = backup / "user-managed"
    if user_backup.exists():
        presence = _read_json(user_backup / "presence.json", {})
        live_targets = {
            "hooks.json": _codex_home() / "hooks.json",
            "worker-explorer.toml": _codex_home() / "agents" / "worker-explorer.toml",
            "worker-implementer.toml": _codex_home() / "agents" / "worker-implementer.toml",
            "worker-reviewer.toml": _codex_home() / "agents" / "worker-reviewer.toml",
            "SKILL.md": _codex_home() / "skills" / "flow-pilot" / "SKILL.md",
            "migrations.json": _migration_state_path(),
        }
        for name, dst in live_targets.items():
            src = user_backup / name
            if src.exists():
                _atomic_copy(src, dst)
            elif isinstance(presence, dict) and presence.get(name) is False:
                with contextlib.suppress(FileNotFoundError):
                    dst.unlink()


def _read_policy_bool(section: str, key: str, fallback: bool) -> bool:
    try:
        text = _policy_path().read_text(encoding="utf-8-sig")
    except OSError:
        return fallback
    return _as_bool(_simple_toml_value(text, section, key), fallback)


def _run_migrations(package_root: Path) -> list[str]:
    migrations_dir = package_root / "scripts" / "migrations"
    state = _read_json(_migration_state_path(), {"applied": []})
    applied = set(state.get("applied") or []) if isinstance(state, dict) else set()
    if not migrations_dir.exists():
        return sorted(applied)
    for script in sorted(migrations_dir.glob("*.py")):
        migration_id = script.stem
        if migration_id.startswith("_") or migration_id in applied:
            continue
        subprocess.run(
            [sys.executable, str(script), "--policy", str(_policy_path())],
            check=True,
            env=os.environ.copy(),
        )
        applied.add(migration_id)
    return sorted(applied)


def _sync_managed_runtime(package_root: Path) -> None:
    state = _state_dir()
    state.mkdir(parents=True, exist_ok=True)
    scripts = package_root / "scripts"
    for name in (
        "updater.py",
        "telemetry.py",
        "manage-hooks.py",
        "menu.py",
        "localization.py",
        "ui.py",
        "doctor.py",
        "strategy_runtime.py",
    ):
        src = scripts / name
        if src.exists():
            _atomic_copy(src, state / name, executable=True)
    for name in ("strategies", "telemetry_core"):
        src = scripts / name
        if src.exists():
            _replace_dir(src, state / name)
    defaults = package_root / "policy" / "defaults.toml"
    if defaults.exists():
        _atomic_copy(defaults, state / "defaults.toml")

    agents_dir = _codex_home() / "agents"
    agents_dir.mkdir(parents=True, exist_ok=True)
    for name in ("worker-explorer.toml", "worker-implementer.toml", "worker-reviewer.toml"):
        src = package_root / "templates" / "agents" / name
        if src.exists():
            _atomic_copy(src, agents_dir / name)
    skill_src = package_root / "templates" / "skills" / "flow-pilot" / "SKILL.md"
    if skill_src.exists():
        _atomic_copy(skill_src, _codex_home() / "skills" / "flow-pilot" / "SKILL.md")

    bin_dir = _bin_dir()
    bin_dir.mkdir(parents=True, exist_ok=True)
    if os.name == "nt":
        for name in ("codex-flow.ps1", "codex-flow.cmd"):
            src = package_root / "bin" / name
            if src.exists():
                _atomic_copy(src, bin_dir / name)
    else:
        src = package_root / "bin" / "codex-flow"
        if src.exists():
            _atomic_copy(src, bin_dir / "codex-flow", executable=True)

    if platform.system().lower() == "darwin":
        for name in ("FlowPilot", "codex-flow-overlay"):
            src = package_root / "apps" / "macos-overlay" / "bin" / name
            if src.exists():
                _atomic_copy(src, state / "bin" / name, executable=True)

    # Hooks keep their stable state-dir target, so replacing telemetry.py does not
    # require re-authorization. Reconcile the hook only when telemetry is enabled.
    manage_hooks = state / "manage-hooks.py"
    if manage_hooks.exists() and _read_policy_bool("telemetry", "enabled", True):
        hooks = _codex_home() / "hooks.json"
        subprocess.run(
            [sys.executable, str(manage_hooks), "install", "--hooks", str(hooks), "--script", str(state / "telemetry.py")],
            check=True,
        )


def _run_health_check() -> None:
    doctor = _state_dir() / "doctor.py"
    if doctor.exists() and os.environ.get("CODEX_FLOW_UPDATE_SKIP_DOCTOR") != "1":
        subprocess.run([sys.executable, str(doctor)], check=True)


def _history() -> list[dict[str, Any]]:
    payload = _read_json(_history_path(), [])
    return payload if isinstance(payload, list) else []


def _append_history(entry: dict[str, Any]) -> None:
    history = _history()
    history.append(entry)
    atomic_write_json(_history_path(), history[-20:])


def _ensure_current_version_package(version: str) -> Path | None:
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
            (staging / "VERSION").write_text(version + "\n", encoding="utf-8")
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


def _install_package(package_root: Path, version: str, manifest: dict[str, Any]) -> UpdateState:
    state_dir = _state_dir()
    versions = state_dir / "versions"
    versions.mkdir(parents=True, exist_ok=True)
    target_version = versions / version
    current = current_version()
    _ensure_current_version_package(current)
    backup = _snapshot(current)
    previous_source = None
    source_path = state_dir / "source"
    with contextlib.suppress(OSError):
        previous_source = source_path.read_text(encoding="utf-8-sig").strip()

    staged_version = versions / f".{version}.staging-{os.getpid()}"
    shutil.rmtree(staged_version, ignore_errors=True)
    shutil.copytree(package_root, staged_version)
    try:
        applied_migrations = _run_migrations(staged_version)
        _sync_managed_runtime(staged_version)
        _run_health_check()
        atomic_write_json(_migration_state_path(), {"applied": applied_migrations})
        if target_version.exists():
            shutil.rmtree(target_version)
        os.replace(staged_version, target_version)
        atomic_write_text(state_dir / "previous-version", current + "\n")
        atomic_write_text(state_dir / "version", version + "\n")
        atomic_write_text(state_dir / "current-version", version + "\n")
        atomic_write_text(state_dir / "source", str(target_version) + "\n")
        state = load_state()
        state.current_version = version
        state.latest_version = _strip_v(str(manifest.get("version") or version))
        state.previous_version = current
        state.update_available = is_newer(state.latest_version, version)
        state.status = "available" if state.update_available else "latest"
        state.restart_required = True
        state.installed_at = utc_now()
        state.last_error = None
        state.progress = 1.0
        save_state(state)
        _append_history(
            {
                "from": current,
                "to": version,
                "installed_at": state.installed_at,
                "backup": str(backup),
                "previous_source": previous_source,
            }
        )
        return state
    except Exception:
        _restore_snapshot(backup)
        raise
    finally:
        shutil.rmtree(staged_version, ignore_errors=True)


def perform_update(*, force_check: bool = True) -> UpdateState:
    state = check_for_updates(force=force_check)
    manifest = state.extra.get("manifest") if isinstance(state.extra, dict) else None
    if not state.update_available:
        return state
    if not isinstance(manifest, dict):
        raise RuntimeError("no installable update manifest is cached")
    artifact = _artifact_for_platform(manifest)
    if not artifact:
        raise RuntimeError(f"release does not provide an artifact for {platform_key()}")
    url = str(artifact.get("url") or "")
    expected = str(artifact.get("sha256") or "").lower()
    if not url or not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise RuntimeError("release artifact metadata is incomplete")

    version = _strip_v(str(manifest["version"]))
    state.status = "downloading"
    state.progress = 0.0
    save_state(state)
    with tempfile.TemporaryDirectory(prefix="codex-flow-update-") as tmp_value:
        tmp = Path(tmp_value)
        suffix = ".zip" if url.lower().endswith(".zip") else ".tar.gz"
        archive = tmp / f"release{suffix}"
        _download(url, archive)
        state.progress = 0.55
        save_state(state)
        actual = _sha256(archive)
        if actual.lower() != expected:
            raise RuntimeError(f"checksum mismatch for update artifact: expected {expected}, got {actual}")
        extract = tmp / "extract"
        safe_extract(archive, extract)
        root = _package_root(extract)
        package_version = _strip_v((root / "VERSION").read_text(encoding="utf-8-sig").strip())
        if package_version != version:
            raise RuntimeError(f"artifact version {package_version} does not match manifest {version}")
        state.status = "installing"
        state.progress = 0.8
        save_state(state)
        return _install_package(root, version, manifest)


def rollback() -> UpdateState:
    state_dir = _state_dir()
    current = current_version()
    previous_path = state_dir / "previous-version"
    if not previous_path.exists():
        raise RuntimeError("no previous codex-flow version is available for rollback")
    previous = _strip_v(previous_path.read_text(encoding="utf-8-sig").strip())
    package_root = state_dir / "versions" / previous
    if not package_root.exists():
        raise RuntimeError(f"rollback package is missing: {package_root}")
    backup = _snapshot(current)
    history_entry = next(
        (entry for entry in reversed(_history()) if entry.get("from") == previous and entry.get("to") == current and entry.get("backup")),
        None,
    )
    try:
        if history_entry:
            historical_backup = Path(str(history_entry["backup"]))
            if historical_backup.exists():
                _restore_snapshot(historical_backup)
        _sync_managed_runtime(package_root)
        _run_health_check()
        atomic_write_text(state_dir / "version", previous + "\n")
        atomic_write_text(state_dir / "current-version", previous + "\n")
        atomic_write_text(state_dir / "source", str(package_root) + "\n")
        atomic_write_text(state_dir / "previous-version", current + "\n")
        state = load_state()
        state.current_version = previous
        state.previous_version = current
        state.update_available = bool(state.latest_version and is_newer(state.latest_version, previous))
        state.status = "available" if state.update_available else "latest"
        state.restart_required = True
        state.last_error = None
        save_state(state)
        _append_history({"from": current, "to": previous, "rollback": True, "installed_at": utc_now(), "backup": str(backup)})
        return state
    except Exception:
        _restore_snapshot(backup)
        raise


def _legacy_git_update() -> int:
    """Compatibility bridge for pre-OTA releases and source installs.

    Once a release ships a manifest/artifact this path is not used. Keeping it
    temporarily means existing users and old smoke tests still have a recovery
    path while the release channel is being bootstrapped.
    """

    source_file = _state_dir() / "source"
    try:
        src = Path(source_file.read_text(encoding="utf-8-sig").strip())
    except OSError:
        return 2
    if not (src / ".git").exists():
        return 2
    try:
        branch = subprocess.check_output(
            ["git", "-C", str(src), "rev-parse", "--abbrev-ref", "HEAD"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        if branch and branch != "HEAD":
            remote = subprocess.run(
                ["git", "-C", str(src), "config", "--get", f"branch.{branch}.remote"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            ).stdout.strip() or "origin"
            subprocess.run(["git", "-C", str(src), "pull", "--ff-only", remote, branch], check=True)
        if os.name == "nt":
            subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(src / "install.ps1")], check=True)
        else:
            subprocess.run(["bash", str(src / "install.sh")], check=True)
        return 0
    except (OSError, subprocess.CalledProcessError):
        return 2


def _print_status(state: UpdateState, as_json: bool = False) -> None:
    if as_json:
        print(json.dumps(state.to_mapping(), ensure_ascii=False, indent=2, sort_keys=True))
        return
    if state.restart_required:
        print(f"✓ codex-flow v{state.current_version} installed; restart Codex to activate updated policy/hooks snapshots.")
    elif state.update_available and state.latest_version:
        suffix = "" if state.artifact_available else " (release package not available yet)"
        print(f"↑ codex-flow v{state.latest_version} is available; current v{state.current_version}{suffix}")
    elif state.status == "latest":
        print(f"✓ codex-flow v{state.current_version} is up to date.")
    elif state.last_error:
        print(f"! Update check unavailable: {state.last_error}")
    else:
        print(f"codex-flow v{state.current_version}: update status unknown")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="codex-flow OTA updater")
    parser.add_argument("command", nargs="?", choices=("rollback",))
    parser.add_argument("--check", action="store_true", help="check only; never install")
    parser.add_argument("--force", action="store_true", help="ignore cached check interval")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-legacy-fallback", action="store_true")
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(list(argv) if argv is not None else None)
    _update_dir().mkdir(parents=True, exist_ok=True)
    if args.command == "rollback":
        try:
            state = rollback()
            if not args.quiet:
                print(f"↩ Rolled back codex-flow to v{state.current_version}. Restart Codex to activate it.")
            return 0
        except Exception as exc:
            print(f"codex-flow rollback failed: {exc}", file=sys.stderr)
            return 1

    if args.check:
        with update_lock() as acquired:
            state = check_for_updates(force=args.force, quiet=args.quiet) if acquired else load_state()
        if not args.quiet:
            _print_status(state, as_json=args.json)
        return 0 if not state.last_error or state.latest_version else 1

    try:
        state = check_for_updates(force=True)
        if state.update_available and state.artifact_available:
            state = perform_update(force_check=False)
            if not args.quiet:
                print(f"✨ Updated codex-flow to v{state.current_version}.")
                print("⚠ Restart Codex to activate updated FlowPilot policy/hooks snapshots.")
            return 0
        if state.update_available and not state.artifact_available:
            raise RuntimeError("new release detected but no installable artifact is available")
        if state.status == "latest":
            if not args.quiet:
                _print_status(state, as_json=args.json)
            return 0
        if state.last_error:
            raise RuntimeError(state.last_error)
        if not args.quiet:
            _print_status(state, as_json=args.json)
        return 0
    except Exception as exc:
        if not args.no_legacy_fallback and _legacy_git_update() == 0:
            if not args.quiet:
                print("✓ Updated using the legacy source checkout fallback. Future release packages will use OTA automatically.")
            return 0
        print(f"codex-flow update failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
