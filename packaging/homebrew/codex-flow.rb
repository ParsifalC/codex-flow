class CodexFlow < Formula
  desc "Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex"
  homepage "https://github.com/ParsifalC/codex-flow"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.13/codex-flow-2.1.13-darwin-arm64.tar.gz"
      sha256 "8ef4e634b1c33425b465ea3b14b9cb0e779c20207efbea1e8c12f1c20d24c3af"
    else
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.13/codex-flow-2.1.13-darwin-x86_64.tar.gz"
      sha256 "4b0336f3b649185b216d021d871dcde6088431b21c2f6fa8eb03bdf66b703843"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.13/codex-flow-2.1.13-linux-arm64.tar.gz"
      sha256 "e008c3af44fe6b154e28d0bc1889e28c0c87c99819203973928635fbc07cebcf"
    else
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.13/codex-flow-2.1.13-linux-x86_64.tar.gz"
      sha256 "f57ee3f1ea4a17ef67ba7c3a49143532bc2867f0641b82fa562f13d1f21cca0b"
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
    assert_match "codex-flow", shell_output("#{bin}/codex-flow --help")
  end
end
