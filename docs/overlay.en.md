# macOS Native Overlay Widget (FlowPilot Overlay)

<div align="center">

<img src="assets/logo.png" alt="FlowPilot Logo" width="100" height="100" />

<br />

[ 简体中文 ](overlay.md) | [ English ](overlay.en.md)

</div>

The **FlowPilot Overlay** is a 100% native macOS desktop companion built with **SwiftUI + AppKit**. It delivers ambient, real-time multi-agent orchestration telemetry, account rate-limit quota monitoring, multi-session history inspection, and aggregated performance analytics directly on your desktop.

![FlowPilot Desktop Scene](assets/promo/flowpilot_promo_desktop_scene.png)

---

## Visual Architecture & 3 View Modes

![FlowPilot 3-State Poster](assets/promo/flowpilot_promo_poster.png)

### 1. 🟢 Micro Capsule (Idle & Ambient State)
- **Ultra-Lightweight Footprint**: 68px frosted glass floating bubble with dynamic macOS `ultraThinMaterial`.
- **Live Aura & Breathing Ring**: Dynamic rainbow gradient border with real-time status pulses:
  - 🟢 **Idle / Success**: Green indicator, ready for new tasks.
  - 🔵 **Running**: Cyan breathing pulse with live elapsed timer.
  - 🟠 **Alert / Error**: Orange pulse alerting on failed runs or high rate limits.
- **Token Badge**: Live token counter badge (e.g. `198.2k`) for the latest turn.
- **Auto Half-Tuck**: Smart screen-edge docking and anti-overflow magnetic snapping.

---

### 2. ⚡️ Inspector (Live Telemetry & Quota Monitor)
- **Task Objective & Outcome Card**: Smart extraction and presentation of the current task `Objective` and delivery `Conclusion / Outcome`.
- **3 KPI Ring Gauges**: High-precision circular gauges for **Duration** (`1m 4s`), **Tokens** (`198.2k`), and **Cost Estimation**.
- **Execution Trajectory & Logs**: Collapsible step trajectory (19+ steps) and detailed log stream.
- **Account Rate Limits & Quotas**: Real-time 5m / 1h / 1d / 7d quota progression bars (`usedPercent`), per-turn quota deltas (`+1 pp`), and reset countdown timers.
- **Agent Topology Tree**: Hierarchical display of the Parent Orchestrator model and Worker subagents.
- **Token Distribution Bar**: Proportional breakdown of Prompt, Cached, Output, and Reasoning tokens.
- **Skills & MCP Badges**: Automatic discovery and badge labeling of activated skills and MCP server tools.
- **Historical View Navigation**: Browse any past run with one-click `[⚡️ Jump to Live]` to return to real-time tracking.

---

### 3. 📜 History (Multi-Dimensional Chat & Session Timeline)
- **Dimension 1 (Project Filter & Time Scope)**: Filter by individual project/repository or toggle `All` / `Today`.
- **Dimension 2 (Chat Accordion)**: Groups multi-turn runs into chronological chat sessions (`#1`, `#2`, `#3`), displaying total tokens, aggregated duration, and max worker concurrency.
- **Dimension 3 (Session Turns Stream)**: Expandable turn-level timeline with turn numbers (`#1.1`, `#1.2`), precise timestamps, execution durations, worker tags, and per-turn quota deltas (`+1%` / `-1%`).
- **Instant Keyword Search**: Live filtering across chat titles, branch names, and turn prompts.
- **One-Click Drilldown**: Clicking any session turn immediately switches to the Inspector view for that turn.

---

### 4. 📊 Analytics (30-Day Efficiency Dashboard)
- **Period Toggles**: Switch between `7-Day` and `30-Day` performance windows.
- **Core KPI Summary**: Total Tasks (Dispatched vs. Direct), Total Active Hours, and Total Attributed Tokens.
- **Cache Hit Efficiency**: Percentage gauge and total cached tokens saved.
- **Worker Offload Ratio**: Percentage of computing workload delegated to economic worker models.
- **Model Distribution Matrix**: Call counts, token proportions, and Parent / Worker role badges per model.
- **Project Distribution Ranking**: Activity breakdown and run counts across all repositories.

---

## 🔒 Privacy & Demo Mode (Desensitization)

FlowPilot includes native privacy protection (`isPrivacyMode`) to prevent internal project names, confidential prompts, or proprietary data from leaking during presentations, recordings, or screenshot captures.

When enabled:
- Task **Objective** and **Outcome** descriptions are smoothly blurred using native Gaussian filters (`blur(radius: 4.5)`).
- Session **prompts** and **titles** in header bars and history rows are frosted.
- **Project and repository names** in headers, history, and analytics cards are desensitized.

---

## 🛠️ Showcase & Retina Screenshot Pipeline

FlowPilot features a built-in SwiftUI `ImageRenderer` screenshot utility ([scripts/generate_showcase.swift](file:///Users/parsifal/Repo/SkillHub/codex-flow/scripts/generate_showcase.swift)) to generate unclipped, 2x/3x Retina screenshots and promotional artwork:

```bash
# Compile and run screenshot & poster generator
SWIFT_FILES=($(find apps/macos-overlay/Sources -name "*.swift" ! -name "main.swift"))
swiftc -framework Cocoa -framework SwiftUI -framework Combine "${SWIFT_FILES[@]}" scripts/generate_showcase.swift -o bin/generate_showcase
bin/generate_showcase
```

Generated outputs in `docs/assets/`:
- `docs/assets/screenshots/inspector_full.png` (Unclipped Full-Height Inspector)
- `docs/assets/screenshots/history_full.png` (Unclipped Full-Height History Timeline)
- `docs/assets/screenshots/analytics_full.png` (Unclipped Full-Height Analytics)
- `docs/assets/screenshots/capsule.png` (3x Retina Micro Capsule)
- `docs/assets/promo/flowpilot_promo_poster.png` (2720 × 2002 3-State Comparison Poster)
- `docs/assets/promo/flowpilot_promo_banner.png` (2680 × 1594 Hero Banner)
- `docs/assets/promo/flowpilot_promo_desktop_scene.png` (2560 × 1440 Desktop Scene)

---

## 🚀 Quick Start & Controls

### Build & Run
```bash
# Build binary
bash apps/macos-overlay/build.sh

# Launch daemon
codex-flow overlay start
```

### CLI Commands
```bash
# State control
codex-flow overlay status       # Check running state
codex-flow overlay toggle       # Toggle expand / collapse
codex-flow overlay expand       # Expand to card view
codex-flow overlay collapse     # Collapse to micro capsule

# Navigation
codex-flow overlay tab inspector
codex-flow overlay tab history
codex-flow overlay tab analytics

# Historical view
codex-flow overlay show 1       # Jump to specific task

# Stats & History shortcuts
codex-flow overlay stats 30     # Open analytics with 30d window
codex-flow overlay history      # Open history tab

# Daemon lifecycle
codex-flow overlay restart
codex-flow overlay stop
```

---

## 🖱️ Mouse & Keyboard Interactions

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
