#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW_PET_BUILD="$(mktemp -d)"
trap 'rm -rf "$FLOW_PET_BUILD"' EXIT

export CODEX_FLOW_BIN_DIR="$ROOT/bin"
export PET_FIXTURES_ROOT="$ROOT/tests/fixtures/pets"
export CODEX_HOME="$FLOW_PET_BUILD/codex-home"


swiftc \
  -framework Foundation \
  "$ROOT/apps/macos-overlay/Sources/Models/PetModels.swift" \
  "$ROOT/apps/macos-overlay/Sources/Services/PetActivity.swift" \
  "$ROOT/apps/macos-overlay/Tests/PetActivityTests.swift" \
  -o "$FLOW_PET_BUILD/pet-activity-tests"

"$FLOW_PET_BUILD/pet-activity-tests"

swiftc \
  -framework AppKit \
  -framework ImageIO \
  -framework Combine \
  "$ROOT/apps/macos-overlay/Sources/Models/PetModels.swift" \
  "$ROOT/apps/macos-overlay/Sources/Services/PetResourceStore.swift" \
  "$ROOT/apps/macos-overlay/Sources/Models/PetBehavior.swift" \
  "$ROOT/apps/macos-overlay/Sources/Services/PetAnimator.swift" \
  "$ROOT/apps/macos-overlay/Tests/PetAnimationTests.swift" \
  -o "$FLOW_PET_BUILD/pet-tests"

swiftc -framework Combine \
  "$ROOT/apps/macos-overlay/Sources/Models/PetModels.swift" \
  "$ROOT/apps/macos-overlay/Sources/Models/PetBehavior.swift" \
  "$ROOT/apps/macos-overlay/Sources/Services/PetAnimator.swift" \
  "$ROOT/apps/macos-overlay/Tests/PetBehaviorTests.swift" \
  -o "$FLOW_PET_BUILD/pet-behavior-tests"

swiftc -framework Combine \
  "$ROOT/apps/macos-overlay/Sources/Models/PetModels.swift" \
  "$ROOT/apps/macos-overlay/Sources/Models/PetBehavior.swift" \
  "$ROOT/apps/macos-overlay/Sources/Services/PetAnimator.swift" \
  "$ROOT/apps/macos-overlay/Tests/PetPlaybackTests.swift" \
  -o "$FLOW_PET_BUILD/pet-playback-tests"
"$FLOW_PET_BUILD/pet-playback-tests"
"$FLOW_PET_BUILD/pet-behavior-tests"

"$FLOW_PET_BUILD/pet-tests"

SWIFT_SOURCES=()
while IFS= read -r -d '' file; do
  SWIFT_SOURCES+=("$file")
done < <(find "$ROOT/apps/macos-overlay/Sources" -name '*.swift' ! -name main.swift -print0)

swiftc -framework Cocoa -framework SwiftUI -framework Combine -framework ImageIO \
  "${SWIFT_SOURCES[@]}" \
  "$ROOT/apps/macos-overlay/Tests/PetCatalogTests.swift" \
  -o "$FLOW_PET_BUILD/pet-catalog-tests"
"$FLOW_PET_BUILD/pet-catalog-tests"

swiftc \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Combine \
  -framework ImageIO \
  "${SWIFT_SOURCES[@]}" \
  "$ROOT/apps/macos-overlay/Tests/PetOverlayInteractionTests.swift" \
  -o "$FLOW_PET_BUILD/pet-overlay-tests"

"$FLOW_PET_BUILD/pet-overlay-tests"

swiftc \
  -framework Cocoa \
  -framework SwiftUI \
  -framework Combine \
  -framework ImageIO \
  "${SWIFT_SOURCES[@]}" \
  "$ROOT/apps/macos-overlay/Tests/PetActivityIPCIntegrationTests.swift" \
  -o "$FLOW_PET_BUILD/pet-activity-ipc-tests"

"$FLOW_PET_BUILD/pet-activity-ipc-tests"
