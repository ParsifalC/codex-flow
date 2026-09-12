class CodexFlow < Formula
  desc "Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex"
  homepage "https://github.com/ParsifalC/codex-flow"
  version "2.1.11"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.11/codex-flow-2.1.11-darwin-arm64.tar.gz"
      sha256 "1a76cfd415b5b4115a82af472745903a6e5aaef7ad6aecf0b001a13a76e79caa"
    else
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.11/codex-flow-2.1.11-darwin-x86_64.tar.gz"
      sha256 "766885ac040cacf35ca663b18726a487ec51a1f3fdf3eedd9add2639c3c47761"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.11/codex-flow-2.1.11-linux-arm64.tar.gz"
      sha256 "9e349d48b1ac7cd75bc41d38db26c80c5ad0cb9663a18eb4f6949d1ba87e8167"
    else
      url "https://github.com/ParsifalC/codex-flow/releases/download/v2.1.11/codex-flow-2.1.11-linux-x86_64.tar.gz"
      sha256 "68651d9c83ad872a127aff9a5791d9352556b25ab7829649b86b61f7d99d422c"
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
    assert_match "codex-flow", shell_output("#{bin}/codex-flow --help", 0)
  end
end
