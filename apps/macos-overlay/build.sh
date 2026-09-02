#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
OUTPUT="$BIN_DIR/codex-flow-overlay"
FLOWPILOT_OUTPUT="$BIN_DIR/FlowPilot"

mkdir -p "$BIN_DIR"

echo "🔨 Building FlowPilot native macOS widget (this usually takes ~40-50s on macOS)..."

SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$SCRIPT_DIR/Sources" -name "*.swift" -print0)

CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

swiftc \
    -num-threads "$CORES" \
    -j "$CORES" \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    "${SWIFT_FILES[@]}" \
    -o "$OUTPUT"

chmod +x "$OUTPUT"
cp -f "$OUTPUT" "$FLOWPILOT_OUTPUT"
chmod +x "$FLOWPILOT_OUTPUT"
ln -sf "codex-flow-overlay" "$BIN_DIR/flow-pilot"

# Sync to installed state dir if it exists
STATE_BIN="$HOME/.codex/codex-flow/bin"
if [[ -d "$STATE_BIN" ]]; then
    cp -f "$FLOWPILOT_OUTPUT" "$STATE_BIN/FlowPilot"
    cp -f "$OUTPUT" "$STATE_BIN/codex-flow-overlay"
    chmod +x "$STATE_BIN/FlowPilot" "$STATE_BIN/codex-flow-overlay"
fi

echo "✨ Build succeeded: $FLOWPILOT_OUTPUT"
echo ""
echo "🚀 Quick Start:"
echo "   • 启动悬浮窗:  codex-flow overlay start"
echo "   • 或独立运行:  $FLOWPILOT_OUTPUT start &"
echo ""
