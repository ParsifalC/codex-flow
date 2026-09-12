#!/usr/bin/env python3
"""Update Homebrew Formula for codex-flow using release manifests."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORMULA_PATH = ROOT / "Formula" / "codex-flow.rb"

TEMPLATE = """class CodexFlow < Formula
  desc "Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex"
  homepage "https://github.com/ParsifalC/codex-flow"
  version "{version}"

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
    bash_completion.install libexec/"completions/codex-flow.bash" => "codex-flow" if (libexec/"completions/codex-flow.bash").exist?
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
    assert_match "codex-flow", shell_output("#{{bin}}/codex-flow --help", 0)
  end
end
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Update Homebrew formula for codex-flow")
    parser.add_argument("--manifest", type=Path, default=ROOT / "dist" / "codex-flow-update.json")
    parser.add_argument("--output", type=Path, default=FORMULA_PATH)
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
