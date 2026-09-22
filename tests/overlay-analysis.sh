#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYSIS_BUILD="$(mktemp -d)"
trap 'rm -rf "$ANALYSIS_BUILD"' EXIT

ANALYSIS_SOURCES=()
while IFS= read -r -d '' file; do
    ANALYSIS_SOURCES+=("$file")
done < <(find "$ROOT/apps/macos-overlay/Sources" -name '*.swift' ! -name main.swift -print0)

swiftc -framework Cocoa -framework SwiftUI -framework Combine \
    "${ANALYSIS_SOURCES[@]}" \
    "$ROOT/apps/macos-overlay/Tests/ConversationAnalysisTests.swift" \
    -o "$ANALYSIS_BUILD/conversation-analysis-tests"

"$ANALYSIS_BUILD/conversation-analysis-tests"
