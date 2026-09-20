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

# SwiftUI's newer SDKs expose property wrappers such as @State through the
# SwiftUIMacros compiler plugin.  A machine can have Xcode installed while
# xcode-select still points at CommandLineTools, whose SDK does not ship that
# plugin.  Prefer an installed developer directory that contains the plugin so
# the build does not depend on the user's global xcode-select setting.
has_swiftui_macro_plugin() {
    [[ -f "$1/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]]
}

developer_dir="${DEVELOPER_DIR:-}"
if [[ -n "$developer_dir" && "$developer_dir" == *.app ]]; then
    developer_dir="$developer_dir/Contents/Developer"
fi

if [[ -z "$developer_dir" ]]; then
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
fi

if ! has_swiftui_macro_plugin "$developer_dir"; then
    developer_dir=""
    for candidate in /Applications/Xcode*.app/Contents/Developer "$HOME"/Applications/Xcode*.app/Contents/Developer; do
        if has_swiftui_macro_plugin "$candidate"; then
            developer_dir="$candidate"
            break
        fi
    done
fi

SWIFT_COMPILER=(swiftc)
if [[ -n "$developer_dir" ]]; then
    swiftui_plugin_dir="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
    SWIFT_COMPILER=(env "DEVELOPER_DIR=$developer_dir" xcrun swiftc -plugin-path "$swiftui_plugin_dir")
    echo "Using SwiftUI macro-capable Xcode toolchain: $developer_dir"
fi

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
"${SWIFT_COMPILER[@]}" \
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
