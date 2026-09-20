# macOS Native Overlay Widget (FlowPilot Overlay)

<div align="center">

<img src="assets/logo.png" alt="FlowPilot Logo" width="100" height="100" />

<br />

[ 简体中文 ](overlay.md) | [ English ](overlay.en.md)

</div>

The **FlowPilot Overlay** is a 100% native macOS desktop companion built with **SwiftUI + AppKit**. It delivers ambient, real-time multi-agent orchestration telemetry, account rate-limit quota monitoring, multi-session history inspection, and aggregated performance analytics directly on your desktop.

![FlowPilot Desktop Scene](assets/promo/flowpilot_promo_desktop_scene.png)

---

## Compact entry and four pages

Turn goals, results, and orchestration are keyed by `session_id + turn_id`, not
a chat-wide goal. New records require `publication` before appearing in details.
Legacy completed history remains readable. New fields take priority; when an old
record has no `turn_context.goal` or `result`, the UI reads the existing
`summary_info.goal/conclusion` for display and marks it as legacy history. Those
values are never written back as new publication fields.
Host receipt delivery is verified per installation; see [telemetry compatibility](telemetry.en.md#store-goals-plans-and-results-per-turn).

Task, History, Analytics, and Account tabs retain more, pin, collapse, switch,
and copy actions. Task, History, and Account hide 300-minute (five-hour) quota
windows while retaining collection and other periods. Native glass uses
`NSVisualEffectView`, with an opaque fallback for reduced transparency.
More → Language offers system, Chinese, and English; the saved setting applies immediately.
Turn goals display in full without an expand button. Execution details start expanded;
the full plan JSON remains optional. Plan counts describe staffing by task stage,
while participation counts describe agents recorded this turn. Reusing a plan does
not imply rerunning every stage. Statistics aggregate locally recorded completed
turns in the selected period, not account-wide usage across devices.
The panel is 420 pt wide, with 13–14 pt body/settings text, 16 pt goals, and
secondary text of at least 12 pt. Long content wraps or scrolls; account reset
times do not shrink to fit.

This release targets native macOS UI. Windows keeps Python/CLI compatibility;
its visual specification uses higher-opacity acrylic surfaces, or solid colors
and clear borders without system material or in high-contrast mode. The
[HTML preview](../apps/macos-overlay/flowpilot-overlay-navigation.html) does not
prove a native Windows overlay exists or was verified. Older promotional images
may still show the previous content model.

![FlowPilot 3-State Poster](assets/promo/flowpilot_promo_poster.png)

### 1. Compact entry
- **Status**: Shows “New result”, “Completed”, or “Waiting”, plus the latest completed turn’s token usage.
- **Unread indicator**: Clears when that turn is explicitly opened. Automatic expansion does not acknowledge it.
- **Docking**: The 148×58pt glass capsule reduces to an icon, unread dot, and arrow at the edge.
- **Accessibility**: Respects reduced transparency and reduced motion.

---

### 2. Inspector (Completed Turn Details)
- **Turn Goal and Result**: New records read the goal from `turn_context.goal` and the parent final from `result`; old history without those fields falls back to `summary_info.goal/conclusion` and is marked as legacy history. If both sources are absent, the UI shows “Not recorded”. New turns appear only after parent Stop publishes them.
- **Orchestration Configuration**: Execution details start collapsed. Show strategy, routing, and review settings, with planned counts separate from observed participants.
- **Run Facts**: Compact duration, token, and actual participant counts appear after the goal and result.
- **Complete Plan**: Expand the full JSON inside execution details, including plan origin and revision. Long goals and results can be expanded separately.
- **Account Information**: The Account tab retains other quota windows and reset times. Five-hour windows are filtered only from presentation.
- **Historical View Navigation**: Browse completed turns or return to the latest published snapshot. Each turn retains its own goal and result.

---

### 3. History
- **Projects and chats**: Groups by project path, then expands each chat into turns.
- **Time filter**: Switch between All and Today, or refresh manually.
- **Turn rows**: Show the goal, turn identifier, completion time, duration, and token usage.
- **Search and details**: Search projects, chats, or goals; select a turn to open the shared task details.

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
- Turn **Goal** and **Result** use the native privacy display rules.
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
- `docs/assets/promo/flowpilot_promo_strategies.png` (3480 × 1363 4-Strategy Matrix Poster)

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
codex-flow overlay tab account

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
