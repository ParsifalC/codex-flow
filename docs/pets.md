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

| 动作 | 触发时机 |
| --- | --- |
| `idle` | 空闲或实时状态不可用 |
| `running-right` | 向右拖动 |
| `running-left` | 向左拖动 |
| `waving` | 悬停或收到新结果 |
| `jumping` | 明确确认任务成功 |
| `failed` | 明确确认任务失败 |
| `waiting` | 等待用户回答或授权 |
| `running` | 任务开始或恢复执行 |
| `review` | 实际进入审查 |

任务动作来自宿主事件和 FlowPilot 的明确执行报告。普通结束不等于成功，某次命令失败也不等于整个任务失败。宿主没有提供相应事件时不会猜测状态。运行、等待或审查超过 120 秒没有新事件，会退回空闲并标记实时状态不可用；明确的失败状态会保留。

多个任务同时运行时，宠物跟随最近启动的任务。动画不会改变已完成详情和未读标记；历史刷新不会重播庆祝。系统开启“减少动态效果”时显示静态姿势，浮窗展开或隐藏时停止动画计时。

更新安装后，如果 Codex 提示重新信任 FlowPilot hooks，需要在宿主中完成正常的信任操作，任务状态事件才会生效。关闭遥测后不再采集实时活动。

## 资源保存在哪里

资源和选择保存在 `$CODEX_HOME/codex-flow/pets/`，默认是 `~/.codex/codex-flow/pets/`。应用更新和卸载会保留这个目录；需要彻底移除资源时可以自行删除。

Petdex 下载包会保存来源、作者和内容摘要。素材的使用许可以作者声明为准。
