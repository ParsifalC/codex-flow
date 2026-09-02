<div align="center">

# ✨ codex-flow

**智能、高效、自适应的 Codex 多 Agent 协同编排引擎**

[![Version](https://img.shields.io/badge/version-1.6.0-blue.svg?style=flat-square)](VERSION)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-brightgreen.svg?style=flat-square)](#-快速安装)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-orange.svg?style=flat-square)](docs/overlay.md)
[![Telemetry](https://img.shields.io/badge/telemetry-deterministic%200--cost-purple.svg?style=flat-square)](docs/telemetry.md)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)

<br />

<img src="docs/assets/promo/flowpilot_promo_banner.png" alt="codex-flow Banner" width="100%" style="border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.15);" />

<br /><br />

[**English Documentation**](README.en.md) · [**深入配置**](docs/configuration.md) · [**遥测机制**](docs/telemetry.md) · [**原生悬浮窗**](docs/overlay.md) · [**基准评测**](docs/benchmark.md)

<br />

> **“ 让高能力模型负责规划决策，让更经济的 Worker 负责落地执行；只有任务确实需要时，才提高推理强度。”**

</div>

---

## ✨ 核心亮点

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>🧠 动态自适应路由 (FlowPilot)</h3>
      <p>不与固定模型强绑定。自动识别任务复杂度（<code>SMALL</code> / <code>ROUTINE</code> / <code>COMPLEX</code> / <code>CRITICAL</code>），按需分发子任务并自适应调节推理深度。</p>
    </td>
    <td width="50%" valign="top">
      <h3>⚡️ 确定性零开销遥测</h3>
      <p>纯 Python 本地 Token 差值归因 + 实时账户 Quota 配额感知。<b>统计过程 0 次额外 LLM 调用</b>，任务结束即刻输出清晰消耗卡片。</p>
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <h3>🪟 macOS 原生灵动悬浮窗</h3>
      <p>SwiftUI + AppKit 纯原生构建。闲置微胶囊吸附 + 展开式毛玻璃仪表盘，提供实时巡检、历史回溯与 30 天效能看板。</p>
    </td>
    <td width="50%" valign="top">
      <h3>🎯 零摩擦交互与显式控制</h3>
      <p>开箱即用。在对话中随心使用 <code>direct</code>（直出）、<code>delegate</code>（委派）或自然语言控制当前任务编排，不污染全局配置。</p>
    </td>
  </tr>
</table>

---

## 🚀 快速安装

### 一键安装

```bash
# macOS / Linux
git clone git@github.com:ParsifalC/codex-flow.git && cd codex-flow && bash install.sh
```

```powershell
# Windows PowerShell
git clone git@github.com:ParsifalC/codex-flow.git; cd codex-flow; .\install.ps1
```

> ⚠️ **重要**：安装完成后请**完整重启 Codex**（重新打开应用），即可自动激活 FlowPilot 编排能力！

---

## 🎮 基本使用

### 1. 对话内自然语言路由

在 Codex 对话中，你可以随时用关键词或自然语言精确指定当前任务是否使用子 Agent（仅当前轮次生效）：

```text
👉 自动模式（默认） : "按默认策略实现" / "自适应处理"
👉 强制委派 (Worker) : "delegate" / "使用子 agent 实现" / "交给 worker 处理"
👉 单兵直出 (Direct) : "direct" / "不要使用子 agent，直接完成" / "这次直接做"
```

---

### 2. 交互式控制台

终端输入 `codex-flow` 即刻进入交互式管理菜单：

```bash
codex-flow
```

```text
╭────────────────────────────────────────────────────────────────────╮
│                  🚀 codex-flow 控制台 (v1.6.0)                   │
│    FlowPilot 智能编排 · 确定性任务遥测 · 本地 Benchmark 验证     │
╰────────────────────────────────────────────────────────────────────╯
  [1] 🪟 macOS 原生悬浮窗 (overlay widget)
  [2] 📊 查看最新任务卡片 (usage last)
  [3] 📜 浏览历史任务列表 (usage list)
  [4] 📈 项目聚合统计分析 (usage stats)
  [5] 🎯 查看生效策略配置 (status)
  [6] 🩺 运行系统诊断检查 (doctor)
  [7] ⚡ 本地快速 Benchmark (benchmark-local quick)
  [8] 🔄 检查与拉取更新 (update)
  [0] 🚪 退出
```

---

### 3. 常用 CLI 快捷命令

```bash
# 📊 查看最近任务的 Token、耗时与账户 Quota 变化
codex-flow usage last

# 📜 查看历史任务列表
codex-flow usage list --today

# 📈 查看 30 天算力卸载与缓存命中分析
codex-flow usage stats -d 30

# 🩺 环境诊断与配置检查
codex-flow doctor

# 🔄 一键无损更新
codex-flow update
```

---

## 🪟 FlowPilot macOS 原生悬浮窗

专为 macOS 深度定制的 **100% 纯原生毛玻璃效能看板**，深度打通任务生命周期与 Quota 监控。

<div align="center">
  <img src="docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Widget Showcase" width="100%" style="border-radius: 12px; margin: 16px 0;" />
</div>

- **🟢 灵动微胶囊 (Capsule)**：闲置时边缘半收起，呼吸光环直观指示任务状态与最新消耗。
- **⚡️ 实时巡检 (Inspector)**：3 组高精环形仪表盘（耗时 / Tokens / 费用），实时呈现 5m / 1h / 1d 配额水位与 Agent 拓扑树。
- **📜 历史回溯 (History)**：多项目任务流水线，点击任意历史任务即刻切回详情回溯。
- **📊 效能看板 (Analytics)**：7d/30d 缓存命中率、Worker 算力卸载比与多模型/多仓库活跃度分布。

```bash
# 一键启动悬浮窗
codex-flow overlay start

# 切换展开 / 折叠
codex-flow overlay toggle
```

---

## 📚 深入文档

高级特性、底层原理与深入定制请参阅二级文档：

| 模块 | 文档入口 | 核心内容 |
| :--- | :--- | :--- |
| **⚙️ 策略与配置** | [docs/configuration.md](docs/configuration.md) | `codex-flow.toml` 参数全解、推理强度矩阵、环境变量覆盖 |
| **📈 确定性遥测** | [docs/telemetry.md](docs/telemetry.md) | Hook 生命周期、Token 差值归因算法、账户 Quota 采集机制 |
| **🪟 原生悬浮窗** | [docs/overlay.md](docs/overlay.md) | 交互手势、快捷控制、IPC 通信与 SwiftUI 架构指南 |
| **🧪 本地基准测试** | [docs/benchmark.md](docs/benchmark.md) | 6 任务平衡测试集、本地无 Key 评测方法与多策略对比 |
| **☁️ Actions 评测** | [docs/benchmark-actions.md](docs/benchmark-actions.md) | GitHub Actions 云端自动化 Benchmark 工作流 |
| **🌐 多语言支持** | [docs/localization.md](docs/localization.md) | 中英双语 (i18n) 切换与本地化范围说明 |

---

## 📄 开源协议

本项目采用 [MIT License](LICENSE) 开源协议。
