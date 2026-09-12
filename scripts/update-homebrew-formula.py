#!/usr/bin/env python3
"""Update Homebrew Formula for codex-flow using release manifests."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORMULA_PATH = ROOT / "packaging" / "homebrew" / "codex-flow.rb"

TEMPLATE = """class CodexFlow < Formula
  desc "Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex"
  homepage "https://github.com/ParsifalC/codex-flow"

  on_macos do
    if Hardware::CPU.arm?
      url "{darwin_arm64_url}"
      sha256 "{darwin_arm64_sha}"
    else
      url "{darwin_x86_64_url}"
      sha256 "{darwin_x86_64_sha}"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "{linux_arm64_url}"
      sha256 "{linux_arm64_sha}"
    else
      url "{linux_x86_64_url}"
      sha256 "{linux_x86_64_sha}"
    end
  end

  def install
    libexec.install Dir["*"]
    bin.write_exec_script libexec/"bin/codex-flow"
    bin.write_exec_script libexec/"bin/codex-flow-mcp"
    completion = libexec/"completions/codex-flow.bash"
    bash_completion.install completion => "codex-flow" if completion.exist?
  end

  def caveats
    <<~EOS
      To initialize FlowPilot into your Codex environment, run:
        codex-flow install

      Or launch the interactive terminal console:
        codex-flow
    EOS
  end

  test do
    assert_match "codex-flow", shell_output("#{{bin}}/codex-flow --help")
  end
end
"""


def sync_to_tap(repo: str, token: str, branch: str, formula_content: str, version: str) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        clone_url = f"https://x-access-token:{token}@github.com/{repo}.git"
        print(f"Cloning {repo} ({branch})...")
        subprocess.run(
            ["git", "clone", "--depth", "1", "--branch", branch, clone_url, tmp_dir],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        target = Path(tmp_dir) / "Formula" / "codex-flow.rb"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(formula_content, encoding="utf-8")

        status = subprocess.run(
            ["git", "-C", tmp_dir, "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        )
        if not status.stdout.strip():
            print(f"Formula in {repo} is already up to date for version {version}")
            return

        subprocess.run(["git", "-C", tmp_dir, "config", "user.name", "Parsifal"], check=True)
        subprocess.run(["git", "-C", tmp_dir, "config", "user.email", "parsifal@users.noreply.github.com"], check=True)
        subprocess.run(["git", "-C", tmp_dir, "add", "Formula/codex-flow.rb"], check=True)
        subprocess.run(["git", "-C", tmp_dir, "commit", "-m", f"chore(formula): update codex-flow to v{version}"], check=True)
        subprocess.run(["git", "-C", tmp_dir, "push", "origin", branch], check=True)
        print(f"Successfully pushed updated formula to {repo} ({branch}) for version {version}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Update Homebrew formula for codex-flow")
    parser.add_argument("--manifest", type=Path, default=ROOT / "dist" / "codex-flow-update.json")
    parser.add_argument("--output", type=Path, default=FORMULA_PATH)
    parser.add_argument("--tap-repo", type=str, default="", help="GitHub tap repo (e.g. ParsifalC/homebrew-tap)")
    parser.add_argument("--tap-token", type=str, default=os.getenv("HOMEBREW_TAP_TOKEN", ""), help="GitHub token for tap repo")
    parser.add_argument("--tap-branch", type=str, default="main", help="Tap branch to push to")
    args = parser.parse_args()

    if not args.manifest.exists():
        raise SystemExit(f"Manifest not found: {args.manifest}")

    data = json.loads(args.manifest.read_text(encoding="utf-8"))
    version = data["version"]
    artifacts = data["artifacts"]

    content = TEMPLATE.format(
        version=version,
        darwin_arm64_url=artifacts["darwin-arm64"]["url"],
        darwin_arm64_sha=artifacts["darwin-arm64"]["sha256"],
        darwin_x86_64_url=artifacts["darwin-x86_64"]["url"],
        darwin_x86_64_sha=artifacts["darwin-x86_64"]["sha256"],
        linux_arm64_url=artifacts["linux-arm64"]["url"],
        linux_arm64_sha=artifacts["linux-arm64"]["sha256"],
        linux_x86_64_url=artifacts["linux-x86_64"]["url"],
        linux_x86_64_sha=artifacts["linux-x86_64"]["sha256"],
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding="utf-8")
    print(f"Updated {args.output} for version {version}")

    if args.tap_repo:
        token = args.tap_token.strip()
        if not token:
            print(f"::warning::HOMEBREW_TAP_TOKEN is not provided. Skipping push to {args.tap_repo}.")
        else:
            sync_to_tap(
                repo=args.tap_repo,
                token=token,
                branch=args.tap_branch,
                formula_content=content,
                version=version,
            )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
