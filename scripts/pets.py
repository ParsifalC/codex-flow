#!/usr/bin/env python3
"""Install and select validated Petdex-compatible sprite resources.

The module intentionally owns only resource data.  It never executes files
from a pet package and it writes only below ``CODEX_HOME/codex-flow/pets``.
PNG and WebP validation here is structural; complete native image decoding is
performed by the overlay in the native implementation unit.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import re
import shutil
import socket
import ssl
import stat
import struct
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Iterator


PETDEX_SITE = "https://petdex.dev"
PETDEX_REFERER = f"{PETDEX_SITE}/"
ASSET_HOST = "assets.petdex.dev"
CANONICAL_MANIFEST = f"https://{ASSET_HOST}/manifests/petdex-v2.json"
LEGACY_CANONICAL_MANIFEST = f"https://{ASSET_HOST}/manifests/petdex-v1.json"
MANIFEST_TIMEOUT = 4.0
DOWNLOAD_TIMEOUT = 8.0
MAX_MANIFEST_BYTES = 12 * 1024 * 1024
MAX_PET_JSON_BYTES = 256 * 1024
MAX_SPRITESHEET_BYTES = 16 * 1024 * 1024
MAX_IMAGE_PIXELS = 16 * 1024 * 1024
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 128
MAX_IMAGE_DIMENSION = 8192
MANIFEST_FIELDS = (
    "slug",
    "displayName",
    "kind",
    "submittedBy",
    "spritesheet",
    "petJson",
    "zip",
    "spriteVersionNumber",
)


class PetError(RuntimeError):
    """A user-facing pet resource or selection error."""


class NativeActivationRejected(PetError):
    """The overlay answered the reload command but rejected the resource."""


class NativeActivationUnavailable(PetError):
    """The overlay is not running or could not be reached."""


@dataclass(frozen=True)
class PetPaths:
    home: Path
    state: Path
    root: Path
    installed: Path
    current: Path
    lock: Path


def codex_home(home: str | os.PathLike[str] | None = None) -> Path:
    """Resolve a testable CODEX_HOME without changing the process environment."""

    if home is not None:
        return Path(home).expanduser()
    return Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()


def pet_paths(home: str | os.PathLike[str] | None = None) -> PetPaths:
    home_path = codex_home(home)
    state = home_path / "codex-flow"
    root = state / "pets"
    return PetPaths(home_path, state, root, root / "installed", root / "current", root / ".lock")


def overlay_socket_path(home: str | os.PathLike[str] | None = None) -> Path:
    return pet_paths(home).state / "overlay.sock"


def _ensure_directory(path: Path) -> None:
    if path.exists() and path.is_symlink():
        raise PetError(f"managed path may not be a symlink: {path}")
    try:
        path.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise PetError(f"managed path is not a directory: {path}") from exc
    if not path.is_dir() or path.is_symlink():
        raise PetError(f"managed path is not a directory: {path}")


def initialize_store(home: str | os.PathLike[str] | None = None) -> PetPaths:
    paths = pet_paths(home)
    _ensure_directory(paths.root)
    if paths.current.exists() and paths.current.is_symlink():
        raise PetError(f"managed path may not be a symlink: {paths.current}")
    return paths


@contextlib.contextmanager
def store_lock(paths: PetPaths, timeout: float = 20.0) -> Iterator[None]:
    """Serialize installs and selection writes across processes."""

    _ensure_directory(paths.root)
    if paths.lock.is_symlink() or paths.lock.is_dir():
        raise PetError(f"managed lock must be a regular file: {paths.lock}")
    fd = os.open(str(paths.lock), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        if os.name == "nt":
            import msvcrt

            deadline = time.monotonic() + timeout
            while True:
                try:
                    msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise PetError("another pet operation is still running")
                    time.sleep(0.05)
        else:
            import fcntl

            deadline = time.monotonic() + timeout
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise PetError("another pet operation is still running")
                    time.sleep(0.05)
        yield
    finally:
        if os.name == "nt":
            with contextlib.suppress(OSError):
                import msvcrt

                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        else:
            with contextlib.suppress(OSError):
                import fcntl

                fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def _atomic_write(path: Path, data: bytes) -> None:
    _ensure_directory(path.parent)
    if path.is_symlink() or path.is_dir():
        raise PetError(f"managed path is not a writable file: {path}")
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            tmp.unlink()


def _atomic_write_text(path: Path, value: str) -> None:
    _atomic_write(path, value.encode("utf-8"))


def read_current(home: str | os.PathLike[str] | None = None) -> str:
    paths = pet_paths(home)
    try:
        if paths.root.is_symlink() or paths.installed.is_symlink() or paths.current.is_symlink():
            return "default"
        value = paths.current.read_text(encoding="utf-8-sig").strip()
    except (OSError, UnicodeError):
        return "default"
    if not value or value == "default":
        return "default"
    try:
        return safe_id(value)
    except PetError:
        return "default"


def safe_id(value: str) -> str:
    """Return a path-safe stable ID, rejecting traversal instead of rewriting it."""

    if not isinstance(value, str):
        raise PetError("pet id must be a string")
    value = unicodedata.normalize("NFKC", value).strip()
    if not value or "\x00" in value or "/" in value or "\\" in value:
        raise PetError("pet id contains an unsafe path component")
    value = value.lower()
    value = re.sub(r"[^a-z0-9._-]+", "-", value).strip(".-_")
    value = re.sub(r"-{2,}", "-", value)
    if not value or value in {"default", "current", "installed", "lock"}:
        raise PetError("pet id is empty or reserved")
    if len(value) > 80:
        digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:12]
        value = f"{value[:67].rstrip('-')}-{digest}"
    return value


def _safe_member(name: str) -> str:
    if not name or "\x00" in name or "\\" in name:
        raise PetError(f"unsafe archive member: {name!r}")
    normalized = name.replace("\\", "/")
    if normalized.startswith("/") or normalized.startswith("../") or "/../" in normalized or normalized == "..":
        raise PetError(f"unsafe archive member: {name!r}")
    parts = [part for part in normalized.split("/") if part not in {"", "."}]
    if any(part == ".." for part in parts):
        raise PetError(f"unsafe archive member: {name!r}")
    return "/".join(parts)


def _assert_no_symlinks(path: Path) -> None:
    if path.is_symlink():
        raise PetError(f"resource path may not contain symlinks: {path}")
    if path.is_dir():
        for child in path.iterdir():
            _assert_no_symlinks(child)


def _bounded_read(path: Path, limit: int, label: str) -> bytes:
    if path.is_symlink():
        raise PetError(f"{label} may not be a symlink")
    try:
        if path.stat().st_size > limit:
            raise PetError(f"{label} exceeds the size limit")
        value = path.read_bytes()
    except OSError as exc:
        raise PetError(f"unable to read {label}: {exc}") from exc
    if len(value) > limit:
        raise PetError(f"{label} exceeds the size limit")
    return value


def _metadata(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_PET_JSON_BYTES:
        raise PetError("pet.json exceeds the size limit")
    try:
        value = json.loads(payload.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PetError(f"pet.json is invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise PetError("pet.json must contain an object")
    raw_id = value.get("id")
    if raw_id is not None and not isinstance(raw_id, str):
        raise PetError("pet.json id must be a string")
    version = value.get("spriteVersionNumber", 1)
    if type(version) is not int or version not in (1, 2):
        raise PetError("spriteVersionNumber must be omitted, 1, or 2")
    return value


def _sprite_name(metadata: dict[str, Any], names: Iterable[str]) -> str:
    raw = metadata.get("spritesheetPath")
    if raw is not None:
        if not isinstance(raw, str) or not raw or "\x00" in raw:
            raise PetError("spritesheetPath is invalid")
        name = _safe_member(raw)
        if name != raw or name.startswith("/") or name.startswith("."):
            raise PetError("spritesheetPath must stay inside the package")
        if name in names:
            return name
        raise PetError("spritesheetPath does not exist")
    candidates = sorted(name for name in names if name.lower().endswith((".png", ".webp")))
    if len(candidates) != 1:
        raise PetError("package must contain exactly one spritesheet.png or spritesheet.webp")
    return candidates[0]


def _validate_png(payload: bytes) -> tuple[int, int]:
    if not payload.startswith(b"\x89PNG\r\n\x1a\n"):
        raise PetError("spritesheet is not a PNG")
    offset = 8
    width = height = 0
    saw_idat = False
    saw_iend = False
    first = True
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise PetError("truncated PNG chunk")
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        if length > MAX_SPRITESHEET_BYTES or offset + 12 + length > len(payload):
            raise PetError("truncated PNG payload")
        kind = payload[offset + 4 : offset + 8]
        chunk = payload[offset + 8 : offset + 8 + length]
        expected_crc = struct.unpack(">I", payload[offset + 8 + length : offset + 12 + length])[0]
        if zlib.crc32(kind + chunk) & 0xFFFFFFFF != expected_crc:
            raise PetError("PNG chunk checksum is invalid")
        if first and kind != b"IHDR":
            raise PetError("PNG is missing IHDR")
        first = False
        if kind == b"IHDR":
            if length != 13 or width:
                raise PetError("PNG IHDR is invalid")
            width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(">IIBBBBB", chunk)
            if not width or not height or width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
                raise PetError("PNG dimensions are invalid")
            valid_depths = {0: {1, 2, 4, 8, 16}, 2: {8, 16}, 3: {1, 2, 4, 8}, 4: {8, 16}, 6: {8, 16}}
            if color_type not in valid_depths or bit_depth not in valid_depths[color_type] or compression or filtering or interlace not in (0, 1):
                raise PetError("PNG image header is invalid")
        elif kind == b"IDAT":
            saw_idat = True
        elif kind == b"IEND":
            if length != 0:
                raise PetError("PNG IEND is invalid")
            saw_iend = True
            offset += 12
            break
        offset += 12 + length
    if not width or not height or not saw_idat or not saw_iend or offset != len(payload):
        raise PetError("truncated or incomplete PNG")
    return width, height


def _read_u24_le(value: bytes) -> int:
    return int.from_bytes(value, "little")


def _validate_webp(payload: bytes) -> tuple[int, int]:
    if len(payload) < 20 or payload[:4] != b"RIFF" or payload[8:12] != b"WEBP":
        raise PetError("spritesheet is not a WebP")
    riff_size = struct.unpack_from("<I", payload, 4)[0]
    if riff_size != len(payload) - 8:
        raise PetError("truncated WebP RIFF payload")
    offset = 12
    dimensions: tuple[int, int] | None = None
    header_dimensions: tuple[int, int] | None = None
    saw_frame = False
    while offset < len(payload):
        if len(payload) - offset < 8:
            raise PetError("truncated WebP chunk")
        kind = payload[offset : offset + 4]
        length = struct.unpack_from("<I", payload, offset + 4)[0]
        end = offset + 8 + length
        padded_end = end + (length & 1)
        if end > len(payload) or padded_end > len(payload):
            raise PetError("truncated WebP chunk payload")
        chunk = payload[offset + 8 : end]
        if kind == b"VP8X":
            if len(chunk) != 10:
                raise PetError("WebP VP8X header is invalid")
            header_dimensions = (_read_u24_le(chunk[4:7]) + 1, _read_u24_le(chunk[7:10]) + 1)
        elif kind == b"VP8 ":
            if len(chunk) < 10 or chunk[3:6] != b"\x9d\x01\x2a":
                raise PetError("WebP VP8 frame is invalid")
            dimensions = (struct.unpack_from("<H", chunk, 6)[0] & 0x3FFF, struct.unpack_from("<H", chunk, 8)[0] & 0x3FFF)
            saw_frame = True
        elif kind == b"VP8L":
            if len(chunk) < 5 or chunk[0] != 0x2F:
                raise PetError("WebP VP8L frame is invalid")
            bits = int.from_bytes(chunk[1:5], "little")
            dimensions = ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
            saw_frame = True
        offset = padded_end
    if offset != len(payload) or not saw_frame or dimensions is None:
        raise PetError("WebP has no complete image frame")
    if header_dimensions is not None and header_dimensions != dimensions:
        raise PetError("WebP frame dimensions do not match VP8X")
    width, height = dimensions
    if not width or not height or width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
        raise PetError("WebP dimensions are invalid")
    return width, height


def _detected_extension(payload: bytes) -> str:
    if payload.startswith(b"\x89PNG"):
        return "png"
    if payload.startswith(b"RIFF"):
        return "webp"
    raise PetError("spritesheet must be PNG or WebP")


def _require_extension(payload: bytes, extension: str) -> None:
    actual = _detected_extension(payload)
    if actual != extension.lower().lstrip("."):
        raise PetError(f"spritesheet format does not match .{extension} file")


def sprite_version(metadata: dict[str, Any]) -> int:
    value = metadata.get("spriteVersionNumber", 1)
    if type(value) is not int or value not in (1, 2):
        raise PetError("spriteVersionNumber must be omitted, 1, or 2")
    return int(value)


def sprite_geometry(source: Path | bytes, metadata: dict[str, Any]) -> tuple[int, int, int, int]:
    """Validate static image structure and return columns, rows, cell size."""

    payload = source if isinstance(source, bytes) else _bounded_read(source, MAX_SPRITESHEET_BYTES, "spritesheet")
    if payload.startswith(b"\x89PNG"):
        width, height = _validate_png(payload)
    elif payload.startswith(b"RIFF"):
        width, height = _validate_webp(payload)
    else:
        raise PetError("spritesheet must be PNG or WebP")
    if width * height > MAX_IMAGE_PIXELS:
        raise PetError("spritesheet exceeds the native pixel limit")
    rows = 11 if sprite_version(metadata) == 2 else 9
    columns = 8
    if width % columns or height % rows:
        raise PetError(f"spritesheet dimensions must be an {columns}x{rows} atlas")
    cell_width = width // columns
    cell_height = height // rows
    if cell_width * 208 != cell_height * 192:
        raise PetError("spritesheet cell geometry must preserve the 192:208 ratio")
    return columns, rows, cell_width, cell_height


def _normalized_metadata(metadata: dict[str, Any], installed_id: str, sprite_name: str) -> dict[str, Any]:
    result = dict(metadata)
    result["id"] = installed_id
    result.setdefault("displayName", installed_id)
    if not isinstance(result["displayName"], str) or not result["displayName"].strip():
        raise PetError("pet.json displayName must be a non-empty string")
    result["spritesheetPath"] = sprite_name
    return result


def _directory_package(source: Path) -> tuple[dict[str, Any], bytes, str]:
    source = source.expanduser()
    if not source.exists() or not source.is_dir():
        raise PetError(f"pet directory does not exist: {source}")
    _assert_no_symlinks(source)
    metadata_path = source / "pet.json"
    metadata = _metadata(_bounded_read(metadata_path, MAX_PET_JSON_BYTES, "pet.json"))
    names = [path.name for path in source.iterdir() if path.is_file()]
    sprite_name = _sprite_name(metadata, names)
    sprite_path = source / sprite_name
    if sprite_path.parent != source:
        raise PetError("spritesheet must be at the package root")
    extension = Path(sprite_name).suffix.lower().lstrip(".")
    if extension not in {"png", "webp"}:
        raise PetError("spritesheet must use PNG or WebP")
    sprite = _bounded_read(sprite_path, MAX_SPRITESHEET_BYTES, "spritesheet")
    _require_extension(sprite, extension)
    return metadata, sprite, extension


def _read_archive_member(archive: zipfile.ZipFile, member: zipfile.ZipInfo, limit: int) -> bytes:
    if member.file_size > limit:
        raise PetError("pet archive resource exceeds the size limit")
    try:
        with archive.open(member) as stream:
            data = stream.read(limit + 1)
    except (OSError, zipfile.BadZipFile, RuntimeError, EOFError, zlib.error) as exc:
        raise PetError(f"unable to read pet archive: {exc}") from exc
    if len(data) > limit:
        raise PetError("pet archive resource exceeds the size limit")
    return data


def _zip_package(source: Path) -> tuple[dict[str, Any], bytes, str]:
    if source.is_symlink() or not source.is_file():
        raise PetError(f"pet archive does not exist: {source}")
    if source.stat().st_size > MAX_ARCHIVE_BYTES:
        raise PetError("pet archive exceeds the size limit")
    try:
        archive = zipfile.ZipFile(source)
    except (OSError, zipfile.BadZipFile) as exc:
        raise PetError(f"unable to read pet archive: {exc}") from exc
    with archive:
        entries: dict[str, zipfile.ZipInfo] = {}
        total = 0
        members = archive.infolist()
        if len(members) > MAX_ARCHIVE_MEMBERS:
            raise PetError("pet archive contains too many files")
        for info in members:
            name = _safe_member(info.filename)
            mode = (info.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(mode)
            if info.is_dir() and file_type in (0, stat.S_IFDIR):
                continue
            if stat.S_ISLNK(mode) or (file_type and file_type != stat.S_IFREG):
                raise PetError(f"unsafe archive member: {info.filename!r}")
            if name in entries:
                raise PetError(f"duplicate archive member: {name}")
            total += max(0, info.file_size)
            if info.file_size > MAX_EXPANDED_BYTES or total > MAX_EXPANDED_BYTES:
                raise PetError("expanded pet archive exceeds the size limit")
            entries[name] = info
        metadata_name = "pet.json" if "pet.json" in entries else next((n for n in entries if n.endswith("/pet.json")), "")
        if not metadata_name:
            raise PetError("pet archive is missing pet.json")
        metadata = _metadata(_read_archive_member(archive, entries[metadata_name], MAX_PET_JSON_BYTES))
        prefix = metadata_name[: -len("pet.json")] if metadata_name.endswith("/pet.json") else ""
        package_names: Iterable[str] = entries.keys()
        if prefix:
            metadata = dict(metadata)
            sprite_path = metadata.get("spritesheetPath")
            if isinstance(sprite_path, str) and f"{prefix}{sprite_path}" in entries:
                metadata["spritesheetPath"] = f"{prefix}{sprite_path}"
            package_names = [name for name in entries if name.startswith(prefix)]
        sprite_name = _sprite_name(metadata, package_names)
        if sprite_name not in entries:
            if prefix and prefix + sprite_name in entries:
                sprite_name = prefix + sprite_name
            else:
                raise PetError("spritesheet is missing from pet archive")
        sprite = _read_archive_member(archive, entries[sprite_name], MAX_SPRITESHEET_BYTES)
        if len(sprite) > MAX_SPRITESHEET_BYTES:
            raise PetError("spritesheet exceeds the size limit")
        extension = Path(sprite_name).suffix.lower().lstrip(".")
        if extension not in {"png", "webp"}:
            raise PetError("spritesheet must use PNG or WebP")
        _require_extension(sprite, extension)
        return metadata, sprite, extension


def _package_from_path(source: Path) -> tuple[dict[str, Any], bytes, str]:
    if source.is_dir():
        return _directory_package(source)
    if source.suffix.lower() == ".zip":
        return _zip_package(source)
    raise PetError("pet install input must be a directory or .zip archive")


def _digest(metadata: dict[str, Any], sprite: bytes) -> str:
    encoded = json.dumps(metadata, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded + b"\0" + sprite).hexdigest()


def _existing_matches(target: Path, metadata: dict[str, Any], sprite: bytes, extension: str) -> bool:
    try:
        existing_meta = _metadata(_bounded_read(target / "pet.json", MAX_PET_JSON_BYTES, "installed pet.json"))
        existing_name = _sprite_name(existing_meta, [p.name for p in target.iterdir() if p.is_file()])
        existing_sprite = _bounded_read(target / existing_name, MAX_SPRITESHEET_BYTES, "installed spritesheet")
    except (OSError, PetError):
        return False
    return _digest(existing_meta, existing_sprite) == _digest(metadata, sprite) and Path(existing_name).suffix.lower().lstrip(".") == extension


def _write_staged(stage: Path, metadata: dict[str, Any], sprite: bytes, extension: str) -> None:
    stage.mkdir(parents=False, exist_ok=False)
    (stage / "pet.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    (stage / f"spritesheet.{extension}").write_bytes(sprite)
    sprite_geometry(stage / f"spritesheet.{extension}", metadata)


def _parse_overlay_response(payload: bytes) -> str:
    if not payload:
        return "rejected"
    try:
        response = json.loads(payload.decode("utf-8-sig").strip())
    except (UnicodeDecodeError, json.JSONDecodeError):
        return "rejected"
    if isinstance(response, dict) and response.get("ok") is True:
        return "activated"
    return "rejected"


def notify_overlay(home: str | os.PathLike[str] | None = None) -> str:
    """Ask a running native overlay to reload and classify its response."""

    path = overlay_socket_path(home)
    if not path.exists() or path.is_symlink():
        return "unavailable"
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.75)
            client.connect(str(path))
            client.sendall(b"pet reload\n")
            response = client.recv(4096)
        return _parse_overlay_response(response)
    except (OSError, TimeoutError):
        return "unavailable"


def _activate(installed_id: str, home: str | os.PathLike[str] | None = None) -> dict[str, str]:
    paths = initialize_store(home)
    with store_lock(paths):
        _ensure_directory(paths.installed)
        target = paths.installed / installed_id
        if not target.is_dir() or target.is_symlink():
            raise PetError(f"installed pet does not exist: {installed_id}")
        _atomic_write_text(paths.current, installed_id)
    activation = notify_overlay(home)
    return {"id": installed_id, "activation": activation}


def _install_bytes(
    metadata: dict[str, Any],
    sprite: bytes,
    extension: str,
    *,
    installed_id: str,
    home: str | os.PathLike[str] | None = None,
    provenance: dict[str, Any] | None = None,
) -> dict[str, str]:
    paths = initialize_store(home)
    extension = extension.lower().lstrip(".")
    if extension not in {"png", "webp"}:
        raise PetError("spritesheet must use PNG or WebP")
    metadata = _normalized_metadata(metadata, installed_id, f"spritesheet.{extension}")
    _require_extension(sprite, extension)
    sprite_geometry(sprite, metadata)
    with store_lock(paths):
        _ensure_directory(paths.installed)
        target = paths.installed / installed_id
        if target.exists() or target.is_symlink():
            if target.is_symlink() or not target.is_dir():
                raise PetError(f"installed pet path is unsafe: {installed_id}")
            if not _existing_matches(target, metadata, sprite, extension):
                raise PetError(f"pet id already installed with different bytes: {installed_id}")
            reused = True
        else:
            reused = False
            stage = Path(tempfile.mkdtemp(prefix=f".{installed_id}.", dir=str(paths.installed)))
            try:
                shutil.rmtree(stage)
                _write_staged(stage, metadata, sprite, extension)
                origin = dict(provenance or {"provider": "local"})
                origin["sha256"] = _digest(metadata, sprite)
                (stage / "provenance.json").write_text(json.dumps(origin, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
                os.replace(stage, target)
            finally:
                if stage.exists():
                    shutil.rmtree(stage, ignore_errors=True)
        _atomic_write_text(paths.current, installed_id)
    activation = notify_overlay(home)
    return {"id": installed_id, "activation": activation, "reused": "true" if reused else "false"}


def install_local(source: str | os.PathLike[str], *, home: str | os.PathLike[str] | None = None) -> dict[str, str]:
    path = Path(source).expanduser()
    metadata, sprite, extension = _package_from_path(path)
    source_id = metadata.get("id") or path.stem
    local_id = f"local-{safe_id(str(source_id))}"
    return _install_bytes(metadata, sprite, extension, installed_id=local_id, home=home)


def _trusted_asset_url(raw: str, base: str | None = None) -> str:
    try:
        resolved = urllib.parse.urljoin(f"{base.rstrip('/')}/" if base else "", raw)
        parsed = urllib.parse.urlparse(resolved)
    except (AttributeError, ValueError) as exc:
        raise PetError("manifest contains an invalid asset URL") from exc
    if parsed.scheme != "https" or parsed.hostname != ASSET_HOST or parsed.username or parsed.password:
        raise PetError("manifest contains an untrusted asset host")
    return urllib.parse.urlunparse(("https", ASSET_HOST, parsed.path, "", parsed.query, parsed.fragment))


def parse_manifest(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("pets"), list):
        raise PetError("invalid Petdex manifest")
    entries = payload["pets"]
    if payload.get("total") is not None and payload.get("total") != len(entries):
        raise PetError("manifest total does not match its entries")
    result: list[dict[str, Any]] = []
    if payload.get("v") == 2:
        if payload.get("fields") != list(MANIFEST_FIELDS) or not isinstance(payload.get("assetBase"), str):
            raise PetError("invalid compact manifest fields")
        base = payload["assetBase"]
        _trusted_asset_url(base)
        for index, row in enumerate(entries):
            if not isinstance(row, list) or len(row) != len(MANIFEST_FIELDS):
                raise PetError(f"invalid compact manifest pet at index {index}")
            slug, display, kind, author, sprite_url, json_url, zip_url, version = row
            if not isinstance(slug, str) or not isinstance(display, str) or not isinstance(kind, str) or (author is not None and not isinstance(author, str)) or not isinstance(sprite_url, str) or not isinstance(json_url, str) or (zip_url is not None and not isinstance(zip_url, str)) or type(version) is not int or version not in (1, 2):
                raise PetError(f"invalid compact manifest pet at index {index}")
            result.append({
                "slug": slug,
                "displayName": display,
                "kind": kind,
                "submittedBy": author,
                "spritesheetUrl": _trusted_asset_url(sprite_url, base),
                "petJsonUrl": _trusted_asset_url(json_url, base),
                "zipUrl": _trusted_asset_url(zip_url, base) if zip_url else None,
                "spriteVersionNumber": version,
            })
        return result
    for index, row in enumerate(entries):
        if not isinstance(row, dict):
            raise PetError(f"invalid legacy manifest pet at index {index}")
        slug = row.get("slug")
        display = row.get("displayName")
        kind = row.get("kind", "creature")
        sprite_url = row.get("spritesheetUrl", row.get("spritesheet"))
        json_url = row.get("petJsonUrl", row.get("petJson"))
        zip_url = row.get("zipUrl", row.get("zip"))
        version = row.get("spriteVersionNumber", 1)
        if not isinstance(slug, str) or not isinstance(display, str) or not isinstance(kind, str) or not isinstance(sprite_url, str) or not isinstance(json_url, str) or (zip_url is not None and not isinstance(zip_url, str)) or type(version) is not int or version not in (1, 2):
            raise PetError(f"invalid legacy manifest pet at index {index}")
        result.append({
            "slug": slug,
            "displayName": display,
            "kind": kind,
            "submittedBy": row.get("submittedBy"),
            "spritesheetUrl": _trusted_asset_url(sprite_url),
            "petJsonUrl": _trusted_asset_url(json_url),
            "zipUrl": _trusted_asset_url(zip_url) if zip_url else None,
            "spriteVersionNumber": version,
        })
    return result


def _ssl_context() -> ssl.SSLContext:
    return ssl.create_default_context()


def download_bytes(url: str, *, referer: str = PETDEX_REFERER, limit: int = MAX_SPRITESHEET_BYTES, timeout: float = DOWNLOAD_TIMEOUT, trusted_asset: bool = True) -> bytes:
    parsed = urllib.parse.urlparse(url)
    if trusted_asset and (parsed.scheme != "https" or parsed.hostname != ASSET_HOST or parsed.username or parsed.password):
        raise PetError("refusing download from an untrusted asset host")
    request = urllib.request.Request(url, headers={"Accept": "*/*", "Referer": referer, "User-Agent": "codex-flow-pets/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=_ssl_context()) as response:
            final = urllib.parse.urlparse(response.geturl() or url)
            if trusted_asset and (final.scheme != "https" or final.hostname != ASSET_HOST or final.username or final.password):
                raise PetError("asset redirect left the trusted host")
            status = getattr(response, "status", 200)
            if status and status >= 400:
                raise PetError(f"download failed with HTTP {status}")
            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = response.read(min(1024 * 1024, limit + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > limit:
                    raise PetError("download exceeds the size limit")
                chunks.append(chunk)
            return b"".join(chunks)
    except PetError:
        raise
    except (OSError, urllib.error.URLError, TimeoutError) as exc:
        raise PetError(f"download failed: {exc}") from exc


def fetch_json(url: str, *, timeout: float = MANIFEST_TIMEOUT) -> Any:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in {"petdex.dev", "www.petdex.dev", ASSET_HOST} or parsed.username or parsed.password:
        raise PetError("manifest URL is not a trusted HTTPS host")
    request = urllib.request.Request(url, headers={"Accept": "application/json", "Referer": PETDEX_REFERER, "User-Agent": "codex-flow-pets/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=_ssl_context()) as response:
            final = urllib.parse.urlparse(response.geturl() or url)
            if final.scheme != "https" or final.hostname not in {"petdex.dev", "www.petdex.dev", ASSET_HOST} or final.username or final.password:
                raise PetError("manifest redirect left the trusted host")
            payload = response.read(MAX_MANIFEST_BYTES + 1)
            if len(payload) > MAX_MANIFEST_BYTES:
                raise PetError("manifest exceeds the size limit")
            return json.loads(payload.decode("utf-8-sig"))
    except PetError:
        raise
    except (OSError, urllib.error.URLError, TimeoutError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PetError(f"manifest request failed: {exc}") from exc


def fetch_manifest() -> list[dict[str, Any]]:
    override = os.environ.get("CODEX_FLOW_PETDEX_MANIFEST_URL")
    candidates = [override] if override else [f"{PETDEX_SITE}/api/manifest/v2", f"{PETDEX_SITE}/api/manifest", CANONICAL_MANIFEST, LEGACY_CANONICAL_MANIFEST]
    errors: list[str] = []
    for candidate in candidates:
        if not candidate:
            continue
        try:
            return parse_manifest(fetch_json(candidate))
        except PetError as exc:
            errors.append(f"{candidate}: {exc}")
    raise PetError("manifest unavailable: " + "; ".join(errors[-3:]))


def _resolve_online(source: str) -> dict[str, Any]:
    raw = source.strip()
    if raw.startswith("petdex:"):
        slug = raw.split(":", 1)[1].strip()
    elif re.match(r"^https://(?:www\.)?petdex\.dev(?:/|$)", raw, re.IGNORECASE):
        parsed = urllib.parse.urlparse(raw)
        parts = [part for part in parsed.path.split("/") if part]
        slug = parts[-1] if parts else ""
    else:
        slug = raw
    if not slug or "/" in slug or "\\" in slug:
        raise PetError("Petdex slug is invalid")
    entries = fetch_manifest()
    for entry in entries:
        if entry.get("slug") == slug:
            return entry
    safe_slug = safe_id(slug)
    matches = []
    for entry in entries:
        try:
            if safe_id(str(entry.get("slug", ""))) == safe_slug:
                matches.append(entry)
        except PetError:
            continue
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        raise PetError("Petdex pet name is ambiguous; use an exact catalog slug")
    raise PetError(f"Petdex pet was not found in the trusted manifest: {slug}")


def install_online(source: str, *, home: str | os.PathLike[str] | None = None) -> dict[str, str]:
    entry = _resolve_online(source)
    installed_id = safe_id(str(entry["slug"]))
    metadata_payload = download_bytes(str(entry["petJsonUrl"]), limit=MAX_PET_JSON_BYTES)
    sprite_url = str(entry["spritesheetUrl"])
    sprite = download_bytes(sprite_url, limit=MAX_SPRITESHEET_BYTES)
    extension = _detected_extension(sprite)
    metadata = _metadata(metadata_payload)
    # The package metadata and actual geometry are authoritative.  The catalog
    # version is only a hint because known catalog rows have gone stale.
    provenance = {"provider": "petdex", **{key: entry.get(key) for key in (
        "slug", "submittedBy", "petJsonUrl", "spritesheetUrl",
    )}}
    return _install_bytes(metadata, sprite, extension, installed_id=installed_id, home=home, provenance=provenance)


def install(source: str | os.PathLike[str], *, home: str | os.PathLike[str] | None = None) -> dict[str, str]:
    path = Path(source).expanduser()
    if path.exists():
        return install_local(path, home=home)
    return install_online(str(source), home=home)


def list_installed(home: str | os.PathLike[str] | None = None) -> list[dict[str, Any]]:
    paths = pet_paths(home)
    if paths.root.is_symlink():
        raise PetError("pet directory may not be a symlink")
    if not paths.installed.exists():
        return []
    if paths.installed.is_symlink():
        raise PetError("installed pet directory may not be a symlink")
    items: list[dict[str, Any]] = []
    for target in sorted(paths.installed.iterdir(), key=lambda p: p.name):
        if target.is_symlink() or not target.is_dir():
            raise PetError(f"unsafe installed pet entry: {target.name}")
        metadata = _metadata(_bounded_read(target / "pet.json", MAX_PET_JSON_BYTES, "installed pet.json"))
        item = dict(metadata)
        item["id"] = target.name
        item["current"] = target.name == read_current(home)
        items.append(item)
    return items


def use_pet(identifier: str, *, home: str | os.PathLike[str] | None = None) -> dict[str, str]:
    value = identifier.strip()
    if value == "default":
        paths = initialize_store(home)
        with store_lock(paths):
            _atomic_write_text(paths.current, "default")
        return {"id": "default", "activation": notify_overlay(home)}
    value = safe_id(value)
    return _activate(value, home)


def _print_result(result: dict[str, str], action: str) -> None:
    activation = result.get("activation", "unavailable")
    print(f"{action} {result['id']}")
    if activation == "rejected":
        print("native overlay rejected activation; selection was saved", file=sys.stderr)
    elif activation == "unavailable":
        print("overlay unavailable; selection was saved for the next start", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="codex-flow pets", description="Install and select Petdex-compatible pets")
    parser.add_argument("--home", help=argparse.SUPPRESS)
    parser.add_argument("command", nargs="?")
    parser.add_argument("argument", nargs="?")
    args = list(argv if argv is not None else sys.argv[1:])
    if args and args[0] == "pets":
        args = args[1:]
    home: str | None = None
    if args[:1] == ["--home"]:
        if len(args) < 2:
            parser.error("--home requires a path")
        home, args = args[1], args[2:]
    if not args or args[0] in {"-h", "--help", "help"}:
        parser.print_help()
        return 0
    command = args[0]
    try:
        if command == "install" and len(args) == 2:
            _print_result(install(args[1], home=home), "installed")
            return 0
        if command == "list" and len(args) == 1:
            current = read_current(home)
            for item in list_installed(home):
                marker = " *" if item["id"] == current else ""
                print(f"{item['id']}\t{item.get('displayName', item['id'])}{marker}")
            if not list_installed(home):
                print("default\tDefault")
            return 0
        if command == "use" and len(args) == 2:
            _print_result(use_pet(args[1], home=home), "using")
            return 0
        parser.error("expected: install <slug|petdex:slug|Petdex URL|local-dir|zip>, list, or use <id|default>")
    except PetError as exc:
        print(f"codex-flow pets: {exc}", file=sys.stderr)
        return 1
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
