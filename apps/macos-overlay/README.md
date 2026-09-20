# macOS 原生悬浮窗 (Native Floating Widget)

<div align="center">

[ 简体中文 ](README.md) | [ English ](README.en.md)

</div>

`codex-flow-overlay` 是专为 macOS 设计的 100% 纯原生（基于 **SwiftUI + AppKit** 构建）桌面悬浮窗组件，深度集成了 `codex-flow usage` 的全部核心能力（已完成轮次详情、账户信息、历史回溯、聚合统计）。

---

<div align="center">
  <img src="../../docs/assets/promo/flowpilot_promo_poster.png" alt="FlowPilot Native Overlay Showcase" width="100%" style="border-radius: 12px; margin: 12px 0;" />
</div>

---

## 界面与数据

- **悬浮入口**：148×58pt 毛玻璃胶囊，显示新结果状态和最近已完成轮次的 Token 消耗；靠边后缩成图标、未读点与箭头。
- **任务**：显示项目、会话、本轮目标与结果。目标由父 Agent 提炼写入，最多 80 个 Unicode 码点、两句话；结果来自同轮父 Agent 的最终输出。父 Stop 发布后才展示，缺失内容显示“未记录”。
- **执行详情**：默认折叠，显示实际保存的完整编排计划，区分计划人数与实际参与人数。
- **历史**：按项目、会话、轮次分组，支持全部/今天、搜索和切换轮次。
- **统计**：保留 7/30 天用量、缓存效率、模型和项目分布。
- **账户**：保留账户信息、其他周期额度、重置事实、全局策略与自启动设置；五小时额度仅从 UI 隐藏，底层采集保留。
- **操作**：四个 tab，置顶、收起、更多菜单、复制摘要及切换入口；底部不再重复品牌名。

新结果在明确查看后标记已读，自动弹窗不清除未读。隐私模式隐藏项目、会话、目标与结果，并禁用摘要复制。原生材质支持系统减少透明度和减少动态效果；Windows 目前只覆盖 Python/CLI，不提供原生浮窗。

旧宣传图可能与当前界面不同。详见[浮窗说明](../../docs/overlay.md)及[按轮次记录与宿主验证](../../docs/telemetry.md#按轮次保存目标计划和结果)。

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
codex-flow overlay tab account

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
| **光标移出卡片区域** | 延迟 0.8 秒自动收起为胶囊（未 Pin 时） |
| **单击气泡 / 顶部折叠按钮** | 立即切换展开 / 收起状态 |
| **切换 Tab 选项卡** | 平滑切换 任务、历史、统计、账户 |
| **点击 History 任务条目** | 立即在 Inspector 中回溯该轮次的目标、结果与编排详情 |
| **按住气泡拖拽** | 自由拖拽到屏幕任意角落（带边界贴靠保护） |
| **右键点击** | 弹出上下文菜单（Pin 锁定、折叠/展开、打开控制台、刷新、退出） |
| **点击「Copy Summary」** | 格式化复制任务摘要至系统剪贴板 |
| **点击「Console」** | 快速唤起终端打开 `codex-flow` 管理控制台 |
