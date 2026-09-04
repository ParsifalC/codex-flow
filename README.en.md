<div align="center">

<a href="https://github.com/ParsifalC/codex-flow">
  <img src="docs/assets/logo.png" alt="FlowPilot Logo" width="130" height="130" />
</a>

# FlowPilot · codex-flow

**Intelligent, Efficient, Adaptive Multi-Agent Strategy Orchestration for Codex**

[![Version](https://img.shields.io/badge/version-2.1.0-blue.svg?style=flat-square)](VERSION)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-brightgreen.svg?style=flat-square)](#-quick-start)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-orange.svg?style=flat-square)](docs/overlay.en.md)
[![Telemetry](https://img.shields.io/badge/telemetry-deterministic%200--cost-purple.svg?style=flat-square)](docs/telemetry.en.md)
[![LinuxDo](https://img.shields.io/badge/LinuxDo-Public%20Beta-5046e6.svg?style=flat-square)](https://linux.do)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)

<br />

<img src="docs/assets/promo/flowpilot_promo_banner.png" alt="codex-flow Banner" width="100%" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

<br /><br />

[**简体中文**](README.md) · [**Strategy Runtime**](docs/strategy-runtime.md) · [**Configuration**](docs/configuration.en.md) · [**Telemetry**](docs/telemetry.en.md) · [**Native Overlay**](docs/overlay.en.md) · [**Benchmarks**](docs/benchmark.en.md)

<br />

> 📢 **Community Beta**: `codex-flow` is currently in public beta on [**LINUX DO**](https://linux.do). Feedback, suggestions, and discussions are welcome!

<br />

> **“ Spend expensive Parent capability on high-value decisions; let efficient Workers reason deeper through execution, and concentrate premium capability on critical Implementer / Reviewer roles instead of upgrading every Worker indiscriminately. ”**

</div>

---

## ✨ Key Highlights

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>🧠 Multi-Strategy Runtime</h3>
      <p>Built-in <code>efficient</code>, <code>balanced</code>, <code>quality</code>, and <code>speed</code> strategies compile TaskProfile → WorkerBudget → ExecutionPlan v7 through one deterministic runtime.</p>
    </td>
    <td width="50%" valign="top">
      <h3>⚙️ Dynamic Worker Budgeting</h3>
      <p>Fan-out is no longer fixed at one or two Workers. Runtime derives Explorer / Implementer / Reviewer counts from uncertainty, proven workstream isolation, quota, strategy budget, and hard thread ceilings.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🧠 Worker-First Reasoning</h3>
      <p>Fresh installs keep Parent mostly at <code>high</code> while Worker roles start at <code>xhigh</code>. Delegated roles run at least one effort tier above Parent whenever the supported effort ladder permits it.</p>
    </td>
    <td width="50%" valign="top">
      <h3>🏆 Quality Intent</h3>
      <p><code>quality</code> supports per-task <code>normal / strong / absolute</code> intent. Ordinary Explorers remain <code>latest-efficient</code>; strong/absolute intent can promote high-value Implementer / Reviewer roles to <code>latest-capable</code>. Explorers move to Parent-class capability only when technical risk itself is critical.</p>
    </td>
  </tr>
</table>

---

## 🧩 Built-In Strategies

| Strategy | Optimization Goal | Demanding-task Worker tendency |
| :--- | :--- | :--- |
| **`efficient`** | Reduce expensive Parent use and wasted total work | Up to roughly 2 Explorers / 2 Implementers, low speculation, quota-aware collapse |
| **`balanced`** | Balance quality, quota, and latency | Up to roughly 3 Explorers / 3 Implementers with moderate safe parallelism |
| **`quality`** | Maximize correctness and verification confidence | Normal complex work prefers efficient Workers + `max` reasoning; `strong/absolute` promotes only key Implementer / Reviewer roles while Explorers remain efficient by default |
| **`speed`** | Minimize wall-clock latency | Budget allows up to 8 Implementers; actual count follows proven writable workstreams and runtime ceiling |

`quality_intent` is **per-task semantic intent**, not persistent policy and not an alias for `risk`; only the `quality` strategy consumes it:

```text
normal   → ordinary quality target; prefer latest-efficient Workers with deep reasoning
strong   → explicit quality-over-cost preference; Parent-class Implementer / Reviewer capability is allowed
absolute → explicit highest-quality preference; correctness > quota / latency inside hard safety ceilings while Explorers remain latest-efficient by default
```

The persistent default remains:

```text
strategy = efficient
routing = adaptive
```

However, v1.7 fresh-install resource policy is intentionally more Worker-centric than the earlier architecture. Existing customized reasoning settings are preserved losslessly across update/reinstall.

---

## 🚀 Quick Start

### Prerequisites

> 💡 **Note**: The Codex CLI is **only required for initial installation checks and one-time hook authorization**. Once initial setup is complete, you can use the **Codex Desktop App exclusively** for daily workflows without ever touching the CLI.

Ensure the Codex CLI is installed for initial bootstrap:
```bash
# via npm
npm install -g @openai/codex

# or via macOS Homebrew
brew install codex
```

### One-Line Installation

Fresh installs use the matching GitHub Release artifact directly; cloning the repository is not required.

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/ParsifalC/codex-flow/main/install-release.sh | bash
```

```powershell
# Windows PowerShell
irm https://raw.githubusercontent.com/ParsifalC/codex-flow/main/install-release.ps1 | iex
```

The bootstrap detects OS/CPU, resolves the Latest Stable Release, downloads the matching artifact, verifies SHA-256, installs it under `~/.codex/codex-flow/versions/<version>`, and runs health checks. Windows automatically selects the x86_64 or ARM64 ZIP. macOS uses the prebuilt FlowPilot binary from the Release and starts the floating widget automatically without running `build.sh` locally.

> ⚠️ **Final step**:
> 1. **One-time authorization**: Launch `codex` in your terminal once, type `/hooks` in the conversation prompt, and approve FlowPilot telemetry (required only once for permanent trust).
> 2. **Restart Codex Desktop**: Fully quit and relaunch your Codex Desktop App. FlowPilot is already running on macOS; you can now perform all daily tasks directly in the Codex Desktop App.

---

## 🎮 Basic Usage

### 1. Inspect or change strategy

```bash
codex-flow strategy show
codex-flow strategy profiles
codex-flow strategy set quality
codex-flow strategy set efficient
codex-flow strategy routing adaptive
```

### 2. Per-task natural-language overrides

```text
👉 Strategy       : "quality first" / "minimize Plan quota" / "finish as fast as possible"
👉 Strong quality : "quality first; use stronger models when useful" → quality_intent=strong
👉 Max quality    : "cost is secondary; use the strongest models and independent verification" → quality_intent=absolute
👉 Adaptive       : "follow default strategy" / "handle adaptively"
👉 Delegate       : "use subagents" / "assign to workers"
👉 Direct         : "do not use subagents" / "complete directly"
```

Strategy and routing are orthogonal. For example:

```text
quality + direct
```

uses quality-oriented capability/reasoning policy while keeping execution in Parent for that task.

### 3. Compile a deterministic ExecutionPlan

```bash
codex-flow strategy plan \
  --profile quality \
  --quality-intent strong \
  --complexity complex \
  --uncertainty high \
  --parallelism high
```

The Plan exposes `quality_intent`, the selected `worker_budget`, and separate role-scoped resources:

```text
explorer_capability_policy / explorer_model / explorer_reasoning
implementer_capability_policy / implementer_model / implementer_reasoning
reviewer_capability_policy / reviewer_model / reviewer_reasoning
```

It also includes concrete `exploration_workers`, `implementation_workers`, `reviewer_workers`, and `planned_worker_count`.

### 4. Interactive console

```bash
codex-flow
```

The latest console also integrates Overlay build/start management, effective policy, Benchmark, and telemetry entry points:

```text
╭────────────────────────────────────────────────────────────────────╮
│                  🚀 codex-flow Console (v2.1.0)                    │
│   FlowPilot orchestration · deterministic telemetry · validation   │
╰────────────────────────────────────────────────────────────────────╯
  [1] 🪟 macOS native floating widget (overlay widget)
  [2] 📊 Latest task card (usage last)
  [3] 📜 Task history (usage list)
  [4] 📈 Project aggregate statistics (usage stats)
  [5] 🎯 Effective policy (status)
  [6] 🩺 Diagnostics (doctor)
  [7] ⚡ Local quick Benchmark (benchmark-local quick)
  [8] 🔄 Check and pull updates (update)
  [0] 🚪 Exit
```

The Overlay submenu can start the widget directly, build and start it, build only, or—when running—rebuild/restart, toggle expansion, and push the latest data. Users no longer need to run `build.sh` manually first.

### 5. Essential commands

```bash
codex-flow usage last
codex-flow usage list --today
codex-flow usage stats -d 30
codex-flow doctor
codex-flow update
```

---

## 🪟 FlowPilot Native macOS Widget

A **100% native SwiftUI + AppKit** frosted-glass dashboard for task lifecycle and quota observability.

<div align="center">
  <img src="docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Widget Showcase" width="100%" style="border-radius: 12px; margin: 16px 0;" />
</div>

- **🟢 Micro Capsule**: edge docking with task state and latest usage.
- **⚡️ Live Inspector**: time, token, cost, quota, and Agent topology.
- **📜 Task History**: cross-project timeline and drill-down.
- **📊 Analytics**: 7d/30d cache efficiency, Worker offload, and model/project distribution.

```bash
codex-flow overlay start
codex-flow overlay toggle
```

---

## 📚 Deep-Dive Documentation

| Module | Document | Description |
| :--- | :--- | :--- |
| **🧠 Strategy Runtime** | [docs/strategy-runtime.md](docs/strategy-runtime.md) | TaskProfile, Quality Intent, WorkerBudget, Strategy Registry, ExecutionPlan v7, role-scoped resources |
| **⚙️ Configuration** | [docs/configuration.en.md](docs/configuration.en.md) | Policy schema v4, Worker-first reasoning, routing, runtime ceilings |
| **📈 Telemetry & Quota** | [docs/telemetry.en.md](docs/telemetry.en.md) | Hook lifecycle, token attribution, quota sampling |
| **🪟 Native Overlay** | [docs/overlay.en.md](docs/overlay.en.md) | Gestures, IPC, SwiftUI architecture |
| **🧪 Local Benchmarks** | [docs/benchmark.en.md](docs/benchmark.en.md) | Keyless validation and multi-strategy comparisons |
| **☁️ Actions CI** | [docs/benchmark-actions.en.md](docs/benchmark-actions.en.md) | GitHub Actions benchmark workflow |
| **🌐 Localization** | [docs/localization.en.md](docs/localization.en.md) | English / Chinese localization coverage |

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
