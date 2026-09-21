#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_NAV_BUILD="$(mktemp -d)"
trap 'rm -rf "$FLOW_NAV_BUILD"' EXIT
SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
    SWIFT_SOURCES+=("$file")
done < <(find "$ROOT/apps/macos-overlay/Sources" -name '*.swift' ! -name main.swift -print0)
swiftc -framework Cocoa -framework SwiftUI -framework Combine \
    "${SWIFT_SOURCES[@]}" "$ROOT/apps/macos-overlay/Tests/OverlayTurnNavigationTests.swift" \
    -o "$FLOW_NAV_BUILD/navigation-tests"
"$FLOW_NAV_BUILD/navigation-tests"
