#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_LANGUAGE_TEST="$(mktemp -d)"
trap 'rm -rf "$FLOW_LANGUAGE_TEST"' EXIT
SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
    SWIFT_SOURCES+=("$file")
done < <(find "$ROOT/apps/macos-overlay/Sources" -name '*.swift' ! -name main.swift -print0)
swiftc -framework Cocoa -framework SwiftUI -framework Combine \
    "${SWIFT_SOURCES[@]}" "$ROOT/apps/macos-overlay/Tests/LocalizationSettingsTests.swift" \
    -o "$FLOW_LANGUAGE_TEST/language-tests"
env -u CODEX_FLOW_LANGUAGE CODEX_HOME="$FLOW_LANGUAGE_TEST" CODEX_FLOW_BIN_DIR="$ROOT/bin" \
    "$FLOW_LANGUAGE_TEST/language-tests"
