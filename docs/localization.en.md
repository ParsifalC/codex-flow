# Language Localization (i18n)

<div align="center">

[ 简体中文 ](localization.md) | [ English ](localization.en.md)

</div>

`codex-flow` provides full bilingual support for both Chinese and English across the CLI, interactive console, notifications, and native macOS FlowPilot desktop widget.

---

## Default Behavior

The default configuration in `~/.codex/codex-flow.toml` is:

```toml
[ui]
language = "auto"
```

- `auto`: Automatically detects the operating system / shell locale.
  - Chinese locales (`zh_CN`, `zh_TW`, `zh_HK`) resolve to `zh`.
  - Other locales resolve to `en`.

---

## Configuring Language

```bash
# View current configured and effective language
codex-flow language

# Follow system locale
codex-flow language auto

# Force Chinese (简体中文)
codex-flow language zh

# Force English
codex-flow language en
```

The setting is persisted in `~/.codex/codex-flow.toml` and preserved across `codex-flow update` and reinstalls.

### Temporary Environment Override
For a temporary per-session override, set:
```bash
export CODEX_FLOW_LANGUAGE=zh   # or 'en', 'auto'
```

---

## Localized Surfaces

The language setting is seamlessly shared across:
1. **Interactive Terminal Menu** (`codex-flow`)
2. **CLI Output** (`status`, `doctor`, `help`, install/uninstall prompts)
3. **Telemetry Summaries & Statistics** (`usage last`, `usage list`, `usage stats`)
4. **macOS Notification Alerts** (Task completion banners)
5. **FlowPilot macOS Native Widget** (Summary card, Tab bars, History timeline, Analytics dashboard, and Context menus)
