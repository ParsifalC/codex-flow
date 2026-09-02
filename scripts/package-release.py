#!/usr/bin/env python3
"""Build deterministic-enough codex-flow OTA release archives."""

from __future__ import annotations

import argparse
import hashlib
import os
import tarfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INCLUDE_ROOTS = (
    "VERSION",
    "install.sh",
    "install.ps1",
    "bin",
    "scripts",
    "templates",
    "completions",
    "policy",
)


def version() -> str:
    return (ROOT / "VERSION").read_text(encoding="utf-8-sig").strip().lstrip("v")


def iter_files(platform_name: str):
    seen: set[Path] = set()
    for item in INCLUDE_ROOTS:
        path = ROOT / item
        if path.is_file():
            seen.add(path)
        elif path.is_dir():
            for child in path.rglob("*"):
                if child.is_file() and "__pycache__" not in child.parts and child.suffix not in {".pyc", ".pyo"}:
                    seen.add(child)
    if platform_name.startswith("darwin-"):
        overlay_bin = ROOT / "apps" / "macos-overlay" / "bin"
        if overlay_bin.exists():
            for child in overlay_bin.iterdir():
                if child.is_file() and child.name in {"FlowPilot", "codex-flow-overlay"}:
                    seen.add(child)
    return sorted(seen, key=lambda p: p.relative_to(ROOT).as_posix())


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build(platform_name: str, output_dir: Path) -> Path:
    output_dir.mkdir(parents=True, exist_ok=True)
    ver = version()
    prefix = f"codex-flow-{ver}"
    if platform_name.startswith("windows-"):
        archive = output_dir / f"codex-flow-{ver}-{platform_name}.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
            for src in iter_files(platform_name):
                rel = src.relative_to(ROOT).as_posix()
                info = zipfile.ZipInfo(f"{prefix}/{rel}")
                info.date_time = (2020, 1, 1, 0, 0, 0)
                mode = 0o755 if os.access(src, os.X_OK) or src.suffix in {".sh", ".py"} else 0o644
                info.external_attr = (mode & 0xFFFF) << 16
                info.compress_type = zipfile.ZIP_DEFLATED
                zf.writestr(info, src.read_bytes())
    else:
        archive = output_dir / f"codex-flow-{ver}-{platform_name}.tar.gz"
        with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as tf:
            for src in iter_files(platform_name):
                rel = src.relative_to(ROOT).as_posix()
                arcname = f"{prefix}/{rel}"
                info = tf.gettarinfo(str(src), arcname=arcname)
                info.uid = info.gid = 0
                info.uname = info.gname = "root"
                info.mtime = 0
                info.mode = 0o755 if os.access(src, os.X_OK) or src.suffix in {".sh", ".py"} else 0o644
                with src.open("rb") as handle:
                    tf.addfile(info, handle)
    digest = sha256(archive)
    (archive.with_suffix(archive.suffix + ".sha256")).write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(archive)
    return archive


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True)
    parser.add_argument("--output-dir", default="dist", type=Path)
    args = parser.parse_args()
    build(args.platform, args.output_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
