# Language localization

codex-flow supports Chinese and English across the CLI and the native macOS FlowPilot app.

## Default behavior

The default configuration is:

```toml
[ui]
language = "auto"
```

`auto` follows the operating system / shell locale. Chinese locales resolve to `zh`; English locales resolve to `en`. Other locales currently fall back to English.

## Configure the language

```bash
codex-flow language          # show configured/system/effective language
codex-flow language auto     # follow the system language
codex-flow language zh       # force Chinese
codex-flow language en       # force English
```

The setting is persisted in `~/.codex/codex-flow.toml` and is preserved by `codex-flow update` and reinstall.

For a temporary per-process override, set `CODEX_FLOW_LANGUAGE=zh`, `en`, or `auto`. The environment override has higher priority than the persisted `[ui].language` value but does not rewrite the policy file.

## Localized surfaces

The language setting is used by the interactive console, `status`, `help`, `doctor`, install guidance, telemetry summaries/history/statistics, macOS completion notifications, and the native FlowPilot app (summary, history, analytics, bubble status, context menus, and native binary help). The running app re-reads the shared policy periodically, so `codex-flow language zh|en|auto` propagates without maintaining a separate app preference. Benchmark internals and machine-readable JSON/IPC protocol fields remain stable and are not translated.
