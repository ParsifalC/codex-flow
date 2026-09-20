# macOS 原生悬浮窗组件 (FlowPilot Overlay)

<div align="center">

<img src="assets/logo.png" alt="FlowPilot Logo" width="100" height="100" />

<br />

[ 简体中文 ](overlay.md) | [ English ](overlay.en.md)

</div>


**FlowPilot Overlay** 是专为 macOS 设计的 100% 纯原生桌面交互组件（基于 **SwiftUI + AppKit** 构建）。无需打开终端或网页，即可在桌面上实时获取多 Agent 协同编排 Telemetry 遥测指标、账户速率配额感知、历史会话回溯以及聚合效能分析看板。

![FlowPilot 桌面场景演示](assets/promo/flowpilot_promo_desktop_scene.png)

---

## 悬浮入口与四个页面

本轮目标、结果和编排使用 `session_id + turn_id` 区分，不维护 chat 总目标。
新数据必须有 `publication` 才进入详情；旧的已结束记录仍可浏览，缺失字段不回填。
宿主凭证传递按安装环境验证，详见[遥测兼容性说明](telemetry.md#按轮次保存目标计划和结果)。

任务、历史、统计、账户四个 tab 和更多、置顶、收起、切换、复制操作保留。
任务、历史及账户不显示 300 分钟（五小时）额度窗口；底层采集及其他周期保留。
右上角“更多 → 语言”可选择跟随系统、中文或 English，设置会保存并立即生效。
本轮目标完整显示，不提供展开按钮；执行详情默认展开，完整计划 JSON 仍可按需展开。
计划显示任务各阶段的人员配置，参与人数显示本轮已记录的 Agent；沿用计划不代表重跑全部阶段。
统计页汇总所选时间内本机 FlowPilot 已记录的已完成轮次，不是账户跨设备总用量。
原生玻璃使用 `NSVisualEffectView`；减少透明度时使用不透明底色。
浮窗宽 420 pt，正文及设置项使用 13–14 pt 字体，目标使用 16 pt，辅助文字至少 12 pt。
长信息分行或滚动查看，账户重置时间不会自动缩成小字。

本期原生 UI 仅支持 macOS。Windows 保持 Python/CLI 兼容，并规定较高不透明度的
亚克力底色；无系统材质或高对比模式使用纯色和清晰边框。HTML 的 `backdrop-filter`
仅用于[导航仿真](../apps/macos-overlay/flowpilot-overlay-navigation.html)，不代表
Windows 原生浮窗已实现或已验证。旧宣传截图可能仍展示改造前的内容。

![FlowPilot 3 状态全景海报](assets/promo/flowpilot_promo_poster.png)

### 1. 悬浮入口
- **状态**：显示“新结果”“最近完成”或“等待结果”，以及最近已完成轮次的 Token 消耗。
- **未读提示**：新结果显示圆点；明确打开该轮次后清除，自动弹出不视为已读。
- **边缘收起**：停靠时缩成图标、未读点和展开箭头；正常状态使用 148×58pt 毛玻璃胶囊。
- **辅助功能**：跟随系统减少透明度和减少动态效果设置。

---

### 2. Inspector（已完成轮次详情）
- **本轮目标与结果**：目标只读取 `turn_context.goal`，结果只读取本轮父 Agent 的 `result`；缺失时显示“未记录”。父 Stop 发布之前不展示本轮详情。
- **编排配置**：执行详情默认折叠，展示完整计划中的策略、路由与审查配置；计划人数和实际参与人数分别呈现。
- **运行事实**：紧凑呈现耗时、Tokens 和实际参与人数，放在目标与结果之后。
- **完整计划**：执行详情中可继续展开完整 JSON，查看计划来源与修订；长目标和结果支持展开全文。
- **账户信息**：账户 tab 保留其他周期的额度和重置时间，五小时窗口仅从显示层过滤。
- **历史查看态导航**：回溯已完成轮次，或返回最新已发布快照。历史中每轮保留自己的目标和结果。

---

### 3. 历史
- **项目与会话**：按项目路径分组，再按会话展开轮次。
- **时间范围**：切换“全部”或“今天”，也可手动刷新。
- **轮次条目**：显示目标、轮次标识、完成时间、耗时和 Token 消耗。
- **搜索与详情**：搜索项目、会话或目标；点击轮次进入共用的任务详情。

---

### 4. 📊 Analytics (30 天效能聚合看板)
- **周期切换**：支持一键切换 `7 天` 与 `30 天` 聚合分析视图。
- **核心效能 KPI**：汇总任务总数（委派派发 vs 直接执行）、累计活跃工时与总消耗 Token。
- **缓存效率 (Cache Hit)**：缓存命中百分比与累计节省 Token 数。
- **Worker 分流率 (Offload Ratio)**：经济型 Worker 承担的计算分流百分比。
- **模型分布矩阵**：各模型的调用次数、Token 占比与角色定位（Parent / Worker）。
- **项目活跃度排行**：多工程/多仓库的任务频次与活跃热度排行。

---

## 🔒 隐私脱敏与演示模式 (Privacy & Demo Mode)

FlowPilot 内置了系统级隐私保护模式（`isPrivacyMode`），专为公开演示、技术分享或录屏截图设计，防止敏感工程名、私有指令或业务数据泄露。

开启脱敏模式后：
- 任务 **目标** 与 **结果** 使用原生隐私显示规则隐藏。
- 顶部 Header 与历史列表中的 **会话标题** 及 **Prompt 提示词** 自动毛玻璃脱敏。
- 项目与仓库名称在 Header、History 与 Analytics 视图中均自动打码。

---

## 🛠️ 超高精无截断截图与宣传图渲染管线

FlowPilot 提供了基于 SwiftUI `ImageRenderer` 的全景无截断渲染脚本 ([scripts/generate_showcase.swift](file:///Users/parsifal/Repo/SkillHub/codex-flow/scripts/generate_showcase.swift))，可一键输出 2x / 3x Retina 高清资产：

```bash
# 编译并生成全套高精截图与宣传物料
SWIFT_FILES=($(find apps/macos-overlay/Sources -name "*.swift" ! -name "main.swift"))
swiftc -framework Cocoa -framework SwiftUI -framework Combine "${SWIFT_FILES[@]}" scripts/generate_showcase.swift -o bin/generate_showcase
bin/generate_showcase
```

生成产物位于 `docs/assets/`：
- `docs/assets/screenshots/inspector_full.png`（全高无截断 Inspector 视图）
- `docs/assets/screenshots/history_full.png`（全高无截断 History 任务流水线）
- `docs/assets/screenshots/analytics_full.png`（全高无截断 Analytics 看板）
- `docs/assets/screenshots/capsule.png`（3x Retina 灵动微胶囊）
- `docs/assets/promo/flowpilot_promo_poster.png`（2720 × 2002 三态对比全景海报）
- `docs/assets/promo/flowpilot_promo_banner.png`（2680 × 1594 宽屏 Hero Banner）
- `docs/assets/promo/flowpilot_promo_desktop_scene.png`（2560 × 1440 沉浸式桌面场景图）
- `docs/assets/promo/flowpilot_promo_strategies.png`（3480 × 1363 四大编排策略全景图）

---

## 🚀 快速上手与 CLI 控制

### 编译与运行
```bash
# 源码编译
bash apps/macos-overlay/build.sh

# 启动常驻浮窗守护进程
codex-flow overlay start
```

### CLI 控制指令
```bash
# 查看浮窗运行状态
codex-flow overlay status

# 切换 展开 / 收起
codex-flow overlay toggle
codex-flow overlay expand       # 展开为卡片
codex-flow overlay collapse     # 收起为灵动微胶囊

# 切换选项卡
codex-flow overlay tab inspector
codex-flow overlay tab history
codex-flow overlay tab analytics
codex-flow overlay tab account

# 穿透查看指定历史任务
codex-flow overlay show 1

# 打开统计看板与历史
codex-flow overlay stats 30     # 30 天效能统计
codex-flow overlay history      # 任务历史列表

# 进程生命周期管理
codex-flow overlay restart
codex-flow overlay stop
```

---

## 🖱️ 鼠标与快捷交互

| 动作 | 交互效果 |
| :--- | :--- |
| **光标悬停气泡 (0.4s)** | 触发 Spring 弹性展开为全功能毛玻璃监控台 |
| **光标离开卡片 (0.8s)** | 延迟自动收起为微胶囊（未 Pin 锁定时） |
| **点击气泡 / 顶部折叠按钮** | 瞬间切换展开 / 折叠状态 |
| **点击 Pin 锁定图标 (`📌`)** | 永久置顶常驻桌面，不随光标移出收起 |
| **任意位置拖拽** | 自由平滑拖拽，支持屏幕边缘磁吸吸附 |
| **右键上下文菜单** | 快速切换视图、Pin 锁定、刷新数据、打开终端或退出应用 |
| **点击「复制摘要 (Copy Summary)」**| 格式化复制任务报告至系统剪贴板（带 Copied 动画反馈） |
| **点击「控制台 (Console)」** | 快速在终端中唤起 `codex-flow` 交互式管理菜单 |
