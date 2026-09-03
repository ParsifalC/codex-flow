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

CORES="$(sysctl -n hw.ncpu 2>/dev/null || echo 2)"
if [ "$CORES" -gt 4 ]; then
    CORES=4
fi

# The Intel Swift 6 solver can hit its default expression budget on the
# refreshed HistoryChatRow SwiftUI result builder even though the same source
# type-checks on arm64. Keep the larger budget scoped to Intel builds. Use two
# explicit invocations instead of an optional empty array so macOS Bash 3.2 +
# `set -u` remains compatible on arm64 runners.
if [[ "$(uname -m)" == "x86_64" ]]; then
    swiftc \
        -num-threads "$CORES" \
        -j "$CORES" \
        -Xfrontend -solver-expression-time-threshold=180 \
        -framework Cocoa \
        -framework SwiftUI \
        -framework Combine \
        "${SWIFT_FILES[@]}" \
        -o "$OUTPUT"
else
    swiftc \
        -num-threads "$CORES" \
        -j "$CORES" \
        -framework Cocoa \
        -framework SwiftUI \
        -framework Combine \
        "${SWIFT_FILES[@]}" \
        -o "$OUTPUT"
fi

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
