#!/usr/bin/env bash
set -euo pipefail

REPO="${CODEX_FLOW_REPO:-ParsifalC/codex-flow}"
CHANNEL="${CODEX_FLOW_UPDATE_CHANNEL:-stable}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-flow-install.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

say() { printf '%s\n' "$*"; }
fail() { printf 'codex-flow installer: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"

case "$(uname -s)" in
  Darwin) os="darwin" ;;
  Linux) os="linux" ;;
  *) fail "unsupported operating system: $(uname -s)" ;;
esac

case "$(uname -m)" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64) arch="x86_64" ;;
  *) fail "unsupported CPU architecture: $(uname -m)" ;;
esac

platform="$os-$arch"

if [[ "$CHANNEL" != "stable" ]]; then
  fail "first-install bootstrap currently supports the stable channel only; install stable first, then switch update.channel to $CHANNEL"
fi

manifest_url="https://github.com/$REPO/releases/latest/download/codex-flow-update.json"
manifest="$TMP_DIR/codex-flow-update.json"
say "→ Resolving latest codex-flow release for $platform"
curl -fL --retry 3 --connect-timeout 15 "$manifest_url" -o "$manifest"

IFS=$'\t' read -r version artifact_url expected_sha archive_format < <(python3 - "$manifest" "$platform" <<'PY'
import json, sys
from pathlib import Path
manifest_path, platform = Path(sys.argv[1]), sys.argv[2]
data = json.loads(manifest_path.read_text(encoding="utf-8"))
if data.get("channel") != "stable":
    raise SystemExit("latest release manifest is not stable")
artifact = (data.get("artifacts") or {}).get(platform)
if not artifact:
    raise SystemExit(f"release does not contain artifact for {platform}")
for key in ("url", "sha256", "format"):
    if not artifact.get(key):
        raise SystemExit(f"artifact is missing {key}")
print("\t".join((
    data.get("version") or "unknown",
    artifact["url"],
    artifact["sha256"].lower(),
    artifact["format"],
)))
PY
)

[[ -n "${version:-}" && -n "${artifact_url:-}" && -n "${expected_sha:-}" && -n "${archive_format:-}" ]] || fail "invalid release manifest"

case "$archive_format" in
  tar.gz) archive="$TMP_DIR/codex-flow.tar.gz" ;;
  zip) archive="$TMP_DIR/codex-flow.zip" ;;
  *) fail "unsupported release archive format: $archive_format" ;;
esac

say "→ Downloading codex-flow v$version"
curl -fL --retry 3 --connect-timeout 15 "$artifact_url" -o "$archive"

actual_sha="$(python3 - "$archive" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b""):
        h.update(chunk)
print(h.hexdigest())
PY
)"
[[ "$actual_sha" == "$expected_sha" ]] || fail "SHA-256 mismatch for downloaded release"
say "✓ SHA-256 verified"

package_dir="$TMP_DIR/package"
mkdir -p "$package_dir"
case "$archive_format" in
  tar.gz)
    command -v tar >/dev/null 2>&1 || fail "tar is required"
    tar -xzf "$archive" -C "$package_dir"
    ;;
  zip)
    command -v unzip >/dev/null 2>&1 || fail "unzip is required"
    unzip -q "$archive" -d "$package_dir"
    ;;
esac

install_script="$(find "$package_dir" -maxdepth 2 -type f -name install.sh -print -quit)"
[[ -n "$install_script" ]] || fail "release package does not contain install.sh"
package_root="$(cd "$(dirname "$install_script")" && pwd)"

say "→ Installing codex-flow v$version"
(
  cd "$package_root"
  bash ./install.sh
)

if [[ "$os" == "darwin" ]]; then
  flowpilot="$CODEX_HOME/codex-flow/bin/FlowPilot"
  legacy_overlay="$CODEX_HOME/codex-flow/bin/codex-flow-overlay"
  if [[ -s "$flowpilot" && -x "$flowpilot" ]]; then
    overlay_bin="$flowpilot"
  elif [[ -s "$legacy_overlay" && -x "$legacy_overlay" ]]; then
    overlay_bin="$legacy_overlay"
  else
    fail "macOS release installed successfully, but no prebuilt FlowPilot binary was found"
  fi

  say "→ Starting FlowPilot"
  "$overlay_bin" stop >/dev/null 2>&1 || true
  pkill -f "FlowPilot.*start|codex-flow-overlay.*start|bin/FlowPilot" 2>/dev/null || true
  sleep 0.2
  nohup "$overlay_bin" start >/dev/null 2>&1 &
  sleep 0.4

  if pgrep -f "FlowPilot.*start|codex-flow-overlay.*start|bin/FlowPilot" >/dev/null 2>&1; then
    say "✓ FlowPilot is running in the background"
  else
    say "! codex-flow installed, but FlowPilot did not stay running. Retry with: codex-flow overlay start" >&2
  fi
fi

say ""
say "✓ codex-flow v$version installation complete"
say "  Fully restart Codex to activate the new Agent / Skill / Hook / policy snapshot."
