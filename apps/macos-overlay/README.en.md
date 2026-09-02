# macOS Native Floating Widget (FlowPilot Overlay)

<div align="center">

[ 简体中文 ](README.md) | [ English ](README.en.md)

</div>

`codex-flow-overlay` is a 100% native macOS floating widget built with **SwiftUI + AppKit**, deeply integrating the entire suite of `codex-flow usage` capabilities (live inspection, rate-limit quota monitoring, multi-session history, and aggregate efficiency analytics).

---

<div align="center">
  <img src="../../docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Overlay Showcase" width="100%" style="border-radius: 12px; margin: 12px 0;" />
</div>

---

## ✨ Core Highlights

- 🟢 **Micro Capsule (Idle State)**:
  - 68px diameter Frosted Glass bubble (macOS `ultraThinMaterial`);
  - Dynamic rainbow gradient border with real-time breathing status aura;
  - Status indicator (🟢 Idle/Complete · 🔵 Task Running · 🟠 Alert/Error);
  - Live token badge displaying latest turn tokens (e.g. `198.2k`);
  - Automatic half-tuck edge docking and magnetic screen snapping.

- ⚡️ **Glass TabBar Control Center (Expanded State)**:
  - **⚡️ Inspector**:
    - **Header**: Project tag, Git branch badge, status pill, Pin lock, and collapse button;
    - **Objective & Outcome**: Auto-extracted task goal and delivery conclusion;
    - **3 KPI Rings**: Real-time circular gauges for Duration, Tokens, and Cost;
    - **Rate Limits & Quota**: 5m / 1h / 1d / 7d quota progression bars and reset countdowns;
    - **Token Distribution Bar**: Stacked breakdown of Prompt, Cached, Output, and Reasoning tokens;
    - **Multi-Agent Topology**: Parent model reasoning effort and Worker subagent concurrency;
    - **Skills & MCP Badges**: Automatic discovery and badge labeling of activated skills and MCP tools;
    - **Historical Drilldown**: Inspect any past task with one-click `[⚡️ Jump to Live]`;
    - **Action Bar**: Copy formatted summary, open Terminal console, Pin lock toggle.
  - **📜 History**:
    - Project filter, `All` / `Today` scope, and instant keyword search;
    - **Chat Accordion**: Aggregates multi-turn runs into chronological chat sessions;
    - **Session Turns**: Turn-level timeline with duration, tokens, worker badges, and quota deltas (`+1%` / `-1%`);
    - Click any turn to inspect full details in the Inspector.
  - **📊 Analytics**:
    - Aggregate efficiency analysis with `7 Days` / `30 Days` toggles;
    - Total tasks (dispatched vs. direct), active hours, and total attributed tokens;
    - **Cache Efficiency**: Hit percentage and cached tokens saved;
    - **Worker Offload**: Percentage of workload delegated to economic models;
    - **Model Breakdown**: Calls, token proportions, and Parent/Worker roles;
    - **Projects Distribution**: Multi-repository activity rankings.

---

## 🔒 Privacy & Demo Mode

FlowPilot includes built-in privacy protection (`isPrivacyMode`):
- All sensitive project names, prompt titles, task goals, and delivery conclusions are automatically frosted with smooth Gaussian blur filters (`blur(radius: 4.5)`).
- Ideal for public presentations, videos, and documentation screenshots.

---

## 🚀 Quick Start

### 1. Build
```bash
bash apps/macos-overlay/build.sh
```
Binary output: `apps/macos-overlay/bin/FlowPilot`.

### 2. Launch Daemon
```bash
# Start background overlay widget
codex-flow overlay start

# Or run directly
./apps/macos-overlay/bin/FlowPilot start &
```

### 3. CLI Commands
```bash
# Check status
codex-flow overlay status

# Toggle expand / collapse
codex-flow overlay toggle
codex-flow overlay expand
codex-flow overlay collapse

# Switch tabs
codex-flow overlay tab inspector
codex-flow overlay tab history
codex-flow overlay tab analytics

# Inspect historical task
codex-flow overlay show 1

# Open analytics or history directly
codex-flow overlay stats 30
codex-flow overlay history

# Update telemetry data
codex-flow overlay update

# Stop overlay
codex-flow overlay stop
```

---

## 🖱 Mouse & Keyboard Interactions

| Action | Result |
| :--- | :--- |
| **Hover on Capsule (0.4s)** | Spring animation expands into full Glass Card |
| **Mouse Leave (0.8s)** | Smoothly collapses back to Capsule (when unpinned) |
| **Click Capsule / Header** | Toggle expanded/collapsed state immediately |
| **Click Pin Icon (`📌`)** | Lock widget permanently open on top of all windows |
| **Drag Anywhere** | Smooth desktop repositioning with screen-edge magnetic snap |
| **Right-Click Context Menu**| Quick access to View Switcher, Pin, Refresh, Terminal, and Quit |
| **Click "Copy Summary"** | Copies formatted run card to system clipboard |
| **Click "Console"** | Opens `codex-flow` interactive management menu in Terminal |
