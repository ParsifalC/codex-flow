#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_STARTUP_BUILD="$(mktemp -d)"
trap 'rm -rf "$FLOW_STARTUP_BUILD"' EXIT
SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
    SWIFT_SOURCES+=("$file")
done < <(find "$ROOT/apps/macos-overlay/Sources" -name '*.swift' ! -name main.swift -print0)
swiftc -framework Cocoa -framework SwiftUI -framework Combine \
    "${SWIFT_SOURCES[@]}" "$ROOT/apps/macos-overlay/Tests/OverlayStateStartupTests.swift" \
    -o "$FLOW_STARTUP_BUILD/startup-tests"
"$FLOW_STARTUP_BUILD/startup-tests"
