#!/usr/bin/env python3
"""Generate codex-flow-update.json from packaged release artifacts."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = "ParsifalC/codex-flow"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dist", type=Path, default=Path("dist"))
    parser.add_argument("--tag")
    parser.add_argument("--channel", default="stable", choices=("stable", "beta", "nightly"))
    parser.add_argument("--release-notes-file", type=Path)
    parser.add_argument("--output", type=Path, default=Path("dist/codex-flow-update.json"))
    args = parser.parse_args()

    version = (ROOT / "VERSION").read_text(encoding="utf-8-sig").strip().lstrip("v")
    tag = args.tag or f"v{version}"
    notes = ""
    if args.release_notes_file and args.release_notes_file.exists():
        notes = args.release_notes_file.read_text(encoding="utf-8-sig").strip()

    artifacts: dict[str, dict[str, str]] = {}
    pattern = re.compile(rf"^codex-flow-{re.escape(version)}-(.+?)\.(tar\.gz|zip)$")
    for archive in sorted(args.dist.iterdir() if args.dist.exists() else []):
        match = pattern.match(archive.name)
        if not match:
            continue
        checksum_path = archive.with_suffix(archive.suffix + ".sha256")
        if not checksum_path.exists():
            raise SystemExit(f"missing checksum for {archive.name}")
        checksum = checksum_path.read_text(encoding="utf-8").split()[0].strip().lower()
        if not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise SystemExit(f"invalid checksum for {archive.name}")
        platform_name = match.group(1)
        artifacts[platform_name] = {
            "url": f"https://github.com/{REPO}/releases/download/{tag}/{archive.name}",
            "sha256": checksum,
            "format": "zip" if archive.suffix == ".zip" else "tar.gz",
        }

    if not artifacts:
        raise SystemExit("no release archives found")

    payload = {
        "schema": 1,
        "version": version,
        "channel": args.channel,
        "published_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "minimum_updater_version": "1.7.0",
        "restart_required": True,
        "mandatory": False,
        "release_url": f"https://github.com/{REPO}/releases/tag/{tag}",
        "release_notes": notes,
        "artifacts": artifacts,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
