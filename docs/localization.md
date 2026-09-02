# 多语言国际化支持 (i18n)

<div align="center">

[ 简体中文 ](localization.md) | [ English ](localization.en.md)

</div>

`codex-flow` 在 CLI 命令行、交互控制台、系统通知中心以及 macOS 原生 FlowPilot 悬浮窗中提供了完整的中英双语本地化支持。

---

## 默认语言机制

配置文件 `~/.codex/codex-flow.toml` 中的默认设置为：

```toml
[ui]
language = "auto"
```

- `auto`（自适应）：自动检测操作系统与 Shell 环境变量的语言偏好。
  - 中文语系（`zh_CN`、`zh_TW`、`zh_HK` 等）自动适配为 `zh`（简体中文）。
  - 其他语言环境默认回退为 `en`（English）。

---

## 语言配置指令

```bash
# 查看当前配置语言、系统检测语言与生效语言
codex-flow language

# 恢复随系统自适应
codex-flow language auto

# 强制设为简体中文
codex-flow language zh

# 强制设为 English
codex-flow language en
```

该设置会持久化写入 `~/.codex/codex-flow.toml`，并在执行 `codex-flow update` 或重新安装时完整保留。

### 临时环境变量覆盖
如需在当前终端会话临时覆盖，可设置：
```bash
export CODEX_FLOW_LANGUAGE=zh   # 或 'en' / 'auto'
```

---

## 已本地化的模块界面

语言配置在以下界面无缝实时生效：
1. **交互式终端菜单** (`codex-flow` 主菜单)
2. **CLI 终端输出** (`status`、`doctor`、`help` 与安装/引导提示)
3. **Telemetry 遥测卡片与统计** (`usage last`、`usage list`、`usage stats`)
4. **macOS 原生通知中心** (任务完成提醒横幅)
5. **FlowPilot macOS 原生悬浮窗** (实时巡检卡、TabBar、历史手风琴、效能看板与右键菜单)
