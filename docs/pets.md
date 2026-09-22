# 给悬浮按钮换一个宠物

在 [Petdex](https://petdex.dev) 挑一个宠物，复制它的名称，然后运行：

```bash
codex-flow pets install boba
```

安装完成后自动启用。浮窗未运行时会保存选择，下次启动生效：

```bash
codex-flow overlay start
```

不需要安装 Petdex 客户端或 Node。动画显示目前支持 macOS 原生浮窗。宠物以透明背景独立显示，消耗文字位于下方；点击打开详情，拖动可以移动位置。

## 安装和切换

```bash
codex-flow pets install petdex:boba  # 明确指定 Petdex 来源
codex-flow pets list                # 查看已安装宠物，* 表示当前选择
codex-flow pets use boba            # 切换到已安装宠物，无需联网
codex-flow pets use default         # 恢复默认形象，保留已安装资源
```

重复安装相同内容会启用已有资源；同名但内容不同的包会被拒绝，不会覆盖旧文件。
下载或验证失败时保留原来的选择。原生解码失败会提示加载未成功，浮窗恢复默认形象。

## 导入其他宠物库

同格式的资源可以直接从本地目录或 ZIP 安装：

```bash
codex-flow pets install ./my-pet/
codex-flow pets install ./my-pet.zip
```

安装后会打印 `local-` 开头的 ID，切换时使用这个 ID。
目录内需要 `pet.json` 和 PNG 或 WebP 精灵图，例如：

```json
{
  "id": "my-pet",
  "displayName": "My Pet",
  "description": "My companion",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp"
}
```

v1 使用 8 列 × 9 行，v2 使用 8 列 × 11 行；每格比例为 192:208，可以等比例缩放。两者都播放前九行。图片最多 16 MiB、16M 像素，不能使用越界路径或符号链接。

GIF、Shimeji 等不同格式需要先转换成上述精灵图格式。首版没有这些格式的直接读取器，也没有内置资源商城。

## 九种动作

宠物会自己活动，不需要运行任务或触发特殊 hooks。启动约 4 秒后开始第一段小动作；之后通常安静 15–30 秒，再播放一段约 2–4 秒的场景。场景轮换时避免紧接着重复，九套动画都会用到：

| 日常场景 | 动作 |
| --- | --- |
| 平时待着 | `idle` |
| 左右活动 | `running-left → idle → running-right` |
| 自己忙一会儿 | `review → running` |
| 等得无聊 | `waiting → failed` |
| 自娱自乐 | `jumping → waving → idle` |

场景里的 `failed` 是短暂沮丧，`review` 是思考动作，不代表任务失败或正在审查。每段结束后恢复空闲；宠物只在落点附近移动最多 10 点，文字和窗口不会跟着移动，也不会越走越远。

- 鼠标靠近时挥手，8 秒内不重复触发；悬停不会打开详情，点击才打开。
- 拖动会打断日常动作；水平方向拖动时播放对应跑动，松手后恢复。
- 新结果到达时跳跃一次，不自动打开面板；同一结果不会因历史刷新或重复通知再次庆祝。
- 如果接通了真实任务事件，工作、等待输入等状态优先于日常动作；非终态超过 120 秒没有更新后恢复日常活动。缺少 hooks 不影响自主动作。
- 浮窗隐藏、详情展开时暂停；系统开启“减少动态效果”时保持静态。

任务数据仍由遥测提供。关闭遥测后，宠物的日常动作可以继续播放，但不再采集实时任务活动。更新 hooks 后如宿主提示信任，需要在 Codex 中完成正常的信任操作。

## 资源保存在哪里

资源和选择保存在 `$CODEX_HOME/codex-flow/pets/`，默认是 `~/.codex/codex-flow/pets/`。应用更新和卸载会保留这个目录；需要彻底移除资源时可以自行删除。

Petdex 下载包会保存来源、作者和内容摘要。素材的使用许可以作者声明为准。
