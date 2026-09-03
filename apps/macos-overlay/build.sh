#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
OUTPUT="$BIN_DIR/codex-flow-overlay"
FLOWPILOT_OUTPUT="$BIN_DIR/FlowPilot"
TMP_OUTPUT="$BIN_DIR/.codex-flow-overlay.$$"
TMP_FLOWPILOT="$BIN_DIR/.FlowPilot.$$"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
state_tmp_flowpilot=""
state_tmp_overlay=""

cleanup() {
    rm -f "$TMP_OUTPUT" "$TMP_FLOWPILOT"
    [[ -z "$state_tmp_flowpilot" ]] || rm -f "$state_tmp_flowpilot"
    [[ -z "$state_tmp_overlay" ]] || rm -f "$state_tmp_overlay"
}
trap cleanup EXIT

mkdir -p "$BIN_DIR"

echo "🔨 Building FlowPilot native macOS widget (this usually takes ~40-50s on macOS)..."

SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$SCRIPT_DIR/Sources" -name "*.swift" -print0)

CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
if [ "$CORES" -gt 4 ]; then
    CORES=4
fi

# Build to a fresh inode first. Replacing a currently executing macOS binary in
# place can invalidate mapped executable pages and SIGKILL the running process.
# Atomic rename keeps the old inode alive for the current process while new
# launches immediately see the freshly built binary.
swiftc \
    -num-threads "$CORES" \
    -j "$CORES" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    "${SWIFT_FILES[@]}" \
    -o "$TMP_OUTPUT"

chmod +x "$TMP_OUTPUT"
mv -f "$TMP_OUTPUT" "$OUTPUT"
cp "$OUTPUT" "$TMP_FLOWPILOT"
chmod +x "$TMP_FLOWPILOT"
mv -f "$TMP_FLOWPILOT" "$FLOWPILOT_OUTPUT"
ln -sf "codex-flow-overlay" "$BIN_DIR/flow-pilot"

# Sync to installed state dir if it exists. Use the same atomic replacement so
# rebuilding from the console never corrupts a currently running installed copy.
STATE_BIN="$CODEX_HOME/codex-flow/bin"
if [[ -d "$STATE_BIN" ]]; then
    state_tmp_flowpilot="$STATE_BIN/.FlowPilot.$$"
    state_tmp_overlay="$STATE_BIN/.codex-flow-overlay.$$"
    cp "$FLOWPILOT_OUTPUT" "$state_tmp_flowpilot"
    cp "$OUTPUT" "$state_tmp_overlay"
    chmod +x "$state_tmp_flowpilot" "$state_tmp_overlay"
    mv -f "$state_tmp_flowpilot" "$STATE_BIN/FlowPilot"
    state_tmp_flowpilot=""
    mv -f "$state_tmp_overlay" "$STATE_BIN/codex-flow-overlay"
    state_tmp_overlay=""
fi

echo "✨ Build succeeded: $FLOWPILOT_OUTPUT"
echo ""
echo "🚀 Quick Start:"
echo "   • 启动悬浮窗:  codex-flow overlay start"
echo "   • 或独立运行:  $FLOWPILOT_OUTPUT start &"
echo ""
