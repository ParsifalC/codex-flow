# macOS 原生悬浮窗 (Native Floating Widget)

<div align="center">

[ 简体中文 ](README.md) | [ English ](README.en.md)

</div>

`codex-flow-overlay` 是专为 macOS 设计的 100% 纯原生（基于 **SwiftUI + AppKit** 构建）桌面悬浮窗组件，深度集成了 `codex-flow usage` 的全部核心能力（实时巡检、配额监控、历史回溯、聚合效能分析）。

---

<div align="center">
  <img src="../../docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Overlay Showcase" width="100%" style="border-radius: 12px; margin: 12px 0;" />
</div>

---

## ✨ 核心特性

- 🟢 **默认形态（灵动微胶囊 Micro Capsule）**：
  - 直径 68px 的 Frosted Glass 毛玻璃拟物圆环（macOS `ultraThinMaterial`）；
  - 外圈动态彩虹渐变边框与实时呼吸灯；
  - 实时状态角标（🟢 空闲/完成 · 🔵 任务运行中 · 🟠 异常/告警）；
  - 底部微缩显示最近任务的 Token 消耗徽章（如 `198.2k`）；
  - 边缘自动半收起（Half-Tuck）与屏幕防溢出磁吸贴靠。

- ⚡️ **展开态（全功能 Glass TabBar 监控台）**：
  - **⚡️ Inspector（任务巡检）**：
    - **Header**：项目名标签、Git 分支胶囊、任务状态徽章、Pin 锁定按钮与折叠按钮；
    - **任务目标与交付结论卡**：智能提炼展示会话目标与交付成果；
    - **KPI Rings**：3 组高精环形仪表盘（Time 耗时、Tokens 消耗、Cost 费用估算）；
    - **Rate Limits & Quota**：5m / 1h / 1d / 7d 账户配额消耗百分比进度与重置倒计时；
    - **Token 细分条**：多色堆叠胶囊条，直观呈现 Prompt、Output、Cached 与 Reasoning 思考 Token 分布；
    - **多 Agent 路由拓扑**：展示 Parent Agent（模型与 Reasoning 强度）及各个 Worker Subagents 的独立用量与状态；
    - **技能与 MCP 标签**：自动标注调用的 Skills 与 MCP Server 工具；
    - **历史查看态导航**：支持回溯任意历史任务，提供一键 `[⚡️ 查看最新]` 返回实时任务；
    - **操作底栏**：一键复制 Summary 剪贴板（带 Copied 动画反馈）、唤起终端控制台、Pin 锁定常驻。
  - **📜 History（历史回溯）**：
    - 多维历史会话：支持按工程过滤、`All` / `Today` 切换与实时关键词检索；
    - **会话手风琴 (Chat Accordion)**：按会话聚合多轮任务，展示会话总 Token 与最大并发；
    - **轮次流水线 (Session Turns)**：精确展开每一轮次的时间、耗时、Worker 标签与配额消耗差值（`+1%` / `-1%`）；
    - 点击任意历史任务条目即刻在 Inspector 中展开深度详情。
  - **📊 Analytics（效能看板）**：
    - 集成聚合效能分析，支持 `7 Days` / `30 Days` 周期切换；
    - 汇总总任务数（委派 vs 直接）、总活跃时长、总 Token 消耗与费用预估；
    - **Cache Efficiency**：缓存命中率与节省 Token 统计；
    - **Worker Offload**：Worker 算力委派比例仪表；
    - **Model Breakdown**：各模型调用次数、Token 占比与角色标签（Parent/Worker）；
    - **Projects Distribution**：多仓库/多项目活跃度排行。

---

## 🔒 隐私脱敏与演示模式

内置 `isPrivacyMode` 隐私保护：
- 所有敏感项目名、对话指令、任务目标与交付结论均自动采用平滑的高斯模糊滤镜（`blur(radius: 4.5)`）打码；
- 非常适合录屏演示、公开分享与制作文档插图。

---

## 🚀 快速使用

### 1. 编译构建
```bash
bash apps/macos-overlay/build.sh
```
编译产物位于 `apps/macos-overlay/bin/FlowPilot`。

### 2. 启动悬浮窗守护进程
```bash
# 启动后台常驻悬浮窗
codex-flow overlay start
# 或直接执行二进制
./apps/macos-overlay/bin/FlowPilot start &
```

### 3. CLI 控制指令
```bash
# 检查浮窗运行状态
codex-flow overlay status

# 切换展开 / 折叠
codex-flow overlay toggle
codex-flow overlay expand
codex-flow overlay collapse

# 切换视图选项卡
codex-flow overlay tab inspector
codex-flow overlay tab history
codex-flow overlay tab analytics

# 查看指定历史任务（支持 #1、#2 或 session_id）
codex-flow overlay show 1

# 打开统计看板（可指定天数）
codex-flow overlay stats 30

# 打开任务历史列表
codex-flow overlay history

# 推送并刷新最新 telemetry 运行数据
codex-flow overlay update

# 停止悬浮窗
codex-flow overlay stop
```

---

## 🖱 交互与快捷操作

| 动作 | 效果 |
|---|---|
| **光标移入气泡停留 0.4 秒** | 触发 Spring 弹性展开为 Telemetry 卡片 |
| **光标移出卡片区域** | 延迟 0.8 秒自动收起为圆形气泡（未 Pin 时） |
| **单击气泡 / 顶部折叠按钮** | 立即切换展开 / 收起状态 |
| **切换 Tab 选项卡** | 平滑切换 Inspector（任务详情）、History（任务列表）、Analytics（效能统计） |
| **点击 History 任务条目** | 立即在 Inspector 中回溯该任务的完整 Token、费用与配额明细 |
| **按住气泡拖拽** | 自由拖拽到屏幕任意角落（带边界贴靠保护） |
| **右键点击** | 弹出上下文菜单（Pin 锁定、折叠/展开、打开控制台、刷新、退出） |
| **点击「Copy Summary」** | 格式化复制任务摘要至系统剪贴板 |
| **点击「Console」** | 快速唤起终端打开 `codex-flow` 管理控制台 |
