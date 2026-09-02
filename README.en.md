<div align="center">

# ⚡️ codex-flow

**Intelligent, Efficient, and Adaptive Multi-Agent Orchestration for Codex**

[![Version](https://img.shields.io/badge/version-1.5.0-blue.svg?style=flat-square)](VERSION)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-brightgreen.svg?style=flat-square)](#-quick-start)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-orange.svg?style=flat-square)](docs/overlay.md)
[![Telemetry](https://img.shields.io/badge/telemetry-deterministic%200--cost-purple.svg?style=flat-square)](docs/telemetry.md)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)

<br />

<img src="docs/assets/promo/flowpilot_promo_banner.png" alt="codex-flow Banner" width="100%" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

<br /><br />

[**简体中文**](README.md) · [**Configuration**](docs/configuration.md) · [**Telemetry**](docs/telemetry.md) · [**Native Overlay**](docs/overlay.md) · [**Benchmarks**](docs/benchmark.md)

<br />

> **“ Empower high-capability models to orchestrate and plan, dispatch cost-effective workers to execute, and scale reasoning only when the task proves it is needed. ”**

</div>

---

## ✨ Key Highlights

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>🧠 Dynamic Adaptive Routing (FlowPilot)</h3>
      <p>No hardcoded model slugs. Dynamically classifies task complexity (<code>SMALL</code> / <code>ROUTINE</code> / <code>COMPLEX</code> / <code>CRITICAL</code>), dispatches subtasks on-demand, and adapts reasoning depth.</p>
    </td>
    <td width="50%" valign="top">
      <h3>⚡️ Deterministic Zero-Cost Telemetry</h3>
      <p>Pure Python token delta arithmetic + live account rate-limit quota tracking. <b>Zero secondary LLM calls</b> for generating summaries.</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🪟 Native macOS Floating Widget</h3>
      <p>Built with 100% native SwiftUI + AppKit. Idle micro-capsule docking and expandable frosted glass dashboard for live inspection, history replay, and 30-day analytics.</p>
    </td>
    <td width="50%" valign="top">
      <h3>🎯 Frictionless In-Task Control</h3>
      <p>Out of the box. Easily use <code>direct</code>, <code>delegate</code>, or natural language prompts to control orchestration per-turn without mutating persistent configuration.</p>
    </td>
  </tr>
</table>

---

## 🚀 Quick Start

### One-Line Installation

```bash
# macOS / Linux
git clone git@github.com:ParsifalC/codex-flow.git && cd codex-flow && bash install.sh
```

```powershell
# Windows PowerShell
git clone git@github.com:ParsifalC/codex-flow.git; cd codex-flow; .\install.ps1
```

> ⚠️ **Important**: After installation, **fully restart Codex** (quit and reopen the application) to activate the FlowPilot orchestration skill!

---

## 🎮 Basic Usage

### 1. In-Conversation Natural Language Routing

In any Codex conversation, you can explicitly guide subagent delegation for the current turn:

```text
👉 Adaptive (Default) : "Follow default strategy" / "Handle adaptively"
👉 Force Delegate     : "delegate" / "Use subagents" / "Assign to worker"
👉 Direct Execution   : "direct" / "Do not use subagents, complete directly" / "Skip workers"
```

---

### 2. Interactive Terminal Console

Type `codex-flow` in your terminal to launch the interactive management menu:

```bash
codex-flow
```

```text
╭──────────────────────────────────────────────────╮
│   ⚡️  FlowPilot Management Console               │
╰──────────────────────────────────────────────────╯
  [1] 📋 Last Task Summary (usage last)
  [2] 📜 Task History (usage list)
  [3] 📊 Efficiency & Worker Offload Dashboard (usage stats)
  [4] 🩺 Health Diagnostics (doctor)
  [5] 🪟 Launch / Toggle Native Floating Widget (overlay)
  [6] 🔄 Check & Pull Updates (update)
  [0] 🚪 Exit
```

---

### 3. Essential CLI Commands

```bash
# 📊 View latest task token breakdown, duration, and quota delta
codex-flow usage last

# 📜 List recent tasks
codex-flow usage list --today

# 📈 Inspect 30-day compute offload and cache hit efficiency
codex-flow usage stats -d 30

# 🩺 Run environment health check
codex-flow doctor

# 🔄 Seamlessly update to latest version
codex-flow update
```

---

## 🪟 FlowPilot macOS Native Floating Widget

A **100% native macOS frosted glass widget** designed for ambient task lifecycle and quota observability.

<div align="center">
  <img src="docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Widget Showcase" width="100%" style="border-radius: 12px; margin: 16px 0;" />
</div>

- **🟢 Micro Capsule**: Screen-edge half-tuck when idle, breathing glow with live state and token badge.
- **⚡️ Live Inspector**: 3 high-precision KPI rings (Time / Tokens / Cost), 5m/1h/1d rate-limit trackers, and Agent topology tree.
- **📜 Task History**: Timeline feed across projects, with one-click drill-down inspection.
- **📊 Analytics Dashboard**: 7d/30d cache hit efficiency, Worker offload ratio, and multi-model distribution.

```bash
# Start widget daemon
codex-flow overlay start

# Toggle expand / collapse
codex-flow overlay toggle
```

---

## 📚 Deep-Dive Documentation

For detailed configurations, architectural specifications, and advanced benchmarks, see our secondary documentation:

| Module | Document | Description |
| :--- | :--- | :--- |
| **⚙️ Configuration** | [docs/configuration.md](docs/configuration.md) | Full `codex-flow.toml` parameters, reasoning matrix, and env overrides |
| **📈 Telemetry & Quota** | [docs/telemetry.md](docs/telemetry.md) | Hook lifecycle, transcript token delta algorithm, app-server quota sampling |
| **🪟 Native Overlay** | [docs/overlay.md](docs/overlay.md) | Gestures, keyboard shortcuts, IPC protocol, and SwiftUI architecture |
| **🧪 Local Benchmarks** | [docs/benchmark.md](docs/benchmark.md) | 6-task balanced corpus, keyless local testing, and multi-strategy comparisons |
| **☁️ Actions CI** | [docs/benchmark-actions.md](docs/benchmark-actions.md) | GitHub Actions automated cloud benchmark workflow |
| **🌐 Localization** | [docs/localization.md](docs/localization.md) | English / Chinese (i18n) setup and coverage |

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
