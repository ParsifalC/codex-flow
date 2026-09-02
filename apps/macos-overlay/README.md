# macOS 原生悬浮窗 (Native Floating Widget)

`codex-flow-overlay` 是专为 macOS 设计的 100% 纯原生（SwiftUI + AppKit）悬浮窗组件。

---

## ✨ 核心特性

- 🟢 **默认形态（圆形悬浮气泡）**：
  - 直径 68px 的 Frosted Glass 毛玻璃拟物风格（macOS `ultraThinMaterial`）；
  - 外圈动态彩虹渐变边框与实时呼吸灯；
  - 实时状态角标（🟢 空闲/完成 · 🔵 任务运行中 · 🟠 异常/告警）；
  - 底部微缩显示最近任务的 Token 消耗徽章（如 `42.5k`）；
  - 支持全屏任意位置自由拖拽移动与边缘防溢出贴靠。

- ⚡️ **展开时机（光标停止 1 秒展开 / Hover Dwell 1.0s）**：
  - 当鼠标光标移入气泡并在气泡上**停止微动达到 1.0 秒**时，自动触发 Spring 弹性动画无缝展开为精致的 **Summary 卡片**；
  - 鼠标离开卡片超过 0.8 秒后平滑收起（支持点击 Pin 锁定常驻）；
  - 单击气泡可立即展开/收起。

- 📊 **展开态（现代化 Native Summary 卡片）**：
  - **Header**：项目名标签、Git 分支胶囊、任务状态徽章、Pin 锁定按钮与折叠按钮；
  - **KPI Rings**：3 组高精环形仪表盘（Time 耗时、Tokens 消耗、Cost 费用估算）；
  - **Token 进度条**：多色堆叠胶囊条，直观呈现 Prompt 输入、Output 输出与 Cache 命中比例；
  - **多 Agent 路由拓扑**：展示 Parent Agent（模型与 Reasoning 强度）及各个 Worker Subagents 的独立用量与状态；
  - **操作底栏**：一键复制 Summary 到剪贴板（带 Copied 动画反馈）、唤起终端控制台、Pin 锁定等。

---

## 🚀 快速使用

### 1. 编译构建
```bash
bash apps/macos-overlay/build.sh
```
编译产物位于 `apps/macos-overlay/bin/codex-flow-overlay`。

### 2. 启动悬浮窗守护进程
```bash
# 启动后台常驻悬浮窗
codex-flow overlay start
# 或直接执行二进制
./apps/macos-overlay/bin/codex-flow-overlay start &
```

### 3. CLI 控制指令
```bash
# 检查浮窗运行状态
codex-flow overlay status

# 切换展开 / 折叠
codex-flow overlay toggle

# 主动展开 Summary 卡片
codex-flow overlay expand

# 收起为圆形气泡
codex-flow overlay collapse

# 推送并刷新最新 telemetry 运行数据
codex-flow overlay update

# 停止悬浮窗
codex-flow overlay stop
```

---

## 🖱 交互与快捷操作

| 动作 | 效果 |
|---|---|
| **光标移入气泡停留 1 秒** | 触发 Spring 弹性展开为 Summary 卡片 |
| **光标移出卡片区域** | 延迟 0.8 秒自动收起为圆形气泡（未 Pin 时） |
| **单击气泡 / 顶部按钮** | 立即切换展开 / 收起状态 |
| **按住气泡拖拽** | 自由拖拽到屏幕任意角落（带边界贴靠保护） |
| **右键点击** | 弹出上下文菜单（Pin 锁定、折叠/展开、打开控制台、刷新、退出） |
| **点击「Copy Summary」** | 格式化复制任务摘要至系统剪贴板 |
| **点击「Open Console」** | 快速唤起终端打开 `codex-flow` 管理控制台 |
