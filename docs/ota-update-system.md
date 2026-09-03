# OTA Update System

`codex-flow` uses GitHub Releases as the source of truth for self-updates. The CLI and FlowPilot share the same durable update state under the codex-flow state directory and consume the same release manifest.

## Update contract

- Release assets are described by `codex-flow-update.json` and verified with SHA-256 before activation.
- Update checks are cached and may run non-blocking so normal CLI/App startup is not gated by GitHub availability.
- Installation stages verified files before switching managed files into place.
- Managed-file activation is transactional, keeps rollback history/backups, and prunes retained backups.
- Update state distinguishes Codex restart requirements from FlowPilot restart requirements.
- Configuration/runtime migration state is persisted and reconciled as part of the managed update payload.
- Post-update validation uses the updater/doctor health path before an update is considered complete.
- The updater is implemented with Python standard library only and contains platform-specific handling for Windows, macOS, and Linux.

## User surfaces

The terminal update entry renders cached availability/restart state without requiring a blocking network request. FlowPilot reads the same update state, exposes update availability as UI state, and provides the Update Now/restart actions appropriate to the installed update.

## Release validation

The OTA CI validates manifest generation, release artifact/checksum handling, updater behavior, migration/rollback state, and the supported platform matrix. The macOS overlay workflow separately validates the FlowPilot integration.
