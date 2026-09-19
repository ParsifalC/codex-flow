# macOS Native Floating Widget (FlowPilot Overlay)

<div align="center">

[ 简体中文 ](README.md) | [ English ](README.en.md)

</div>

`codex-flow-overlay` is a 100% native macOS floating widget built with **SwiftUI + AppKit**, deeply integrating the entire suite of `codex-flow usage` capabilities (completed turn details, account information, chat history, and aggregate usage analytics).

---

<div align="center">
  <img src="../../docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Overlay Showcase" width="100%" style="border-radius: 12px; margin: 12px 0;" />
</div>

---

## Interface and data

- **Compact entry**: A 148×58pt glass capsule shows unread result status and the latest completed turn’s token usage. Docking reduces it to an icon, unread dot, and arrow.
- **Task**: Shows the project, chat, turn goal, and result. The parent agent writes a goal of at most 80 Unicode code points and two sentences. Results come from the same turn’s parent final. Details appear after parent Stop; missing fields show “Not recorded”.
- **Execution details**: A collapsed section exposes the saved complete plan and separates planned worker counts from actual participants.
- **History**: Project/chat/turn grouping with All/Today filters, search, and turn selection.
- **Statistics**: Retains 7/30-day usage, cache efficiency, model and project breakdowns.
- **Account**: Retains identity, other quota windows, reset facts, strategy and login-start settings. Five-hour quota is hidden only in the UI; collection remains intact.
- **Controls**: Four tabs, pin, collapse, more actions, copy, and turn switching; no repeated brand footer.

Explicitly viewing a result clears its unread indicator; automatic expansion does not. Privacy mode hides projects, chats, goals, and results, and disables copying. Native glass respects reduced transparency and reduced motion. Windows support currently covers Python/CLI only.

Older promotional images may show the previous interface. See the [overlay guide](../../docs/overlay.en.md) and [turn metadata and host validation](../../docs/telemetry.en.md#store-goals-plans-and-results-per-turn).

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
codex-flow overlay tab account

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
