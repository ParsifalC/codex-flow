# macOS Native Floating Widget (FlowPilot Overlay)

The **FlowPilot Overlay** is a 100% native macOS widget built with **SwiftUI + AppKit**. It delivers ambient, real-time multi-agent telemetry, rate-limit quota monitoring, run history inspection, and aggregated efficiency analytics directly on your desktop.

![FlowPilot Desktop Scene](assets/promo/flowpilot_promo_desktop_scene.png)

---

## Visual Architecture & 3 View Modes

![FlowPilot 3-State Poster](assets/promo/flowpilot_promo_poster.png)

### 1. 🟢 Micro Capsule (Idle State)
- **Compact Footprint**: 68px frosted glass floating bubble with dynamic macOS `ultraThinMaterial`.
- **Live Aura**: Rainbow breathing glow with real-time status indicator (🟢 Idle/Complete · 🔵 Running · 🟠 Alert).
- **Auto Half-Tuck**: Smart screen-edge docking and anti-overflow magnetic snapping.

### 2. ⚡️ Inspector (Live Telemetry & Quota)
- **Ring Gauges**: Real-time rings for Duration, Total Tokens, and Estimated Cost.
- **Quota Awareness**: Live monitoring of 5m / 1h / 1d rate-limit windows (`+X pp` change and reset countdowns).
- **Token Breakdown**: Interactive capsule bar detailing Prompt, Output, Cached, and Reasoning tokens.
- **Agent Topology Tree**: Hierarchical view of Parent Orchestrator and Worker subagents.
- **Live Return**: One-click `[⚡️ Jump to Live]` when viewing historical tasks.

### 3. 📜 History (Task Timeline)
- **Timeline Feed**: Filterable run list displaying task index, timestamp, Git branch, summary, worker count, and token pills.
- **Instant Search**: Real-time keyword filter and project dropdown.
- **Drill-down**: Clicking any task navigates directly to its full breakdown in the Inspector.

### 4. 📊 Analytics (Efficiency Dashboard)
- **Period Toggles**: Switch between 7-Day and 30-Day performance windows.
- **Efficiency Metrics**: Cache hit efficiency and Worker offload ratio.
- **Model Breakdown**: Calls, token proportions, and Parent vs. Worker distribution per model.
- **Project Heatmap**: Multi-repository activity rankings.

---

## Quick Start & Controls

### Build & Run
```bash
# Build from source
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

# Daemon lifecycle
codex-flow overlay restart
codex-flow overlay stop
```

---

## Mouse & Keyboard Interactions

| Action | Result |
| :--- | :--- |
| **Hover on Capsule (0.4s)** | Spring animation expands into full Glass Card |
| **Mouse Leave (0.8s)** | Smoothly collapses back to Capsule (when unpinned) |
| **Click Capsule / Header** | Toggle expanded/collapsed state immediately |
| **Click Pin Icon (`📌`)** | Lock widget permanently open on top of all windows |
| **Drag Anywhere** | Smooth desktop repositioning with screen-edge magnetic snap |
| **Right-Click Context Menu**| Quick access to View Switcher, Pin, Refresh, Terminal, and Quit |
| **Click "Copy Summary"** | Copies formatted run card to system clipboard |
