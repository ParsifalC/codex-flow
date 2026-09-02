#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
OUTPUT="$BIN_DIR/codex-flow-overlay"
FLOWPILOT_OUTPUT="$BIN_DIR/FlowPilot"

mkdir -p "$BIN_DIR"

echo "🔨 Building FlowPilot native macOS widget..."

SWIFT_FILES=()
while IFS= read -r -d '' file; do
    SWIFT_FILES+=("$file")
done < <(find "$SCRIPT_DIR/Sources" -name "*.swift" -print0)

swiftc \
    -O \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    "${SWIFT_FILES[@]}" \
    -o "$OUTPUT"

chmod +x "$OUTPUT"
cp -f "$OUTPUT" "$FLOWPILOT_OUTPUT"
chmod +x "$FLOWPILOT_OUTPUT"
ln -sf "codex-flow-overlay" "$BIN_DIR/flow-pilot"

echo "✨ Build succeeded: $FLOWPILOT_OUTPUT & $OUTPUT"
